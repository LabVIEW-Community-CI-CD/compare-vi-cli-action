#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync, readdirSync, statSync } from 'node:fs';

const repoRoot = process.cwd();
const ignoredDirNames = new Set(['.venv', '__pycache__', 'node_modules']);

function walk(relativeDir, predicate) {
  const start = path.join(repoRoot, relativeDir);
  const results = [];

  function visit(currentPath) {
    for (const entry of readdirSync(currentPath, { withFileTypes: true })) {
      const absolutePath = path.join(currentPath, entry.name);
      const relativePath = path.relative(repoRoot, absolutePath).replace(/\\/g, '/');
      if (entry.isDirectory()) {
        if (ignoredDirNames.has(entry.name)) {
          continue;
        }
        visit(absolutePath);
        continue;
      }
      if (!predicate || predicate(relativePath)) {
        results.push(relativePath);
      }
    }
  }

  visit(start);
  return results;
}

function read(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function readPackageJson() {
  return JSON.parse(read('package.json'));
}

test('ruamel imports stay inside tools/workflows', () => {
  const pythonFiles = walk('tools', (relativePath) => relativePath.endsWith('.py'));
  for (const relativePath of pythonFiles) {
    const raw = read(relativePath);
    if (relativePath.startsWith('tools/workflows/')) {
      continue;
    }
    assert.doesNotMatch(raw, /ruamel\.yaml/, `${relativePath} should not import or mention ruamel.yaml`);
  }
});

test('repo scripts and workflows do not inline-install ruamel', () => {
  const trackedTextFiles = [
    ...walk(
      'tools',
      (relativePath) =>
        /\.(ps1|psm1|mjs|ts|py)$/.test(relativePath) &&
        !relativePath.includes('/__tests__/') &&
        !relativePath.startsWith('tools/workflows/tests/')
    ),
    ...walk('.github/workflows', (relativePath) => relativePath.endsWith('.yml'))
  ];

  for (const relativePath of trackedTextFiles) {
    const raw = read(relativePath);
    assert.doesNotMatch(raw, /pip install[^\n]*ruamel/i, `${relativePath} should not inline-install ruamel`);
  }

  const dockerfile = read('tools/docker/Dockerfile.tools');
  assert.match(dockerfile, /requirements\.txt/, 'tools image should install pinned workflow enclave requirements');
  assert.match(dockerfile, /python3-venv/, 'tools image should install python3-venv for workflow enclave venv creation');
  assert.doesNotMatch(dockerfile, /pip install[^\n]*ruamel/i, 'tools image should not install ruamel inline');
});

test('workflow-writing callers use the enclave wrapper instead of the low-level updater', () => {
  const checkWorkflowDrift = read('tools/Check-WorkflowDrift.ps1');
  assert.match(checkWorkflowDrift, /workflow_enclave\.py/);
  assert.match(checkWorkflowDrift, /--default-scope/);
  assert.match(checkWorkflowDrift, /COMPAREVI_PYTHON_EXE/);
  assert.match(checkWorkflowDrift, /-3/);
  assert.match(checkWorkflowDrift, /if \(\$FailOnDrift\)\s*\{\s*exit 2\s*\}/);
  assert.match(checkWorkflowDrift, /Executable\s*=/);
  assert.match(checkWorkflowDrift, /Arguments\s*=/);
  assert.match(checkWorkflowDrift, /\$pythonCommand = Resolve-PythonCommand/);
  assert.match(checkWorkflowDrift, /& \$pythonCommand\.Executable @pythonArguments/);
  assert.match(checkWorkflowDrift, /Push-Location \$repoRoot/);
  assert.match(checkWorkflowDrift, /git -C \$repoRoot/);
  assert.match(checkWorkflowDrift, /managedWorkflowFiles array of non-empty strings/);
  assert.doesNotMatch(checkWorkflowDrift, /update_workflows\.py/);

  const dockerChecks = read('tools/Run-NonLVChecksInDocker.ps1');
  assert.match(dockerChecks, /workflow_enclave\.py/);
  assert.match(dockerChecks, /--default-scope/);
  assert.match(dockerChecks, /COMPAREVI_WORKFLOW_ENCLAVE_HOME=\/opt\/comparevi-workflow-enclave/);
  assert.match(dockerChecks, /COMPAREVI_WORKFLOW_ENCLAVE_HOME=\/tmp\/comparevi-workflow-enclave/);
  assert.match(dockerChecks, /node tools\/npm\/run-script\.mjs lint:md/);
  assert.match(dockerChecks, /git config --global --add safe\.directory \/work/);
  assert.doesNotMatch(dockerChecks, /-AcceptExitCodes\s+@\(0,1\)\s+-Label 'markdownlint(?: \(tools\))?'/);
  assert.doesNotMatch(dockerChecks, /update_workflows\.py/);

  const validateWorkflow = read('.github/workflows/validate.yml');
  assert.match(validateWorkflow, /Check-WorkflowDrift\.ps1 -FailOnDrift/);
  assert.doesNotMatch(validateWorkflow, /update_workflows\.py/);
});

test('workflow updater normalizes checkout insertion and docs-only expressions correctly', () => {
  const updater = read('tools/workflows/_update_workflows_impl.py');
  assert.match(updater, /def dump_yaml\(doc, _path: Path\)/);
  assert.match(updater, /steps\.g\.outputs\.docs_only \|\| 'false'/);
  assert.doesNotMatch(updater, /docs_only \|\| ''false''/);
  assert.match(updater, /True in doc/);
  assert.match(updater, /def _find_step_uses_index/);
  assert.doesNotMatch(updater, /_find_step_index\(steps, 'actions\/checkout@v5'\)/);
  assert.match(updater, /actions\/setup-node@v5/);
  assert.doesNotMatch(updater, /actions\/setup-node@v4/);
});

test('package scripts expose first-class workflow drift and markdown surfaces', () => {
  const packageJson = readPackageJson();
  assert.equal(packageJson.scripts['workflow:drift:ensure'], 'node tools/workflows/run-workflow-enclave.mjs --ensure-only');
  assert.equal(packageJson.scripts['workflow:drift:check'], 'node tools/workflows/run-workflow-enclave.mjs --default-scope --check');
  assert.equal(packageJson.scripts['workflow:drift:write'], 'node tools/workflows/run-workflow-enclave.mjs --default-scope --write');
  assert.equal(packageJson.scripts['lint:md'], 'node tools/lint-markdown.mjs --all');
});

test('workflow enclave state is ignored and the compatibility surfaces exist', () => {
  const gitignore = read('.gitignore');
  assert.match(gitignore, /tools\/workflows\/\.venv\//);
  assert.equal(statSync(path.join(repoRoot, 'tools', 'workflows', 'update_workflows.py')).isFile(), true);
  assert.equal(statSync(path.join(repoRoot, 'tools', 'workflows', 'workflow_enclave.py')).isFile(), true);
  assert.equal(statSync(path.join(repoRoot, 'tools', 'workflows', 'run-workflow-enclave.mjs')).isFile(), true);
  assert.equal(statSync(path.join(repoRoot, 'tools', 'workflows', 'requirements.txt')).isFile(), true);
  assert.equal(statSync(path.join(repoRoot, 'tools', 'workflows', 'workflow-manifest.json')).isFile(), true);
});

test('workflow enclave node wrapper only accepts Python 3 interpreters', () => {
  const wrapper = read('tools/workflows/run-workflow-enclave.mjs');
  assert.match(wrapper, /sys\.version_info\[0\] == 3/);
  assert.match(wrapper, /COMPAREVI_PYTHON_EXE must resolve to a Python 3 interpreter/);
  assert.match(wrapper, /canRunPython3\('python3'\)/);
  assert.match(wrapper, /canRunPython3\('python'\)/);

  const pythonWrapper = read('tools/workflows/workflow_enclave.py');
  assert.match(
    pythonWrapper,
    /Usage: workflow_enclave\.py \[--ensure-only\|--default-scope \(\--check\|\--write\)\|\(\--check\|\--write\) <files\.\.\.>\]/
  );
});

test('workflow and composite lint surfaces use repo-owned markdown commands', () => {
  const validateWorkflow = read('.github/workflows/validate.yml');
  const orchestratedWorkflow = read('.github/workflows/ci-orchestrated.yml');
  const cliLintsAction = read('.github/actions/cli-lints/action.yml');

  assert.match(validateWorkflow, /node tools\/npm\/run-script\.mjs lint:md:changed/);
  assert.match(orchestratedWorkflow, /node tools\/npm\/run-script\.mjs lint:md:changed/);
  assert.doesNotMatch(validateWorkflow, /Install markdownlint-cli \(retry\)/);
  assert.doesNotMatch(orchestratedWorkflow, /Install markdownlint-cli \(retry\)/);
  assert.doesNotMatch(cliLintsAction, /install -g markdownlint-cli/);
  assert.match(cliLintsAction, /node tools\/npm\/run-script\.mjs lint:md:changed/);
  assert.match(cliLintsAction, /markdownlint-cli2 --config docs\/relaxed\.markdownlint-cli2\.jsonc/);
});

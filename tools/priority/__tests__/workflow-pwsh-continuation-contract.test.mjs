import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowsRoot = path.join(repoRoot, '.github', 'workflows');

function collectPwshContinuationViolations() {
  const violations = [];

  for (const entry of readdirSync(workflowsRoot)) {
    if (!entry.endsWith('.yml')) {
      continue;
    }

    const workflowPath = path.join(workflowsRoot, entry);
    const workflow = yaml.load(readFileSync(workflowPath, 'utf8'));
    const jobs = workflow?.jobs ?? {};

    for (const [jobId, job] of Object.entries(jobs)) {
      const steps = Array.isArray(job?.steps) ? job.steps : [];
      steps.forEach((step, index) => {
        if (!step || step.shell !== 'pwsh' || typeof step.run !== 'string') {
          return;
        }

        step.run.split(/\r?\n/).forEach((line, lineIndex) => {
          if (line.trimEnd().endsWith('\\')) {
            violations.push({
              workflow: entry,
              jobId,
              stepName: step.name ?? `step-${index + 1}`,
              line: lineIndex + 1,
              source: line.trim()
            });
          }
        });
      });
    }
  }

  return violations;
}

test('pwsh workflow steps never rely on bash-style line continuations', () => {
  const violations = collectPwshContinuationViolations();
  assert.deepEqual(violations, []);
});

test('publish-tools-image workflow resolves context through the dedicated helper', () => {
  const workflowPath = path.join(workflowsRoot, 'publish-tools-image.yml');
  const workflow = readFileSync(workflowPath, 'utf8');

  assert.match(workflow, /node tools\/priority\/resolve-tools-image-publish-context\.mjs/);
  assert.match(workflow, /steps\.context\.outputs\.stable_family_version/);
  assert.match(workflow, /steps\.context\.outputs\.is_tools_tag/);
});

test('release workflow explicitly dispatches publish-tools-image with actions write permission', () => {
  const workflowPath = path.join(workflowsRoot, 'release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');
  const workflow = yaml.load(workflowRaw);
  const releaseJob = workflow?.jobs?.release;
  const dispatchStep = releaseJob?.steps?.find((step) => step?.name === 'Dispatch Publish Tools Image workflow');

  assert.equal(releaseJob?.permissions?.actions, 'write');
  assert.ok(dispatchStep, 'release workflow should dispatch publish-tools-image explicitly');
  assert.equal(dispatchStep.uses, 'actions/github-script@v8');
  assert.match(dispatchStep.with.script, /workflow_id:\s*'publish-tools-image\.yml'/);
  assert.match(dispatchStep.with.script, /ref:\s*'\$\{\{\s*github\.ref_name\s*\}\}'/);
  assert.match(
    dispatchStep.with.script,
    /const releaseVersion = '\$\{\{\s*steps\.comparevi_tools\.outputs\.comparevi_tools_release_version\s*\}\}';/
  );
  assert.match(dispatchStep.with.script, /const releaseChannel = releaseVersion\.includes\('-rc\.'\) \? 'rc' : 'stable';/);
});

test('release workflow resolves downloaded artifacts through the shared helper before validation', () => {
  const workflowPath = path.join(workflowsRoot, 'release.yml');
  const workflowRaw = readFileSync(workflowPath, 'utf8');
  const workflow = yaml.load(workflowRaw);
  const validateSteps = workflow?.jobs?.['validate-cli-artifacts']?.steps ?? [];
  const checkoutIndex = validateSteps.findIndex((step) => step?.uses === 'actions/checkout@v5');
  const resolveIndex = validateSteps.findIndex((step) => step?.name === 'Resolve validation artifact paths');

  assert.ok(checkoutIndex >= 0, 'validate-cli-artifacts should check out the repository before helper-backed steps');
  assert.ok(resolveIndex > checkoutIndex, 'validate-cli-artifacts should resolve artifact paths after checkout');
  assert.match(workflowRaw, /name: Resolve validation artifact paths/);
  assert.match(workflowRaw, /Resolve-DownloadedArtifactPath\.ps1/);
  assert.match(workflowRaw, /steps\.artifact_paths\.outputs\.archive_path/);
  assert.match(workflowRaw, /steps\.artifact_paths\.outputs\.checksum_path/);
  assert.match(workflowRaw, /name: Resolve release-contract artifact paths/);
  assert.match(workflowRaw, /steps\.contract_artifacts\.outputs\.provenance_path/);
  assert.match(workflowRaw, /steps\.contract_artifacts\.outputs\.linux_tarball_path/);
  assert.match(workflowRaw, /Out-File -FilePath \$env:GITHUB_OUTPUT -Encoding utf8 -Append/);
  assert.doesNotMatch(workflowRaw, /ls -1 cli-dl\/comparevi-cli-v\$\{v\}-linux-x64-selfcontained\.tar\.gz/);
  assert.doesNotMatch(workflowRaw, /tarball=\"cli-dl\/comparevi-cli-v\$\{v\}-linux-x64-selfcontained\.tar\.gz\"/);
  assert.doesNotMatch(workflowRaw, /cli-dl\/SHA256SUMS\.txt/);
});

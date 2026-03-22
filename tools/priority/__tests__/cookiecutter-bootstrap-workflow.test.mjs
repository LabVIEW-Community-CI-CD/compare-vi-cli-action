#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(process.cwd());

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('cookiecutter bootstrap workflow provisions hosted Linux and Windows proof lanes', () => {
  const workflow = read('.github/workflows/cookiecutter-bootstrap.yml');

  assert.match(workflow, /name:\s*Cookiecutter Bootstrap/);
  assert.match(workflow, /runner:\s*ubuntu-latest/);
  assert.match(workflow, /runner:\s*windows-latest/);
  assert.match(workflow, /docs\/documentation-manifest\.json/);
  assert.match(workflow, /docs\/schemas\/template-\*\.json/);
  assert.match(workflow, /uses:\s*actions\/setup-node@v6/);
  assert.match(workflow, /node-version:\s*24/);
  assert.match(workflow, /run:\s*npm ci/);
  assert.match(workflow, /uses:\s*actions\/setup-python@v6/);
  assert.match(workflow, /python-version:\s*'3\.12'/);
  assert.match(workflow, /Resolve pinned template dependency policy/);
  assert.match(workflow, /Build local tools image for cookiecutter conveyor/);
  assert.match(workflow, /docker build -f tools\/docker\/Dockerfile\.tools -t comparevi-tools:cookiecutter \./);
  assert.match(workflow, /Render pinned template dependency in the tools container/);
  assert.match(workflow, /Verify pinned template dependency on Windows/);
  assert.match(workflow, /priority:template:render:container/);
  assert.match(workflow, /tools\/docker\/Dockerfile\.tools/);
  assert.match(workflow, /--container-image comparevi-tools:cookiecutter/);
  assert.match(workflow, /template-cookiecutter-container\.json/);
  assert.match(workflow, /hostProjectDir \|\| receipt\.result\.projectDir/);
  assert.match(workflow, /templateRepositorySlug/);
  assert.match(workflow, /tools\/policy\/template-dependency\.json/);
  assert.match(workflow, /tools\/policy\/template-\*\.json/);
  assert.match(workflow, /tools\/priority\/template-\*\.mjs/);
  assert.match(workflow, /tools\/priority\/__tests__\/template-\*\.test\.mjs/);
  assert.match(workflow, /tools\/priority\/__tests__\/template-\*-schema\.test\.mjs/);
  assert.match(workflow, /container_image/);
  assert.match(workflow, /cookiecutter_version/);
  assert.match(workflow, /default_context_path/);
  assert.match(workflow, /pinned-template-dependency\.json/);
  assert.match(workflow, /container-workspaces/);
  assert.match(workflow, /Test-CompareVICookiecutterBootstrap\.ps1/);
  assert.match(workflow, /cookiecutter-bootstrap-\$\{\{\s*matrix\.proof_id\s*\}\}/);
  assert.match(workflow, /tests\/results\/_agent\/cookiecutter-bootstrap\/\$\{\{\s*matrix\.proof_id\s*\}\}/);
  assert.match(workflow, /tests\/results\/_agent\/cookiecutter-scaffolds\/bootstrap-proof\/\$\{\{\s*matrix\.proof_id\s*\}\}/);
  assert.match(workflow, /Template Agent Verification \/ template-agent-verification/);
  assert.match(workflow, /priority:template:agent:verify/);
  assert.match(workflow, /template-agent-verification-report\.json/);
  assert.match(workflow, /name:\s*cookiecutter-bootstrap-linux[\s\S]*path:\s*tests\/results\/_agent/);
  assert.match(workflow, /name:\s*cookiecutter-bootstrap-windows[\s\S]*path:\s*tests\/results\/_agent/);
  assert.match(workflow, /receipt\.run\.runToken/);
  assert.match(workflow, /container-workspaces/);
});

test('package and runbook surfaces advertise the cookiecutter bootstrap proof', () => {
  const packageJson = JSON.parse(read('package.json'));
  assert.equal(
    packageJson.scripts['priority:scaffold:cookiecutter:proof'],
    'pwsh -NoLogo -NoProfile -File tools/Test-CompareVICookiecutterBootstrap.ps1'
  );

  const runbook = read('docs/knowledgebase/Cookiecutter-Certification-Scaffolds.md');
  assert.match(runbook, /priority:scaffold:cookiecutter:proof/);
  assert.match(runbook, /cookiecutter-bootstrap\.yml/);
  assert.match(runbook, /actions\/setup-python@v6/);
  assert.match(runbook, /windows-latest/);
  assert.match(runbook, /ubuntu-latest/);
  assert.match(runbook, /LabVIEW-Community-CI-CD\/LabviewGitHubCiTemplate@v0\.1\.0/);
  assert.match(runbook, /cookiecutter==2\.7\.1/);
  assert.match(runbook, /ghcr\.io\/labview-community-ci-cd\/comparevi-tools:latest/);
  assert.match(runbook, /priority:template:render:container/);
  assert.match(runbook, /template-agent-verification-report\.json/);
});

test('documentation manifest tracks the pinned template conveyor', () => {
  const manifest = JSON.parse(read('docs/documentation-manifest.json'));
  const scaffoldContracts = manifest.entries.find((entry) => entry.name === 'Cookiecutter Scaffold Contracts');
  const templateVerificationContracts = manifest.entries.find((entry) => entry.name === 'Template Agent Verification Contracts');

  assert.ok(scaffoldContracts);
  assert.ok(templateVerificationContracts);
  assert.match(scaffoldContracts.description, /LabviewGitHubCiTemplate@v0\.1\.0/);
  assert.match(scaffoldContracts.description, /hosted container-backed render conveyor/);
  assert.match(templateVerificationContracts.description, /LabviewGitHubCiTemplate@v0\.1\.0/);
  assert.match(templateVerificationContracts.description, /hosted container-backed verification plane/);
  assert.ok(scaffoldContracts.files.includes('tests/fixtures/cookiecutter/template-context.json'));
  assert.ok(templateVerificationContracts.files.includes('tools/policy/template-dependency.json'));
});

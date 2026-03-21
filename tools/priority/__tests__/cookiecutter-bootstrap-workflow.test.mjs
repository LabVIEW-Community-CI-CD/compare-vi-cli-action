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
  assert.match(workflow, /uses:\s*actions\/setup-node@v6/);
  assert.match(workflow, /node-version:\s*24/);
  assert.match(workflow, /run:\s*npm ci/);
  assert.match(workflow, /uses:\s*actions\/setup-python@v6/);
  assert.match(workflow, /python-version:\s*'3\.12'/);
  assert.match(workflow, /Test-CompareVICookiecutterBootstrap\.ps1/);
  assert.match(workflow, /cookiecutter-bootstrap-\$\{\{\s*matrix\.proof_id\s*\}\}/);
  assert.match(workflow, /tests\/results\/_agent\/cookiecutter-bootstrap\/\$\{\{\s*matrix\.proof_id\s*\}\}/);
  assert.match(workflow, /tests\/results\/_agent\/cookiecutter-scaffolds\/bootstrap-proof\/\$\{\{\s*matrix\.proof_id\s*\}\}/);
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
});

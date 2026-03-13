#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('Validate standard path is not blocked by a validation environment approval gate', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  assert.doesNotMatch(workflow, /^\s*environment:\s*\r?\n\s*name:\s*validation\b/ms);
  assert.doesNotMatch(workflow, /^\s*deployment-determinism:\s*$/m);
  assert.doesNotMatch(workflow, /priority:deployment:assert/);
});

test('Validate uses explicit PR-head checkout expressions and routes workflow drift through the enclave', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /uses: actions\/checkout@v5/);
  assert.match(
    workflow,
    /repository:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name \|\| github\.repository\s*\}\}/
  );
  assert.match(
    workflow,
    /ref:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| github\.sha\s*\}\}/
  );
  assert.doesNotMatch(workflow, /checkout-workflow-context/);
  assert.match(workflow, /Setup Python for workflow enclave/);
  assert.match(workflow, /pwsh -NoLogo -NoProfile -File tools\/Check-WorkflowDrift\.ps1 -FailOnDrift/);
  assert.match(workflow, /node tools\/npm\/run-script\.mjs lint:md:changed/);
  assert.doesNotMatch(workflow, /update_workflows\.py/);
  assert.doesNotMatch(workflow, /pip install[^\n]*ruamel/i);
  assert.doesNotMatch(workflow, /Install markdownlint-cli \(retry\)/);
  assert.doesNotMatch(workflow, /Run markdownlint \(non-blocking\)/);
});

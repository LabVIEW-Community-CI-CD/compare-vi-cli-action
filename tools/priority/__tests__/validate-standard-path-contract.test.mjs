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

test('Validate resolves checkout through the workflow context helper on PR-capable lanes', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /uses: \.\/\.github\/actions\/checkout-workflow-context/);
  assert.match(workflow, /mode: 'pr-head'/);
  assert.doesNotMatch(workflow, /actions\/checkout@v5/);
});

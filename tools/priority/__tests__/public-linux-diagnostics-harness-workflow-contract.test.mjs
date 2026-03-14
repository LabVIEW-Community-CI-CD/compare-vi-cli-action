#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('public Linux diagnostics harness workflow is workflow_dispatch-only and exposes the shared contract inputs', () => {
  const workflow = readRepoFile('.github/workflows/public-linux-diagnostics-harness.yml');

  assert.match(workflow, /^on:\s*\r?\n\s+workflow_dispatch:/m);
  assert.doesNotMatch(workflow, /^\s*pull_request:/m);
  assert.match(workflow, /repository:\s+\s*description:[\s\S]+required: true[\s\S]+type: string/m);
  assert.match(workflow, /reference:\s+\s*description:[\s\S]+required: true[\s\S]+type: string/m);
  assert.match(workflow, /develop_relationship:[\s\S]+type: choice[\s\S]+options:\s+\s+- equal\s+\s+- ahead/m);
});

test('public Linux diagnostics harness workflow writes and uploads deterministic dispatch artifacts', () => {
  const workflow = readRepoFile('.github/workflows/public-linux-diagnostics-harness.yml');

  assert.match(workflow, /tools\/priority\/public-linux-diagnostics-workflow-dispatch\.mjs/);
  assert.match(workflow, /tests\/results\/_agent\/diagnostics\/public-linux-diagnostics-workflow-dispatch\.json/);
  assert.match(workflow, /name: Upload public Linux diagnostics dispatch artifact\s+if: always\(\)\s+uses: actions\/upload-artifact@v6/ms);
  assert.match(workflow, /name: public-linux-diagnostics-harness-dispatch/);
  assert.match(workflow, /human-go-no-go-feedback\.yml/);
});

test('public Linux diagnostics harness workflow keeps permissions minimal', () => {
  const workflow = readRepoFile('.github/workflows/public-linux-diagnostics-harness.yml');

  assert.match(workflow, /permissions:\s+contents: read/ms);
  assert.doesNotMatch(workflow, /permissions:\s+write-all/);
  assert.doesNotMatch(workflow, /deployments:\s+write/);
  assert.doesNotMatch(workflow, /pull-requests:\s+write/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('pester service-model quality workflow publishes coverage evidence and docs link integrity', () => {
  const workflow = readRepoFile('.github/workflows/pester-service-model-quality.yml');

  assert.match(workflow, /name:\s+Pester service-model quality/);
  assert.match(workflow, /pull_request:/);
  assert.match(workflow, /integration\/\*\*/);
  assert.match(workflow, /name:\s+PR Coverage Gate \/ coverage/);
  assert.match(workflow, /node --test --experimental-test-coverage/);
  assert.match(workflow, /write-node-test-coverage-xml\.mjs/);
  assert.match(workflow, /coverage\.xml/);
  assert.match(workflow, /upload-artifact@v7/);
  assert.match(workflow, /name:\s+Docs link check \/ lychee/);
  assert.match(workflow, /lycheeverse\/lychee-action@v2/);
});

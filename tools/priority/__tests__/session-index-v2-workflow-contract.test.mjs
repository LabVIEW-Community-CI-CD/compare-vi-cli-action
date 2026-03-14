#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('validate uploads both session-index-v2 contract and disposition summary artifacts', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /name:\s+Upload v2 contract report/);
  assert.match(
    workflow,
    /name:\s+validate-session-index-v2-contract\r?\n\s+path:\s*\|\r?\n\s+\$\{\{\s*runner\.temp\s*\}\}\/sessionindex-v2-contract\/session-index-v2-contract\.json\r?\n\s+\$\{\{\s*runner\.temp\s*\}\}\/sessionindex-v2-contract\/session-index-v2-disposition\.json/ms
  );
});

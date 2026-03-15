#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('Validate uploads the contract, disposition, and cutover readiness artifacts together', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(
    workflow,
    /name: Upload v2 contract report\s+if: always\(\)\s+uses: actions\/upload-artifact@v6\s+with:\s+name: validate-session-index-v2-contract\s+path: \|\s+\$\{\{ runner\.temp \}\}\/sessionindex-v2-contract\/session-index-v2-contract\.json\s+\$\{\{ runner\.temp \}\}\/sessionindex-v2-contract\/session-index-v2-disposition\.json\s+\$\{\{ runner\.temp \}\}\/sessionindex-v2-contract\/session-index-v2-cutover-readiness\.json/ms
  );
});

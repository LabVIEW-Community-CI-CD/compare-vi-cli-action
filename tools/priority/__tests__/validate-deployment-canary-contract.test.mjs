#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('Validate deployment-determinism lane emits normalized deployment-state incident event artifact', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  assert.match(workflow, /name:\s+Normalize deployment determinism canary event/);
  assert.ok(workflow.includes('priority:event:ingest -- \\'));
  assert.match(workflow, /--source-type deployment-state/);
  assert.match(workflow, /--input \"\$report_path\"/);
  assert.match(workflow, /tests\/results\/_agent\/canary\/validation-deployment-incident-event\.json/);
});

test('Validate deployment-determinism lane uploads canary event artifact', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  assert.match(workflow, /name:\s+Upload deployment determinism canary event report/);
  assert.match(workflow, /name:\s+validate-deployment-determinism-event/);
  assert.match(workflow, /if-no-files-found:\s+warn/);
});

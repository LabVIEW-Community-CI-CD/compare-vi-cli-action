#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('validation approval helper workflow is workflow_dispatch-only and pinned to validation', () => {
  const workflow = readRepoFile('.github/workflows/validation-approval-helper.yml');

  assert.match(workflow, /^on:\s*\r?\n\s+workflow_dispatch:/m);
  assert.doesNotMatch(workflow, /^\s*pull_request:/m);
  assert.doesNotMatch(workflow, /^\s*pull_request_target:/m);
  assert.match(workflow, /--environment" "validation"/);
  assert.doesNotMatch(workflow, /--environment" "production"/);
  assert.doesNotMatch(workflow, /--environment" "monthly-stability-release"/);
  assert.doesNotMatch(workflow, /--environment" "publish"/);
});

test('validation approval helper workflow downloads source artifacts and uploads the decision artifacts', () => {
  const workflow = readRepoFile('.github/workflows/validation-approval-helper.yml');

  assert.match(workflow, /name: Download existing broker decision artifact\s+if: inputs\.broker_mode == 'consume'\s+uses: actions\/download-artifact@v5/);
  assert.match(workflow, /name: Download validation attestation artifact\s+if: inputs\.broker_mode == 'evaluate'\s+uses: actions\/download-artifact@v5/);
  assert.match(workflow, /name: Download validation deployment determinism artifact\s+if: inputs\.broker_mode == 'evaluate'\s+uses: actions\/download-artifact@v5/);
  assert.match(workflow, /run-id: \$\{\{ inputs\.artifact_run_id \|\| inputs\.run_id \}\}/);
  assert.match(workflow, /name: Upload validation approval artifacts\s+if: always\(\)\s+uses: actions\/upload-artifact@v5/);
  assert.match(workflow, /validation-approval-decision\.json/);
  assert.match(workflow, /validation-approval-helper\.json/);
});

test('validation approval helper workflow limits token permissions to the approval surface', () => {
  const workflow = readRepoFile('.github/workflows/validation-approval-helper.yml');

  assert.match(workflow, /permissions:\s+contents: read\s+actions: read\s+deployments: write\s+pull-requests: read/ms);
  assert.doesNotMatch(workflow, /permissions:\s+write-all/);
});

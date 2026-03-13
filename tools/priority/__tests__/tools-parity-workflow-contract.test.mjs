#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('tools parity workflow can dispatch the NI Linux review suite and upload its evidence', () => {
  const workflow = readRepoFile('.github/workflows/tools-parity.yml');
  assert.match(workflow, /uses: actions\/checkout@v4[\s\S]*fetch-depth:\s*0/);
  assert.match(workflow, /runNiLinuxReviewSuite:/);
  assert.match(workflow, /runRequirementsVerification:/);
  assert.match(workflow, /historyTargetPath:/);
  assert.match(workflow, /historyBranchRef:/);
  assert.match(workflow, /historyBaselineRef:/);
  assert.match(workflow, /historyMaxCommitCount:/);
  assert.match(workflow, /-NILinuxReviewSuite/);
  assert.match(workflow, /-RequirementsVerification/);
  assert.match(workflow, /-NILinuxReviewSuiteHistoryTargetPath/);
  assert.match(workflow, /-NILinuxReviewSuiteHistoryBranchRef/);
  assert.match(workflow, /-NILinuxReviewSuiteHistoryBaselineRef/);
  assert.match(workflow, /-NILinuxReviewSuiteHistoryMaxCommitCount/);
  assert.match(workflow, /docker-parity-linux-ni-review-suite/);
  assert.match(workflow, /docker-parity-linux-requirements-verification/);
  assert.match(workflow, /tests\/results\/docker-tools-parity\/ni-linux-review-suite/);
  assert.match(workflow, /tests\/results\/docker-tools-parity\/requirements-verification/);
});

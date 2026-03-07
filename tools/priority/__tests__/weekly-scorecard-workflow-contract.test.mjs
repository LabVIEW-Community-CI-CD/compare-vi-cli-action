#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('weekly scorecard workflow schedules weekly execution', () => {
  const workflow = readRepoFile('.github/workflows/weekly-scorecard.yml');
  assert.match(workflow, /name:\s+Weekly Governance Scorecard/);
  assert.match(workflow, /schedule:\s*\n\s*-\s*cron:\s*'20 18 \* \* 3'/);
});

test('weekly scorecard workflow runs canary, remediation, and weekly scorecard contracts', () => {
  const workflow = readRepoFile('.github/workflows/weekly-scorecard.yml');
  assert.match(workflow, /priority:canary:replay/);
  assert.match(workflow, /priority:remediation:slo/);
  assert.match(workflow, /priority:weekly:scorecard/);
  assert.match(workflow, /--route-on-persistent-breach/);
  assert.match(workflow, /tests\/results\/_agent\/slo\/weekly-scorecard\.json/);
  assert.match(workflow, /tests\/results\/_agent\/canary\/canary-replay-conformance-report\.json/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('validate workflow centralizes VI-history dispatch planning before Linux and Windows lanes', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /vi-history-scenarios-plan:/);
  assert.match(workflow, /Resolve VI history dispatch plan/);
  assert.match(workflow, /tools\/Resolve-ValidateVIHistoryDispatchPlan\.ps1/);
  assert.match(workflow, /-EnableScopedExecution:\$enableScopedExecution/);
  assert.match(workflow, /-ScopedSkipReason \$env:VALIDATE_SCOPE_VI_HISTORY_REASON/);
  assert.match(workflow, /execute_lanes:\s+\$\{\{\s*steps\.plan\.outputs\.execute_lanes\s*\}\}/);
  assert.match(workflow, /history_scenario_set:\s+\$\{\{\s*steps\.plan\.outputs\.history_scenario_set\s*\}\}/);
});

test('validate workflow Linux and Windows VI-history lanes consume the shared dispatch-plan outputs', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /vi-history-scenarios-linux:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, session-index, session-index-v2-contract, vi-history-scenarios-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'/);
  assert.match(workflow, /Append VI history Linux lane plan/);
  assert.match(workflow, /needs\.vi-history-scenarios-plan\.outputs\.execute_lanes == 'true'/);
  assert.match(workflow, /needs\.vi-history-scenarios-plan\.outputs\.history_scenario_set/);
  assert.doesNotMatch(workflow, /Resolve VI history Linux lane execution mode/);
  assert.doesNotMatch(workflow, /vi-history-scenarios-skip-note:/);
});

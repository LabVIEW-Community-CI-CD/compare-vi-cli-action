#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function extractWorkflowJobSection(workflow, jobName, nextJobName = null) {
  const escapedJobName = jobName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const boundary = nextJobName
    ? `\\r?\\n\\s{2}${nextJobName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:`
    : '$';
  const pattern = new RegExp(`${escapedJobName}:\\s*\\r?\\n([\\s\\S]*?)${boundary}`);
  const match = workflow.match(pattern);
  assert.ok(match, `Expected to locate workflow section for ${jobName}`);
  return match[1];
}

test('validate workflow centralizes VI-history dispatch planning before Linux lane execution', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const planSection = extractWorkflowJobSection(workflow, 'vi-history-scenarios-plan', 'vi-history-scenarios-linux');

  assert.match(workflow, /vi-history-scenarios-plan:/);
  assert.match(workflow, /Resolve VI history dispatch plan/);
  assert.match(workflow, /tools\/Resolve-ValidateVIHistoryDispatchPlan\.ps1/);
  assert.match(workflow, /-EnableScopedExecution:\$enableScopedExecution/);
  assert.match(workflow, /-ScopedSkipReason \$env:VALIDATE_SCOPE_VI_HISTORY_REASON/);
  assert.match(workflow, /execute_lanes:\s+\$\{\{\s*steps\.plan\.outputs\.execute_lanes\s*\}\}/);
  assert.match(workflow, /history_scenario_set:\s+\$\{\{\s*steps\.plan\.outputs\.history_scenario_set\s*\}\}/);
  assert.match(planSection, /permissions:\s*\r?\n\s+contents: read/);
  assert.doesNotMatch(planSection, /pull-requests: read/);
  assert.doesNotMatch(planSection, /uses: actions\/checkout@v5\s*\r?\n\s+with:\s*\r?\n\s+fetch-depth: 0/);
});

test('validate workflow Linux VI-history lane consumes shared dispatch-plan outputs', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const linuxSection = extractWorkflowJobSection(workflow, 'vi-history-scenarios-linux');

  assert.match(workflow, /vi-history-scenarios-linux:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, session-index, session-index-v2-contract, vi-history-scenarios-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'/);
  assert.match(workflow, /Append VI history Linux lane plan/);
  assert.match(workflow, /needs\.vi-history-scenarios-plan\.outputs\.execute_lanes == 'true'/);
  assert.match(workflow, /needs\.vi-history-scenarios-plan\.outputs\.history_scenario_set/);
  assert.doesNotMatch(workflow, /Resolve VI history Linux lane execution mode/);
  assert.doesNotMatch(workflow, /vi-history-scenarios-skip-note:/);
  assert.match(linuxSection, /permissions:\s*\r?\n\s+contents: read/);
  assert.doesNotMatch(linuxSection, /pull-requests: read/);
});

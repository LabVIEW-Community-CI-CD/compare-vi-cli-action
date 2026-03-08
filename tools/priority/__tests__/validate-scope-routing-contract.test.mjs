#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('validate workflow resolves change scope before heavy fan-out and publishes a routing artifact', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /validate-scope-plan:/);
  assert.match(workflow, /Resolve Validate scope plan/);
  assert.match(workflow, /tools\/Resolve-ValidateScopePlan\.ps1/);
  assert.match(workflow, /name:\s+validate-scope-plan/);
  assert.match(workflow, /run_fixtures:\s+\$\{\{\s*steps\.plan\.outputs\.run_fixtures\s*\}\}/);
  assert.match(workflow, /run_bundle_certification:\s+\$\{\{\s*steps\.plan\.outputs\.run_bundle_certification\s*\}\}/);
  assert.match(workflow, /run_vi_history:\s+\$\{\{\s*steps\.plan\.outputs\.run_vi_history\s*\}\}/);
});

test('validate heavy jobs consume scoped lane decisions without skipping required checks', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /validate-scope-plan:\s*\r?\n\s+needs:\s+smoke-gate\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'\r?\n\s+runs-on:\s+ubuntu-latest\r?\n\s+permissions:\s*\r?\n\s+contents:\s+read\r?\n\s+pull-requests:\s+read/ms);
  assert.match(workflow, /fixtures:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, validate-scope-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'/);
  assert.match(workflow, /fixtures:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, validate-scope-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'\r?\n\s+runs-on:\s+\[self-hosted, Windows, X64\]\r?\n\s+permissions:\s*\r?\n\s+contents:\s+read/ms);
  assert.match(workflow, /VALIDATE_SCOPE_RUN_FIXTURES:\s+\$\{\{\s*needs\.validate-scope-plan\.outputs\.run_fixtures\s*\}\}/);
  assert.match(workflow, /Append fixture lane plan/);
  assert.match(workflow, /if:\s+env\.VALIDATE_SCOPE_RUN_FIXTURES == 'true'/);
  assert.match(workflow, /comparevi-history-bundle-certification:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, validate-scope-plan, session-index, session-index-v2-contract\]/);
  assert.match(workflow, /needs\.validate-scope-plan\.outputs\.run_bundle_certification == 'true'/);
  assert.match(workflow, /VALIDATE_SCOPE_RUN_VI_HISTORY:\s+\$\{\{\s*needs\.validate-scope-plan\.outputs\.run_vi_history\s*\}\}/);
  assert.match(workflow, /VALIDATE_SCOPE_VI_HISTORY_REASON:\s+\$\{\{\s*needs\.validate-scope-plan\.outputs\.vi_history_reason\s*\}\}/);
});

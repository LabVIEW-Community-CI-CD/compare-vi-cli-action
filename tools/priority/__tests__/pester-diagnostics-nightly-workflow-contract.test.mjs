#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('pester diagnostics nightly keeps synthetic-failure diagnostics in notice-only mode', () => {
  const workflow = readRepoFile('.github/workflows/pester-diagnostics-nightly.yml');

  assert.match(workflow, /name:\s+Pester diagnostics nightly/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /sample_id:/);
  assert.match(workflow, /jobs:\s*\n\s*diagnostics:\s*\n\s*uses:\s+\.\s*\/\.github\/workflows\/pester-reusable\.yml/);
  assert.match(workflow, /diagnostic_fail:\s+\$\{\{\s*'true'\s*\}\}/);
  assert.match(workflow, /continue_on_error:\s+\$\{\{\s*'true'\s*\}\}/);
  assert.match(workflow, /verify:\s*\n\s*needs:\s+diagnostics\s*\n\s*if:\s+always\(\)/);
  assert.match(workflow, /Download Pester artifacts/);
  assert.match(workflow, /continue-on-error:\s+true/);
  assert.match(workflow, /Verify failure JSON emitted \(notice-only\)/);
  assert.match(workflow, /Nightly Diagnostics \(Synthetic Failure\)/);
});

test('pester reusable honors continue_on_error at the job boundary', () => {
  const workflow = readRepoFile('.github/workflows/pester-reusable.yml');

  assert.match(workflow, /continue_on_error:/);
  assert.match(workflow, /concurrency:\s*\n\s*group:\s+\$\{\{\s*github\.workflow\s*\}\}-pester-reusable-\$\{\{\s*github\.repository\s*\}\}-\$\{\{\s*inputs\.sample_id \|\| github\.ref\s*\}\}/);
  assert.match(workflow, /-\s+name:\s+Run Pester tests via local dispatcher\s*\n\s+id:\s+dispatcher\s*\n\s+continue-on-error:\s+true/);
  assert.match(workflow, /"exit_code=\$exitCode"/);
  assert.match(workflow, /\$global:LASTEXITCODE = 0/);
  assert.match(workflow, /Propagate dispatcher failure/);
  assert.match(workflow, /steps\.dispatcher\.outcome == 'failure'/);
  assert.match(workflow, /inputs\.continue_on_error != 'true'/);
});

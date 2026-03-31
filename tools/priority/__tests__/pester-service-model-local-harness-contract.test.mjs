#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('package.json exposes the local execution harness as a first-class entrypoint', () => {
  const packageJson = JSON.parse(readRepoFile('package.json'));
  assert.equal(
    packageJson.scripts['tests:execution:local'],
    'pwsh -NoLogo -NoProfile -File tools/Run-PesterExecutionOnly.Local.ps1'
  );
});

test('local execution harness owns lock lifecycle, preflight, dispatch, and receipt generation', () => {
  const harness = readRepoFile('tools/Run-PesterExecutionOnly.Local.ps1');

  assert.match(harness, /\[string\]\$SessionLockRoot/);
  assert.match(harness, /\$resolvedSessionLockRoot = if \(\[string\]::IsNullOrWhiteSpace\(\$SessionLockRoot\)\)/);
  assert.match(harness, /-Action Acquire -Group \$SessionLockGroup -LockRoot \$resolvedSessionLockRoot/);
  assert.match(harness, /-Action Release/);
  assert.match(harness, /SESSION_LOCK_ROOT = \$resolvedSessionLockRoot/);
  assert.match(harness, /Invoke-RunnerUnblockGuardLocal/);
  assert.match(harness, /Invoke-PrepareFixturesLocal/);
  assert.match(harness, /Get-Command dotnet/);
  assert.match(harness, /Resolve-LVComparePath/);
  assert.match(harness, /Invoke-PesterTests\.ps1/);
  assert.match(harness, /Invoke-PesterExecutionPostprocess\.ps1/);
  assert.match(harness, /pester-execution-receipt@v1/);
  assert.match(harness, /pester-execution-contract/);
  assert.match(harness, /source = 'local-harness'/);
  assert.match(harness, /results-xml-truncated/);
  assert.match(harness, /summaryPresent/);
  assert.match(harness, /sessionLockRoot = ConvertTo-PortablePath \$resolvedSessionLockRoot/);
});

test('knowledgebase documents the local harness as the workflow-shell-free execution entrypoint', () => {
  const doc = readRepoFile('docs/knowledgebase/Pester-Service-Model.md');

  assert.match(doc, /Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(doc, /without the workflow shell/i);
  assert.match(doc, /lock,\s+LV guard,\s+fixture prep,\s+dispatcher profile,\s+dispatch,\s+execution postprocess,\s+and local execution receipt/i);
});

test('execution-layer assurance packet traces the local harness in the SRS, RTM, and test plan', () => {
  const srs = readRepoFile('docs/requirements-pester-service-model-srs.md');
  const rtm = readRepoFile('docs/rtm-pester-service-model.csv');
  const plan = readRepoFile('docs/testing/pester-service-model-test-plan.md');

  assert.match(srs, /Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(srs, /mirrors that slice locally without the workflow shell/i);
  assert.match(rtm, /tools\/Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(rtm, /pester-service-model-local-harness-contract\.test\.mjs/);
  assert.match(plan, /Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(plan, /Local harness contract tests pass/i);
});

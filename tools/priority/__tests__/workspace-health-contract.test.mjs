#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('bootstrap enforces workspace health gate before and after lease acquisition', () => {
  const content = readRepoFile('tools/priority/bootstrap.ps1');
  assert.match(content, /Invoke-WorkspaceHealthGate -LeaseMode 'optional' -ReportName 'bootstrap-preflight-workspace-health\.json'/);
  assert.match(content, /Invoke-WorkspaceHealthGate -LeaseMode 'required' -ReportName 'bootstrap-postlease-workspace-health\.json'/);
});

test('PrePush-Checks invokes workspace health gate in optional lease mode', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /check-workspace-health\.mjs/);
  assert.match(content, /--lease-mode optional/);
  assert.match(content, /pre-push-workspace-health\.json/);
});

test('PrePush NI image known-flag scenario uses direct script invocation and explicit LabVIEWPath', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /& \$niCompareScript/);
  assert.match(content, /-LabVIEWPath \$containerLabVIEWPath/);
  assert.match(content, /\$knownFlags = @\('-noattr', '-nofppos', '-nobdcosm'\)/);
  assert.doesNotMatch(content, /pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+\$niCompareScript/);
});

test('policy workflows enforce workspace health gate and publish health artifacts', () => {
  const guardWorkflow = readRepoFile('.github/workflows/policy-guard-upstream.yml');
  assert.match(guardWorkflow, /Workspace health gate/);
  assert.match(guardWorkflow, /check-workspace-health\.mjs --repo-root \. --lease-mode ignore --report tests\/results\/_agent\/health\/policy-guard-workspace-health\.json/);
  assert.match(guardWorkflow, /tests\/results\/_agent\/health\/policy-guard-workspace-health\.json/);

  const syncWorkflow = readRepoFile('.github/workflows/policy-sync.yml');
  assert.match(syncWorkflow, /Workspace health gate/);
  assert.match(syncWorkflow, /check-workspace-health\.mjs --repo-root \. --lease-mode ignore --report tests\/results\/_agent\/health\/policy-sync-workspace-health\.json/);
  assert.match(syncWorkflow, /tests\/results\/_agent\/health\/policy-sync-workspace-health\.json/);
});

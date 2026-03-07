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

test('PrePush includes local PSScriptAnalyzer gate for changed PowerShell files', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /function Invoke-PSScriptAnalyzerGate/);
  assert.match(content, /Get-ChangedPowerShellPaths/);
  assert.match(content, /Invoke-ScriptAnalyzer -Path \$path -Severity Error,Warning/);
  assert.match(content, /Invoke-PSScriptAnalyzerGate -repoRoot \$root/);
});

test('PrePush validates watcher telemetry via the sanitized schema wrapper', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /function Invoke-WatcherTelemetrySchemaGate/);
  assert.match(content, /run-script\.mjs/);
  assert.match(content, /schema:watcher:validate/);
  assert.match(content, /Invoke-WatcherTelemetrySchemaGate -repoRoot \$root/);
});

test('PrePush emits deterministic incident-event report for NI known-flag failures', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /function Write-PrePushNIKnownFlagIncidentEvent/);
  assert.match(content, /--source-type incident-event/);
  assert.match(content, /pre-push-ni-known-flag-incident-input\.json/);
  assert.match(content, /pre-push-ni-known-flag-incident-event\.json/);
  assert.match(content, /\[pre-push\] NI known-flag incident event report:/);
});

test('policy workflows enforce workspace health gate and publish health artifacts', () => {
  const guardWorkflow = readRepoFile('.github/workflows/policy-guard-upstream.yml');
  assert.match(guardWorkflow, /Workspace health gate/);
  assert.match(guardWorkflow, /check-workspace-health\.mjs --repo-root \. --lease-mode ignore --report tests\/results\/_agent\/health\/policy-guard-workspace-health\.json/);
  assert.match(guardWorkflow, /Verify deployment environment gate policy/);
  assert.match(guardWorkflow, /priority:deployment:gate-policy/);
  assert.match(guardWorkflow, /tests\/results\/_agent\/deployments\/environment-gate-policy\.json/);
  assert.match(guardWorkflow, /tests\/results\/_agent\/health\/policy-guard-workspace-health\.json/);

  const syncWorkflow = readRepoFile('.github/workflows/policy-sync.yml');
  assert.match(syncWorkflow, /Workspace health gate/);
  assert.match(syncWorkflow, /check-workspace-health\.mjs --repo-root \. --lease-mode ignore --report tests\/results\/_agent\/health\/policy-sync-workspace-health\.json/);
  assert.match(syncWorkflow, /tests\/results\/_agent\/health\/policy-sync-workspace-health\.json/);
});

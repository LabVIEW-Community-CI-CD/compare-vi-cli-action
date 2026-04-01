#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('package.json exposes explicit Windows shared-surface entrypoints', () => {
  const packageJson = JSON.parse(readRepoFile('package.json'));

  assert.equal(
    packageJson.scripts['priority:windows-surface:local-ci'],
    'node tools/priority/windows-docker-shared-surface-local-ci.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:windows-surface:next-step'],
    'node tools/priority/windows-docker-shared-surface-local-ci.mjs --print-next-step'
  );
  assert.equal(
    packageJson.scripts['tests:windows-surface:probe'],
    'pwsh -NoLogo -NoProfile -File tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1'
  );
});

test('Windows shared-surface packet traces requirements, tests, and shared-program integration', () => {
  const srs = readRepoFile('docs/requirements-windows-docker-shared-surface-srs.md');
  const rtm = readRepoFile('docs/rtm-windows-docker-shared-surface.csv');
  const plan = readRepoFile('docs/testing/windows-docker-shared-surface-test-plan.md');
  const doc = readRepoFile('docs/knowledgebase/Windows-Docker-Shared-Surface.md');
  const arch = readRepoFile('docs/architecture/windows-docker-shared-surface-control-plane.md');
  const programDoc = readRepoFile('docs/knowledgebase/Local-Proof-Autonomy-Program.md');
  const localCi = readRepoFile('tools/priority/windows-docker-shared-surface-local-ci.mjs');

  assert.match(srs, /REQ-WDSS-001/);
  assert.match(srs, /Docker Desktop Windows engine/i);
  assert.match(srs, /REQ-WDSS-003/);
  assert.match(srs, /OneDrive-managed paths/i);
  assert.match(srs, /REQ-WDSS-006/);
  assert.match(srs, /shared local proof program selector/i);
  assert.match(srs, /REQ-WDSS-007/);
  assert.match(srs, /reachable Windows host bridge/i);
  assert.match(srs, /REQ-WDSS-008/);
  assert.match(srs, /UNC-backed WSL/i);
  assert.match(srs, /Windows-local mount root/i);
  assert.match(srs, /REQ-WDSS-009/);
  assert.match(srs, /blocking execution truth/i);
  assert.match(srs, /pester-reusable\.yml/);

  assert.match(rtm, /REQ-WDSS-003/);
  assert.match(rtm, /TEST-WDSS-003/);
  assert.match(rtm, /REQ-WDSS-006/);
  assert.match(rtm, /TEST-WDSS-006/);
  assert.match(rtm, /REQ-WDSS-007/);
  assert.match(rtm, /TEST-WDSS-007/);
  assert.match(rtm, /REQ-WDSS-008/);
  assert.match(rtm, /TEST-WDSS-008/);
  assert.match(rtm, /REQ-WDSS-009/);
  assert.match(rtm, /TEST-WDSS-009/);

  assert.match(plan, /TEST-WDSS-001/);
  assert.match(plan, /TEST-WDSS-002/);
  assert.match(plan, /TEST-WDSS-003/);
  assert.match(plan, /TEST-WDSS-006/);
  assert.match(plan, /OneDrive-like managed roots/i);
  assert.match(plan, /TEST-WDSS-007/);
  assert.match(plan, /reachable Windows host bridge/i);
  assert.match(plan, /TEST-WDSS-008/);
  assert.match(plan, /UNC-backed WSL staging coverage/i);
  assert.match(plan, /TEST-WDSS-009/);
  assert.match(plan, /authoritative CI gate coverage/i);

  assert.match(doc, /priority:windows-surface:local-ci/);
  assert.match(doc, /tests:windows-surface:probe/);
  assert.match(doc, /docker:ni:windows:bootstrap/);
  assert.match(doc, /OneDrive-like managed roots/i);
  assert.match(doc, /reachable Windows host bridge/i);
  assert.match(doc, /ExecutionPolicy Bypass/i);
  assert.match(doc, /stage container-bound inputs and output targets/i);
  assert.match(doc, /ni-windows-container-capture\.json/);
  assert.match(doc, /authoritative[\s\S]*execution-truth plane/i);
  assert.match(doc, /windows-ni-proof-reusable\.yml/);
  assert.match(doc, /Test-VIBinaryHandlingInvariants\.ps1/);

  assert.match(arch, /Readiness probe surface/);
  assert.match(arch, /Path-hygiene surface/);
  assert.match(arch, /shared Windows surface should stay packetized separately/i);
  assert.match(arch, /Bridge surface/);
  assert.match(arch, /Windows-local staging surface/);
  assert.match(arch, /UNC-backed WSL repo paths should never be passed straight to Docker bind\s+mounts/i);
  assert.match(arch, /Hosted CI authority surface/);
  assert.match(arch, /windows-ni-proof-reusable\.yml/);

  assert.match(programDoc, /Windows Docker Shared Surface/i);

  assert.match(localCi, /REQ-WDSS-003/);
  assert.match(localCi, /local-safe-root/);
  assert.match(localCi, /windows-docker-desktop-ni-image/);
  assert.match(localCi, /Invoke-PesterWindowsContainerSurfaceProbe\.ps1/);
  assert.match(localCi, /Test-WindowsNI2026q1HostPreflight\.ps1/);
  assert.match(localCi, /windows-host-bridge-unavailable/);

  const compareScript = readRepoFile('tools/Run-NIWindowsContainerCompare.ps1');
  assert.match(compareScript, /Test-PathRequiresWindowsDockerLocalStage/);
  assert.match(compareScript, /outputSyncStatus/);
  assert.match(compareScript, /cleanupStatus/);

  const invariantsScript = readRepoFile('tools/Test-VIBinaryHandlingInvariants.ps1');
  assert.match(invariantsScript, /comparevi\/vi-binary-handling-invariants@v1/);
  assert.match(invariantsScript, /no-textual-vi-reads/);
});

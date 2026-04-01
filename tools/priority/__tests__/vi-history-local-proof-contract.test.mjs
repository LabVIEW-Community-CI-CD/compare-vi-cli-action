#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('package.json exposes explicit VI History local proof entrypoints', () => {
  const packageJson = JSON.parse(readRepoFile('package.json'));

  assert.equal(
    packageJson.scripts['priority:workflow:replay:windows:vi-history'],
    'node tools/priority/windows-workflow-replay-lane.mjs --mode vi-history-scenarios-windows'
  );
  assert.equal(
    packageJson.scripts['history:local:proof'],
    'pwsh -NoLogo -NoProfile -File tools/Invoke-VIHistoryLocalRefinement.ps1 -Profile proof'
  );
  assert.equal(
    packageJson.scripts['history:local:refine'],
    'pwsh -NoLogo -NoProfile -File tools/Invoke-VIHistoryLocalRefinement.ps1 -Profile dev-fast'
  );
  assert.equal(
    packageJson.scripts['history:local:operator:review'],
    'pwsh -NoLogo -NoProfile -File tools/Invoke-VIHistoryLocalOperatorSession.ps1 -Profile dev-fast'
  );
  assert.equal(
    packageJson.scripts['priority:vi-history:local-ci'],
    'node tools/priority/vi-history-local-ci.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:vi-history:next-step'],
    'node tools/priority/vi-history-local-ci.mjs --print-next-step'
  );
});

test('VI History local-proof packet traces requirements, tests, and shared Windows-surface escalation', () => {
  const srs = readRepoFile('docs/requirements-vi-history-local-proof-srs.md');
  const rtm = readRepoFile('docs/rtm-vi-history-local-proof.csv');
  const plan = readRepoFile('docs/testing/vi-history-local-proof-test-plan.md');
  const doc = readRepoFile('docs/knowledgebase/VI-History-Local-Proof.md');
  const arch = readRepoFile('docs/architecture/vi-history-local-proof-control-plane.md');
  const localCi = readRepoFile('tools/priority/vi-history-local-ci.mjs');

  assert.match(srs, /REQ-VHLP-001/);
  assert.match(srs, /windows workflow-replay lane/i);
  assert.match(srs, /REQ-VHLP-002/);
  assert.match(srs, /windows-mirror-proof/i);
  assert.match(srs, /REQ-VHLP-003/);
  assert.match(srs, /operator-session wrappers/i);
  assert.match(srs, /REQ-VHLP-004/);
  assert.match(srs, /workflow-readiness envelope/i);
  assert.match(srs, /REQ-VHLP-005/);
  assert.match(srs, /machine-readable report, ranked backlog, and next step/i);
  assert.match(srs, /REQ-VHLP-006/);
  assert.match(srs, /windows-docker-desktop-ni-image/i);
  assert.match(srs, /reachable Windows host bridge/i);
  assert.match(srs, /REQ-VHLP-007/);
  assert.match(srs, /shared local proof program selector/i);
  assert.match(srs, /REQ-VHLP-008/);
  assert.match(srs, /ni\/labview-icon-editor/i);
  assert.match(srs, /VIP_Pre-Uninstall Custom Action\.vi/);
  assert.match(srs, /REQ-VHLP-009/);
  assert.match(srs, /clone exists locally, contains the target VI, and exposes real git history/i);

  assert.match(rtm, /REQ-VHLP-006/);
  assert.match(rtm, /TEST-VHLP-006/);
  assert.match(rtm, /REQ-VHLP-007/);
  assert.match(rtm, /TEST-VHLP-007/);
  assert.match(rtm, /REQ-VHLP-008/);
  assert.match(rtm, /TEST-VHLP-008/);
  assert.match(rtm, /REQ-VHLP-009/);
  assert.match(rtm, /TEST-VHLP-009/);

  assert.match(plan, /TEST-VHLP-001/);
  assert.match(plan, /TEST-VHLP-006/);
  assert.match(plan, /TEST-VHLP-007/);
  assert.match(plan, /machine-readable escalation step/i);
  assert.match(plan, /reachable Windows host bridge/i);
  assert.match(plan, /TEST-VHLP-008/);
  assert.match(plan, /ni\/labview-icon-editor/i);
  assert.match(plan, /TEST-VHLP-009/);
  assert.match(plan, /clone presence, target path presence, and git history/i);

  assert.match(doc, /priority:workflow:replay:windows:vi-history/);
  assert.match(doc, /history:local:proof/);
  assert.match(doc, /vi-history-local-next-step\.json/);
  assert.match(doc, /comparevi-local-program-next-step\.json/);
  assert.match(doc, /shared `windows-docker-desktop-ni-image` proof surface/i);
  assert.match(doc, /reachable Windows Desktop is available behind WSL/i);
  assert.match(doc, /vi-history-live-candidate\.json/);
  assert.match(doc, /ni\/labview-icon-editor/i);
  assert.match(doc, /VIP_Pre-Uninstall Custom Action\.vi/);
  assert.match(doc, /UNC-backed WSL checkout/i);
  assert.match(doc, /staged into a Windows-local mount root/i);

  assert.match(arch, /Windows workflow replay surface/);
  assert.match(arch, /Local autonomy surface/);
  assert.match(arch, /Clone-backed live-history candidate surface/);

  assert.match(localCi, /REQ-VHLP-006/);
  assert.match(localCi, /windows-docker-desktop-ni-image/);
  assert.match(localCi, /priority:workflow:replay:windows:vi-history/);
  assert.match(localCi, /windows-host-bridge/i);
  assert.match(localCi, /REQ-VHLP-009/);
  assert.match(localCi, /clone-backed-live-history-candidate/);
  assert.match(localCi, /vi-history-live-candidate-readiness\.json/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import { buildAgentCostTurn, parseArgs, runAgentCostTurn } from '../agent-cost-turn.mjs';

test('parseArgs captures reasoning-effort metadata and derives effective defaults', () => {
  const parsed = parseArgs([
    'node',
    'agent-cost-turn.mjs',
    '--provider-id', 'codex-cli',
    '--provider-kind', 'local-codex',
    '--provider-runtime', 'codex-cli',
    '--execution-plane', 'wsl2',
    '--requested-model', 'gpt-5.4',
    '--requested-reasoning-effort', 'xhigh',
    '--repository', 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--issue-number', '1644',
    '--lane-id', 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
    '--lane-branch', 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
    '--session-id', 'session-live-1644',
    '--turn-id', 'turn-live-1644',
    '--agent-role', 'live',
    '--source-schema', 'priority/manual-live-session@v1',
    '--usage-observed-at', '2026-03-21T18:40:00.000Z'
  ]);

  assert.equal(parsed.effectiveModel, 'gpt-5.4');
  assert.equal(parsed.requestedReasoningEffort, 'xhigh');
  assert.equal(parsed.effectiveReasoningEffort, 'xhigh');
  assert.equal(parsed.usageUnitCount, 1);
  assert.equal(parsed.operatorCostProfilePath.replace(/\\/g, '/'), 'tools/policy/operator-cost-profile.json');
  assert.equal(parsed.operatorSteered, false);
});

test('parseArgs does not require lane-branch when branch attribution can be inferred later', () => {
  const parsed = parseArgs([
    'node',
    'agent-cost-turn.mjs',
    '--provider-id', 'codex-cli',
    '--provider-kind', 'local-codex',
    '--provider-runtime', 'codex-cli',
    '--execution-plane', 'wsl2',
    '--requested-model', 'gpt-5.4',
    '--repository', 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--issue-number', '1682',
    '--lane-id', 'origin-1682',
    '--session-id', 'session-live-1682',
    '--turn-id', 'turn-live-1682',
    '--agent-role', 'live',
    '--source-schema', 'priority/manual-live-session@v1',
    '--usage-observed-at', '2026-03-21T18:40:00.000Z'
  ]);

  assert.equal(parsed.laneBranch, null);
  assert.equal(parsed.laneId, 'origin-1682');
});

test('buildAgentCostTurn writes a normalized receipt with reasoning effort and steering metadata', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-turn-'));
  const outputPath = path.join(tmpDir, 'turn.json');
  const result = buildAgentCostTurn({
    providerId: 'codex-cli',
    providerKind: 'local-codex',
    providerRuntime: 'codex-cli',
    executionPlane: 'wsl2',
    requestedModel: 'gpt-5.4',
    effectiveModel: 'gpt-5.4',
    requestedReasoningEffort: 'xhigh',
    effectiveReasoningEffort: 'xhigh',
    inputTokens: 1000,
    cachedInputTokens: 0,
    outputTokens: 250,
    usageUnitKind: 'turn',
    usageUnitCount: 1,
    exactness: 'estimated',
    amountUsd: 0.05,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber: 1644,
    laneId: 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
    laneBranch: 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
    sessionId: 'session-live-1644',
    turnId: 'turn-live-1644',
    workerSlotId: 'worker-slot-1',
    agentRole: 'live',
    sourceSchema: 'priority/manual-live-session@v1',
    sourceReceiptPath: 'tests/results/_agent/runtime/live-turn-1644.json',
    sourceReportPath: null,
    usageObservedAt: '2026-03-21T18:40:00.000Z',
    startedAt: '2026-03-21T18:39:00.000Z',
    endedAt: '2026-03-21T18:41:00.000Z',
    operatorSteered: true,
    operatorSteeringKind: 'operator-prompt',
    operatorSteeringSource: 'operator-observed',
    operatorSteeringObservedAt: '2026-03-21T18:39:30.000Z',
    operatorSteeringNote: 'Operator provided extra steering for this calibration turn.',
    steeringInvoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    outputPath
  }, new Date('2026-03-21T18:41:00.000Z'));

  assert.equal(result.report.model.requestedReasoningEffort, 'xhigh');
  assert.equal(result.report.model.effectiveReasoningEffort, 'xhigh');
  assert.equal(result.report.runtime.elapsedSeconds, 120);
  assert.equal(result.report.labor.operatorId, 'sergio');
  assert.equal(result.report.labor.laborRateUsdPerHour, 250);
  assert.equal(result.report.labor.amountUsd, 8.333333);
  assert.equal(result.report.labor.blendedTotalUsd, 8.383333);
  assert.equal(result.report.labor.status, 'computed');
  assert.equal(result.report.steering.operatorIntervened, true);
  assert.equal(result.report.steering.kind, 'operator-prompt');
  assert.equal(result.report.steering.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(result.report.usage.totalTokens, 1250);
  assert.equal(result.outputPath, outputPath);
});

test('buildAgentCostTurn infers laneBranch from source reports before falling back to the current branch', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-turn-branch-attribution-'));
  const sourceReportPath = path.join(tmpDir, 'worker-slot.json');
  fs.writeFileSync(
    sourceReportPath,
    `${JSON.stringify({
      pullRequest: {
        headRefName: 'issue/origin-1682-branch-attributed-cost-turns'
      }
    }, null, 2)}\n`,
    'utf8'
  );

  const result = buildAgentCostTurn({
    providerId: 'codex-cli',
    providerKind: 'local-codex',
    providerRuntime: 'codex-cli',
    executionPlane: 'wsl2',
    requestedModel: 'gpt-5.4',
    effectiveModel: 'gpt-5.4',
    inputTokens: 1000,
    cachedInputTokens: 0,
    outputTokens: 250,
    usageUnitKind: 'turn',
    usageUnitCount: 1,
    exactness: 'estimated',
    amountUsd: 0.05,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber: 1682,
    laneId: 'origin-1682',
    laneBranch: null,
    sessionId: 'session-live-1682',
    turnId: 'turn-live-1682',
    workerSlotId: 'worker-slot-1',
    agentRole: 'live',
    sourceSchema: 'priority/runtime-worker-slot@v1',
    sourceReceiptPath: null,
    sourceReportPath,
    usageObservedAt: '2026-03-21T18:40:00.000Z'
  }, new Date('2026-03-21T18:41:00.000Z'));

  assert.equal(result.report.context.laneId, 'origin-1682');
  assert.equal(result.report.context.laneBranch, 'issue/origin-1682-branch-attributed-cost-turns');
  assert.equal(result.report.runtime.elapsedSeconds, null);
  assert.equal(result.report.labor.status, 'missing-elapsed-seconds');
});

test('buildAgentCostTurn falls back to the current git branch when no explicit or source-derived laneBranch exists', () => {
  const result = buildAgentCostTurn({
    providerId: 'codex-cli',
    providerKind: 'local-codex',
    providerRuntime: 'codex-cli',
    executionPlane: 'wsl2',
    requestedModel: 'gpt-5.4',
    effectiveModel: 'gpt-5.4',
    inputTokens: 1000,
    cachedInputTokens: 0,
    outputTokens: 250,
    usageUnitKind: 'turn',
    usageUnitCount: 1,
    exactness: 'estimated',
    amountUsd: 0.05,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber: 1682,
    laneId: 'origin-1682',
    laneBranch: null,
    sessionId: 'session-live-1682',
    turnId: 'turn-live-1682',
    workerSlotId: 'worker-slot-1',
    agentRole: 'live',
    sourceSchema: 'priority/manual-live-session@v1',
    sourceReceiptPath: null,
    sourceReportPath: null,
    usageObservedAt: '2026-03-21T18:40:00.000Z'
  }, new Date('2026-03-21T18:41:00.000Z'), {
    inferCurrentGitBranchFn: () => 'issue/origin-1682-branch-attributed-cost-turns-refresh'
  });

  assert.equal(result.report.context.laneBranch, 'issue/origin-1682-branch-attributed-cost-turns-refresh');
});

test('buildAgentCostTurn infers elapsedSeconds from a source receipt when present', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-turn-source-duration-'));
  const sourceReceiptPath = path.join(tmpDir, 'source-duration.json');
  fs.writeFileSync(
    sourceReceiptPath,
    `${JSON.stringify({
      durationMs: 90000,
      startedAt: '2026-03-21T18:39:00.000Z',
      endedAt: '2026-03-21T18:40:30.000Z'
    }, null, 2)}\n`,
    'utf8'
  );

  const result = buildAgentCostTurn({
    providerId: 'codex-cli',
    providerKind: 'local-codex',
    providerRuntime: 'codex-cli',
    executionPlane: 'wsl2',
    requestedModel: 'gpt-5.4',
    effectiveModel: 'gpt-5.4',
    inputTokens: 1000,
    cachedInputTokens: 0,
    outputTokens: 250,
    usageUnitKind: 'turn',
    usageUnitCount: 1,
    exactness: 'estimated',
    amountUsd: 0.05,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber: 1682,
    laneId: 'origin-1682',
    laneBranch: 'issue/origin-1682-branch-attributed-cost-turns',
    sessionId: 'session-live-1682',
    turnId: 'turn-live-1682',
    workerSlotId: 'worker-slot-1',
    agentRole: 'live',
    sourceSchema: 'priority/manual-live-session@v1',
    sourceReceiptPath,
    sourceReportPath: null,
    usageObservedAt: '2026-03-21T18:40:00.000Z'
  }, new Date('2026-03-21T18:41:00.000Z'));

  assert.equal(result.report.runtime.elapsedSeconds, 90);
  assert.equal(result.report.runtime.elapsedSource, 'source-receipt');
  assert.equal(result.report.labor.amountUsd, 6.25);
  assert.equal(result.report.labor.blendedTotalUsd, 6.3);
});

test('agent-cost-turn CLI writes a receipt directly', () => {
  const repoRoot = path.resolve(process.cwd());
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-turn-cli-'));
  const outputPath = path.join(tmpDir, 'turn.json');
  const result = spawnSync(
    process.execPath,
    [
      path.join('tools', 'priority', 'agent-cost-turn.mjs'),
      '--provider-id', 'codex-cli',
      '--provider-kind', 'local-codex',
      '--provider-runtime', 'codex-cli',
      '--execution-plane', 'wsl2',
      '--requested-model', 'gpt-5.4',
      '--requested-reasoning-effort', 'xhigh',
      '--input-tokens', '100',
      '--output-tokens', '50',
      '--repository', 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--issue-number', '1644',
      '--lane-id', 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
      '--lane-branch', 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
      '--session-id', 'session-live-1644',
      '--turn-id', 'turn-live-1644',
      '--agent-role', 'live',
      '--source-schema', 'priority/manual-live-session@v1',
      '--usage-observed-at', '2026-03-21T18:40:00.000Z',
      '--elapsed-seconds', '90',
      '--operator-steered',
      '--operator-steering-kind', 'operator-prompt',
      '--operator-steering-source', 'operator-observed',
      '--output', outputPath
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[agent-cost-turn\] wrote /);
  assert.equal(fs.existsSync(outputPath), true);
  const output = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(output.runtime.elapsedSeconds, 90);
  assert.equal(output.labor.amountUsd, 6.25);
  assert.equal(output.steering.operatorIntervened, true);
  assert.equal(output.steering.kind, 'operator-prompt');
});

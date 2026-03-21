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
});

test('buildAgentCostTurn writes a normalized receipt with reasoning effort metadata', () => {
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
    outputPath
  }, new Date('2026-03-21T18:41:00.000Z'));

  assert.equal(result.report.model.requestedReasoningEffort, 'xhigh');
  assert.equal(result.report.model.effectiveReasoningEffort, 'xhigh');
  assert.equal(result.report.usage.totalTokens, 1250);
  assert.equal(result.outputPath, outputPath);
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
});

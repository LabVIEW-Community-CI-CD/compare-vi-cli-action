#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import { buildAgentCostInvoiceTurn, parseArgs as parseInvoiceTurnArgs, runAgentCostInvoiceTurn } from '../agent-cost-invoice-turn.mjs';
import { buildAgentCostTurn, parseArgs as parseTurnArgs, runAgentCostTurn } from '../agent-cost-turn.mjs';
import { evaluateAgentCostRollup, parseArgs, runAgentCostRollup } from '../agent-cost-rollup.mjs';

const repoRoot = path.resolve(process.cwd());
const fixtureRoot = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs accepts repeated turn reports and optional repo override', () => {
  const parsed = parseArgs([
    'node',
    'agent-cost-rollup.mjs',
    '--turn-report',
    'turn-a.json',
    '--turn-report',
    'turn-b.json',
    '--repo',
    'example/repo',
    '--no-fail-on-invalid-inputs'
  ]);

  assert.deepEqual(parsed.turnReportPaths, ['turn-a.json', 'turn-b.json']);
  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.failOnInvalidInputs, false);
});

test('agent cost turn helper derives effective reasoning effort and total tokens deterministically', () => {
  const parsed = parseTurnArgs([
    'node',
    'agent-cost-turn.mjs',
    '--provider-id', 'codex-cli',
    '--provider-kind', 'local-codex',
    '--provider-runtime', 'codex-cli',
    '--execution-plane', 'wsl2',
    '--requested-model', 'gpt-5.4',
    '--requested-reasoning-effort', 'xhigh',
    '--input-tokens', '2000',
    '--output-tokens', '500',
    '--repository', 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--issue-number', '1644',
    '--lane-id', 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
    '--lane-branch', 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
    '--session-id', 'session-live-1644',
    '--turn-id', 'turn-live-1644',
    '--agent-role', 'live',
    '--source-schema', 'priority/manual-live-session@v1',
    '--usage-observed-at', '2026-03-21T19:10:30.000Z'
  ]);

  const { report } = buildAgentCostTurn(parsed, new Date('2026-03-21T19:11:00.000Z'));
  assert.equal(report.model.effectiveReasoningEffort, 'xhigh');
  assert.equal(report.usage.totalTokens, 2500);
});

test('invoice turn helper derives the prepaid baseline deterministically', () => {
  const parsed = parseInvoiceTurnArgs([
    'node',
    'agent-cost-invoice-turn.mjs',
    '--invoice-id',
    'HQ1VJLMV-0027',
    '--opened-at',
    '2026-03-21T10:01:07.000-07:00',
    '--credits-purchased',
    '10000',
    '--unit-price-usd',
    '0.04'
  ]);

  const { report } = buildAgentCostInvoiceTurn(parsed, new Date('2026-03-21T17:00:00.000Z'));
  assert.equal(report.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(report.billing.prepaidUsd, 400);
  assert.equal(report.credits.purchased, 10000);
  assert.equal(report.credits.unitPriceUsd, 0.04);
});

test('evaluateAgentCostRollup reports blockers deterministically', () => {
  const pass = evaluateAgentCostRollup({
    turnInputs: [{ exists: true, error: null, path: path.join(repoRoot, 'turn-a.json') }],
    normalizedTurns: [
      {
        status: 'valid',
        blockers: [],
        turn: { exactness: 'estimated', amountUsd: 0.02 }
      }
    ]
  });
  assert.equal(pass.status, 'pass');
  assert.equal(pass.recommendation, 'continue-estimated-telemetry');

  const fail = evaluateAgentCostRollup({
    turnInputs: [{ exists: false, error: null, path: path.join(repoRoot, 'missing.json') }],
    normalizedTurns: [
      {
        status: 'invalid',
        blockers: [{ code: 'turn-schema-mismatch', message: 'bad schema', inputPath: 'missing.json' }]
      }
    ]
  });
  assert.equal(fail.status, 'fail');
  assert.ok(fail.blockers.some((entry) => entry.code === 'turn-report-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'turn-schema-mismatch'));
});

test('estimated turns do not let a declared zero amount mask a computable rate-card estimate', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-zero-mask-'));
  const turnPath = path.join(tmpDir, 'estimated-zero-turn.json');

  writeJson(turnPath, {
    schema: 'priority/agent-cost-turn@v1',
    generatedAt: '2026-03-21T19:10:00.000Z',
    provider: {
      id: 'codex-cli',
      kind: 'local-codex',
      runtime: 'codex-cli',
      executionPlane: 'wsl2'
    },
    model: {
      requested: 'gpt-5-codex',
      effective: 'gpt-5-codex'
    },
    usage: {
      inputTokens: 2000,
      cachedInputTokens: 0,
      outputTokens: 500,
      totalTokens: 2500,
      usageUnitKind: 'turn',
      usageUnitCount: 1
    },
    billing: {
      exactness: 'estimated',
      amountUsd: 0,
      currency: 'USD',
      rateCard: {
        id: 'openai-public-2026-03-01',
        source: 'https://openai.com/api/pricing',
        retrievedAt: '2026-03-21T18:20:00.000Z',
        pricingBasis: 'per-1k-tokens',
        inputUsdPer1kTokens: 0.005,
        cachedInputUsdPer1kTokens: 0,
        outputUsdPer1kTokens: 0.016,
        usageUnitUsd: 0
      }
    },
    context: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issueNumber: 1639,
      laneId: 'issue/origin-1639-agent-cost-telemetry',
      laneBranch: 'issue/origin-1639-agent-cost-telemetry',
      sessionId: 'session-live-002',
      turnId: 'turn-live-002',
      workerSlotId: 'worker-slot-1',
      agentRole: 'live'
    },
    provenance: {
      sourceSchema: 'priority/codex-cli-review@v1',
      sourceReceiptPath: 'tests/results/_agent/runtime/worker-slot-1.json',
      sourceReportPath: null,
      usageObservedAt: '2026-03-21T19:10:30.000Z'
    }
  });

  const result = runAgentCostRollup({
    turnReportPaths: [turnPath],
    outputPath: path.join(tmpDir, 'agent-cost-rollup.json')
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.turns[0].amountUsd, 0.018);
  assert.equal(result.report.turns[0].amountSource, 'rate-card-estimate');
});

test('runAgentCostRollup aggregates exact and estimated turn spend with provenance', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [
      path.join(fixtureRoot, 'live-turn-estimated.json'),
      path.join(fixtureRoot, 'background-turn-exact.json')
    ],
    invoiceTurnPath: path.join(fixtureRoot, 'invoice-turn-baseline.json'),
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.recommendation, 'continue-estimated-telemetry');
  assert.equal(result.report.summary.metrics.totalTurns, 2);
  assert.equal(result.report.summary.metrics.exactTurnCount, 1);
  assert.equal(result.report.summary.metrics.estimatedTurnCount, 1);
  assert.equal(result.report.summary.metrics.totalUsd, 0.0626);
  assert.equal(result.report.summary.metrics.exactUsd, 0.0425);
  assert.equal(result.report.summary.metrics.estimatedUsd, 0.0201);
  assert.equal(result.report.summary.metrics.estimatedCreditsConsumed, 1.565);
  assert.equal(result.report.summary.metrics.creditsRemaining, 9998.435);
  assert.equal(result.report.summary.metrics.estimatedPrepaidUsdRemaining, 399.9374);
  assert.equal(result.report.summary.metrics.totalInputTokens, 3600);
  assert.equal(result.report.summary.metrics.totalOutputTokens, 760);
  assert.ok(result.report.summary.provenance.sessionIds.includes('session-live-001'));
  assert.ok(result.report.summary.provenance.reasoningEfforts.includes('xhigh'));
  assert.equal(result.report.summary.provenance.invoiceTurn.invoiceId, 'HQ1VJLMV-0027');
  assert.equal(result.report.billingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.ok(result.report.summary.provenance.repositories.includes('LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'));
  assert.ok(result.report.breakdown.byProvider.some((entry) => entry.key === 'codex-cli' && entry.totalUsd === 0.0201));
  assert.ok(result.report.breakdown.byReasoningEffort.some((entry) => entry.key === 'xhigh' && entry.turnCount === 1));
  assert.ok(result.report.breakdown.byAgentRole.some((entry) => entry.key === 'background' && entry.turnCount === 1));
  assert.equal(fs.existsSync(outputPath), true);
});

test('runAgentCostRollup fails closed when a turn report cannot resolve cost', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-invalid-'));
  const invalidTurnPath = path.join(tmpDir, 'invalid-turn.json');

  writeJson(invalidTurnPath, {
    schema: 'priority/agent-cost-turn@v1',
    generatedAt: '2026-03-21T19:00:00.000Z',
    provider: {
      id: 'codex-cli',
      kind: 'local-codex',
      runtime: 'codex-cli',
      executionPlane: 'wsl2'
    },
    model: {
      requested: 'gpt-5-codex',
      effective: 'gpt-5-codex'
    },
    usage: {
      inputTokens: 100,
      cachedInputTokens: 0,
      outputTokens: 20,
      totalTokens: 120,
      usageUnitKind: 'turn',
      usageUnitCount: 1
    },
    billing: {
      exactness: 'estimated',
      currency: 'USD',
      amountUsd: null,
      rateCard: null
    },
    context: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issueNumber: 1639,
      laneId: 'issue/origin-1639-agent-cost-telemetry',
      laneBranch: 'issue/origin-1639-agent-cost-telemetry',
      sessionId: 'session-live-999',
      turnId: 'turn-live-999',
      workerSlotId: 'worker-slot-9',
      agentRole: 'live'
    },
    provenance: {
      sourceSchema: 'priority/codex-cli-review@v1',
      sourceReceiptPath: 'tests/results/_agent/runtime/worker-slot-9.json',
      sourceReportPath: null,
      usageObservedAt: '2026-03-21T19:00:30.000Z'
    }
  });

  const result = runAgentCostRollup({
    turnReportPaths: [invalidTurnPath],
    outputPath: path.join(tmpDir, 'agent-cost-rollup.json'),
    failOnInvalidInputs: true
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.summary.status, 'fail');
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'billing-amount-unresolved'));
  assert.equal(result.report.summary.recommendation, 'repair-input-receipts');
});

test('runAgentCostInvoiceTurn writes a normalized invoice-turn receipt', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-invoice-turn-'));
  const outputPath = path.join(tmpDir, 'invoice-turn.json');
  const result = runAgentCostInvoiceTurn(
    {
      invoiceTurnId: null,
      invoiceId: 'HQ1VJLMV-0027',
      openedAt: '2026-03-21T10:01:07.000-07:00',
      closedAt: null,
      creditsPurchased: 10000,
      unitPriceUsd: 0.04,
      prepaidUsd: 400,
      pricingBasis: 'prepaid-credit',
      sourceKind: 'operator-invoice',
      sourcePath: 'C:/Users/sveld/Downloads/Invoice-HQ1VJLMV-0027.pdf',
      operatorNote: 'First invoice turn baseline.',
      outputPath
    },
    new Date('2026-03-21T17:00:00.000Z')
  );

  assert.equal(result.report.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(result.report.billing.prepaidUsd, 400);
  assert.equal(fs.existsSync(outputPath), true);
});

test('agent-cost-invoice-turn CLI writes a receipt when invoked directly', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-invoice-turn-cli-'));
  const outputPath = path.join(tmpDir, 'invoice-turn.json');
  const result = spawnSync(
    process.execPath,
    [
      path.join('tools', 'priority', 'agent-cost-invoice-turn.mjs'),
      '--invoice-id',
      'HQ1VJLMV-0027',
      '--opened-at',
      '2026-03-21T10:01:07.000-07:00',
      '--credits-purchased',
      '10000',
      '--unit-price-usd',
      '0.04',
      '--output',
      outputPath
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[agent-cost-invoice-turn\] wrote /);
  assert.equal(fs.existsSync(outputPath), true);
});

test('agent-cost-rollup CLI writes a rollup receipt when invoked directly', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-cli-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const result = spawnSync(
    process.execPath,
    [
      path.join('tools', 'priority', 'agent-cost-rollup.mjs'),
      '--turn-report',
      path.join('tools', 'priority', '__fixtures__', 'agent-cost-rollup', 'live-turn-estimated.json'),
      '--turn-report',
      path.join('tools', 'priority', '__fixtures__', 'agent-cost-rollup', 'background-turn-exact.json'),
      '--invoice-turn',
      path.join('tools', 'priority', '__fixtures__', 'agent-cost-rollup', 'invoice-turn-baseline.json'),
      '--output',
      outputPath
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[agent-cost-rollup\] wrote /);
  assert.equal(fs.existsSync(outputPath), true);
});

test('runAgentCostTurn writes a turn receipt when invoked programmatically', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-turn-programmatic-'));
  const outputPath = path.join(tmpDir, 'turn.json');
  const result = runAgentCostTurn(
    {
      providerId: 'codex-cli',
      providerKind: 'local-codex',
      providerRuntime: 'codex-cli',
      executionPlane: 'wsl2',
      requestedModel: 'gpt-5.4',
      requestedReasoningEffort: 'xhigh',
      inputTokens: 100,
      outputTokens: 50,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issueNumber: 1644,
      laneId: 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
      laneBranch: 'issue/origin-1644-reasoning-effort-model-selection-telemetry',
      sessionId: 'session-live-1644',
      turnId: 'turn-live-1644',
      agentRole: 'live',
      sourceSchema: 'priority/manual-live-session@v1',
      usageObservedAt: '2026-03-21T18:40:00.000Z',
      outputPath
    },
    new Date('2026-03-21T18:41:00.000Z')
  );

  assert.equal(result.report.model.effectiveReasoningEffort, 'xhigh');
  assert.equal(fs.existsSync(outputPath), true);
});

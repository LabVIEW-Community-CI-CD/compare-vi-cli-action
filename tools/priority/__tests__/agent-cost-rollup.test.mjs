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
    '--invoice-turn',
    'invoice-a.json',
    '--invoice-turn',
    'invoice-b.json',
    '--usage-export',
    'usage-a.json',
    '--account-balance',
    'balance-a.json',
    '--invoice-turn-id',
    'invoice-turn-2026-03-HQ1VJLMV-0027',
    '--repo',
    'example/repo',
    '--no-fail-on-invalid-inputs'
  ]);

  assert.deepEqual(parsed.turnReportPaths, ['turn-a.json', 'turn-b.json']);
  assert.deepEqual(parsed.invoiceTurnPaths, ['invoice-a.json', 'invoice-b.json']);
  assert.deepEqual(parsed.usageExportPaths, ['usage-a.json']);
  assert.deepEqual(parsed.accountBalancePaths, ['balance-a.json']);
  assert.equal(parsed.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
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
  assert.equal(report.policy.activationState, 'active');
  assert.equal(report.policy.fundingPurpose, 'operational');
  assert.equal(report.reconciliation.status, 'baseline-only');
  assert.equal(report.selection.mode, 'hold');
  assert.equal(report.selection.calibrationWindowId, null);
});

test('invoice turn helper carries sticky calibration selection metadata when explicitly activated', () => {
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
    '0.04',
    '--selection-mode',
    'sticky-calibration',
    '--selection-reason',
    'Calibration is active and must remain pinned to the funding window.',
    '--calibration-window-id',
    'invoice-turn-2026-03-HQ1VJLMV-0027'
  ]);

  const { report } = buildAgentCostInvoiceTurn(parsed, new Date('2026-03-21T17:00:00.000Z'));
  assert.equal(report.selection.mode, 'sticky-calibration');
  assert.equal(report.selection.calibrationWindowId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(report.selection.reason, 'Calibration is active and must remain pinned to the funding window.');
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
    },
    steering: {
      operatorIntervened: false,
      kind: null,
      source: null,
      observedAt: null,
      note: null,
      invoiceTurnId: null
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

test('runAgentCostRollup summarizes optional usage-export and account-balance evidence', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-account-evidence-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const usageExportPath = path.join(tmpDir, 'usage-export.json');
  const accountBalancePath = path.join(tmpDir, 'account-balance.json');

  writeJson(usageExportPath, {
    schema: 'priority/agent-cost-usage-export@v1',
    generatedAt: '2026-03-21T20:20:00.000Z',
    reportWindow: {
      startDate: '2026-03-15',
      endDate: '2026-03-20',
      rowCount: 6
    },
    usageType: 'codex',
    totals: {
      usageCredits: 10559.88,
      usageQuantity: 211197.6
    },
    sourceKind: 'operator-usage-export',
    sourcePathEvidence: 'LabVIEW Open-Source Initiative Credit Usage Report (Mar 15 - Apr 15).csv',
    operatorNote: 'Current partial usage window.'
  });

  writeJson(accountBalancePath, {
    schema: 'priority/agent-cost-account-balance@v1',
    generatedAt: '2026-03-21T20:21:00.000Z',
    effectiveAt: '2026-03-21T20:21:00.000Z',
    plan: {
      name: 'Business',
      renewsAt: '2026-04-15T00:00:00.000Z'
    },
    balances: {
      totalCredits: 27500,
      usedCredits: 15800,
      remainingCredits: 11700
    },
    sourceKind: 'operator-account-balance',
    sourcePathEvidence: 'Business plan account snapshot',
    operatorNote: 'Current account balance snapshot.'
  });

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [
      path.join(fixtureRoot, 'live-turn-estimated.json'),
      path.join(fixtureRoot, 'background-turn-exact.json')
    ],
    invoiceTurnPaths: [path.join(fixtureRoot, 'invoice-turn-baseline.json')],
    usageExportPaths: [usageExportPath],
    accountBalancePaths: [accountBalancePath],
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.metrics.usageExportWindowCount, 1);
  assert.equal(result.report.summary.metrics.usageExportCreditsReported, 10559.88);
  assert.equal(result.report.summary.metrics.accountBalanceRemainingCredits, 11700);
  assert.equal(result.report.summary.provenance.usageExports.length, 1);
  assert.equal(result.report.summary.provenance.accountBalance?.planName, 'Business');
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
    invoiceTurnPaths: [path.join(fixtureRoot, 'invoice-turn-baseline.json')],
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
  assert.equal(result.report.summary.metrics.actualUsdConsumed, null);
  assert.equal(result.report.summary.metrics.heuristicUsdDelta, null);
  assert.equal(result.report.summary.metrics.totalInputTokens, 3600);
  assert.equal(result.report.summary.metrics.totalOutputTokens, 760);
  assert.equal(result.report.summary.metrics.steeredTurnCount, 1);
  assert.equal(result.report.summary.metrics.unsteeredTurnCount, 1);
  assert.equal(result.report.summary.metrics.steeredUsd, 0.0201);
  assert.equal(result.report.summary.metrics.unsteeredUsd, 0.0425);
  assert.ok(result.report.summary.provenance.sessionIds.includes('session-live-001'));
  assert.ok(result.report.summary.provenance.reasoningEfforts.includes('xhigh'));
  assert.ok(result.report.summary.provenance.steeringKinds.includes('operator-prompt'));
  assert.ok(result.report.summary.provenance.steeringSources.includes('operator-observed'));
  assert.equal(result.report.summary.provenance.invoiceTurn.invoiceId, 'HQ1VJLMV-0027');
  assert.equal(result.report.summary.provenance.invoiceTurn.activationState, 'active');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.strategy, 'single-candidate');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.mode, 'hold');
  assert.equal(result.report.billingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(result.report.billingWindow.activationState, 'active');
  assert.equal(result.report.billingWindow.selection.mode, 'hold');
  assert.equal(result.report.billingWindow.selection.selectedInvoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.ok(result.report.summary.provenance.repositories.includes('LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'));
  assert.ok(result.report.breakdown.byProvider.some((entry) => entry.key === 'codex-cli' && entry.totalUsd === 0.0201));
  assert.ok(result.report.breakdown.byReasoningEffort.some((entry) => entry.key === 'xhigh' && entry.turnCount === 1));
  assert.ok(result.report.breakdown.byAgentRole.some((entry) => entry.key === 'background' && entry.turnCount === 1));
  assert.ok(result.report.breakdown.bySteering.some((entry) => entry.key === 'steered' && entry.turnCount === 1));
  assert.equal(fs.existsSync(outputPath), true);
});

test('runAgentCostRollup prefers sticky calibration invoice turns over operational windows', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-sticky-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const stickyInvoiceTurnPath = path.join(tmpDir, 'invoice-turn-sticky-calibration.json');

  const stickyInvoiceTurn = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'invoice-turn-next-baseline.json'), 'utf8'));
  stickyInvoiceTurn.invoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration';
  stickyInvoiceTurn.invoiceId = 'HQ1VJLMV-0028';
  stickyInvoiceTurn.billingPeriod.openedAt = '2026-03-21T12:00:00.000-07:00';
  stickyInvoiceTurn.credits.purchased = 2500;
  stickyInvoiceTurn.billing.prepaidUsd = 100;
  stickyInvoiceTurn.policy.activationState = 'active';
  stickyInvoiceTurn.policy.fundingPurpose = 'calibration';
  stickyInvoiceTurn.provenance.operatorNote = 'Protected calibration funding window that must remain sticky.';
  stickyInvoiceTurn.selection = {
    mode: 'sticky-calibration',
    calibrationWindowId: 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration',
    reason: 'Calibration remains pinned until the session is explicitly ended.'
  };
  writeJson(stickyInvoiceTurnPath, stickyInvoiceTurn);

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [path.join(fixtureRoot, 'live-turn-estimated.json')],
    invoiceTurnPaths: [
      path.join(fixtureRoot, 'invoice-turn-baseline.json'),
      stickyInvoiceTurnPath
    ],
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.provenance.invoiceTurn.invoiceId, 'HQ1VJLMV-0028');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.strategy, 'sticky-calibration-active');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.mode, 'sticky-calibration');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.calibrationWindowId, 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration');
  assert.match(result.report.summary.provenance.invoiceTurnSelection.reason, /pinned/i);
  assert.equal(result.report.billingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration');
  assert.equal(result.report.billingWindow.selection.mode, 'sticky-calibration');
});

test('runAgentCostRollup selects the active invoice turn deterministically when multiple receipts coexist', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-overlap-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const lateTurnPath = path.join(tmpDir, 'late-turn.json');

  const liveTurn = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'live-turn-estimated.json'), 'utf8'));
  liveTurn.provenance.usageObservedAt = '2026-04-20T12:00:00.000Z';
  writeJson(lateTurnPath, liveTurn);

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [lateTurnPath],
    invoiceTurnPaths: [
      path.join(fixtureRoot, 'invoice-turn-baseline.json'),
      path.join(fixtureRoot, 'invoice-turn-next-baseline.json')
    ],
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.provenance.invoiceTurn.invoiceId, 'HQ1VJLMV-0028');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.strategy, 'active-window-latest-openedAt');
  assert.equal(result.report.billingWindow.invoiceTurnId, 'invoice-turn-2026-04-HQ1VJLMV-0028');
  assert.equal(result.report.summary.metrics.estimatedPrepaidUsdRemaining, 319.9799);
  assert.notEqual(result.report.summary.metrics.estimatedPrepaidUsdRemaining, 719.9799);
});

test('runAgentCostRollup honors an explicit invoice-turn selection override', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-explicit-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [path.join(fixtureRoot, 'live-turn-estimated.json')],
    invoiceTurnPaths: [
      path.join(fixtureRoot, 'invoice-turn-baseline.json'),
      path.join(fixtureRoot, 'invoice-turn-next-baseline.json')
    ],
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.strategy, 'explicit-id');
  assert.equal(result.report.billingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
});

test('runAgentCostRollup ignores held calibration invoice turns during automatic selection', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-hold-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const holdInvoiceTurnPath = path.join(tmpDir, 'invoice-turn-calibration-hold.json');

  const holdInvoiceTurn = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'invoice-turn-next-baseline.json'), 'utf8'));
  holdInvoiceTurn.invoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration';
  holdInvoiceTurn.invoiceId = 'HQ1VJLMV-0028';
  holdInvoiceTurn.billingPeriod.openedAt = '2026-03-21T12:00:00.000-07:00';
  holdInvoiceTurn.credits.purchased = 2500;
  holdInvoiceTurn.billing.prepaidUsd = 100;
  holdInvoiceTurn.policy.activationState = 'hold';
  holdInvoiceTurn.policy.fundingPurpose = 'calibration';
  holdInvoiceTurn.provenance.operatorNote = 'Protected one-time calibration funding window.';
  writeJson(holdInvoiceTurnPath, holdInvoiceTurn);

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [path.join(fixtureRoot, 'live-turn-estimated.json')],
    invoiceTurnPaths: [
      path.join(fixtureRoot, 'invoice-turn-baseline.json'),
      holdInvoiceTurnPath
    ],
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.provenance.invoiceTurn.invoiceId, 'HQ1VJLMV-0027');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.strategy, 'single-candidate');
  assert.equal(result.report.billingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.notEqual(result.report.billingWindow.invoiceId, 'HQ1VJLMV-0028');
});

test('runAgentCostRollup honors an explicit hold-window calibration selection override', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-hold-explicit-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const holdInvoiceTurnPath = path.join(tmpDir, 'invoice-turn-calibration-hold.json');

  const holdInvoiceTurn = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'invoice-turn-next-baseline.json'), 'utf8'));
  holdInvoiceTurn.invoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration';
  holdInvoiceTurn.invoiceId = 'HQ1VJLMV-0028';
  holdInvoiceTurn.billingPeriod.openedAt = '2026-03-21T12:00:00.000-07:00';
  holdInvoiceTurn.credits.purchased = 2500;
  holdInvoiceTurn.billing.prepaidUsd = 100;
  holdInvoiceTurn.policy.activationState = 'hold';
  holdInvoiceTurn.policy.fundingPurpose = 'calibration';
  writeJson(holdInvoiceTurnPath, holdInvoiceTurn);

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [path.join(fixtureRoot, 'live-turn-estimated.json')],
    invoiceTurnPaths: [
      path.join(fixtureRoot, 'invoice-turn-baseline.json'),
      holdInvoiceTurnPath
    ],
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration',
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.provenance.invoiceTurn.invoiceId, 'HQ1VJLMV-0028');
  assert.equal(result.report.summary.provenance.invoiceTurn.activationState, 'hold');
  assert.equal(result.report.summary.provenance.invoiceTurn.fundingPurpose, 'calibration');
  assert.equal(result.report.summary.provenance.invoiceTurnSelection.strategy, 'explicit-id');
  assert.equal(result.report.billingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0028-calibration');
});

test('runAgentCostRollup emits heuristic drift metrics when actual invoice consumption is available', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-reconciled-'));
  const outputPath = path.join(tmpDir, 'agent-cost-rollup.json');

  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [
      path.join(fixtureRoot, 'live-turn-estimated.json'),
      path.join(fixtureRoot, 'background-turn-exact.json')
    ],
    invoiceTurnPaths: [path.join(fixtureRoot, 'invoice-turn-baseline-reconciled.json')],
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.metrics.actualUsdConsumed, 11.2);
  assert.equal(result.report.summary.metrics.actualCreditsConsumed, 280);
  assert.equal(result.report.summary.metrics.heuristicUsdDelta, -11.1374);
  assert.equal(result.report.summary.metrics.heuristicCreditsDelta, -278.435);
  assert.equal(result.report.billingWindow.reconciliationStatus, 'actual-observed');
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
    },
    steering: {
      operatorIntervened: false,
      kind: null,
      source: null,
      observedAt: null,
      note: null,
      invoiceTurnId: null
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
      activationState: 'active',
      fundingPurpose: 'operational',
      actualUsdConsumed: null,
      actualCreditsConsumed: null,
      reconciledAt: null,
      reconciliationSourceKind: null,
      reconciliationNote: null,
      outputPath
    },
    new Date('2026-03-21T17:00:00.000Z')
  );

  assert.equal(result.report.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(result.report.billing.prepaidUsd, 400);
  assert.equal(result.report.reconciliation.status, 'baseline-only');
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
      '--activation-state',
      'hold',
      '--funding-purpose',
      'calibration',
      '--selection-mode',
      'sticky-calibration',
      '--selection-reason',
      'Calibration receipts stay pinned while the window is active.',
      '--actual-usd-consumed',
      '11.2',
      '--actual-credits-consumed',
      '280',
      '--reconciled-at',
      '2026-04-01T09:30:00.000-07:00',
      '--reconciliation-source-kind',
      'operator-observed',
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
  const output = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(output.policy.activationState, 'hold');
  assert.equal(output.policy.fundingPurpose, 'calibration');
  assert.equal(output.selection.mode, 'sticky-calibration');
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
      '--invoice-turn',
      path.join('tools', 'priority', '__fixtures__', 'agent-cost-rollup', 'invoice-turn-next-baseline.json'),
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

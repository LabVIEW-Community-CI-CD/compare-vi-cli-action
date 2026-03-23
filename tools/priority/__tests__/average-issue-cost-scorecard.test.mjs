#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { runAverageIssueCostScorecard } from '../average-issue-cost-scorecard.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function buildTurn({
  issueNumber,
  turnId,
  observedAt,
  amountUsd,
  exactness = 'exact',
  agentRole = 'live',
  executionPlane = 'local',
  steeringInvoiceTurnId = null
}) {
  return {
    sourcePath: `tests/results/_agent/cost/turns/${turnId}.json`,
    generatedAt: observedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber,
    laneId: 'lane-1708',
    laneBranch: 'issue/origin-1708-average-issue-cost-over-time',
    sessionId: 'session-1708',
    turnId,
    workerSlotId: 'worker-1',
    agentRole,
    providerId: 'openai',
    providerKind: 'api',
    providerRuntime: 'responses',
    executionPlane,
    requestedModel: 'gpt-5.4',
    effectiveModel: 'gpt-5.4',
    requestedReasoningEffort: 'medium',
    effectiveReasoningEffort: 'medium',
    startedAt: observedAt,
    endedAt: observedAt,
    elapsedSeconds: 60,
    elapsedSource: 'explicit',
    operatorProfilePath: 'tools/policy/operator-cost-profile.json',
    operatorId: 'sergio',
    operatorName: 'Sergio Velderrain Ruiz',
    laborRateUsdPerHour: 250,
    operatorLaborUsd: 4.166667,
    blendedTotalUsd: Number((amountUsd + 4.166667).toFixed(6)),
    laborStatus: 'computed',
    operatorIntervened: false,
    steeringKind: null,
    steeringSource: null,
    steeringObservedAt: null,
    steeringNote: null,
    steeringInvoiceTurnId,
    usageUnitKind: 'token',
    usageUnitCount: 100,
    inputTokens: 60,
    cachedInputTokens: 0,
    outputTokens: 40,
    totalTokens: 100,
    exactness,
    amountUsd,
    amountSource: 'rate-card-estimate',
    rateCardId: 'rate-card-1',
    rateCardSource: 'checked-in-fixture',
    rateCardRetrievedAt: observedAt,
    pricingBasis: 'token',
    provenance: {
      sourceSchema: 'priority/agent-cost-turn@v1',
      sourceReceiptPath: `tests/results/_agent/cost/turns/${turnId}.json`,
      sourceReportPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
      usageObservedAt: observedAt
    }
  };
}

function buildInvoiceTurn({
  invoiceTurnId,
  invoiceId,
  openedAt,
  closedAt,
  activationState = 'active',
  fundingPurpose = 'operational'
}) {
  return {
    schema: 'priority/agent-cost-invoice-turn@v1',
    generatedAt: openedAt,
    invoiceTurnId,
    invoiceId,
    billingPeriod: {
      openedAt,
      closedAt
    },
    credits: {
      purchased: 100,
      unitPriceUsd: 0.1
    },
    billing: {
      currency: 'USD',
      prepaidUsd: 10,
      pricingBasis: 'prepaid-credit'
    },
    policy: {
      activationState,
      fundingPurpose
    },
    reconciliation: {
      status: 'baseline-only',
      actualUsdConsumed: null,
      actualCreditsConsumed: null,
      reconciledAt: null,
      sourceKind: null,
      note: null
    },
    provenance: {
      sourceKind: 'manual-baseline',
      sourcePath: null,
      operatorNote: null
    },
    selection: {
      mode: 'hold',
      calibrationWindowId: null,
      reason: null
    }
  };
}

function buildCostRollup(turns, invoiceTurnPaths = []) {
  return {
    schema: 'priority/agent-cost-rollup@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      turnReportPaths: [],
      invoiceTurnPaths: invoiceTurnPaths.map((entry) => ({ path: entry, exists: true, error: null })),
      usageExportPaths: [],
      accountBalancePaths: [],
      selectedInvoiceTurnId: 'invoice-turn-002',
      explicitInvoiceTurnId: null
    },
    turns,
    summary: {
      metrics: {
        totalUsd: turns.reduce((sumValue, turn) => sumValue + turn.amountUsd, 0)
      }
    },
    billingWindow: {
      invoiceTurnId: 'invoice-turn-002',
      invoiceId: 'invoice-002',
      openedAt: '2026-03-11T00:00:00.000Z',
      closedAt: null,
      fundingPurpose: 'operational',
      activationState: 'active',
      reconciliationStatus: 'baseline-only',
      selection: {
        mode: 'hold',
        calibrationWindowId: null
      },
      reconciledAt: null
    }
  };
}

test('runAverageIssueCostScorecard projects rolling window averages, current-state buckets, and spend channel splits', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'average-issue-cost-scorecard-pass-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const invoiceTurn1Path = path.join(tempDir, 'invoice-turn-001.json');
  const invoiceTurn2Path = path.join(tempDir, 'invoice-turn-002.json');
  const outputPath = path.join(tempDir, 'average-issue-cost-scorecard.json');

  writeJson(invoiceTurn1Path, buildInvoiceTurn({
    invoiceTurnId: 'invoice-turn-001',
    invoiceId: 'invoice-001',
    openedAt: '2026-03-01T00:00:00.000Z',
    closedAt: '2026-03-10T23:59:59.000Z'
  }));
  writeJson(invoiceTurn2Path, buildInvoiceTurn({
    invoiceTurnId: 'invoice-turn-002',
    invoiceId: 'invoice-002',
    openedAt: '2026-03-11T00:00:00.000Z',
    closedAt: null
  }));

  const turns = [
    buildTurn({ issueNumber: 101, turnId: 'turn-1', observedAt: '2026-03-05T10:00:00.000Z', amountUsd: 6 }),
    buildTurn({ issueNumber: 101, turnId: 'turn-2', observedAt: '2026-03-12T10:00:00.000Z', amountUsd: 2, exactness: 'estimated', agentRole: 'background' }),
    buildTurn({ issueNumber: 102, turnId: 'turn-3', observedAt: '2026-03-12T12:00:00.000Z', amountUsd: 8, executionPlane: 'hosted' }),
    buildTurn({ issueNumber: 103, turnId: 'turn-4', observedAt: '2026-03-13T12:00:00.000Z', amountUsd: 4 }),
    buildTurn({ issueNumber: null, turnId: 'turn-5', observedAt: '2026-03-13T14:00:00.000Z', amountUsd: 1 })
  ];
  writeJson(costRollupPath, buildCostRollup(turns, [invoiceTurn1Path, invoiceTurn2Path]));

  const result = await runAverageIssueCostScorecard({
    costRollupPath,
    invoiceTurnPaths: [invoiceTurn1Path, invoiceTurn2Path],
    outputPath,
    repoRoot: tempDir,
    fetchIssueFn: async (issueNumber) => {
      if (issueNumber === 101) return { number: 101, title: 'Open issue', state: 'open', updatedAt: '2026-03-20T00:00:00.000Z', url: 'https://example.test/101', labels: [], body: '', comments: [] };
      if (issueNumber === 102) return { number: 102, title: 'Closed issue', state: 'closed', updatedAt: '2026-03-20T00:00:00.000Z', url: 'https://example.test/102', labels: [], body: '', comments: [] };
      return { number: 103, title: 'Blocked issue', state: 'open', updatedAt: '2026-03-20T00:00:00.000Z', url: 'https://example.test/103', labels: ['blocked'], body: 'Externally blocked on upstream dependency.', comments: [] };
    },
    now: new Date('2026-03-21T18:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.recommendation, 'tighten-issue-attribution');
  assert.deepEqual(result.report.summary.reasons, ['estimated-spend-present', 'unattributed-turns-present']);
  assert.equal(result.report.summary.metrics.totalUsd, 21);
  assert.equal(result.report.summary.metrics.operatorLaborUsd, 20.833335);
  assert.equal(result.report.summary.metrics.blendedTotalUsd, 41.833335);
  assert.equal(result.report.summary.metrics.issueAttributedUsd, 20);
  assert.equal(result.report.summary.metrics.unattributedUsd, 1);
  assert.equal(result.report.summary.metrics.liveAgentUsd, 11);
  assert.equal(result.report.summary.metrics.backgroundAgentUsd, 2);
  assert.equal(result.report.summary.metrics.hostedValidationUsd, 8);
  assert.equal(result.report.summary.metrics.rollingAverageUsdPerIssue, 6.666667);
  assert.equal(result.report.summary.metrics.currentActiveWindowAverageUsdPerIssue, 4.666667);
  assert.equal(result.report.summary.metrics.latestTrailingOperationalWindowAverageUsdPerIssue, 6);
  assert.equal(result.report.windows.length, 2);
  assert.equal(result.report.windows[0].metrics.averageUsdPerIssue, 6);
  assert.equal(result.report.windows[0].metrics.operatorLaborUsd, 4.166667);
  assert.equal(result.report.windows[1].metrics.rollingAverageUsdPerIssue, 6.666667);
  assert.equal(result.report.issues.find((entry) => entry.issueNumber === 102)?.hostedValidationUsd, 8);
  assert.equal(result.report.issues.find((entry) => entry.issueNumber === 102)?.blendedTotalUsd, 12.166667);
  assert.equal(result.report.issues.find((entry) => entry.issueNumber === 103)?.stateBucket, 'blocked-external');
  assert.equal(fs.existsSync(outputPath), true);
});

test('runAverageIssueCostScorecard falls back to the current billing window and warns when invoice-turn receipts or issue hydration are missing', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'average-issue-cost-scorecard-fallback-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');

  writeJson(
    costRollupPath,
    buildCostRollup([buildTurn({ issueNumber: 201, turnId: 'turn-fallback', observedAt: '2026-03-12T09:00:00.000Z', amountUsd: 5 })])
  );

  const result = await runAverageIssueCostScorecard({
    costRollupPath,
    repoRoot: tempDir,
    fetchIssueFn: async () => {
      throw new Error('gh unavailable');
    },
    now: new Date('2026-03-21T19:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.recommendation, 'refresh-issue-state-hydration');
  assert.deepEqual(result.report.summary.reasons, [
    'invoice-turn-receipts-missing',
    'issue-state-hydration-incomplete',
    'single-window-coverage'
  ]);
  assert.equal(result.report.windows.length, 1);
  assert.equal(result.report.windows[0].synthetic, true);
  assert.equal(result.report.issues[0].stateBucket, 'unknown');
});

test('runAverageIssueCostScorecard fails closed when the cost rollup is missing', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'average-issue-cost-scorecard-fail-'));
  const costRollupPath = path.join(tempDir, 'missing-rollup.json');

  const result = await runAverageIssueCostScorecard({
    costRollupPath,
    repoRoot: tempDir,
    now: new Date('2026-03-21T20:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'fail');
  assert.equal(result.report.summary.recommendation, 'repair-input-receipts');
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'cost-rollup-missing'));
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'billing-window-missing'));
});

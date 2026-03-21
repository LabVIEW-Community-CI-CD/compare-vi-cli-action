#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { runFundedThroughputScorecard } from '../funded-throughput-scorecard.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function buildCostRollup({
  totalUsd = 20,
  exactUsd = 20,
  estimatedUsd = 0,
  actualUsdConsumed = 19.5,
  heuristicUsdDelta = 0.5,
  heuristicUsdDeltaRatio = 0.025641,
  fundingPurpose = 'operational',
  selectionMode = 'hold',
  reconciliationStatus = 'actual-observed'
} = {}) {
  return {
    schema: 'priority/agent-cost-rollup@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      metrics: {
        totalUsd,
        exactUsd,
        estimatedUsd,
        actualUsdConsumed,
        heuristicUsdDelta,
        heuristicUsdDeltaRatio
      }
    },
    billingWindow: {
      invoiceTurnId: 'invoice-turn-001',
      invoiceId: 'invoice-001',
      openedAt: '2026-03-21T00:00:00.000Z',
      closedAt: '2026-03-21T12:00:00.000Z',
      pricingBasis: 'prepaid-credits',
      activationState: 'active',
      fundingPurpose,
      sourceKind: 'operator-capture',
      sourcePathEvidence: 'tests/results/_agent/cost/invoice-turns/invoice-turn-001.json',
      operatorNote: null,
      reconciliationStatus,
      actualUsdConsumed,
      actualCreditsConsumed: 195,
      reconciledAt: reconciliationStatus === 'actual-observed' ? '2026-03-21T12:30:00.000Z' : null,
      reconciliationSourceKind: reconciliationStatus === 'actual-observed' ? 'invoice-export' : null,
      reconciliationNote: null,
      selection: {
        strategy: 'active-window-latest-openedAt',
        explicitInvoiceTurnId: null,
        selectionObservedAt: '2026-03-21T12:00:00.000Z',
        candidateCount: 1,
        matchingCandidateCount: 1,
        candidateInvoiceTurnIds: ['invoice-turn-001'],
        selectedInvoiceTurnId: 'invoice-turn-001',
        mode: selectionMode,
        calibrationWindowId: selectionMode === 'sticky-calibration' ? 'cal-001' : null,
        reason: selectionMode === 'sticky-calibration' ? 'calibration-hold' : null
      }
    }
  };
}

function buildThroughputScorecard({
  totalTerminalPullRequestCount = 5,
  mergedPullRequestCount = 4,
  hostedWaitEscapeCount = 2,
  concurrentLaneActiveCount = 2
} = {}) {
  return {
    schema: 'priority/throughput-scorecard@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    delivery: {
      totalTerminalPullRequestCount,
      mergedPullRequestCount,
      closedPullRequestCount: Math.max(totalTerminalPullRequestCount - mergedPullRequestCount, 0),
      hostedWaitEscapeCount,
      meanTerminalDurationMinutes: 12,
      viHistorySuitePullRequestCount: 1
    },
    summary: {
      status: 'pass',
      reasons: [],
      metrics: {
        concurrentLaneActiveCount,
        hostedWaitEscapeCount
      }
    }
  };
}

test('runFundedThroughputScorecard reports operational validated throughput per funded dollar from existing cost and throughput artifacts', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'funded-throughput-scorecard-pass-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputScorecardPath = path.join(tempDir, 'throughput-scorecard.json');
  const outputPath = path.join(tempDir, 'funded-throughput-scorecard.json');

  writeJson(costRollupPath, buildCostRollup());
  writeJson(throughputScorecardPath, buildThroughputScorecard());

  const result = runFundedThroughputScorecard({
    costRollupPath,
    throughputScorecardPath,
    outputPath,
    now: new Date('2026-03-21T13:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.recommendation, 'benchmark-operational-throughput');
  assert.equal(result.report.summary.metrics.fundedUsd, 20);
  assert.equal(result.report.summary.metrics.validatedMergedPullRequestCount, 4);
  assert.equal(result.report.summary.metrics.closedIssueCount, 1);
  assert.equal(result.report.summary.metrics.promotionEvidenceCount, 5);
  assert.equal(result.report.summary.metrics.concurrentLaneActiveCount, 2);
  assert.equal(result.report.summary.metrics.meanTerminalDurationMinutes, 12);
  assert.equal(result.report.summary.metrics.laneMinutesAllocated, 24);
  assert.equal(result.report.summary.metrics.validatedMergedPullRequestsPerFundedUsd, 0.2);
  assert.equal(result.report.summary.metrics.closedIssuesPerFundedUsd, 0.05);
  assert.equal(result.report.summary.metrics.promotionEvidencePerFundedUsd, 0.25);
  assert.equal(result.report.summary.metrics.laneMinutesAllocatedPerFundedUsd, 1.2);
  assert.equal(result.report.summary.metrics.hostedWaitEscapesPerFundedUsd, 0.1);
  assert.equal(result.report.fundingWindow.windowClass, 'operational');
  assert.deepEqual(result.report.coverage.implementedMetricCodes, [
    'validated-merged-prs-per-funded-dollar',
    'issues-closed-per-funded-dollar',
    'promotion-evidence-per-funded-dollar',
    'lane-minutes-allocated-per-funded-dollar',
    'hosted-wait-escapes-per-funded-dollar',
    'heuristic-spend-drift-relative-to-invoice-turn'
  ]);
  assert.deepEqual(result.report.coverage.projectedMetricCodes, [
    'issues-closed-per-funded-dollar',
    'promotion-evidence-per-funded-dollar',
    'lane-minutes-allocated-per-funded-dollar'
  ]);
  assert.deepEqual(result.report.coverage.deferredMetrics, []);
  assert.equal(fs.existsSync(outputPath), true);
});

test('runFundedThroughputScorecard warns when the funding window is calibration-scoped and spend remains estimated', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'funded-throughput-scorecard-calibration-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputScorecardPath = path.join(tempDir, 'throughput-scorecard.json');

  writeJson(
    costRollupPath,
    buildCostRollup({
      totalUsd: 10,
      exactUsd: 4,
      estimatedUsd: 6,
      actualUsdConsumed: null,
      heuristicUsdDelta: null,
      heuristicUsdDeltaRatio: null,
      fundingPurpose: 'calibration',
      selectionMode: 'sticky-calibration',
      reconciliationStatus: 'baseline-only'
    })
  );
  writeJson(
    throughputScorecardPath,
    buildThroughputScorecard({
      totalTerminalPullRequestCount: 2,
      mergedPullRequestCount: 1,
      hostedWaitEscapeCount: 0
    })
  );

  const result = runFundedThroughputScorecard({
    costRollupPath,
    throughputScorecardPath,
    now: new Date('2026-03-21T14:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.recommendation, 'continue-calibration-before-benchmarking');
  assert.deepEqual(result.report.summary.reasons, [
    'calibration-window',
    'estimated-spend-present',
    'invoice-reconciliation-pending'
  ]);
  assert.equal(result.report.fundingWindow.windowClass, 'calibration');
  assert.equal(result.report.summary.metrics.validatedMergedPullRequestsPerFundedUsd, 0.1);
  assert.equal(result.report.summary.metrics.closedIssuesPerFundedUsd, 0.1);
  assert.equal(result.report.summary.metrics.promotionEvidencePerFundedUsd, 0.2);
  assert.equal(result.report.summary.metrics.laneMinutesAllocatedPerFundedUsd, 2.4);
  assert.equal(result.report.summary.metrics.heuristicUsdDelta, null);
});

test('runFundedThroughputScorecard warns cleanly instead of dividing by zero when no funded spend has been observed', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'funded-throughput-scorecard-zero-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputScorecardPath = path.join(tempDir, 'throughput-scorecard.json');

  writeJson(
    costRollupPath,
    buildCostRollup({
      totalUsd: 0,
      exactUsd: 0,
      estimatedUsd: 0,
      actualUsdConsumed: 0,
      heuristicUsdDelta: 0,
      heuristicUsdDeltaRatio: null
    })
  );
  writeJson(
    throughputScorecardPath,
    buildThroughputScorecard({
      totalTerminalPullRequestCount: 0,
      mergedPullRequestCount: 0,
      hostedWaitEscapeCount: 0
    })
  );

  const result = runFundedThroughputScorecard({
    costRollupPath,
    throughputScorecardPath,
    now: new Date('2026-03-21T15:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.recommendation, 'observe-funded-window');
  assert.deepEqual(result.report.summary.reasons, ['no-funded-spend-observed']);
  assert.equal(result.report.summary.metrics.validatedMergedPullRequestsPerFundedUsd, null);
  assert.equal(result.report.summary.metrics.closedIssuesPerFundedUsd, null);
  assert.equal(result.report.summary.metrics.promotionEvidencePerFundedUsd, null);
  assert.equal(result.report.summary.metrics.laneMinutesAllocatedPerFundedUsd, null);
  assert.equal(result.report.summary.metrics.hostedWaitEscapesPerFundedUsd, null);
});

test('runFundedThroughputScorecard fails closed when the required cost artifact is missing', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'funded-throughput-scorecard-fail-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputScorecardPath = path.join(tempDir, 'throughput-scorecard.json');

  writeJson(throughputScorecardPath, buildThroughputScorecard());

  const result = runFundedThroughputScorecard({
    costRollupPath,
    throughputScorecardPath,
    now: new Date('2026-03-21T16:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'fail');
  assert.equal(result.report.summary.recommendation, 'repair-input-receipts');
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'cost-rollup-missing'));
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'funded-usd-missing'));
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'billing-window-missing'));
});

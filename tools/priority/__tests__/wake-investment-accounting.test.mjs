import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { runWakeInvestmentAccounting } from '../wake-investment-accounting.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy() {
  return {
    schema: 'priority/wake-investment-accounting-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    benchmarkMetricPreference: [
      'rollingAverageBlendedUsdPerIssue',
      'currentActiveWindowAverageBlendedUsdPerIssue',
      'latestTrailingOperationalWindowAverageBlendedUsdPerIssue',
      'rollingAverageUsdPerIssue',
      'currentActiveWindowAverageUsdPerIssue',
      'latestTrailingOperationalWindowAverageUsdPerIssue'
    ],
    allowObservedIssueFallback: true,
    decisionAccounting: {
      suppress: { accountingBucket: 'suppressed-wake', avoidedCostProxy: 'issue-benchmark' },
      monitor: { accountingBucket: 'monitoring-wake', avoidedCostProxy: 'none' },
      'compare-governance-work': { accountingBucket: 'compare-governance-work', avoidedCostProxy: 'issue-benchmark' },
      'template-work': { accountingBucket: 'template-work', avoidedCostProxy: 'none' },
      'consumer-proving-drift': { accountingBucket: 'consumer-proving-drift', avoidedCostProxy: 'issue-benchmark' },
      'investment-work': { accountingBucket: 'investment-work', avoidedCostProxy: 'none' }
    },
    paybackTriggers: {
      classificationEligibility: ['stale-artifact', 'branch-target-drift'],
      allowSuppressionTrigger: true,
      allowOwnerRepositoryMismatchTrigger: true
    }
  };
}

function createWakeAdjudication({ classification, suppressed, ownerRepository }) {
  return {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: '2026-03-22T17:03:14.724Z',
    wakeKind: 'downstream-onboarding',
    reported: {
      path: 'reported.json',
      generatedAt: '2026-03-22T15:29:06.702Z',
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      targetBranch: classification === 'branch-target-drift' ? 'downstream/develop' : 'develop',
      defaultBranch: classification === 'branch-target-drift' ? 'downstream/develop' : 'develop',
      summaryStatus: 'fail',
      requiredFailCount: classification === 'live-defect' ? 1 : 3,
      warningCount: 2,
      workflowReferenceCount: 0,
      successfulRunCount: 0,
      requiredFailures: [],
      warnings: []
    },
    revalidated: {
      path: 'revalidated.json',
      generatedAt: '2026-03-22T16:09:18.062Z',
      downstreamRepository: ownerRepository,
      targetBranch: 'develop',
      defaultBranch: 'develop',
      summaryStatus: classification === 'live-defect' ? 'fail' : 'warn',
      requiredFailCount: classification === 'live-defect' ? 1 : 0,
      warningCount: 2,
      workflowReferenceCount: 1,
      successfulRunCount: 7,
      requiredFailures: [],
      warnings: [],
      reran: false,
      exitCode: null
    },
    delta: {
      targetBranchChanged: classification === 'branch-target-drift',
      defaultBranchChanged: classification === 'branch-target-drift',
      workflowReferenceCountDelta: 1,
      successfulRunCountDelta: 7,
      reportedRequiredFailureIds: [],
      revalidatedRequiredFailureIds: [],
      clearedRequiredFailureIds: [],
      persistentRequiredFailureIds: [],
      newRequiredFailureIds: []
    },
    summary: {
      classification,
      status: suppressed ? 'suppressed' : 'actionable',
      suppressIssueInjection: suppressed,
      suppressDownstreamIssueInjection: suppressed,
      suppressTemplateIssueInjection: suppressed,
      recommendedOwnerRepository: ownerRepository,
      nextAction: classification === 'live-defect' ? 'route-live-downstream-defect' : 'reconcile-downstream-branch-target-provenance',
      reason:
        classification === 'live-defect'
          ? 'Live replay still blocks required onboarding checks.'
          : 'Live replay cleared the blockers after branch truth changed.'
    }
  };
}

function createWakeSynthesis({ classification, decision, workKind, recommendedOwnerRepository, governingRepository }) {
  return {
    schema: 'priority/wake-work-synthesis-report@v1',
    generatedAt: '2026-03-22T17:03:14.973Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/wake-work-synthesis.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    inputs: {
      wakeAdjudicationReportPath: 'tests/results/_agent/issue/wake-adjudication.json',
      repoGraphTruthPath: 'tests/results/_agent/handoff/downstream-repo-graph-truth.json'
    },
    wake: {
      classification,
      status: decision === 'monitor' ? 'monitoring' : decision === 'suppress' ? 'suppressed' : 'actionable',
      recommendedOwnerRepository,
      nextAction: decision,
      reason: 'Wake routed from synthesized repo graph truth.',
      suppressIssueInjection: classification !== 'live-defect',
      suppressDownstreamIssueInjection: classification !== 'live-defect',
      suppressTemplateIssueInjection: classification !== 'live-defect'
    },
    roles: {
      reportedRoleMatches: [],
      revalidatedRoleMatches: [],
      governingRole: {
        repositoryId: 'canonical-template',
        repository: governingRepository,
        repositoryKind: 'canonical-template',
        repositoryStatus: 'pass',
        roleId: 'template-consumer-proving-rail',
        role: classification === 'branch-target-drift' ? 'consumer-proving-rail' : 'canonical-development',
        branch: classification === 'branch-target-drift' ? 'downstream/develop' : 'develop',
        localRefAlias: null,
        required: classification !== 'branch-target-drift',
        roleStatus: classification === 'branch-target-drift' ? 'missing' : 'pass',
        relationshipStatus: classification === 'branch-target-drift' ? 'unknown' : null
      }
    },
    summary: {
      decision,
      status: decision === 'monitor' ? 'monitoring' : decision === 'suppress' ? 'suppressed' : 'actionable',
      workKind,
      recommendedOwnerRepository,
      reason: 'Wake routed from synthesized repo graph truth.',
      issueRouting: {
        compareGovernanceWork: decision === 'compare-governance-work',
        templateWork: decision === 'template-work',
        consumerProvingDriftWork: decision === 'consumer-proving-drift',
        investmentWork: decision === 'investment-work'
      }
    }
  };
}

function createAverageIssueCostScorecard({ issueNumber = 1816, totalUsd = 0.0201, benchmark = 0.5, includeIssue = true }) {
  const operatorLaborUsd = 10;
  const blendedTotalUsd = totalUsd + operatorLaborUsd;
  return {
    schema: 'priority/average-issue-cost-scorecard@v1',
    generatedAt: '2026-03-22T17:10:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      costRollupPath: { path: 'cost.json', exists: true, error: null },
      invoiceTurnPaths: []
    },
    coverage: {
      implementedMetricCodes: [],
      deferredMetrics: []
    },
    issueHydration: {
      status: 'pass',
      attempted: true,
      stateAttributionBasis: 'live',
      hydratedIssueCount: includeIssue ? 1 : 0,
      failedIssueNumbers: [],
      warnings: []
    },
    summary: {
      status: 'warn',
      recommendation: 'continue-estimated-telemetry',
      reasons: includeIssue ? ['estimated-spend-present'] : ['unattributed-turns-present'],
      blockerCount: 0,
      blockers: [],
      metrics: {
        observedFundingWindowCount: 1,
        distinctIssueCount: includeIssue ? 1 : 0,
        totalUsd,
        operatorLaborUsd,
        operatorLaborMissingTurnCount: 0,
        blendedTotalUsd,
        issueAttributedUsd: includeIssue ? totalUsd : 0,
        unattributedUsd: includeIssue ? 0 : totalUsd,
        exactUsd: 0,
        estimatedUsd: totalUsd,
        liveAgentUsd: totalUsd,
        backgroundAgentUsd: 0,
        hostedValidationUsd: 0,
        rollingAverageUsdPerIssue: benchmark,
        rollingAverageBlendedUsdPerIssue: benchmark + operatorLaborUsd,
        currentActiveWindowAverageUsdPerIssue: benchmark - 0.05,
        currentActiveWindowAverageBlendedUsdPerIssue: benchmark + operatorLaborUsd - 0.05,
        activeCalibrationWindowAverageUsdPerIssue: null,
        latestTrailingOperationalWindowAverageUsdPerIssue: benchmark + 0.05,
        latestTrailingOperationalWindowAverageBlendedUsdPerIssue: benchmark + operatorLaborUsd + 0.05,
        unattributedTurnCount: includeIssue ? 0 : 1
      }
    },
    stateAverages: [],
    windows: [],
    issues: includeIssue
      ? [
          {
            issueNumber,
            title: 'Wake synthesis issue',
            state: 'open',
            stateBucket: 'open-active',
            labels: ['governance'],
            url: 'https://example.test/issues/1816',
            totalUsd,
            operatorLaborUsd,
            operatorLaborMissingTurnCount: 0,
            blendedTotalUsd,
            exactUsd: 0,
            estimatedUsd: totalUsd,
            turnCount: 1,
            liveAgentUsd: totalUsd,
            backgroundAgentUsd: 0,
            hostedValidationUsd: 0,
            firstTurnAt: '2026-03-22T17:04:38.584Z',
            lastTurnAt: '2026-03-22T17:04:38.584Z',
            windowIds: ['invoice-turn-2026-03-HQ1VJLMV-0027'],
            invoiceTurnIds: ['invoice-turn-2026-03-HQ1VJLMV-0027'],
            turnIds: ['turn-1'],
            turnSourcePaths: ['tests/results/_agent/cost/turns/current-lane-heuristic.json'],
            sourceReceiptPaths: ['tests/results/_agent/cost/turns/current-lane-heuristic.json'],
            sourceReportPaths: ['tests/results/_agent/cost/agent-cost-rollup.json'],
            assignmentStrategies: ['billing-window-selected']
          }
        ]
      : []
  };
}

function createCostRollup({ issueNumbers = [1816] }) {
  return {
    schema: 'priority/agent-cost-rollup@v1',
    generatedAt: '2026-03-22T17:04:38.627Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      turnReportPaths: [],
      invoiceTurnPaths: [],
      usageExportPaths: [],
      accountBalancePaths: [],
      operatorSteeringEventPaths: [],
      selectedInvoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
      explicitInvoiceTurnId: null
    },
    turns: [],
    summary: {
      status: 'pass',
      recommendation: 'continue-estimated-telemetry',
      blockerCount: 0,
      blockers: [],
      metrics: {
        totalTurns: 1,
        exactTurnCount: 0,
        estimatedTurnCount: 1,
        totalUsd: 0.0201,
        exactUsd: 0,
        estimatedUsd: 0.0201,
        totalInputTokens: 2400,
        totalCachedInputTokens: 600,
        totalOutputTokens: 500,
        totalTokens: 3500,
        totalUsageUnits: 1,
        steeredTurnCount: 1,
        unsteeredTurnCount: 0,
        steeredUsd: 0.0201,
        unsteeredUsd: 0,
        estimatedCreditsConsumed: 0.5025,
        creditsRemaining: 9999.4975,
        estimatedPrepaidUsdRemaining: 399.9799,
        prepaidUsdConsumedRatio: 0.00005,
        actualUsdConsumed: null,
        actualCreditsConsumed: null,
        heuristicUsdDelta: null,
        heuristicUsdDeltaRatio: null,
        heuristicCreditsDelta: null,
        usageExportWindowCount: 3,
        usageExportCreditsReported: 45640.2,
        usageExportQuantityReported: 912804,
        operatorSteeringEventCount: 0,
        operatorSteeringFundingWindowMatchedCount: 0,
        operatorSteeringFundingWindowUnmatchedCount: 0,
        operatorSteeringIssueCount: 0,
        accountBalanceTotalCredits: 27500,
        accountBalanceUsedCredits: 15800,
        accountBalanceRemainingCredits: 11700
      },
      provenance: {
        sessionIds: ['session-1816'],
        issueNumbers,
        laneIds: ['issue/upstream-1816-wake-work-synthesis'],
        repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
        reasoningEfforts: ['xhigh'],
        steeringKinds: [],
        steeringSources: [],
        operatorSteeringTriggerKinds: [],
        rateCards: [],
        invoiceTurn: {
          sourcePath: 'tests/results/_agent/cost/invoice-turns/HQ1VJLMV-0027.local.json',
          invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
          invoiceId: 'HQ1VJLMV-0027',
          openedAt: '2026-03-21T10:01:07.000-07:00',
          closedAt: null,
          creditsPurchased: 10000,
          unitPriceUsd: 0.04,
          prepaidUsd: 400,
          pricingBasis: 'prepaid-credit',
          activationState: 'active',
          fundingPurpose: 'operational',
          reconciliationStatus: 'baseline-only',
          actualUsdConsumed: null,
          actualCreditsConsumed: null,
          reconciledAt: null,
          reconciliationSourceKind: null,
          reconciliationNote: null,
          sourceKind: 'operator-invoice',
          sourcePathEvidence: 'C:\\Users\\sveld\\Downloads\\Invoice-HQ1VJLMV-0027.pdf',
          operatorNote: 'Active operational funding window.',
          selection: {
            mode: 'hold',
            calibrationWindowId: null,
            reason: null
          }
        },
        invoiceTurnSelection: {
          strategy: 'active-window-latest-openedAt',
          explicitInvoiceTurnId: null,
          selectionObservedAt: '2026-03-22T17:04:38.584Z',
          candidateCount: 1,
          matchingCandidateCount: 1,
          candidateInvoiceTurnIds: ['invoice-turn-2026-03-HQ1VJLMV-0027'],
          selectedInvoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
          mode: 'hold',
          calibrationWindowId: null,
          reason: null
        }
      }
    },
    billingWindow: {
      invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
      invoiceId: 'HQ1VJLMV-0027',
      openedAt: '2026-03-21T10:01:07.000-07:00',
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

test('wake investment accounting prices compare-governance wake handling against the current issue benchmark', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-investment-accounting-governance-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const wakeAdjudicationPath = path.join(tmpDir, 'wake-adjudication.json');
  const wakeWorkSynthesisPath = path.join(tmpDir, 'wake-work-synthesis.json');
  const averageIssueCostPath = path.join(tmpDir, 'average-issue-cost-scorecard.json');
  const costRollupPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const outputPath = path.join(tmpDir, 'wake-investment-accounting.json');

  writeJson(policyPath, createPolicy());
  writeJson(
    wakeAdjudicationPath,
    createWakeAdjudication({
      classification: 'branch-target-drift',
      suppressed: true,
      ownerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    })
  );
  writeJson(
    wakeWorkSynthesisPath,
    createWakeSynthesis({
      classification: 'branch-target-drift',
      decision: 'compare-governance-work',
      workKind: 'drift-correction',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      governingRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    })
  );
  writeJson(averageIssueCostPath, createAverageIssueCostScorecard({ benchmark: 0.5 }));
  writeJson(costRollupPath, createCostRollup({ issueNumbers: [1816] }));

  const { report } = await runWakeInvestmentAccounting({
    repoRoot: tmpDir,
    policyPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    averageIssueCostScorecardPath: averageIssueCostPath,
    costRollupPath,
    outputPath
  });

  assert.equal(report.summary.accountingBucket, 'compare-governance-work');
  assert.equal(report.summary.status, 'warn');
  assert.equal(report.summary.recommendation, 'continue-estimated-telemetry');
  assert.equal(report.costBenchmark.selectedMetricCode, 'rollingAverageBlendedUsdPerIssue');
  assert.equal(report.costBenchmark.selectedBenchmarkUsd, 10.5);
  assert.equal(report.observedIssueCost.issueNumber, 1816);
  assert.equal(report.summary.metrics.observedWakeIssueUsd, 10.0201);
  assert.equal(report.summary.metrics.observedCostBasis, 'blended');
  assert.equal(report.summary.metrics.avoidedIssueBenchmarkUsd, 10.5);
  assert.equal(report.summary.metrics.netPaybackUsd, 0.4799);
  assert.equal(report.summary.paybackStatus, 'positive');
  assert.deepEqual(report.summary.paybackTriggerCodes, ['classification-eligible', 'owner-repository-mismatch', 'suppression-trigger']);
});

test('wake investment accounting stays warning-only when a live template wake has no observed issue cost yet', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-investment-accounting-template-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const wakeAdjudicationPath = path.join(tmpDir, 'wake-adjudication.json');
  const wakeWorkSynthesisPath = path.join(tmpDir, 'wake-work-synthesis.json');
  const averageIssueCostPath = path.join(tmpDir, 'average-issue-cost-scorecard.json');
  const costRollupPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const outputPath = path.join(tmpDir, 'wake-investment-accounting.json');

  writeJson(policyPath, createPolicy());
  writeJson(
    wakeAdjudicationPath,
    createWakeAdjudication({
      classification: 'live-defect',
      suppressed: false,
      ownerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    })
  );
  writeJson(
    wakeWorkSynthesisPath,
    createWakeSynthesis({
      classification: 'live-defect',
      decision: 'template-work',
      workKind: 'defect',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      governingRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    })
  );
  writeJson(averageIssueCostPath, createAverageIssueCostScorecard({ includeIssue: false, totalUsd: 0.02, benchmark: 0.75 }));
  writeJson(costRollupPath, createCostRollup({ issueNumbers: [] }));

  const { report } = await runWakeInvestmentAccounting({
    repoRoot: tmpDir,
    policyPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    averageIssueCostScorecardPath: averageIssueCostPath,
    costRollupPath,
    outputPath
  });

  assert.equal(report.summary.accountingBucket, 'template-work');
  assert.equal(report.summary.status, 'warn');
  assert.equal(report.summary.recommendation, 'continue-observing-wake-cost');
  assert.equal(report.observedIssueCost.issueNumber, null);
  assert.equal(report.summary.metrics.avoidedIssueBenchmarkUsd, null);
  assert.equal(report.summary.metrics.netPaybackUsd, null);
  assert.equal(report.summary.metrics.observedCostBasis, 'token-only');
  assert.equal(report.summary.paybackStatus, 'unresolved');
  assert.equal(report.summary.accountingConfidence, 'low');
});

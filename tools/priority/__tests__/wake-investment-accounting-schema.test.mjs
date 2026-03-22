import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runWakeInvestmentAccounting } from '../wake-investment-accounting.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function runSchemaValidate(repoRoot, schemaPath, dataPath) {
  execFileSync('node', ['tools/npm/run-script.mjs', 'schema:validate', '--', '--schema', schemaPath, '--data', dataPath], {
    cwd: repoRoot,
    stdio: 'pipe'
  });
}

test('wake investment accounting report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-investment-accounting-schema-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const wakeAdjudicationPath = path.join(tmpDir, 'wake-adjudication.json');
  const wakeWorkSynthesisPath = path.join(tmpDir, 'wake-work-synthesis.json');
  const averageIssueCostPath = path.join(tmpDir, 'average-issue-cost-scorecard.json');
  const costRollupPath = path.join(tmpDir, 'agent-cost-rollup.json');
  const outputPath = path.join(tmpDir, 'wake-investment-accounting.json');

  writeJson(policyPath, {
    schema: 'priority/wake-investment-accounting-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    benchmarkMetricPreference: [
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
  });
  writeJson(wakeAdjudicationPath, {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: '2026-03-22T17:03:14.724Z',
    wakeKind: 'downstream-onboarding',
    reported: {
      path: 'reported.json',
      generatedAt: '2026-03-22T15:29:06.702Z',
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      targetBranch: 'downstream/develop',
      defaultBranch: 'downstream/develop',
      summaryStatus: 'fail',
      requiredFailCount: 3,
      warningCount: 2,
      workflowReferenceCount: 0,
      successfulRunCount: 0,
      requiredFailures: [],
      warnings: []
    },
    revalidated: {
      path: 'revalidated.json',
      generatedAt: '2026-03-22T16:09:18.062Z',
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      targetBranch: 'develop',
      defaultBranch: 'develop',
      summaryStatus: 'warn',
      requiredFailCount: 0,
      warningCount: 2,
      workflowReferenceCount: 1,
      successfulRunCount: 7,
      requiredFailures: [],
      warnings: [],
      reran: false,
      exitCode: null
    },
    delta: {
      targetBranchChanged: true,
      defaultBranchChanged: true,
      workflowReferenceCountDelta: 1,
      successfulRunCountDelta: 7,
      reportedRequiredFailureIds: [],
      revalidatedRequiredFailureIds: [],
      clearedRequiredFailureIds: [],
      persistentRequiredFailureIds: [],
      newRequiredFailureIds: []
    },
    summary: {
      classification: 'branch-target-drift',
      status: 'suppressed',
      suppressIssueInjection: true,
      suppressDownstreamIssueInjection: true,
      suppressTemplateIssueInjection: true,
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'reconcile-downstream-branch-target-provenance',
      reason: 'Live replay cleared blockers after branch truth changed.'
    }
  });
  writeJson(wakeWorkSynthesisPath, {
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
      classification: 'branch-target-drift',
      status: 'actionable',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'compare-governance-work',
      reason: 'Wake routed from synthesized repo graph truth.',
      suppressIssueInjection: true,
      suppressDownstreamIssueInjection: true,
      suppressTemplateIssueInjection: true
    },
    roles: {
      reportedRoleMatches: [],
      revalidatedRoleMatches: [],
      governingRole: {
        repositoryId: 'canonical-template',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        repositoryKind: 'canonical-template',
        repositoryStatus: 'pass',
        roleId: 'template-consumer-proving-rail',
        role: 'consumer-proving-rail',
        branch: 'downstream/develop',
        localRefAlias: null,
        required: false,
        roleStatus: 'missing',
        relationshipStatus: 'unknown'
      }
    },
    summary: {
      decision: 'compare-governance-work',
      status: 'actionable',
      workKind: 'drift-correction',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      reason: 'Wake routed from synthesized repo graph truth.',
      issueRouting: {
        compareGovernanceWork: true,
        templateWork: false,
        consumerProvingDriftWork: false,
        investmentWork: false
      }
    }
  });
  writeJson(averageIssueCostPath, {
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
      hydratedIssueCount: 1,
      failedIssueNumbers: [],
      warnings: []
    },
    summary: {
      status: 'warn',
      recommendation: 'continue-estimated-telemetry',
      reasons: ['estimated-spend-present'],
      blockerCount: 0,
      blockers: [],
      metrics: {
        observedFundingWindowCount: 1,
        distinctIssueCount: 1,
        totalUsd: 0.0201,
        issueAttributedUsd: 0.0201,
        unattributedUsd: 0,
        exactUsd: 0,
        estimatedUsd: 0.0201,
        liveAgentUsd: 0.0201,
        backgroundAgentUsd: 0,
        hostedValidationUsd: 0,
        rollingAverageUsdPerIssue: 0.5,
        currentActiveWindowAverageUsdPerIssue: 0.45,
        activeCalibrationWindowAverageUsdPerIssue: null,
        latestTrailingOperationalWindowAverageUsdPerIssue: 0.55,
        unattributedTurnCount: 0
      }
    },
    stateAverages: [],
    windows: [],
    issues: [
      {
        issueNumber: 1816,
        title: 'Wake synthesis issue',
        state: 'open',
        stateBucket: 'open-active',
        labels: ['governance'],
        url: 'https://example.test/issues/1816',
        totalUsd: 0.0201,
        exactUsd: 0,
        estimatedUsd: 0.0201,
        turnCount: 1,
        liveAgentUsd: 0.0201,
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
  });
  writeJson(costRollupPath, {
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
        issueNumbers: [1816],
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
  });

  const { report } = await runWakeInvestmentAccounting({
    repoRoot: tmpDir,
    policyPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    averageIssueCostScorecardPath: averageIssueCostPath,
    costRollupPath,
    outputPath
  });

  runSchemaValidate(repoRoot, path.join(repoRoot, 'docs', 'schemas', 'wake-investment-accounting-report-v1.schema.json'), outputPath);
  assert.equal(report.schema, 'priority/wake-investment-accounting-report@v1');
});

test('checked-in wake investment accounting policy matches schema', () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  runSchemaValidate(
    repoRoot,
    path.join(repoRoot, 'docs', 'schemas', 'wake-investment-accounting-policy-v1.schema.json'),
    path.join(repoRoot, 'tools', 'policy', 'wake-investment-accounting.json')
  );
  assert.ok(true);
});

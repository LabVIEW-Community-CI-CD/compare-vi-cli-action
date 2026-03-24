import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { runMaterializeAgentCostRollup } from '../materialize-agent-cost-rollup.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createUsageExportPayload() {
  return {
    schema: 'priority/agent-cost-usage-export@v1',
    generatedAt: '2026-03-21T20:34:46.900Z',
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
    sourceKind: 'operator-private-usage-export-csv',
    sourcePathEvidence: 'usage-export.csv',
    operatorNote: 'Normalized from a local private account usage export CSV.'
  };
}

function createAccountBalancePayload() {
  return {
    schema: 'priority/agent-cost-account-balance@v1',
    generatedAt: '2026-03-21T20:35:10.743Z',
    effectiveAt: '2026-03-21T12:00:00.000Z',
    plan: {
      name: 'business',
      renewsAt: '2026-04-15T00:00:00.000Z'
    },
    balances: {
      totalCredits: 27500,
      usedCredits: 15800,
      remainingCredits: 11700
    },
    sourceKind: 'operator-account-state',
    sourcePathEvidence: 'operator-chat-snapshot-2026-03-21',
    operatorNote: 'Operator-provided business-plan balance snapshot on 2026-03-21.'
  };
}

function createInvoiceTurnPayload() {
  return {
    schema: 'priority/agent-cost-invoice-turn@v1',
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    invoiceId: 'HQ1VJLMV-0027',
    billingPeriod: {
      openedAt: '2026-03-21T10:01:07.000-07:00',
      closedAt: null
    },
    credits: {
      purchased: 10000,
      unitPriceUsd: 0.04
    },
    billing: {
      prepaidUsd: 400,
      pricingBasis: 'prepaid-credit'
    },
    policy: {
      activationState: 'active',
      fundingPurpose: 'operational'
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
      sourceKind: 'operator-invoice',
      sourcePath: 'C:/Users/operator/Downloads/Invoice-HQ1VJLMV-0027.pdf',
      operatorNote: 'Active operational funding window normalized from the first operator-provided invoice.'
    },
    selection: {
      mode: 'hold',
      calibrationWindowId: null,
      reason: null
    }
  };
}

function createOperatorSteeringEventPayload() {
  return {
    schema: 'priority/operator-steering-event@v1',
    generatedAt: '2026-03-22T05:44:18.180Z',
    eventKey: 'continuity-resume|1497|active-work-pending|2026-03-22T05:44:13.999Z|none',
    steeringKind: 'operator-prompt-resume',
    triggerKind: 'continuity-failure',
    provenance: {
      source: 'bootstrap-resume-detection'
    },
    issueContext: {
      observedAt: '2026-03-22T05:44:13.999Z'
    },
    continuity: {
      recommendation: 'keep the live lane active or hand the standing lane to a background worker before ending the turn'
    }
  };
}

function createLiveAgentModelSelectionPolicy() {
  return {
    schema: 'priority/live-agent-model-selection-policy@v1',
    mode: 'recommend-only',
    outputPath: 'tests/results/_agent/runtime/live-agent-model-selection.json',
    previousReportPath: 'tests/results/_agent/runtime/live-agent-model-selection.json',
    inputs: {
      costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
      throughputScorecardPath: 'tests/results/_agent/throughput/throughput-scorecard.json',
      deliveryMemoryPath: 'tests/results/_agent/runtime/delivery-memory.json'
    },
    evidenceWindow: {
      minLiveTurnCount: 1,
      minTerminalPullRequests: 1,
      confidenceThreshold: 'medium'
    },
    stability: {
      cooldownReports: 1,
      hysteresisScoreDelta: 0.5,
      holdCurrentOnCostOnly: true,
      performancePressureOverridesCooldown: true,
      throughputWarnEscalates: true,
      meanTerminalDurationWarningMinutes: 180,
      minMergeSuccessRatio: 0.6,
      maxHostedWaitEscapeCount: 0
    },
    providers: [
      {
        providerId: 'local-codex',
        agentRole: 'live',
        defaultModel: 'gpt-5.4',
        defaultReasoningEffort: 'xhigh',
        candidateModels: [
          {
            model: 'gpt-5.4',
            reasoningEffort: 'xhigh',
            strength: 3,
            costTier: 3,
            notes: 'Default RC live-agent tier.'
          }
        ]
      }
    ]
  };
}

function createMaterializationPolicy(discoveryRoot) {
  return {
    schema: 'priority/agent-cost-rollup-materialization-policy@v1',
    costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
    materializationReportPath: 'tests/results/_agent/cost/agent-cost-rollup-materialization.json',
    turnsDir: 'tests/results/_agent/cost/turns',
    heuristicTurnFileName: 'current-lane-heuristic.json',
    operatorSteeringEventPath: 'tests/results/_agent/runtime/operator-steering-event.json',
    repoFamilyPrefix: 'compare-vi-cli-action',
    discoveryRoots: [discoveryRoot],
    liveLaneHeuristic: {
      providerId: 'local-codex',
      providerKind: 'local-codex',
      providerRuntime: 'codex-cli',
      executionPlane: 'local',
      usage: {
        inputTokens: 2400,
        cachedInputTokens: 600,
        outputTokens: 500,
        usageUnitKind: 'turn',
        usageUnitCount: 1
      },
      rateCard: {
        id: 'openai-public-2026-03-01',
        source: 'https://openai.com/api/pricing',
        pricingBasis: 'per-1k-tokens',
        inputUsdPer1kTokens: 0.005,
        cachedInputUsdPer1kTokens: 0.001,
        outputUsdPer1kTokens: 0.015,
        usageUnitUsd: null
      }
    }
  };
}

function setupMaterializationFixture() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-materialization-'));
  const repoRoot = path.join(tempDir, 'repo');
  const discoveryRoot = path.join(tempDir, 'discovery');
  const donorRoot = path.join(discoveryRoot, 'compare-vi-cli-action-seed');

  writeJson(
    path.join(repoRoot, 'tools', 'policy', 'agent-cost-rollup-materialization.json'),
    createMaterializationPolicy(discoveryRoot)
  );
  writeJson(
    path.join(repoRoot, 'tools', 'policy', 'live-agent-model-selection.json'),
    createLiveAgentModelSelectionPolicy()
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'),
    createOperatorSteeringEventPayload()
  );

  writeJson(
    path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'invoice-turns', 'HQ1VJLMV-0027.local.json'),
    createInvoiceTurnPayload()
  );
  writeJson(
    path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'invoice-turns', 'HQ1VJLMV-0027.metadata.local.json'),
    {
      schema: 'priority/agent-cost-private-invoice-metadata@v1',
      invoiceId: 'HQ1VJLMV-0027'
    }
  );
  writeJson(
    path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'usage-exports', 'usage-export-2026-03-15.json'),
    createUsageExportPayload()
  );
  writeJson(
    path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'account-balances', 'account-balance-2026-03-21.json'),
    createAccountBalancePayload()
  );
  writeJson(
    path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'account-balances', 'account-balance-2026-03-21.private.local.json'),
    {
      schema: 'priority/agent-cost-private-account-balance@v1',
      balances: {
        totalCredits: 27500,
        usedCredits: 15800,
        remainingCredits: 11700
      }
    }
  );

  return { repoRoot };
}

test('runMaterializeAgentCostRollup materializes a heuristic turn and rollup in a fresh lane', () => {
  const { repoRoot } = setupMaterializationFixture();

  const result = runMaterializeAgentCostRollup({
    repoRoot,
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber: 1773,
    laneId: 'issue/origin-1773-materialize-cost-rollups-before-pr-spend',
    laneBranch: 'issue/origin-1773-materialize-cost-rollups-before-pr-spend'
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.materializedRollup, true);
  assert.equal(result.report.summary.materializedHeuristicTurn, true);
  assert.equal(result.report.syncedReceipts.invoiceTurns.materializedCount, 1);
  assert.equal(result.report.syncedReceipts.usageExports.materializedCount, 1);
  assert.equal(result.report.syncedReceipts.accountBalances.materializedCount, 1);
  assert.equal(
    result.report.syncedReceipts.invoiceTurns.files.some((entry) => entry.fileName.includes('.metadata.')),
    false
  );
  assert.equal(
    result.report.syncedReceipts.accountBalances.files.some((entry) => entry.fileName.includes('.private.')),
    false
  );
  assert.equal(result.report.heuristicTurn.requestedModel, 'gpt-5.4');
  assert.equal(fs.existsSync(result.outputPath), true);
  assert.equal(fs.existsSync(result.costRollupPath), true);
  assert.equal(fs.existsSync(result.heuristicTurnPath), true);
});

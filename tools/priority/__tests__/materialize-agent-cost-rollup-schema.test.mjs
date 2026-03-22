import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runMaterializeAgentCostRollup } from '../materialize-agent-cost-rollup.mjs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(process.cwd());

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function setupFixture() {
  const os = require('node:os');
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-materialization-schema-'));
  const workRoot = path.join(tempDir, 'repo');
  const discoveryRoot = path.join(tempDir, 'discovery');
  const donorRoot = path.join(discoveryRoot, 'compare-vi-cli-action-seed');

  writeJson(path.join(workRoot, 'tools', 'policy', 'agent-cost-rollup-materialization.json'), {
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
  });

  writeJson(path.join(workRoot, 'tools', 'policy', 'live-agent-model-selection.json'), {
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
  });

  writeJson(path.join(workRoot, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'), {
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
      recommendation: 'keep the live lane active'
    }
  });

  writeJson(path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'invoice-turns', 'HQ1VJLMV-0027.local.json'), {
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
  });

  writeJson(path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'usage-exports', 'usage-export-2026-03-15.json'), {
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
  });

  writeJson(path.join(donorRoot, 'tests', 'results', '_agent', 'cost', 'account-balances', 'account-balance-2026-03-21.json'), {
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
  });

  return { workRoot };
}

test('agent-cost-rollup-materialization report matches its schema', () => {
  const { workRoot } = setupFixture();
  const result = runMaterializeAgentCostRollup({
    repoRoot: workRoot,
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber: 1773,
    laneId: 'issue/origin-1773-materialize-cost-rollups-before-pr-spend',
    laneBranch: 'issue/origin-1773-materialize-cost-rollups-before-pr-spend'
  });

  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-rollup-materialization-report-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(result.report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

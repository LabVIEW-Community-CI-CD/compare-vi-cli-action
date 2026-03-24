import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runAutonomousGovernorSummary } from '../autonomous-governor-summary.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function toGlobPath(filePath) {
  return path.resolve(filePath).replace(/\\/g, '/');
}

function resolveValidatorRepoRoot(repoRoot) {
  const localValidatorOk =
    fs.existsSync(path.join(repoRoot, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'ajv', 'package.json')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'argparse', 'package.json'));
  if (localValidatorOk) {
    return repoRoot;
  }
  const candidates = [
    path.resolve(repoRoot, '..', 'compare-monitoring-canonical'),
    path.resolve(repoRoot, '..', '1843-wake-lifecycle-state-machine')
  ];
  return (
    candidates.find(
      (candidate) =>
        fs.existsSync(path.join(candidate, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'ajv', 'package.json')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'argparse', 'package.json'))
    ) || repoRoot
  );
}

function runSchemaValidate(repoRoot, schemaPath, dataPath) {
  const validatorRepoRoot = resolveValidatorRepoRoot(repoRoot);
  execFileSync('node', ['dist/tools/schemas/validate-json.js', '--schema', toGlobPath(schemaPath), '--data', toGlobPath(dataPath)], {
    cwd: validatorRepoRoot,
    stdio: 'pipe'
  });
}

test('autonomous governor summary report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-schema-'));

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 11
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), {
    schema: 'priority/continuity-telemetry-report@v1',
    status: 'maintained',
    continuity: {
      turnBoundary: {
        status: 'safe-idle',
        supervisionState: 'safe-idle',
        operatorPromptRequiredToResume: false
      }
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), {
    schema: 'agent-handoff/monitoring-mode-v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    compare: {
      queueState: { status: 'queue-empty', detail: 'queue-empty', ready: true },
      continuity: { status: 'maintained', detail: 'safe-idle', ready: true }
    },
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'), {
    schema: 'priority/delivery-agent-runtime-state@v1',
    status: 'waiting-ci',
    laneLifecycle: 'waiting-ci',
    activeLane: {
      issue: 1863,
      prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864',
      laneLifecycle: 'waiting-ci',
      actionType: 'merge-pr',
      outcome: 'waiting-ci',
      blockerClass: 'none',
      nextWakeCondition: 'checks-green',
      reason: 'Waiting for hosted checks to finish before merge queue advances.'
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'cost', 'treasury-control-plane.json'), {
    schema: 'priority/treasury-control-plane@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      status: 'warn',
      recommendation: 'constrain-spend-to-core-delivery',
      confidence: 'lower-bound-only',
      spendPolicyState: 'core-delivery-only',
      budgetPressureState: 'tight',
      tokenSpendUsd: 12.5,
      operatorLaborObservedUsd: 30,
      operatorLaborMissingTurnCount: 1,
      observedBlendedLowerBoundUsd: 42.5,
      knownBlendedUsd: null,
      protectedReserveUsd: 100,
      accountRemainingUsdEstimate: 166,
      operationalHeadroomUsd: 66,
      operationalHeadroomStatus: 'reserve-near',
      safeSpendableUsd: 66,
      possibleSpendableUpperBoundUsd: 66,
      sourceConflictCount: 0,
      operatorBudgetCapUsd: 50000,
      operatorBudgetObservedRemainingUpperBoundUsd: 49970,
      operatorBudgetObservedRemainingStatus: 'upper-bound',
      operatorBudgetRemainingLowerBoundUsd: null,
      operatorBudgetRemainingStatus: 'unknown',
      operatorBudgetSpendableUsd: null,
      operatorBudgetSpendableStatus: 'unreconciled',
      premiumSaganAllowed: false,
      backgroundFanoutAllowed: false,
      maxBackgroundSubagents: 0,
      nonEssentialWorkAllowed: false,
      calibrationReserveProtected: true
    },
    turns: {
      totalTurns: 3,
      liveTurnCount: 1,
      backgroundTurnCount: 2
    },
    funding: {
      billingWindow: {
        invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
        invoiceId: 'HQ1VJLMV-0027',
        fundingPurpose: 'operational',
        activationState: 'active',
        prepaidUsd: 400,
        tokenSpendUsd: 12.5,
        remainingUsd: 387.5,
        pricingBasis: 'prepaid-credit',
        selectionMode: 'hold',
        selectionReason: 'Calibration funding window remains on hold before activation.'
      },
      accountBalance: {
        totalCredits: 28750,
        usedCredits: 24600,
        remainingCredits: 4150,
        unitPriceUsd: 0.04,
        remainingUsdEstimate: 166,
        sourceKind: 'operator-account-state',
        sourcePathEvidence: 'operator-account-state.json',
        operatorNote: 'Latest operator-provided balance snapshot.'
      },
      reservedFunding: {
        count: 1,
        totalReservedUsd: 100,
        windows: [
          {
            invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0028',
            invoiceId: 'HQ1VJLMV-0028',
            fundingPurpose: 'calibration',
            activationState: 'hold',
            prepaidUsd: 100,
            operatorNote: 'Reserved calibration window.'
          }
        ]
      }
    },
    controls: {
      premiumSaganMode: {
        allowed: false,
        requiresOperatorAuthorization: true,
        minimumOperationalHeadroomUsd: 150,
        reason: 'budget-tight'
      },
      backgroundFanout: {
        allowed: false,
        minimumOperationalHeadroomUsd: 125,
        maximumConcurrentSubagents: 0,
        reason: 'budget-tight'
      },
      nonEssentialWork: {
        allowed: false,
        minimumOperationalHeadroomUsd: 100,
        reason: 'budget-tight'
      }
    },
    source: {
      policyPath: 'tools/policy/treasury-control-plane.json',
      costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
      costRollupMaterialized: true,
      costRollupMaterializationReportPath: 'tests/results/_agent/cost/agent-cost-rollup-materialization.json',
      operatorCostProfilePath: 'tools/policy/operator-cost-profile.json',
      outputPath: 'tests/results/_agent/cost/treasury-control-plane.json'
    },
    blockers: []
  });

  const outputPath = path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json');
  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir, outputPath });

  runSchemaValidate(repoRoot, path.join(repoRoot, 'docs', 'schemas', 'autonomous-governor-summary-report-v1.schema.json'), outputPath);
  assert.equal(report.schema, 'priority/autonomous-governor-summary-report@v1');
  assert.equal(report.summary.treasurySafeSpendableUsd, 66);
});

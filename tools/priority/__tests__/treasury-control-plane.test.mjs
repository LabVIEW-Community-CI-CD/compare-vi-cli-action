import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { runTreasuryControlPlane } from '../treasury-control-plane.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createRollupFixture({ operatorLaborMissingTurnCount = 1 } = {}) {
  return {
    schema: 'priority/agent-cost-rollup@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      metrics: {
        totalTurns: 3,
        liveTurnCount: 1,
        backgroundTurnCount: 2,
        totalUsd: 12.5,
        operatorLaborUsd: 30,
        operatorLaborMissingTurnCount,
        blendedTotalUsd: null,
        estimatedPrepaidUsdRemaining: 387.5,
        accountBalanceTotalCredits: 28750,
        accountBalanceUsedCredits: 24600,
        accountBalanceRemainingCredits: 4150
      },
      provenance: {
        operatorProfiles: [
          {
            operatorProfilePath: 'tools/policy/operator-cost-profile.json'
          }
        ],
        invoiceTurn: {
          unitPriceUsd: 0.04
        },
        accountBalance: {
          sourceKind: 'operator-account-state',
          sourcePathEvidence: 'operator-account-state.json',
          operatorNote: 'Latest operator-provided balance snapshot.'
        },
        invoiceTurns: [
          {
            invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
            invoiceId: 'HQ1VJLMV-0027',
            fundingPurpose: 'operational',
            activationState: 'active',
            prepaidUsd: 400,
            operatorNote: 'Operational window.'
          },
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
    billingWindow: {
      invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
      invoiceId: 'HQ1VJLMV-0027',
      fundingPurpose: 'operational',
      activationState: 'active',
      prepaidUsd: 400,
      pricingBasis: 'prepaid-credit',
      selection: {
        mode: 'hold',
        reason: 'Calibration funding window remains on hold before activation.'
      }
    }
  };
}

test('runTreasuryControlPlane produces a governed lower-bound treasury state when operator timing is incomplete', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-control-plane-'));
  const repoRoot = path.join(tempDir, 'repo');
  fs.mkdirSync(repoRoot, { recursive: true });

  const policyPath = path.join(repoRoot, 'tools', 'policy', 'treasury-control-plane.json');
  writeJson(policyPath, {
    schema: 'priority/treasury-control-plane-policy@v1',
    costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
    materializationPolicyPath: 'tools/policy/agent-cost-rollup-materialization.json',
    materializationReportPath: 'tests/results/_agent/cost/agent-cost-rollup-materialization.json',
    outputPath: 'tests/results/_agent/cost/treasury-control-plane.json',
    operatorBudgetCapUsd: 50000,
    materializeCostRollup: true,
    reservedFundingPurposes: ['calibration'],
    reservedActivationStates: ['hold'],
    thresholds: {
      reserveNearOperationalHeadroomUsd: 100,
      healthyOperationalHeadroomUsd: 250,
      premiumSaganMinimumOperationalHeadroomUsd: 150,
      backgroundFanoutMinimumOperationalHeadroomUsd: 125,
      nonEssentialWorkMinimumOperationalHeadroomUsd: 100
    },
    limits: {
      healthyBackgroundSubagentsMax: 2,
      cautiousBackgroundSubagentsMax: 1
    }
  });

  const result = runTreasuryControlPlane(
    {
      repoRoot,
      policyPath
    },
    {
      runMaterializeAgentCostRollupFn: ({ costRollupPath, outputPath }) => {
        writeJson(costRollupPath, createRollupFixture());
        writeJson(outputPath, {
          schema: 'priority/agent-cost-rollup-materialization@v1',
          summary: { status: 'pass' }
        });
        return {
          costRollupPath,
          outputPath
        };
      }
    }
  );

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.confidence, 'lower-bound-only');
  assert.equal(result.report.summary.spendPolicyState, 'core-delivery-only');
  assert.equal(result.report.summary.budgetPressureState, 'tight');
  assert.equal(result.report.summary.protectedReserveUsd, 100);
  assert.equal(result.report.summary.accountRemainingUsdEstimate, 166);
  assert.equal(result.report.summary.operationalHeadroomUsd, 66);
  assert.equal(result.report.summary.safeSpendableUsd, 66);
  assert.equal(result.report.summary.operatorBudgetObservedRemainingUpperBoundUsd, 49970);
  assert.equal(result.report.summary.operatorBudgetObservedRemainingStatus, 'upper-bound');
  assert.equal(result.report.summary.operatorBudgetRemainingLowerBoundUsd, null);
  assert.equal(result.report.summary.operatorBudgetRemainingStatus, 'unknown');
  assert.equal(result.report.summary.operatorBudgetSpendableUsd, null);
  assert.equal(result.report.summary.operatorBudgetSpendableStatus, 'unreconciled');
  assert.equal(result.report.summary.premiumSaganAllowed, false);
  assert.equal(result.report.summary.backgroundFanoutAllowed, false);
  assert.equal(result.report.summary.maxBackgroundSubagents, 0);
  assert.equal(result.report.summary.nonEssentialWorkAllowed, false);
  assert.equal(result.report.controls.premiumSaganMode.requiresOperatorAuthorization, true);
  assert.equal(result.report.funding.reservedFunding.totalReservedUsd, 100);
});

test('runTreasuryControlPlane allows healthier expansion only when operator timing is fully observed', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-control-plane-healthy-'));
  const repoRoot = path.join(tempDir, 'repo');
  fs.mkdirSync(repoRoot, { recursive: true });

  const policyPath = path.join(repoRoot, 'tools', 'policy', 'treasury-control-plane.json');
  writeJson(policyPath, {
    schema: 'priority/treasury-control-plane-policy@v1',
    costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
    materializationPolicyPath: 'tools/policy/agent-cost-rollup-materialization.json',
    materializationReportPath: 'tests/results/_agent/cost/agent-cost-rollup-materialization.json',
    outputPath: 'tests/results/_agent/cost/treasury-control-plane.json',
    operatorBudgetCapUsd: 50000,
    materializeCostRollup: true,
    reservedFundingPurposes: ['calibration'],
    reservedActivationStates: ['hold'],
    thresholds: {
      reserveNearOperationalHeadroomUsd: 100,
      healthyOperationalHeadroomUsd: 250,
      premiumSaganMinimumOperationalHeadroomUsd: 150,
      backgroundFanoutMinimumOperationalHeadroomUsd: 125,
      nonEssentialWorkMinimumOperationalHeadroomUsd: 100
    },
    limits: {
      healthyBackgroundSubagentsMax: 2,
      cautiousBackgroundSubagentsMax: 1
    }
  });

  const result = runTreasuryControlPlane(
    {
      repoRoot,
      policyPath
    },
    {
      runMaterializeAgentCostRollupFn: ({ costRollupPath, outputPath }) => {
        const rollup = createRollupFixture({ operatorLaborMissingTurnCount: 0 });
        rollup.summary.metrics.accountBalanceRemainingCredits = 10000;
        writeJson(costRollupPath, rollup);
        writeJson(outputPath, {
          schema: 'priority/agent-cost-rollup-materialization@v1',
          summary: { status: 'pass' }
        });
        return {
          costRollupPath,
          outputPath
        };
      }
    }
  );

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.confidence, 'observed');
  assert.equal(result.report.summary.budgetPressureState, 'healthy');
  assert.equal(result.report.summary.spendPolicyState, 'healthy');
  assert.equal(result.report.summary.operationalHeadroomUsd, 300);
  assert.equal(result.report.summary.safeSpendableUsd, 300);
  assert.equal(result.report.summary.operatorBudgetRemainingLowerBoundUsd, 49970);
  assert.equal(result.report.summary.operatorBudgetRemainingStatus, 'observed');
  assert.equal(result.report.summary.operatorBudgetSpendableUsd, 49970);
  assert.equal(result.report.summary.operatorBudgetSpendableStatus, 'observed');
  assert.equal(result.report.summary.premiumSaganAllowed, true);
  assert.equal(result.report.summary.backgroundFanoutAllowed, true);
  assert.equal(result.report.summary.maxBackgroundSubagents, 2);
  assert.equal(result.report.summary.nonEssentialWorkAllowed, true);
});

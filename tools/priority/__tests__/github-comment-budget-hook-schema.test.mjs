import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runGitHubCommentBudgetHook } from '../github-comment-budget-hook.mjs';

const repoRoot = path.resolve(process.cwd());

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('github-comment-budget-hook report and policy validate against checked-in schemas', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'github-comment-budget-hook-schema-'));
  const repo = path.join(tempDir, 'repo');
  const policyPath = path.join(repo, 'tools', 'policy', 'github-comment-budget-hook.json');
  writeJson(policyPath, {
    schema: 'priority/github-comment-budget-hook-policy@v1',
    treasuryPolicyPath: 'tools/policy/treasury-control-plane.json',
    costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
    materializationPolicyPath: 'tools/policy/agent-cost-rollup-materialization.json',
    materializationReportPath: 'tests/results/_agent/cost/agent-cost-rollup-materialization.json',
    outputPath: 'tests/results/_agent/cost/github-comment-budget-hook.json',
    markdownOutputPath: 'tests/results/_agent/cost/github-comment-budget-hook.md',
    operatorBudgetCapUsd: 50000,
    materializeCostRollup: true,
    reservedFundingPurposes: ['calibration'],
    reservedActivationStates: ['hold']
  });

  const { report } = runGitHubCommentBudgetHook(
    {
      repoRoot: repo,
      policyPath,
      targetKind: 'pr',
      targetNumber: 1908
    },
    {
      runTreasuryControlPlaneFn: () => ({
        report: {
          schema: 'priority/treasury-control-plane@v1',
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          summary: {
            status: 'pass',
            recommendation: 'treasury-control-plane-ready',
            confidence: 'observed',
            spendPolicyState: 'healthy',
            budgetPressureState: 'healthy',
            tokenSpendUsd: 1.5,
            operatorLaborObservedUsd: 4,
            operatorLaborMissingTurnCount: 0,
            observedBlendedLowerBoundUsd: 5.5,
            knownBlendedUsd: 5.5,
            protectedReserveUsd: 0,
            accountRemainingUsdEstimate: 400,
            operationalHeadroomUsd: 400,
            operationalHeadroomStatus: 'healthy',
            safeSpendableUsd: 400,
            possibleSpendableUpperBoundUsd: 400,
            sourceConflictCount: 0,
            operatorBudgetCapUsd: 50000,
            operatorBudgetObservedRemainingUpperBoundUsd: 49996,
            operatorBudgetObservedRemainingStatus: 'observed',
            operatorBudgetRemainingLowerBoundUsd: 49996,
            operatorBudgetRemainingStatus: 'observed',
            operatorBudgetSpendableUsd: 49996,
            operatorBudgetSpendableStatus: 'observed',
            premiumSaganAllowed: true,
            backgroundFanoutAllowed: true,
            maxBackgroundSubagents: 2,
            nonEssentialWorkAllowed: true,
            calibrationReserveProtected: false
          },
          turns: {
            totalTurns: 1,
            liveTurnCount: 0,
            backgroundTurnCount: 1
          },
          funding: {
            billingWindow: {
              invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
              invoiceId: 'HQ1VJLMV-0027',
              fundingPurpose: 'operational',
              activationState: 'active',
              prepaidUsd: 400,
              tokenSpendUsd: 1.5,
              remainingUsd: 398.5,
              pricingBasis: 'prepaid-credit',
              selectionMode: 'hold',
              selectionReason: null
            },
            accountBalance: {
              totalCredits: 28750,
              usedCredits: 18750,
              remainingCredits: 10000,
              unitPriceUsd: 0.04,
              remainingUsdEstimate: 400,
              sourceKind: 'operator-account-state',
              sourcePathEvidence: 'operator-account-state.json',
              operatorNote: 'Latest operator-provided balance snapshot.'
            },
            reservedFunding: {
              count: 0,
              totalReservedUsd: 0,
              windows: []
            }
          },
          controls: {
            premiumSaganMode: {
              allowed: true,
              requiresOperatorAuthorization: true,
              minimumOperationalHeadroomUsd: 150,
              reason: 'budget-healthy'
            },
            backgroundFanout: {
              allowed: true,
              minimumOperationalHeadroomUsd: 125,
              maximumConcurrentSubagents: 2,
              reason: 'budget-healthy'
            },
            nonEssentialWork: {
              allowed: true,
              minimumOperationalHeadroomUsd: 100,
              reason: 'budget-healthy'
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
        }
      })
    }
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validatePolicy = ajv.compile(readJson(path.join(repoRoot, 'docs', 'schemas', 'github-comment-budget-hook-policy-v1.schema.json')));
  const validateReport = ajv.compile(readJson(path.join(repoRoot, 'docs', 'schemas', 'github-comment-budget-hook-report-v1.schema.json')));

  assert.equal(validatePolicy(readJson(policyPath)), true, JSON.stringify(validatePolicy.errors, null, 2));
  assert.equal(validateReport(report), true, JSON.stringify(validateReport.errors, null, 2));
});

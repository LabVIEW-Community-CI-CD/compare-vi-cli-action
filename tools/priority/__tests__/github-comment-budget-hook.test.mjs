import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  COMMENT_HOOK_END_MARKER,
  COMMENT_HOOK_START_MARKER,
  appendBudgetHook,
  runGitHubCommentBudgetHook,
  stripExistingBudgetHook
} from '../github-comment-budget-hook.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createTreasuryReportFixture() {
  return {
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
  };
}

test('stripExistingBudgetHook removes the previous budget block cleanly', () => {
  const original = ['Intro line', '', COMMENT_HOOK_START_MARKER, 'old hook', COMMENT_HOOK_END_MARKER, '', 'Tail line'].join('\n');
  assert.equal(stripExistingBudgetHook(original), 'Intro line\n\nTail line');
});

test('appendBudgetHook appends exactly one hook block', () => {
  const hook = `${COMMENT_HOOK_START_MARKER}\nHook\n${COMMENT_HOOK_END_MARKER}`;
  const once = appendBudgetHook('Hello', hook);
  const twice = appendBudgetHook(once, hook);
  assert.equal(once, twice);
  assert.match(twice, /Hello/);
  assert.match(twice, new RegExp(COMMENT_HOOK_START_MARKER.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('runGitHubCommentBudgetHook projects the treasury control plane into a durable comment hook', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'github-comment-budget-hook-'));
  const repoRoot = path.join(tempDir, 'repo');
  fs.mkdirSync(repoRoot, { recursive: true });
  const policyPath = path.join(repoRoot, 'tools', 'policy', 'github-comment-budget-hook.json');
  const outputPath = path.join(repoRoot, 'tests', 'results', '_agent', 'cost', 'github-comment-budget-hook.json');
  const markdownOutputPath = path.join(repoRoot, 'tests', 'results', '_agent', 'cost', 'github-comment-budget-hook.md');

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

  const result = runGitHubCommentBudgetHook(
    {
      repoRoot,
      policyPath,
      targetKind: 'issue',
      targetNumber: 1907
    },
    {
      runTreasuryControlPlaneFn: () => ({
        report: createTreasuryReportFixture()
      })
    }
  );

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.operatorBudgetCapUsd, 50000);
  assert.equal(result.report.summary.operatorBudgetObservedRemainingUpperBoundUsd, 49970);
  assert.equal(result.report.summary.operatorBudgetObservedRemainingStatus, 'upper-bound');
  assert.equal(result.report.summary.operatorBudgetRemainingLowerBoundUsd, null);
  assert.equal(result.report.summary.operatorBudgetRemainingStatus, 'unknown');
  assert.equal(result.report.summary.operatorBudgetSpendableStatus, 'unreconciled');
  assert.equal(result.report.summary.operatorBudgetSpendableUsd, null);
  assert.equal(result.report.summary.observedBlendedLowerBoundUsd, 42.5);
  assert.equal(result.report.summary.accountRemainingUsdEstimate, 166);
  assert.equal(result.report.summary.operationalHeadroomUsd, 66);
  assert.equal(result.report.summary.safeSpendableUsd, 66);
  assert.equal(result.report.summary.treasuryConfidence, 'lower-bound-only');
  assert.equal(result.report.summary.treasurySpendPolicyState, 'core-delivery-only');
  assert.equal(result.report.summary.premiumSaganAllowed, false);
  assert.equal(result.report.summary.backgroundFanoutAllowed, false);
  assert.equal(result.report.summary.maxBackgroundSubagents, 0);
  assert.equal(result.report.summary.nonEssentialWorkAllowed, false);
  assert.equal(result.report.summary.budgetPressureState, 'tight');
  assert.equal(result.report.turns.backgroundTurnCount, 2);
  assert.equal(result.report.funding.accountBalance.remainingCredits, 4150);
  assert.equal(result.report.funding.accountBalance.remainingUsdEstimate, 166);
  assert.equal(result.report.funding.reservedFunding.count, 1);
  assert.equal(result.report.funding.reservedFunding.totalReservedUsd, 100);
  assert.equal(fs.existsSync(outputPath), true);
  assert.equal(fs.existsSync(markdownOutputPath), true);
  assert.match(result.markdown, /blended lower bound \$42\.500000/);
  assert.match(result.markdown, /observed upper bound \$49970\.000000/);
  assert.match(result.markdown, /safe spend \$66\.000000/);
  assert.match(result.markdown, /treasury core-delivery-only \(lower-bound-only\)/);
  assert.match(result.markdown, /calibration reserve \$100\.000000/);
});

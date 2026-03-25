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

function createRollupFixture() {
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
        operatorLaborMissingTurnCount: 1,
        blendedTotalUsd: null,
        estimatedPrepaidUsdRemaining: 387.5
      },
      provenance: {
        operatorProfiles: [
          {
            operatorProfilePath: 'tools/policy/operator-cost-profile.json'
          }
        ],
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

test('runGitHubCommentBudgetHook emits a durable lower-bound budget hook with reserved calibration context', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'github-comment-budget-hook-'));
  const repoRoot = path.join(tempDir, 'repo');
  fs.mkdirSync(repoRoot, { recursive: true });
  const policyPath = path.join(repoRoot, 'tools', 'policy', 'github-comment-budget-hook.json');
  const outputPath = path.join(repoRoot, 'tests', 'results', '_agent', 'cost', 'github-comment-budget-hook.json');
  const markdownOutputPath = path.join(repoRoot, 'tests', 'results', '_agent', 'cost', 'github-comment-budget-hook.md');
  const rollupPath = path.join(repoRoot, 'tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');

  writeJson(policyPath, {
    schema: 'priority/github-comment-budget-hook-policy@v1',
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
      runMaterializeAgentCostRollupFn: ({ costRollupPath, outputPath: materializationPath }) => {
        writeJson(costRollupPath, createRollupFixture());
        writeJson(materializationPath, {
          schema: 'priority/agent-cost-rollup-materialization@v1',
          summary: { status: 'pass' }
        });
        return {
          costRollupPath,
          outputPath: materializationPath
        };
      }
    }
  );

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.operatorBudgetCapUsd, 50000);
  assert.equal(result.report.summary.operatorBudgetRemainingStatus, 'lower-bound');
  assert.equal(result.report.summary.observedBlendedLowerBoundUsd, 42.5);
  assert.equal(result.report.turns.backgroundTurnCount, 2);
  assert.equal(result.report.funding.reservedFunding.count, 1);
  assert.equal(result.report.funding.reservedFunding.totalReservedUsd, 100);
  assert.equal(fs.existsSync(outputPath), true);
  assert.equal(fs.existsSync(markdownOutputPath), true);
  assert.match(result.markdown, /blended lower bound \$42\.500000/);
  assert.match(result.markdown, /calibration reserve \$100\.000000/);
});

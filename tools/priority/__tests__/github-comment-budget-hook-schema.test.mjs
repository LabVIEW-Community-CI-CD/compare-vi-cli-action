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
      runMaterializeAgentCostRollupFn: ({ costRollupPath, outputPath }) => {
        writeJson(costRollupPath, {
          schema: 'priority/agent-cost-rollup@v1',
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          summary: {
            metrics: {
              totalTurns: 1,
              liveTurnCount: 0,
              backgroundTurnCount: 1,
              totalUsd: 1.5,
              operatorLaborUsd: 4,
              operatorLaborMissingTurnCount: 0,
              blendedTotalUsd: 5.5,
              estimatedPrepaidUsdRemaining: 398.5,
              accountBalanceTotalCredits: 28750,
              accountBalanceUsedCredits: 24600,
              accountBalanceRemainingCredits: 4150
            },
            provenance: {
              operatorProfiles: [{ operatorProfilePath: 'tools/policy/operator-cost-profile.json' }],
              invoiceTurn: {
                unitPriceUsd: 0.04
              },
              accountBalance: {
                sourceKind: 'operator-account-state',
                sourcePathEvidence: 'operator-account-state.json',
                operatorNote: 'Latest operator-provided balance snapshot.'
              },
              invoiceTurns: []
            }
          },
          billingWindow: {
            invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
            invoiceId: 'HQ1VJLMV-0027',
            fundingPurpose: 'operational',
            activationState: 'active',
            prepaidUsd: 400,
            pricingBasis: 'prepaid-credit',
            selection: { mode: 'hold', reason: null }
          }
        });
        writeJson(outputPath, { schema: 'priority/agent-cost-rollup-materialization@v1', summary: { status: 'pass' } });
        return { costRollupPath, outputPath };
      }
    }
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validatePolicy = ajv.compile(readJson(path.join(repoRoot, 'docs', 'schemas', 'github-comment-budget-hook-policy-v1.schema.json')));
  const validateReport = ajv.compile(readJson(path.join(repoRoot, 'docs', 'schemas', 'github-comment-budget-hook-report-v1.schema.json')));

  assert.equal(validatePolicy(readJson(policyPath)), true, JSON.stringify(validatePolicy.errors, null, 2));
  assert.equal(validateReport(report), true, JSON.stringify(validateReport.errors, null, 2));
});

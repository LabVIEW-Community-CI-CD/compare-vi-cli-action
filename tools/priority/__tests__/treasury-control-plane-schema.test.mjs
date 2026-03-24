import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runTreasuryControlPlane } from '../treasury-control-plane.mjs';

const repoRoot = path.resolve(process.cwd());

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('treasury-control-plane policy and report validate against checked-in schemas', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-control-plane-schema-'));
  const repo = path.join(tempDir, 'repo');
  const policyPath = path.join(repo, 'tools', 'policy', 'treasury-control-plane.json');

  writeJson(policyPath, {
    schema: 'priority/treasury-control-plane-policy@v2',
    costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
    materializationPolicyPath: 'tools/policy/agent-cost-rollup-materialization.json',
    materializationReportPath: 'tests/results/_agent/cost/agent-cost-rollup-materialization.json',
    outputPath: 'tests/results/_agent/cost/treasury-control-plane.json',
    operatorBudgetCapUsd: 50000,
    materializeCostRollup: true,
    reservedFundingPurposes: ['calibration'],
    reservedActivationStates: ['hold'],
    thresholds: {
      accountBalanceMaxAgeHours: 24,
      reserveNearOperationalHeadroomUsd: 100,
      healthyOperationalHeadroomUsd: 250,
      premiumSaganMinimumOperationalHeadroomUsd: 150,
      backgroundFanoutMinimumOperationalHeadroomUsd: 125,
      nonEssentialWorkMinimumOperationalHeadroomUsd: 100
    },
    limits: {
      healthyBackgroundSubagentsMax: 2,
      cautiousBackgroundSubagentsMax: 1,
      premiumSaganFollowupAuthorizationsEstimate: 1
    }
  });

  const { report } = runTreasuryControlPlane(
    {
      repoRoot: repo,
      policyPath
    },
    {
      runMaterializeAgentCostRollupFn: ({ costRollupPath, outputPath }) => {
        writeJson(costRollupPath, {
          schema: 'priority/agent-cost-rollup@v1',
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          summary: {
            metrics: {
              totalTurns: 1,
              liveTurnCount: 1,
              backgroundTurnCount: 0,
              totalUsd: 1.5,
              operatorLaborUsd: 4,
              operatorLaborMissingTurnCount: 0,
              blendedTotalUsd: 5.5,
              estimatedPrepaidUsdRemaining: 398.5,
              accountBalanceTotalCredits: 28750,
              accountBalanceUsedCredits: 18750,
              accountBalanceRemainingCredits: 10000
            },
            provenance: {
              operatorProfiles: [{ operatorProfilePath: 'tools/policy/operator-cost-profile.json' }],
              invoiceTurn: {
                unitPriceUsd: 0.04
              },
              accountBalance: {
                snapshotAt: '2026-03-24T08:00:00.000Z',
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
            selection: { mode: 'hold', reason: null }
          }
        });
        writeJson(outputPath, { schema: 'priority/agent-cost-rollup-materialization@v1', summary: { status: 'pass' } });
        return { costRollupPath, outputPath };
      },
      now: new Date('2026-03-24T12:00:00.000Z')
    }
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validatePolicy = ajv.compile(readJson(path.join(repoRoot, 'docs', 'schemas', 'treasury-control-plane-policy-v2.schema.json')));
  const validateReport = ajv.compile(readJson(path.join(repoRoot, 'docs', 'schemas', 'treasury-control-plane-report-v2.schema.json')));

  assert.equal(validatePolicy(readJson(policyPath)), true, JSON.stringify(validatePolicy.errors, null, 2));
  assert.equal(validateReport(report), true, JSON.stringify(validateReport.errors, null, 2));
});

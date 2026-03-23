import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runPrSpendProjection } from '../pr-spend-projection.mjs';

const repoRoot = path.resolve(process.cwd());

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('pr-spend-projection schema validates a generated report', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-spend-projection-schema-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const outputPath = path.join(tempDir, 'pr-spend-projection.json');

  fs.writeFileSync(
    costRollupPath,
    `${JSON.stringify(
      {
        schema: 'priority/agent-cost-rollup@v1',
        generatedAt: '2026-03-21T20:41:41.298Z',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        summary: {
          status: 'pass',
          recommendation: 'continue-estimated-telemetry',
          blockers: [],
          metrics: {
            totalTurns: 1,
            exactTurnCount: 0,
            estimatedTurnCount: 1,
            totalUsd: 0.25,
            exactUsd: 0,
            estimatedUsd: 0.25,
            operatorLaborSeconds: 60,
            operatorLaborUsd: 4.166667,
            operatorLaborMissingTurnCount: 0,
            blendedTotalUsd: 4.416667,
            totalTokens: 1000,
            estimatedCreditsConsumed: 6.25,
            actualCreditsConsumed: null,
            actualUsdConsumed: null
          },
          provenance: {
            invoiceTurn: {
              invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
              invoiceId: 'HQ1VJLMV-0027',
              activationState: 'active',
              fundingPurpose: 'operational'
            },
            invoiceTurnSelection: {
              selectedInvoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027'
            },
            rateCards: []
          }
        },
        turns: [
          {
            agentRole: 'live',
            providerId: 'codex-cli',
            providerKind: 'local-codex',
            effectiveModel: 'gpt-5.4',
            effectiveReasoningEffort: 'xhigh',
            issueNumber: 1679,
            laneId: 'issue/origin-1679-pr-spend-projection',
            elapsedSeconds: 60,
            operatorLaborUsd: 4.166667,
            amountUsd: 0.25
          }
        ]
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const { report } = runPrSpendProjection(
    {
      costRollupPath,
      outputPath,
      markdownOutputPath: path.join(tempDir, 'pr-spend-projection.md'),
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      prNumber: 1679,
      postComment: false
    },
    {
      resolveRepoSlugFn: (explicitRepo) => explicitRepo,
      resolvePullRequestContextFn: () => ({
        number: 1679,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1679',
        headRefName: 'issue/origin-1679-pr-spend-projection',
        headSha: 'abc123',
        selectorSource: 'github-pr-head-ref'
      })
    }
  );

  const schema = readJson(path.join(repoRoot, 'docs', 'schemas', 'pr-spend-projection-v1.schema.json'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  COMMENT_MARKER,
  DEFAULT_COST_ROLLUP_PATH,
  DEFAULT_MATERIALIZATION_REPORT_PATH,
  DEFAULT_MARKDOWN_OUTPUT_PATH,
  DEFAULT_OUTPUT_PATH,
  evaluatePrSpendProjection,
  parseArgs,
  runPrSpendProjection
} from '../pr-spend-projection.mjs';

const repoRoot = path.resolve(process.cwd());

function createCostRollupFixture(overrides = {}) {
  return {
    schema: 'priority/agent-cost-rollup@v1',
    generatedAt: '2026-03-21T20:41:41.298Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      status: 'pass',
      recommendation: 'continue-estimated-telemetry',
      blockers: [],
      metrics: {
        totalTurns: 3,
        exactTurnCount: 1,
        estimatedTurnCount: 2,
        totalUsd: 1.23,
        exactUsd: 0.5,
        estimatedUsd: 0.73,
        operatorLaborSeconds: 180,
        operatorLaborUsd: 12.5,
        operatorLaborMissingTurnCount: 0,
        blendedTotalUsd: 13.73,
        totalTokens: 123456,
        estimatedCreditsConsumed: 30.75,
        actualCreditsConsumed: 12.5,
        actualUsdConsumed: 0.5
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
        rateCards: [
          {
            id: 'openai-api-pricing-2026-03-21-gpt-5.4',
            source: 'https://openai.com/api/pricing',
            retrievedAt: '2026-03-21T20:00:00.000Z',
            pricingBasis: 'per-1k-tokens'
          }
        ]
      }
    },
    turns: [
      {
        agentRole: 'live',
        providerId: 'codex-cli',
        providerKind: 'local-codex',
        effectiveModel: 'gpt-5.4',
        effectiveReasoningEffort: 'xhigh',
        issueNumber: 1671,
        laneId: 'issue/origin-1671-account-usage-balance-calibration',
        elapsedSeconds: 120,
        operatorLaborUsd: 8.333333,
        amountUsd: 0.83
      },
      {
        agentRole: 'background',
        providerId: 'codex-cli',
        providerKind: 'local-codex',
        effectiveModel: 'gpt-5.4-mini',
        effectiveReasoningEffort: 'medium',
        issueNumber: 1679,
        laneId: 'issue/origin-1679-pr-spend-projection',
        elapsedSeconds: 30,
        operatorLaborUsd: 2.083333,
        amountUsd: 0.2
      },
      {
        agentRole: 'background',
        providerId: 'codex-cli',
        providerKind: 'local-codex',
        effectiveModel: 'gpt-5.4-mini',
        effectiveReasoningEffort: 'medium',
        issueNumber: 1679,
        laneId: 'issue/origin-1679-pr-spend-projection',
        elapsedSeconds: 30,
        operatorLaborUsd: 2.083334,
        amountUsd: 0.2
      }
    ],
    ...overrides
  };
}

test('parseArgs captures PR spend projection inputs', () => {
  const options = parseArgs([
    'node',
    'pr-spend-projection.mjs',
    '--cost-rollup',
    'custom-rollup.json',
    '--output',
    'custom.json',
    '--markdown-output',
    'custom.md',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--pr',
    '1676',
    '--post-comment'
  ]);

  assert.equal(options.costRollupPath, 'custom-rollup.json');
  assert.equal(options.outputPath, 'custom.json');
  assert.equal(options.markdownOutputPath, 'custom.md');
  assert.equal(options.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(options.prNumber, 1676);
  assert.equal(options.postComment, true);
});

test('parseArgs requires a PR number when posting a comment', () => {
  assert.throws(
    () => parseArgs(['node', 'pr-spend-projection.mjs', '--post-comment']),
    /--pr <number>/
  );
});

test('evaluatePrSpendProjection summarizes spend by role, provider, model, issue, and lane', () => {
  const report = evaluatePrSpendProjection({
    costRollup: createCostRollupFixture(),
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    prContext: {
      number: 1679,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1679',
      headRefName: 'issue/origin-1679-pr-spend-projection',
      headSha: 'abc123',
      selectorSource: 'github-pr-head-ref'
    }
  });

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.summary.billingTruth, 'estimated-only');
  assert.equal(report.summary.operatorLaborUsd, 4.166667);
  assert.equal(report.summary.knownBlendedUsd, 4.566667);
  assert.equal(report.summary.operatorLaborStatus, 'complete');
  assert.equal(report.metrics.totalTurns, 2);
  assert.equal(report.metrics.liveTurnCount, 0);
  assert.equal(report.metrics.backgroundTurnCount, 2);
  assert.equal(report.metrics.operatorLaborSeconds, 60);
  assert.equal(report.breakdown.providers[0].providerId, 'codex-cli');
  assert.deepEqual(
    report.breakdown.models.map((entry) => [entry.effectiveModel, entry.amountUsd]),
    [
      ['gpt-5.4-mini', 0.4]
    ]
  );
  assert.deepEqual(
    report.breakdown.issues.map((entry) => [entry.issueNumber, entry.amountUsd]),
    [
      [1679, 0.4]
    ]
  );
  assert.equal(report.pullRequest.headRefName, 'issue/origin-1679-pr-spend-projection');
});

test('evaluatePrSpendProjection falls back to linked issue turns when branch turns are missing', () => {
  const report = evaluatePrSpendProjection({
    costRollup: createCostRollupFixture({
      turns: [
        {
          agentRole: 'background',
          providerId: 'codex-cli',
          providerKind: 'local-codex',
          effectiveModel: 'gpt-5.4',
          effectiveReasoningEffort: 'xhigh',
          issueNumber: 1679,
          laneId: 'verify/template-agent-proof-20260321',
          laneBranch: 'verify/template-agent-proof-20260321',
          amountUsd: 0.529789
        }
      ]
    }),
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    prContext: {
      number: 1680,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1680',
      headRefName: 'issue/origin-1679-pr-spend-projection',
      headSha: 'abc123',
      linkedIssueNumber: 1679,
      selectorSource: 'github-pr-head-ref'
    }
  });

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.pullRequest.selectorSource, 'github-pr-linked-issue-fallback');
  assert.equal(report.pullRequest.linkedIssueNumber, 1679);
  assert.equal(report.metrics.totalTurns, 1);
  assert.equal(report.summary.totalUsd, 0.529789);
  assert.equal(report.summary.operatorLaborStatus, 'missing');
});

test('evaluatePrSpendProjection falls back to the PR head ref issue number when the body omits a link', () => {
  const report = evaluatePrSpendProjection({
    costRollup: createCostRollupFixture({
      turns: [
        {
          agentRole: 'live',
          providerId: 'codex-cli',
          providerKind: 'local-codex',
          effectiveModel: 'gpt-5.4',
          effectiveReasoningEffort: 'xhigh',
          issueNumber: 1716,
          laneId: 'origin-1716',
          laneBranch: 'issue/origin-1716-branch-turn-attribution-gap-worker',
          amountUsd: 0.612345
        }
      ]
    }),
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    prContext: {
      number: 1716,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1716',
      headRefName: 'issue/origin-1716-branch-turn-attribution-gap',
      headSha: 'abc123',
      linkedIssueNumber: null,
      headRefIssueNumber: 1716,
      selectorSource: 'github-pr-head-ref'
    }
  });

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.pullRequest.selectorSource, 'github-pr-head-ref-issue-fallback');
  assert.equal(report.metrics.totalTurns, 1);
  assert.equal(report.summary.totalUsd, 0.612345);
  assert.equal(report.summary.operatorLaborStatus, 'missing');
});

test('evaluatePrSpendProjection prefers laneBranch-attributed turns before linked issue fallback when laneId is a short lane identity', () => {
  const report = evaluatePrSpendProjection({
    costRollup: createCostRollupFixture({
      turns: [
        {
          agentRole: 'live',
          providerId: 'codex-cli',
          providerKind: 'local-codex',
          effectiveModel: 'gpt-5.4',
          effectiveReasoningEffort: 'high',
          issueNumber: 1682,
          laneId: 'origin-1682',
          laneBranch: 'issue/origin-1682-branch-attributed-cost-turns',
          amountUsd: 0.311111
        },
        {
          agentRole: 'background',
          providerId: 'codex-cli',
          providerKind: 'local-codex',
          effectiveModel: 'gpt-5.4-mini',
          effectiveReasoningEffort: 'medium',
          issueNumber: 1682,
          laneId: 'verify/template-agent-proof-20260321',
          laneBranch: 'verify/template-agent-proof-20260321',
          amountUsd: 0.111111
        }
      ]
    }),
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    prContext: {
      number: 1682,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1682',
      headRefName: 'issue/origin-1682-branch-attributed-cost-turns',
      headSha: 'abc123',
      linkedIssueNumber: 1682,
      selectorSource: 'github-pr-head-ref'
    }
  });

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.pullRequest.selectorSource, 'github-pr-head-ref');
  assert.equal(report.metrics.totalTurns, 1);
  assert.equal(report.summary.totalUsd, 0.311111);
  assert.equal(report.summary.operatorLaborStatus, 'missing');
  assert.equal(report.breakdown.lanes[0].laneId, 'origin-1682');
});

test('runPrSpendProjection writes JSON and markdown outputs and can upsert a comment via injected functions', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-spend-projection-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const outputPath = path.join(tempDir, 'pr-spend-projection.json');
  const markdownOutputPath = path.join(tempDir, 'pr-spend-projection.md');
  fs.writeFileSync(costRollupPath, `${JSON.stringify(createCostRollupFixture(), null, 2)}\n`, 'utf8');

  let posted = null;
  const result = runPrSpendProjection(
    {
      costRollupPath,
      outputPath,
      markdownOutputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      prNumber: 1676,
      postComment: true
    },
    {
      resolveRepoSlugFn: (explicitRepo) => explicitRepo,
      resolvePullRequestContextFn: () => ({
        number: 1676,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1676',
        headRefName: 'issue/origin-1679-pr-spend-projection',
        headSha: 'abc123',
        linkedIssueNumber: 1679,
        selectorSource: 'github-pr-head-ref'
      }),
      upsertCommentFn: (repo, prNumber, body) => {
        posted = { repo, prNumber, body };
        return { posted: true, mode: 'update-existing-marker-comment' };
      },
      lookupCurrentLoginFn: () => 'automation-user'
    }
  );

  assert.equal(fs.existsSync(outputPath), true);
  assert.equal(fs.existsSync(markdownOutputPath), true);
  assert.equal(result.report.commentPost.posted, true);
  assert.equal(result.report.commentPost.actorLogin, 'automation-user');
  assert.equal(posted.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(posted.prNumber, 1676);
  assert.match(posted.body, /Intermediate PR Spend/);
  assert.match(posted.body, new RegExp(COMMENT_MARKER.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('runPrSpendProjection materializes a missing cost rollup before projection', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-spend-projection-materialize-'));
  const costRollupPath = path.join(tempDir, 'missing-agent-cost-rollup.json');
  const outputPath = path.join(tempDir, 'pr-spend-projection.json');
  const markdownOutputPath = path.join(tempDir, 'pr-spend-projection.md');
  const materializationReportPath = path.join(tempDir, 'agent-cost-rollup-materialization.json');

  const result = runPrSpendProjection(
    {
      costRollupPath,
      outputPath,
      markdownOutputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      prNumber: 1772,
      postComment: false
    },
    {
      resolveRepoSlugFn: (explicitRepo) => explicitRepo,
      resolvePullRequestContextFn: () => ({
        number: 1772,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1772',
        headRefName: 'issue/origin-1770-template-verification-authority',
        headSha: 'abc123',
        headRefIssueNumber: 1770,
        linkedIssueNumber: null,
        selectorSource: 'github-pr-head-ref'
      }),
      materializeAgentCostRollupFn: ({ costRollupPath: requestedPath, outputPath: requestedOutputPath }) => {
        fs.writeFileSync(
          requestedPath,
          `${JSON.stringify(
            createCostRollupFixture({
              turns: [
                {
                  agentRole: 'live',
                  providerId: 'codex-cli',
                  providerKind: 'local-codex',
                  effectiveModel: 'gpt-5.4',
                  effectiveReasoningEffort: 'xhigh',
                  issueNumber: 1770,
                  laneId: 'issue/origin-1770-template-verification-authority',
                  laneBranch: 'issue/origin-1770-template-verification-authority',
                  amountUsd: 0.0201
                }
              ]
            }),
            null,
            2
          )}\n`,
          'utf8'
        );
        fs.writeFileSync(
          requestedOutputPath,
          `${JSON.stringify(
            {
              schema: 'priority/agent-cost-rollup-materialization@v1',
              generatedAt: '2026-03-22T06:00:00.000Z',
              summary: {
                status: 'pass'
              }
            },
            null,
            2
          )}\n`,
          'utf8'
        );
        return {
          outputPath: materializationReportPath,
          costRollupPath: requestedPath
        };
      }
    }
  );

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.source.costRollupMaterialized, true);
  assert.equal(result.report.source.costRollupMaterializationReportPath, path.relative(repoRoot, materializationReportPath).replace(/\\/g, '/'));
  assert.match(fs.readFileSync(markdownOutputPath, 'utf8'), /materialized-current-lane/);
});

test('runPrSpendProjection rematerializes when an existing rollup has no matching turns for the PR', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-spend-projection-rematerialize-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const outputPath = path.join(tempDir, 'pr-spend-projection.json');
  const markdownOutputPath = path.join(tempDir, 'pr-spend-projection.md');

  fs.writeFileSync(costRollupPath, `${JSON.stringify(createCostRollupFixture(), null, 2)}\n`, 'utf8');

  const result = runPrSpendProjection(
    {
      costRollupPath,
      outputPath,
      markdownOutputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      prNumber: 1772,
      postComment: false
    },
    {
      resolveRepoSlugFn: (explicitRepo) => explicitRepo,
      resolvePullRequestContextFn: () => ({
        number: 1772,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1772',
        headRefName: 'issue/origin-1770-template-verification-authority',
        headSha: 'abc123',
        headRefIssueNumber: 1770,
        linkedIssueNumber: 1770,
        selectorSource: 'github-pr-head-ref'
      }),
      materializeAgentCostRollupFn: ({ costRollupPath: requestedPath, outputPath: requestedOutputPath }) => {
        fs.writeFileSync(
          requestedPath,
          `${JSON.stringify(
            createCostRollupFixture({
              turns: [
                {
                  agentRole: 'live',
                  providerId: 'codex-cli',
                  providerKind: 'local-codex',
                  effectiveModel: 'gpt-5.4',
                  effectiveReasoningEffort: 'xhigh',
                  issueNumber: 1770,
                  laneId: 'issue/origin-1770-template-verification-authority',
                  laneBranch: 'issue/origin-1770-template-verification-authority',
                  amountUsd: 0.0201
                }
              ]
            }),
            null,
            2
          )}\n`,
          'utf8'
        );
        fs.writeFileSync(
          requestedOutputPath,
          `${JSON.stringify(
            {
              schema: 'priority/agent-cost-rollup-materialization@v1',
              generatedAt: '2026-03-22T06:00:00.000Z',
              summary: {
                status: 'pass'
              }
            },
            null,
            2
          )}\n`,
          'utf8'
        );
        return {
          outputPath: requestedOutputPath,
          costRollupPath: requestedPath
        };
      }
    }
  );

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.source.costRollupMaterialized, true);
  assert.equal(result.report.summary.totalUsd, 0.0201);
  assert.match(fs.readFileSync(markdownOutputPath, 'utf8'), /materialized-current-lane/);
});

test('CLI entrypoint writes the PR spend projection report on Windows path resolution', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-spend-projection-cli-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const outputPath = path.join(tempDir, 'pr-spend-projection.json');
  const markdownOutputPath = path.join(tempDir, 'pr-spend-projection.md');
  fs.writeFileSync(costRollupPath, `${JSON.stringify(createCostRollupFixture(), null, 2)}\n`, 'utf8');

  const result = spawnSync(
    process.execPath,
    [
      path.join(repoRoot, 'tools', 'priority', 'pr-spend-projection.mjs'),
      '--cost-rollup',
      costRollupPath,
      '--output',
      outputPath,
      '--markdown-output',
      markdownOutputPath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(fs.existsSync(outputPath), true);
  assert.equal(fs.existsSync(markdownOutputPath), true);
});

test('defaults remain anchored to the checked-in agent cost paths', () => {
  assert.match(DEFAULT_COST_ROLLUP_PATH, /agent-cost-rollup\.json$/);
  assert.match(DEFAULT_MATERIALIZATION_REPORT_PATH, /agent-cost-rollup-materialization\.json$/);
  assert.match(DEFAULT_OUTPUT_PATH, /pr-spend-projection\.json$/);
  assert.match(DEFAULT_MARKDOWN_OUTPUT_PATH, /pr-spend-projection\.md$/);
});

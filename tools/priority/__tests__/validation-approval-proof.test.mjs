import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'validation-approval-proof.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function readDevelopRequiredChecks() {
  const payload = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'), 'utf8'),
  );
  return payload.branches.develop;
}

function createSuccessRollup(contexts) {
  return contexts.map((name) => ({
    __typename: 'CheckRun',
    name,
    status: 'COMPLETED',
    conclusion: 'SUCCESS',
  }));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createSignalFixture({ prNumber, headSha, currentHeadReview, actionableCommentCount = 0, unresolvedThreadCount = 0, staleReviewCount = 0 }) {
  return {
    schema: 'priority/copilot-review-signal@v1',
    schemaVersion: '1.0.0',
    generatedAt: '2026-03-08T08:00:00.000Z',
    status: 'pass',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    reviewState: actionableCommentCount > 0 || unresolvedThreadCount > 0 ? 'attention' : 'clean',
    pullRequest: {
      number: prNumber,
      url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
      state: 'closed',
      draft: false,
      headSha,
      headRef: `issue/${prNumber}-test`,
      baseRef: 'develop',
      author: 'svelderrainruiz',
      updatedAt: '2026-03-08T08:00:00.000Z',
    },
    summary: {
      copilotReviewCount: 1,
      currentHeadReviewCount: currentHeadReview ? 1 : 0,
      staleReviewCount,
      unresolvedThreadCount,
      actionableThreadCount: actionableCommentCount > 0 ? 1 : 0,
      actionableCommentCount,
      staleThreadCount: staleReviewCount > 0 ? 1 : 0,
      suppressedNotesObservedInLatestReview: false,
      suppressedNoteCountInLatestReview: null,
    },
    signals: {
      hasCopilotReview: true,
      hasCurrentHeadReview: currentHeadReview,
      hasStaleReview: staleReviewCount > 0,
      hasUnresolvedThreads: unresolvedThreadCount > 0,
      hasActionableComments: actionableCommentCount > 0,
      hasSuppressedNotesInLatestReview: false,
    },
    latestCopilotReview: {
      id: String(3900000000 + prNumber),
      state: 'COMMENTED',
      commitId: headSha,
      submittedAt: '2026-03-08T08:00:00.000Z',
      url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}#pullrequestreview-${3900000000 + prNumber}`,
      isCurrentHead: currentHeadReview,
      suppressedNotesObserved: false,
      suppressedNoteCount: null,
      bodySummary: 'Historical replay fixture',
    },
    staleReviews: staleReviewCount > 0 ? [{ id: 'stale-review' }] : [],
    unresolvedThreads: [],
    actionableComments: [],
    errors: [],
  };
}

function createRunPayload({ runId, headBranch, headSha }) {
  return {
    id: runId,
    name: 'Validate',
    path: '.github/workflows/validate.yml',
    html_url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/${runId}`,
    head_branch: headBranch,
    head_sha: headSha,
    event: 'pull_request',
    status: 'completed',
    conclusion: 'success',
    display_title: `Validate ${headBranch}`,
    created_at: '2026-03-08T08:00:00.000Z',
    updated_at: '2026-03-08T08:05:00.000Z',
  };
}

function createPullView({ prNumber, headSha }) {
  return {
    number: prNumber,
    url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
    isDraft: false,
    headRefOid: headSha,
    headRefName: `issue/${prNumber}-test`,
    baseRefName: 'develop',
    headRepositoryOwner: {
      login: 'labview-community-ci-cd',
    },
    isCrossRepository: false,
    mergeStateStatus: 'CLEAN',
    statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
  };
}

function createProofHarness(tmpDir) {
  const deployments = [
    {
      id: 4101,
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ref: 'issue/900-test',
      created_at: '2026-03-08T08:10:00.000Z',
    },
    {
      id: 4102,
      sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ref: 'issue/901-test',
      created_at: '2026-03-08T08:00:00.000Z',
    },
  ];
  const statusesByDeployment = new Map([
    [
      4101,
      [
        {
          id: 1,
          state: 'waiting',
          created_at: '2026-03-08T08:10:10.000Z',
          target_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/7001/job/1',
        },
        {
          id: 2,
          state: 'success',
          created_at: '2026-03-08T08:11:10.000Z',
          target_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/7001/job/1',
        },
      ],
    ],
    [
      4102,
      [
        {
          id: 3,
          state: 'waiting',
          created_at: '2026-03-08T08:00:10.000Z',
          target_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/7002/job/1',
        },
        {
          id: 4,
          state: 'success',
          created_at: '2026-03-08T08:01:10.000Z',
          target_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/7002/job/1',
        },
      ],
    ],
  ]);
  const runsById = new Map([
    [7001, createRunPayload({ runId: 7001, headBranch: 'issue/900-test', headSha: deployments[0].sha })],
    [7002, createRunPayload({ runId: 7002, headBranch: 'issue/901-test', headSha: deployments[1].sha })],
  ]);
  const pullsByCommit = new Map([
    [deployments[0].sha, [{ number: 900, url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/900', state: 'closed', merged_at: '2026-03-08T08:20:00.000Z', head: { ref: 'issue/900-test', sha: deployments[0].sha }, base: { ref: 'develop' } }]],
    [deployments[1].sha, [{ number: 901, url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/901', state: 'closed', merged_at: '2026-03-08T08:20:00.000Z', head: { ref: 'issue/901-test', sha: deployments[1].sha }, base: { ref: 'develop' } }]],
  ]);
  const pullViews = new Map([
    [900, createPullView({ prNumber: 900, headSha: deployments[0].sha })],
    [901, createPullView({ prNumber: 901, headSha: deployments[1].sha })],
  ]);

  return {
    runGhJsonFn(args) {
      if (args[0] === 'api' && String(args[1]).includes('/deployments?environment=')) {
        return deployments;
      }
      if (args[0] === 'api' && /\/deployments\/4101\/statuses$/.test(args[1])) {
        return statusesByDeployment.get(4101);
      }
      if (args[0] === 'api' && /\/deployments\/4102\/statuses$/.test(args[1])) {
        return statusesByDeployment.get(4102);
      }
      if (args[0] === 'api' && /\/actions\/runs\/7001$/.test(args[1])) {
        return runsById.get(7001);
      }
      if (args[0] === 'api' && /\/actions\/runs\/7002$/.test(args[1])) {
        return runsById.get(7002);
      }
      if (args[0] === 'api' && args.at(-1) === `repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/commits/${deployments[0].sha}/pulls`) {
        return pullsByCommit.get(deployments[0].sha);
      }
      if (args[0] === 'api' && args.at(-1) === `repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/commits/${deployments[1].sha}/pulls`) {
        return pullsByCommit.get(deployments[1].sha);
      }
      if (args[0] === 'pr' && args[1] === 'view' && args[2] === '900') {
        return pullViews.get(900);
      }
      if (args[0] === 'pr' && args[1] === 'view' && args[2] === '901') {
        return pullViews.get(901);
      }
      throw new Error(`Unexpected gh invocation: ${args.join(' ')}`);
    },
    runSignalCollectorFn({ prNumber, outPath }) {
      const payload =
        prNumber === 900
          ? createSignalFixture({ prNumber, headSha: deployments[0].sha, currentHeadReview: true })
          : createSignalFixture({
              prNumber,
              headSha: deployments[1].sha,
              currentHeadReview: false,
              staleReviewCount: 1,
            });
      writeJson(outPath, payload);
    },
    downloadArtifactFn({ runId, destination }) {
      writeJson(path.join(destination, 'validation-deployment-determinism.json'), {
        schema: 'priority/deployment-determinism@v1',
        generatedAt: '2026-03-08T08:00:00.000Z',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        environment: 'validation',
        runId: String(runId),
        result: 'pass',
        issues: [],
      });
      return true;
    },
  };
}

test('parseArgs accepts proof-specific flags', async () => {
  const { parseArgs } = await loadModule();
  const parsed = parseArgs([
    'node',
    'validation-approval-proof.mjs',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--environment',
    'validation',
    '--policy',
    'tools/policy/validation-approval-policy.json',
    '--max-deployments',
    '6',
    '--min-samples',
    '2',
    '--lookback-days',
    '3',
    '--artifacts-dir',
    'tmp/proof',
    '--report',
    'tmp/report.json',
    '--no-strict',
  ]);

  assert.equal(parsed.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(parsed.environment, 'validation');
  assert.equal(parsed.policyPath, 'tools/policy/validation-approval-policy.json');
  assert.equal(parsed.maxDeployments, 6);
  assert.equal(parsed.minSamples, 2);
  assert.equal(parsed.lookbackDays, 3);
  assert.equal(parsed.artifactsDir, 'tmp/proof');
  assert.equal(parsed.reportPath, 'tmp/report.json');
  assert.equal(parsed.strict, false);
});

test('runValidationApprovalProof emits a passing report with conservative false-blocks but no false-ready outcomes', async (t) => {
  const { runValidationApprovalProof } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-approval-proof-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const harness = createProofHarness(tmpDir);
  const reportPath = path.join(tmpDir, 'proof.json');
  const result = await runValidationApprovalProof({
    argv: [
      'node',
      'validation-approval-proof.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      path.join(repoRoot, 'tools', 'policy', 'validation-approval-policy.json'),
      '--max-deployments',
      '2',
      '--min-samples',
      '2',
      '--lookback-days',
      '2',
      '--artifacts-dir',
      path.join(tmpDir, 'artifacts'),
      '--report',
      reportPath,
    ],
    now: new Date('2026-03-08T08:30:00.000Z'),
    repoRoot,
    runGhJsonFn: harness.runGhJsonFn,
    runSignalCollectorFn: harness.runSignalCollectorFn,
    downloadArtifactFn: harness.downloadArtifactFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.summary.samplesEvaluated, 2);
  assert.equal(result.report?.summary.falseReadyCount, 0);
  assert.equal(result.report?.summary.falseBlockedCount, 1);
  assert.equal(result.report?.verdict.policyFlipRecommended, true);
  assert.equal(result.report?.samples[0].comparison, 'match-ready');
  assert.equal(result.report?.samples[1].comparison, 'false-blocked');
  assert.ok(result.report?.samples[1].reasons.includes('current-head-review-missing'));
  assert.ok(fs.existsSync(reportPath));
});

test('runValidationApprovalProof fails strict mode when the proof window is undersampled', async (t) => {
  const { runValidationApprovalProof } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-approval-proof-fail-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const harness = createProofHarness(tmpDir);
  const result = await runValidationApprovalProof({
    argv: [
      'node',
      'validation-approval-proof.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      path.join(repoRoot, 'tools', 'policy', 'validation-approval-policy.json'),
      '--max-deployments',
      '1',
      '--min-samples',
      '2',
      '--lookback-days',
      '2',
      '--artifacts-dir',
      path.join(tmpDir, 'artifacts'),
      '--report',
      path.join(tmpDir, 'proof.json'),
    ],
    now: new Date('2026-03-08T08:30:00.000Z'),
    repoRoot,
    runGhJsonFn: harness.runGhJsonFn,
    runSignalCollectorFn: harness.runSignalCollectorFn,
    downloadArtifactFn: harness.downloadArtifactFn,
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.status, 'fail');
  assert.ok(result.report?.verdict.reasons.includes('insufficient-samples'));
  assert.equal(result.report?.verdict.policyFlipRecommended, false);
});

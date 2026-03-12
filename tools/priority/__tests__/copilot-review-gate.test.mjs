import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'copilot-review-gate.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function createArgv(argvExtras) {
  return ['node', 'copilot-review-gate.mjs', ...argvExtras];
}

function createSignalFixture(t, fileName = 'copilot-review-signal.json') {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-review-gate-signal-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));
  const signalPath = path.join(tmpDir, fileName);
  fs.writeFileSync(signalPath, '{}\n', 'utf8');
  return signalPath;
}

test('parseRepoSlug trims whitespace and rejects slugs with extra segments', async () => {
  const { parseRepoSlug } = await loadModule();

  assert.deepEqual(parseRepoSlug(' LabVIEW-Community-CI-CD / compare-vi-cli-action '), {
    owner: 'LabVIEW-Community-CI-CD',
    repo: 'compare-vi-cli-action',
  });
  assert.throws(
    () => parseRepoSlug('LabVIEW-Community-CI-CD/compare-vi-cli-action/extra'),
    /Expected <owner>\/<repo>/,
  );
});

test('copilot-review-gate skips draft PRs before any live lookup', async () => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCalled = false;
  let threadsCalled = false;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      '--base-ref',
      'develop',
      '--draft',
      'true',
    ]),
    loadReviewsFn: async () => {
      reviewsCalled = true;
      return [];
    },
    loadThreadsFn: async () => {
      threadsCalled = true;
      return [];
    },
    writeReportFn: () => 'memory://copilot-review-gate.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.gateState, 'skipped');
  assert.deepEqual(result.report?.reasons, ['draft-pr-skip']);
  assert.equal(reviewsCalled, false);
  assert.equal(threadsCalled, false);
});

test('parseMergeGroupHeadBranch resolves the queued PR number and source head SHA from the merge-group branch', async () => {
  const { parseMergeGroupHeadBranch } = await loadModule();

  assert.deepEqual(
    parseMergeGroupHeadBranch('gh-readonly-queue/develop/pr-1012-23324a081abaf177d24ea295e6da805ce541465a'),
    {
      headBranch: 'gh-readonly-queue/develop/pr-1012-23324a081abaf177d24ea295e6da805ce541465a',
      baseRef: 'develop',
      prNumber: 1012,
      sourceHeadSha: '23324a081abaf177d24ea295e6da805ce541465a',
    },
  );
  assert.equal(parseMergeGroupHeadBranch('feature/not-a-queue-branch'), null);
});

test('copilot-review-gate evaluates merge-group runs against the queued PR head instead of skipping', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const sourceHead = '23324a081abaf177d24ea295e6da805ce541465a';

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'merge_group',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--head-sha',
      '7c5a463fc1c90edff1bc7671a22cd2bb1308def5',
      '--head-branch',
      'gh-readonly-queue/develop/pr-1012-23324a081abaf177d24ea295e6da805ce541465a',
      '--base-ref',
      'refs/heads/develop',
    ]),
    loadPullRequestFn: async () => ({
      number: 1012,
      html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1012',
      draft: false,
      head: { sha: sourceHead },
      base: { ref: 'develop' },
    }),
    loadReviewsFn: async () => [],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    loadReviewRunFn: async () => ({
      id: 93020,
      name: 'Copilot code review',
      status: 'completed',
      conclusion: 'success',
      html_url: 'https://github.com/example/actions/runs/93020',
      head_sha: sourceHead,
    }),
    writeReportFn: () => 'memory://copilot-review-gate.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-run-completed-clean']);
  assert.equal(result.report?.source.mode, 'merge-group-live');
  assert.equal(result.report?.source.mergeGroup?.prNumber, 1012);
  assert.equal(result.report?.source.mergeGroup?.sourceHeadSha, sourceHead);
  assert.equal(result.report?.pullRequest.liveHeadSha, sourceHead);
});

test('copilot-review-gate blocks merge-group runs when the queued source head is stale relative to the live PR head', async () => {
  const { runCopilotReviewGate } = await loadModule();

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'merge_group',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--head-sha',
      '7c5a463fc1c90edff1bc7671a22cd2bb1308def5',
      '--head-branch',
      'gh-readonly-queue/develop/pr-1012-23324a081abaf177d24ea295e6da805ce541465a',
      '--base-ref',
      'refs/heads/develop',
    ]),
    loadPullRequestFn: async () => ({
      number: 1012,
      html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1012',
      draft: false,
      head: { sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
      base: { ref: 'develop' },
    }),
    loadReviewsFn: async () => [],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    loadReviewRunFn: async () => null,
    writeReportFn: () => 'memory://copilot-review-gate-merge-group-stale.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.gateState, 'blocked');
  assert.deepEqual(result.report?.reasons, ['merge-group-source-head-stale']);
  assert.equal(result.report?.source.mergeGroup?.sourceHeadMatchesPullRequestHead, false);
});

test('copilot-review-gate fails early when a merge-group head branch cannot be resolved', async () => {
  const { runCopilotReviewGate } = await loadModule();
  let pullRequestLookupCalled = false;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'merge_group',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--head-sha',
      '7c5a463fc1c90edff1bc7671a22cd2bb1308def5',
      '--head-branch',
      'feature/not-a-queue-branch',
      '--base-ref',
      'refs/heads/develop',
    ]),
    loadPullRequestFn: async () => {
      pullRequestLookupCalled = true;
      throw new Error('loadPullRequestFn should not be called for unresolved merge-group metadata');
    },
    loadReviewsFn: async () => [],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    writeReportFn: () => 'memory://copilot-review-gate-merge-group-unresolved.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.status, 'fail');
  assert.equal(result.report?.gateState, 'error');
  assert.deepEqual(result.report?.reasons, ['merge-group-source-unresolved']);
  assert.match(result.report?.errors?.[0] ?? '', /expected gh-readonly-queue\/<base>\/pr-<number>-<sha> pattern/i);
  assert.equal(result.report?.source.mode, 'merge-group-metadata');
  assert.equal(pullRequestLookupCalled, false);
});

test('copilot-review-gate skips throughput fork repos before any live lookup', async () => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCalled = false;
  let threadsCalled = false;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'svelderrainruiz/compare-vi-cli-action',
      '--pr',
      '304',
      '--head-sha',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      '--base-ref',
      'develop',
      '--draft',
      'false',
    ]),
    loadReviewsFn: async () => {
      reviewsCalled = true;
      return [];
    },
    loadThreadsFn: async () => {
      threadsCalled = true;
      return [];
    },
    writeReportFn: () => 'memory://copilot-review-gate-throughput-fork.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'skipped');
  assert.deepEqual(result.report?.reasons, ['throughput-fork-skip']);
  assert.equal(result.report?.signals.gateApplies, false);
  assert.equal(reviewsCalled, false);
  assert.equal(threadsCalled, false);
});

test('copilot-review-gate passes stale but clean follow-up heads after an earlier Copilot review', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'cccccccccccccccccccccccccccccccccccccccc';
  const staleHead = 'dddddddddddddddddddddddddddddddddddddddd';

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_review',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
    ]),
    loadReviewsFn: async () => [
      {
        id: 10,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Older Copilot review.',
        html_url: 'https://github.com/example/review/10',
        submitted_at: '2026-03-08T06:00:00Z',
        commit_id: staleHead,
      },
    ],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    writeReportFn: () => 'memory://copilot-review-gate.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.gateState, 'ready');
  assert.equal(result.report?.status, 'pass');
  assert.deepEqual(result.report?.reasons, ['stale-review-clean-followup']);
  assert.equal(result.report?.signals.staleReviewCleanFollowup, true);
});

test('copilot-review-gate blocks stale-only review state on pull_request_target so broker-managed ready-for-review waits for a fresh current-head Copilot review', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'abababababababababababababababababababab';
  const staleHead = 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
    ]),
    loadReviewsFn: async () => [
      {
        id: 13,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Initial Copilot review on the previous head.',
        html_url: 'https://github.com/example/review/13',
        submitted_at: '2026-03-08T06:03:00Z',
        commit_id: staleHead,
      },
    ],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    writeReportFn: () => 'memory://copilot-review-gate-broker-refresh.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.gateState, 'blocked');
  assert.deepEqual(result.report?.reasons, ['current-head-review-missing', 'latest-review-stale']);
  assert.equal(result.report?.signals.hasCurrentHeadReview, false);
  assert.equal(result.report?.signals.staleReviewCleanFollowup, false);
});

test('copilot-review-gate passes when the observed Copilot workflow run completed cleanly for the current head even if no current-head review object exists', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'acacacacacacacacacacacacacacacacacacacac';

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'workflow_run',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--review-run-id',
      '93001',
      '--review-run-status',
      'completed',
      '--review-run-conclusion',
      'success',
      '--review-run-url',
      'https://github.com/example/actions/runs/93001',
      '--review-run-workflow-name',
      'Copilot code review',
    ]),
    loadReviewsFn: async () => [],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    writeReportFn: () => 'memory://copilot-review-gate-workflow-run-clean.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-run-completed-clean']);
  assert.equal(result.report?.reviewRun?.observationState, 'completed-clean');
});

test('copilot-review-gate blocks while the observed Copilot workflow run is still active for the current head', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'dadadadadadadadadadadadadadadadadadadada';

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--review-run-id',
      '93002',
      '--review-run-status',
      'in_progress',
      '--review-run-url',
      'https://github.com/example/actions/runs/93002',
      '--review-run-workflow-name',
      'Copilot code review',
      '--poll-attempts',
      '1',
    ]),
    loadReviewsFn: async () => [],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    writeReportFn: () => 'memory://copilot-review-gate-workflow-run-active.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.gateState, 'blocked');
  assert.deepEqual(result.report?.reasons, ['copilot-review-run-active']);
  assert.equal(result.report?.reviewRun?.observationState, 'in_progress');
});

test('copilot-review-gate polls live data when the collected signal only contains a stale Copilot review', async (t) => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCallCount = 0;
  let threadsCallCount = 0;
  const currentHead = 'efefefefefefefefefefefefefefefefefefefef';
  const staleHead = '1212121212121212121212121212121212121212';
  const signalPath = createSignalFixture(t, 'copilot-review-signal-stale-only.json');

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--signal',
      signalPath,
      '--poll-attempts',
      '3',
      '--poll-delay-ms',
      '1',
    ]),
    readSignalFn: () => ({
      schema: 'priority/copilot-review-signal@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequest: {
        number: 885,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/885',
        draft: false,
        headSha: currentHead,
        baseRef: 'develop',
      },
      latestCopilotReview: {
        id: '42',
        state: 'COMMENTED',
        commitId: staleHead,
        submittedAt: '2026-03-08T06:05:00Z',
        url: 'https://github.com/example/review/42',
        isCurrentHead: false,
        bodySummary: 'Stale Copilot review before the fresh ready-for-review cycle.',
      },
      staleReviews: [],
      unresolvedThreads: [],
      actionableComments: [],
      errors: [],
    }),
    loadReviewsFn: async () => {
      reviewsCallCount += 1;
      if (reviewsCallCount === 1) {
        return [
          {
            id: 43,
            user: { login: 'copilot-pull-request-reviewer[bot]' },
            state: 'COMMENTED',
            body: 'Fresh current-head review arrived after signal collection.',
            html_url: 'https://github.com/example/review/43',
            submitted_at: '2026-03-08T06:06:00Z',
            commit_id: currentHead,
          },
        ];
      }
      return [];
    },
    loadThreadsFn: async () => {
      threadsCallCount += 1;
      return {
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [],
              },
            },
          },
        },
      };
    },
    writeReportFn: () => 'memory://copilot-review-gate-stale-signal-poll.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-clean']);
  assert.deepEqual(result.report?.poll, {
    attemptsRequested: 3,
    attemptsUsed: 2,
    delayMs: 1,
  });
  assert.equal(reviewsCallCount, 1);
  assert.equal(threadsCallCount, 1);
});

test('copilot-review-gate keeps polling stale-signal current-head gaps until the observed Copilot workflow run completes cleanly', async (t) => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'ababcdcdababcdcdababcdcdababcdcdababcdcd';
  const staleHead = 'fefefefefefefefefefefefefefefefefefefefe';
  const signalPath = createSignalFixture(t, 'copilot-review-signal-stale-run-race.json');
  let reviewRunCallCount = 0;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--signal',
      signalPath,
      '--poll-attempts',
      '4',
      '--poll-delay-ms',
      '1',
    ]),
    readSignalFn: () => ({
      schema: 'priority/copilot-review-signal@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequest: {
        number: 885,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/885',
        draft: false,
        headSha: currentHead,
        baseRef: 'develop',
      },
      latestCopilotReview: {
        id: '52',
        state: 'COMMENTED',
        commitId: staleHead,
        submittedAt: '2026-03-12T16:33:35Z',
        url: 'https://github.com/example/review/52',
        isCurrentHead: false,
        bodySummary: 'Copilot reviewed the previous head before the new ready-for-review cycle.',
      },
      staleReviews: [],
      unresolvedThreads: [],
      actionableComments: [],
      errors: [],
    }),
    loadReviewsFn: async () => [],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    loadReviewRunFn: async () => {
      reviewRunCallCount += 1;
      if (reviewRunCallCount === 1) {
        return {
          id: 93010,
          name: 'Copilot code review',
          status: 'in_progress',
          conclusion: null,
          html_url: 'https://github.com/example/actions/runs/93010',
          head_sha: currentHead,
        };
      }
      return {
        id: 93010,
        name: 'Copilot code review',
        status: 'completed',
        conclusion: 'success',
        html_url: 'https://github.com/example/actions/runs/93010',
        head_sha: currentHead,
      };
    },
    writeReportFn: () => 'memory://copilot-review-gate-stale-run-race.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-run-completed-clean']);
  assert.equal(result.report?.reviewRun?.observationState, 'completed-clean');
  assert.deepEqual(result.report?.poll, {
    attemptsRequested: 4,
    attemptsUsed: 3,
    delayMs: 1,
  });
  assert.equal(reviewRunCallCount, 2);
});

test('copilot-review-gate passes from live polling when the Copilot workflow run completes cleanly before any review object is posted', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'cdcdababcdcdababcdcdababcdcdababcdcdabab';
  let reviewRunCallCount = 0;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--poll-attempts',
      '4',
      '--poll-delay-ms',
      '1',
    ]),
    loadReviewsFn: async () => [],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    loadReviewRunFn: async () => {
      reviewRunCallCount += 1;
      if (reviewRunCallCount < 3) {
        return {
          id: 93011,
          name: 'Copilot code review',
          status: 'in_progress',
          conclusion: null,
          html_url: 'https://github.com/example/actions/runs/93011',
          head_sha: currentHead,
        };
      }
      return {
        id: 93011,
        name: 'Copilot code review',
        status: 'completed',
        conclusion: 'success',
        html_url: 'https://github.com/example/actions/runs/93011',
        head_sha: currentHead,
      };
    },
    writeReportFn: () => 'memory://copilot-review-gate-live-run-clean.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-run-completed-clean']);
  assert.equal(result.report?.reviewRun?.observationState, 'completed-clean');
  assert.deepEqual(result.report?.poll, {
    attemptsRequested: 4,
    attemptsUsed: 3,
    delayMs: 1,
  });
  assert.equal(reviewRunCallCount, 3);
});

test('copilot-review-gate blocks unresolved current-head Copilot threads', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_review_thread',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
    ]),
    loadReviewsFn: async () => [
      {
        id: 11,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Current-head review with one unresolved thread.',
        html_url: 'https://github.com/example/review/11',
        submitted_at: '2026-03-08T06:02:00Z',
        commit_id: currentHead,
      },
    ],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [
                {
                  id: 'PRRT_gate_1',
                  isResolved: false,
                  isOutdated: false,
                  path: 'tools/priority/dispatch-validate.mjs',
                  line: 44,
                  originalLine: 44,
                  comments: {
                    nodes: [
                      {
                        id: 'PRRC_gate_1',
                        body: 'Wait for a current-head Copilot review before queueing.',
                        publishedAt: '2026-03-08T06:02:30Z',
                        url: 'https://github.com/example/comment/1',
                        author: { login: 'copilot-pull-request-reviewer' },
                        pullRequestReview: {
                          databaseId: 11,
                          state: 'COMMENTED',
                          author: { login: 'copilot-pull-request-reviewer' },
                          submittedAt: '2026-03-08T06:02:00Z',
                          commit: { oid: currentHead },
                        },
                      },
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    }),
    writeReportFn: () => 'memory://copilot-review-gate.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.gateState, 'blocked');
  assert.deepEqual(result.report?.reasons, ['actionable-comments-present']);
  assert.equal(result.report?.summary.actionableThreadCount, 1);
  assert.equal(result.report?.summary.actionableCommentCount, 1);
});

test('copilot-review-gate passes when the latest Copilot review is current-head and clean', async () => {
  const { runCopilotReviewGate } = await loadModule();
  const currentHead = 'ffffffffffffffffffffffffffffffffffffffff';

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_review',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      currentHead,
      '--base-ref',
      'develop',
      '--draft',
      'false',
    ]),
    loadReviewsFn: async () => [
      {
        id: 12,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Current-head review with no actionable comments.',
        html_url: 'https://github.com/example/review/12',
        submitted_at: '2026-03-08T06:04:00Z',
        commit_id: currentHead,
      },
    ],
    loadThreadsFn: async () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [],
            },
          },
        },
      },
    }),
    writeReportFn: () => 'memory://copilot-review-gate.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-clean']);
  assert.equal(result.report?.signals.hasCurrentHeadReview, true);
});

test('copilot-review-gate can evaluate the current-head state from the collected signal artifact', async (t) => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCalled = false;
  let threadsCalled = false;
  const signalPath = createSignalFixture(t, 'copilot-review-signal.json');

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      '9999999999999999999999999999999999999999',
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--signal',
      signalPath,
    ]),
    readSignalFn: () => ({
      schema: 'priority/copilot-review-signal@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequest: {
        number: 885,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/885',
        draft: false,
        headSha: '9999999999999999999999999999999999999999',
        baseRef: 'develop',
      },
      latestCopilotReview: {
        id: '15',
        state: 'COMMENTED',
        commitId: '9999999999999999999999999999999999999999',
        submittedAt: '2026-03-08T06:05:00Z',
        url: 'https://github.com/example/review/15',
        isCurrentHead: true,
        bodySummary: 'Current-head Copilot review.',
      },
      staleReviews: [],
      unresolvedThreads: [],
      actionableComments: [],
      errors: [],
    }),
    loadReviewsFn: async () => {
      reviewsCalled = true;
      return [];
    },
    loadThreadsFn: async () => {
      threadsCalled = true;
      return [];
    },
    writeReportFn: () => 'memory://copilot-review-gate.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.source.mode, 'signal');
  assert.equal(result.report?.gateState, 'ready');
  assert.equal(reviewsCalled, false);
  assert.equal(threadsCalled, false);
});

test('copilot-review-gate accepts a fresh current-head review from the signal artifact even when the initial Copilot review remains as stale history', async (t) => {
  const { runCopilotReviewGate } = await loadModule();
  const signalPath = createSignalFixture(t, 'copilot-review-signal-stale-and-current.json');

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      '9999999999999999999999999999999999999999',
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--signal',
      signalPath,
    ]),
    readSignalFn: () => ({
      schema: 'priority/copilot-review-signal@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequest: {
        number: 885,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/885',
        draft: false,
        headSha: '9999999999999999999999999999999999999999',
        baseRef: 'develop',
      },
      latestCopilotReview: {
        id: '16',
        state: 'COMMENTED',
        commitId: '9999999999999999999999999999999999999999',
        submittedAt: '2026-03-08T06:08:00Z',
        url: 'https://github.com/example/review/16',
        isCurrentHead: true,
        bodySummary: 'Fresh current-head Copilot review after broker-managed ready-for-review.',
      },
      staleReviews: [
        {
          id: '15',
          state: 'COMMENTED',
          commitId: '1111111111111111111111111111111111111111',
          submittedAt: '2026-03-08T06:05:00Z',
          url: 'https://github.com/example/review/15',
          bodySummary: 'Initial Copilot review on the prior head.',
        },
      ],
      unresolvedThreads: [],
      actionableComments: [],
      errors: [],
    }),
    loadReviewsFn: async () => {
      throw new Error('signal mode should not query live reviews');
    },
    loadThreadsFn: async () => {
      throw new Error('signal mode should not query live threads');
    },
    writeReportFn: () => 'memory://copilot-review-gate-stale-and-current.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-clean']);
  assert.equal(result.report?.summary.staleReviewCount, 1);
  assert.equal(result.report?.signals.hasCurrentHeadReview, true);
});

test('copilot-review-gate reads the signal artifact before throughput-fork preflight skipping', async (t) => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCalled = false;
  let threadsCalled = false;
  const signalPath = createSignalFixture(t, 'copilot-review-signal-signal-only.json');

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--pr',
      '885',
      '--head-sha',
      '9999999999999999999999999999999999999999',
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--signal',
      signalPath,
    ]),
    readSignalFn: () => ({
      schema: 'priority/copilot-review-signal@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequest: {
        number: 885,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/885',
        draft: false,
        headSha: '9999999999999999999999999999999999999999',
        baseRef: 'develop',
      },
      latestCopilotReview: {
        id: '15',
        state: 'COMMENTED',
        commitId: '9999999999999999999999999999999999999999',
        submittedAt: '2026-03-08T06:05:00Z',
        url: 'https://github.com/example/review/15',
        isCurrentHead: true,
        bodySummary: 'Current-head Copilot review.',
      },
      staleReviews: [],
      unresolvedThreads: [],
      actionableComments: [],
      errors: [],
    }),
    loadReviewsFn: async () => {
      reviewsCalled = true;
      return [];
    },
    loadThreadsFn: async () => {
      threadsCalled = true;
      return [];
    },
    writeReportFn: () => 'memory://copilot-review-gate-signal-only.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.source.mode, 'signal');
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-clean']);
  assert.equal(reviewsCalled, false);
  assert.equal(threadsCalled, false);
});

test('copilot-review-gate reports an error when loading reviews fails', async () => {
  const { runCopilotReviewGate } = await loadModule();

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      '9999999999999999999999999999999999999999',
      '--base-ref',
      'develop',
      '--draft',
      'false',
    ]),
    // Simulate a failure while loading reviews; the gate should catch this
    // and produce a failure report with gateState 'error'.
    loadReviewsFn: async () => {
      throw new Error('simulated loadReviews failure');
    },
    loadThreadsFn: async () => {
      return [];
    },
    writeReportFn: () => 'memory://copilot-review-gate-error.json',
    appendStepSummaryFn: () => {},
  });

  assert.notEqual(result.exitCode, 0);
  assert.equal(result.report?.gateState, 'error');
});

test('copilot-review-gate polls live data until the first Copilot review lands', async () => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCallCount = 0;
  let threadsCallCount = 0;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      'abababababababababababababababababababab',
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--poll-attempts',
      '3',
      '--poll-delay-ms',
      '1',
    ]),
    loadReviewsFn: async () => {
      reviewsCallCount += 1;
      if (reviewsCallCount === 1) {
        return [];
      }
      return [
        {
          id: 21,
          user: { login: 'copilot-pull-request-reviewer[bot]' },
          state: 'COMMENTED',
          body: 'Current-head review arrived during polling.',
          html_url: 'https://github.com/example/review/21',
          submitted_at: '2026-03-08T06:06:00Z',
          commit_id: 'abababababababababababababababababababab',
        },
      ];
    },
    loadThreadsFn: async () => {
      threadsCallCount += 1;
      return {
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [],
              },
            },
          },
        },
      };
    },
    writeReportFn: () => 'memory://copilot-review-gate-poll.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-clean']);
  assert.deepEqual(result.report?.poll, {
    attemptsRequested: 3,
    attemptsUsed: 2,
    delayMs: 1,
  });
  assert.equal(reviewsCallCount, 2);
  assert.equal(threadsCallCount, 2);
});

test('copilot-review-gate polls across multiple attempts until the first Copilot review lands', async () => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCallCount = 0;
  let threadsCallCount = 0;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      'bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc',
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--poll-attempts',
      '3',
      '--poll-delay-ms',
      '1',
    ]),
    loadReviewsFn: async () => {
      reviewsCallCount += 1;
      if (reviewsCallCount < 3) {
        return [];
      }
      return [
        {
          id: 31,
          user: { login: 'copilot-pull-request-reviewer[bot]' },
          state: 'COMMENTED',
          body: 'Current-head review arrived on the final polling attempt.',
          html_url: 'https://github.com/example/review/31',
          submitted_at: '2026-03-08T06:07:00Z',
          commit_id: 'bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc',
        },
      ];
    },
    loadThreadsFn: async () => {
      threadsCallCount += 1;
      return {
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [],
              },
            },
          },
        },
      };
    },
    writeReportFn: () => 'memory://copilot-review-gate-poll-multi-attempt.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'ready');
  assert.deepEqual(result.report?.reasons, ['current-head-review-clean']);
  assert.deepEqual(result.report?.poll, {
    attemptsRequested: 3,
    attemptsUsed: 3,
    delayMs: 1,
  });
  assert.equal(reviewsCallCount, 3);
  assert.equal(threadsCallCount, 3);
});

test('copilot-review-gate reports exhausted polling when the first Copilot review never lands', async () => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCallCount = 0;
  let threadsCallCount = 0;

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd',
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--poll-attempts',
      '3',
      '--poll-delay-ms',
      '1',
    ]),
    loadReviewsFn: async () => {
      reviewsCallCount += 1;
      return [];
    },
    loadThreadsFn: async () => {
      threadsCallCount += 1;
      return {
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: [],
              },
            },
          },
        },
      };
    },
    writeReportFn: () => 'memory://copilot-review-gate-poll-exhausted.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.status, 'fail');
  assert.equal(result.report?.gateState, 'blocked');
  assert.deepEqual(result.report?.reasons, ['copilot-review-run-unobserved']);
  assert.deepEqual(result.report?.poll, {
    attemptsRequested: 3,
    attemptsUsed: 3,
    delayMs: 1,
  });
  assert.equal(reviewsCallCount, 3);
  assert.equal(threadsCallCount, 3);
});

test('copilot-review-gate fails when signal includes thread pagination errors', async (t) => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCalled = false;
  let threadsCalled = false;
  const signalPath = createSignalFixture(t, 'copilot-review-signal-pagination-error.json');

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      '9999999999999999999999999999999999999999',
      '--base-ref',
      'develop',
      '--draft',
      'false',
      '--signal',
      signalPath,
    ]),
    readSignalFn: () => ({
      schema: 'priority/copilot-review-signal@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequest: {
        number: 885,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/885',
        draft: false,
        headSha: '9999999999999999999999999999999999999999',
        baseRef: 'develop',
      },
      latestCopilotReview: {
        id: '15',
        state: 'COMMENTED',
        commitId: '9999999999999999999999999999999999999999',
        submittedAt: '2026-03-08T06:05:00Z',
        url: 'https://github.com/example/review/15',
        isCurrentHead: true,
        bodySummary: 'Current-head Copilot review.',
      },
      staleReviews: [],
      unresolvedThreads: [],
      actionableComments: [],
      // Simulate errors produced by detectThreadPaginationErrors, e.g., when
      // hasNextPage is true and threads are truncated.
      errors: [
        {
          scope: 'threads',
          code: 'pagination-truncated',
          message: 'Review threads were truncated due to pagination; unable to safely evaluate gate.',
        },
      ],
    }),
    loadReviewsFn: async () => {
      reviewsCalled = true;
      return [];
    },
    loadThreadsFn: async () => {
      threadsCalled = true;
      return [];
    },
    writeReportFn: () => 'memory://copilot-review-gate-pagination-error.json',
    appendStepSummaryFn: () => {},
  });

  assert.notEqual(result.exitCode, 0);
  assert.equal(result.report?.source.mode, 'signal');
  assert.equal(result.report?.gateState, 'error');
  assert.equal(reviewsCalled, false);
  assert.equal(threadsCalled, false);
});

test('copilot-review-gate skips when the base ref is not gated', async (t) => {
  const { runCopilotReviewGate } = await loadModule();
  let reviewsCalled = false;
  let threadsCalled = false;
  const signalPath = createSignalFixture(t, 'copilot-review-signal-base-ref-not-gated.json');

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'pull_request_target',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '885',
      '--head-sha',
      '9999999999999999999999999999999999999999',
      '--base-ref',
      'main',
      '--gated-base-refs',
      'develop',
      '--draft',
      'false',
      '--signal',
      signalPath,
    ]),
    readSignalFn: () => ({
      schema: 'priority/copilot-review-signal@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequest: {
        number: 885,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/885',
        draft: false,
        headSha: '9999999999999999999999999999999999999999',
        baseRef: 'main',
      },
      latestCopilotReview: {
        id: '15',
        state: 'COMMENTED',
        commitId: '9999999999999999999999999999999999999999',
        submittedAt: '2026-03-08T06:05:00Z',
        url: 'https://github.com/example/review/15',
        isCurrentHead: true,
        bodySummary: 'Current-head Copilot review on an ungated base ref.',
      },
      staleReviews: [],
      unresolvedThreads: [],
      actionableComments: [],
      errors: [],
    }),
    loadReviewsFn: async () => {
      reviewsCalled = true;
      return [];
    },
    loadThreadsFn: async () => {
      threadsCalled = true;
      return [];
    },
    writeReportFn: () => 'memory://copilot-review-gate-base-ref-not-gated.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.source.mode, 'metadata');
  assert.equal(result.report?.gateState, 'skipped');
  assert.equal(reviewsCalled, false);
  assert.equal(threadsCalled, false);
});

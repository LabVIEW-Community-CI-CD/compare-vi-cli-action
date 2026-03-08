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

test('copilot-review-gate skips merge-group runs while keeping the required status green', async () => {
  const { runCopilotReviewGate } = await loadModule();

  const result = await runCopilotReviewGate({
    argv: createArgv([
      '--event-name',
      'merge_group',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--head-sha',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      '--base-ref',
      'refs/heads/develop',
    ]),
    writeReportFn: () => 'memory://copilot-review-gate.json',
    appendStepSummaryFn: () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.gateState, 'skipped');
  assert.deepEqual(result.report?.reasons, ['merge-group-skip']);
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
  assert.deepEqual(result.report?.reasons, ['copilot-review-missing']);
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

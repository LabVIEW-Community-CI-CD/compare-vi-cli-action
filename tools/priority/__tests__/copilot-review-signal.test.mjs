import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'copilot-review-signal.js');

let builtModulePromise = null;

async function loadModule() {
  if (!builtModulePromise) {
    const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
    assert.equal(
      buildResult.status,
      0,
      [buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'),
    );
    builtModulePromise = import(`${pathToFileURL(distModulePath).href}?cache=${Date.now()}`);
  }

  return builtModulePromise;
}

function makePull(headSha) {
  return {
    number: 863,
    html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/863',
    state: 'OPEN',
    draft: false,
    updated_at: '2026-03-08T05:20:00Z',
    user: { login: 'svelderrainruiz' },
    head: { sha: headSha, ref: 'issue/863-copilot-review-signal' },
    base: {
      ref: 'develop',
      repo: {
        full_name: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      },
    },
  };
}

function makeThreads(nodes) {
  return {
    data: {
      repository: {
        pullRequest: {
          reviewThreads: {
            nodes,
          },
        },
      },
    },
  };
}

test('copilot review signal reports a clean current-head review state', async () => {
  const { analyzeCopilotReviewSignal } = await loadModule();
  const headSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const report = analyzeCopilotReviewSignal({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pull: makePull(headSha),
    reviews: [
      {
        id: 1,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Copilot reviewed 3 out of 3 changed files in this pull request and generated no comments.',
        html_url: 'https://github.com/example/review/1',
        submitted_at: '2026-03-08T05:21:00Z',
        commit_id: headSha,
      },
    ],
    threads: makeThreads([]),
    now: new Date('2026-03-08T05:22:00Z'),
  });

  assert.equal(report.status, 'pass');
  assert.equal(report.reviewState, 'clean');
  assert.equal(report.signals.hasCurrentHeadReview, true);
  assert.equal(report.signals.hasStaleReview, false);
  assert.equal(report.summary.unresolvedThreadCount, 0);
  assert.equal(report.summary.actionableCommentCount, 0);
  assert.equal(report.latestCopilotReview?.commitId, headSha);
});

test('copilot review signal detects stale reviews on older head SHAs', async () => {
  const { analyzeCopilotReviewSignal } = await loadModule();
  const headSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const oldSha = 'cccccccccccccccccccccccccccccccccccccccc';
  const report = analyzeCopilotReviewSignal({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pull: makePull(headSha),
    reviews: [
      {
        id: 2,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Copilot reviewed 6 out of 6 changed files in this pull request and generated 2 comments.',
        html_url: 'https://github.com/example/review/2',
        submitted_at: '2026-03-08T05:23:00Z',
        commit_id: oldSha,
      },
    ],
    threads: makeThreads([]),
    now: new Date('2026-03-08T05:24:00Z'),
  });

  assert.equal(report.reviewState, 'attention');
  assert.equal(report.signals.hasCurrentHeadReview, false);
  assert.equal(report.signals.hasStaleReview, true);
  assert.equal(report.summary.staleReviewCount, 1);
  assert.equal(report.latestCopilotReview?.isCurrentHead, false);
  assert.equal(report.staleReviews[0]?.commitId, oldSha);
});

test('copilot review signal detects unresolved actionable current-head threads', async () => {
  const { analyzeCopilotReviewSignal } = await loadModule();
  const headSha = 'dddddddddddddddddddddddddddddddddddddddd';
  const report = analyzeCopilotReviewSignal({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pull: makePull(headSha),
    reviews: [
      {
        id: 3,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Copilot reviewed 4 out of 4 changed files in this pull request and generated 1 comment.',
        html_url: 'https://github.com/example/review/3',
        submitted_at: '2026-03-08T05:25:00Z',
        commit_id: headSha,
      },
    ],
    threads: makeThreads([
      {
        id: 'PRRT_example_1',
        isResolved: false,
        isOutdated: false,
        path: 'tools/priority/dispatch-validate.mjs',
        line: 378,
        originalLine: 362,
        comments: {
          nodes: [
            {
              id: 'PRRC_example_1',
              body: 'Consider trimming whitespace-only sample ids before dispatch.',
              publishedAt: '2026-03-08T05:25:30Z',
              url: 'https://github.com/example/comment/1',
              author: { login: 'copilot-pull-request-reviewer' },
              pullRequestReview: {
                databaseId: 3,
                state: 'COMMENTED',
                author: { login: 'copilot-pull-request-reviewer' },
                submittedAt: '2026-03-08T05:25:00Z',
                commit: { oid: headSha },
              },
            },
          ],
        },
      },
    ]),
    now: new Date('2026-03-08T05:26:00Z'),
  });

  assert.equal(report.reviewState, 'attention');
  assert.equal(report.summary.unresolvedThreadCount, 1);
  assert.equal(report.summary.actionableThreadCount, 1);
  assert.equal(report.summary.actionableCommentCount, 1);
  assert.equal(report.signals.hasActionableComments, true);
  assert.equal(report.unresolvedThreads[0]?.actionable, true);
  assert.match(report.actionableComments[0]?.snippet ?? '', /sample ids/i);
});

test('copilot review signal records suppressed notes from the latest review body', async () => {
  const { analyzeCopilotReviewSignal } = await loadModule();
  const headSha = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
  const report = analyzeCopilotReviewSignal({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pull: makePull(headSha),
    reviews: [
      {
        id: 4,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: [
          '## Pull request overview',
          '',
          '<details>',
          '<summary>Comments suppressed due to low confidence (2)</summary>',
          '',
          'Low-confidence notes omitted.',
          '</details>',
        ].join('\n'),
        html_url: 'https://github.com/example/review/4',
        submitted_at: '2026-03-08T05:27:00Z',
        commit_id: headSha,
      },
    ],
    threads: makeThreads([]),
    now: new Date('2026-03-08T05:28:00Z'),
  });

  assert.equal(report.summary.suppressedNotesObservedInLatestReview, true);
  assert.equal(report.summary.suppressedNoteCountInLatestReview, 2);
  assert.equal(report.signals.hasSuppressedNotesInLatestReview, true);
  assert.equal(report.latestCopilotReview?.suppressedNoteCount, 2);
});

test('parseRepoSlug rejects repository slugs that do not have exactly two path segments', async () => {
  const { parseRepoSlug } = await loadModule();

  assert.throws(
    () => parseRepoSlug('LabVIEW-Community-CI-CD/compare-vi-cli-action/extra'),
    /Expected <owner>\/<repo>/,
  );
  assert.deepEqual(parseRepoSlug(' LabVIEW-Community-CI-CD / compare-vi-cli-action '), {
    owner: 'LabVIEW-Community-CI-CD',
    repo: 'compare-vi-cli-action',
  });
});

test('copilot review signal fails when the review-thread payload is truncated', async () => {
  const { analyzeCopilotReviewSignal } = await loadModule();
  const headSha = 'abababababababababababababababababababab';
  const report = analyzeCopilotReviewSignal({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pull: makePull(headSha),
    reviews: [
      {
        id: 5,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Current-head review body.',
        html_url: 'https://github.com/example/review/5',
        submitted_at: '2026-03-08T05:31:00Z',
        commit_id: headSha,
      },
    ],
    threads: {
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              pageInfo: {
                hasNextPage: true,
                endCursor: 'cursor:threads:100',
              },
              nodes: [],
            },
          },
        },
      },
    },
    now: new Date('2026-03-08T05:32:00Z'),
  });

  assert.equal(report.status, 'fail');
  assert.equal(report.reviewState, 'error');
  assert.match(report.errors[0] ?? '', /Pagination is required/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import {
  assertUpstreamOwnedHead,
  buildBranchClassTrace,
  buildMergeArgs,
  buildMergeSummaryPayload,
  buildPolicyTrace,
  classifyPromotionState,
  evaluatePromotionReviewClearance,
  isUpstreamOwnedHead,
  normalizeBaseRefName,
  runMergeSync,
  selectMergeMode,
  shouldRetryWithAuto,
  getMergeQueueBranches
} from '../merge-sync-pr.mjs';
import { classifyBranch, loadBranchClassContract } from '../lib/branch-classification.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const branchClassContract = loadBranchClassContract(repoRoot);

test('selectMergeMode chooses auto for policy-blocked merge states', () => {
  const selection = selectMergeMode({
    state: 'OPEN',
    isDraft: false,
    mergeStateStatus: 'BLOCKED',
    mergeable: 'MERGEABLE'
  });
  assert.equal(selection.mode, 'auto');
  assert.match(selection.reason, /merge-state-blocked/);
});

test('selectMergeMode maps unknown merge state to unknown reason when queue branch is absent', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'develop',
      mergeStateStatus: 'UNKNOWN',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'unknown-merge-state'
  });
});

test('selectMergeMode maps absent merge state with unset mergeable to merge-state-unspecified when queue branch is absent', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'develop'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-state-unspecified'
  });
});

test('selectMergeMode maps missing merge state to merge-state-unspecified when queue branch is absent', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'develop',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-state-unspecified'
  });
});

test('selectMergeMode maps empty merge state to merge-state-unspecified when queue branch is absent', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'develop',
      mergeStateStatus: '',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-state-unspecified'
  });
});

test('selectMergeMode chooses direct for clean mergeable PRs', () => {
  const selection = selectMergeMode({
    state: 'OPEN',
    isDraft: false,
    baseRefName: 'develop',
    mergeStateStatus: 'CLEAN',
    mergeable: 'MERGEABLE'
  });
  assert.deepEqual(selection, {
    mode: 'direct',
    reason: 'clean-mergeable'
  });
});

test('selectMergeMode chooses auto for merge-queue branches', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'main',
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-queue-branch-main'
  });
});

test('selectMergeMode honors branch-class merge policy for queue-managed upstream branches', () => {
  const baseBranchClass = classifyBranch({
    branch: 'develop',
    contract: branchClassContract,
    repositoryRole: 'upstream'
  });

  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'develop',
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(),
      baseBranchClass
    }
  );

  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-queue-branch-develop'
  });
});

test('selectMergeMode ignores legacy mergeQueueBranches when branch-class policy is non-queue', () => {
  const baseBranchClass = classifyBranch({
    branch: 'develop',
    contract: branchClassContract,
    repositoryRole: 'fork'
  });

  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'develop',
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['develop']),
      baseBranchClass
    }
  );

  assert.deepEqual(selection, {
    mode: 'direct',
    reason: 'clean-mergeable'
  });
});

test('buildMergeArgs omits --delete-branch for merge-queue auto mode', () => {
  const args = buildMergeArgs({
    pr: 1015,
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    method: 'squash',
    mode: 'auto',
    keepBranch: false
  });

  assert.deepEqual(args, [
    'pr',
    'merge',
    '1015',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--squash',
    '--auto'
  ]);
});

test('buildMergeArgs keeps --delete-branch for direct merges when branch cleanup is requested', () => {
  const args = buildMergeArgs({
    pr: 1015,
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    method: 'squash',
    mode: 'direct',
    keepBranch: false
  });

  assert.deepEqual(args, [
    'pr',
    'merge',
    '1015',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--squash',
    '--delete-branch'
  ]);
});

test('selectMergeMode keeps queue reason stable for refs/heads base branch values', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'refs/heads/Main',
      mergeStateStatus: 'UNSTABLE',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-queue-branch-main'
  });
});

test('selectMergeMode preserves queue reason precedence when merge state is unknown', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'refs/heads/main',
      mergeStateStatus: 'UNKNOWN',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-queue-branch-main'
  });
});

test('selectMergeMode preserves queue reason precedence when mergeable is unset and merge state is absent', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'refs/heads/main'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-queue-branch-main'
  });
});

test('selectMergeMode preserves queue reason precedence when merge state is missing', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      baseRefName: 'refs/heads/main',
      mergeable: 'MERGEABLE'
    },
    {
      mergeQueueBranches: new Set(['main'])
    }
  );
  assert.deepEqual(selection, {
    mode: 'auto',
    reason: 'merge-queue-branch-main'
  });
});

test('selectMergeMode honors explicit admin override', () => {
  const selection = selectMergeMode(
    {
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE'
    },
    { admin: true }
  );
  assert.deepEqual(selection, {
    mode: 'admin',
    reason: 'explicit-admin-override'
  });
});

test('selectMergeMode throws on conflicting or dirty PRs', () => {
  assert.throws(
    () =>
      selectMergeMode({
        state: 'OPEN',
        isDraft: false,
        mergeStateStatus: 'DIRTY',
        mergeable: 'CONFLICTING'
      }),
    /merge conflicts/i
  );
});

test('selectMergeMode returns none when PR is already merged', () => {
  const selection = selectMergeMode({
    state: 'MERGED',
    mergeStateStatus: 'CLEAN',
    mergeable: 'MERGEABLE'
  });
  assert.deepEqual(selection, {
    mode: 'none',
    reason: 'already-merged'
  });
});

test('shouldRetryWithAuto detects policy-blocked direct merge failures', () => {
  assert.equal(
    shouldRetryWithAuto({
      mode: 'direct',
      stderr: 'Base branch policy requires merge queue; direct merge blocked.'
    }),
    true
  );
  assert.equal(
    shouldRetryWithAuto({
      mode: 'direct',
      stderr: 'Merge conflict detected'
    }),
    false
  );
  assert.equal(
    shouldRetryWithAuto({
      mode: 'auto',
      stderr: 'Base branch policy requires merge queue'
    }),
    false
  );
});

test('buildMergeArgs omits --delete-branch for auto merges so merge-queue branches can enqueue cleanly', () => {
  assert.deepEqual(buildMergeArgs({
    pr: 1017,
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    method: 'squash',
    mode: 'auto',
    keepBranch: false
  }), [
    'pr',
    'merge',
    '1017',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--squash',
    '--auto'
  ]);
});

test('getMergeQueueBranches returns exact queue-managed branches from policy rulesets', () => {
  const policy = {
    rulesets: {
      develop: {
        includes: ['refs/heads/develop'],
        merge_queue: null
      },
      main: {
        includes: ['refs/heads/main'],
        merge_queue: {
          merge_method: 'SQUASH'
        }
      },
      release: {
        includes: ['refs/heads/release/*'],
        merge_queue: {
          merge_method: 'SQUASH'
        }
      }
    }
  };

  const branches = getMergeQueueBranches(policy);
  assert.deepEqual(Array.from(branches).sort(), ['main']);
});

test('buildPolicyTrace emits deterministic sorted queue branch metadata', () => {
  const trace = buildPolicyTrace(new Set(['main', 'develop', 'main']));
  assert.deepEqual(trace, {
    manifestPath: 'tools/priority/policy.json',
    mergeQueueBranches: ['develop', 'main']
  });
});

test('buildBranchClassTrace emits deterministic base-branch classification metadata', () => {
  const baseBranchClass = classifyBranch({
    branch: 'develop',
    contract: branchClassContract,
    repositoryRole: 'upstream'
  });

  assert.deepEqual(
    buildBranchClassTrace({
      targetRepositoryRole: 'upstream',
      baseBranchClass
    }),
    {
      contractPath: 'tools/policy/branch-classes.json',
      targetRepositoryRole: 'upstream',
      baseBranchClassId: 'upstream-integration',
      baseBranchMergePolicy: 'merge-queue-squash',
      baseBranchPattern: 'develop'
    }
  );
});

test('buildMergeSummaryPayload remains stable for direct mode contracts', () => {
  const payload = buildMergeSummaryPayload({
    repo: 'owner/repo',
    pr: 123,
    mergeMethod: 'squash',
    selectedMode: 'direct',
    selectedReason: 'clean-mergeable',
    finalMode: 'direct',
    finalReason: 'clean-mergeable',
    dryRun: true,
    mergeQueueBranches: new Set(['main']),
    attempts: [{ mode: 'direct', args: ['pr', 'merge'], exitCode: 0 }],
    prInfo: {
      state: 'OPEN',
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      isDraft: false,
      url: 'https://example.test/pr/123'
    },
    createdAt: '2026-03-03T00:00:00.000Z'
  });

  assert.equal(payload.schema, 'priority/sync-merge@v1');
  assert.equal(payload.selectedMode, 'direct');
  assert.equal(payload.finalMode, 'direct');
  assert.equal(payload.prState.baseRefName, 'develop');
  assert.deepEqual(payload.policyTrace.mergeQueueBranches, ['main']);
  assert.equal(payload.createdAt, '2026-03-03T00:00:00.000Z');
});

test('buildMergeSummaryPayload captures auto mode policy-driven selection details', () => {
  const baseBranchClass = classifyBranch({
    branch: 'main',
    contract: branchClassContract,
    repositoryRole: 'upstream'
  });
  const payload = buildMergeSummaryPayload({
    repo: 'owner/repo',
    pr: 456,
    mergeMethod: 'squash',
    selectedMode: 'auto',
    selectedReason: 'merge-queue-branch-main',
    finalMode: 'auto',
    finalReason: 'merge-queue-branch-main',
    dryRun: false,
    mergeQueueBranches: new Set(['main']),
    attempts: [{ mode: 'auto', args: ['pr', 'merge', '--auto'], exitCode: 0 }],
    prInfo: {
      state: 'OPEN',
      mergeStateStatus: 'BLOCKED',
      mergeable: 'MERGEABLE',
      baseRefName: 'refs/heads/main',
      isDraft: false,
      url: 'https://example.test/pr/456'
    },
    branchClassTrace: buildBranchClassTrace({
      targetRepositoryRole: 'upstream',
      baseBranchClass
    }),
    createdAt: '2026-03-03T00:00:01.000Z'
  });

  assert.equal(payload.selectedMode, 'auto');
  assert.equal(payload.finalReason, 'merge-queue-branch-main');
  assert.equal(payload.prState.baseRefName, 'main');
  assert.deepEqual(payload.policyTrace.mergeQueueBranches, ['main']);
  assert.equal(payload.branchClassTrace.baseBranchClassId, 'upstream-release');
});

test('normalizeBaseRefName handles refs prefix and casing', () => {
  assert.equal(normalizeBaseRefName('refs/heads/Main'), 'main');
  assert.equal(normalizeBaseRefName('DEVELOP'), 'develop');
  assert.equal(normalizeBaseRefName(''), '');
  assert.equal(normalizeBaseRefName(undefined), '');
});

test('buildMergeSummaryPayload captures admin override selection details', () => {
  const payload = buildMergeSummaryPayload({
    repo: 'owner/repo',
    pr: 789,
    mergeMethod: 'rebase',
    selectedMode: 'admin',
    selectedReason: 'explicit-admin-override',
    finalMode: 'admin',
    finalReason: 'explicit-admin-override',
    dryRun: false,
    mergeQueueBranches: new Set(['main']),
    attempts: [{ mode: 'admin', args: ['pr', 'merge', '--admin'], exitCode: 0 }],
    prInfo: {
      state: 'OPEN',
      mergeStateStatus: 'UNSTABLE',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      isDraft: false,
      url: 'https://example.test/pr/789'
    },
    createdAt: '2026-03-03T00:00:02.000Z'
  });

  assert.equal(payload.selectedMode, 'admin');
  assert.equal(payload.finalMode, 'admin');
  assert.equal(payload.selectedReason, 'explicit-admin-override');
  assert.equal(payload.prState.baseRefName, 'develop');
  assert.equal(payload.attempts.length, 1);
});

test('buildMergeSummaryPayload preserves direct-to-auto retry attempt sequence', () => {
  const payload = buildMergeSummaryPayload({
    repo: 'owner/repo',
    pr: 910,
    mergeMethod: 'squash',
    selectedMode: 'direct',
    selectedReason: 'clean-mergeable',
    finalMode: 'auto',
    finalReason: 'direct-merge-policy-block-retry-auto',
    dryRun: false,
    mergeQueueBranches: new Set(['main']),
    attempts: [
      { mode: 'direct', args: ['pr', 'merge', '--squash'], exitCode: 1 },
      { mode: 'auto', args: ['pr', 'merge', '--squash', '--auto'], exitCode: 0 }
    ],
    prInfo: {
      state: 'OPEN',
      mergeStateStatus: 'UNSTABLE',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      isDraft: false,
      url: 'https://example.test/pr/910'
    },
    createdAt: '2026-03-03T00:00:03.000Z'
  });

  assert.equal(payload.selectedMode, 'direct');
  assert.equal(payload.finalMode, 'auto');
  assert.equal(payload.finalReason, 'direct-merge-policy-block-retry-auto');
  assert.deepEqual(
    payload.attempts.map((attempt) => ({ mode: attempt.mode, exitCode: attempt.exitCode })),
    [
      { mode: 'direct', exitCode: 1 },
      { mode: 'auto', exitCode: 0 }
    ]
  );
});

test('buildMergeSummaryPayload preserves selected/final reason fields for diagnostics', () => {
  const payload = buildMergeSummaryPayload({
    repo: 'owner/repo',
    pr: 911,
    mergeMethod: 'squash',
    selectedMode: 'auto',
    selectedReason: 'merge-state-unstable',
    finalMode: 'auto',
    finalReason: 'direct-merge-policy-block-retry-auto',
    dryRun: false,
    mergeQueueBranches: new Set(['main']),
    attempts: [
      { mode: 'direct', args: ['pr', 'merge', '--squash'], exitCode: 1 },
      { mode: 'auto', args: ['pr', 'merge', '--squash', '--auto'], exitCode: 0 }
    ],
    prInfo: {
      state: 'OPEN',
      mergeStateStatus: 'UNSTABLE',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      isDraft: false,
      url: 'https://example.test/pr/911'
    },
    createdAt: '2026-03-03T00:00:04.000Z'
  });

  assert.equal(payload.selectedReason, 'merge-state-unstable');
  assert.equal(payload.finalReason, 'direct-merge-policy-block-retry-auto');
});

test('classifyPromotionState reports queued and already-queued distinctly', () => {
  assert.deepEqual(
    classifyPromotionState(
      {
        state: 'OPEN',
        isInMergeQueue: false,
        autoMergeRequest: null
      },
      {
        state: 'OPEN',
        isInMergeQueue: true,
        autoMergeRequest: null
      },
      { finalMode: 'auto' }
    ),
    {
      status: 'queued',
      materialized: true,
      finalMode: 'auto',
      initial: {
        state: 'OPEN',
        mergeStateStatus: null,
        isInMergeQueue: false,
        autoMergeEnabled: false,
        mergedAt: null
      },
      final: {
        state: 'OPEN',
        mergeStateStatus: null,
        isInMergeQueue: true,
        autoMergeEnabled: false,
        mergedAt: null
      }
    }
  );

  assert.equal(
    classifyPromotionState(
      {
        state: 'OPEN',
        isInMergeQueue: true,
        autoMergeRequest: null
      },
      {
        state: 'OPEN',
        isInMergeQueue: true,
        autoMergeRequest: null
      },
      { finalMode: 'auto' }
    ).status,
    'already-queued'
  );
});

test('runMergeSync records queued promotion state after auto merge activation materializes', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-queued-'));
  const promotionStates = [
    {
      state: 'OPEN',
      mergeStateStatus: 'BLOCKED',
      isInMergeQueue: false,
      autoMergeRequest: null,
      mergedAt: null
    },
    {
      state: 'OPEN',
      mergeStateStatus: 'BLOCKED',
      isInMergeQueue: true,
      autoMergeRequest: null,
      mergedAt: null
    }
  ];
  let promotionReads = 0;
  const payload = await runMergeSync({
    argv: [
      'node',
      'tools/priority/merge-sync-pr.mjs',
      '--pr',
      '123',
      '--repo',
      'owner/repo',
      '--summary-path',
      path.join(tempDir, 'summary.json')
    ],
    repoRoot,
    ensureGhCliFn: () => {},
    readPrInfoFn: () => ({
      number: 123,
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'BLOCKED',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      headRefOid: '1234567890123456789012345678901234567890',
      url: 'https://example.test/pr/123'
    }),
    evaluatePromotionReviewClearanceFn: async () => ({
      ok: true,
      report: {
        status: 'pass',
        gateState: 'ready',
        reasons: ['current-head-review-run-completed-clean']
      }
    }),
    readPromotionStateFn: () => {
      const value = promotionStates[Math.min(promotionReads, promotionStates.length - 1)];
      promotionReads += 1;
      return structuredClone(value);
    },
    runMergeAttemptFn: () => ({ status: 0, stdout: 'queued', stderr: '' }),
    sleepFn: async () => {}
  });

  assert.equal(payload.promotion.status, 'queued');
  assert.equal(payload.promotion.materialized, true);
  assert.ok(payload.promotion.pollAttemptsUsed >= 1);

  const written = JSON.parse(await readFile(path.join(tempDir, 'summary.json'), 'utf8'));
  assert.equal(written.promotion.status, 'queued');
});

test('runMergeSync fails when auto merge command succeeds but no durable promotion state appears', async () => {
  await assert.rejects(
    () =>
      runMergeSync({
        argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '124', '--repo', 'owner/repo'],
        repoRoot,
        ensureGhCliFn: () => {},
        readPrInfoFn: () => ({
          number: 124,
          state: 'OPEN',
          isDraft: false,
          mergeStateStatus: 'BLOCKED',
          mergeable: 'MERGEABLE',
          baseRefName: 'develop',
          headRefOid: '1234567890123456789012345678901234567890',
          url: 'https://example.test/pr/124'
        }),
        evaluatePromotionReviewClearanceFn: async () => ({
          ok: true,
          report: {
            status: 'pass',
            gateState: 'ready',
            reasons: ['current-head-review-run-completed-clean']
          }
        }),
        readPromotionStateFn: () => ({
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: false,
          autoMergeRequest: null,
          mergedAt: null
        }),
        runMergeAttemptFn: () => ({ status: 0, stdout: 'queued', stderr: '' }),
        sleepFn: async () => {}
      }),
    /no durable promotion state was observed/
  );
});

test('evaluatePromotionReviewClearance summarizes a passing current-head no-comment review run', async () => {
  const result = await evaluatePromotionReviewClearance({
    repoRoot,
    repo: 'owner/repo',
    pr: 125,
    prInfo: {
      isDraft: false,
      baseRefName: 'develop',
      headRefOid: '1234567890123456789012345678901234567890'
    },
    runCopilotReviewGateFn: async () => ({
      exitCode: 0,
      report: {
        status: 'pass',
        gateState: 'ready',
        reasons: ['current-head-review-run-completed-clean'],
        summary: {
          actionableCommentCount: 0,
          actionableThreadCount: 0
        },
        signals: {
          hasCurrentHeadReview: false,
          latestReviewIsCurrentHead: false,
          reviewRunCompletedClean: true
        }
      }
    })
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.report, {
    status: 'pass',
    gateState: 'ready',
    reasons: ['current-head-review-run-completed-clean'],
    actionableCommentCount: 0,
    actionableThreadCount: 0,
    hasCurrentHeadReview: false,
    latestReviewIsCurrentHead: false,
    reviewRunCompletedClean: true
  });
});

test('runMergeSync fails closed when current-head Copilot comments remain unresolved', async () => {
  let mergeAttempted = false;
  await assert.rejects(
    () =>
      runMergeSync({
        argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '124', '--repo', 'owner/repo'],
        repoRoot,
        ensureGhCliFn: () => {},
        readPrInfoFn: () => ({
          number: 124,
          state: 'OPEN',
          isDraft: false,
          mergeStateStatus: 'BLOCKED',
          mergeable: 'MERGEABLE',
          baseRefName: 'develop',
          headRefOid: '1234567890123456789012345678901234567890',
          url: 'https://example.test/pr/124'
        }),
        readPromotionStateFn: () => ({
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: false,
          autoMergeRequest: null,
          mergedAt: null
        }),
        evaluatePromotionReviewClearanceFn: async () => ({
          ok: false,
          report: {
            status: 'fail',
            gateState: 'blocked',
            reasons: ['actionable-comments-present']
          }
        }),
        runMergeAttemptFn: () => {
          mergeAttempted = true;
          return { status: 0, stdout: '', stderr: '' };
        },
        sleepFn: async () => {}
      }),
    /actionable-comments-present/
  );

  assert.equal(mergeAttempted, false);
});

test('runMergeSync includes review clearance evidence when clean current-head admission is allowed', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-review-clearance-'));
  const payload = await runMergeSync({
    argv: [
      'node',
      'tools/priority/merge-sync-pr.mjs',
      '--pr',
      '127',
      '--repo',
      'owner/repo',
      '--summary-path',
      path.join(tempDir, 'summary.json')
    ],
    repoRoot,
    ensureGhCliFn: () => {},
    readPrInfoFn: () => ({
      number: 127,
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'BLOCKED',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      headRefOid: '1234567890123456789012345678901234567890',
      url: 'https://example.test/pr/127'
    }),
    evaluatePromotionReviewClearanceFn: async () => ({
      ok: true,
      report: {
        status: 'pass',
        gateState: 'ready',
        reasons: ['current-head-review-run-completed-clean'],
        actionableCommentCount: 0,
        actionableThreadCount: 0,
        hasCurrentHeadReview: false,
        latestReviewIsCurrentHead: false,
        reviewRunCompletedClean: true
      }
    }),
    readPromotionStateFn: (() => {
      let reads = 0;
      return () => {
        reads += 1;
        return reads === 1
          ? {
              state: 'OPEN',
              mergeStateStatus: 'BLOCKED',
              isInMergeQueue: false,
              autoMergeRequest: null,
              mergedAt: null
            }
          : {
              state: 'OPEN',
              mergeStateStatus: 'BLOCKED',
              isInMergeQueue: true,
              autoMergeRequest: null,
              mergedAt: null
            };
      };
    })(),
    runMergeAttemptFn: () => ({ status: 0, stdout: 'queued', stderr: '' }),
    sleepFn: async () => {}
  });

  assert.equal(payload.reviewClearance.status, 'pass');
  assert.deepEqual(payload.reviewClearance.reasons, ['current-head-review-run-completed-clean']);

  const written = JSON.parse(await readFile(path.join(tempDir, 'summary.json'), 'utf8'));
  assert.equal(written.reviewClearance.status, 'pass');
  assert.deepEqual(written.reviewClearance.reasons, ['current-head-review-run-completed-clean']);
});

test('runMergeSync does not query promotion state when the PR is already merged', async () => {
  let promotionReads = 0;
  const payload = await runMergeSync({
    argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '125', '--repo', 'owner/repo'],
    repoRoot,
    ensureGhCliFn: () => {},
    readPrInfoFn: () => ({
      number: 125,
      state: 'MERGED',
      isDraft: false,
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      url: 'https://example.test/pr/125'
    }),
    readPromotionStateFn: () => {
      promotionReads += 1;
      throw new Error('should not be called');
    }
  });

  assert.equal(promotionReads, 0);
  assert.equal(payload.finalMode, 'none');
  assert.equal(payload.promotion.status, 'already-merged');
});

test('runMergeSync rejects repo slugs with extra path segments', async () => {
  await assert.rejects(
    () =>
      runMergeSync({
        argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '126', '--repo', 'owner/repo/extra'],
        repoRoot,
        ensureGhCliFn: () => {},
        readPrInfoFn: () => ({
          number: 126,
          state: 'OPEN',
          isDraft: false,
          mergeStateStatus: 'BLOCKED',
          mergeable: 'MERGEABLE',
          baseRefName: 'develop',
          url: 'https://example.test/pr/126'
        }),
        readPromotionStateFn: () => ({
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: false,
          autoMergeRequest: null,
          mergedAt: null
        }),
        runMergeAttemptFn: () => ({ status: 0, stdout: '', stderr: '' }),
        sleepFn: async () => {}
      }),
    /Invalid repo slug/
  );
});

test('isUpstreamOwnedHead returns true only when PR head owner matches repo owner', () => {
  assert.equal(
    isUpstreamOwnedHead(
      {
        headRepositoryOwner: { login: 'LabVIEW-Community-CI-CD' }
      },
      'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    ),
    true
  );
  assert.equal(
    isUpstreamOwnedHead(
      {
        headRepositoryOwner: { login: 'svelderrainruiz' }
      },
      'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    ),
    false
  );
});

test('assertUpstreamOwnedHead returns false for fork-headed PRs without blocking merge automation', () => {
  assert.equal(
    assertUpstreamOwnedHead(
      {
        state: 'OPEN',
        headRepositoryOwner: { login: 'svelderrainruiz' }
      },
      'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    ),
    false
  );
});

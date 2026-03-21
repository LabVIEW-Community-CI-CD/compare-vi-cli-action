import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import {
  assertUpstreamOwnedHead,
  buildBranchClassTrace,
  buildMergeArgs,
  buildMergeSummaryPayload,
  buildPolicyTrace,
  classifyPromotionState,
  deleteHeadBranchRef,
  deleteMergedHeadBranch,
  evaluatePromotionReviewClearance,
  hasDeferredPostMergeBranchCleanup,
  isQueueManagedBaseBranch,
  loadMergeSyncCopilotReviewStrategy,
  normalizeRepositoryMergeCapabilities,
  normalizeCopilotReviewStrategy,
  reconcileDeferredBranchCleanup,
  readRepositoryMergeCapabilities,
  resolveBranchCleanupPlan,
  resolveReadyValidationClearancePath,
  isUpstreamOwnedHead,
  normalizeBaseRefName,
  runMergeSync,
  selectMergeMethod,
  selectMergeMode,
  shouldRetryWithAuto,
  getMergeQueueBranches
} from '../merge-sync-pr.mjs';
import { classifyBranch, loadBranchClassContract } from '../lib/branch-classification.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const branchClassContract = loadBranchClassContract(repoRoot);
const DEFAULT_REPOSITORY_MERGE_CAPABILITIES = normalizeRepositoryMergeCapabilities({
  allow_merge_commit: false,
  allow_squash_merge: true,
  allow_rebase_merge: true
});

function buildRepositoryMergeCapabilities(overrides = {}) {
  return {
    ...DEFAULT_REPOSITORY_MERGE_CAPABILITIES,
    ...overrides,
    supportedMethods: Array.isArray(overrides.supportedMethods)
      ? [...overrides.supportedMethods]
      : Array.isArray(DEFAULT_REPOSITORY_MERGE_CAPABILITIES.supportedMethods)
        ? [...DEFAULT_REPOSITORY_MERGE_CAPABILITIES.supportedMethods]
        : []
  };
}

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

test('isQueueManagedBaseBranch honors branch-class merge policy and normalized base refs', () => {
  const baseBranchClass = classifyBranch({
    branch: 'develop',
    contract: branchClassContract,
    repositoryRole: 'upstream'
  });

  assert.equal(
    isQueueManagedBaseBranch({
      baseRefName: 'refs/heads/develop',
      mergeQueueBranches: new Set(),
      baseBranchClass
    }),
    true
  );
  assert.equal(
    isQueueManagedBaseBranch({
      baseRefName: 'refs/heads/main',
      mergeQueueBranches: new Set(['main'])
    }),
    true
  );
});

test('resolveBranchCleanupPlan switches queue-managed admin merges to post-merge cleanup', () => {
  const baseBranchClass = classifyBranch({
    branch: 'develop',
    contract: branchClassContract,
    repositoryRole: 'upstream'
  });

  assert.deepEqual(
    resolveBranchCleanupPlan({
      keepBranch: false,
      mode: 'admin',
      baseRefName: 'develop',
      mergeQueueBranches: new Set(),
      baseBranchClass
    }),
    {
      requested: true,
      inlineDeleteBranch: false,
      postMergeDelete: true,
      reason: 'post-merge-api-delete'
    }
  );
});

test('resolveBranchCleanupPlan uses post-merge cleanup for auto mode', () => {
  assert.deepEqual(
    resolveBranchCleanupPlan({
      keepBranch: false,
      mode: 'auto',
      baseRefName: 'develop',
      mergeQueueBranches: new Set(['develop'])
    }),
    {
      requested: true,
      inlineDeleteBranch: false,
      postMergeDelete: true,
      reason: 'post-merge-api-delete'
    }
  );
});

test('buildMergeArgs omits --delete-branch when inline cleanup is disabled for admin merges', () => {
  assert.deepEqual(
    buildMergeArgs({
      pr: 1018,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      method: 'squash',
      mode: 'admin',
      keepBranch: false,
      inlineDeleteBranch: false
    }),
    [
      'pr',
      'merge',
      '1018',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--squash',
      '--admin'
    ]
  );
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

test('buildMergeArgs ignores explicit inline delete requests for auto merges', () => {
  assert.deepEqual(buildMergeArgs({
    pr: 1017,
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    method: 'squash',
    mode: 'auto',
    keepBranch: false,
    inlineDeleteBranch: true
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

test('deleteMergedHeadBranch treats an already-absent branch as a successful cleanup outcome', () => {
  const cleanup = deleteMergedHeadBranch({
    repoRoot,
    prInfo: {
      headRefName: 'issue/origin-1397-test-branch',
      headRepository: { name: 'compare-vi-cli-action-fork' },
      headRepositoryOwner: { login: 'LabVIEW-Community-CI-CD' }
    },
    spawnSyncFn: () => ({
      status: 1,
      stdout: '',
      stderr: 'gh: Not Found (HTTP 404)\n'
    })
  });

  assert.equal(cleanup.status, 'already-absent');
  assert.equal(cleanup.repository, 'labview-community-ci-cd/compare-vi-cli-action-fork');
  assert.equal(cleanup.headRefName, 'issue/origin-1397-test-branch');
});

test('deleteHeadBranchRef emits queue-safe dry-run cleanup output', () => {
  const cleanup = deleteHeadBranchRef({
    repoRoot,
    headRepositorySlug: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
    headRefName: 'issue/origin-1430-test-branch',
    dryRun: true
  });

  assert.equal(cleanup.status, 'dry-run');
  assert.equal(cleanup.repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork');
  assert.equal(cleanup.headRefName, 'issue/origin-1430-test-branch');
});

test('hasDeferredPostMergeBranchCleanup detects queued auto-merge cleanup receipts', () => {
  assert.equal(hasDeferredPostMergeBranchCleanup({
    branchCleanup: {
      requested: true,
      status: 'deferred',
      postMergeDelete: true
    }
  }), true);

  assert.equal(hasDeferredPostMergeBranchCleanup({
    branchCleanup: {
      requested: true,
      status: 'inline-requested',
      postMergeDelete: false
    }
  }), false);

  assert.equal(hasDeferredPostMergeBranchCleanup({
    finalMode: 'auto',
    branchCleanup: {
      requested: true,
      status: 'deferred',
      postMergeDelete: false,
      inlineDeleteBranch: false
    }
  }), true);
});

test('reconcileDeferredBranchCleanup completes deferred cleanup once queued promotion materializes', async () => {
  const cleanupCalls = [];
  const result = await reconcileDeferredBranchCleanup({
    repoRoot,
    summary: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pr: 1430,
      finalMode: 'auto',
      promotion: {
        initial: {
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: false,
          autoMergeEnabled: false,
          mergedAt: null
        },
        final: {
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: true,
          autoMergeEnabled: true,
          mergedAt: null
        },
        status: 'queued',
        materialized: true
      },
      branchCleanup: {
        requested: true,
        attempted: false,
        status: 'deferred',
        reason: 'promotion-not-yet-merged',
        postMergeDelete: true,
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
        headRefName: 'issue/origin-1430-queue-auto-branch-cleanup'
      }
    },
    readPromotionStateFn: () => ({
      state: 'MERGED',
      mergeStateStatus: 'CLEAN',
      isInMergeQueue: false,
      autoMergeRequest: null,
      mergedAt: '2026-03-20T02:15:00Z'
    }),
    deleteHeadBranchRefFn: ({ headRepositorySlug, headRefName, dryRun }) => {
      cleanupCalls.push({ headRepositorySlug, headRefName, dryRun });
      return {
        requested: true,
        attempted: true,
        status: 'deleted',
        reason: 'post-merge-api-delete',
        repository: headRepositorySlug,
        headRefName
      };
    },
    observedAt: '2026-03-20T02:16:00Z'
  });

  assert.equal(result.changed, true);
  assert.equal(result.status, 'completed');
  assert.equal(result.promotion.status, 'merged');
  assert.equal(result.summary.branchCleanup.status, 'deleted');
  assert.equal(result.summary.reconciledAt, '2026-03-20T02:16:00Z');
  assert.deepEqual(cleanupCalls, [{
    headRepositorySlug: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
    headRefName: 'issue/origin-1430-queue-auto-branch-cleanup',
    dryRun: false
  }]);
});

test('reconcileDeferredBranchCleanup leaves queued auto-merge cleanup deferred until merged', async () => {
  const result = await reconcileDeferredBranchCleanup({
    repoRoot,
    summary: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pr: 1430,
      finalMode: 'auto',
      promotion: {
        initial: {
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: false,
          autoMergeEnabled: false,
          mergedAt: null
        }
      },
      branchCleanup: {
        requested: true,
        attempted: false,
        status: 'deferred',
        reason: 'promotion-not-yet-merged',
        postMergeDelete: true,
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
        headRefName: 'issue/origin-1430-queue-auto-branch-cleanup'
      }
    },
    readPromotionStateFn: () => ({
      state: 'OPEN',
      mergeStateStatus: 'BLOCKED',
      isInMergeQueue: true,
      autoMergeRequest: { enabledAt: '2026-03-20T02:14:00Z' },
      mergedAt: null
    })
  });

  assert.equal(result.changed, false);
  assert.equal(result.status, 'deferred');
  assert.equal(result.promotion.status, 'queued');
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

test('buildMergeSummaryPayload carries the resolved plane transition when promotion crosses planes', () => {
  const payload = buildMergeSummaryPayload({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pr: 912,
    mergeMethod: 'squash',
    selectedMode: 'auto',
    selectedReason: 'merge-queue-branch-develop',
    finalMode: 'auto',
    finalReason: 'merge-queue-branch-develop',
    dryRun: false,
    mergeQueueBranches: new Set(['develop']),
    attempts: [{ mode: 'auto', args: ['pr', 'merge', '--auto'], exitCode: 0 }],
    prInfo: {
      state: 'OPEN',
      mergeStateStatus: 'BLOCKED',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      isDraft: false,
      headRepository: { name: 'compare-vi-cli-action' },
      headRepositoryOwner: { login: 'svelderrainruiz' },
      url: 'https://example.test/pr/912'
    },
    planeTransition: {
      from: 'personal',
      action: 'promote',
      to: 'upstream',
      via: 'pull-request',
      branchClass: 'lane'
    },
    createdAt: '2026-03-14T00:00:00.000Z'
  });

  assert.deepEqual(payload.planeTransition, {
    from: 'personal',
    action: 'promote',
    to: 'upstream',
    via: 'pull-request',
    branchClass: 'lane'
  });
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

test('normalizeRepositoryMergeCapabilities maps GitHub repo fields into supported merge methods', () => {
  const capabilities = normalizeRepositoryMergeCapabilities({
    allow_merge_commit: false,
    allow_squash_merge: true,
    allow_rebase_merge: true
  });

  assert.deepEqual(capabilities, {
    allowMergeCommit: false,
    allowSquashMerge: true,
    allowRebaseMerge: true,
    supportedMethods: ['squash', 'rebase']
  });
});

test('selectMergeMethod keeps the preferred default when the repository supports squash', () => {
  const selection = selectMergeMethod({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    requestedMethod: 'squash',
    requestedSource: 'default',
    capabilities: buildRepositoryMergeCapabilities({
      supportedMethods: ['squash', 'rebase']
    })
  });

  assert.deepEqual(selection, {
    requestedMethod: 'squash',
    requestedSource: 'default',
    effectiveMethod: 'squash',
    reason: 'default-preferred-supported',
    capabilities: buildRepositoryMergeCapabilities({
      supportedMethods: ['squash', 'rebase']
    })
  });
});

test('selectMergeMethod falls back to a supported method when the default is disabled by repo policy', () => {
  const selection = selectMergeMethod({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    requestedMethod: 'squash',
    requestedSource: 'default',
    capabilities: buildRepositoryMergeCapabilities({
      allowSquashMerge: false,
      supportedMethods: ['rebase']
    })
  });

  assert.equal(selection.effectiveMethod, 'rebase');
  assert.equal(selection.reason, 'default-fallback-rebase');
});

test('selectMergeMethod fails closed when an explicit unsupported method is requested', () => {
  assert.throws(
    () =>
      selectMergeMethod({
        repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        requestedMethod: 'merge',
        requestedSource: 'cli',
        capabilities: buildRepositoryMergeCapabilities({
          allowMergeCommit: false,
          supportedMethods: ['squash', 'rebase']
        })
      }),
    /does not allow requested merge method 'merge'/i
  );
});

test('readRepositoryMergeCapabilities uses the repo REST endpoint and normalizes support flags', () => {
  let observedArgs = null;
  const capabilities = readRepositoryMergeCapabilities({
    repoRoot: '/tmp/repo',
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runGhJsonFn: (_repoRoot, args) => {
      observedArgs = args;
      return {
        allow_merge_commit: false,
        allow_squash_merge: true,
        allow_rebase_merge: false
      };
    }
  });

  assert.deepEqual(observedArgs, ['api', 'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action']);
  assert.deepEqual(capabilities, {
    allowMergeCommit: false,
    allowSquashMerge: true,
    allowRebaseMerge: false,
    supportedMethods: ['squash']
  });
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

test('normalizeCopilotReviewStrategy defaults and accepts the local-only strategy', () => {
  assert.equal(normalizeCopilotReviewStrategy(null), 'github-review-required');
  assert.equal(normalizeCopilotReviewStrategy('draft-only-explicit'), 'draft-only-explicit');
  assert.throws(() => normalizeCopilotReviewStrategy('disabled'), /Unsupported copilotReviewStrategy/);
});

test('loadMergeSyncCopilotReviewStrategy reads delivery-agent policy and falls back when absent', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-policy-'));
  await mkdir(path.join(tempDir, 'tools', 'priority'), { recursive: true });
  await writeFile(
    path.join(tempDir, 'tools', 'priority', 'delivery-agent.policy.json'),
    `${JSON.stringify({ copilotReviewStrategy: 'draft-only-explicit' })}\n`,
    'utf8'
  );

  assert.equal(await loadMergeSyncCopilotReviewStrategy({ repoRoot: tempDir }), 'draft-only-explicit');
  assert.equal(
    await loadMergeSyncCopilotReviewStrategy({ repoRoot: path.join(tempDir, 'missing-policy-root') }),
    'github-review-required'
  );
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
  const mergeArgs = [];
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
    readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
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
    runMergeAttemptFn: ({ args }) => {
      mergeArgs.push(args);
      return { status: 0, stdout: 'queued', stderr: '' };
    },
    sleepFn: async () => {}
  });

  assert.deepEqual(mergeArgs, [[
    'pr',
    'merge',
    '123',
    '--repo',
    'owner/repo',
    '--squash',
    '--auto'
  ]]);
  assert.equal(payload.promotion.status, 'queued');
  assert.equal(payload.promotion.materialized, true);
  assert.ok(payload.promotion.pollAttemptsUsed >= 1);

  const written = JSON.parse(await readFile(path.join(tempDir, 'summary.json'), 'utf8'));
  assert.equal(written.promotion.status, 'queued');
});

test('runMergeSync retries policy-blocked direct merges without reintroducing inline branch deletion', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-retry-cleanup-'));
  const mergeArgs = [];
  let promotionReads = 0;

  const payload = await runMergeSync({
    argv: [
      'node',
      'tools/priority/merge-sync-pr.mjs',
      '--pr',
      '557',
      '--repo',
      'svelderrainruiz/compare-vi-cli-action',
      '--summary-path',
      path.join(tempDir, 'summary.json')
    ],
    repoRoot,
    ensureGhCliFn: () => {},
    readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
    readPrInfoFn: () => ({
      number: 557,
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      headRefName: 'issue/personal-1397-retry-cleanup',
      headRepository: {
        name: 'compare-vi-cli-action'
      },
      headRepositoryOwner: {
        login: 'svelderrainruiz'
      },
      headRefOid: '1234567890123456789012345678901234567890',
      url: 'https://example.test/pr/557'
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
      promotionReads += 1;
      return promotionReads === 1
        ? {
            state: 'OPEN',
            mergeStateStatus: 'CLEAN',
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
    },
    runMergeAttemptFn: ({ args }) => {
      mergeArgs.push(args);
      return mergeArgs.length === 1
        ? {
            status: 1,
            stdout: '',
            stderr: 'Base branch policy requires merge queue; direct merge blocked.'
          }
        : {
            status: 0,
            stdout: 'queued',
            stderr: ''
          };
    },
    sleepFn: async () => {}
  });

  assert.deepEqual(mergeArgs, [
    [
      'pr',
      'merge',
      '557',
      '--repo',
      'svelderrainruiz/compare-vi-cli-action',
      '--squash'
    ],
    [
      'pr',
      'merge',
      '557',
      '--repo',
      'svelderrainruiz/compare-vi-cli-action',
      '--squash',
      '--auto'
    ]
  ]);
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
  assert.deepEqual(payload.branchCleanup, {
    requested: true,
    attempted: false,
    status: 'deferred',
    reason: 'promotion-not-yet-merged',
    inlineDeleteBranch: false,
    postMergeDelete: true,
    repository: 'svelderrainruiz/compare-vi-cli-action',
    headRefName: 'issue/personal-1397-retry-cleanup'
  });

  const written = JSON.parse(await readFile(path.join(tempDir, 'summary.json'), 'utf8'));
  assert.equal(written.finalReason, 'direct-merge-policy-block-retry-auto');
  assert.equal(written.branchCleanup.status, 'deferred');
  assert.equal(written.branchCleanup.postMergeDelete, true);
});

test('runMergeSync falls back to a supported repository merge method before invoking gh pr merge', async () => {
  const mergeArgs = [];
  let promotionReads = 0;

  const payload = await runMergeSync({
    argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '555', '--repo', 'owner/repo'],
    repoRoot,
    ensureGhCliFn: () => {},
    readRepositoryMergeCapabilitiesFn: () =>
      buildRepositoryMergeCapabilities({
        allowSquashMerge: false,
        allowRebaseMerge: true,
        supportedMethods: ['rebase']
      }),
    readPrInfoFn: () => ({
      number: 555,
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE',
      baseRefName: 'sync-test',
      headRefOid: '1234567890123456789012345678901234567890',
      url: 'https://example.test/pr/555'
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
      promotionReads += 1;
      return promotionReads === 1
        ? {
            state: 'OPEN',
            mergeStateStatus: 'CLEAN',
            isInMergeQueue: false,
            autoMergeRequest: null,
            mergedAt: null
          }
        : {
            state: 'MERGED',
            mergeStateStatus: 'CLEAN',
            isInMergeQueue: false,
            autoMergeRequest: null,
            mergedAt: '2026-03-20T03:14:00Z'
          };
    },
    runMergeAttemptFn: ({ args }) => {
      mergeArgs.push(args);
      return { status: 0, stdout: 'merged', stderr: '' };
    },
    sleepFn: async () => {}
  });

  assert.deepEqual(mergeArgs, [[
    'pr',
    'merge',
    '555',
    '--repo',
    'owner/repo',
    '--rebase',
    '--delete-branch'
  ]]);
  assert.equal(payload.mergeMethod, 'rebase');
  assert.equal(payload.mergeMethodSelection.requestedMethod, 'squash');
  assert.equal(payload.mergeMethodSelection.effectiveMethod, 'rebase');
  assert.equal(payload.mergeMethodSelection.reason, 'default-fallback-rebase');
});

test('runMergeSync fails before merge when an explicit unsupported method is requested', async () => {
  let mergeAttempted = false;

  await assert.rejects(
    () =>
      runMergeSync({
        argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '556', '--repo', 'owner/repo', '--method', 'merge'],
        repoRoot,
        ensureGhCliFn: () => {},
        readRepositoryMergeCapabilitiesFn: () =>
          buildRepositoryMergeCapabilities({
            allowMergeCommit: false,
            allowSquashMerge: true,
            allowRebaseMerge: false,
            supportedMethods: ['squash']
          }),
        runMergeAttemptFn: () => {
          mergeAttempted = true;
          return { status: 0, stdout: '', stderr: '' };
        }
      }),
    /does not allow requested merge method 'merge'/i
  );

  assert.equal(mergeAttempted, false);
});

test('runMergeSync creates the parent directory for explicit summary paths', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-summary-dir-'));
  const nestedSummaryPath = path.join(tempDir, 'tests', 'results', '_agent', 'queue', 'merge-sync-1433.json');

  await runMergeSync({
    argv: [
      'node',
      'tools/priority/merge-sync-pr.mjs',
      '--pr',
      '1433',
      '--repo',
      'owner/repo',
      '--summary-path',
      nestedSummaryPath
    ],
    repoRoot,
    ensureGhCliFn: () => {},
    readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
    readPrInfoFn: () => ({
      number: 1433,
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'BLOCKED',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      headRefOid: '1234567890123456789012345678901234567890',
      url: 'https://example.test/pr/1433'
    }),
    evaluatePromotionReviewClearanceFn: async () => ({
      ok: true,
      report: {
        status: 'pass',
        gateState: 'ready',
        reasons: ['current-head-review-run-completed-clean']
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

  const written = JSON.parse(await readFile(nestedSummaryPath, 'utf8'));
  assert.equal(written.pr, 1433);
  assert.equal(written.promotion.status, 'queued');
});

test('runMergeSync omits inline delete and performs post-merge cleanup for admin merges on queue-managed bases', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-admin-cleanup-'));
  const mergeArgs = [];
  const cleanupCalls = [];
  let promotionReads = 0;

  const payload = await runMergeSync({
    argv: [
      'node',
      'tools/priority/merge-sync-pr.mjs',
      '--pr',
      '128',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--admin',
      '--summary-path',
      path.join(tempDir, 'summary.json')
    ],
    repoRoot,
    ensureGhCliFn: () => {},
    readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
    readPrInfoFn: () => ({
      number: 128,
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'BLOCKED',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      headRefName: 'issue/origin-1397-merge-queue-delete-branch',
      headRepository: {
        name: 'compare-vi-cli-action-fork'
      },
      headRepositoryOwner: {
        login: 'LabVIEW-Community-CI-CD'
      },
      headRefOid: '1234567890123456789012345678901234567890',
      url: 'https://example.test/pr/128'
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
      promotionReads += 1;
      return promotionReads === 1
        ? {
            state: 'OPEN',
            mergeStateStatus: 'BLOCKED',
            isInMergeQueue: false,
            autoMergeRequest: null,
            mergedAt: null
          }
        : {
            state: 'MERGED',
            mergeStateStatus: 'CLEAN',
            isInMergeQueue: false,
            autoMergeRequest: null,
            mergedAt: '2026-03-20T01:26:17Z'
          };
    },
    runMergeAttemptFn: ({ args }) => {
      mergeArgs.push(args);
      return { status: 0, stdout: 'merged', stderr: '' };
    },
    deleteMergedHeadBranchFn: ({ prInfo, dryRun }) => {
      cleanupCalls.push({ headRefName: prInfo.headRefName, dryRun });
      return {
        requested: true,
        attempted: true,
        status: 'already-absent',
        reason: 'post-merge-api-delete',
        repository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
        headRefName: prInfo.headRefName
      };
    },
    sleepFn: async () => {}
  });

  assert.deepEqual(mergeArgs, [[
    'pr',
    'merge',
    '128',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--squash',
    '--admin'
  ]]);
  assert.deepEqual(cleanupCalls, [{
    headRefName: 'issue/origin-1397-merge-queue-delete-branch',
    dryRun: false
  }]);
  assert.equal(payload.promotion.status, 'merged');
  assert.equal(payload.branchCleanup.status, 'already-absent');

  const written = JSON.parse(await readFile(path.join(tempDir, 'summary.json'), 'utf8'));
  assert.equal(written.branchCleanup.status, 'already-absent');
});

test('runMergeSync fails when auto merge command succeeds but no durable promotion state appears', async () => {
  await assert.rejects(
    () =>
      runMergeSync({
        argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '124', '--repo', 'owner/repo'],
        repoRoot,
        ensureGhCliFn: () => {},
        readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
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

test('runMergeSync forwards the effective copilot review strategy into merge admission', async () => {
  let observedStrategy = null;

  await assert.rejects(
    () =>
      runMergeSync({
        argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '124', '--repo', 'owner/repo'],
        repoRoot,
        ensureGhCliFn: () => {},
        readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
        loadMergeSyncCopilotReviewStrategyFn: async () => 'draft-only-explicit',
        readPromotionStateFn: () => ({
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: false,
          autoMergeRequest: null,
          mergedAt: null
        }),
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
        evaluatePromotionReviewClearanceFn: async ({ copilotReviewStrategy }) => {
          observedStrategy = copilotReviewStrategy;
          return {
            ok: false,
            report: {
              status: 'fail',
              gateState: 'blocked',
              reasons: ['copilot-review-run-unobserved']
            }
          };
        }
      }),
    /copilot-review-run-unobserved/
  );

  assert.equal(observedStrategy, 'draft-only-explicit');
});

test('evaluatePromotionReviewClearance summarizes a passing current-head no-comment review run', async () => {
  let receivedArgs = null;
  const result = await evaluatePromotionReviewClearance({
    repo: 'owner/repo',
    pr: 125,
    prInfo: {
      isDraft: false,
      baseRefName: 'develop',
      headRefOid: '1234567890123456789012345678901234567890'
    },
    copilotReviewStrategy: 'draft-only-explicit',
    runCopilotReviewGateFn: async ({ argv }) => {
      receivedArgs = argv;
      return {
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
      };
    }
  });

  assert.ok(receivedArgs.includes('--copilot-review-strategy'));
  assert.ok(receivedArgs.includes('draft-only-explicit'));
  assert.equal(result.ok, true);
  assert.deepEqual(result.report, {
    status: 'pass',
    gateState: 'ready',
    reasons: ['current-head-review-run-completed-clean'],
    actionableCommentCount: 0,
    actionableThreadCount: 0,
    hasCurrentHeadReview: false,
    latestReviewIsCurrentHead: false,
    reviewRunCompletedClean: true,
    source: 'copilot-review-gate',
    receiptPath: null,
    readyHeadSha: null,
    currentHeadSha: '1234567890123456789012345678901234567890',
    staleForCurrentHead: null
  });
});

test('evaluatePromotionReviewClearance passes from stored ready-validation clearance on the current head without invoking the GitHub gate', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-stored-clearance-'));
  const receiptPath = resolveReadyValidationClearancePath({
    repoRoot: tempDir,
    repo: 'owner/repo',
    pr: 126
  });
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'priority/ready-validation-clearance@v1',
      generatedAt: '2026-03-14T00:00:00.000Z',
      repository: 'owner/repo',
      pullRequestNumber: 126,
      readyHeadSha: '1234567890123456789012345678901234567890',
      currentHeadSha: '1234567890123456789012345678901234567890',
      status: 'current',
      reason: 'PR remains in ready-validation on the same cleared head.'
    })}\n`,
    'utf8'
  );

  let gateCalls = 0;
  const result = await evaluatePromotionReviewClearance({
    repoRoot: tempDir,
    repo: 'owner/repo',
    pr: 126,
    prInfo: {
      isDraft: false,
      baseRefName: 'develop',
      headRefOid: '1234567890123456789012345678901234567890'
    },
    runCopilotReviewGateFn: async () => {
      gateCalls += 1;
      throw new Error('gate should not be called when stored clearance is current');
    }
  });

  assert.equal(gateCalls, 0);
  assert.equal(result.ok, true);
  assert.deepEqual(result.report, {
    status: 'pass',
    gateState: 'ready',
    reasons: ['stored-ready-validation-clearance-current-head'],
    actionableCommentCount: 0,
    actionableThreadCount: 0,
    hasCurrentHeadReview: false,
    latestReviewIsCurrentHead: false,
    reviewRunCompletedClean: false,
    source: 'stored-ready-validation-clearance',
    receiptPath,
    readyHeadSha: '1234567890123456789012345678901234567890',
    currentHeadSha: '1234567890123456789012345678901234567890',
    staleForCurrentHead: false
  });
});

test('evaluatePromotionReviewClearance fails closed when stored ready-validation clearance is stale for the current head', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'merge-sync-pr-stale-clearance-'));
  const receiptPath = resolveReadyValidationClearancePath({
    repoRoot: tempDir,
    repo: 'owner/repo',
    pr: 127
  });
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'priority/ready-validation-clearance@v1',
      generatedAt: '2026-03-14T00:00:00.000Z',
      repository: 'owner/repo',
      pullRequestNumber: 127,
      readyHeadSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      currentHeadSha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      status: 'current',
      reason: 'PR remains in ready-validation on the same cleared head.'
    })}\n`,
    'utf8'
  );

  let gateCalls = 0;
  const result = await evaluatePromotionReviewClearance({
    repoRoot: tempDir,
    repo: 'owner/repo',
    pr: 127,
    prInfo: {
      isDraft: false,
      baseRefName: 'develop',
      headRefOid: 'cccccccccccccccccccccccccccccccccccccccc'
    },
    runCopilotReviewGateFn: async () => {
      gateCalls += 1;
      throw new Error('gate should not be called when stored clearance is stale');
    }
  });

  assert.equal(gateCalls, 0);
  assert.equal(result.ok, false);
  assert.deepEqual(result.report, {
    status: 'fail',
    gateState: 'blocked',
    reasons: ['stored-ready-validation-clearance-stale-head'],
    actionableCommentCount: 0,
    actionableThreadCount: 0,
    hasCurrentHeadReview: false,
    latestReviewIsCurrentHead: false,
    reviewRunCompletedClean: false,
    source: 'stored-ready-validation-clearance',
    receiptPath,
    readyHeadSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    currentHeadSha: 'cccccccccccccccccccccccccccccccccccccccc',
    staleForCurrentHead: true
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
        readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
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
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--summary-path',
      path.join(tempDir, 'summary.json')
    ],
    repoRoot,
    ensureGhCliFn: () => {},
    readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
    readPrInfoFn: () => ({
      number: 127,
        state: 'OPEN',
        isDraft: false,
        mergeStateStatus: 'BLOCKED',
        mergeable: 'MERGEABLE',
        baseRefName: 'develop',
        headRepository: {
          name: 'compare-vi-cli-action'
        },
        headRepositoryOwner: {
          login: 'svelderrainruiz'
        },
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
  assert.equal(payload.planeTransition.from, 'personal');
  assert.equal(payload.planeTransition.to, 'upstream');
  assert.equal(payload.planeTransition.action, 'promote');

  const written = JSON.parse(await readFile(path.join(tempDir, 'summary.json'), 'utf8'));
  assert.equal(written.reviewClearance.status, 'pass');
  assert.deepEqual(written.reviewClearance.reasons, ['current-head-review-run-completed-clean']);
  assert.equal(written.planeTransition.from, 'personal');
});

test('runMergeSync fails closed when the head repository plane is outside the tracked branch model', async () => {
  await assert.rejects(
    () =>
      runMergeSync({
        argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '130', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action'],
        repoRoot,
        ensureGhCliFn: () => {},
        readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
        readPrInfoFn: () => ({
          number: 130,
          state: 'OPEN',
          isDraft: false,
          mergeStateStatus: 'BLOCKED',
          mergeable: 'MERGEABLE',
          baseRefName: 'develop',
          headRepository: {
            name: 'compare-vi-cli-action'
          },
          headRepositoryOwner: {
            login: 'someone-else'
          },
          headRefOid: '1234567890123456789012345678901234567890',
          url: 'https://example.test/pr/130'
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
        runMergeAttemptFn: () => ({ status: 0, stdout: '', stderr: '' }),
        sleepFn: async () => {}
      }),
    /plane transition fork --promote--> upstream is not allowed/i
  );
});

test('runMergeSync does not query promotion state when the PR is already merged', async () => {
  let promotionReads = 0;
  const payload = await runMergeSync({
    argv: ['node', 'tools/priority/merge-sync-pr.mjs', '--pr', '125', '--repo', 'owner/repo'],
    repoRoot,
    ensureGhCliFn: () => {},
    readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
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
        readRepositoryMergeCapabilitiesFn: () => buildRepositoryMergeCapabilities(),
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

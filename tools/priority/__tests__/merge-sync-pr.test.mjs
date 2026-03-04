import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildMergeSummaryPayload,
  buildPolicyTrace,
  normalizeBaseRefName,
  selectMergeMode,
  shouldRetryWithAuto,
  getMergeQueueBranches
} from '../merge-sync-pr.mjs';

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
    createdAt: '2026-03-03T00:00:01.000Z'
  });

  assert.equal(payload.selectedMode, 'auto');
  assert.equal(payload.finalReason, 'merge-queue-branch-main');
  assert.equal(payload.prState.baseRefName, 'main');
  assert.deepEqual(payload.policyTrace.mergeQueueBranches, ['main']);
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

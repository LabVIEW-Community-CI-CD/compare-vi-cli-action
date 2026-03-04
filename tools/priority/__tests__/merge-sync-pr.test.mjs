import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPolicyTrace, selectMergeMode, shouldRetryWithAuto, getMergeQueueBranches } from '../merge-sync-pr.mjs';

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

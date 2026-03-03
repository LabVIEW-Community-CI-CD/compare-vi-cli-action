import test from 'node:test';
import assert from 'node:assert/strict';
import { selectMergeMode, shouldRetryWithAuto } from '../merge-sync-pr.mjs';

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
    mergeStateStatus: 'CLEAN',
    mergeable: 'MERGEABLE'
  });
  assert.deepEqual(selection, {
    mode: 'direct',
    reason: 'clean-mergeable'
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

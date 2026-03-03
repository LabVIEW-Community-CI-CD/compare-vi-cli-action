#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildNoStandingPriorityState,
  determinePrioritySyncExitCode,
  isStandingPriorityCacheCandidate,
  resolveStandingPriorityLabels,
  resolveStandingPriorityFromSources
} from '../sync-standing-priority.mjs';

test('isStandingPriorityCacheCandidate requires OPEN state and matching standing label', () => {
  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'OPEN',
      labels: ['bug', 'standing-priority']
    }),
    true
  );

  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'CLOSED',
      labels: ['standing-priority']
    }),
    false
  );

  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'OPEN',
      labels: ['bug']
    }),
    false
  );
});

test('resolveStandingPriorityFromSources uses cache only when lookups are unavailable and cache is valid', () => {
  const number = resolveStandingPriorityFromSources({
    ghOutcome: { status: 'unavailable', error: 'gh missing' },
    restOutcome: { status: 'error', error: 'network timeout' },
    standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
    cache: {
      number: 99,
      state: 'OPEN',
      labels: ['standing-priority']
    }
  });
  assert.equal(number, 99);
});

test('resolveStandingPriorityFromSources rejects stale cache when gh reports empty standing set', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'empty' },
        restOutcome: { status: 'error', error: 'network timeout' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'OPEN',
          labels: ['standing-priority']
        }
      }),
    (err) => err?.code === 'NO_STANDING_PRIORITY'
  );
});

test('resolveStandingPriorityFromSources rejects stale cache when rest reports empty standing set', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'error', error: 'gh unavailable' },
        restOutcome: { status: 'empty' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'OPEN',
          labels: ['standing-priority']
        }
      }),
    (err) => err?.code === 'NO_STANDING_PRIORITY'
  );
});

test('resolveStandingPriorityFromSources fails when only invalid cache remains', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'unavailable', error: 'gh missing' },
        restOutcome: { status: 'error', error: 'network timeout' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'CLOSED',
          labels: ['standing-priority']
        }
      }),
    /Unable to resolve standing-priority issue number/
  );
});

test('buildNoStandingPriorityState clears router/cache deterministically', () => {
  const state = buildNoStandingPriorityState(
    {
      number: 12,
      title: 'Old',
      state: 'OPEN',
      labels: ['standing-priority']
    },
    'No open issue found with labels: `fork-standing-priority`, `standing-priority`.',
    '2026-03-03T03:10:00.000Z',
    ['fork-standing-priority', 'standing-priority']
  );

  assert.equal(state.clearedRouter.issue, null);
  assert.deepEqual(state.clearedRouter.actions, []);
  assert.equal(state.clearedCache.number, null);
  assert.equal(state.clearedCache.state, 'NONE');
  assert.equal(
    state.clearedCache.lastFetchError,
    'No open issue found with labels: `fork-standing-priority`, `standing-priority`.'
  );
  assert.equal(state.result.fetchSource, 'none');
});

test('resolveStandingPriorityLabels prefers fork-standing-priority for non-canonical owners', () => {
  const labels = resolveStandingPriorityLabels(
    '/tmp/repo',
    'svelderrainruiz/compare-vi-cli-action',
    {}
  );
  assert.deepEqual(labels, ['fork-standing-priority', 'standing-priority']);
});

test('resolveStandingPriorityLabels honors explicit env override order', () => {
  const labels = resolveStandingPriorityLabels('/tmp/repo', null, {
    AGENT_STANDING_PRIORITY_LABELS: 'custom-one, custom-two, custom-one'
  });
  assert.deepEqual(labels, ['custom-one', 'custom-two']);
});

test('determinePrioritySyncExitCode maps no-standing to success and real errors to failure', () => {
  assert.equal(determinePrioritySyncExitCode(null), 0);
  assert.equal(determinePrioritySyncExitCode({ code: 'NO_STANDING_PRIORITY' }), 0);
  assert.equal(determinePrioritySyncExitCode(new Error('boom')), 1);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isStandingPriorityCacheCandidate,
  resolveStandingPriorityFromSources
} from '../sync-standing-priority.mjs';

test('isStandingPriorityCacheCandidate requires OPEN state and standing-priority label', () => {
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
        cache: {
          number: 1,
          state: 'CLOSED',
          labels: ['standing-priority']
        }
      }),
    /Unable to resolve standing-priority issue number/
  );
});


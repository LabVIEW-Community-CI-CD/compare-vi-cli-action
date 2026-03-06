import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeReleaseRollbackPolicy, getReleaseRollbackStreamPolicy } from '../lib/release-rollback-policy.mjs';

test('normalizeReleaseRollbackPolicy applies defaults', () => {
  const policy = normalizeReleaseRollbackPolicy({});
  assert.equal(policy.schema, 'release-rollback-policy/v1');
  assert.equal(policy.rollback.remote, 'upstream');
  assert.deepEqual(policy.rollback.targetBranches, ['main', 'develop']);
  assert.equal(policy.streams.stable.minimumHistory, 2);
  assert.equal(policy.drill.workflow, 'release-rollback-drill.yml');
  assert.equal(policy.drill.minimumSuccessRate, 0.8);
});

test('normalizeReleaseRollbackPolicy honors explicit settings', () => {
  const policy = normalizeReleaseRollbackPolicy({
    schema: 'custom',
    rollback: {
      remote: 'mirror',
      target_branches: ['mainline', 'devline'],
      minimum_history: 3
    },
    streams: {
      stable: {
        tag_pattern: '^v1\\.',
        minimum_history: 4
      }
    },
    drill: {
      workflow: 'drill.yml',
      branch: 'main',
      lookback_runs: 20,
      minimum_success_rate: 0.9,
      max_hours_since_success: 96
    }
  });
  assert.equal(policy.schema, 'custom');
  assert.equal(policy.rollback.remote, 'mirror');
  assert.deepEqual(policy.rollback.targetBranches, ['mainline', 'devline']);
  assert.equal(policy.rollback.minimumHistory, 3);
  assert.equal(policy.streams.stable.tagPattern, '^v1\\.');
  assert.equal(policy.streams.stable.minimumHistory, 4);
  assert.equal(policy.drill.workflow, 'drill.yml');
  assert.equal(policy.drill.branch, 'main');
  assert.equal(policy.drill.lookbackRuns, 20);
  assert.equal(policy.drill.minimumSuccessRate, 0.9);
  assert.equal(policy.drill.maxHoursSinceSuccess, 96);
});

test('getReleaseRollbackStreamPolicy resolves known stream and rejects unknown values', () => {
  const policy = normalizeReleaseRollbackPolicy({});
  const stable = getReleaseRollbackStreamPolicy(policy, 'stable');
  assert.equal(typeof stable.tagPattern, 'string');
  assert.throws(() => getReleaseRollbackStreamPolicy(policy, 'unknown'), /Unsupported rollback stream/);
});


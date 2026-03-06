import test from 'node:test';
import assert from 'node:assert/strict';
import { parseArgs, evaluateDrillHealth } from '../rollback-drill-health.mjs';

test('parseArgs applies defaults and overrides', () => {
  const defaults = parseArgs(['node', 'rollback-drill-health.mjs']);
  assert.equal(defaults.repo, null);
  assert.equal(defaults.lookbackRuns, null);
  assert.equal(defaults.minSuccessRate, null);
  assert.equal(defaults.maxHoursSinceSuccess, null);

  const parsed = parseArgs([
    'node',
    'rollback-drill-health.mjs',
    '--repo',
    'owner/repo',
    '--workflow',
    'release-rollback-drill.yml',
    '--branch',
    'develop',
    '--lookback-runs',
    '12',
    '--min-success-rate',
    '0.75',
    '--max-hours-since-success',
    '168'
  ]);
  assert.equal(parsed.repo, 'owner/repo');
  assert.equal(parsed.workflow, 'release-rollback-drill.yml');
  assert.equal(parsed.branch, 'develop');
  assert.equal(parsed.lookbackRuns, 12);
  assert.equal(parsed.minSuccessRate, 0.75);
  assert.equal(parsed.maxHoursSinceSuccess, 168);
});

test('evaluateDrillHealth passes when success rate and freshness satisfy thresholds', () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const runs = [
    {
      id: 100,
      run_number: 10,
      conclusion: 'success',
      status: 'completed',
      event: 'schedule',
      created_at: '2026-03-06T10:00:00Z',
      updated_at: '2026-03-06T10:05:00Z'
    },
    {
      id: 99,
      run_number: 9,
      conclusion: 'failure',
      status: 'completed',
      event: 'schedule',
      created_at: '2026-03-05T10:00:00Z',
      updated_at: '2026-03-05T10:05:00Z'
    },
    {
      id: 98,
      run_number: 8,
      conclusion: 'success',
      status: 'completed',
      event: 'schedule',
      created_at: '2026-03-04T10:00:00Z',
      updated_at: '2026-03-04T10:05:00Z'
    }
  ];

  const result = evaluateDrillHealth(
    runs,
    {
      minimumSuccessRate: 0.6,
      maxHoursSinceSuccess: 24
    },
    now
  );

  assert.equal(result.status, 'pass');
  assert.equal(result.summary.successRate, 2 / 3);
  assert.equal(result.failures.length, 0);
});

test('evaluateDrillHealth fails on low success rate', () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const runs = [
    {
      id: 1,
      run_number: 1,
      conclusion: 'failure',
      status: 'completed',
      event: 'schedule',
      created_at: '2026-03-06T10:00:00Z',
      updated_at: '2026-03-06T10:05:00Z'
    },
    {
      id: 2,
      run_number: 2,
      conclusion: 'success',
      status: 'completed',
      event: 'schedule',
      created_at: '2026-03-05T10:00:00Z',
      updated_at: '2026-03-05T10:05:00Z'
    }
  ];
  const result = evaluateDrillHealth(
    runs,
    {
      minimumSuccessRate: 0.8,
      maxHoursSinceSuccess: 72
    },
    now
  );

  assert.equal(result.status, 'fail');
  assert.ok(result.failures.some((failure) => failure.code === 'success-rate-below-threshold'));
});

test('evaluateDrillHealth fails on stale latest success and missing runs', () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const staleRuns = [
    {
      id: 1,
      run_number: 1,
      conclusion: 'success',
      status: 'completed',
      event: 'schedule',
      created_at: '2026-02-20T10:00:00Z',
      updated_at: '2026-02-20T10:05:00Z'
    }
  ];
  const stale = evaluateDrillHealth(
    staleRuns,
    {
      minimumSuccessRate: 0.5,
      maxHoursSinceSuccess: 72
    },
    now
  );
  assert.equal(stale.status, 'fail');
  assert.ok(stale.failures.some((failure) => failure.code === 'latest-success-stale'));

  const missing = evaluateDrillHealth(
    [],
    {
      minimumSuccessRate: 0.5,
      maxHoursSinceSuccess: 72
    },
    now
  );
  assert.equal(missing.status, 'fail');
  assert.ok(missing.failures.some((failure) => failure.code === 'missing-drill-history'));
});


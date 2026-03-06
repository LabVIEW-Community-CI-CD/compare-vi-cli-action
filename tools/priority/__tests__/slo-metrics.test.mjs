import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseArgs,
  summarizeWorkflowRuns,
  buildSloSummary,
  evaluateBreaches
} from '../slo-metrics.mjs';

test('parseArgs applies defaults and supports explicit options', () => {
  const defaults = parseArgs(['node', 'slo-metrics.mjs']);
  assert.equal(defaults.lookbackDays, 45);
  assert.equal(defaults.maxRuns, 100);
  assert.equal(defaults.routeOnBreach, false);
  assert.deepEqual(defaults.workflows, [
    'release.yml',
    'publish-tools-image.yml',
    'publish-shared-package.yml',
    'monthly-stability-release.yml',
    'promotion-contract.yml'
  ]);

  const parsed = parseArgs([
    'node',
    'slo-metrics.mjs',
    '--repo',
    'owner/repo',
    '--workflow',
    'release.yml',
    '--lookback-days',
    '14',
    '--threshold-failure-rate',
    '0.5',
    '--route-on-breach',
    '--route-labels',
    'slo,ci'
  ]);
  assert.equal(parsed.repo, 'owner/repo');
  assert.deepEqual(parsed.workflows, ['release.yml']);
  assert.equal(parsed.lookbackDays, 14);
  assert.equal(parsed.thresholdFailureRate, 0.5);
  assert.equal(parsed.routeOnBreach, true);
  assert.deepEqual(parsed.routeLabels, ['slo', 'ci']);
});

test('summarizeWorkflowRuns computes lead time, failure rate, mttr, and stale hours', () => {
  const now = new Date('2026-03-06T08:00:00Z');
  const runs = [
    {
      created_at: '2026-03-06T00:00:00Z',
      updated_at: '2026-03-06T00:10:00Z',
      conclusion: 'failure'
    },
    {
      created_at: '2026-03-06T01:00:00Z',
      updated_at: '2026-03-06T01:20:00Z',
      conclusion: 'success'
    },
    {
      created_at: '2026-03-06T02:00:00Z',
      updated_at: '2026-03-06T02:12:00Z',
      conclusion: 'success'
    }
  ];

  const summary = summarizeWorkflowRuns(runs, now);
  assert.equal(summary.totals.totalRuns, 3);
  assert.equal(summary.totals.failedRuns, 1);
  assert.equal(summary.totals.successRuns, 2);
  assert.equal(summary.metrics.failureRate, 1 / 3);
  assert.equal(summary.metrics.leadTimeP50Seconds, 720);
  assert.equal(summary.metrics.mttrSeconds, 4200);
  assert.equal(summary.metrics.staleHours, (now.getTime() - Date.parse('2026-03-06T02:12:00Z')) / 3_600_000);
});

test('buildSloSummary aggregates workflow summaries and breach evaluation triggers', () => {
  const summary = buildSloSummary([
    {
      workflow: 'release.yml',
      summary: {
        totals: { totalRuns: 4, successRuns: 2, failedRuns: 2, gateRegressions: 2 },
        metrics: {
          failureRate: 0.5,
          leadTimeP50Seconds: 900,
          leadTimeP95Seconds: 1400,
          mttrSeconds: 3600,
          staleHours: 100
        }
      }
    },
    {
      workflow: 'publish-tools-image.yml',
      summary: {
        totals: { totalRuns: 2, successRuns: 2, failedRuns: 0, gateRegressions: 0 },
        metrics: {
          failureRate: 0,
          leadTimeP50Seconds: 600,
          leadTimeP95Seconds: 600,
          mttrSeconds: null,
          staleHours: 1200
        }
      }
    }
  ]);

  assert.equal(summary.totals.totalRuns, 6);
  assert.equal(summary.totals.failedRuns, 2);
  assert.equal(summary.totals.gateRegressions, 2);
  assert.equal(summary.metrics.failureRate, 2 / 6);
  assert.equal(summary.metrics.staleHours, 1200);

  const breaches = evaluateBreaches(summary, {
    failureRate: 0.2,
    mttrHours: 0.5,
    staleHours: 1000,
    gateRegressions: 1
  });
  assert.deepEqual(
    breaches.map((entry) => entry.code).sort(),
    ['failure-rate', 'gate-regressions', 'mttr', 'stale-budget']
  );
});

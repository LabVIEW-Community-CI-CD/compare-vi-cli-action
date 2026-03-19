import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseArgs,
  summarizeWorkflowRuns,
  buildSloSummary,
  evaluateBreaches,
  evaluatePromotionGate
} from '../slo-metrics.mjs';

test('parseArgs applies defaults and supports explicit options', () => {
  const defaults = parseArgs(['node', 'slo-metrics.mjs']);
  assert.equal(defaults.lookbackDays, 45);
  assert.equal(defaults.maxRuns, 100);
  assert.equal(defaults.thresholdSkipRate, 1);
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
    },
    {
      created_at: '2026-03-06T03:00:00Z',
      updated_at: '2026-03-06T03:10:00Z',
      conclusion: 'skipped'
    }
  ];

  const summary = summarizeWorkflowRuns(runs, now);
  assert.equal(summary.totals.totalRuns, 3);
  assert.equal(summary.totals.observedRuns, 4);
  assert.equal(summary.totals.failedRuns, 1);
  assert.equal(summary.totals.successRuns, 2);
  assert.equal(summary.totals.skippedRuns, 1);
  assert.equal(summary.metrics.failureRate, 1 / 3);
  assert.equal(summary.metrics.skipRate, 1 / 4);
  assert.equal(summary.metrics.leadTimeP50Seconds, 720);
  assert.equal(summary.metrics.mttrSeconds, 4200);
  assert.equal(summary.metrics.staleHours, (now.getTime() - Date.parse('2026-03-06T02:12:00Z')) / 3_600_000);
  assert.equal(summary.metrics.unresolvedIncident, false);
  assert.equal(summary.incidents.total, 1);
  assert.equal(summary.incidents.resolved, 1);
  assert.equal(summary.incidents.unresolved, 0);
});

test('buildSloSummary aggregates workflow summaries and breach evaluation triggers', () => {
  const summary = buildSloSummary([
    {
      workflow: 'release.yml',
      summary: {
        totals: { totalRuns: 4, observedRuns: 5, successRuns: 2, failedRuns: 2, skippedRuns: 1, gateRegressions: 2 },
        metrics: {
          failureRate: 0.5,
          skipRate: 0.2,
          leadTimeP50Seconds: 900,
          leadTimeP95Seconds: 1400,
          mttrSeconds: 3600,
          staleHours: 100,
          unresolvedIncident: false,
          unresolvedIncidentAgeSeconds: null
        },
        incidents: {
          total: 2,
          resolved: 2,
          unresolved: 0
        }
      }
    },
    {
      workflow: 'publish-tools-image.yml',
      summary: {
        totals: { totalRuns: 2, observedRuns: 2, successRuns: 2, failedRuns: 0, skippedRuns: 0, gateRegressions: 0 },
        metrics: {
          failureRate: 0,
          skipRate: 0,
          leadTimeP50Seconds: 600,
          leadTimeP95Seconds: 600,
          mttrSeconds: null,
          staleHours: 1200,
          unresolvedIncident: false,
          unresolvedIncidentAgeSeconds: null
        },
        incidents: {
          total: 0,
          resolved: 0,
          unresolved: 0
        }
      }
    }
  ]);

  assert.equal(summary.totals.totalRuns, 6);
  assert.equal(summary.totals.observedRuns, 7);
  assert.equal(summary.totals.failedRuns, 2);
  assert.equal(summary.totals.skippedRuns, 1);
  assert.equal(summary.totals.gateRegressions, 2);
  assert.equal(summary.metrics.failureRate, 2 / 6);
  assert.equal(summary.metrics.skipRate, 1 / 7);
  assert.equal(summary.metrics.staleHours, 1200);
  assert.equal(summary.metrics.unresolvedIncident, false);
  assert.equal(summary.incidents.total, 2);
  assert.equal(summary.incidents.resolved, 2);
  assert.equal(summary.incidents.unresolved, 0);

  const breaches = evaluateBreaches(summary, {
    failureRate: 0.2,
    skipRate: 0.1,
    mttrHours: 0.5,
    staleHours: 1000,
    gateRegressions: 1
  });
  assert.deepEqual(
    breaches.map((entry) => entry.code).sort(),
    ['failure-rate', 'gate-regressions', 'mttr', 'skip-rate', 'stale-budget']
  );
});

test('evaluatePromotionGate ignores historical breaches after recovery and blocks unresolved incidents', () => {
  const thresholds = {
    failureRate: 0.2,
    skipRate: 0.1,
    mttrHours: 0.5,
    staleHours: 168,
    gateRegressions: 1
  };

  const recovered = evaluatePromotionGate(
    [
      {
        workflow: 'release.yml',
        summary: {
          metrics: {
            staleHours: 1,
            unresolvedIncident: false,
            unresolvedIncidentAgeSeconds: null
          }
        }
      }
    ],
    thresholds
  );
  assert.equal(recovered.status, 'pass');
  assert.equal(recovered.blockerCount, 0);

  const active = evaluatePromotionGate(
    [
      {
        workflow: 'release.yml',
        summary: {
          metrics: {
            staleHours: 200,
            unresolvedIncident: true,
            unresolvedIncidentAgeSeconds: 4 * 3600
          }
        }
      }
    ],
    thresholds
  );
  assert.equal(active.status, 'fail');
  assert.deepEqual(
    active.blockers.map((entry) => entry.code).sort(),
    ['stale-budget', 'unresolved-incident']
  );
});

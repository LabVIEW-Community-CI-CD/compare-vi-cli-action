#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_THRESHOLDS,
  evaluateRemediationSlo,
  parseArgs,
  runRemediationSloEvaluator,
  summarizeIncidentMetrics,
  summarizeOperationalMetrics
} from '../remediation-slo-evaluator.mjs';

test('parseArgs applies defaults and explicit overrides', () => {
  const defaults = parseArgs(['node', 'remediation-slo-evaluator.mjs']);
  assert.match(defaults.outputPath, /remediation-slo-report\.json$/);
  assert.match(defaults.issueEventsPath, /incident-events\.json$/);
  assert.equal(defaults.lookbackDays, 30);

  const parsed = parseArgs([
    'node',
    'remediation-slo-evaluator.mjs',
    '--output',
    'tmp/report.json',
    '--issue-events',
    'tmp/incidents.json',
    '--lookback-days',
    '14',
    '--repo',
    'owner/repo'
  ]);
  assert.equal(parsed.outputPath, 'tmp/report.json');
  assert.equal(parsed.issueEventsPath, 'tmp/incidents.json');
  assert.equal(parsed.lookbackDays, 14);
  assert.equal(parsed.repo, 'owner/repo');
});

test('summarizeIncidentMetrics computes MTTD/route latency/MTTR/reopen rates', () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const summary = summarizeIncidentMetrics({
    now,
    lookbackDays: 30,
    events: [
      {
        id: 'i1',
        priority: 'P0',
        occurredAtMs: Date.parse('2026-03-06T00:00:00Z'),
        detectedAtMs: Date.parse('2026-03-06T00:30:00Z'),
        routedAtMs: Date.parse('2026-03-06T01:30:00Z'),
        resolvedAtMs: Date.parse('2026-03-06T10:30:00Z'),
        reopenedCount: 1
      },
      {
        id: 'i2',
        priority: 'P1',
        occurredAtMs: Date.parse('2026-03-05T10:00:00Z'),
        detectedAtMs: Date.parse('2026-03-05T11:00:00Z'),
        routedAtMs: Date.parse('2026-03-05T12:00:00Z'),
        resolvedAtMs: Date.parse('2026-03-05T20:00:00Z'),
        reopenedCount: 0
      }
    ]
  });

  assert.equal(summary.totalIncidents, 2);
  assert.equal(summary.reopenedIncidents, 1);
  assert.equal(summary.reopenRate, 0.5);
  assert.equal(summary.mttdHours, 0.75);
  assert.equal(summary.routeLatencyHours, 1);
  assert.equal(summary.mttrByPriorityHours.P0, 10);
  assert.equal(summary.mttrByPriorityHours.P1, 9);
});

test('evaluateRemediationSlo emits warn/fail checks and breaches', () => {
  const incidentMetrics = {
    mttdHours: 3,
    routeLatencyHours: 1,
    reopenRate: 0.1,
    mttrByPriorityHours: {
      P0: 80,
      P1: 20,
      P2: 20
    }
  };
  const operationalMetrics = {
    queueRetryRatio: 0.4,
    trunkRedMinutes: 10,
    releaseBlockerCount: 0
  };

  const evaluated = evaluateRemediationSlo({
    incidentMetrics,
    operationalMetrics,
    thresholds: DEFAULT_THRESHOLDS
  });

  assert.equal(evaluated.status, 'fail');
  assert.ok(evaluated.breaches.some((entry) => entry.key === 'mttd-hours' && entry.status === 'warn'));
  assert.ok(evaluated.breaches.some((entry) => entry.key === 'mttr-p0-hours' && entry.status === 'fail'));
  assert.ok(evaluated.breaches.some((entry) => entry.key === 'queue-retry-ratio' && entry.status === 'fail'));
});

test('summarizeOperationalMetrics maps queue/trunk/release signals', () => {
  const metrics = summarizeOperationalMetrics({
    queueReport: {
      throughputController: {
        retryPressure: {
          retryRatio: 0.22,
          quarantineRatio: 0.1
        }
      },
      health: {
        redMinutes: 35
      }
    },
    sloMetrics: {
      summary: {
        metrics: {
          failureRate: 0.15
        }
      }
    },
    releaseScorecard: {
      summary: {
        blockerCount: 2,
        status: 'fail'
      }
    }
  });

  assert.equal(metrics.queueRetryRatio, 0.22);
  assert.equal(metrics.trunkRedMinutes, 35);
  assert.equal(metrics.trunkFailureRate, 0.15);
  assert.equal(metrics.releaseBlockerCount, 2);
  assert.equal(metrics.releaseStatus, 'fail');
});

test('runRemediationSloEvaluator sets governor stabilize on first breach transition', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.endsWith('remediation-slo-report.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          summary: {
            status: 'pass'
          }
        }
      };
    }
    if (normalized.includes('incident-events.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: [
          {
            id: 'evt-1',
            priority: 'P0',
            occurredAt: '2026-03-06T00:00:00Z',
            detectedAt: '2026-03-06T10:00:00Z',
            routedAt: '2026-03-06T11:00:00Z',
            resolvedAt: '2026-03-06T12:00:00Z',
            reopenedCount: 1
          }
        ]
      };
    }
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          throughputController: {
            retryPressure: {
              retryRatio: 0.4,
              quarantineRatio: 0.2
            }
          },
          health: {
            redMinutes: 80
          }
        }
      };
    }
    if (normalized.includes('slo-metrics.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          summary: {
            metrics: {
              failureRate: 0.3
            }
          }
        }
      };
    }
    if (normalized.includes('release-scorecard.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          summary: {
            blockerCount: 4,
            status: 'fail'
          }
        }
      };
    }
    throw new Error(`Unexpected path: ${filePath}`);
  };

  const { report, exitCode } = await runRemediationSloEvaluator({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:30:00Z'),
    args: {
      outputPath: 'tests/results/_agent/slo/remediation-slo-report.json',
      issueEventsPath: 'tests/results/_agent/ops/incident-events.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      sloMetricsPath: 'tests/results/_agent/slo/slo-metrics.json',
      releaseScorecardPath: 'tests/results/_agent/release/release-scorecard.json',
      lookbackDays: 30,
      repo: 'owner/repo',
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo'
    },
    readJsonOptionalFn,
    writeJsonFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 0);
  assert.equal(report.summary.status, 'fail');
  assert.equal(report.governor.intent, 'stabilize');
  assert.equal(report.governor.firstBreach, true);
  assert.ok(report.breaches.length > 0);
});
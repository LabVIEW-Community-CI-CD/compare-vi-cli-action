#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import {
  DEFAULT_ROUTE_LABELS,
  DEFAULT_THRESHOLDS,
  buildRemediationCandidates,
  evaluateOverride,
  evaluateSecurityBreaches,
  normalizeDependabotAlert,
  parseArgs,
  runSecurityIntake,
  summarizeDependabotAlerts
} from '../security-intake.mjs';

function sampleAlert(overrides = {}) {
  return {
    number: 10,
    state: 'open',
    created_at: '2026-01-01T00:00:00Z',
    fixed_at: null,
    dismissed_at: null,
    auto_dismissed_at: null,
    html_url: 'https://example.test/alerts/10',
    security_advisory: {
      severity: 'moderate'
    },
    dependency: {
      package: {
        ecosystem: 'npm',
        name: 'brace-expansion'
      },
      manifest_path: 'package-lock.json'
    },
    ...overrides
  };
}

test('parseArgs supports thresholds, routing, and override flags', () => {
  const parsed = parseArgs([
    'node',
    'security-intake.mjs',
    '--route-on-breach',
    '--fail-on-breach',
    '--fail-on-skip',
    '--lookback-days',
    '60',
    '--threshold-open-critical',
    '1',
    '--threshold-open-high',
    '2',
    '--threshold-open-moderate',
    '3',
    '--threshold-stale-days',
    '20',
    '--threshold-stale-count',
    '4',
    '--threshold-mttr-days',
    '14',
    '--route-labels',
    'security,governance',
    '--override-owner',
    'alice',
    '--override-reason',
    'release freeze',
    '--override-expires-at',
    '2026-04-01T00:00:00Z',
    '--override-ticket',
    '#999'
  ]);

  assert.equal(parsed.routeOnBreach, true);
  assert.equal(parsed.failOnBreach, true);
  assert.equal(parsed.failOnSkip, true);
  assert.equal(parsed.lookbackDays, 60);
  assert.equal(parsed.thresholds.openCriticalMax, 1);
  assert.equal(parsed.thresholds.openHighMax, 2);
  assert.equal(parsed.thresholds.openModerateMax, 3);
  assert.equal(parsed.thresholds.staleOpenDays, 20);
  assert.equal(parsed.thresholds.staleOpenCountMax, 4);
  assert.equal(parsed.thresholds.mttrDaysMax, 14);
  assert.deepEqual(parsed.routeLabels, ['security', 'governance']);
  assert.equal(parsed.overrideOwner, 'alice');
  assert.equal(parsed.overrideReason, 'release freeze');
  assert.equal(parsed.overrideExpiresAt, '2026-04-01T00:00:00Z');
  assert.equal(parsed.overrideTicket, '#999');
});

test('summaries and breaches calculate expected values', () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const openAlerts = [
    normalizeDependabotAlert(sampleAlert({ number: 1, created_at: '2026-01-01T00:00:00Z', security_advisory: { severity: 'high' } }), now),
    normalizeDependabotAlert(sampleAlert({ number: 2, created_at: '2026-03-01T00:00:00Z', security_advisory: { severity: 'moderate' } }), now)
  ];
  const resolvedAlerts = [
    normalizeDependabotAlert(
      sampleAlert({
        number: 3,
        state: 'fixed',
        created_at: '2026-02-01T00:00:00Z',
        fixed_at: '2026-02-21T00:00:00Z',
        security_advisory: { severity: 'critical' }
      }),
      now
    )
  ];

  const summary = summarizeDependabotAlerts({
    openAlerts,
    resolvedAlerts,
    thresholds: {
      ...DEFAULT_THRESHOLDS,
      staleOpenDays: 30
    },
    lookbackDays: 45,
    now
  });
  assert.equal(summary.open.total, 2);
  assert.equal(summary.open.bySeverity.high, 1);
  assert.equal(summary.open.bySeverity.moderate, 1);
  assert.equal(summary.open.staleCount, 1);
  assert.equal(summary.resolved.total, 1);
  assert.equal(summary.resolved.mttrDays.average, 20);

  const breaches = evaluateSecurityBreaches(summary, {
    ...DEFAULT_THRESHOLDS,
    openHighMax: 0,
    openModerateMax: 0,
    staleOpenCountMax: 0,
    mttrDaysMax: 10
  });
  assert.deepEqual(
    breaches.map((entry) => entry.code),
    ['mttr-days', 'open-high', 'open-moderate', 'stale-open-count']
  );
});

test('buildRemediationCandidates sorts by severity then age', () => {
  const candidates = buildRemediationCandidates([
    { number: 5, severity: 'moderate', ageDays: 3 },
    { number: 2, severity: 'critical', ageDays: 1 },
    { number: 4, severity: 'high', ageDays: 40 }
  ]);
  assert.deepEqual(
    candidates.map((entry) => entry.number),
    [2, 4, 5]
  );
});

test('evaluateOverride enforces metadata and expiration', () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const valid = evaluateOverride(
    {
      overrideOwner: 'alice',
      overrideReason: 'hotfix train',
      overrideExpiresAt: '2026-03-08T12:00:00Z',
      overrideTicket: '#100'
    },
    now
  );
  assert.equal(valid.provided, true);
  assert.equal(valid.active, true);
  assert.deepEqual(valid.validationErrors, []);

  const invalid = evaluateOverride(
    {
      overrideOwner: 'alice',
      overrideReason: '',
      overrideExpiresAt: '2026-03-01T00:00:00Z'
    },
    now
  );
  assert.equal(invalid.active, false);
  assert.ok(invalid.validationErrors.includes('reason-missing'));
  assert.ok(invalid.validationErrors.includes('expires-at-not-future'));
});

test('runSecurityIntake writes deterministic report and routes on breach', async () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'security-intake-'));
  const outputPath = path.join(tmpDir, 'report.json');

  const result = await runSecurityIntake(
    {
      outputPath,
      routeOnBreach: true,
      failOnBreach: true,
      thresholds: {
        ...DEFAULT_THRESHOLDS,
        openModerateMax: 0
      }
    },
    {
      now,
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => 'token',
      listDependabotAlertsFn: async ({ state }) => {
        if (state === 'open') return [sampleAlert()];
        return [];
      },
      upsertRemediationIssueFn: async () => ({
        action: 'created',
        issueNumber: 123,
        issueUrl: 'https://example.test/issues/123',
        title: '[Security Intake] Vulnerability remediation required',
        labels: DEFAULT_ROUTE_LABELS
      })
    }
  );

  assert.equal(result.exitCode, 2);
  assert.equal(result.report.status, 'breach');
  assert.equal(result.report.route.action, 'created');
  assert.equal(result.report.route.issueNumber, 123);
  assert.equal(result.report.flags.routeOnBreach, true);
  assert.equal(result.report.flags.failOnBreach, true);
  assert.equal(result.report.remediation.candidateCount, 1);

  const persisted = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(persisted.schema, 'priority/security-intake@v1');
  assert.equal(persisted.route.issueNumber, 123);
  assert.deepEqual(persisted.route.labels, DEFAULT_ROUTE_LABELS);
});

test('runSecurityIntake supports skip semantics and override bypass', async () => {
  const now = new Date('2026-03-06T12:00:00Z');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'security-intake-'));

  const skipped = await runSecurityIntake(
    {
      outputPath: path.join(tmpDir, 'skip.json'),
      failOnSkip: false
    },
    {
      now,
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => {
        throw new Error('missing token');
      }
    }
  );
  assert.equal(skipped.exitCode, 0);
  assert.equal(skipped.report.status, 'skip');

  const failOnSkip = await runSecurityIntake(
    {
      outputPath: path.join(tmpDir, 'skip-fail.json'),
      failOnSkip: true
    },
    {
      now,
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => {
        throw new Error('missing token');
      }
    }
  );
  assert.equal(failOnSkip.exitCode, 1);

  const overridden = await runSecurityIntake(
    {
      outputPath: path.join(tmpDir, 'override.json'),
      failOnBreach: true,
      thresholds: {
        ...DEFAULT_THRESHOLDS,
        openModerateMax: 0
      },
      overrideOwner: 'alice',
      overrideReason: 'approved emergency',
      overrideExpiresAt: '2026-03-09T12:00:00Z'
    },
    {
      now,
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => 'token',
      listDependabotAlertsFn: async ({ state }) => {
        if (state === 'open') return [sampleAlert()];
        return [];
      }
    }
  );

  assert.equal(overridden.exitCode, 0);
  assert.equal(overridden.report.status, 'overridden');
  assert.equal(overridden.report.override.active, true);
});


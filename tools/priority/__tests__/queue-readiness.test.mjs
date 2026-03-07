#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildQueueReadinessReport,
  parseArgs,
  parseFlakyExposure,
  parseRiskClass
} from '../queue-readiness.mjs';

test('parseArgs applies defaults and explicit paths', () => {
  const defaults = parseArgs(['node', 'queue-readiness.mjs']);
  assert.match(defaults.supervisorReportPath, /queue-supervisor-report\.json$/);
  assert.match(defaults.reportPath, /queue-readiness-report\.json$/);

  const parsed = parseArgs([
    'node',
    'queue-readiness.mjs',
    '--supervisor-report',
    'tmp/supervisor.json',
    '--report',
    'tmp/readiness.json'
  ]);
  assert.equal(parsed.supervisorReportPath, 'tmp/supervisor.json');
  assert.equal(parsed.reportPath, 'tmp/readiness.json');
});

test('parseRiskClass prefers body override, then labels, then medium default', () => {
  assert.equal(parseRiskClass({ body: 'Risk-Class: high', labels: ['risk-low'] }), 'high');
  assert.equal(parseRiskClass({ body: '', labels: [{ name: 'risk-low' }] }), 'low');
  assert.equal(parseRiskClass({ body: '', labels: [] }), 'medium');
});

test('parseFlakyExposure prefers body override, then labels, then none default', () => {
  assert.equal(parseFlakyExposure({ body: 'Flaky-Exposure: medium', labels: ['flaky-risk-high'] }), 'medium');
  assert.equal(parseFlakyExposure({ body: '', labels: [{ name: 'flaky-risk-high' }] }), 'high');
  assert.equal(parseFlakyExposure({ body: '', labels: [] }), 'none');
});

test('buildQueueReadinessReport ranks dependency-safe ready set deterministically', () => {
  const report = buildQueueReadinessReport({
    repository: 'owner/repo',
    now: new Date('2026-03-06T12:00:00.000Z'),
    orderedEligible: [101, 102],
    candidates: [
      {
        number: 102,
        title: '[P0] dependent',
        body: 'Coupling: hard\nRisk-Class: high',
        labels: ['flaky-risk-high'],
        url: 'https://example.test/pr/102',
        updatedAt: '2026-03-06T11:45:00.000Z',
        eligible: true,
        reasons: [],
        priority: 0,
        coupling: 'hard',
        unresolvedOpenDependencies: [],
        checks: { ok: true }
      },
      {
        number: 101,
        title: '[P1] foundation',
        body: 'Coupling: independent\nRisk-Class: low',
        labels: [],
        url: 'https://example.test/pr/101',
        updatedAt: '2026-03-06T10:00:00.000Z',
        eligible: true,
        reasons: [],
        priority: 1,
        coupling: 'independent',
        unresolvedOpenDependencies: [],
        checks: { ok: true }
      },
      {
        number: 103,
        title: '[P0] blocked',
        body: 'Coupling: independent',
        labels: [],
        url: 'https://example.test/pr/103',
        updatedAt: '2026-03-06T11:00:00.000Z',
        eligible: false,
        reasons: ['required-checks-missing'],
        priority: 0,
        coupling: 'independent',
        unresolvedOpenDependencies: [101],
        checks: { ok: false }
      }
    ]
  });

  assert.equal(report.schema, 'priority/queue-readiness-report@v1');
  assert.equal(report.summary.candidateCount, 3);
  assert.equal(report.summary.readyCount, 2);
  assert.deepEqual(report.readySet.map((entry) => entry.number), [101, 102]);
  assert.equal(report.readySet[0].dependencyRank, 0);
  assert.equal(report.readySet[1].dependencyRank, 1);
  assert.equal(report.candidates.find((entry) => entry.number === 103)?.eligible, false);
});

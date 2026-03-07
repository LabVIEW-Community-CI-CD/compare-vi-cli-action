#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { parseArgs, runWeeklyScorecard } from '../weekly-scorecard.mjs';

test('parseArgs applies defaults and explicit options', () => {
  const defaults = parseArgs(['node', 'weekly-scorecard.mjs']);
  assert.equal(defaults.mode, 'weekly');
  assert.equal(defaults.requireCanary, false);
  assert.equal(defaults.routeOnPersistentBreach, false);
  assert.deepEqual(defaults.issueLabels, ['governance', 'slo', 'canary']);

  const parsed = parseArgs([
    'node',
    'weekly-scorecard.mjs',
    '--mode',
    'gameday',
    '--require-canary',
    '--route-on-persistent-breach',
    '--issue-title-prefix',
    '[Gov] Breach',
    '--issue-labels',
    'governance,slo',
    '--repo',
    'owner/repo'
  ]);
  assert.equal(parsed.mode, 'gameday');
  assert.equal(parsed.requireCanary, true);
  assert.equal(parsed.routeOnPersistentBreach, true);
  assert.equal(parsed.issueTitlePrefix, '[Gov] Breach');
  assert.deepEqual(parsed.issueLabels, ['governance', 'slo']);
  assert.equal(parsed.repo, 'owner/repo');
});

test('runWeeklyScorecard passes when remediation passes and canary is optional', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.endsWith('weekly-scorecard.json')) {
      return {
        exists: false,
        path: filePath,
        payload: null,
        error: null
      };
    }
    if (normalized.includes('remediation-slo-report.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          summary: {
            status: 'pass'
          }
        },
        error: null
      };
    }
    return {
      exists: false,
      path: filePath,
      payload: null,
      error: null
    };
  };

  const { report, exitCode } = await runWeeklyScorecard({
    repoRoot: process.cwd(),
    now: new Date('2026-03-07T00:00:00Z'),
    args: {
      outputPath: 'tests/results/_agent/slo/weekly-scorecard.json',
      remediationReportPath: 'tests/results/_agent/slo/remediation-slo-report.json',
      canaryReportPath: 'tests/results/_agent/canary/canary-replay-conformance-report.json',
      mode: 'weekly',
      requireCanary: false,
      routeOnPersistentBreach: true,
      issueTitlePrefix: '[Governance] Weekly scorecard breach',
      issueLabels: ['governance', 'slo', 'canary'],
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
  assert.equal(report.summary.status, 'pass');
  assert.equal(report.summary.breachCount, 0);
  assert.equal(report.routing.action, 'none');
});

test('runWeeklyScorecard fails gameday when canary report is required but missing', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.endsWith('weekly-scorecard.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          summary: {
            status: 'pass'
          }
        },
        error: null
      };
    }
    if (normalized.includes('remediation-slo-report.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          summary: {
            status: 'pass'
          }
        },
        error: null
      };
    }
    return {
      exists: false,
      path: filePath,
      payload: null,
      error: null
    };
  };

  const { report } = await runWeeklyScorecard({
    repoRoot: process.cwd(),
    now: new Date('2026-03-07T00:00:00Z'),
    args: {
      outputPath: 'tests/results/_agent/slo/weekly-scorecard.json',
      remediationReportPath: 'tests/results/_agent/slo/remediation-slo-report.json',
      canaryReportPath: 'tests/results/_agent/canary/canary-replay-conformance-report.json',
      mode: 'gameday',
      requireCanary: true,
      routeOnPersistentBreach: false,
      issueTitlePrefix: '[Governance] Weekly scorecard breach',
      issueLabels: ['governance', 'slo', 'canary'],
      repo: 'owner/repo',
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo'
    },
    readJsonOptionalFn,
    writeJsonFn: async (reportPath) => reportPath
  });

  assert.equal(report.summary.status, 'fail');
  assert.ok(report.summary.breaches.some((entry) => entry.key === 'canary-missing'));
});

test('runWeeklyScorecard upserts governance issue on persistent breach', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.endsWith('weekly-scorecard.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          summary: {
            status: 'warn'
          }
        },
        error: null
      };
    }
    if (normalized.includes('remediation-slo-report.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          summary: {
            status: 'fail'
          }
        },
        error: null
      };
    }
    if (normalized.includes('canary-replay-conformance-report.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          status: 'fail'
        },
        error: null
      };
    }
    throw new Error(`Unexpected path: ${filePath}`);
  };

  let routeCallCount = 0;
  const routeIssueFn = async () => {
    routeCallCount += 1;
    return {
      action: 'create',
      issueNumber: 999,
      issueUrl: 'https://example.test/issues/999',
      error: null
    };
  };

  const { report } = await runWeeklyScorecard({
    repoRoot: process.cwd(),
    now: new Date('2026-03-07T00:00:00Z'),
    args: {
      outputPath: 'tests/results/_agent/slo/weekly-scorecard.json',
      remediationReportPath: 'tests/results/_agent/slo/remediation-slo-report.json',
      canaryReportPath: 'tests/results/_agent/canary/canary-replay-conformance-report.json',
      mode: 'gameday',
      requireCanary: true,
      routeOnPersistentBreach: true,
      issueTitlePrefix: '[Governance] Weekly scorecard breach',
      issueLabels: ['governance', 'slo', 'canary'],
      repo: 'owner/repo',
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo'
    },
    githubToken: 'token',
    readJsonOptionalFn,
    routeIssueFn,
    writeJsonFn: async (reportPath) => reportPath
  });

  assert.equal(report.summary.persistentBreach, true);
  assert.equal(routeCallCount, 1);
  assert.equal(report.routing.action, 'create');
  assert.equal(report.routing.issueNumber, 999);
});
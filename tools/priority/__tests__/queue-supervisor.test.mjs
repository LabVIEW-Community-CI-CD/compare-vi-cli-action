#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  classifyOpenPullRequests,
  evaluateHealthGate,
  evaluateRequiredChecks,
  parseArgs,
  runQueueSupervisor
} from '../queue-supervisor.mjs';

function successCheck(name) {
  return {
    __typename: 'CheckRun',
    name,
    status: 'COMPLETED',
    conclusion: 'SUCCESS'
  };
}

test('parseArgs defaults to dry-run and supports apply mode', () => {
  const defaults = parseArgs(['node', 'queue-supervisor.mjs']);
  assert.equal(defaults.apply, false);
  assert.equal(defaults.dryRun, true);
  assert.equal(defaults.maxInflight, 4);

  const apply = parseArgs(['node', 'queue-supervisor.mjs', '--apply', '--max-inflight', '6']);
  assert.equal(apply.apply, true);
  assert.equal(apply.dryRun, false);
  assert.equal(apply.maxInflight, 6);
});

test('evaluateRequiredChecks detects missing and failing contexts', () => {
  const checks = evaluateRequiredChecks(['lint', 'fixtures'], [successCheck('lint')]);
  assert.equal(checks.ok, false);
  assert.deepEqual(checks.missing, ['fixtures']);
  assert.deepEqual(checks.failing, []);
});

test('classifyOpenPullRequests enforces branch/check/label gates and dependency-safe ordering', () => {
  const result = classifyOpenPullRequests({
    pullRequests: [
      {
        number: 101,
        title: '[P1] foundation',
        body: 'Coupling: independent',
        baseRefName: 'develop',
        headRepositoryOwner: { login: 'owner' },
        isDraft: false,
        mergeStateStatus: 'CLEAN',
        mergeable: 'MERGEABLE',
        updatedAt: '2026-03-05T20:00:00Z',
        labels: [],
        statusCheckRollup: [successCheck('lint')]
      },
      {
        number: 102,
        title: '[P0] depends',
        body: 'Coupling: hard\nDepends-On: #101',
        baseRefName: 'develop',
        headRepositoryOwner: { login: 'owner' },
        isDraft: false,
        mergeStateStatus: 'CLEAN',
        mergeable: 'MERGEABLE',
        updatedAt: '2026-03-05T20:01:00Z',
        labels: [],
        statusCheckRollup: [successCheck('lint')]
      },
      {
        number: 103,
        title: '[P0] independent',
        body: 'Coupling: independent',
        baseRefName: 'develop',
        headRepositoryOwner: { login: 'owner' },
        isDraft: false,
        mergeStateStatus: 'CLEAN',
        mergeable: 'MERGEABLE',
        updatedAt: '2026-03-05T19:59:00Z',
        labels: [],
        statusCheckRollup: [successCheck('lint')]
      },
      {
        number: 104,
        title: '[P0] blocked',
        body: '',
        baseRefName: 'develop',
        headRepositoryOwner: { login: 'owner' },
        isDraft: false,
        mergeStateStatus: 'CLEAN',
        mergeable: 'MERGEABLE',
        updatedAt: '2026-03-05T19:58:00Z',
        labels: [{ name: 'queue-blocked' }],
        statusCheckRollup: [successCheck('lint')]
      },
      {
        number: 105,
        title: '[P0] missing checks',
        body: '',
        baseRefName: 'develop',
        headRepositoryOwner: { login: 'owner' },
        isDraft: false,
        mergeStateStatus: 'CLEAN',
        mergeable: 'MERGEABLE',
        updatedAt: '2026-03-05T19:57:00Z',
        labels: [],
        statusCheckRollup: []
      }
    ],
    requiredChecksByBranch: {
      develop: ['lint']
    },
    queueManagedBranches: new Set(['develop']),
    expectedHeadOwner: 'owner'
  });

  const ordered = result.orderedEligible.map((item) => item.number);
  assert.deepEqual(ordered, [103, 101, 102]);

  const blocked = result.candidates.find((item) => item.number === 104);
  assert.equal(blocked.eligible, false);
  assert.ok(blocked.reasons.includes('queue-label-blocked'));

  const missingChecks = result.candidates.find((item) => item.number === 105);
  assert.equal(missingChecks.eligible, false);
  assert.ok(missingChecks.reasons.includes('required-checks-missing'));
});

test('classifyOpenPullRequests marks fork-headed PRs ineligible when upstream owner is required', () => {
  const result = classifyOpenPullRequests({
    pullRequests: [
      {
        number: 110,
        title: '[P0] fork head',
        body: '',
        baseRefName: 'develop',
        headRepositoryOwner: { login: 'fork-owner' },
        isDraft: false,
        mergeStateStatus: 'CLEAN',
        mergeable: 'MERGEABLE',
        updatedAt: '2026-03-05T20:00:00Z',
        labels: [],
        statusCheckRollup: [successCheck('lint')]
      }
    ],
    requiredChecksByBranch: {
      develop: ['lint']
    },
    queueManagedBranches: new Set(['develop']),
    expectedHeadOwner: 'owner'
  });

  assert.equal(result.orderedEligible.length, 0);
  assert.equal(result.candidates[0].eligible, false);
  assert.ok(result.candidates[0].reasons.includes('head-not-upstream-owned'));
});

test('evaluateHealthGate pauses when success rate drops or red window exceeds threshold', () => {
  const now = new Date('2026-03-05T22:00:00.000Z');
  const pass = evaluateHealthGate({
    workflowRunsByName: {
      Validate: [
        { conclusion: 'success', status: 'completed', created_at: '2026-03-05T21:50:00Z', updated_at: '2026-03-05T21:52:00Z' },
        { conclusion: 'success', status: 'completed', created_at: '2026-03-05T21:40:00Z', updated_at: '2026-03-05T21:42:00Z' }
      ],
      'Policy Guard (Upstream)': [
        { conclusion: 'success', status: 'completed', created_at: '2026-03-05T21:30:00Z', updated_at: '2026-03-05T21:31:00Z' }
      ]
    },
    now
  });
  assert.equal(pass.paused, false);

  const lowSuccess = evaluateHealthGate({
    workflowRunsByName: {
      Validate: [
        { conclusion: 'failure', status: 'completed', created_at: '2026-03-05T21:55:00Z', updated_at: '2026-03-05T21:56:00Z' },
        { conclusion: 'failure', status: 'completed', created_at: '2026-03-05T21:45:00Z', updated_at: '2026-03-05T21:46:00Z' },
        { conclusion: 'success', status: 'completed', created_at: '2026-03-05T21:35:00Z', updated_at: '2026-03-05T21:36:00Z' }
      ]
    },
    now
  });
  assert.equal(lowSuccess.paused, true);
  assert.ok(lowSuccess.reasons.includes('success-rate-below-threshold'));

  const redWindow = evaluateHealthGate({
    workflowRunsByName: {
      Validate: [
        { conclusion: 'failure', status: 'completed', created_at: '2026-03-05T21:59:00Z', updated_at: '2026-03-05T21:59:30Z' },
        { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:45:00Z' }
      ]
    },
    now
  });
  assert.equal(redWindow.paused, true);
  assert.ok(redWindow.reasons.includes('trunk-red-window-exceeded'));
});

test('runQueueSupervisor apply mode quarantines on second failure within 24h', async () => {
  const commandCalls = [];
  const writeCalls = [];
  const responseMap = new Map();
  responseMap.set('pr', [
    {
      number: 22,
      title: '[P0] Queue managed change',
      body: 'Coupling: independent',
      baseRefName: 'develop',
      headRepositoryOwner: { login: 'owner' },
      isDraft: false,
      mergeStateStatus: 'BEHIND',
      mergeable: 'MERGEABLE',
      updatedAt: '2026-03-05T21:00:00Z',
      url: 'https://example.test/pr/22',
      labels: [],
      statusCheckRollup: [successCheck('lint')],
      autoMergeRequest: null
    }
  ]);
  responseMap.set('validate-runs', {
    workflow_runs: [
      { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:50:00Z', updated_at: '2026-03-05T20:52:00Z' }
    ]
  });
  responseMap.set('policy-runs', {
    workflow_runs: [
      { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:41:00Z' }
    ]
  });

  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') return responseMap.get('pr');
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) return responseMap.get('validate-runs');
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) return responseMap.get('policy-runs');
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
  };

  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'node') {
      return { status: 1, stdout: '', stderr: 'merge-sync failed' };
    }
    if (command === 'gh' && args[0] === 'pr' && args[1] === 'update-branch') {
      return { status: 0, stdout: '', stderr: '' };
    }
    if (command === 'gh' && args[0] === 'pr' && args[1] === 'edit') {
      return { status: 0, stdout: '', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const readJsonFileFn = async (filePath) => {
    if (String(filePath).endsWith('branch-required-checks.json')) {
      return { branches: { develop: ['lint'] } };
    }
    if (String(filePath).endsWith('policy.json')) {
      return {
        rulesets: {
          develop: {
            includes: ['refs/heads/develop'],
            merge_queue: { merge_method: 'SQUASH' }
          }
        }
      };
    }
    throw new Error(`Unexpected read path: ${filePath}`);
  };

  const readOptionalJsonFn = async () => ({
    retryHistory: {
      '22': {
        failures: ['2026-03-05T20:15:00.000Z']
      }
    }
  });

  const writeReportFn = async (reportPath, report) => {
    writeCalls.push({ reportPath, report });
    return reportPath;
  };

  const now = new Date('2026-03-05T21:30:00.000Z');
  const { report } = await runQueueSupervisor({
    repoRoot: process.cwd(),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      maxInflight: 4,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now,
    runGhJsonFn,
    runCommandFn,
    readJsonFileFn,
    readOptionalJsonFn,
    writeReportFn
  });

  assert.equal(report.summary.quarantinedCount, 1);
  assert.equal(report.actions.length, 1);
  assert.equal(report.actions[0].quarantined, true);
  assert.ok(commandCalls.some((call) => call.command === 'gh' && call.args[1] === 'edit'));
  assert.equal(writeCalls.length, 1);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  classifyOpenPullRequests,
  evaluateAdaptiveInflight,
  evaluateBurstWindow,
  evaluateHealthGate,
  evaluateRuntimeFleetHealth,
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
  const keys = [
    'QUEUE_AUTOPILOT_MAX_INFLIGHT',
    'QUEUE_AUTOPILOT_MIN_INFLIGHT',
    'QUEUE_AUTOPILOT_ADAPTIVE_CAP',
    'QUEUE_AUTOPILOT_MAX_QUEUED_RUNS',
    'QUEUE_AUTOPILOT_MAX_IN_PROGRESS_RUNS',
    'QUEUE_AUTOPILOT_STALL_THRESHOLD_MINUTES',
    'QUEUE_BURST_MODE',
    'QUEUE_BURST_REFILL_CYCLES'
  ];
  const previous = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  for (const key of keys) delete process.env[key];
  try {
    const defaults = parseArgs(['node', 'queue-supervisor.mjs']);
    assert.equal(defaults.apply, false);
    assert.equal(defaults.dryRun, true);
    assert.equal(defaults.maxInflight, 5);
    assert.equal(defaults.minInflight, 2);
    assert.equal(defaults.adaptiveCap, true);
    assert.equal(defaults.maxQueuedRuns, 6);
    assert.equal(defaults.maxInProgressRuns, 8);
    assert.equal(defaults.stallThresholdMinutes, 45);
    assert.equal(defaults.burstMode, 'auto');
    assert.equal(defaults.burstRefillCycles, 3);
    assert.match(defaults.readinessReportPath, /queue-readiness-report\.json$/);
    assert.match(defaults.governorStatePath, /ops-governor-state\.json$/);

    const apply = parseArgs([
      'node',
      'queue-supervisor.mjs',
      '--apply',
      '--max-inflight',
      '6',
      '--min-inflight',
      '3',
      '--no-adaptive-cap',
      '--max-queued-runs',
      '7',
      '--max-in-progress-runs',
      '9',
      '--stall-threshold-minutes',
      '50',
      '--governor-state',
      'tests/results/_agent/slo/custom-governor-state.json',
      '--burst-mode',
      'on',
      '--burst-refill-cycles',
      '4'
    ]);
    assert.equal(apply.apply, true);
    assert.equal(apply.dryRun, false);
    assert.equal(apply.maxInflight, 6);
    assert.equal(apply.minInflight, 3);
    assert.equal(apply.adaptiveCap, false);
    assert.equal(apply.maxQueuedRuns, 7);
    assert.equal(apply.maxInProgressRuns, 9);
    assert.equal(apply.stallThresholdMinutes, 50);
    assert.equal(apply.governorStatePath, 'tests/results/_agent/slo/custom-governor-state.json');
    assert.equal(apply.burstMode, 'on');
    assert.equal(apply.burstRefillCycles, 4);
  } finally {
    for (const key of keys) {
      if (previous[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = previous[key];
      }
    }
  }
});

test('parseArgs rejects invalid inflight bounds', () => {
  assert.throws(
    () => parseArgs(['node', 'queue-supervisor.mjs', '--max-inflight', '2', '--min-inflight', '3']),
    /min-inflight/i
  );
});

test('parseArgs reads adaptive inflight controls from environment', () => {
  const previous = {
    max: process.env.QUEUE_AUTOPILOT_MAX_INFLIGHT,
    min: process.env.QUEUE_AUTOPILOT_MIN_INFLIGHT,
    adaptive: process.env.QUEUE_AUTOPILOT_ADAPTIVE_CAP,
    burstMode: process.env.QUEUE_BURST_MODE,
    burstRefillCycles: process.env.QUEUE_BURST_REFILL_CYCLES
  };
  process.env.QUEUE_AUTOPILOT_MAX_INFLIGHT = '4';
  process.env.QUEUE_AUTOPILOT_MIN_INFLIGHT = '1';
  process.env.QUEUE_AUTOPILOT_ADAPTIVE_CAP = '0';
  process.env.QUEUE_BURST_MODE = 'on';
  process.env.QUEUE_BURST_REFILL_CYCLES = '6';
  try {
    const parsed = parseArgs(['node', 'queue-supervisor.mjs']);
    assert.equal(parsed.maxInflight, 4);
    assert.equal(parsed.minInflight, 1);
    assert.equal(parsed.adaptiveCap, false);
    assert.equal(parsed.burstMode, 'on');
    assert.equal(parsed.burstRefillCycles, 6);
  } finally {
    if (previous.max === undefined) delete process.env.QUEUE_AUTOPILOT_MAX_INFLIGHT;
    else process.env.QUEUE_AUTOPILOT_MAX_INFLIGHT = previous.max;
    if (previous.min === undefined) delete process.env.QUEUE_AUTOPILOT_MIN_INFLIGHT;
    else process.env.QUEUE_AUTOPILOT_MIN_INFLIGHT = previous.min;
    if (previous.adaptive === undefined) delete process.env.QUEUE_AUTOPILOT_ADAPTIVE_CAP;
    else process.env.QUEUE_AUTOPILOT_ADAPTIVE_CAP = previous.adaptive;
    if (previous.burstMode === undefined) delete process.env.QUEUE_BURST_MODE;
    else process.env.QUEUE_BURST_MODE = previous.burstMode;
    if (previous.burstRefillCycles === undefined) delete process.env.QUEUE_BURST_REFILL_CYCLES;
    else process.env.QUEUE_BURST_REFILL_CYCLES = previous.burstRefillCycles;
  }
});

test('evaluateAdaptiveInflight applies fixed/guarded/stabilize controller modes deterministically', () => {
  const fixed = evaluateAdaptiveInflight({
    maxInflight: 5,
    minInflight: 2,
    adaptiveCap: false,
    health: { successRate: 1, minSuccessRate: 0.8 },
    runtimeFleet: { totals: { queued: 0, inProgress: 0, stalled: 0 }, thresholds: { maxQueuedRuns: 6, maxInProgressRuns: 8 } }
  });
  assert.equal(fixed.effectiveMaxInflight, 5);
  assert.equal(fixed.tier, 'fixed');

  const guarded = evaluateAdaptiveInflight({
    maxInflight: 5,
    minInflight: 2,
    adaptiveCap: true,
    health: { successRate: 0.86, minSuccessRate: 0.8 },
    runtimeFleet: { totals: { queued: 4, inProgress: 1, stalled: 0 }, thresholds: { maxQueuedRuns: 6, maxInProgressRuns: 8 } },
    retryPressure: { retryRatio: 0.05, quarantineRatio: 0 }
  });
  assert.equal(guarded.effectiveMaxInflight, 3);
  assert.equal(guarded.tier, 'guarded');
  assert.ok(guarded.reasons.includes('success-rate-warning'));

  const restricted = evaluateAdaptiveInflight({
    maxInflight: 5,
    minInflight: 2,
    adaptiveCap: true,
    health: { successRate: 0.78, minSuccessRate: 0.8 },
    runtimeFleet: { totals: { queued: 1, inProgress: 1, stalled: 1 }, thresholds: { maxQueuedRuns: 6, maxInProgressRuns: 8 } },
    retryPressure: { retryRatio: 0.36, quarantineRatio: 0.3 }
  });
  assert.equal(restricted.effectiveMaxInflight, 2);
  assert.equal(restricted.tier, 'stabilize');
  assert.ok(restricted.reasons.includes('stalled-runs-detected'));
});

test('evaluateAdaptiveInflight applies hysteresis before upgrading from stabilize', () => {
  const firstRecovery = evaluateAdaptiveInflight({
    maxInflight: 5,
    minInflight: 2,
    adaptiveCap: true,
    health: { successRate: 0.95, minSuccessRate: 0.8 },
    runtimeFleet: { totals: { queued: 0, inProgress: 0, stalled: 0 }, thresholds: { maxQueuedRuns: 6, maxInProgressRuns: 8 } },
    retryPressure: { retryRatio: 0, quarantineRatio: 0 },
    previousControllerState: { mode: 'stabilize', upgradeStreak: 0 }
  });
  assert.equal(firstRecovery.tier, 'stabilize');
  assert.equal(firstRecovery.hysteresis.transition, 'upgrade-pending');
  assert.equal(firstRecovery.hysteresis.upgradeStreak, 1);

  const secondRecovery = evaluateAdaptiveInflight({
    maxInflight: 5,
    minInflight: 2,
    adaptiveCap: true,
    health: { successRate: 0.95, minSuccessRate: 0.8 },
    runtimeFleet: { totals: { queued: 0, inProgress: 0, stalled: 0 }, thresholds: { maxQueuedRuns: 6, maxInProgressRuns: 8 } },
    retryPressure: { retryRatio: 0, quarantineRatio: 0 },
    previousControllerState: { mode: 'stabilize', upgradeStreak: 1 }
  });
  assert.equal(secondRecovery.tier, 'guarded');
  assert.equal(secondRecovery.hysteresis.transition, 'upgrade-applied');
});

test('evaluateBurstWindow activates on release triggers and carries refill cycles', () => {
  const initial = evaluateBurstWindow({
    burstMode: 'auto',
    burstRefillCycles: 2,
    now: new Date('2026-03-04T18:10:00.000Z'),
    pullRequests: []
  });
  assert.equal(initial.active, true);
  assert.equal(initial.refillCyclesRemaining, 2);
  assert.ok(initial.reasons.includes('release-window'));

  const refill = evaluateBurstWindow({
    burstMode: 'auto',
    burstRefillCycles: 2,
    now: new Date('2026-03-04T19:10:00.000Z'),
    pullRequests: [],
    previousBurst: {
      refillCyclesRemaining: initial.refillCyclesRemaining
    }
  });
  assert.equal(refill.active, true);
  assert.equal(refill.refillCyclesRemaining, 1);
  assert.ok(refill.reasons.includes('refill-cycles'));
});

test('evaluateBurstWindow applies stabilize backoff and disables burst temporarily', () => {
  const burst = evaluateBurstWindow({
    burstMode: 'on',
    burstRefillCycles: 3,
    now: new Date('2026-03-06T12:00:00.000Z'),
    controllerMode: 'stabilize',
    pullRequests: [
      {
        number: 700,
        baseRefName: 'develop',
        headRefName: 'release/2026.03'
      }
    ]
  });

  assert.equal(burst.active, false);
  assert.equal(burst.backoffActive, true);
  assert.ok(typeof burst.backoffUntil === 'string' && burst.backoffUntil.endsWith('Z'));
  assert.ok(burst.reasons.includes('stabilize-backoff'));
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

test('classifyOpenPullRequests keeps fork-headed PRs eligible when checks and queue rules are clean', () => {
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
    queueManagedBranches: new Set(['develop'])
  });

  assert.equal(result.orderedEligible.length, 1);
  assert.equal(result.candidates[0].eligible, true);
  assert.deepEqual(result.candidates[0].reasons, []);
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

test('evaluateRuntimeFleetHealth pauses on saturation and stalled runs', () => {
  const now = new Date('2026-03-05T22:00:00.000Z');
  const runtime = evaluateRuntimeFleetHealth({
    workflowRunsByName: {
      Validate: [
        {
          id: 1,
          status: 'queued',
          conclusion: null,
          created_at: '2026-03-05T21:00:00Z',
          updated_at: '2026-03-05T21:05:00Z',
          html_url: 'https://example.test/runs/1'
        },
        {
          id: 2,
          status: 'queued',
          conclusion: null,
          created_at: '2026-03-05T21:55:00Z',
          updated_at: '2026-03-05T21:56:00Z',
          html_url: 'https://example.test/runs/2'
        }
      ],
      'Policy Guard (Upstream)': [
        {
          id: 3,
          status: 'in_progress',
          conclusion: null,
          created_at: '2026-03-05T21:40:00Z',
          updated_at: '2026-03-05T21:41:00Z',
          html_url: 'https://example.test/runs/3'
        }
      ]
    },
    now,
    maxQueuedRuns: 1,
    maxInProgressRuns: 0,
    stallThresholdMinutes: 30
  });

  assert.equal(runtime.paused, true);
  assert.ok(runtime.reasons.includes('queued-runs-threshold-exceeded'));
  assert.ok(runtime.reasons.includes('in-progress-runs-threshold-exceeded'));
  assert.ok(runtime.reasons.includes('stalled-runs-detected'));
  assert.equal(runtime.totals.queued, 2);
  assert.equal(runtime.totals.inProgress, 1);
  assert.equal(runtime.totals.stalled >= 1, true);
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
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
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
      minInflight: 1,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
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
  assert.equal(report.maxInflight, 4);
  assert.equal(report.effectiveMaxInflight, 4);
  assert.equal(report.adaptiveInflight.enabled, false);
  assert.ok(commandCalls.some((call) => call.command === 'gh' && call.args[1] === 'edit'));
  assert.equal(writeCalls.length, 3);
  assert.ok(writeCalls.some((call) => String(call.reportPath).includes('throughput-controller-state.json')));
  assert.ok(writeCalls.some((call) => String(call.reportPath).includes('queue-readiness-report.json')));
});

test('runQueueSupervisor does not enqueue when pause control is active', async () => {
  const priorPause = process.env.QUEUE_AUTOPILOT_PAUSED;
  process.env.QUEUE_AUTOPILOT_PAUSED = '1';
  const commandCalls = [];

  try {
    const runGhJsonFn = (args) => {
      if (args[0] === 'pr' && args[1] === 'list') {
        return [
          {
            number: 301,
            title: '[P0] eligible change',
            body: 'Coupling: independent',
            baseRefName: 'develop',
            headRepositoryOwner: { login: 'owner' },
            isDraft: false,
            mergeStateStatus: 'CLEAN',
            mergeable: 'MERGEABLE',
            updatedAt: '2026-03-05T21:00:00Z',
            url: 'https://example.test/pr/301',
            labels: [],
            statusCheckRollup: [successCheck('lint')],
            autoMergeRequest: null
          }
        ];
      }
      if (args[0] === 'api' && String(args[1]).includes('validate.yml')) {
        return {
          workflow_runs: [
            { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:50:00Z', updated_at: '2026-03-05T20:52:00Z' }
          ]
        };
      }
      if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) {
        return {
          workflow_runs: [
            { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:41:00Z' }
          ]
        };
      }
      if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
      if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    };

    const runCommandFn = (command, args) => {
      commandCalls.push({ command, args });
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

    const { report } = await runQueueSupervisor({
      repoRoot: process.cwd(),
      args: {
        apply: true,
        dryRun: false,
        reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
        maxInflight: 4,
        minInflight: 1,
        adaptiveCap: false,
        maxQueuedRuns: 6,
        maxInProgressRuns: 8,
        stallThresholdMinutes: 45,
        repo: 'owner/repo',
        baseBranches: ['develop', 'main'],
        healthBranch: 'develop',
        help: false
      },
      now: new Date('2026-03-05T21:30:00.000Z'),
      runGhJsonFn,
      runCommandFn,
      readJsonFileFn,
      readOptionalJsonFn: async () => ({}),
      writeReportFn: async (reportPath) => reportPath
    });

    assert.equal(report.paused, true);
    assert.ok(report.pausedReasons.includes('paused-by-variable'));
    assert.equal(report.summary.eligibleCount, 1);
    assert.equal(report.summary.enqueuedCount, 0);
    assert.equal(report.actions.length, 0);
    assert.equal(
      commandCalls.some((call) => call.command === 'node' && call.args.includes('tools/priority/merge-sync-pr.mjs')),
      false
    );
  } finally {
    if (priorPause === undefined) {
      delete process.env.QUEUE_AUTOPILOT_PAUSED;
    } else {
      process.env.QUEUE_AUTOPILOT_PAUSED = priorPause;
    }
  }
});

test('runQueueSupervisor enqueues eligible PRs in dependency-safe deterministic order', async () => {
  const commandCalls = [];
  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') {
      return [
        {
          number: 401,
          title: '[P1] foundational change',
          body: 'Coupling: independent',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'owner' },
          isDraft: false,
          mergeStateStatus: 'CLEAN',
          mergeable: 'MERGEABLE',
          updatedAt: '2026-03-05T20:05:00Z',
          url: 'https://example.test/pr/401',
          labels: [],
          statusCheckRollup: [successCheck('lint')],
          autoMergeRequest: null
        },
        {
          number: 402,
          title: '[P0] follow-up dependent change',
          body: 'Coupling: hard\nDepends-On: #401',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'owner' },
          isDraft: false,
          mergeStateStatus: 'CLEAN',
          mergeable: 'MERGEABLE',
          updatedAt: '2026-03-05T20:10:00Z',
          url: 'https://example.test/pr/402',
          labels: [],
          statusCheckRollup: [successCheck('lint')],
          autoMergeRequest: null
        },
        {
          number: 403,
          title: '[P0] independent urgent change',
          body: 'Coupling: independent',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'owner' },
          isDraft: false,
          mergeStateStatus: 'CLEAN',
          mergeable: 'MERGEABLE',
          updatedAt: '2026-03-05T20:00:00Z',
          url: 'https://example.test/pr/403',
          labels: [],
          statusCheckRollup: [successCheck('lint')],
          autoMergeRequest: null
        }
      ];
    }
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:50:00Z', updated_at: '2026-03-05T20:52:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:41:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
  };

  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'node' && args[0] === 'tools/priority/merge-sync-pr.mjs') {
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

  const { report } = await runQueueSupervisor({
    repoRoot: process.cwd(),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      maxInflight: 5,
      minInflight: 1,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now: new Date('2026-03-05T21:30:00.000Z'),
    runGhJsonFn,
    runCommandFn,
    readJsonFileFn,
    readOptionalJsonFn: async (filePath) => {
      if (String(filePath).includes('merge-sync-')) {
        return {
          finalMode: 'auto',
          finalReason: 'merge-queue-branch-develop',
          promotion: {
            status: 'queued',
            materialized: true
          }
        };
      }
      return {};
    },
    writeReportFn: async (reportPath) => reportPath
  });

  const actionNumbers = report.actions.map((action) => action.number);
  assert.deepEqual(actionNumbers, [403, 401, 402]);
  assert.equal(actionNumbers.indexOf(401) < actionNumbers.indexOf(402), true);
  assert.equal(report.summary.enqueuedCount, 3);
  assert.equal(report.summary.quarantinedCount, 0);
  assert.equal(report.readiness.readySet[0].number, 403);
  assert.equal(report.readiness.readySet[1].number, 401);
  assert.equal(report.readiness.readySet[2].number, 402);
  for (const action of report.actions) {
    assert.equal(action.status, 'enqueued');
    assert.ok(action.attempts.some((attempt) => attempt.type === 'merge-sync' && attempt.status === 0));
  }
  const mergeSyncInvocations = commandCalls.filter(
    (call) => call.command === 'node' && call.args[0] === 'tools/priority/merge-sync-pr.mjs'
  );
  assert.equal(mergeSyncInvocations.length, 3);
});

test('runQueueSupervisor does not mark enqueue success when merge-sync exits 0 without durable promotion state', async () => {
  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') {
      return [
        {
          number: 611,
          title: '[P0] eligible change',
          body: 'Coupling: independent',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'owner' },
          isDraft: false,
          mergeStateStatus: 'CLEAN',
          mergeable: 'MERGEABLE',
          updatedAt: '2026-03-05T20:05:00Z',
          url: 'https://example.test/pr/611',
          labels: [],
          statusCheckRollup: [successCheck('lint')],
          autoMergeRequest: null
        }
      ];
    }
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:50:00Z', updated_at: '2026-03-05T20:52:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:41:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
  };

  const runCommandFn = (command, args) => {
    if (command === 'node' && args[0] === 'tools/priority/merge-sync-pr.mjs') {
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

  const { report } = await runQueueSupervisor({
    repoRoot: process.cwd(),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      maxInflight: 5,
      minInflight: 1,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now: new Date('2026-03-05T21:30:00.000Z'),
    runGhJsonFn,
    runCommandFn,
    readJsonFileFn,
    readOptionalJsonFn: async (filePath) => {
      if (String(filePath).includes('merge-sync-')) {
        return {
          finalMode: 'auto',
          finalReason: 'merge-queue-branch-develop',
          promotion: {
            status: 'unchanged',
            materialized: false
          }
        };
      }
      return {};
    },
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(report.summary.enqueuedCount, 0);
  assert.equal(report.actions.length, 1);
  assert.equal(report.actions[0].status, 'failed');
  assert.equal(report.actions[0].mergeSummary.materialized, false);
  assert.equal(report.actions[0].mergeSummary.promotionStatus, 'unchanged');
});

test('runQueueSupervisor reconciles deferred branch cleanup receipts after queued merges materialize', async () => {
  const writes = [];
  const reconcileCalls = [];
  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') {
      return [];
    }
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:50:00Z', updated_at: '2026-03-05T20:52:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:41:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
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

  const mergeSummaryReceipt = {
    repo: 'owner/repo',
    pr: 711,
    branchCleanup: {
      requested: true,
      status: 'deferred',
      reason: 'promotion-not-yet-merged',
      postMergeDelete: true,
      repository: 'owner/repo-fork',
      headRefName: 'issue/origin-711-test'
    },
    promotion: {
      status: 'queued',
      materialized: true
    }
  };

  const { report } = await runQueueSupervisor({
    repoRoot: process.cwd(),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      maxInflight: 5,
      minInflight: 1,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now: new Date('2026-03-05T21:30:00.000Z'),
    runGhJsonFn,
    runCommandFn: () => ({ status: 0, stdout: '', stderr: '' }),
    readdirFn: async () => ['merge-sync-711.json'],
    readJsonFileFn,
    readOptionalJsonFn: async (filePath) => {
      if (String(filePath).includes('merge-sync-711.json')) {
        return mergeSummaryReceipt;
      }
      return null;
    },
    reconcileDeferredBranchCleanupFn: async ({ summary }) => {
      reconcileCalls.push(summary.pr);
      return {
        changed: true,
        status: 'completed',
        promotion: { status: 'merged' },
        summary: {
          ...summary,
          branchCleanup: {
            ...summary.branchCleanup,
            status: 'deleted',
            reason: 'post-merge-api-delete'
          }
        }
      };
    },
    writeReportFn: async (reportPath, payload) => {
      writes.push({ reportPath: String(reportPath), payload });
      return reportPath;
    }
  });

  assert.deepEqual(reconcileCalls, [711]);
  assert.equal(report.deferredBranchCleanup.summary.completedCount, 1);
  assert.equal(report.deferredBranchCleanup.summary.pendingCount, 0);
  assert.equal(report.deferredBranchCleanup.actions[0].status, 'completed');
  assert.equal(report.deferredBranchCleanup.actions[0].branchCleanupStatus, 'deleted');
  assert.ok(writes.some((entry) => String(entry.reportPath).includes('merge-sync-711.json')));
});

test('runQueueSupervisor reports deferred branch cleanup receipts in dry-run mode without mutating them', async () => {
  let reconcileCalled = false;
  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') {
      return [];
    }
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
  };

  const readJsonFileFn = async (filePath) => {
    if (String(filePath).endsWith('branch-required-checks.json')) {
      return { branches: { develop: ['lint'] } };
    }
    if (String(filePath).endsWith('policy.json')) {
      return { rulesets: {} };
    }
    throw new Error(`Unexpected read path: ${filePath}`);
  };

  const { report } = await runQueueSupervisor({
    repoRoot: process.cwd(),
    args: {
      apply: false,
      dryRun: true,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      maxInflight: 5,
      minInflight: 1,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now: new Date('2026-03-05T21:30:00.000Z'),
    runGhJsonFn,
    readdirFn: async () => ['merge-sync-712.json'],
    readJsonFileFn,
    readOptionalJsonFn: async (filePath) => {
      if (String(filePath).includes('merge-sync-712.json')) {
        return {
          repo: 'owner/repo',
          pr: 712,
          branchCleanup: {
            requested: true,
            status: 'deferred',
            reason: 'promotion-not-yet-merged',
            postMergeDelete: true
          },
          promotion: {
            status: 'queued',
            materialized: true
          }
        };
      }
      return null;
    },
    reconcileDeferredBranchCleanupFn: async () => {
      reconcileCalled = true;
      return null;
    },
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(reconcileCalled, false);
  assert.equal(report.deferredBranchCleanup.summary.pendingCount, 1);
  assert.equal(report.deferredBranchCleanup.actions[0].status, 'pending');
});

test('runQueueSupervisor respects governor pause mode before enqueue actions', async () => {
  const commandCalls = [];
  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') {
      return [
        {
          number: 510,
          title: '[P0] eligible change',
          body: 'Coupling: independent',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'owner' },
          isDraft: false,
          mergeStateStatus: 'CLEAN',
          mergeable: 'MERGEABLE',
          updatedAt: '2026-03-05T20:05:00Z',
          url: 'https://example.test/pr/510',
          labels: [],
          statusCheckRollup: [successCheck('lint')],
          autoMergeRequest: null
        }
      ];
    }
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:50:00Z', updated_at: '2026-03-05T20:52:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:41:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
  };

  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
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

  const readOptionalJsonFn = async (filePath) => {
    if (String(filePath).includes('ops-governor-state.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          schema: 'ops-governor-state@v1',
          mode: 'pause',
          desiredMode: 'pause',
          reasons: ['trunk-red-fail-threshold'],
          generatedAt: '2026-03-05T21:00:00Z'
        }
      };
    }
    return {};
  };

  const { report } = await runQueueSupervisor({
    repoRoot: process.cwd(),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      governorStatePath: 'tests/results/_agent/slo/ops-governor-state.json',
      maxInflight: 5,
      minInflight: 2,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now: new Date('2026-03-05T21:30:00.000Z'),
    runGhJsonFn,
    runCommandFn,
    readJsonFileFn,
    readOptionalJsonFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(report.governor.mode, 'pause');
  assert.equal(report.governor.capApplied, true);
  assert.equal(report.governor.capLimit, 0);
  assert.equal(report.effectiveMaxInflight, 0);
  assert.equal(report.paused, true);
  assert.ok(report.pausedReasons.includes('governor-pause'));
  assert.equal(report.summary.enqueuedCount, 0);
  assert.equal(report.actions.length, 0);
  assert.equal(
    commandCalls.some((call) => call.command === 'node' && call.args.includes('tools/priority/merge-sync-pr.mjs')),
    false
  );
});

test('runQueueSupervisor applies governor stabilize cap when queue is healthy', async () => {
  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') {
      return [
        {
          number: 520,
          title: '[P0] eligible change',
          body: 'Coupling: independent',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'owner' },
          isDraft: false,
          mergeStateStatus: 'CLEAN',
          mergeable: 'MERGEABLE',
          updatedAt: '2026-03-05T20:05:00Z',
          url: 'https://example.test/pr/520',
          labels: [],
          statusCheckRollup: [successCheck('lint')],
          autoMergeRequest: null
        }
      ];
    }
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:50:00Z', updated_at: '2026-03-05T20:52:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-05T20:40:00Z', updated_at: '2026-03-05T20:41:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
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

  const readOptionalJsonFn = async (filePath) => {
    if (String(filePath).includes('ops-governor-state.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          schema: 'ops-governor-state@v1',
          mode: 'stabilize',
          desiredMode: 'stabilize',
          reasons: ['slo-breach'],
          generatedAt: '2026-03-05T21:00:00Z'
        }
      };
    }
    return {};
  };

  const { report } = await runQueueSupervisor({
    repoRoot: process.cwd(),
    args: {
      apply: false,
      dryRun: true,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      governorStatePath: 'tests/results/_agent/slo/ops-governor-state.json',
      maxInflight: 5,
      minInflight: 2,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now: new Date('2026-03-05T21:30:00.000Z'),
    runGhJsonFn,
    runCommandFn: () => ({ status: 0, stdout: '', stderr: '' }),
    readJsonFileFn,
    readOptionalJsonFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(report.governor.mode, 'stabilize');
  assert.equal(report.governor.capApplied, true);
  assert.equal(report.governor.capLimit, 2);
  assert.equal(report.effectiveMaxInflight, 2);
  assert.equal(report.paused, false);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  evaluateGreenDwell,
  evaluatePolicySnapshotGate,
  evaluateQuarantineGate,
  evaluateQueueHealthGate,
  parseArgs,
  runReleaseConductor
} from '../release-conductor.mjs';

function makeWorkflowRunsResponse(workflowFile) {
  if (workflowFile.includes('validate.yml')) {
    return {
      workflow_runs: [
        {
          id: 1,
          status: 'completed',
          conclusion: 'success',
          updated_at: '2026-03-06T11:45:00Z'
        }
      ]
    };
  }
  return {
    workflow_runs: [
      {
        id: 2,
        status: 'completed',
        conclusion: 'success',
        updated_at: '2026-03-06T11:40:00Z'
      }
    ]
  };
}

test('parseArgs applies defaults and supports burst-style apply flags', () => {
  const defaults = parseArgs(['node', 'release-conductor.mjs']);
  assert.equal(defaults.apply, false);
  assert.equal(defaults.dryRun, true);
  assert.equal(defaults.repairExistingTag, false);
  assert.equal(defaults.channel, 'stable');
  assert.equal(defaults.dwellMinutes, 60);

  const parsed = parseArgs([
    'node',
    'release-conductor.mjs',
    '--apply',
    '--repair-existing-tag',
    '--repo',
    'owner/repo',
    '--channel',
    'rc',
    '--version',
    '0.8.0-rc.1',
    '--dwell-minutes',
    '30',
    '--quarantine-stale-hours',
    '12'
  ]);
  assert.equal(parsed.apply, true);
  assert.equal(parsed.dryRun, false);
  assert.equal(parsed.repairExistingTag, true);
  assert.equal(parsed.repo, 'owner/repo');
  assert.equal(parsed.channel, 'rc');
  assert.equal(parsed.version, '0.8.0-rc.1');
  assert.equal(parsed.dwellMinutes, 30);
  assert.equal(parsed.quarantineStaleHours, 12);
});

test('gate evaluators classify pass/fail deterministically', () => {
  const now = new Date('2026-03-06T12:00:00.000Z');
  const green = evaluateGreenDwell({
    now,
    dwellMinutes: 60,
    workflowRunsByName: {
      Validate: [{ status: 'completed', conclusion: 'success', updated_at: '2026-03-06T11:30:00Z' }],
      'Policy Guard (Upstream)': [{ status: 'completed', conclusion: 'success', updated_at: '2026-03-06T11:35:00Z' }]
    }
  });
  assert.equal(green.status, 'pass');

  const queueFail = evaluateQueueHealthGate({
    exists: true,
    error: null,
    payload: {
      paused: true,
      throughputController: { mode: 'stabilize' }
    }
  });
  assert.equal(queueFail.status, 'fail');
  assert.ok(queueFail.reasons.includes('queue-paused'));

  const queueIdlePass = evaluateQueueHealthGate({
    exists: true,
    error: null,
    payload: {
      paused: true,
      pausedReasons: ['success-rate-below-threshold'],
      throughputController: { mode: 'stabilize' },
      runtimeFleet: {
        totals: {
          queued: 0,
          inProgress: 0,
          stalled: 0
        }
      },
      queueInventory: {
        mergeQueueOccupancy: 0,
        readyQueuedCount: 0
      },
      summary: {
        quarantinedCount: 0
      }
    }
  });
  assert.equal(queueIdlePass.status, 'pass');
  assert.equal(queueIdlePass.paused, true);
  assert.equal(queueIdlePass.controllerMode, 'stabilize');
  assert.deepEqual(queueIdlePass.reasons, ['release-safe-idle-queue-pause']);

  const policyPass = evaluatePolicySnapshotGate({
    exists: true,
    error: null,
    payload: {
      schema: 'priority/policy-live-state@v1',
      generatedAt: '2026-03-06T11:00:00Z',
      state: {}
    }
  });
  assert.equal(policyPass.status, 'pass');

  const quarantineFail = evaluateQuarantineGate({
    now,
    staleHours: 24,
    queueReportEnvelope: {
      exists: true,
      error: null,
      payload: {
        retryHistory: {
          '88': {
            failures: ['2026-03-04T10:00:00Z', '2026-03-04T11:00:00Z']
          }
        }
      }
    }
  });
  assert.equal(quarantineFail.status, 'fail');
  assert.equal(quarantineFail.staleCount, 1);

  const quarantineUnavailable = evaluateQuarantineGate({
    now,
    staleHours: 12,
    queueReportEnvelope: {
      exists: false,
      error: null,
      payload: null
    }
  });
  assert.equal(quarantineUnavailable.status, 'fail');
  assert.equal(quarantineUnavailable.staleHours, 12);
});

test('runReleaseConductor blocks apply when release conductor flag is disabled', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const commandCalls = [];
  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'git' && args[0] === 'config') {
      return { status: 0, stdout: 'ABC123', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'stable',
      version: '0.8.0',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '0'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 1);
  assert.equal(report.decision.status, 'fail');
  assert.ok(report.decision.blockers.some((entry) => entry.code === 'apply-disabled'));
  assert.equal(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'tag'), false);
});

test('runReleaseConductor keeps dry-run proposal-only when queue evidence is missing and no recent success exists', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: false,
        error: null,
        path: filePath,
        payload: null
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] !== 'api') {
      throw new Error(`unexpected gh args: ${args.join(' ')}`);
    }
    return {
      workflow_runs: [
        {
          id: 1,
          status: 'completed',
          conclusion: 'success',
          updated_at: '2026-03-06T09:00:00Z'
        }
      ]
    };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: false,
      dryRun: true,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'stable',
      version: '0.8.0',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '0'
    },
    runGhJsonFn,
    runCommandFn: () => ({ status: 0, stdout: '', stderr: '' }),
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 0);
  assert.equal(report.decision.status, 'pass');
  assert.equal(report.release.proposalOnly, true);
  assert.equal(report.gates.greenDwell.status, 'fail');
  assert.equal(report.gates.queueHealth.status, 'fail');
  assert.equal(report.gates.quarantine.status, 'fail');
  assert.equal(report.decision.blockerCount, 0);
  assert.ok(report.decision.advisories.some((entry) => entry.code === 'green-dwell-no-recent-success'));
  assert.ok(report.decision.advisories.some((entry) => entry.code === 'queue-report-unavailable-dry-run'));
});

test('runReleaseConductor still blocks dry-run when the dwell window contains workflow failures', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] !== 'api') {
      throw new Error(`unexpected gh args: ${args.join(' ')}`);
    }
    return {
      workflow_runs: [
        {
          id: 1,
          status: 'completed',
          conclusion: 'failure',
          updated_at: '2026-03-06T11:45:00Z'
        }
      ]
    };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: false,
      dryRun: true,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'stable',
      version: '0.8.0',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '0'
    },
    runGhJsonFn,
    runCommandFn: () => ({ status: 0, stdout: '', stderr: '' }),
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 1);
  assert.equal(report.decision.status, 'fail');
  assert.ok(report.decision.blockers.some((entry) => entry.code === 'green-dwell-failed'));
});

test('runReleaseConductor creates and publishes a signed tag when apply is enabled and signing key is available', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const commandCalls = [];
  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'git' && args[0] === 'config') {
      if (args[2] === 'user.signingkey') {
        return { status: 0, stdout: '/tmp/release-signing.pub', stderr: '' };
      }
      if (args[2] === 'gpg.format') {
        return { status: 0, stdout: 'ssh', stderr: '' };
      }
      if (args[2] === 'remote.upstream.url') {
        return { status: 0, stdout: 'https://github.com/owner/repo.git', stderr: '' };
      }
      return { status: 1, stdout: '', stderr: 'missing config' };
    }
    if (command === 'git' && args[0] === 'ls-remote') {
      return {
        status: 0,
        stdout: [
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v0.8.0-rc.1',
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v0.8.0-rc.1^{}'
        ].join('\n'),
        stderr: ''
      };
    }
    if (command === 'git' && args[0] === 'rev-parse') {
      return { status: 0, stdout: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n', stderr: '' };
    }
    if (command === 'git' && args[0] === 'tag') {
      return { status: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'push') {
      return { status: 0, stdout: '', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'stable',
      version: '0.8.0',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '1'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 0);
  assert.equal(report.decision.status, 'pass');
  assert.equal(report.release.proposalOnly, false);
  assert.equal(report.release.tagCreated, true);
  assert.equal(report.release.tagPushed, true);
  assert.equal(report.release.tagPushRemote.remoteName, 'upstream');
  assert.equal(report.release.signingMaterial.backend, 'ssh');
  assert.ok(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'tag'));
  assert.ok(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'push'));
});

test('runReleaseConductor allows apply when queue pause is only an idle success-rate throttle', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: true,
          pausedReasons: ['success-rate-below-threshold'],
          throughputController: { mode: 'stabilize' },
          runtimeFleet: {
            totals: {
              queued: 0,
              inProgress: 0,
              stalled: 0
            }
          },
          queueInventory: {
            mergeQueueOccupancy: 0,
            readyQueuedCount: 0
          },
          summary: {
            quarantinedCount: 0
          },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const commandCalls = [];
  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'git' && args[0] === 'config') {
      if (args[2] === 'user.signingkey') {
        return { status: 0, stdout: '/tmp/release-signing.pub', stderr: '' };
      }
      if (args[2] === 'gpg.format') {
        return { status: 0, stdout: 'ssh', stderr: '' };
      }
      if (args[2] === 'remote.upstream.url') {
        return { status: 0, stdout: 'https://github.com/owner/repo.git', stderr: '' };
      }
      return { status: 1, stdout: '', stderr: 'missing config' };
    }
    if (command === 'git' && args[0] === 'tag') {
      return { status: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'push') {
      return { status: 0, stdout: '', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: true,
      dryRun: false,
      repairExistingTag: false,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'rc',
      version: '0.8.0-rc.1',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '1'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 0);
  assert.equal(report.gates.queueHealth.status, 'pass');
  assert.deepEqual(report.gates.queueHealth.reasons, ['release-safe-idle-queue-pause']);
  assert.equal(report.release.proposalOnly, false);
  assert.ok(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'tag'));
  assert.ok(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'push'));
});

test('runReleaseConductor blocks apply when authoritative tag already exists and repair mode is not requested', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const commandCalls = [];
  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'git' && args[0] === 'config') {
      if (args[2] === 'user.signingkey') {
        return { status: 0, stdout: '/tmp/release-signing.pub', stderr: '' };
      }
      if (args[2] === 'gpg.format') {
        return { status: 0, stdout: 'ssh', stderr: '' };
      }
      if (args[2] === 'remote.upstream.url') {
        return { status: 0, stdout: 'https://github.com/owner/repo.git', stderr: '' };
      }
      return { status: 1, stdout: '', stderr: 'missing config' };
    }
    if (command === 'git' && args[0] === 'ls-remote') {
      return {
        status: 0,
        stdout: [
          '1111111111111111111111111111111111111111\trefs/tags/v0.8.0-rc.1',
          '2222222222222222222222222222222222222222\trefs/tags/v0.8.0-rc.1^{}'
        ].join('\n'),
        stderr: ''
      };
    }
    if (command === 'git' && args[0] === 'rev-parse') {
      return { status: 1, stdout: '', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: true,
      dryRun: false,
      repairExistingTag: false,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'rc',
      version: '0.8.0-rc.1',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '1'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 1);
  assert.equal(report.release.repair.status, 'repair-available');
  assert.equal(report.release.repair.remoteTagExists, true);
  assert.equal(report.release.repair.remoteTargetCommitOid, '2222222222222222222222222222222222222222');
  assert.ok(report.decision.blockers.some((entry) => entry.code === 'existing-tag-requires-repair-mode'));
  assert.equal(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'tag'), false);
});

test('runReleaseConductor reports a repair plan in dry-run for an existing authoritative tag', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const runCommandFn = (command, args) => {
    if (command === 'git' && args[0] === 'config') {
      if (args[2] === 'remote.upstream.url') {
        return { status: 0, stdout: 'https://github.com/owner/repo.git', stderr: '' };
      }
      return { status: 1, stdout: '', stderr: 'missing config' };
    }
    if (command === 'git' && args[0] === 'ls-remote') {
      return {
        status: 0,
        stdout: [
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v0.8.0-rc.1',
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v0.8.0-rc.1^{}'
        ].join('\n'),
        stderr: ''
      };
    }
    if (command === 'git' && args[0] === 'rev-parse') {
      return { status: 0, stdout: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: false,
      dryRun: true,
      repairExistingTag: true,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'rc',
      version: '0.8.0-rc.1',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '0'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 0);
  assert.equal(report.decision.status, 'pass');
  assert.equal(report.release.repair.requested, true);
  assert.equal(report.release.repair.status, 'ready');
  assert.equal(report.release.repair.remoteTagExists, true);
  assert.equal(report.release.repair.remoteTagAnnotated, true);
  assert.equal(report.release.repair.remoteTagObjectOid, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  assert.equal(report.release.repair.remoteTargetCommitOid, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
  assert.equal(report.release.repair.localTagPresent, true);
  assert.equal(report.release.proposalOnly, true);
});

test('runReleaseConductor repairs an existing authoritative tag when repair mode is enabled', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const commandCalls = [];
  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'git' && args[0] === 'config') {
      if (args[2] === 'user.signingkey') {
        return { status: 0, stdout: '/tmp/release-signing.pub', stderr: '' };
      }
      if (args[2] === 'gpg.format') {
        return { status: 0, stdout: 'ssh', stderr: '' };
      }
      if (args[2] === 'remote.upstream.url') {
        return { status: 0, stdout: 'https://github.com/owner/repo.git', stderr: '' };
      }
      return { status: 1, stdout: '', stderr: 'missing config' };
    }
    if (command === 'git' && args[0] === 'ls-remote') {
      return {
        status: 0,
        stdout: [
          '1111111111111111111111111111111111111111\trefs/tags/v0.8.0-rc.1',
          '2222222222222222222222222222222222222222\trefs/tags/v0.8.0-rc.1^{}'
        ].join('\n'),
        stderr: ''
      };
    }
    if (command === 'git' && args[0] === 'rev-parse') {
      return { status: 0, stdout: '1111111111111111111111111111111111111111\n', stderr: '' };
    }
    if (command === 'git' && args[0] === 'tag' && args[1] === '-d') {
      return { status: 0, stdout: `Deleted tag '${args[2]}'`, stderr: '' };
    }
    if (command === 'git' && args[0] === 'tag') {
      return { status: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'push') {
      return { status: 0, stdout: '', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: true,
      dryRun: false,
      repairExistingTag: true,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'rc',
      version: '0.8.0-rc.1',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '1'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 0);
  assert.equal(report.decision.status, 'pass');
  assert.equal(report.release.proposalOnly, false);
  assert.equal(report.release.tagCreated, true);
  assert.equal(report.release.tagPushed, true);
  assert.equal(report.release.repair.status, 'repaired');
  assert.equal(report.release.repair.localTagDeleted, true);
  assert.equal(report.release.repair.tagRecreated, true);
  assert.equal(
    commandCalls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'push' &&
        entry.args[1] === '--force-with-lease=refs/tags/v0.8.0-rc.1:1111111111111111111111111111111111111111'
    ),
    true
  );
  assert.equal(
    commandCalls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'tag' &&
        entry.args[1] === '-s' &&
        entry.args[2] === '-f' &&
        entry.args[3] === 'v0.8.0-rc.1' &&
        entry.args[4] === '2222222222222222222222222222222222222222'
    ),
    true
  );
});

test('runReleaseConductor fails apply when signed tag push remote is unavailable', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const commandCalls = [];
  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'git' && args[0] === 'config') {
      if (args[2] === 'user.signingkey') {
        return { status: 0, stdout: '/tmp/release-signing.pub', stderr: '' };
      }
      if (args[2] === 'gpg.format') {
        return { status: 0, stdout: 'ssh', stderr: '' };
      }
      return { status: 1, stdout: '', stderr: 'missing config' };
    }
    if (command === 'git' && args[0] === 'tag') {
      return { status: 0, stdout: '', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'stable',
      version: '0.8.0',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '1'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 1);
  assert.equal(report.decision.status, 'fail');
  assert.equal(report.release.tagCreated, true);
  assert.equal(report.release.tagPushed, false);
  assert.equal(report.release.tagPushRemote.remoteName, null);
  assert.ok(report.decision.blockers.some((entry) => entry.code === 'tag-push-remote-missing'));
  assert.equal(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'push'), false);
});

test('runReleaseConductor blocks apply when signing material is unavailable', async () => {
  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] === 'api') {
      return makeWorkflowRunsResponse(String(args[1]));
    }
    throw new Error(`unexpected gh args: ${args.join(' ')}`);
  };

  const commandCalls = [];
  const runCommandFn = (command, args) => {
    commandCalls.push({ command, args });
    if (command === 'git' && args[0] === 'config') {
      return { status: 1, stdout: '', stderr: 'missing signing key' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const { report, exitCode } = await runReleaseConductor({
    repoRoot: process.cwd(),
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'stable',
      version: '0.8.0',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '1'
    },
    runGhJsonFn,
    runCommandFn,
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 1);
  assert.equal(report.decision.status, 'fail');
  assert.equal(report.release.proposalOnly, true);
  assert.equal(report.release.tagCreated, false);
  assert.equal(report.release.signingMaterial.available, false);
  assert.ok(report.decision.blockers.some((entry) => entry.code === 'tag-signing-material-missing'));
  assert.equal(commandCalls.some((entry) => entry.command === 'git' && entry.args[0] === 'tag'), false);
});

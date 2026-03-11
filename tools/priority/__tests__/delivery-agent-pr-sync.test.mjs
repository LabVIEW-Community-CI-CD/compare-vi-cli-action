#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, rm } from 'node:fs/promises';

import {
  classifyPullRequestWork,
  planDeliveryBrokerAction,
  runDeliveryTurnBroker
} from '../delivery-agent.mjs';

test('classifyPullRequestWork prioritizes branch sync before draft review when a PR is behind', () => {
  const result = classifyPullRequestWork({
    isDraft: true,
    mergeStateStatus: 'BEHIND',
    mergeable: 'MERGEABLE',
    reviewDecision: 'REVIEW_REQUIRED',
    statusCheckRollup: []
  });

  assert.equal(result.laneLifecycle, 'waiting-ci');
  assert.equal(result.blockerClass, 'ci');
  assert.equal(result.syncRequired, true);
  assert.equal(result.nextWakeCondition, 'branch-synced');
});

test('planDeliveryBrokerAction chooses sync-pr-branch before watch-pr for behind PRs', () => {
  const planned = planDeliveryBrokerAction({
    status: 'waiting-review',
    evidence: {
      delivery: {
        laneLifecycle: 'waiting-review',
        pullRequest: {
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017',
          number: 1017,
          mergeStateStatus: 'BEHIND',
          syncRequired: true,
          checks: {
            blockerClass: 'ci'
          }
        }
      }
    }
  });

  assert.deepEqual(planned, {
    actionType: 'sync-pr-branch',
    laneLifecycle: 'waiting-ci'
  });
});

test('runDeliveryTurnBroker updates a behind PR branch before waiting on review', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-pr-sync-'));
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      objective: {
        summary: 'Advance issue #959'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1017,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017',
            mergeStateStatus: 'BEHIND',
            syncRequired: true,
            checks: {
              blockerClass: 'ci'
            }
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      updatePullRequestBranchFn: async () => ({
        status: 'completed',
        outcome: 'branch-updated',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'sync-pr-branch',
          laneLifecycle: 'waiting-ci',
          blockerClass: 'ci',
          retryable: true,
          nextWakeCondition: 'checks-green',
          helperCallsExecuted: ['gh pr update-branch'],
          filesTouched: []
        }
      })
    }
  });

  assert.equal(brokerResult.outcome, 'branch-updated');
  assert.equal(brokerResult.details.actionType, 'sync-pr-branch');
  assert.equal(brokerResult.details.nextWakeCondition, 'checks-green');
});

test('runDeliveryTurnBroker falls back to local git sync when gh pr update-branch fails', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-pr-sync-fallback-'));
  const executionRoot = path.join(repoRoot, 'worker');
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const commandLog = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      branch: {
        name: 'issue/origin-959-codex-pressure-governor'
      },
      objective: {
        summary: 'Advance issue #959'
      },
      evidence: {
        lane: {
          workerCheckoutPath: executionRoot
        },
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1017,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017',
            headRefName: 'issue/origin-959-codex-pressure-governor',
            baseRefName: 'develop',
            mergeStateStatus: 'BEHIND',
            syncRequired: true,
            checks: {
              blockerClass: 'ci'
            }
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      runCommandFn: async (command, args, options) => {
        commandLog.push({ command, args, cwd: options?.cwd || '' });
        if (command === 'gh' && args[0] === 'pr' && args[1] === 'update-branch') {
          return {
            status: 1,
            stdout: '',
            stderr: 'GraphQL: Something went wrong while executing your query.'
          };
        }
        if (command === 'git' && args[0] === 'status') {
          return {
            status: 0,
            stdout: '',
            stderr: ''
          };
        }
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'branch-updated');
  assert.deepEqual(brokerResult.details.helperCallsExecuted, [
    'gh pr update-branch',
    'git fetch upstream develop',
    'git fetch origin issue/origin-959-codex-pressure-governor',
    'git checkout issue/origin-959-codex-pressure-governor',
    'git rebase upstream/develop',
    'git push --force-with-lease origin HEAD:issue/origin-959-codex-pressure-governor'
  ]);
  assert.deepEqual(commandLog, [
    {
      command: 'gh',
      args: ['pr', 'update-branch', '1017', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action'],
      cwd: executionRoot
    },
    {
      command: 'git',
      args: ['status', '--porcelain'],
      cwd: executionRoot
    },
    {
      command: 'git',
      args: ['fetch', 'upstream', 'develop'],
      cwd: executionRoot
    },
    {
      command: 'git',
      args: ['fetch', 'origin', 'issue/origin-959-codex-pressure-governor'],
      cwd: executionRoot
    },
    {
      command: 'git',
      args: ['checkout', 'issue/origin-959-codex-pressure-governor'],
      cwd: executionRoot
    },
    {
      command: 'git',
      args: ['rebase', 'upstream/develop'],
      cwd: executionRoot
    },
    {
      command: 'git',
      args: ['push', '--force-with-lease', 'origin', 'HEAD:issue/origin-959-codex-pressure-governor'],
      cwd: executionRoot
    }
  ]);
});

test('runDeliveryTurnBroker aborts a conflicted rebase when local branch sync cannot complete linearly', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-pr-sync-rebase-conflict-'));
  const executionRoot = path.join(repoRoot, 'worker');
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const commandLog = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      branch: {
        name: 'issue/origin-959-codex-pressure-governor'
      },
      objective: {
        summary: 'Advance issue #959'
      },
      evidence: {
        lane: {
          workerCheckoutPath: executionRoot
        },
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1017,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017',
            headRefName: 'issue/origin-959-codex-pressure-governor',
            baseRefName: 'develop',
            mergeStateStatus: 'BEHIND',
            syncRequired: true,
            checks: {
              blockerClass: 'ci'
            }
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      runCommandFn: async (command, args, options) => {
        commandLog.push({ command, args, cwd: options?.cwd || '' });
        if (command === 'gh' && args[0] === 'pr' && args[1] === 'update-branch') {
          return {
            status: 1,
            stdout: '',
            stderr: 'GraphQL: Something went wrong while executing your query.'
          };
        }
        if (command === 'git' && args[0] === 'status') {
          return {
            status: 0,
            stdout: '',
            stderr: ''
          };
        }
        if (command === 'git' && args[0] === 'rebase' && args[1] === 'upstream/develop') {
          return {
            status: 1,
            stdout: '',
            stderr: 'CONFLICT (content): could not apply deadbeef...'
          };
        }
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'branch-sync-blocked');
  assert.equal(brokerResult.details.blockerClass, 'merge');
  assert.equal(brokerResult.details.retryable, false);
  assert.deepEqual(brokerResult.details.helperCallsExecuted, [
    'gh pr update-branch',
    'git fetch upstream develop',
    'git fetch origin issue/origin-959-codex-pressure-governor',
    'git checkout issue/origin-959-codex-pressure-governor',
    'git rebase upstream/develop',
    'git rebase --abort'
  ]);
  assert.ok(
    commandLog.some(
      (entry) => entry.command === 'git' && entry.args[0] === 'rebase' && entry.args[1] === '--abort' && entry.cwd === executionRoot
    )
  );
});

test('runDeliveryTurnBroker surfaces upstream fetch failures from the local branch-sync fallback', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-pr-sync-upstream-fetch-fail-'));
  const executionRoot = path.join(repoRoot, 'worker');
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      branch: {
        name: 'issue/origin-959-codex-pressure-governor'
      },
      evidence: {
        lane: {
          workerCheckoutPath: executionRoot
        },
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1017,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017',
            headRefName: 'issue/origin-959-codex-pressure-governor',
            baseRefName: 'develop',
            mergeStateStatus: 'BEHIND',
            syncRequired: true,
            checks: {
              blockerClass: 'ci'
            }
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      runCommandFn: async (command, args) => {
        if (command === 'gh' && args[0] === 'pr' && args[1] === 'update-branch') {
          return { status: 1, stdout: '', stderr: 'GraphQL: Something went wrong while executing your query.' };
        }
        if (command === 'git' && args[0] === 'status') {
          return { status: 0, stdout: '', stderr: '' };
        }
        if (command === 'git' && args[0] === 'fetch' && args[1] === 'upstream') {
          return { status: 1, stdout: '', stderr: 'fatal: could not read from remote repository' };
        }
        return { status: 0, stdout: '', stderr: '' };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'branch-sync-failed');
  assert.match(brokerResult.reason, /could not read from remote repository/i);
  assert.deepEqual(brokerResult.details.helperCallsExecuted, ['gh pr update-branch', 'git fetch upstream develop']);
});

test('runDeliveryTurnBroker surfaces checkout failures from the local branch-sync fallback', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-pr-sync-checkout-fail-'));
  const executionRoot = path.join(repoRoot, 'worker');
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      branch: {
        name: 'issue/origin-959-codex-pressure-governor'
      },
      evidence: {
        lane: {
          workerCheckoutPath: executionRoot
        },
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1017,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017',
            headRefName: 'issue/origin-959-codex-pressure-governor',
            baseRefName: 'develop',
            mergeStateStatus: 'BEHIND',
            syncRequired: true,
            checks: {
              blockerClass: 'ci'
            }
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      runCommandFn: async (command, args) => {
        if (command === 'gh' && args[0] === 'pr' && args[1] === 'update-branch') {
          return { status: 1, stdout: '', stderr: 'GraphQL: Something went wrong while executing your query.' };
        }
        if (command === 'git' && args[0] === 'status') {
          return { status: 0, stdout: '', stderr: '' };
        }
        if (command === 'git' && args[0] === 'checkout') {
          return { status: 1, stdout: '', stderr: 'error: pathspec did not match any file(s) known to git' };
        }
        return { status: 0, stdout: '', stderr: '' };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'branch-sync-failed');
  assert.match(brokerResult.reason, /pathspec did not match/i);
  assert.deepEqual(brokerResult.details.helperCallsExecuted, [
    'gh pr update-branch',
    'git fetch upstream develop',
    'git fetch origin issue/origin-959-codex-pressure-governor',
    'git checkout issue/origin-959-codex-pressure-governor'
  ]);
});

test('runDeliveryTurnBroker executes coding commands in the worker checkout instead of the control root', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-coding-root-'));
  const executionRoot = path.join(repoRoot, 'worker');
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const calls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacketPath: path.join(repoRoot, 'task-packet.json'),
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #959'
      },
      evidence: {
        lane: {
          workerCheckoutPath: executionRoot
        },
        delivery: {
          laneLifecycle: 'coding'
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: ['node', 'mock-coding-turn']
      }),
      runCommandFn: async (command, args, options) => {
        calls.push({ command, args, cwd: options?.cwd || '', env: options?.env || {} });
        return {
          status: 0,
          stdout: JSON.stringify({
            status: 'completed',
            outcome: 'coding-command-finished',
            source: 'delivery-agent-broker',
            details: {
              actionType: 'execute-coding-turn',
              laneLifecycle: 'coding',
              blockerClass: 'none',
              retryable: true,
              nextWakeCondition: 'scheduler-rescan',
              helperCallsExecuted: [],
              filesTouched: []
            }
          }),
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'coding-command-finished');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cwd, executionRoot);
  assert.equal(calls[0].env.COMPAREVI_DELIVERY_REPO_ROOT, executionRoot);
  assert.equal(calls[0].env.COMPAREVI_DELIVERY_CONTROL_ROOT, repoRoot);
});

test('runDeliveryTurnBroker keeps priority sync stdout chatter out of merge receipts', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-merge-sync-stdout-'));
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const commandLog = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #959'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          selectedIssue: {
            number: 959,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/959'
          },
          standingIssue: {
            number: 959,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/959'
          },
          pullRequest: {
            number: 1017,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017',
            readyToMerge: true
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      listOpenIssuesFn: async () => [],
      runCommandFn: async (command, args, options) => {
        commandLog.push({ command, args, cwd: options?.cwd || '' });
        if (command === 'node' && args[0] === 'tools/priority/merge-sync-pr.mjs') {
          return {
            status: 0,
            stdout: '[priority:merge-sync] selected mode=auto\n',
            stderr: ''
          };
        }
        if (command === 'node' && args[0] === 'tools/priority/sync-standing-priority.mjs') {
          return {
            status: 0,
            stdout: '[priority] Standing issue: #960\n',
            stderr: ''
          };
        }
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'merged');
  assert.equal(brokerResult.details.finalizedIssueNumber, 959);
  assert.deepEqual(brokerResult.details.helperCallsExecuted, [
    'node tools/priority/merge-sync-pr.mjs',
    'gh issue edit 959 --remove-label standing-priority',
    'node tools/priority/sync-standing-priority.mjs',
    'gh issue close 959'
  ]);
  assert.deepEqual(commandLog, [
    {
      command: 'node',
      args: ['tools/priority/merge-sync-pr.mjs', '--pr', '1017', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action'],
      cwd: repoRoot
    },
    {
      command: 'gh',
      args: ['issue', 'edit', '959', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action', '--remove-label', 'standing-priority'],
      cwd: repoRoot
    },
    {
      command: 'node',
      args: ['tools/priority/sync-standing-priority.mjs'],
      cwd: repoRoot
    },
    {
      command: 'gh',
      args: [
        'issue',
        'close',
        '959',
        '--repo',
        'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        '--comment',
        'Completed by PR #1017 (https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1017). No next standing-priority issue is currently labeled, so the queue is now idle until a new issue is promoted.'
      ],
      cwd: repoRoot
    }
  ]);
});

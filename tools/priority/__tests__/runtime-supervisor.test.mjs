#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { compareviRuntimeTest, parseArgs, runRuntimeSupervisor } from '../runtime-supervisor.mjs';
import { buildCanonicalDeliveryDecision, fetchIssueExecutionGraph, runDeliveryTurnBroker } from '../delivery-agent.mjs';

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

async function readNdjson(filePath) {
  const raw = await readFile(filePath, 'utf8');
  return raw
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function makeLeaseDeps() {
  const calls = [];
  return {
    calls,
    acquireWriterLeaseFn: async (options) => {
      calls.push({ type: 'acquire', options });
      return {
        action: 'acquire',
        status: 'acquired',
        scope: options.scope,
        owner: options.owner,
        checkedAt: '2026-03-10T00:00:00.000Z',
        lease: {
          leaseId: 'lease-1',
          owner: options.owner
        }
      };
    },
    releaseWriterLeaseFn: async (options) => {
      calls.push({ type: 'release', options });
      return {
        action: 'release',
        status: 'released',
        scope: options.scope,
        owner: options.owner,
        checkedAt: '2026-03-10T00:00:05.000Z',
        lease: {
          leaseId: options.leaseId,
          owner: options.owner
        }
      };
    }
  };
}

test('parseArgs accepts runtime action, lane metadata, and lease options', () => {
  const parsed = parseArgs([
    'node',
    'runtime-supervisor.mjs',
    '--action',
    'step',
    '--repo',
    'example/repo',
    '--runtime-dir',
    'custom-runtime',
    '--lane',
    'origin-977',
    '--issue',
    '977',
    '--epic',
    '967',
    '--fork-remote',
    'origin',
    '--branch',
    'issue/origin-977-fork-policy-portability',
    '--pr-url',
    'https://example.test/pr/7',
    '--blocker-class',
    'ci',
    '--reason',
    'hosted checks are red',
    '--lease-scope',
    'workspace',
    '--lease-root',
    '.tmp/leases',
    '--owner',
    'agent@example'
  ]);

  assert.equal(parsed.action, 'step');
  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.runtimeDir, 'custom-runtime');
  assert.equal(parsed.lane, 'origin-977');
  assert.equal(parsed.issue, 977);
  assert.equal(parsed.epic, 967);
  assert.equal(parsed.forkRemote, 'origin');
  assert.equal(parsed.branch, 'issue/origin-977-fork-policy-portability');
  assert.equal(parsed.prUrl, 'https://example.test/pr/7');
  assert.equal(parsed.blockerClass, 'ci');
  assert.equal(parsed.reason, 'hosted checks are red');
  assert.equal(parsed.leaseScope, 'workspace');
  assert.equal(parsed.leaseRoot, '.tmp/leases');
  assert.equal(parsed.owner, 'agent@example');
});

test('comparevi branch resolver matches the repo issue branch naming contract', () => {
  const branch = compareviRuntimeTest.resolveCompareviIssueBranchName({
    issueNumber: 998,
    title: 'Attach ready worker checkouts onto deterministic lane branches',
    forkRemote: 'personal'
  });

  assert.equal(branch, 'issue/personal-998-attach-ready-worker-checkouts-onto-deterministic-lane-branches');
});

test('runRuntimeSupervisor step writes runtime state, lane, turn, event, and blocker artifacts', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-supervisor-'));
  const runtimeDir = 'tests/results/_agent/runtime';
  const deps = makeLeaseDeps();
  const result = await runRuntimeSupervisor(
    {
      action: 'step',
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-977',
      issue: 977,
      epic: 967,
      forkRemote: 'origin',
      branch: 'issue/origin-977-fork-policy-portability',
      prUrl: 'https://example.test/pr/7',
      blockerClass: 'ci',
      reason: 'hosted checks are red',
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T12:00:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );

  const runtimeRoot = path.join(repoRoot, runtimeDir);
  const state = await readJson(path.join(runtimeRoot, 'runtime-state.json'));
  const lane = await readJson(path.join(runtimeRoot, 'lanes', 'origin-977.json'));
  const blocker = await readJson(path.join(runtimeRoot, 'last-blocker.json'));
  const events = await readNdjson(path.join(runtimeRoot, 'runtime-events.ndjson'));
  const turnsDir = path.join(runtimeRoot, 'turns');
  const turnStats = await stat(result.report.turnPath);
  const turn = await readJson(result.report.turnPath);

  assert.equal(result.exitCode, 0);
  assert.equal(state.schema, 'priority/runtime-supervisor-state@v1');
  assert.equal(state.lifecycle.status, 'running');
  assert.equal(state.lifecycle.cycle, 1);
  assert.equal(state.lifecycle.stopRequested, false);
  assert.equal(state.activeLane.laneId, 'origin-977');
  assert.equal(state.summary.trackedLaneCount, 1);
  assert.equal(lane.issue, 977);
  assert.equal(lane.epic, 967);
  assert.equal(lane.blocker.blockerClass, 'ci');
  assert.equal(blocker.issue, 977);
  assert.equal(blocker.blockerClass, 'ci');
  assert.equal(events.length, 1);
  assert.equal(events[0].outcome, 'lane-tracked');
  assert.equal(turn.schema, 'priority/runtime-turn@v1');
  assert.equal(turn.outcome, 'lane-tracked');
  assert.equal(turn.activeLane.issue, 977);
  assert.ok(turnStats.isFile());
  assert.match(turnsDir, /turns$/);
  assert.deepEqual(
    deps.calls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});

test('stop, step with stop request, and resume manage runtime control state deterministically', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-supervisor-stop-'));
  const runtimeDir = 'tests/results/_agent/runtime';
  const deps = makeLeaseDeps();

  const stopResult = await runRuntimeSupervisor(
    {
      action: 'stop',
      repo: 'example/repo',
      runtimeDir,
      reason: 'operator pause',
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T13:00:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );
  assert.equal(stopResult.exitCode, 0);

  const pausedStep = await runRuntimeSupervisor(
    {
      action: 'step',
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-978',
      issue: 978,
      forkRemote: 'personal',
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T13:05:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );
  assert.equal(pausedStep.exitCode, 0);
  assert.equal(pausedStep.report.outcome, 'stop-requested');

  const resumeResult = await runRuntimeSupervisor(
    {
      action: 'resume',
      repo: 'example/repo',
      runtimeDir,
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T13:10:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );
  assert.equal(resumeResult.exitCode, 0);

  const runtimeRoot = path.join(repoRoot, runtimeDir);
  const state = await readJson(path.join(runtimeRoot, 'runtime-state.json'));
  const events = await readNdjson(path.join(runtimeRoot, 'runtime-events.ndjson'));

  assert.equal(state.lifecycle.stopRequested, false);
  assert.equal(state.lifecycle.status, 'idle');
  assert.equal(events.map((entry) => entry.action).join(','), 'stop,step,resume');
  assert.equal(events[1].outcome, 'stop-requested');
});

test('canonical delivery scheduler ranks existing PR unblock before ready child issues and backlog repair', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-scheduler-'));
  const decision = await buildCanonicalDeliveryDecision({
    repoRoot,
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    targetRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueSnapshot: {
      number: 1010,
      title: 'Epic: Linux-first unattended delivery runtime',
      body: 'epic body',
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    issueGraph: {
      standingIssue: {
        number: 1010,
        title: 'Epic: Linux-first unattended delivery runtime',
        body: 'epic body',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010',
        state: 'OPEN',
        labels: [],
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        createdAt: '2026-03-10T00:00:00Z',
        updatedAt: '2026-03-10T00:00:00Z',
        priority: 1,
        epic: true,
        pullRequests: []
      },
      subIssues: [
        {
          number: 1012,
          title: '[P1] Wire canonical delivery broker',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1012',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 88,
              title: 'Broker wiring',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: 'APPROVED',
              mergeStateStatus: 'CLEAN',
              mergeable: 'MERGEABLE',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        },
        {
          number: 1013,
          title: '[P1] Add overnight manager aliases',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1013',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-09T00:00:00Z',
          updatedAt: '2026-03-09T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: []
        }
      ],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    }
  });

  assert.equal(decision.stepOptions.issue, 1012);
  assert.equal(decision.stepOptions.epic, 1010);
  assert.equal(decision.stepOptions.forkRemote, 'origin');
  assert.equal(decision.stepOptions.prUrl, 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88');
  assert.equal(decision.artifacts.selectedActionType, 'existing-pr-unblock');
  assert.equal(decision.artifacts.laneLifecycle, 'ready-merge');
});

test('fetchIssueExecutionGraph normalizes status rollup contexts from GraphQL payloads', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-graph-'));
  const graph = await fetchIssueExecutionGraph({
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber: 1010,
    deps: {
      runGhGraphqlFn: () => ({
        data: {
          repository: {
            issue: {
              number: 1010,
              title: 'Containerize NILinuxCompare tests via tools image Docker contract',
              body: 'issue body',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010',
              state: 'OPEN',
              createdAt: '2026-03-10T00:00:00Z',
              updatedAt: '2026-03-10T00:00:00Z',
              labels: { nodes: [{ name: 'standing-priority' }] },
              subIssues: {
                totalCount: 0,
                nodes: []
              },
              timelineItems: {
                nodes: [
                  {
                    source: {
                      __typename: 'PullRequest',
                      number: 88,
                      title: 'Containerize NILinuxCompare tests',
                      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88',
                      state: 'OPEN',
                      isDraft: false,
                      reviewDecision: 'APPROVED',
                      mergeStateStatus: 'CLEAN',
                      mergeable: 'MERGEABLE',
                      statusCheckRollup: {
                        contexts: {
                          nodes: [
                            {
                              __typename: 'CheckRun',
                              name: 'lint',
                              status: 'COMPLETED',
                              conclusion: 'SUCCESS',
                              detailsUrl: 'https://example.test/lint'
                            },
                            {
                              __typename: 'StatusContext',
                              context: 'fixtures',
                              state: 'SUCCESS',
                              targetUrl: 'https://example.test/fixtures'
                            }
                          ]
                        }
                      }
                    }
                  }
                ]
              }
            }
          }
        }
      })
    }
  });

  assert.equal(graph.pullRequests.length, 1);
  assert.deepEqual(
    graph.pullRequests[0].statusCheckRollup.map((entry) => ({
      name: entry.name,
      status: entry.status,
      conclusion: entry.conclusion
    })),
    [
      { name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { name: 'fixtures', status: 'SUCCESS', conclusion: 'SUCCESS' }
    ]
  );
});

test('canonical delivery scheduler falls back to backlog repair when an epic has no open child slices', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-backlog-'));
  const decision = await buildCanonicalDeliveryDecision({
    repoRoot,
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    targetRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueSnapshot: {
      number: 1010,
      title: 'Epic: Linux-first unattended delivery runtime',
      body: 'epic body',
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    issueGraph: {
      standingIssue: {
        number: 1010,
        title: 'Epic: Linux-first unattended delivery runtime',
        body: 'epic body',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010',
        state: 'OPEN',
        labels: [],
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        createdAt: '2026-03-10T00:00:00Z',
        updatedAt: '2026-03-10T00:00:00Z',
        priority: 1,
        epic: true,
        pullRequests: []
      },
      subIssues: [],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    }
  });

  assert.equal(decision.stepOptions.issue, 1010);
  assert.equal(decision.artifacts.selectedActionType, 'reshape-backlog');
  assert.equal(decision.artifacts.laneLifecycle, 'reshaping-backlog');
  assert.equal(decision.artifacts.backlogRepair.mode, 'repair-child-slice');
});

test('comparevi canonical execution delegates to the delivery broker instead of returning execution-noop', async () => {
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot: '/tmp/repo',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-1012',
        issue: 1012,
        forkRemote: 'origin',
        branch: 'issue/origin-1012-wire-canonical-delivery-broker'
      },
      artifacts: {
        standingRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        standingIssueNumber: 1010,
        laneLifecycle: 'coding',
        selectedActionType: 'advance-child-issue'
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: { summary: 'Advance issue #1012' },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          selectedActionType: 'advance-child-issue',
          mutationEnvelope: {
            maxActiveCodingLanes: 1
          },
          turnBudget: {
            maxMinutes: 20,
            maxToolCalls: 12
          }
        }
      }
    },
    taskPacketArtifacts: {
      latestPath: '/tmp/repo/tests/results/_agent/runtime/task-packet.json'
    },
    runtimeArtifactPaths: {
      runtimeDir: '/tmp/repo/tests/results/_agent/runtime'
    },
    deps: {
      invokeDeliveryTurnBrokerFn: async () => ({
        status: 'completed',
        outcome: 'coding-command-finished',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'coding',
          blockerClass: 'none',
          retryable: true,
          nextWakeCondition: 'scheduler-rescan'
        }
      })
    }
  });

  assert.equal(execution.outcome, 'coding-command-finished');
  assert.equal(execution.source, 'delivery-agent-broker');
  assert.equal(execution.details.actionType, 'execute-coding-turn');
});

test('comparevi canonical execution consumes the broker receipt file when stdout includes helper chatter', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-broker-receipt-'));
  const runtimeDir = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime');
  await mkdir(runtimeDir, { recursive: true });

  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-962',
        issue: 962,
        forkRemote: 'origin',
        branch: 'issue/origin-962-github-metadata-apply-tolerate-bot-review-requests-in-pr-reviewer-state'
      },
      artifacts: {
        standingRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        standingIssueNumber: 962,
        laneLifecycle: 'ready-merge',
        selectedActionType: 'merge-pr'
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: { summary: 'Advance issue #962' },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          selectedActionType: 'merge-pr'
        }
      }
    },
    taskPacketArtifacts: {
      latestPath: path.join(runtimeDir, 'task-packet.json')
    },
    runtimeArtifactPaths: {
      runtimeDir
    },
    deps: {
      execFileFn: async (_command, args) => {
        const receiptPath = args[args.indexOf('--receipt-out') + 1];
        assert.equal(path.basename(receiptPath), 'broker-execution-receipt.json');
        await writeFile(
          receiptPath,
          `${JSON.stringify(
            {
              status: 'completed',
              outcome: 'merged',
              reason: 'Merged PR #1018 and closed issue #962.',
              source: 'delivery-agent-broker',
              details: {
                actionType: 'merge-pr',
                laneLifecycle: 'complete',
                blockerClass: 'none',
                retryable: false,
                nextWakeCondition: 'next-scheduler-cycle',
                helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs', 'gh issue close 962'],
                filesTouched: [],
                finalizedIssueNumber: 962
              }
            },
            null,
            2
          )}\n`,
          'utf8'
        );
        return {
          stdout: '[priority] Standing issue: #963\n{\n  "ignored": true\n}\n'
        };
      }
    }
  });

  assert.equal(execution.outcome, 'merged');
  assert.equal(execution.reason, 'Merged PR #1018 and closed issue #962.');
  assert.equal(execution.details.actionType, 'merge-pr');
  assert.equal(execution.details.finalizedIssueNumber, 962);
});

test('delivery broker auto-slices epics by creating and linking a child issue', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'reshaping-backlog',
      objective: {
        summary: 'Reshape epic #1010'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'reshaping-backlog',
          backlog: {
            mode: 'repair-child-slice'
          },
          standingIssue: {
            number: 1010,
            title: 'Epic: Linux-first unattended delivery runtime',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
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
      autoSliceIssueFn: async () => ({
        status: 'completed',
        outcome: 'child-issue-created',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'create-child-issue',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          childIssue: {
            number: 1015
          }
        }
      })
    }
  });

  assert.equal(brokerResult.outcome, 'child-issue-created');
  assert.equal(brokerResult.details.actionType, 'create-child-issue');
  assert.equal(brokerResult.details.childIssue.number, 1015);
});

test('delivery broker classifies rate-limit failures with a retryable blocker', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #1012'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          mutationEnvelope: {
            maxActiveCodingLanes: 1
          },
          turnBudget: {
            maxMinutes: 20,
            maxToolCalls: 12
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
        codingTurnCommand: ['node', 'mock-broker']
      }),
      invokeCodingTurnFn: async () => ({
        status: 'blocked',
        outcome: 'rate-limit',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'blocked',
          blockerClass: 'rate-limit',
          retryable: true,
          nextWakeCondition: 'github-rate-limit-reset'
        }
      })
    }
  });

  assert.equal(brokerResult.outcome, 'rate-limit');
  assert.equal(brokerResult.details.blockerClass, 'rate-limit');
  assert.equal(brokerResult.details.retryable, true);
});

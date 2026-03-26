#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compareviRuntimeTest, parseArgs, runRuntimeSupervisor } from '../runtime-supervisor.mjs';
import {
  buildCanonicalDeliveryDecision,
  buildLocalReviewLoopRequest,
  classifyPullRequestWork,
  fetchIssueExecutionGraph,
  planDeliveryBrokerAction,
  persistDeliveryAgentRuntimeState,
  runDeliveryTurnBroker
} from '../delivery-agent.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

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

function runGit(repoPath, args, env = process.env) {
  const result = spawnSync('git', ['-C', repoPath, ...args], {
    encoding: 'utf8',
    env,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  assert.equal(result.status, 0, result.stderr || result.stdout || `git ${args.join(' ')} failed`);
  return result.stdout.trim();
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

function makeLaneBranchClassContract() {
  return {
    schema: 'branch-classes/v1',
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    repositoryPlanes: [
      {
        id: 'upstream',
        repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
        laneBranchPrefix: 'issue/'
      },
      {
        id: 'origin',
        repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
        laneBranchPrefix: 'issue/origin-'
      },
      {
        id: 'personal',
        repositories: ['svelderrainruiz/compare-vi-cli-action'],
        laneBranchPrefix: 'issue/personal-'
      }
    ],
    classes: [
      {
        id: 'lane',
        repositoryRoles: ['upstream', 'fork'],
        branchPatterns: ['issue/*'],
        purpose: 'lane',
        prSourceAllowed: true,
        prTargetAllowed: false,
        mergePolicy: 'n/a'
      }
    ],
    allowedTransitions: [
      {
        from: 'lane',
        action: 'promote',
        to: 'upstream-integration',
        via: 'pull-request'
      }
    ]
  };
}

function createMonitoringEntrypoints({
  comparePath = 'E:\\comparevi-lanes\\compare-monitoring-canonical',
  templatePath = 'E:\\comparevi-lanes\\LabviewGitHubCiTemplate-monitoring-canonical',
  historyPath = 'E:\\comparevi-lanes\\comparevi-history-monitoring-canonical'
} = {}) {
  return {
    schema: 'local/monitoring-entrypoints-v1',
    generatedAt: '2026-03-23T04:30:00.000Z',
    compare: {
      authoritative: true,
      path: comparePath,
      checkoutState: 'branch-monitoring/upstream-develop',
      headSha: 'e0acdbfd445cafcc7257a2b740fdb4cce4da12bb',
      receipts: {
        queueEmpty: `${comparePath}\\tests\\results\\_agent\\issue\\no-standing-priority.json`
      },
      currentState: {
        standingQueue: 'queue-empty',
        continuity: 'maintained',
        turnBoundary: 'safe-idle',
        monitoringMode: 'active',
        futureAgentAction: 'future-agent-may-pivot'
      }
    },
    template: {
      authoritative: true,
      path: templatePath,
      checkoutState: 'branch-monitoring/origin-develop',
      headSha: '7c09c6fc989a25d79b9ae73135aa2403f77d6df6',
      currentState: {
        canonicalOpenIssues: 0,
        orgForkOpenIssues: 0,
        personalForkOpenIssues: 0
      },
      supportedProofRuns: {
        orgFork: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23405232217',
        personalFork: 'https://github.com/svelderrainruiz/LabviewGitHubCiTemplate/actions/runs/23405232554'
      }
    },
    history: {
      authoritative: true,
      path: historyPath,
      checkoutState: 'branch-monitoring/upstream-develop',
      headSha: '9be0b25c4a5d4fd49b7576f2f4dfca53a5d7f4c9',
      receipts: {
        standingQueue: `${historyPath}\\tests\\results\\_agent\\issue\\standing-priority.json`
      },
      currentState: {
        standingQueue: 'standing-open',
        continuity: 'maintained'
      }
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

test('buildCompareviTaskPacket carries a daemon-requested Docker/Desktop review loop from standing issue metadata', async () => {
  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot,
    schedulerDecision: {
      activeLane: {
        issue: 1053,
        branch: 'issue/origin-1053-daemon-docker-desktop-review-loop',
        forkRemote: 'origin'
      },
      artifacts: {
        executionMode: 'canonical-delivery',
        selectedActionType: 'advance-child-issue',
        laneLifecycle: 'coding',
        selectedIssueSnapshot: {
          number: 1053,
          title: 'CI: extend Docker Desktop parity to NI Linux smoke and VI history suite generation',
          body: [
            '## Daemon-first local iteration extension',
            '- markdownlint',
            '- requirements verification',
            '- NI Linux review suite',
            '- single-VI touch-aware history on develop'
          ].join('\n'),
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
        },
        standingIssueSnapshot: {
          number: 1053,
          title: 'CI: extend Docker Desktop parity to NI Linux smoke and VI history suite generation',
          body: [
            '## Daemon-first local iteration extension',
            '- markdownlint',
            '- requirements verification',
            '- NI Linux review suite',
            '- single-VI touch-aware history on develop'
          ].join('\n'),
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
        }
      }
    },
    preparedWorker: {
      checkoutPath: '/tmp/worker'
    },
    workerReady: {
      checkoutPath: '/tmp/worker'
    },
    workerBranch: {
      branch: 'issue/origin-1053-daemon-docker-desktop-review-loop',
      checkoutPath: '/tmp/worker'
    }
  });

  assert.equal(packet.evidence.delivery.localReviewLoop.requested, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.source, 'both-issue-bodies');
  assert.equal(packet.evidence.delivery.localReviewLoop.markdownlint, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.requirementsVerification, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.niLinuxReviewSuite, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.singleViHistory, null);
  assert.equal(packet.evidence.lane.workerProviderId, 'local-codex');
  assert.equal(packet.evidence.delivery.workerProviderSelection.selectedProviderId, 'local-codex');
  assert.equal(packet.evidence.delivery.workerProviderSelection.selectedAssignmentMode, 'interactive-coding');
  assert.equal(packet.evidence.delivery.planeTransition.from, 'origin');
  assert.equal(packet.evidence.delivery.planeTransition.to, 'upstream');
  assert.equal(packet.evidence.delivery.planeTransition.action, 'promote');
  assert.equal(packet.evidence.delivery.planeTransition.branchClass, 'lane');
});

test('buildCompareviTaskPacket keeps queue-empty monitoring packets branchless without plane-transition evidence', async () => {
  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot,
    schedulerDecision: {
      source: 'comparevi-standing-priority-live',
      outcome: 'idle',
      reason: 'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action.',
      activeLane: null,
      artifacts: {
        noStandingReason: 'queue-empty',
        laneLifecycle: 'idle'
      }
    }
  });

  assert.equal(packet.status, 'idle');
  assert.equal('branch' in packet, false);
  assert.equal(
    packet.objective.summary,
    'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action.'
  );
  assert.equal(packet.evidence.delivery.planeTransition, null);
});

test('buildCompareviTaskPacket honors local review-loop directives from the selected issue when the standing issue body lacks them', async () => {
  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot,
    schedulerDecision: {
      activeLane: {
        issue: 1054,
        branch: 'issue/origin-1054-slice',
        forkRemote: 'origin'
      },
      artifacts: {
        executionMode: 'canonical-delivery',
        selectedActionType: 'advance-child-issue',
        laneLifecycle: 'coding',
        selectedIssueSnapshot: {
          number: 1054,
          title: 'Child slice',
          body: [
            '## daemon-FIRST local ITERATION extension',
            '- requirements verification',
            '- single-VI touch-aware history on develop'
          ].join('\n'),
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1054'
        },
        standingIssueSnapshot: {
          number: 1053,
          title: 'Standing issue',
          body: 'No review-loop marker here.',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
        }
      }
    },
    preparedWorker: {
      checkoutPath: '/tmp/worker'
    },
    workerReady: {
      checkoutPath: '/tmp/worker'
    },
    workerBranch: {
      branch: 'issue/origin-1054-slice',
      checkoutPath: '/tmp/worker'
    }
  });

  assert.equal(packet.evidence.delivery.localReviewLoop.requested, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.source, 'selected-issue-body');
  assert.equal(packet.evidence.delivery.localReviewLoop.markdownlint, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.requirementsVerification, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.singleViHistory, null);
});

test('buildCompareviTaskPacket only reads local review-loop directives from bodies that contain the marker', async () => {
  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot,
    schedulerDecision: {
      activeLane: {
        issue: 1054,
        branch: 'issue/origin-1054-slice',
        forkRemote: 'origin'
      },
      artifacts: {
        executionMode: 'canonical-delivery',
        selectedActionType: 'advance-child-issue',
        laneLifecycle: 'coding',
        selectedIssueSnapshot: {
          number: 1054,
          title: 'Child slice',
          body: [
            '## daemon-FIRST local ITERATION extension',
            '- requirements verification'
          ].join('\n'),
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1054'
        },
        standingIssueSnapshot: {
          number: 1053,
          title: 'Standing issue',
          body: [
            'This epic mentions markdownlint in unrelated background text.',
            'It intentionally lacks the local iteration marker.'
          ].join('\n'),
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
        }
      }
    },
    preparedWorker: {
      checkoutPath: '/tmp/worker'
    },
    workerReady: {
      checkoutPath: '/tmp/worker'
    },
    workerBranch: {
      branch: 'issue/origin-1054-slice',
      checkoutPath: '/tmp/worker'
    }
  });

  assert.equal(packet.evidence.delivery.localReviewLoop.requested, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.source, 'selected-issue-body');
  assert.equal(packet.evidence.delivery.localReviewLoop.markdownlint, true);
  assert.equal(packet.evidence.delivery.localReviewLoop.requirementsVerification, true);
});

test('buildCompareviTaskPacket honors deps.deliveryAgentPolicyPath overrides', async () => {
  const repoRootTemp = await mkdtemp(path.join(os.tmpdir(), 'comparevi-policy-override-'));
  const policyPath = path.join(repoRootTemp, 'custom-policy.json');
  await writeFile(
    policyPath,
    JSON.stringify({
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true,
      turnBudget: {
        maxMinutes: 7,
        maxToolCalls: 3
      },
      localReviewLoop: {
        enabled: false
      }
    }),
    'utf8'
  );

  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot: repoRootTemp,
    schedulerDecision: {
      activeLane: {
        issue: 1053,
        branch: 'issue/origin-1053-daemon-docker-desktop-review-loop',
        forkRemote: 'origin'
      },
      artifacts: {
        executionMode: 'canonical-delivery',
        selectedActionType: 'advance-child-issue',
        laneLifecycle: 'coding',
        selectedIssueSnapshot: {
          number: 1053,
          title: 'Local loop slice',
          body: '## Daemon-first local iteration extension',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
        },
        standingIssueSnapshot: {
          number: 1053,
          title: 'Standing issue',
          body: '## Daemon-first local iteration extension',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
        }
      }
    },
    preparedWorker: { checkoutPath: '/tmp/worker' },
    workerReady: { checkoutPath: '/tmp/worker' },
    workerBranch: {
      branch: 'issue/origin-1053-daemon-docker-desktop-review-loop',
      checkoutPath: '/tmp/worker'
    },
    deps: {
      deliveryAgentPolicyPath: policyPath,
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ],
        planeTransitions: [
          {
            from: 'origin',
            action: 'promote',
            to: 'upstream',
            via: 'pull-request',
            branchClass: 'lane'
          }
        ]
      })
    }
  });

  assert.equal(packet.evidence.delivery.turnBudget.maxMinutes, 7);
  assert.equal(packet.evidence.delivery.turnBudget.maxToolCalls, 3);
  assert.equal(packet.evidence.delivery.localReviewLoop, null);
  assert.equal(packet.evidence.delivery.planeTransition.from, 'origin');
  assert.equal(packet.evidence.delivery.planeTransition.to, 'upstream');
});

test('buildCompareviTaskPacket projects concurrent lane status receipts from the worker checkout and releases the slot into waiting-ci', async () => {
  const repoRootTemp = await mkdtemp(path.join(os.tmpdir(), 'comparevi-concurrent-status-packet-'));
  const checkoutPath = path.join(repoRootTemp, 'worker');
  const receiptPath = path.join(
    checkoutPath,
    'tests',
    'results',
    '_agent',
    'runtime',
    'concurrent-lane-status-receipt.json'
  );
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify(
      {
        schema: 'priority/concurrent-lane-status-receipt@v1',
        generatedAt: '2026-03-21T10:00:00.000Z',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        status: 'active',
        applyReceipt: {
          path: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
          schema: 'priority/concurrent-lane-apply-receipt@v1',
          status: 'succeeded',
          selectedBundleId: 'hosted-plus-manual-linux-docker'
        },
        hostedRun: {
          observationStatus: 'active',
          runId: 234567890,
          status: 'in_progress',
          conclusion: null,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/234567890',
          workflowName: 'Validate',
          displayTitle: 'Validate',
          headBranch: 'issue/origin-1589-consume-concurrent-lane-status',
          headSha: 'abc123',
          createdAt: '2026-03-21T10:00:00.000Z',
          updatedAt: '2026-03-21T10:05:00.000Z',
          error: null,
          reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-upstream-1482.json',
          helperCommand: ['node', 'tools/npm/run-script.mjs', 'priority:validate']
        },
        pullRequest: {
          observationStatus: 'not-requested',
          selector: {
            source: 'none',
            pr: null,
            ref: null
          },
          number: null,
          url: null,
          state: null,
          isDraft: null,
          headRefName: null,
          mergeStateStatus: null,
          mergeQueue: {
            status: 'not-requested',
            position: null,
            estimatedTimeToMerge: null,
            enqueuedAt: null
          },
          checksSummary: {
            total: 0,
            completed: 0,
            pending: 0,
            failed: 0,
            successful: 0
          },
          error: null
        },
        executionBundle: {
          path: 'tests/results/_agent/runtime/execution-cell-bundle.json',
          schema: 'priority/execution-cell-bundle-report@v1',
          status: 'committed',
          cellId: 'cell-sagan-kernel',
          laneId: 'docker-lane-01',
          cellClass: 'kernel-coordinator',
          suiteClass: 'dual-plane-parity',
          executionCellLeaseId: 'exec-lease-123',
          dockerLaneLeaseId: 'docker-lease-456',
          harnessKind: 'teststand-compare-harness',
          harnessInstanceId: 'ts-harness-01',
          planeBinding: 'dual-plane-parity',
          premiumSaganMode: true,
          reciprocalLinkReady: true,
          effectiveBillableRateUsdPerHour: 375,
          operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
          isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        },
        laneStatuses: [
          {
            id: 'hosted-linux-proof',
            laneClass: 'hosted-proof',
            executionPlane: 'hosted',
            decision: 'dispatched',
            availability: 'available',
            runtimeStatus: 'active',
            reasons: ['hosted-runner-independent-from-local-host'],
            metadata: {}
          },
          {
            id: 'manual-linux-docker',
            laneClass: 'manual-docker',
            executionPlane: 'local',
            decision: 'deferred',
            availability: 'available',
            runtimeStatus: 'deferred',
            reasons: ['docker-engine-linux-observed'],
            metadata: {}
          }
        ],
        observationErrors: [],
        summary: {
          selectedBundleId: 'hosted-plus-manual-linux-docker',
          laneCount: 2,
          activeLaneCount: 1,
          completedLaneCount: 0,
          failedLaneCount: 0,
          blockedLaneCount: 0,
          plannedLaneCount: 0,
          deferredLaneCount: 1,
          manualLaneCount: 1,
          shadowLaneCount: 0,
          executionBundleStatus: 'committed',
          executionBundleReciprocalLinkReady: true,
          executionBundlePremiumSaganMode: true,
          pullRequestStatus: 'not-requested',
          orchestratorDisposition: 'wait-hosted-run'
        }
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot: repoRootTemp,
    schedulerDecision: {
      activeLane: {
        issue: 1589,
        branch: 'issue/origin-1589-consume-concurrent-lane-status',
        forkRemote: 'origin'
      },
      artifacts: {
        executionMode: 'canonical-delivery',
        selectedActionType: 'advance-child-issue',
        laneLifecycle: 'coding',
        selectedIssueSnapshot: {
          number: 1589,
          title: 'Consume concurrent lane status receipts to release or reassign worker slots',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1589'
        },
        standingIssueSnapshot: {
          number: 1482,
          title: 'Add concurrent hosted/manual VI History lane orchestration to reduce agent idle time',
          body: 'epic',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1482'
        }
      }
    },
    preparedWorker: {
      checkoutRoot: path.join('E:', 'comparevi-lanes', 'LabVIEW-Community-CI-CD--compare-vi-cli-action'),
      checkoutRootPolicy: {
        strategy: 'policy-preferred-root',
        source: 'delivery-agent.policy.json#storageRoots.worktrees.preferredRoots[0]',
        baseRoot: path.join('E:', 'comparevi-lanes'),
        relativeRoot: 'LabVIEW-Community-CI-CD--compare-vi-cli-action',
        usesExternalRoot: true
      },
      checkoutPath,
      slotId: 'worker-slot-2'
    },
    workerReady: {
      checkoutPath,
      slotId: 'worker-slot-2'
    },
    workerBranch: {
      branch: 'issue/origin-1589-consume-concurrent-lane-status',
      checkoutPath,
      slotId: 'worker-slot-2'
    },
    deps: {
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          },
          {
            id: 'upstream',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ],
        planeTransitions: [
          {
            from: 'origin',
            action: 'promote',
            to: 'upstream',
            via: 'pull-request',
            branchClass: 'lane'
          }
        ]
      }),
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 4,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        concurrentLaneDispatch: {
          historyScenarioSet: 'smoke',
          sampleIdStrategy: 'auto',
          sampleId: '',
          allowForkMode: 'auto',
          pushMissing: true,
          forcePushOk: false,
          allowNonCanonicalViHistory: false,
          allowNonCanonicalHistoryCore: false
        },
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'local-codex',
              kind: 'local-codex',
              executionPlane: 'local',
              assignmentMode: 'interactive-coding',
              dispatchSurface: 'runtime-harness',
              completionMode: 'sync',
              requiresLocalCheckout: true,
              enabled: true,
              slotCount: 1
            },
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false,
              enabled: true,
              slotCount: 1
            }
          ]
        },
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        turnBudget: {
          maxMinutes: 20,
          maxToolCalls: 12
        },
        codingTurnCommand: ['node', 'mock-broker']
      })
    }
  });

  assert.equal(packet.status, 'waiting-ci');
  assert.equal(packet.evidence.delivery.laneLifecycle, 'waiting-ci');
  assert.equal(packet.evidence.delivery.executionTopology.status, 'bundle-committed');
  assert.equal(packet.evidence.delivery.executionTopology.executionPlane, 'hosted');
  assert.equal(packet.evidence.delivery.executionTopology.providerId, 'hosted-github-workflow');
  assert.equal(packet.evidence.delivery.executionTopology.workerSlotId, 'worker-slot-2');
  assert.equal(packet.evidence.delivery.executionTopology.cellId, 'cell-sagan-kernel');
  assert.equal(packet.evidence.delivery.executionTopology.laneId, 'docker-lane-01');
  assert.equal(packet.evidence.delivery.executionTopology.cellClass, 'kernel-coordinator');
  assert.equal(packet.evidence.delivery.executionTopology.suiteClass, 'dual-plane-parity');
  assert.equal(packet.evidence.delivery.executionTopology.planeBinding, 'dual-plane-parity');
  assert.equal(packet.evidence.delivery.executionTopology.harnessKind, 'teststand-compare-harness');
  assert.equal(packet.evidence.delivery.executionTopology.harnessInstanceId, 'ts-harness-01');
  assert.equal(packet.evidence.delivery.executionTopology.executionCellLeaseId, 'exec-lease-123');
  assert.equal(packet.evidence.delivery.executionTopology.dockerLaneLeaseId, 'docker-lease-456');
  assert.equal(packet.evidence.delivery.executionTopology.premiumSaganMode, true);
  assert.equal(packet.evidence.delivery.executionTopology.reciprocalLinkReady, true);
  assert.equal(
    packet.evidence.delivery.executionTopology.operatorAuthorizationRef,
    'budget-auth://operator/session-2026-03-24'
  );
  assert.equal(packet.evidence.delivery.executionTopology.runtimeSurface, 'windows-native-teststand');
  assert.equal(packet.evidence.delivery.executionTopology.processModelClass, 'parallel-process-model');
  assert.equal(packet.evidence.delivery.executionTopology.windowsOnly, true);
  assert.equal(packet.evidence.delivery.executionTopology.requestedSimultaneous, true);
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.executionBundle.status, 'committed');
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.executionBundle.cellClass, 'kernel-coordinator');
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.executionBundle.suiteClass, 'dual-plane-parity');
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.executionBundle.harnessKind, 'teststand-compare-harness');
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.executionBundle.reciprocalLinkReady, true);
  assert.equal(
    packet.evidence.delivery.concurrentLaneStatus.executionBundle.operatorAuthorizationRef,
    'budget-auth://operator/session-2026-03-24'
  );
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.summary.orchestratorDisposition, 'wait-hosted-run');
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.summary.executionBundleStatus, 'committed');
  assert.equal(packet.evidence.delivery.concurrentLaneStatus.summary.deferredLaneCount, 1);
  assert.equal(packet.evidence.delivery.workerProviderSelection.selectedAssignmentMode, 'async-validation');
  assert.equal(
    packet.evidence.lane.workerCheckoutRoot,
    path.join('E:', 'comparevi-lanes', 'LabVIEW-Community-CI-CD--compare-vi-cli-action')
  );
  assert.deepEqual(packet.evidence.lane.workerCheckoutRootPolicy, {
    strategy: 'policy-preferred-root',
    source: 'delivery-agent.policy.json#storageRoots.worktrees.preferredRoots[0]',
    baseRoot: path.join('E:', 'comparevi-lanes'),
    relativeRoot: 'LabVIEW-Community-CI-CD--compare-vi-cli-action',
    usesExternalRoot: true
  });
});

test('buildCompareviTaskPacket projects concurrent lane apply receipts from the worker checkout and keeps the slot in waiting-ci until status is projected', async () => {
  const repoRootTemp = await mkdtemp(path.join(os.tmpdir(), 'comparevi-concurrent-apply-packet-'));
  const checkoutPath = path.join(repoRootTemp, 'worker');
  const receiptPath = path.join(
    checkoutPath,
    'tests',
    'results',
    '_agent',
    'runtime',
    'concurrent-lane-apply-receipt.json'
  );
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify(
      {
        schema: 'priority/concurrent-lane-apply-receipt@v1',
        generatedAt: '2026-03-21T10:00:00.000Z',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        status: 'succeeded',
        summary: {
          selectedBundleId: 'hosted-plus-manual-linux-docker'
        },
        validateDispatch: {
          status: 'dispatched',
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          remote: 'origin',
          ref: 'issue/origin-1604-concurrent-lane-delivery-turn',
          sampleIdStrategy: 'auto',
          sampleId: 'ts-20260321-000000-abcd',
          historyScenarioSet: 'smoke',
          allowFork: true,
          pushMissing: true,
          forcePushOk: false,
          allowNonCanonicalViHistory: false,
          allowNonCanonicalHistoryCore: false,
          reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-origin-1604.json',
          runDatabaseId: 234567890
        }
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot: repoRootTemp,
    schedulerDecision: {
      activeLane: {
        issue: 1604,
        branch: 'issue/origin-1604-concurrent-lane-delivery-turn',
        forkRemote: 'origin'
      },
      artifacts: {
        executionMode: 'canonical-delivery',
        selectedActionType: 'advance-child-issue',
        laneLifecycle: 'coding',
        selectedIssueSnapshot: {
          number: 1604,
          title: 'Dispatch concurrent lane plans from unattended delivery turns',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1604'
        },
        standingIssueSnapshot: {
          number: 1482,
          title: 'Add concurrent hosted/manual VI History lane orchestration to reduce agent idle time',
          body: 'epic',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1482'
        }
      }
    },
    preparedWorker: {
      checkoutRoot: path.join('E:', 'comparevi-lanes', 'LabVIEW-Community-CI-CD--compare-vi-cli-action'),
      checkoutRootPolicy: {
        strategy: 'policy-preferred-root',
        source: 'delivery-agent.policy.json#storageRoots.worktrees.preferredRoots[0]',
        baseRoot: path.join('E:', 'comparevi-lanes'),
        relativeRoot: 'LabVIEW-Community-CI-CD--compare-vi-cli-action',
        usesExternalRoot: true
      },
      checkoutPath,
      slotId: 'worker-slot-2'
    },
    workerReady: {
      checkoutPath,
      slotId: 'worker-slot-2'
    },
    workerBranch: {
      branch: 'issue/origin-1604-concurrent-lane-delivery-turn',
      checkoutPath,
      slotId: 'worker-slot-2'
    },
    deps: {
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          },
          {
            id: 'upstream',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ],
        planeTransitions: [
          {
            from: 'origin',
            action: 'promote',
            to: 'upstream',
            via: 'pull-request',
            branchClass: 'lane'
          }
        ]
      }),
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 4,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        concurrentLaneDispatch: {
          historyScenarioSet: 'smoke',
          sampleIdStrategy: 'auto',
          sampleId: '',
          allowForkMode: 'auto',
          pushMissing: true,
          forcePushOk: false,
          allowNonCanonicalViHistory: false,
          allowNonCanonicalHistoryCore: false
        },
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'local-codex',
              kind: 'local-codex',
              executionPlane: 'local',
              assignmentMode: 'interactive-coding',
              dispatchSurface: 'runtime-harness',
              completionMode: 'sync',
              requiresLocalCheckout: true,
              enabled: true,
              slotCount: 1
            },
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false,
              enabled: true,
              slotCount: 1
            }
          ]
        },
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        turnBudget: {
          maxMinutes: 20,
          maxToolCalls: 12
        },
        codingTurnCommand: ['node', 'mock-broker']
      })
    }
  });

  assert.equal(packet.status, 'waiting-ci');
  assert.equal(packet.evidence.delivery.laneLifecycle, 'waiting-ci');
  assert.equal(packet.evidence.delivery.concurrentLaneStatus, null);
  assert.equal(packet.evidence.delivery.concurrentLaneApply.selectedBundleId, 'hosted-plus-manual-linux-docker');
  assert.equal(packet.evidence.delivery.concurrentLaneApply.validateDispatch.runDatabaseId, 234567890);
  assert.equal(packet.evidence.delivery.workerProviderSelection.selectedAssignmentMode, 'async-validation');
});

test('buildCompareviTaskPacket fails closed when the branch class contract has no matching plane transition', async () => {
  await assert.rejects(
    compareviRuntimeTest.buildCompareviTaskPacket({
      repoRoot,
      schedulerDecision: {
        activeLane: {
          issue: 1129,
          branch: 'issue/origin-1129-runtime-plane-transition-receipts',
          forkRemote: 'origin'
        },
        artifacts: {
          executionMode: 'canonical-delivery',
          selectedActionType: 'advance-child-issue',
          laneLifecycle: 'coding',
          canonicalRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          selectedIssueSnapshot: {
            number: 1129,
            title: 'Record fork-plane transitions in daemon runtime receipts',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1129'
          }
        }
      },
      preparedWorker: { checkoutPath: '/tmp/worker' },
      workerReady: { checkoutPath: '/tmp/worker' },
      workerBranch: {
        branch: 'issue/origin-1129-runtime-plane-transition-receipts',
        checkoutPath: '/tmp/worker'
      },
      deps: {
        loadBranchClassContractFn: () => ({
          schema: 'branch-classes/v1',
          upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          repositoryPlanes: [
            {
              id: 'origin',
              repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
              laneBranchPrefix: 'issue/origin-'
            }
          ],
          classes: [
            {
              id: 'lane',
              repositoryRoles: ['fork'],
              branchPatterns: ['issue/*'],
              purpose: 'lane',
              prSourceAllowed: true,
              prTargetAllowed: false,
              mergePolicy: 'n/a'
            }
          ],
          allowedTransitions: [
            {
              from: 'lane',
              action: 'promote',
              to: 'upstream-integration',
              via: 'pull-request'
            }
          ],
          planeTransitions: []
        })
      }
    }),
    /not allowed by the branch class contract/i
  );
});

test('buildLocalReviewLoopRequest treats policy booleans as the full requested check set once the marker is present', () => {
  const request = buildLocalReviewLoopRequest({
    standingIssue: {
      number: 1053,
      body: [
        '## Daemon-first local iteration extension',
        '- single-VI touch-aware history on develop'
      ].join('\n'),
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
    },
    selectedIssue: {
      number: 1054,
      body: 'No local review loop marker here.',
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1054'
    },
    policy: {
      localReviewLoop: {
        enabled: true,
        bodyMarkers: ['Daemon-first local iteration extension'],
        receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
        actionlint: false,
        markdownlint: true,
        docs: false,
        workflow: true,
        dotnetCliBuild: false,
        requirementsVerification: true,
        niLinuxReviewSuite: false,
        singleViHistory: {
          enabled: true,
          targetPath: 'fixtures/vi-attr/Head.vi',
          branchRef: 'develop',
          baselineRef: '',
          maxCommitCount: 256
        }
      }
    }
  });

  assert.equal(request.source, 'standing-issue-body');
  assert.equal(request.actionlint, false);
  assert.equal(request.markdownlint, true);
  assert.equal(request.docs, false);
  assert.equal(request.workflow, true);
  assert.equal(request.dotnetCliBuild, false);
  assert.equal(request.requirementsVerification, true);
  assert.equal(request.niLinuxReviewSuite, true);
  assert.deepEqual(request.singleViHistory, {
    enabled: true,
    targetPath: 'fixtures/vi-attr/Head.vi',
    branchRef: 'develop',
    baselineRef: null,
    maxCommitCount: 256
  });
});

test('buildTemplateAgentVerificationReportRefreshOptions derives a pending report refresh after a landed iteration', () => {
  const refreshOptions = compareviRuntimeTest.buildTemplateAgentVerificationReportRefreshOptions({
    repoRoot: '/repo',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      templateAgentVerificationLane: {
        enabled: true,
        reportPath: 'tests/results/_agent/promotion/template-agent-verification-report.json',
        targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1632,
      branch: {
        name: 'issue/origin-1632-template-agent-verification-lane'
      },
      objective: {
        summary: 'Advance issue #1632'
      },
      evidence: {
        delivery: {
          selectedIssue: {
            number: 1632
          }
        }
      },
      pullRequest: {
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1632'
      }
    },
    executionReceipt: {
      status: 'completed',
      details: {
        laneLifecycle: 'waiting-review',
        startHead: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        endHead: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      }
    }
  });

  assert.deepEqual(refreshOptions, {
    policyPath: path.join('/repo', 'tools', 'priority', 'delivery-agent.policy.json'),
    outputPath: path.join('/repo', 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json'),
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    iterationLabel: 'post-merge #1632',
    iterationRef: 'issue/origin-1632-template-agent-verification-lane',
    iterationHeadSha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    verificationStatus: 'pending',
    durationSeconds: null,
    provider: 'hosted-github-workflow',
    runUrl: null,
    templateRepo: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    failOnBlockers: false
  });
});

test('comparevi canonical execution refreshes the template-agent verification report after persisting a landed iteration', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-template-agent-refresh-'));
  const refreshCalls = [];

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
        laneId: 'origin-1632',
        issue: 1632,
        forkRemote: 'origin',
        branch: 'issue/origin-1632-template-agent-verification-lane'
      },
      artifacts: {
        standingRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        standingIssueNumber: 1632,
        laneLifecycle: 'coding',
        selectedActionType: 'advance-child-issue'
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1632,
      branch: {
        name: 'issue/origin-1632-template-agent-verification-lane',
        forkRemote: 'origin'
      },
      objective: {
        summary: 'Advance issue #1632'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          selectedActionType: 'advance-child-issue',
          selectedIssue: {
            number: 1632
          },
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          pullRequest: {
            number: 1632,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1632',
            isDraft: false
          },
          turnBudget: {
            maxMinutes: 20,
            maxToolCalls: 12
          }
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
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'upstream',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/'
          },
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['upstream', 'fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ],
        planeTransitions: [
          {
            from: 'origin',
            action: 'promote',
            to: 'upstream',
            via: 'pull-request',
            branchClass: 'lane'
          }
        ]
      }),
      invokeDeliveryTurnBrokerFn: async () => ({
        status: 'completed',
        outcome: 'coding-command-finished',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'draft-review-clearance',
          startHead: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          endHead: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        }
      }),
      runTemplateAgentVerificationReportFn: async (options) => {
        refreshCalls.push(options);
        return {
          report: {
            summary: {
              status: 'pending'
            }
          },
          outputPath: options.outputPath
        };
      }
    }
  });

  assert.equal(execution.outcome, 'coding-command-finished');
  assert.equal(execution.details.laneLifecycle, 'waiting-review');
  assert.equal(refreshCalls.length, 1);
  assert.equal(refreshCalls[0].policyPath, path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'));
  assert.equal(
    refreshCalls[0].outputPath,
    path.join(repoRoot, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json')
  );
  assert.equal(refreshCalls[0].repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(refreshCalls[0].iterationLabel, 'post-merge #1632');
  assert.equal(refreshCalls[0].iterationRef, 'issue/origin-1632-template-agent-verification-lane');
  assert.equal(refreshCalls[0].iterationHeadSha, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
  assert.equal(refreshCalls[0].verificationStatus, 'pending');
  assert.equal(refreshCalls[0].provider, 'hosted-github-workflow');
  assert.equal(refreshCalls[0].templateRepo, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(refreshCalls[0].failOnBlockers, false);
});

test('comparevi branch resolver matches the repo issue branch naming contract', () => {
  const branch = compareviRuntimeTest.resolveCompareviIssueBranchName({
    issueNumber: 998,
    title: 'Attach ready worker checkouts onto deterministic lane branches',
    forkRemote: 'personal'
  });

  assert.equal(branch, 'issue/personal-998-attach-ready-worker-checkouts-onto-deterministic-lane-branches');
});

test('comparevi branch resolver fails closed when the branch contract does not define the requested plane', () => {
  assert.throws(
    () =>
      compareviRuntimeTest.resolveCompareviIssueBranchName({
        issueNumber: 998,
        title: 'Attach ready worker checkouts onto deterministic lane branches',
        forkRemote: 'personal',
        branchClassContract: {
          repositoryPlanes: [
            {
              id: 'origin',
              laneBranchPrefix: 'issue/origin-'
            }
          ]
        }
      }),
    /does not define repository plane 'personal'/i
  );
});

test('canonical delivery decision fails closed when the implementation plane is missing from the branch contract', async () => {
  await assert.rejects(
    buildCanonicalDeliveryDecision({
      repoRoot,
      upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      targetRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issueSnapshot: {
        number: 1084,
        title: 'Define a fork-plane branching model for personal/org/upstream collaboration',
        state: 'OPEN',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        pullRequests: []
      },
      issueGraph: {
        standingIssue: {
          number: 1084,
          title: 'Define a fork-plane branching model for personal/org/upstream collaboration',
          state: 'OPEN',
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          pullRequests: []
        },
        subIssues: [],
        pullRequests: []
      },
      policy: {
        implementationRemote: 'personal'
      },
      deps: {
        loadBranchClassContractFn: () => ({
          schema: 'branch-classes/v1',
          upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          repositoryPlanes: [
            {
              id: 'origin',
              repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
              laneBranchPrefix: 'issue/origin-'
            }
          ],
          classes: [
            {
              id: 'lane',
              repositoryRoles: ['fork'],
              branchPatterns: ['issue/*'],
              purpose: 'lane',
              prSourceAllowed: true,
              prTargetAllowed: false,
              mergePolicy: 'n/a'
            }
          ],
          allowedTransitions: [
            {
              from: 'lane',
              action: 'promote',
              to: 'upstream-integration',
              via: 'pull-request'
            }
          ]
        })
      }
    }),
    /does not define repository plane 'personal'/i
  );
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
  const state = await readJson(path.join(runtimeRoot, 'delivery-agent-state.json'));
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
  const state = await readJson(path.join(runtimeRoot, 'delivery-agent-state.json'));
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
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'upstream',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/'
          },
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          },
          {
            id: 'personal',
            repositories: ['svelderrainruiz/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/personal-'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['upstream', 'fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ]
      })
    }
  });

  assert.equal(decision.stepOptions.issue, 1012);
  assert.equal(decision.stepOptions.epic, 1010);
  assert.equal(decision.stepOptions.forkRemote, 'origin');
  assert.equal(decision.stepOptions.prUrl, 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88');
  assert.equal(decision.artifacts.selectedActionType, 'existing-pr-unblock');
  assert.equal(decision.artifacts.laneLifecycle, 'ready-merge');
});

test('canonical delivery scheduler work-steals onto a child issue when the best PR candidate is waiting-review', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-work-steal-review-'));
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
          title: '[P1] Watch Copilot review completion',
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
              title: 'Copilot review is still pending',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88',
              state: 'OPEN',
              isDraft: true,
              reviewDecision: null,
              headRefName: 'issue/origin-1012-watch-copilot-review-completion',
              mergeStateStatus: 'BLOCKED',
              mergeable: 'MERGEABLE',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        },
        {
          number: 1013,
          title: '[P1] Keep coding another child slice',
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
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'upstream',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/'
          },
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          },
          {
            id: 'personal',
            repositories: ['svelderrainruiz/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/personal-'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['upstream', 'fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ]
      })
    }
  });

  assert.equal(decision.stepOptions.issue, 1013);
  assert.equal(decision.artifacts.selectedActionType, 'advance-child-issue');
  assert.equal(decision.artifacts.laneLifecycle, 'coding');
  assert.equal(decision.artifacts.offloadedPullRequest.pullRequestNumber, 88);
  assert.equal(decision.artifacts.offloadedPullRequest.laneLifecycle, 'waiting-review');
  assert.equal(decision.artifacts.offloadedPullRequest.nextWakeCondition, 'review-disposition-updated');
});

test('canonical delivery scheduler keeps sync-required waiting-ci PRs ahead of child issue work stealing', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-work-steal-sync-required-'));
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
          title: '[P1] Resync the blocked branch',
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
              number: 89,
              title: 'Branch sync required',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/89',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: 'APPROVED',
              headRefName: 'issue/origin-1012-resync-the-blocked-branch',
              mergeStateStatus: 'BEHIND',
              mergeable: 'MERGEABLE',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        },
        {
          number: 1013,
          title: '[P1] Keep coding another child slice',
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
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'upstream',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/'
          },
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          },
          {
            id: 'personal',
            repositories: ['svelderrainruiz/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/personal-'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['upstream', 'fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ]
      })
    }
  });

  assert.equal(decision.stepOptions.issue, 1012);
  assert.equal(decision.artifacts.selectedActionType, 'existing-pr-unblock');
  assert.equal(decision.artifacts.laneLifecycle, 'waiting-ci');
  assert.equal(decision.artifacts.pullRequest.nextWakeCondition, 'branch-synced');
});

test('canonical delivery scheduler skips merged zero-diff child lanes before assigning work', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-stale-landed-child-'));
  const gitCalls = [];
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
          title: '[P1] Replay landed child lane',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1012',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-09T00:00:00Z',
          updatedAt: '2026-03-09T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 88,
              title: 'Already landed child slice',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88',
              state: 'MERGED',
              isDraft: false,
              reviewDecision: 'APPROVED',
              headRefName: 'issue/origin-1012-replay-landed-child-lane',
              mergeStateStatus: 'UNKNOWN',
              mergeable: 'UNKNOWN',
              statusCheckRollup: []
            }
          ]
        },
        {
          number: 1013,
          title: '[P1] Keep coding another child slice',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1013',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
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
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadBranchClassContractFn: () => makeLaneBranchClassContract(),
      spawnSyncFn: (command, args) => {
        gitCalls.push({ command, args });
        assert.equal(command, 'git');
        assert.match(args[3], /upstream\/develop\.\.\.issue\/origin-1012-p1-replay-landed-child-lane$/);
        return {
          status: 0,
          stdout: '4\t0\n',
          stderr: ''
        };
      }
    }
  });

  assert.equal(decision.stepOptions.issue, 1013);
  assert.equal(decision.artifacts.selectedActionType, 'advance-child-issue');
  assert.equal(gitCalls.length, 1);
});

test('canonical delivery scheduler preserves merged child lanes that still have local diff after a partial merge', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-partial-merge-child-'));
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
          title: '[P1] Preserve remaining local delta after partial merge',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1012',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-09T00:00:00Z',
          updatedAt: '2026-03-09T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 88,
              title: 'Partially merged child slice',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88',
              state: 'MERGED',
              isDraft: false,
              reviewDecision: 'APPROVED',
              headRefName: 'issue/origin-1012-preserve-remaining-local-delta-after-partial-merge',
              mergeStateStatus: 'UNKNOWN',
              mergeable: 'UNKNOWN',
              statusCheckRollup: []
            }
          ]
        },
        {
          number: 1013,
          title: '[P1] Secondary child slice',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1013',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
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
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadBranchClassContractFn: () => makeLaneBranchClassContract(),
      spawnSyncFn: () => ({
        status: 0,
        stdout: '1\t2\n',
        stderr: ''
      })
    }
  });

  assert.equal(decision.stepOptions.issue, 1012);
  assert.equal(decision.artifacts.selectedActionType, 'advance-child-issue');
});

test('canonical delivery scheduler attaches the live Copilot review workflow to waiting-review lanes', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-watch-'));
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
          number: 1015,
          title: '[P1] Auto-finalize merged standing lanes',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 1015,
              title: 'Auto-finalize merged standing lanes',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: null,
              headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
              headRefOid: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab',
              mergeStateStatus: 'BLOCKED',
              mergeable: 'MERGEABLE',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        }
      ],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      runGhApiJsonFn: ({ endpoint }) => {
        if (endpoint.includes('/actions/runs?')) {
          assert.match(endpoint, /per_page=100/);
          return {
            workflow_runs: [
              {
                name: 'Copilot code review',
                id: 22968811761,
                event: 'dynamic',
                status: 'in_progress',
                conclusion: null,
                head_sha: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab',
                html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761',
                created_at: '2026-03-11T18:43:13Z',
                updated_at: '2026-03-11T18:44:00Z'
              }
            ]
          };
        }
        if (endpoint.includes('/pulls/1015/reviews')) {
          return [];
        }
        throw new Error(`Unexpected endpoint: ${endpoint}`);
      },
      runGhGraphqlFn: () => ({
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                nodes: []
              }
            }
          }
        }
      })
    }
  });

  assert.equal(decision.artifacts.laneLifecycle, 'waiting-review');
  assert.equal(decision.artifacts.pullRequest.nextWakeCondition, 'copilot-review-workflow-completed');
  assert.equal(decision.artifacts.pullRequest.pollIntervalSecondsHint, 10);
  assert.equal(decision.artifacts.pullRequest.copilotReviewWorkflow.workflowName, 'Copilot code review');
});

test('canonical delivery scheduler skips Copilot review metadata lookups for stable merge-ready lanes', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-skip-'));
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
          number: 1015,
          title: '[P1] Auto-finalize merged standing lanes',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 1015,
              title: 'Auto-finalize merged standing lanes',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: 'APPROVED',
              headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
              headRefOid: '84c4aab72c007c39c65755743b114cebc7ad093a',
              mergeStateStatus: 'CLEAN',
              mergeable: 'MERGEABLE',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        }
      ],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadCopilotReviewWorkflowRunFn: () => {
        throw new Error('Copilot workflow lookup should not run for stable merge-ready lanes');
      },
      loadCopilotReviewSignalFn: () => {
        throw new Error('Copilot signal lookup should not run for stable merge-ready lanes');
      }
    }
  });

  assert.equal(decision.artifacts.laneLifecycle, 'ready-merge');
  assert.equal(decision.artifacts.pullRequest.copilotReviewWorkflow, null);
  assert.equal(decision.artifacts.pullRequest.copilotReviewSignal, null);
});

test('classifyPullRequestWork keeps approved clean lanes merge-ready even when Copilot workflow metadata is present', () => {
  const prStatus = classifyPullRequestWork({
    number: 1015,
    isDraft: false,
    reviewDecision: 'APPROVED',
    mergeStateStatus: 'CLEAN',
    mergeable: 'MERGEABLE',
    statusCheckRollup: [
      { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
    ],
    copilotReviewWorkflow: {
      workflowName: 'Copilot code review',
      status: 'COMPLETED',
      conclusion: 'SUCCESS'
    }
  });

  assert.equal(prStatus.laneLifecycle, 'ready-merge');
  assert.equal(prStatus.readyToMerge, true);
  assert.equal(prStatus.nextWakeCondition, 'merge-attempt');
  assert.equal(prStatus.pollIntervalSecondsHint, undefined);
});

test('canonical delivery scheduler caches Copilot review metadata by head sha while a lane waits for review', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-cache-'));
  let workflowLookups = 0;
  let signalLookups = 0;
  const buildDecision = () =>
    buildCanonicalDeliveryDecision({
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
            number: 1015,
            title: '[P1] Auto-finalize merged standing lanes',
            body: 'child',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
            state: 'OPEN',
            labels: [],
            repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
            createdAt: '2026-03-10T00:00:00Z',
            updatedAt: '2026-03-10T00:00:00Z',
            priority: 1,
            epic: false,
            pullRequests: [
              {
                number: 1015,
                title: 'Auto-finalize merged standing lanes',
                url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
                state: 'OPEN',
                isDraft: false,
                reviewDecision: null,
                headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
                headRefOid: '84c4aab72c007c39c65755743b114cebc7ad093a',
                mergeStateStatus: 'BLOCKED',
                mergeable: 'MERGEABLE',
                repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
                statusCheckRollup: [
                  { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
                ]
              }
            ]
          }
        ],
        pullRequests: []
      },
      policy: {
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true
      },
      now: new Date('2026-03-11T18:44:00Z'),
      deps: {
        loadCopilotReviewWorkflowRunFn: () => {
          workflowLookups += 1;
          return {
            workflowName: 'Copilot code review',
            runId: 22968811761,
            status: 'IN_PROGRESS',
            conclusion: null,
            headSha: '84c4aab72c007c39c65755743b114cebc7ad093a',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761',
            createdAt: '2026-03-11T18:43:13Z',
            updatedAt: '2026-03-11T18:44:00Z'
          };
        },
        loadCopilotReviewSignalFn: () => {
          signalLookups += 1;
          return null;
        }
      }
    });

  const firstDecision = await buildDecision();
  const secondDecision = await buildDecision();

  assert.equal(firstDecision.artifacts.laneLifecycle, 'waiting-review');
  assert.equal(secondDecision.artifacts.laneLifecycle, 'waiting-review');
  assert.equal(workflowLookups, 1);
  assert.equal(signalLookups, 1);
  assert.equal(secondDecision.artifacts.pullRequest.copilotReviewWorkflow.workflowName, 'Copilot code review');
});

test('canonical delivery scheduler refreshes Copilot review metadata after the cache TTL expires', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-cache-expiry-'));
  let workflowLookups = 0;
  let signalLookups = 0;
  const buildDecision = (now) =>
    buildCanonicalDeliveryDecision({
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
            number: 1015,
            title: '[P1] Auto-finalize merged standing lanes',
            body: 'child',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
            state: 'OPEN',
            labels: [],
            repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
            createdAt: '2026-03-10T00:00:00Z',
            updatedAt: '2026-03-10T00:00:00Z',
            priority: 1,
            epic: false,
            pullRequests: [
              {
                number: 1015,
                title: 'Auto-finalize merged standing lanes',
                url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
                state: 'OPEN',
                isDraft: false,
                reviewDecision: null,
                headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
                headRefOid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                mergeStateStatus: 'BLOCKED',
                mergeable: 'MERGEABLE',
                repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
                statusCheckRollup: [
                  { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
                ]
              }
            ]
          }
        ],
        pullRequests: []
      },
      policy: {
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true
      },
      now,
      deps: {
        loadCopilotReviewWorkflowRunFn: () => {
          workflowLookups += 1;
          return {
            workflowName: 'Copilot code review',
            runId: 22968811761,
            status: 'IN_PROGRESS',
            conclusion: null,
            headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761',
            createdAt: '2026-03-11T18:43:13Z',
            updatedAt: '2026-03-11T18:44:00Z'
          };
        },
        loadCopilotReviewSignalFn: () => {
          signalLookups += 1;
          return null;
        }
      }
    });

  const firstDecision = await buildDecision(new Date('2026-03-11T18:44:00Z'));
  const secondDecision = await buildDecision(new Date('2026-03-11T18:44:11Z'));

  assert.equal(firstDecision.artifacts.laneLifecycle, 'waiting-review');
  assert.equal(secondDecision.artifacts.laneLifecycle, 'waiting-review');
  assert.equal(workflowLookups, 2);
  assert.equal(signalLookups, 2);
});

test('canonical delivery scheduler awaits async Copilot metadata loader deps before caching review state', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-async-cache-'));
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
          number: 1015,
          title: '[P1] Auto-finalize merged standing lanes',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 1015,
              title: 'Auto-finalize merged standing lanes',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: null,
              headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
              headRefOid: '3333333333333333333333333333333333333333',
              mergeStateStatus: 'BLOCKED',
              mergeable: 'MERGEABLE',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        }
      ],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    now: new Date('2026-03-11T18:44:00Z'),
    deps: {
      loadCopilotReviewWorkflowRunFn: async () => ({
        workflowName: 'Copilot code review',
        runId: 22968811761,
        status: 'IN_PROGRESS',
        conclusion: null,
        headSha: '3333333333333333333333333333333333333333',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761',
        createdAt: '2026-03-11T18:43:13Z',
        updatedAt: '2026-03-11T18:44:00Z'
      }),
      loadCopilotReviewSignalFn: async () => ({
        hasCopilotReview: false,
        hasCurrentHeadReview: false,
        latestCopilotReview: null,
        actionableThreadCount: 0,
        actionableCommentCount: 0
      })
    }
  });

  assert.equal(decision.artifacts.laneLifecycle, 'waiting-review');
  assert.equal(decision.artifacts.pullRequest.copilotReviewWorkflow.workflowName, 'Copilot code review');
  assert.equal(decision.artifacts.pullRequest.copilotReviewSignal.hasCopilotReview, false);
});

test('canonical delivery scheduler prunes older head-sha Copilot cache entries for the same PR', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-prune-'));
  let workflowLookups = 0;
  const baseOptions = {
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
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    now: new Date('2026-03-11T18:44:00Z'),
    deps: {
      loadCopilotReviewWorkflowRunFn: ({ headSha }) => {
        workflowLookups += 1;
        return {
          workflowName: 'Copilot code review',
          runId: 22968811761,
          status: 'IN_PROGRESS',
          conclusion: null,
          headSha,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761',
          createdAt: '2026-03-11T18:43:13Z',
          updatedAt: '2026-03-11T18:44:00Z'
        };
      },
      loadCopilotReviewSignalFn: () => null
    }
  };
  const buildIssueGraph = (headRefOid) => ({
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
        number: 1015,
        title: '[P1] Auto-finalize merged standing lanes',
        body: 'child',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
        state: 'OPEN',
        labels: [],
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        createdAt: '2026-03-10T00:00:00Z',
        updatedAt: '2026-03-10T00:00:00Z',
        priority: 1,
        epic: false,
        pullRequests: [
          {
            number: 1015,
            title: 'Auto-finalize merged standing lanes',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
            state: 'OPEN',
            isDraft: false,
            reviewDecision: null,
            headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
            headRefOid,
            mergeStateStatus: 'BLOCKED',
            mergeable: 'MERGEABLE',
            repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
            statusCheckRollup: [
              { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
            ]
          }
        ]
      }
    ],
    pullRequests: []
  });

  await buildCanonicalDeliveryDecision({
    ...baseOptions,
    issueGraph: buildIssueGraph('1111111111111111111111111111111111111111')
  });
  await buildCanonicalDeliveryDecision({
    ...baseOptions,
    issueGraph: buildIssueGraph('2222222222222222222222222222222222222222')
  });

  const cacheDir = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'copilot-review-cache');
  const cacheFiles = await readdir(cacheDir);

  assert.equal(workflowLookups, 2);
  assert.equal(cacheFiles.length, 1);
  assert.match(cacheFiles[0], /2222222222222222222222222222222222222222/);
});

test('canonical delivery scheduler prunes stale Copilot cache entries from older PRs and repositories', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-global-prune-'));
  const cacheDir = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'copilot-review-cache');
  await mkdir(cacheDir, { recursive: true });
  await writeFile(
    path.join(cacheDir, 'example-repo-pr-77-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json'),
    JSON.stringify({
      generatedAt: '2026-03-10T00:00:00Z',
      repository: 'example/repo',
      pullRequestNumber: 77,
      headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      reviewWorkflow: null,
      reviewSignal: null
    })
  );

  await buildCanonicalDeliveryDecision({
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
          number: 1015,
          title: '[P1] Auto-finalize merged standing lanes',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 1015,
              title: 'Auto-finalize merged standing lanes',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: null,
              headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
              headRefOid: '4444444444444444444444444444444444444444',
              mergeStateStatus: 'BLOCKED',
              mergeable: 'MERGEABLE',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        }
      ],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    now: new Date('2026-03-11T18:44:00Z'),
    deps: {
      loadCopilotReviewWorkflowRunFn: () => null,
      loadCopilotReviewSignalFn: () => null
    }
  });

  const cacheFiles = await readdir(cacheDir);
  assert.equal(cacheFiles.length, 1);
  assert.match(cacheFiles[0], /4444444444444444444444444444444444444444/);
});

test('canonical delivery scheduler tolerates corrupted Copilot cache files and rewrites them atomically', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-corrupt-cache-'));
  const cacheDir = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'copilot-review-cache');
  await mkdir(cacheDir, { recursive: true });
  const currentCachePath = path.join(
    cacheDir,
    'LabVIEW-Community-CI-CD-compare-vi-cli-action-pr-1015-5555555555555555555555555555555555555555.json'
  );
  await writeFile(currentCachePath, '{"generatedAt":');
  await writeFile(path.join(cacheDir, 'example-repo-pr-77-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json'), '{"broken":');

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
          number: 1015,
          title: '[P1] Auto-finalize merged standing lanes',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 1015,
              title: 'Auto-finalize merged standing lanes',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: null,
              headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
              headRefOid: '5555555555555555555555555555555555555555',
              mergeStateStatus: 'BLOCKED',
              mergeable: 'MERGEABLE',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        }
      ],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    now: new Date('2026-03-11T18:44:00Z'),
    deps: {
      loadCopilotReviewWorkflowRunFn: () => ({
        workflowName: 'Copilot code review',
        runId: 22968811761,
        status: 'IN_PROGRESS',
        conclusion: null,
        headSha: '5555555555555555555555555555555555555555',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761',
        createdAt: '2026-03-11T18:43:13Z',
        updatedAt: '2026-03-11T18:44:00Z'
      }),
      loadCopilotReviewSignalFn: () => null
    }
  });

  const cacheEntries = await readdir(cacheDir);
  const cachePayload = await readJson(currentCachePath);

  assert.equal(decision.artifacts.laneLifecycle, 'waiting-review');
  assert.equal(cacheEntries.filter((entry) => entry.endsWith('.json')).length, 1);
  assert.equal(cacheEntries.filter((entry) => entry.endsWith('.tmp')).length, 0);
  assert.equal(cachePayload.headSha, '5555555555555555555555555555555555555555');
  assert.equal(cachePayload.reviewWorkflow.workflowName, 'Copilot code review');
});

test('canonical delivery scheduler tolerates transient Copilot review metadata fetch failures', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-canonical-copilot-fallback-'));
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
          number: 1015,
          title: '[P1] Auto-finalize merged standing lanes',
          body: 'child',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1015',
          state: 'OPEN',
          labels: [],
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          priority: 1,
          epic: false,
          pullRequests: [
            {
              number: 1015,
              title: 'Auto-finalize merged standing lanes',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
              state: 'OPEN',
              isDraft: false,
              reviewDecision: null,
              headRefName: 'issue/origin-1010-auto-finalize-merged-standing-lanes',
              headRefOid: '8827146e4298783c15fd5514a3cf4291ef766aa0',
              mergeStateStatus: 'BLOCKED',
              mergeable: 'MERGEABLE',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              statusCheckRollup: [
                { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
              ]
            }
          ]
        }
      ],
      pullRequests: []
    },
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadCopilotReviewWorkflowRunFn: () => {
        throw new Error('temporary GitHub failure');
      },
      loadCopilotReviewSignalFn: () => {
        throw new Error('temporary GitHub failure');
      }
    }
  });

  assert.equal(decision.artifacts.selectedActionType, 'existing-pr-unblock');
  assert.equal(decision.artifacts.laneLifecycle, 'ready-merge');
  assert.equal(decision.artifacts.pullRequest.copilotReviewWorkflow, null);
  assert.equal(decision.artifacts.pullRequest.copilotReviewSignal, null);
});

test('delivery agent review-thread query omits comment bodies to keep Copilot scheduler payloads small', async () => {
  const source = await readFile(new URL('../delivery-agent.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /REVIEW_THREADS_QUERY[\s\S]*'body',/);
});

test('delivery agent helper-call audit strings shell-escape repository and label values', async () => {
  const source = await readFile(new URL('../delivery-agent.mjs', import.meta.url), 'utf8');
  assert.match(source, /function shellEscapeHelperValue\(value\)/);
  assert.match(source, /--remove-label \$\{shellEscapeHelperValue\(label\)\}/);
  assert.match(source, /--repo \$\{shellEscapeHelperValue\(repository\)\}/);
});

test('delivery agent GitHub JSON helpers pin a 32 MB maxBuffer for large review payloads', async () => {
  const source = await readFile(new URL('../delivery-agent.mjs', import.meta.url), 'utf8');
  assert.match(source, /const GH_JSON_MAX_BUFFER_BYTES = 32 \* 1024 \* 1024;/);
  assert.match(source, /spawnSync\('gh', buildGraphqlArgs\(query, variables\), \{[\s\S]*maxBuffer: GH_JSON_MAX_BUFFER_BYTES/s);
  assert.match(source, /spawnSync\('gh', \['api', endpoint\], \{[\s\S]*maxBuffer: GH_JSON_MAX_BUFFER_BYTES/s);
});

test('classifyPullRequestWork compresses waiting-review polling after the Copilot workflow completes on the current head', () => {
  const prStatus = classifyPullRequestWork({
    number: 1015,
    isDraft: false,
    reviewDecision: 'REVIEW_REQUIRED',
    headRefOid: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab',
    statusCheckRollup: [
      { name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
    ],
    copilotReviewWorkflow: {
      workflowName: 'Copilot code review',
      runId: 22968811761,
      status: 'COMPLETED',
      conclusion: 'SUCCESS',
      headSha: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab',
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761',
      createdAt: '2026-03-11T18:43:13Z',
      updatedAt: '2026-03-11T18:48:14Z'
    }
  });

  assert.equal(prStatus.laneLifecycle, 'waiting-review');
  assert.equal(prStatus.nextWakeCondition, 'copilot-review-post-expected');
  assert.equal(prStatus.pollIntervalSecondsHint, 5);
  assert.equal(prStatus.reviewMonitor.workflow.workflowName, 'Copilot code review');
});

test('classifyPullRequestWork reopens an existing PR for coding when Copilot posts actionable current-head comments', () => {
  const prStatus = classifyPullRequestWork({
    number: 1015,
    isDraft: false,
    reviewDecision: null,
    headRefOid: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab',
    statusCheckRollup: [
      { name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
    ],
    copilotReviewSignal: {
      hasCopilotReview: true,
      hasCurrentHeadReview: true,
      latestCopilotReview: {
        id: 3931659485,
        commitId: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab'
      },
      actionableThreadCount: 1,
      actionableCommentCount: 2
    }
  });

  assert.equal(prStatus.laneLifecycle, 'coding');
  assert.equal(prStatus.blockerClass, 'review');
  assert.equal(prStatus.nextWakeCondition, 'review-comments-addressed');
});

test('classifyPullRequestWork reopens an existing PR for coding when Copilot leaves an actionable thread with no inline comment count', () => {
  const prStatus = classifyPullRequestWork({
    number: 1015,
    isDraft: false,
    reviewDecision: null,
    headRefOid: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab',
    statusCheckRollup: [
      { name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS' }
    ],
    copilotReviewSignal: {
      hasCopilotReview: true,
      hasCurrentHeadReview: true,
      latestCopilotReview: {
        id: 3931659485,
        commitId: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab'
      },
      actionableThreadCount: 1,
      actionableCommentCount: 0
    }
  });

  assert.equal(prStatus.laneLifecycle, 'coding');
  assert.equal(prStatus.blockerClass, 'review');
  assert.equal(prStatus.nextWakeCondition, 'review-comments-addressed');
});

test('planDeliveryBrokerAction executes a coding turn when an existing PR has actionable review comments', () => {
  const planned = planDeliveryBrokerAction({
    status: 'coding',
    evidence: {
      delivery: {
        laneLifecycle: 'coding',
        pullRequest: {
          number: 1015,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
          nextWakeCondition: 'review-comments-addressed'
        }
      }
    }
  });

  assert.equal(planned.actionType, 'execute-coding-turn');
  assert.equal(planned.laneLifecycle, 'coding');
});

test('planDeliveryBrokerAction dispatches concurrent lanes when async validation is selected and no PR or status receipt exists yet', () => {
  const planned = planDeliveryBrokerAction({
    status: 'waiting-ci',
    evidence: {
      delivery: {
        laneLifecycle: 'waiting-ci',
        workerProviderSelection: {
          source: 'test',
          laneLifecycle: 'waiting-ci',
          selectedActionType: 'advance-child-issue',
          requiredAssignmentMode: 'async-validation',
          selectedProviderId: 'hosted-github-workflow',
          selectedProviderKind: 'hosted-github-workflow',
          selectedExecutionPlane: 'hosted',
          selectedAssignmentMode: 'async-validation',
          dispatchSurface: 'github-actions',
          completionMode: 'async',
          selectedSlotId: 'worker-slot-2',
          requiresLocalCheckout: false
        }
      }
    }
  });

  assert.deepEqual(planned, {
    actionType: 'dispatch-concurrent-lanes',
    laneLifecycle: 'waiting-ci'
  });
});

test('planDeliveryBrokerAction watches concurrent lane apply receipts when status projection is still pending', () => {
  const planned = planDeliveryBrokerAction({
    status: 'waiting-ci',
    evidence: {
      delivery: {
        laneLifecycle: 'waiting-ci',
        workerProviderSelection: {
          source: 'test',
          laneLifecycle: 'waiting-ci',
          selectedActionType: 'advance-child-issue',
          requiredAssignmentMode: 'async-validation',
          selectedProviderId: 'hosted-github-workflow',
          selectedProviderKind: 'hosted-github-workflow',
          selectedExecutionPlane: 'hosted',
          selectedAssignmentMode: 'async-validation',
          dispatchSurface: 'github-actions',
          completionMode: 'async',
          selectedSlotId: 'worker-slot-2',
          requiresLocalCheckout: false
        },
        concurrentLaneApply: {
          receiptPath: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
          status: 'succeeded',
          selectedBundleId: 'hosted-plus-manual-linux-docker',
          validateDispatch: {
            runDatabaseId: 234567890
          }
        }
      }
    }
  });

  assert.equal(planned.actionType, 'watch-concurrent-lanes');
  assert.equal(planned.laneLifecycle, 'waiting-ci');
  assert.equal(planned.blockerClass, 'ci');
  assert.equal(planned.nextWakeCondition, 'concurrent-lane-status-updated');
  assert.equal(planned.concurrentLaneApply.receiptPath, 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json');
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
      copilotReviewStrategy: 'draft-only-explicit',
      readyForReviewPurpose: 'final-validation',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    deps: {
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'upstream',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/'
          },
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          },
          {
            id: 'personal',
            repositories: ['svelderrainruiz/compare-vi-cli-action'],
            laneBranchPrefix: 'issue/personal-'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['upstream', 'fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ]
      })
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
    repoRoot,
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
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          mutationEnvelope: {
            maxActiveCodingLanes: 1
          },
          turnBudget: {
            maxMinutes: 20,
            maxToolCalls: 12
          },
          localReviewLoop: {
            requested: true,
            source: 'selected-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: true,
            singleViHistory: {
              enabled: true,
              targetPath: 'fixtures/vi-attr/Head.vi',
              branchRef: 'develop',
              baselineRef: '',
              maxCommitCount: 256
            }
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
      loadBranchClassContractFn: () => ({
        schema: 'branch-classes/v1',
        upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        repositoryPlanes: [
          {
            id: 'origin',
            repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
            laneBranchPrefix: 'issue/origin-'
          }
        ],
        classes: [
          {
            id: 'lane',
            repositoryRoles: ['fork'],
            branchPatterns: ['issue/*'],
            purpose: 'lane',
            prSourceAllowed: true,
            prTargetAllowed: false,
            mergePolicy: 'n/a'
          }
        ],
        allowedTransitions: [
          {
            from: 'lane',
            action: 'promote',
            to: 'upstream-integration',
            via: 'pull-request'
          }
        ],
        planeTransitions: [
          {
            from: 'origin',
            action: 'promote',
            to: 'upstream',
            via: 'pull-request',
            branchClass: 'lane'
          }
        ]
      }),
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

test('comparevi runtime executes repo-context pivot when queue-empty portfolio handoff targets canonical template', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-portfolio-pivot-'));
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      outcome: 'idle',
      reason:
        'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action while preparing repo-context pivot to LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate.',
      artifacts: {
        governorPortfolioHandoff: {
          summaryPath: 'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json',
          status: 'owner-match',
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          nextAction: 'future-agent-may-pivot',
          ownerDecisionSource: 'compare-monitoring-mode',
          governorMode: 'monitoring-active',
          reason: 'Governor portfolio keeps current ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action.'
        }
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: {
        summary:
          'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action while preparing repo-context pivot to LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate.'
      }
    },
    taskPacketArtifacts: {
      latestPath: path.join(runtimeDir, 'task-packet.json')
    },
    runtimeArtifactPaths: {
      runtimeDir
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        implementationRemote: 'origin',
        maxActiveCodingLanes: 4
      }),
      readMonitoringEntrypointsFn: async () => createMonitoringEntrypoints(),
      collectMarketplaceSnapshotFn: async () => ({
        schema: 'priority/lane-marketplace-snapshot@v1',
        generatedAt: '2026-03-23T04:31:00.000Z',
        summary: {
          repositoryCount: 0,
          eligibleLaneCount: 0,
          topEligibleLane: null
        },
        entries: []
      }),
      writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json'),
      selectMarketplaceRecommendationFn: () => null,
      runTemplateAgentVerificationReportFn: async () => null
    }
  });

  assert.equal(execution.outcome, 'repo-context-pivot');
  assert.equal(execution.details.actionType, 'repo-context-pivot');
  assert.equal(execution.details.nextWakeCondition, 'target-repository-cycle');
  assert.equal(execution.details.nextOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(
    execution.details.targetEntrypointPath,
    'E:\\comparevi-lanes\\LabviewGitHubCiTemplate-monitoring-canonical'
  );
  assert.equal(
    execution.artifacts.governorPortfolioPivot.status,
    'ready'
  );

  const persisted = await readJson(path.join(runtimeDir, 'delivery-agent-state.json'));
  assert.equal(persisted.activeLane.actionType, 'repo-context-pivot');
  assert.equal(persisted.activeLane.outcome, 'repo-context-pivot');
  assert.equal(persisted.activeLane.nextWakeCondition, 'target-repository-cycle');
});

test('comparevi runtime prefers a ready cross-repo broker decision when queue-empty execution pivots to another repository', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-cross-repo-broker-pivot-'));
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      outcome: 'idle',
      reason:
        'standing queue is empty; cross-repo broker selects LabVIEW-Community-CI-CD/comparevi-history issue #301 via local-codex.',
      artifacts: {
        governorPortfolioHandoff: {
          summaryPath: 'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json',
          status: 'owner-match',
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          nextAction: 'future-agent-may-pivot',
          ownerDecisionSource: 'compare-monitoring-mode',
          governorMode: 'monitoring-active',
          reason: 'Governor portfolio keeps current ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action.'
        },
        crossRepoLaneBrokerDecision: {
          schema: 'priority/cross-repo-lane-broker-decision@v1',
          decision: {
            status: 'ready',
            selectedRepository: 'LabVIEW-Community-CI-CD/comparevi-history',
            selectedIssueNumber: 301,
            selectedIssueUrl: 'https://github.com/LabVIEW-Community-CI-CD/comparevi-history/issues/301',
            selectedIssueTitle: '[ci]: history proving lane',
            selectedProviderId: 'local-codex',
            selectedSlotId: 'worker-slot-1'
          }
        }
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: {
        summary:
          'standing queue is empty; cross-repo broker selects LabVIEW-Community-CI-CD/comparevi-history issue #301 via local-codex.'
      }
    },
    taskPacketArtifacts: {
      latestPath: path.join(runtimeDir, 'task-packet.json')
    },
    runtimeArtifactPaths: {
      runtimeDir
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        implementationRemote: 'origin',
        maxActiveCodingLanes: 4
      }),
      readMonitoringEntrypointsFn: async () => createMonitoringEntrypoints(),
      collectMarketplaceSnapshotFn: async () => ({
        schema: 'priority/lane-marketplace-snapshot@v1',
        generatedAt: '2026-03-23T04:31:00.000Z',
        summary: {
          repositoryCount: 0,
          eligibleLaneCount: 0,
          topEligibleLane: null
        },
        entries: []
      }),
      writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json'),
      selectMarketplaceRecommendationFn: () => null,
      runTemplateAgentVerificationReportFn: async () => null
    }
  });

  assert.equal(execution.outcome, 'repo-context-pivot');
  assert.equal(execution.details.nextOwnerRepository, 'LabVIEW-Community-CI-CD/comparevi-history');
  assert.equal(execution.details.brokerSelectedIssueNumber, 301);
  assert.equal(execution.details.brokerProviderId, 'local-codex');
  assert.equal(
    execution.artifacts.governorPortfolioPivot.targetEntrypointPath,
    'E:\\comparevi-lanes\\comparevi-history-monitoring-canonical'
  );
});

test('comparevi runtime keeps idle when repo-context pivot target registry is unavailable', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-portfolio-pending-'));
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      outcome: 'idle',
      reason:
        'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action while preparing repo-context pivot to LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate.',
      artifacts: {
        governorPortfolioHandoff: {
          summaryPath: 'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json',
          status: 'owner-match',
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          nextAction: 'future-agent-may-pivot',
          ownerDecisionSource: 'compare-monitoring-mode',
          governorMode: 'monitoring-active',
          reason: 'Governor portfolio keeps current ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action.'
        }
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: {
        summary:
          'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action while preparing repo-context pivot to LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate.'
      }
    },
    taskPacketArtifacts: {
      latestPath: path.join(runtimeDir, 'task-packet.json')
    },
    runtimeArtifactPaths: {
      runtimeDir
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        implementationRemote: 'origin',
        maxActiveCodingLanes: 4
      }),
      readMonitoringEntrypointsFn: async () => null,
      collectMarketplaceSnapshotFn: async () => ({
        schema: 'priority/lane-marketplace-snapshot@v1',
        generatedAt: '2026-03-23T04:31:00.000Z',
        summary: {
          repositoryCount: 0,
          eligibleLaneCount: 0,
          topEligibleLane: null
        },
        entries: []
      }),
      writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json'),
      selectMarketplaceRecommendationFn: () => null,
      runTemplateAgentVerificationReportFn: async () => null
    }
  });

  assert.equal(execution.outcome, 'idle');
  assert.equal(execution.details.actionType, 'repo-context-pivot-pending');
  assert.equal(execution.details.pivotStatus, 'missing');
  assert.match(execution.reason, /unavailable \(missing\)/i);

  const persisted = await readJson(path.join(runtimeDir, 'delivery-agent-state.json'));
  assert.equal(persisted.activeLane.actionType, 'repo-context-pivot-pending');
  assert.equal(persisted.activeLane.outcome, 'idle');
});

test('comparevi runtime executes repo-context pivot when queue-empty portfolio handoff targets comparevi-history', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-history-pivot-'));
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      outcome: 'idle',
      reason:
        'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action while preparing repo-context pivot to LabVIEW-Community-CI-CD/comparevi-history.',
      artifacts: {
        governorPortfolioHandoff: {
          summaryPath: 'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json',
          status: 'owner-match',
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/comparevi-history',
          nextAction: 'future-agent-may-pivot',
          ownerDecisionSource: 'delivery-runtime-marketplace',
          governorMode: 'monitoring-active',
          reason: 'Governor portfolio keeps current ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action.'
        }
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: {
        summary:
          'standing queue is empty; governor portfolio keeps ownership in LabVIEW-Community-CI-CD/compare-vi-cli-action while preparing repo-context pivot to LabVIEW-Community-CI-CD/comparevi-history.'
      }
    },
    taskPacketArtifacts: {
      latestPath: path.join(runtimeDir, 'task-packet.json')
    },
    runtimeArtifactPaths: {
      runtimeDir
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        implementationRemote: 'origin',
        maxActiveCodingLanes: 4
      }),
      readMonitoringEntrypointsFn: async () => createMonitoringEntrypoints(),
      collectMarketplaceSnapshotFn: async () => ({
        schema: 'priority/lane-marketplace-snapshot@v1',
        generatedAt: '2026-03-23T04:31:00.000Z',
        summary: {
          repositoryCount: 0,
          eligibleLaneCount: 0,
          topEligibleLane: null
        },
        entries: []
      }),
      writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json'),
      selectMarketplaceRecommendationFn: () => null,
      runTemplateAgentVerificationReportFn: async () => null
    }
  });

  assert.equal(execution.outcome, 'repo-context-pivot');
  assert.equal(execution.details.nextOwnerRepository, 'LabVIEW-Community-CI-CD/comparevi-history');
  assert.equal(execution.details.targetEntrypointPath, 'E:\\comparevi-lanes\\comparevi-history-monitoring-canonical');
  assert.equal(execution.artifacts.governorPortfolioPivot.status, 'ready');
});

test('comparevi runtime releases a waiting-ci slot into cross-repo history work stealing', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-waiting-ci-work-steal-'));
  let brokerCall = null;
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-1982',
        issue: 1982,
        forkRemote: 'origin',
        branch: 'issue/origin-1982-ci-release-waiting-state-worker-slots-into-active-cross-repo-work-stealing',
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1982',
        blockerClass: 'ci'
      },
      artifacts: {
        standingRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        standingIssueNumber: 1982,
        laneLifecycle: 'waiting-ci',
        selectedActionType: 'watch-pr',
        planeTransition: {
          from: 'origin',
          to: 'upstream',
          action: 'promote',
          via: 'pull-request',
          branchClass: 'lane',
          sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
          targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
        }
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1982,
      branch: {
        name: 'issue/origin-1982-ci-release-waiting-state-worker-slots-into-active-cross-repo-work-stealing',
        forkRemote: 'origin'
      },
      objective: { summary: 'Advance issue #1982' },
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2'
        },
        delivery: {
          selectedIssue: {
            number: 1982,
            title: '[ci]: release waiting-state worker slots into active cross-repo work stealing'
          },
          laneLifecycle: 'waiting-ci',
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          workerProviderSelection: {
            selectedSlotId: 'worker-slot-2'
          }
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
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        implementationRemote: 'origin',
        maxActiveCodingLanes: 4,
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'local-codex',
              kind: 'local',
              enabled: true,
              slotCount: 2,
              executionPlane: 'local',
              assignmentMode: 'interactive-coding',
              dispatchSurface: 'codex-cli',
              completionMode: 'synchronous',
              requiresLocalCheckout: true
            },
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              enabled: true,
              slotCount: 2,
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false
            }
          ]
        }
      }),
      invokeDeliveryTurnBrokerFn: async () => ({
        status: 'completed',
        outcome: 'waiting-ci',
        reason: 'Hosted validation is still running.',
        details: {
          actionType: 'watch-pr',
          laneLifecycle: 'waiting-ci',
          blockerClass: 'ci',
          retryable: true,
          nextWakeCondition: 'hosted-lane-settled',
          workerSlotId: 'worker-slot-2'
        }
      }),
      readGovernorPortfolioSummaryFn: async () => ({
        schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
        summary: {
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextAction: 'continue-compare-governance-work',
          ownerDecisionSource: 'compare-governor-summary',
          governorMode: 'compare-governance-work'
        }
      }),
      runCrossRepoLaneBrokerFn: async (options) => {
        brokerCall = options;
        return {
          outputPath: path.join(runtimeDir, 'cross-repo-lane-broker-decision.json'),
          report: {
            schema: 'priority/cross-repo-lane-broker-decision@v1',
            decision: {
              status: 'ready',
              selectedRepository: 'LabVIEW-Community-CI-CD/comparevi-history',
              selectedIssueNumber: 301,
              selectedIssueUrl: 'https://github.com/LabVIEW-Community-CI-CD/comparevi-history/issues/301',
              selectedIssueTitle: '[ci]: history proving lane',
              selectedProviderId: 'local-codex',
              selectedSlotId: 'worker-slot-1',
              selectionSource: 'released-waiting-state-marketplace'
            }
          }
        };
      },
      readMonitoringEntrypointsFn: async () => createMonitoringEntrypoints(),
      collectMarketplaceSnapshotFn: async () => ({
        schema: 'priority/lane-marketplace-snapshot@v1',
        generatedAt: '2026-03-26T03:15:00.000Z',
        summary: {
          repositoryCount: 3,
          eligibleLaneCount: 1,
          topEligibleLane: {
            repository: 'LabVIEW-Community-CI-CD/comparevi-history',
            issueNumber: 301
          }
        },
        entries: []
      }),
      writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json'),
      selectMarketplaceRecommendationFn: () => ({
        repository: 'LabVIEW-Community-CI-CD/comparevi-history',
        issueNumber: 301
      }),
      loadBranchClassContractFn: () => makeLaneBranchClassContract(),
      runTemplateAgentVerificationReportFn: async () => null
    }
  });

  assert.equal(brokerCall.allowReleasedWaitingStateDispatch, true);
  assert.equal(execution.outcome, 'repo-context-pivot');
  assert.equal(execution.details.laneLifecycle, 'waiting-ci');
  assert.equal(execution.details.releasedSlotId, 'worker-slot-2');
  assert.equal(execution.details.nextOwnerRepository, 'LabVIEW-Community-CI-CD/comparevi-history');
  assert.equal(execution.details.brokerSelectedIssueNumber, 301);
  assert.equal(execution.details.brokerProviderId, 'local-codex');

  const persisted = await readJson(path.join(runtimeDir, 'delivery-agent-state.json'));
  assert.equal(persisted.workerPool.releasedLaneCount, 1);
  assert.equal(persisted.workerPool.releasedLanes[0].slotId, 'worker-slot-2');
  assert.equal(persisted.activeLane.actionType, 'repo-context-pivot');
  assert.equal(persisted.activeLane.laneLifecycle, 'waiting-ci');
  assert.equal(
    persisted.activeLane.repoContextPivot.nextOwnerRepository,
    'LabVIEW-Community-CI-CD/comparevi-history'
  );
  assert.equal(persisted.activeLane.repoContextPivot.brokerSelectedIssueNumber, 301);
  assert.equal(persisted.activeLane.repoContextPivot.releasedSlotId, 'worker-slot-2');
});

test('comparevi runtime releases a waiting-review slot into cross-repo template work stealing', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-waiting-review-work-steal-'));
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-1982',
        issue: 1982,
        forkRemote: 'origin',
        branch: 'issue/origin-1982-ci-release-waiting-state-worker-slots-into-active-cross-repo-work-stealing',
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1982',
        blockerClass: 'review'
      },
      artifacts: {
        standingRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        standingIssueNumber: 1982,
        laneLifecycle: 'waiting-review',
        selectedActionType: 'watch-pr',
        planeTransition: {
          from: 'origin',
          to: 'upstream',
          action: 'promote',
          via: 'pull-request',
          branchClass: 'lane',
          sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
          targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
        }
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1982,
      branch: {
        name: 'issue/origin-1982-ci-release-waiting-state-worker-slots-into-active-cross-repo-work-stealing',
        forkRemote: 'origin'
      },
      objective: { summary: 'Advance issue #1982' },
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2'
        },
        delivery: {
          selectedIssue: {
            number: 1982,
            title: '[ci]: release waiting-state worker slots into active cross-repo work stealing'
          },
          laneLifecycle: 'waiting-review',
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          workerProviderSelection: {
            selectedSlotId: 'worker-slot-2'
          }
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
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        implementationRemote: 'origin',
        maxActiveCodingLanes: 4,
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'local-codex',
              kind: 'local',
              enabled: true,
              slotCount: 2,
              executionPlane: 'local',
              assignmentMode: 'interactive-coding',
              dispatchSurface: 'codex-cli',
              completionMode: 'synchronous',
              requiresLocalCheckout: true
            }
          ]
        }
      }),
      invokeDeliveryTurnBrokerFn: async () => ({
        status: 'completed',
        outcome: 'waiting-review',
        reason: 'Review disposition is pending.',
        details: {
          actionType: 'watch-pr',
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'review-disposition-updated',
          workerSlotId: 'worker-slot-2'
        }
      }),
      readGovernorPortfolioSummaryFn: async () => ({
        schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
        summary: {
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextAction: 'continue-compare-governance-work',
          ownerDecisionSource: 'compare-governor-summary',
          governorMode: 'compare-governance-work'
        }
      }),
      runCrossRepoLaneBrokerFn: async () => ({
        outputPath: path.join(runtimeDir, 'cross-repo-lane-broker-decision.json'),
        report: {
          schema: 'priority/cross-repo-lane-broker-decision@v1',
          decision: {
            status: 'ready',
            selectedRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
            selectedIssueNumber: 52,
            selectedIssueUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52',
            selectedIssueTitle: '[comparevi]: template consumer rail',
            selectedProviderId: 'local-codex',
            selectedSlotId: 'worker-slot-1',
            selectionSource: 'released-waiting-state-marketplace'
          }
        }
      }),
      readMonitoringEntrypointsFn: async () => createMonitoringEntrypoints(),
      collectMarketplaceSnapshotFn: async () => ({
        schema: 'priority/lane-marketplace-snapshot@v1',
        generatedAt: '2026-03-26T03:15:00.000Z',
        summary: {
          repositoryCount: 3,
          eligibleLaneCount: 1,
          topEligibleLane: {
            repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
            issueNumber: 52
          }
        },
        entries: []
      }),
      writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json'),
      selectMarketplaceRecommendationFn: () => ({
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        issueNumber: 52
      }),
      loadBranchClassContractFn: () => makeLaneBranchClassContract(),
      runTemplateAgentVerificationReportFn: async () => null
    }
  });

  assert.equal(execution.outcome, 'repo-context-pivot');
  assert.equal(execution.details.laneLifecycle, 'waiting-review');
  assert.equal(execution.details.nextOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(execution.details.brokerSelectedIssueNumber, 52);
  assert.equal(execution.details.releasedSlotId, 'worker-slot-2');

  const persisted = await readJson(path.join(runtimeDir, 'delivery-agent-state.json'));
  assert.equal(persisted.workerPool.releasedLaneCount, 1);
  assert.equal(persisted.workerPool.releasedLanes[0].laneLifecycle, 'waiting-review');
  assert.equal(
    persisted.activeLane.repoContextPivot.nextOwnerRepository,
    'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
  );
  assert.equal(persisted.activeLane.repoContextPivot.brokerSelectedIssueNumber, 52);
});

test('comparevi runtime fails closed when released waiting-state capacity finds no external marketplace candidate', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-waiting-ci-fail-closed-'));
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-1982',
        issue: 1982,
        forkRemote: 'origin',
        branch: 'issue/origin-1982-ci-release-waiting-state-worker-slots-into-active-cross-repo-work-stealing',
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1982',
        blockerClass: 'ci'
      },
      artifacts: {
        standingRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        standingIssueNumber: 1982,
        laneLifecycle: 'waiting-ci',
        selectedActionType: 'watch-pr',
        planeTransition: {
          from: 'origin',
          to: 'upstream',
          action: 'promote',
          via: 'pull-request',
          branchClass: 'lane',
          sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
          targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
        }
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1982,
      branch: {
        name: 'issue/origin-1982-ci-release-waiting-state-worker-slots-into-active-cross-repo-work-stealing',
        forkRemote: 'origin'
      },
      objective: { summary: 'Advance issue #1982' },
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2'
        },
        delivery: {
          selectedIssue: {
            number: 1982,
            title: '[ci]: release waiting-state worker slots into active cross-repo work stealing'
          },
          laneLifecycle: 'waiting-ci',
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          workerProviderSelection: {
            selectedSlotId: 'worker-slot-2'
          }
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
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        implementationRemote: 'origin',
        maxActiveCodingLanes: 4,
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'local-codex',
              kind: 'local',
              enabled: true,
              slotCount: 2,
              executionPlane: 'local',
              assignmentMode: 'interactive-coding',
              dispatchSurface: 'codex-cli',
              completionMode: 'synchronous',
              requiresLocalCheckout: true
            }
          ]
        }
      }),
      invokeDeliveryTurnBrokerFn: async () => ({
        status: 'completed',
        outcome: 'waiting-ci',
        reason: 'Hosted validation is still running.',
        details: {
          actionType: 'watch-pr',
          laneLifecycle: 'waiting-ci',
          blockerClass: 'ci',
          retryable: true,
          nextWakeCondition: 'hosted-lane-settled',
          workerSlotId: 'worker-slot-2'
        }
      }),
      readGovernorPortfolioSummaryFn: async () => ({
        schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
        summary: {
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          nextAction: 'continue-compare-governance-work',
          ownerDecisionSource: 'compare-governor-summary',
          governorMode: 'compare-governance-work'
        }
      }),
      runCrossRepoLaneBrokerFn: async () => ({
        outputPath: path.join(runtimeDir, 'cross-repo-lane-broker-decision.json'),
        report: {
          schema: 'priority/cross-repo-lane-broker-decision@v1',
          decision: {
            status: 'no-eligible-repository',
            selectedRepository: null,
            selectedIssueNumber: null,
            selectedProviderId: 'local-codex',
            selectedSlotId: 'worker-slot-1',
            selectionSource: 'released-waiting-state-marketplace'
          }
        }
      }),
      collectMarketplaceSnapshotFn: async () => ({
        schema: 'priority/lane-marketplace-snapshot@v1',
        generatedAt: '2026-03-26T03:15:00.000Z',
        summary: {
          repositoryCount: 0,
          eligibleLaneCount: 0,
          topEligibleLane: null
        },
        entries: []
      }),
      writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json'),
      selectMarketplaceRecommendationFn: () => null,
      loadBranchClassContractFn: () => makeLaneBranchClassContract(),
      runTemplateAgentVerificationReportFn: async () => null
    }
  });

  assert.equal(execution.outcome, 'waiting-ci');
  assert.equal(execution.details.actionType, 'watch-pr');
  assert.equal(execution.details.nextWakeCondition, 'hosted-lane-settled');

  const persisted = await readJson(path.join(runtimeDir, 'delivery-agent-state.json'));
  assert.equal(persisted.workerPool.releasedLaneCount, 1);
  assert.equal(persisted.activeLane.actionType, 'watch-pr');
  assert.equal(persisted.activeLane.repoContextPivot, null);
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
          selectedActionType: 'merge-pr',
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          }
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

test('comparevi canonical execution persists a broker-managed ready-for-review refresh as waiting-review runtime state', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'comparevi-runtime-waiting-review-'));
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
        branch: 'issue/origin-1012-wire-canonical-delivery-broker',
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015'
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
      laneId: 'origin-1012',
      branch: {
        name: 'issue/origin-1012-wire-canonical-delivery-broker',
        forkRemote: 'origin'
      },
      objective: { summary: 'Advance issue #1012' },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          selectedActionType: 'advance-child-issue',
          selectedIssue: {
            number: 1012
          },
          standingIssue: {
            number: 1010
          },
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          pullRequest: {
            number: 1015,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
            isDraft: false
          },
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
      latestPath: path.join(runtimeDir, 'task-packet.json')
    },
    runtimeArtifactPaths: {
      runtimeDir
    },
    deps: {
      invokeDeliveryTurnBrokerFn: async () => ({
        status: 'completed',
        outcome: 'coding-command-finished',
        reason: 'Broker pushed a follow-up commit, left the PR draft, and is waiting for outer-layer draft review clearance.',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'draft-review-clearance',
          reviewPhase: 'draft-review',
          pollIntervalSecondsHint: 10,
          reviewMonitor: {
            workflowName: 'Copilot code review',
            runId: 22968811761,
            status: 'IN_PROGRESS',
            conclusion: null,
            headSha: '021c02d383a974c5ec3fe6c3ef32f54391f7f6ab',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22968811761'
          },
          helperCallsExecuted: [
            'gh pr ready 1015 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --undo',
            'codex exec --json --color never --cd /work/origin-1012 --dangerously-bypass-approvals-and-sandbox'
          ],
          filesTouched: ['tools/priority/runtime-supervisor.mjs'],
          pullRequestUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
          notes: 'Broker left the PR draft; the outer delivery layer must restore ready for review after local review and current-head draft-phase Copilot clearance.',
          localReviewLoop: {
            status: 'passed',
            source: 'docker-desktop-review-loop',
            reason: 'Docker/Desktop review loop passed.',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            receipt: {
              overall: {
                status: 'passed',
                failedCheck: '',
                message: '',
                exitCode: 0
              },
              artifacts: {
                reviewLoopReceiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
                historyReviewReceiptPath:
                  'tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-review-loop-receipt.json',
                requirementsSummaryPath:
                  'tests/results/docker-tools-parity/requirements-verification/verification-summary.json'
              },
              requirementsCoverage: {
                requirementTotal: 9,
                requirementCovered: 9,
                requirementUncovered: 0,
                uncoveredRequirementIds: null,
                unknownRequirementIds: null
              },
              recommendedReviewOrder: [
                'tests/results/docker-tools-parity/review-loop-receipt.json',
                'tests/results/docker-tools-parity/ni-linux-review-suite/review-suite-summary.html'
              ]
            }
          }
        }
      })
    }
  });

  assert.equal(execution.outcome, 'coding-command-finished');
  assert.equal(execution.details.laneLifecycle, 'waiting-review');
  assert.equal(execution.details.blockerClass, 'review');
  assert.equal(execution.details.nextWakeCondition, 'draft-review-clearance');
  assert.equal(execution.details.reviewPhase, 'draft-review');
  assert.equal(execution.details.pollIntervalSecondsHint, 10);
  assert.equal(execution.details.helperCallsExecuted[0], 'gh pr ready 1015 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --undo');

  const persistedState = await readJson(path.join(runtimeDir, 'delivery-agent-state.json'));
  assert.equal(persistedState.status, 'running');
  assert.equal(persistedState.laneLifecycle, 'waiting-review');
  assert.equal(persistedState.workerPool.liveOrchestratorLane, 'Sagan');
  assert.equal(persistedState.activeLane.laneId, 'origin-1012');
  assert.equal(persistedState.activeLane.prUrl, 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015');
  assert.equal(persistedState.activeLane.blockerClass, 'review');
  assert.equal(persistedState.activeLane.laneLifecycle, 'waiting-review');
  assert.equal(persistedState.activeLane.nextWakeCondition, 'draft-review-clearance');
  assert.equal(persistedState.activeLane.reviewPhase, 'draft-review');
  assert.equal(persistedState.activeLane.pollIntervalSecondsHint, 10);
  assert.equal(persistedState.activeLane.reviewMonitor.workflowName, 'Copilot code review');
  assert.equal(persistedState.activeLane.planeTransition.from, 'origin');
  assert.equal(persistedState.activeLane.planeTransition.to, 'upstream');
  assert.equal(persistedState.activeLane.planeTransition.action, 'promote');
  assert.equal(persistedState.localReviewLoop.status, 'passed');
  assert.equal(persistedState.localReviewLoop.receiptStatus, 'passed');
  assert.equal(persistedState.localReviewLoop.requirementsCoverage.requirementCovered, 9);
  assert.equal(
    persistedState.activeLane.localReviewLoop.artifacts.historyReviewReceiptPath,
    'tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-review-loop-receipt.json'
  );
  assert.equal(
    persistedState.artifacts.localReviewLoopReceiptPath,
    'tests/results/docker-tools-parity/review-loop-receipt.json'
  );
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
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

test('delivery broker finalizes merged standing issues by handing off priority and closing the issue', async () => {
  const handoffCalls = [];
  const closeCalls = [];
  const ghFetchCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #1010'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          standingIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          selectedIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          pullRequest: {
            number: 1014,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1014',
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      mergePullRequestFn: async () => ({
        status: 'completed',
        outcome: 'merged',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: []
        }
      }),
      listOpenIssuesFn: async () => [
        {
          number: 1010,
          title: 'Containerize NILinuxCompare tests via tools image Docker contract',
          state: 'OPEN',
          labels: ['standing-priority'],
          createdAt: '2026-03-11T00:00:00Z',
          updatedAt: '2026-03-11T00:00:00Z',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
        },
        {
          number: 958,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: [
            'This issue remains open only as local blocked tracking under epic #930.',
            'Blocked by LabVIEW-Community-CI-CD/comparevi-history#23.',
            'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
          ].join('\n'),
          state: 'OPEN',
          labels: [],
          createdAt: '2026-03-09T00:00:00Z',
          updatedAt: '2026-03-09T00:00:00Z',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/958'
        },
        {
          number: 959,
          title: 'Downstream onboarding feedback: export GH_TOKEN and avoid missing-artifact cascade failures',
          state: 'OPEN',
          labels: ['bug', 'ci'],
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/959'
        }
      ],
      reconcileStandingAfterMergeFn: async (options) => {
        handoffCalls.push(options);
        return {
          status: 'completed',
          nextStandingIssueNumber: 959,
          helperCallsExecuted: [
            'node tools/priority/reconcile-standing-after-merge.mjs --issue 1010 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --merged --pr 1014'
          ],
          summary: {
            status: 'completed',
            reason: 'standing lane reconciled after merge completion',
            nextStandingIssueNumber: 959
          }
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'merged');
  assert.match(brokerResult.reason, /closed issue #1010; standing priority advanced to #959/i);
  assert.equal(brokerResult.details.finalizedIssueNumber, 1010);
  assert.equal(brokerResult.details.nextStandingIssueNumber, 959);
  assert.deepEqual(
    brokerResult.details.helperCallsExecuted,
    [
      'node tools/priority/merge-sync-pr.mjs',
      'node tools/priority/reconcile-standing-after-merge.mjs --issue 1010 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --merged --pr 1014'
    ]
  );
  assert.equal(handoffCalls.length, 1);
  assert.equal(handoffCalls[0].issueNumber, 1010);
  assert.equal(handoffCalls[0].pullRequestNumber, 1014);
});

test('delivery broker clears stale standing labels from a merged issue that is not the active standing issue', async () => {
  const closeCalls = [];
  const labelEditCalls = [];
  const reconcileCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #1011'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          standingIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          selectedIssue: {
            number: 1011,
            title: 'Refresh downstream proving rail evidence',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1011',
            labels: [
              'standing-priority',
              'needs-triage'
            ]
          },
          pullRequest: {
            number: 1015,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      mergePullRequestFn: async () => ({
        status: 'completed',
        outcome: 'merged',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: []
        }
      }),
      closeIssueWithCommentFn: async (options) => {
        closeCalls.push(options);
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      },
      editIssueLabelsFn: async (options) => {
        labelEditCalls.push(options);
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      },
      reconcileStandingAfterMergeFn: async (options) => {
        reconcileCalls.push(options);
        throw new Error('reconcile should not run for a non-active standing issue');
      }
    }
  });

  assert.equal(brokerResult.outcome, 'merged');
  assert.match(brokerResult.reason, /closed issue #1011/i);
  assert.equal(brokerResult.details.finalizedIssueNumber, 1011);
  assert.equal(brokerResult.details.nextStandingIssueNumber, null);
  assert.deepEqual(
    brokerResult.details.helperCallsExecuted,
    [
      'node tools/priority/merge-sync-pr.mjs',
      'gh issue close 1011 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --comment <omitted>',
      'gh issue edit 1011 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --remove-label standing-priority'
    ]
  );
  assert.equal(closeCalls.length, 1);
  assert.equal(closeCalls[0].issueNumber, 1011);
  assert.equal(labelEditCalls.length, 1);
  assert.equal(labelEditCalls[0].issueNumber, 1011);
  assert.deepEqual(labelEditCalls[0].removeLabels, ['standing-priority']);
  assert.equal(reconcileCalls.length, 0);
});

test('delivery broker rehydrates stale standing labels from live issue state before finalizing a non-active merged issue', async () => {
  const closeCalls = [];
  const labelEditCalls = [];
  const fetchIssueCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #1011'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          standingIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          selectedIssue: {
            number: 1011,
            title: 'Refresh downstream proving rail evidence',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1011',
            labels: ['needs-triage']
          },
          pullRequest: {
            number: 1015,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1015',
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      mergePullRequestFn: async () => ({
        status: 'completed',
        outcome: 'merged',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: []
        }
      }),
      fetchIssueFn: async (number, repoRoot, repository, options) => {
        fetchIssueCalls.push({ number, repoRoot, repository, options });
        return {
          number,
          title: 'Refresh downstream proving rail evidence',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1011',
          state: 'OPEN',
          labels: ['standing-priority', 'needs-triage']
        };
      },
      closeIssueWithCommentFn: async (options) => {
        closeCalls.push(options);
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      },
      editIssueLabelsFn: async (options) => {
        labelEditCalls.push(options);
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'merged');
  assert.equal(fetchIssueCalls.length, 1);
  assert.equal(fetchIssueCalls[0].number, 1011);
  assert.equal(fetchIssueCalls[0].repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(closeCalls.length, 1);
  assert.equal(labelEditCalls.length, 1);
  assert.deepEqual(labelEditCalls[0].removeLabels, ['standing-priority']);
});

test('delivery broker clears standing-priority immediately when a merged standing issue exhausts the queue', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-merge-finalize-'));
  const reconcileCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #1010'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          standingIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          selectedIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          pullRequest: {
            number: 1014,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1014',
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      mergePullRequestFn: async () => ({
        status: 'completed',
        outcome: 'merged',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: []
        }
      }),
      reconcileStandingAfterMergeFn: async (options) => {
        reconcileCalls.push(options);
        return {
          status: 'completed',
          nextStandingIssueNumber: null,
          helperCallsExecuted: [
            'node tools/priority/reconcile-standing-after-merge.mjs --issue 1010 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --merged --pr 1014'
          ],
          summary: {
            status: 'completed',
            reason: 'standing lane reconciled after merge completion',
            nextStandingIssueNumber: null
          }
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'merged');
  assert.equal(brokerResult.details.finalizedIssueNumber, 1010);
  assert.equal(brokerResult.details.nextStandingIssueNumber, null);
  assert.deepEqual(
    brokerResult.details.helperCallsExecuted,
    [
      'node tools/priority/merge-sync-pr.mjs',
      'node tools/priority/reconcile-standing-after-merge.mjs --issue 1010 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --merged --pr 1014'
    ]
  );
  assert.equal(reconcileCalls.length, 1);
  assert.equal(reconcileCalls[0].issueNumber, 1010);
  assert.equal(reconcileCalls[0].pullRequestNumber, 1014);
});

test('delivery broker blocks merged standing reconciliation when the helper fails', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #1010'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          standingIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          selectedIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          pullRequest: {
            number: 1014,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1014',
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      mergePullRequestFn: async () => ({
        status: 'completed',
        outcome: 'merged',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: []
        }
      }),
      reconcileStandingAfterMergeFn: async () => {
        throw new Error('detail hydration failed');
      }
    }
  });

  assert.equal(brokerResult.status, 'blocked');
  assert.equal(brokerResult.outcome, 'merged-finalization-blocked');
  assert.match(brokerResult.reason, /automatic standing-priority reconciliation is still pending/i);
  assert.equal(brokerResult.details.finalizedIssueNumber, null);
  assert.equal(brokerResult.details.pendingIssueNumber, 1010);
  assert.equal(brokerResult.details.nextStandingIssueNumber, null);
  assert.match(brokerResult.details.standingSelectionWarning, /detail hydration failed/i);
  assert.deepEqual(brokerResult.details.helperCallsExecuted, [
    'node tools/priority/merge-sync-pr.mjs'
  ]);
});

test('delivery broker propagates reconciliation failures after selection instead of downgrading them to selection warnings', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #1010'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          standingIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          selectedIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          pullRequest: {
            number: 1014,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1014',
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      mergePullRequestFn: async () => ({
        status: 'completed',
        outcome: 'merged',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: []
        }
      }),
      reconcileStandingAfterMergeFn: async () => {
        throw new Error('reconciliation hydration failed');
      }
    }
  });

  assert.equal(brokerResult.status, 'blocked');
  assert.equal(brokerResult.outcome, 'merged-finalization-blocked');
  assert.match(brokerResult.reason, /automatic standing-priority reconciliation is still pending/i);
  assert.deepEqual(brokerResult.details.helperCallsExecuted, ['node tools/priority/merge-sync-pr.mjs']);
});

test('delivery broker forwards null PR numbers to standing reconciliation when only a PR URL is available', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-merge-comment-'));
  const reconcileCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'ready-merge',
      objective: {
        summary: 'Advance issue #1010'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
          standingIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          selectedIssue: {
            number: 1010,
            title: 'Containerize NILinuxCompare tests via tools image Docker contract',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
          },
          pullRequest: {
            number: null,
            url: 'https://example.invalid/pr/custom',
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: []
      }),
      mergePullRequestFn: async () => ({
        status: 'completed',
        outcome: 'merged',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: []
        }
      }),
      reconcileStandingAfterMergeFn: async (options) => {
        reconcileCalls.push(options);
        return {
          status: 'completed',
          nextStandingIssueNumber: null,
          helperCallsExecuted: [
            'node tools/priority/reconcile-standing-after-merge.mjs --issue 1010 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --merged'
          ],
          summary: {
            status: 'completed',
            reason: 'standing lane reconciled after merge completion',
            nextStandingIssueNumber: null
          }
        };
      }
    }
  });

  assert.equal(brokerResult.outcome, 'merged');
  assert.equal(reconcileCalls.length, 1);
  assert.equal(reconcileCalls[0].pullRequestNumber, null);
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
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

test('delivery broker appends a passed local Docker/Desktop review loop to coding receipts when requested', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #1053'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: true,
            singleViHistory: {
              enabled: true,
              targetPath: 'fixtures/vi-attr/Head.vi',
              branchRef: 'develop',
              baselineRef: null,
              maxCommitCount: 256
            }
          },
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          bodyMarkers: ['Daemon-first local iteration extension'],
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs'],
          markdownlint: true,
          requirementsVerification: true,
          niLinuxReviewSuite: true,
          singleViHistory: {
            enabled: true,
            targetPath: 'fixtures/vi-attr/Head.vi',
            branchRef: 'develop',
            baselineRef: '',
            maxCommitCount: 256
          }
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      invokeCodingTurnFn: async () => ({
        status: 'completed',
        outcome: 'waiting-review',
        source: 'delivery-agent-broker',
        reason: 'Broker refreshed the PR and requested a new Copilot review.',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'copilot-review-workflow-completed',
          helperCallsExecuted: ['node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/run-delivery-turn-with-codex.ts --fallback-dist dist/tools/priority/run-delivery-turn-with-codex.js'],
          filesTouched: ['docs/knowledgebase/DOCKER_TOOLS_PARITY.md']
        }
      }),
      runCommandFn: async (command, args) => {
        assert.equal(command, 'node');
        assert.equal(args[0], 'tools/priority/docker-desktop-review-loop.mjs');
        return {
          status: 0,
          stdout: JSON.stringify({
            status: 'passed',
            source: 'docker-desktop-review-loop',
            reason: 'Docker/Desktop review loop passed.',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            receipt: {
              overall: {
                status: 'passed',
                failedCheck: '',
                message: '',
                exitCode: 0
              }
            }
          }),
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-review');
  assert.match(brokerResult.reason, /Local Docker\/Desktop review loop passed/i);
  assert.equal(brokerResult.details.localReviewLoop.status, 'passed');
  assert.equal(brokerResult.details.localReviewLoop.receipt.overall.status, 'passed');
  assert.match(
    brokerResult.details.helperCallsExecuted.join('\n'),
    /node tools\/priority\/docker-desktop-review-loop\.mjs --repo-root \/tmp\/repo/
  );
});

test('delivery broker reuses a current clean Docker/Desktop review loop receipt when the head has not changed', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-broker-local-review-reuse-'));
  runGit(tempRepo, ['init']);
  runGit(tempRepo, ['config', 'user.name', 'Agent Runner']);
  runGit(tempRepo, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(tempRepo, 'README.md'), '# temp\n', 'utf8');
  runGit(tempRepo, ['add', 'README.md']);
  runGit(tempRepo, ['commit', '-m', 'init']);
  const headSha = runGit(tempRepo, ['rev-parse', 'HEAD']);
  const receiptPath = path.join(tempRepo, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'docker-tools-parity-review-loop@v1',
      git: {
        headSha,
        branch: 'issue/test',
        upstreamDevelopMergeBase: null,
        dirtyTracked: false
      },
      overall: {
        status: 'passed',
        failedCheck: '',
        message: '',
        exitCode: 0
      },
      checks: {
        markdownlint: { enabled: true, status: 'passed' },
        requirementsVerification: { enabled: true, status: 'passed' }
      }
    })}\n`,
    'utf8'
  );

  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #1053'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            actionlint: false,
            markdownlint: true,
            docs: false,
            workflow: false,
            dotnetCliBuild: false,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      invokeCodingTurnFn: async () => ({
        status: 'completed',
        outcome: 'waiting-review',
        source: 'delivery-agent-broker',
        reason: 'Broker refreshed the PR and requested a new Copilot review.',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'copilot-review-workflow-completed',
          helperCallsExecuted: ['node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/run-delivery-turn-with-codex.ts --fallback-dist dist/tools/priority/run-delivery-turn-with-codex.js'],
          filesTouched: ['docs/knowledgebase/DOCKER_TOOLS_PARITY.md']
        }
      }),
      runCommandFn: async () => {
        throw new Error('runCommandFn should not be called when a reusable current-head receipt exists');
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-review');
  assert.match(brokerResult.reason, /Reused current Docker\/Desktop review loop receipt/i);
  assert.equal(brokerResult.details.localReviewLoop.source, 'docker-desktop-review-loop-cache');
  assert.equal(brokerResult.details.localReviewLoop.receiptFreshForHead, true);
  assert.equal(brokerResult.details.localReviewLoop.currentHeadSha, headSha);
  assert.equal(brokerResult.details.localReviewLoop.requestedCoverageSatisfied, true);
});

test('delivery broker restores ready only after clean current-head draft review and a reusable local receipt', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-broker-draft-ready-restore-'));
  runGit(tempRepo, ['init']);
  runGit(tempRepo, ['config', 'user.name', 'Agent Runner']);
  runGit(tempRepo, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(tempRepo, 'README.md'), '# temp\n', 'utf8');
  runGit(tempRepo, ['add', 'README.md']);
  runGit(tempRepo, ['commit', '-m', 'init']);
  const headSha = runGit(tempRepo, ['rev-parse', 'HEAD']);
  const receiptPath = path.join(tempRepo, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'docker-tools-parity-review-loop@v1',
      git: {
        headSha,
        branch: 'issue/test',
        upstreamDevelopMergeBase: null,
        dirtyTracked: false
      },
      overall: {
        status: 'passed',
        failedCheck: '',
        message: '',
        exitCode: 0
      },
      checks: {
        markdownlint: { enabled: true, status: 'passed' },
        requirementsVerification: { enabled: true, status: 'passed' }
      }
    })}\n`,
    'utf8'
  );

  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      objective: {
        summary: 'Advance issue #1067'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: true,
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        if (command === 'node') {
          return {
            status: 0,
            stdout: JSON.stringify({
              status: 'passed',
              source: 'docker-desktop-review-loop',
              reason: 'Local Docker/Desktop review loop is green for the current head.',
              receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
              currentHeadSha: headSha,
              receiptHeadSha: headSha,
              receiptFreshForHead: true,
              requestedCoverageSatisfied: true,
              requestedCoverageReason: 'requested coverage satisfied',
              requestedCoverageMissingChecks: [],
              receipt: JSON.parse(await readFile(receiptPath, 'utf8'))
            }),
            stderr: ''
          };
        }
        assert.equal(command, 'gh');
        assert.deepEqual(args, ['pr', 'ready', '1067', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action']);
        return {
          status: 0,
          stdout: 'converted to ready\n',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-ci');
  assert.equal(brokerResult.details.laneLifecycle, 'waiting-ci');
  assert.equal(brokerResult.details.reviewPhase, 'ready-validation');
  assert.equal(brokerResult.details.localReviewLoop.status, 'passed');
  assert.equal(helperCalls.length, 2);
  assert.match(helperCalls[0], /^node tools\/priority\/docker-desktop-review-loop\.mjs /);
  assert.equal(helperCalls[1], 'gh pr ready 1067 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.match(brokerResult.reason, /marked the pr ready for review/i);
});

test('delivery broker passes configured daemon review providers to the local collaboration wrapper on a fresh draft head', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-broker-daemon-rereview-'));
  runGit(tempRepo, ['init']);
  runGit(tempRepo, ['config', 'user.name', 'Agent Runner']);
  runGit(tempRepo, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(tempRepo, 'README.md'), '# temp\n', 'utf8');
  runGit(tempRepo, ['add', 'README.md']);
  runGit(tempRepo, ['commit', '-m', 'init']);
  const headSha = runGit(tempRepo, ['rev-parse', 'HEAD']);

  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      objective: {
        summary: 'Advance issue #1074'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1074,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1074',
            isDraft: true,
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          reviewProviders: ['copilot-cli'],
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/local-collab/orchestrator/run-phase.mjs', '--phase', 'daemon']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        if (command === 'node') {
          return {
            status: 0,
            stdout: JSON.stringify({
              status: 'passed',
              source: 'local-collab-daemon-review',
              reason: 'Docker/Desktop review loop passed and daemon local agent review providers passed.',
              receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
              currentHeadSha: headSha,
              receiptHeadSha: headSha,
              receiptFreshForHead: true,
              requestedCoverageSatisfied: true,
              requestedCoverageReason: 'requested coverage satisfied',
              requestedCoverageMissingChecks: [],
              receipt: {
                git: {
                  headSha,
                  dirtyTracked: false
                },
                overall: {
                  status: 'passed',
                  failedCheck: '',
                  message: '',
                  exitCode: 0
                }
              },
              agentReview: {
                receiptPath: 'tests/results/docker-tools-parity/agent-review-policy/receipt.json',
                receiptStatus: 'passed',
                selectionSource: 'explicit-request',
                requestedProviders: ['copilot-cli'],
                actionableFindingCount: 0
              }
            }),
            stderr: ''
          };
        }
        assert.equal(command, 'gh');
        assert.deepEqual(args, ['pr', 'ready', '1074', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action']);
        return {
          status: 0,
          stdout: 'converted to ready\n',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-ci');
  assert.equal(helperCalls.length, 2);
  assert.match(
    helperCalls[0],
    /^node tools\/local-collab\/orchestrator\/run-phase\.mjs --phase daemon --providers copilot-cli --repo-root /
  );
  assert.equal(brokerResult.details.localReviewLoop.status, 'passed');
  assert.equal(brokerResult.details.localReviewLoop.currentHeadSha, headSha);
});

test('delivery broker keeps a draft PR waiting-review when local receipt freshness or coverage cannot be proven', async () => {
  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      objective: {
        summary: 'Advance issue #1067'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: true,
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        assert.equal(command, 'node');
        return {
          status: 0,
          stdout: JSON.stringify({
            status: 'passed',
            source: 'docker-desktop-review-loop',
            reason: 'Receipt was read, but freshness and coverage were not proven.',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            currentHeadSha: '1111111111111111111111111111111111111111',
            receiptHeadSha: '1111111111111111111111111111111111111111',
            receiptFreshForHead: null,
            requestedCoverageSatisfied: null,
            requestedCoverageReason: null,
            requestedCoverageMissingChecks: [],
            receipt: {
              git: {
                headSha: '1111111111111111111111111111111111111111',
                dirtyTracked: false
              },
              overall: {
                status: 'passed',
                failedCheck: '',
                message: '',
                exitCode: 0
              }
            }
          }),
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-review');
  assert.equal(brokerResult.details.reviewPhase, 'draft-review');
  assert.equal(helperCalls.length, 1);
  assert.equal(brokerResult.details.helperCallsExecuted.length, 1);
  assert.match(
    brokerResult.details.helperCallsExecuted[0],
    /^node tools\/priority\/docker-desktop-review-loop\.mjs\b/
  );
  assert.equal(brokerResult.details.localReviewLoop.receiptFreshForHead, null);
  assert.equal(brokerResult.details.localReviewLoop.requestedCoverageSatisfied, null);
  assert.equal(brokerResult.details.nextWakeCondition, 'local-review-loop-green');
  assert.match(brokerResult.reason, /current-head, clean, and request-complete/i);
});

test('delivery broker keeps a draft PR waiting-review when the Copilot workflow succeeded but no current-head review is observable', async () => {
  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      objective: {
        summary: 'Advance issue #1067'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: true,
            copilotReviewSignal: {
              hasCurrentHeadReview: false,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-review');
  assert.equal(brokerResult.details.reviewPhase, 'draft-review');
  assert.equal(brokerResult.details.nextWakeCondition, 'copilot-review-post-expected');
  assert.equal(helperCalls.length, 0);
  assert.match(brokerResult.reason, /draft-phase Copilot review clearance exists on the current head/i);
});

test('delivery broker returns a prematurely ready PR to draft when draft-phase review clearance is missing', async () => {
  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      objective: {
        summary: 'Advance issue #1067'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-ci',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: false,
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 1
            },
            copilotReviewWorkflow: null
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        assert.equal(command, 'gh');
        assert.deepEqual(args, [
          'pr',
          'ready',
          '1067',
          '--repo',
          'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          '--undo'
        ]);
        return {
          status: 0,
          stdout: 'converted to draft\n',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-review');
  assert.equal(brokerResult.details.reviewPhase, 'draft-review');
  assert.equal(helperCalls.length, 1);
  assert.match(brokerResult.reason, /returned to draft/i);
  assert.equal(brokerResult.details.reviewMonitor, null);
});

test('delivery broker returns a ready PR to draft when the current head no longer matches stored ready-validation clearance', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-broker-redraft-head-mismatch-'));
  runGit(tempRepo, ['init']);
  runGit(tempRepo, ['config', 'user.name', 'Agent Runner']);
  runGit(tempRepo, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(tempRepo, 'README.md'), '# temp\n', 'utf8');
  runGit(tempRepo, ['add', 'README.md']);
  runGit(tempRepo, ['commit', '-m', 'init']);
  const readyValidationDir = path.join(tempRepo, 'tests', 'results', '_agent', 'runtime', 'ready-validation-clearance');
  await mkdir(readyValidationDir, { recursive: true });
  const readyValidationPath = path.join(
    readyValidationDir,
    'LabVIEW-Community-CI-CD-compare-vi-cli-action-pr-1067.json'
  );
  await writeFile(
    readyValidationPath,
    `${JSON.stringify({
      schema: 'priority/ready-validation-clearance@v1',
      generatedAt: '2026-03-14T00:00:00.000Z',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequestNumber: 1067,
      pullRequestUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
      readyHeadSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      status: 'current',
      reason: 'PR entered ready-validation on the current head after clean draft-phase review clearance.',
      localReviewLoop: null
    })}\n`,
    'utf8'
  );

  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      objective: {
        summary: 'Advance issue #1075'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-ci',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: false,
            headRefOid: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        assert.equal(command, 'gh');
        assert.deepEqual(args, [
          'pr',
          'ready',
          '1067',
          '--repo',
          'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          '--undo'
        ]);
        return {
          status: 0,
          stdout: 'converted to draft\n',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-review');
  assert.equal(brokerResult.details.reviewPhase, 'draft-review');
  assert.equal(helperCalls.length, 1);
  assert.equal(brokerResult.details.readyValidationClearance.status, 'invalidated-head-mismatch');
  assert.equal(
    brokerResult.details.readyValidationClearance.readyHeadSha,
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  );
  assert.equal(
    brokerResult.details.readyValidationClearance.currentHeadSha,
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  );
  assert.equal(brokerResult.details.readyValidationClearance.staleForCurrentHead, true);
  assert.match(brokerResult.reason, /current head changed after ready-validation clearance was recorded/i);

  const persistedClearance = JSON.parse(await readFile(readyValidationPath, 'utf8'));
  assert.equal(persistedClearance.status, 'invalidated-head-mismatch');
  assert.equal(persistedClearance.readyHeadSha, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  assert.equal(persistedClearance.currentHeadSha, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
  assert.match(persistedClearance.reason, /no longer matches current head/i);
});

test('delivery broker keeps ready PR waiting-review state in ready-validation when the PR is not draft', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-review',
      objective: {
        summary: 'Advance issue #1067'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-review',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: false,
            nextWakeCondition: 'review-disposition-updated',
            pollIntervalSecondsHint: 30,
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        codingTurnCommand: ['node', 'mock-broker']
      })
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-review');
  assert.equal(brokerResult.details.laneLifecycle, 'waiting-review');
  assert.equal(brokerResult.details.reviewPhase, 'ready-validation');
  assert.deepEqual(brokerResult.details.helperCallsExecuted, []);
});

test('delivery broker fails closed and re-drafts when a ready PR local receipt is stale and cannot be refreshed', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-broker-redraft-stale-receipt-'));
  runGit(tempRepo, ['init']);
  runGit(tempRepo, ['config', 'user.name', 'Agent Runner']);
  runGit(tempRepo, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(tempRepo, 'README.md'), '# temp\n', 'utf8');
  runGit(tempRepo, ['add', 'README.md']);
  runGit(tempRepo, ['commit', '-m', 'init']);
  const receiptPath = path.join(tempRepo, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'docker-tools-parity-review-loop@v1',
      git: {
        headSha: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
        branch: 'issue/test',
        upstreamDevelopMergeBase: null,
        dirtyTracked: false
      },
      overall: {
        status: 'passed',
        failedCheck: '',
        message: '',
        exitCode: 0
      },
      checks: {
        markdownlint: { enabled: true, status: 'passed' },
        requirementsVerification: { enabled: true, status: 'passed' }
      }
    })}\n`,
    'utf8'
  );

  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      objective: {
        summary: 'Advance issue #1067'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-ci',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: false,
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        if (command === 'node') {
          return {
            status: 1,
            stdout: JSON.stringify({
              status: 'failed',
              source: 'docker-desktop-review-loop',
              reason: 'Docker/Desktop review loop failed while refreshing the stale receipt.',
              receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
              receipt: {
                overall: {
                  status: 'failed',
                  failedCheck: 'markdownlint',
                  message: 'markdownlint failed',
                  exitCode: 1
                }
              }
            }),
            stderr: 'markdownlint failed'
          };
        }
        assert.equal(command, 'gh');
        assert.deepEqual(args, [
          'pr',
          'ready',
          '1067',
          '--repo',
          'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          '--undo'
        ]);
        return {
          status: 0,
          stdout: 'converted to draft\n',
          stderr: ''
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'blocked');
  assert.equal(brokerResult.outcome, 'local-review-loop-failed');
  assert.equal(brokerResult.details.reviewPhase, 'draft-review');
  assert.match(brokerResult.reason, /refreshing the stale receipt/i);
  assert.match(brokerResult.details.localReviewLoop.receipt.overall.message, /markdownlint/i);
  assert.match(helperCalls.join('\n'), /gh pr ready 1067 .* --undo/);
});

test('delivery broker fails closed when re-drafting after a local review failure does not succeed', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-broker-redraft-failure-'));
  runGit(tempRepo, ['init']);
  runGit(tempRepo, ['config', 'user.name', 'Agent Runner']);
  runGit(tempRepo, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(tempRepo, 'README.md'), '# temp\n', 'utf8');
  runGit(tempRepo, ['add', 'README.md']);
  runGit(tempRepo, ['commit', '-m', 'init']);

  const helperCalls = [];
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      objective: {
        summary: 'Advance issue #1067'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-ci',
          pullRequest: {
            number: 1067,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1067',
            isDraft: false,
            copilotReviewSignal: {
              hasCurrentHeadReview: true,
              actionableCommentCount: 0,
              actionableThreadCount: 0
            },
            copilotReviewWorkflow: {
              status: 'COMPLETED',
              conclusion: 'SUCCESS'
            }
          },
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      runCommandFn: async (command, args) => {
        helperCalls.push([command, ...args].join(' '));
        if (command === 'node') {
          return {
            status: 1,
            stdout: JSON.stringify({
              status: 'failed',
              source: 'docker-desktop-review-loop',
              reason: 'Docker/Desktop review loop failed on markdownlint.',
              receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
              receipt: {
                overall: {
                  status: 'failed',
                  failedCheck: 'markdownlint',
                  message: 'markdownlint failed',
                  exitCode: 1
                }
              }
            }),
            stderr: 'markdownlint failed'
          };
        }
        assert.equal(command, 'gh');
        assert.deepEqual(args, [
          'pr',
          'ready',
          '1067',
          '--repo',
          'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          '--undo'
        ]);
        return {
          status: 1,
          stdout: '',
          stderr: 'GraphQL: cannot convert pull request back to draft'
        };
      }
    }
  });

  assert.equal(brokerResult.status, 'blocked');
  assert.equal(brokerResult.outcome, 'draft-transition-failed');
  assert.equal(brokerResult.details.blockerClass, 'helperbug');
  assert.equal(brokerResult.details.reviewPhase, 'draft-review');
  assert.equal(brokerResult.details.nextWakeCondition, 'draft-transition-fixed');
  assert.equal(brokerResult.details.localReviewLoop.status, 'failed');
  assert.match(brokerResult.reason, /cannot convert pull request back to draft/i);
  assert.match(helperCalls.join('\n'), /node tools\/priority\/docker-desktop-review-loop\.mjs/);
  assert.match(helperCalls.join('\n'), /gh pr ready 1067 .* --undo/);
});

test('delivery broker reruns the local review loop when the current-head receipt is under-scoped for the requested checks', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-broker-local-review-rerun-'));
  runGit(tempRepo, ['init']);
  runGit(tempRepo, ['config', 'user.name', 'Agent Runner']);
  runGit(tempRepo, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(tempRepo, 'README.md'), '# temp\n', 'utf8');
  runGit(tempRepo, ['add', 'README.md']);
  runGit(tempRepo, ['commit', '-m', 'init']);
  const headSha = runGit(tempRepo, ['rev-parse', 'HEAD']);
  const receiptPath = path.join(tempRepo, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'docker-tools-parity-review-loop@v1',
      git: {
        headSha,
        branch: 'issue/test',
        upstreamDevelopMergeBase: null,
        dirtyTracked: false
      },
      overall: {
        status: 'passed',
        failedCheck: '',
        message: '',
        exitCode: 0
      },
      checks: {
        markdownlint: { enabled: true, status: 'passed' },
        requirementsVerification: { enabled: false, status: 'skipped' }
      }
    })}\n`,
    'utf8'
  );

  let runCount = 0;
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #1053'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            actionlint: false,
            markdownlint: true,
            docs: false,
            workflow: false,
            dotnetCliBuild: false,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      invokeCodingTurnFn: async () => ({
        status: 'completed',
        outcome: 'waiting-review',
        source: 'delivery-agent-broker',
        reason: 'Broker refreshed the PR and requested a new Copilot review.',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'copilot-review-workflow-completed',
          helperCallsExecuted: ['node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/run-delivery-turn-with-codex.ts --fallback-dist dist/tools/priority/run-delivery-turn-with-codex.js'],
          filesTouched: ['docs/knowledgebase/DOCKER_TOOLS_PARITY.md']
        }
      }),
      runCommandFn: async (_command, _args) => {
        runCount += 1;
        await writeFile(
          receiptPath,
          `${JSON.stringify({
            schema: 'docker-tools-parity-review-loop@v1',
            git: {
              headSha,
              branch: 'issue/test',
              upstreamDevelopMergeBase: null,
              dirtyTracked: false
            },
            overall: {
              status: 'passed',
              failedCheck: '',
              message: '',
              exitCode: 0
            },
            checks: {
              markdownlint: { enabled: true, status: 'passed' },
              requirementsVerification: { enabled: true, status: 'passed' }
            }
          })}\n`,
          'utf8'
        );
        return {
          status: 0,
          stdout: JSON.stringify({
            status: 'passed',
            source: 'docker-desktop-review-loop',
            reason: 'Docker/Desktop review loop passed.',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            currentHeadSha: headSha,
            receiptHeadSha: headSha,
            receiptFreshForHead: true,
            requestedCoverageSatisfied: true,
            requestedCoverageReason: 'Docker/Desktop review loop receipt covers the requested review surfaces.',
            requestedCoverageMissingChecks: [],
            receipt: {
              overall: {
                status: 'passed',
                failedCheck: '',
                message: '',
                exitCode: 0
              }
            }
          }),
          stderr: ''
        };
      }
    }
  });

  assert.equal(runCount, 1);
  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.details.localReviewLoop.source, 'docker-desktop-review-loop');
  assert.equal(brokerResult.details.localReviewLoop.requestedCoverageSatisfied, true);
});

test('delivery broker fails closed when the requested local Docker/Desktop review loop fails', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #1053'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          localReviewLoop: {
            requested: true,
            source: 'standing-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      invokeCodingTurnFn: async () => ({
        status: 'completed',
        outcome: 'coding-command-finished',
        source: 'delivery-agent-broker',
        reason: 'Coding turn completed without an explicit receipt payload.',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'coding',
          blockerClass: 'none',
          retryable: true,
          nextWakeCondition: 'scheduler-rescan',
          helperCallsExecuted: ['node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/run-delivery-turn-with-codex.ts --fallback-dist dist/tools/priority/run-delivery-turn-with-codex.js'],
          filesTouched: ['tools/priority/delivery-agent.mjs']
        }
      }),
      runCommandFn: async () => ({
        status: 1,
        stdout: JSON.stringify({
          status: 'failed',
          source: 'docker-desktop-review-loop',
          reason: 'Docker/Desktop review loop failed on markdownlint.',
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          receipt: {
            overall: {
              status: 'failed',
              failedCheck: 'markdownlint',
              message: 'markdownlint failed',
              exitCode: 1
            }
          }
        }),
        stderr: 'markdownlint failed'
      })
    }
  });

  assert.equal(brokerResult.status, 'blocked');
  assert.equal(brokerResult.outcome, 'local-review-loop-failed');
  assert.equal(brokerResult.details.blockerClass, 'ci');
  assert.equal(brokerResult.details.localReviewLoop.status, 'failed');
  assert.match(brokerResult.reason, /markdownlint/i);
});

test('delivery broker fails closed when the local review loop returns non-JSON stdout and no receipt', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #1053'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          localReviewLoop: {
            requested: true,
            source: 'selected-issue-body',
            receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
            markdownlint: true,
            requirementsVerification: true,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      invokeCodingTurnFn: async () => ({
        status: 'completed',
        outcome: 'coding-command-finished',
        source: 'delivery-agent-broker',
        reason: 'Coding turn completed without an explicit receipt payload.',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'coding',
          blockerClass: 'none',
          retryable: true,
          nextWakeCondition: 'scheduler-rescan',
          helperCallsExecuted: ['node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/run-delivery-turn-with-codex.ts --fallback-dist dist/tools/priority/run-delivery-turn-with-codex.js'],
          filesTouched: ['tools/priority/delivery-agent.mjs']
        }
      }),
      runCommandFn: async () => ({
        status: 0,
        stdout: 'not-json',
        stderr: ''
      })
    }
  });

  assert.equal(brokerResult.status, 'blocked');
  assert.equal(brokerResult.outcome, 'local-review-loop-failed');
  assert.equal(brokerResult.details.localReviewLoop.status, 'failed');
  assert.match(brokerResult.reason, /valid machine-readable result|not valid json/i);
});

test('delivery broker fails closed when the local review loop receipt path escapes the repo contract root', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: '/tmp/repo',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      objective: {
        summary: 'Advance issue #1053'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'coding',
          localReviewLoop: {
            requested: true,
            source: 'selected-issue-body',
            receiptPath: '../outside.json',
            markdownlint: true,
            requirementsVerification: false,
            niLinuxReviewSuite: false,
            singleViHistory: null
          },
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
        copilotReviewStrategy: 'draft-only-explicit',
        readyForReviewPurpose: 'final-validation',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 1,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        localReviewLoop: {
          enabled: true,
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          command: ['node', 'tools/priority/docker-desktop-review-loop.mjs']
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      invokeCodingTurnFn: async () => ({
        status: 'completed',
        outcome: 'coding-command-finished',
        source: 'delivery-agent-broker',
        reason: 'Coding turn completed without an explicit receipt payload.',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'coding',
          blockerClass: 'none',
          retryable: true,
          nextWakeCondition: 'scheduler-rescan',
          helperCallsExecuted: ['node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/run-delivery-turn-with-codex.ts --fallback-dist dist/tools/priority/run-delivery-turn-with-codex.js'],
          filesTouched: ['tools/priority/delivery-agent.mjs']
        }
      }),
      runCommandFn: async () => {
        throw new Error('runCommandFn should not be called when receiptPath is invalid');
      }
    }
  });

  assert.equal(brokerResult.status, 'blocked');
  assert.equal(brokerResult.outcome, 'local-review-loop-failed');
  assert.equal(brokerResult.details.blockerClass, 'policy');
  assert.match(brokerResult.reason, /must stay under tests\/results\/docker-tools-parity|escapes the repository root/i);
});

test('delivery agent runCommand keeps spawn errors non-zero and preserves diagnostics', () => {
  const source = readFileSync(new URL('../delivery-agent.mjs', import.meta.url), 'utf8');
  assert.match(source, /status:\s*Number\.isInteger\(result\.status\)\s*\?\s*result\.status\s*:\s*1/);
  assert.match(source, /normalizeText\(result\.error\?\.message\)/);
  assert.match(source, /Process terminated by signal/);
});

test('delivery broker watches concurrent lane status receipts when hosted work is remote-only and no PR exists yet', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      objective: {
        summary: 'Advance issue #1589'
      },
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2'
        },
        delivery: {
          laneLifecycle: 'waiting-ci',
          workerProviderSelection: {
            source: 'test',
            laneLifecycle: 'waiting-ci',
            selectedActionType: 'advance-child-issue',
            requiredAssignmentMode: 'async-validation',
            selectedProviderId: 'hosted-github-workflow',
            selectedProviderKind: 'hosted-github-workflow',
            selectedExecutionPlane: 'hosted',
            selectedAssignmentMode: 'async-validation',
            dispatchSurface: 'github-actions',
            completionMode: 'async',
            selectedSlotId: 'worker-slot-2',
            requiresLocalCheckout: false
          },
          concurrentLaneStatus: {
            receiptPath: 'tests/results/_agent/runtime/concurrent-lane-status-receipt.json',
            status: 'active',
            selectedBundleId: 'hosted-plus-manual-linux-docker',
            hostedRun: {
              observationStatus: 'active',
              runId: 234567890,
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/234567890',
              reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-upstream-1482.json'
            },
            pullRequest: {
              observationStatus: 'not-requested',
              number: null,
              url: null,
              mergeQueue: {
                status: 'not-requested',
                position: null,
                estimatedTimeToMerge: null,
                enqueuedAt: null
              }
            },
            summary: {
              laneCount: 2,
              activeLaneCount: 1,
              completedLaneCount: 0,
              failedLaneCount: 0,
              deferredLaneCount: 1,
              manualLaneCount: 1,
              shadowLaneCount: 0,
              pullRequestStatus: 'not-requested',
              orchestratorDisposition: 'wait-hosted-run'
            }
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
            maxActiveCodingLanes: 4
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 4,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false,
              enabled: true,
              slotCount: 1
            }
          ]
        },
        turnBudget: {
          maxMinutes: 20,
          maxToolCalls: 12
        },
        codingTurnCommand: ['node', 'mock-broker']
      })
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-ci');
  assert.equal(brokerResult.details.actionType, 'watch-concurrent-lanes');
  assert.equal(brokerResult.details.laneLifecycle, 'waiting-ci');
  assert.equal(brokerResult.details.blockerClass, 'ci');
  assert.equal(brokerResult.details.nextWakeCondition, 'hosted-lane-settled');
  assert.equal(brokerResult.details.providerDispatch.completionStatus, 'waiting');
  assert.equal(brokerResult.details.providerDispatch.workerSlotId, 'worker-slot-2');
});

test('delivery broker watches concurrent lane apply receipts instead of redispatching when status is not yet projected', async () => {
  const brokerResult = await runDeliveryTurnBroker({
    repoRoot,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      objective: {
        summary: 'Advance issue #1604'
      },
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2'
        },
        delivery: {
          laneLifecycle: 'waiting-ci',
          workerProviderSelection: {
            source: 'test',
            laneLifecycle: 'waiting-ci',
            selectedActionType: 'advance-child-issue',
            requiredAssignmentMode: 'async-validation',
            selectedProviderId: 'hosted-github-workflow',
            selectedProviderKind: 'hosted-github-workflow',
            selectedExecutionPlane: 'hosted',
            selectedAssignmentMode: 'async-validation',
            dispatchSurface: 'github-actions',
            completionMode: 'async',
            selectedSlotId: 'worker-slot-2',
            requiresLocalCheckout: false
          },
          concurrentLaneApply: {
            receiptPath: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
            status: 'succeeded',
            selectedBundleId: 'hosted-plus-manual-linux-docker',
            validateDispatch: {
              status: 'dispatched',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              remote: 'origin',
              ref: 'issue/origin-1604-concurrent-lane-delivery-turn',
              sampleIdStrategy: 'auto',
              sampleId: 'ts-20260321-000000-abcd',
              historyScenarioSet: 'smoke',
              allowFork: true,
              pushMissing: true,
              forcePushOk: false,
              allowNonCanonicalViHistory: false,
              allowNonCanonicalHistoryCore: false,
              reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-origin-1604.json',
              runDatabaseId: 234567890
            }
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
            maxActiveCodingLanes: 4
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 4,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false,
              enabled: true,
              slotCount: 1
            }
          ]
        },
        turnBudget: {
          maxMinutes: 20,
          maxToolCalls: 12
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      applyConcurrentLanePlanFn: async () => {
        throw new Error('applyConcurrentLanePlanFn should not be called when an apply receipt already exists');
      }
    }
  });

  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-ci');
  assert.equal(brokerResult.details.actionType, 'watch-concurrent-lanes');
  assert.equal(brokerResult.details.laneLifecycle, 'waiting-ci');
  assert.equal(brokerResult.details.blockerClass, 'ci');
  assert.equal(brokerResult.details.nextWakeCondition, 'concurrent-lane-status-updated');
  assert.equal(
    brokerResult.details.concurrentLaneApply.receiptPath,
    'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json'
  );
  assert.equal(brokerResult.details.providerDispatch.completionStatus, 'waiting');
  assert.equal(brokerResult.details.providerDispatch.workerSlotId, 'worker-slot-2');
});

test('delivery broker dispatches concurrent lanes and immediately projects status receipts when hosted validation is selected with no PR yet', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-concurrent-dispatch-'));
  const applyReceiptPath = path.join(tempRepo, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-apply-receipt.json');
  const statusReceiptPath = path.join(tempRepo, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-status-receipt.json');
  const applyCalls = [];
  const statusCalls = [];

  const brokerResult = await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      branch: {
        name: 'issue/origin-1604-concurrent-lane-delivery-turn',
        forkRemote: 'origin'
      },
      objective: {
        summary: 'Advance issue #1604'
      },
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2'
        },
        delivery: {
          laneLifecycle: 'waiting-ci',
          workerProviderSelection: {
            source: 'test',
            laneLifecycle: 'waiting-ci',
            selectedActionType: 'advance-child-issue',
            requiredAssignmentMode: 'async-validation',
            selectedProviderId: 'hosted-github-workflow',
            selectedProviderKind: 'hosted-github-workflow',
            selectedExecutionPlane: 'hosted',
            selectedAssignmentMode: 'async-validation',
            dispatchSurface: 'github-actions',
            completionMode: 'async',
            selectedSlotId: 'worker-slot-2',
            requiresLocalCheckout: false
          },
          mutationEnvelope: {
            copilotReviewStrategy: 'draft-only-explicit',
            maxActiveCodingLanes: 4
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
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 4,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false,
              enabled: true,
              slotCount: 1
            }
          ]
        },
        turnBudget: {
          maxMinutes: 20,
          maxToolCalls: 12
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      applyConcurrentLanePlanFn: async (options) => {
        applyCalls.push(options);
        return {
          receipt: {
            schema: 'priority/concurrent-lane-apply-receipt@v1',
            status: 'succeeded',
            summary: {
              selectedBundleId: 'hosted-plus-manual-linux-docker'
            },
            validateDispatch: {
              status: 'dispatched',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              remote: 'origin',
              ref: 'issue/origin-1604-concurrent-lane-delivery-turn',
              sampleIdStrategy: 'auto',
              sampleId: 'ts-20260321-000000-abcd',
              historyScenarioSet: 'smoke',
              allowFork: true,
              pushMissing: true,
              forcePushOk: false,
              allowNonCanonicalViHistory: false,
              allowNonCanonicalHistoryCore: false,
              reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-origin-1604.json',
              runDatabaseId: 234567890
            }
          },
          outputPath: applyReceiptPath,
          error: null
        };
      },
      observeConcurrentLaneStatusFn: async (options, injectedDeps) => {
        statusCalls.push({ options, injectedDeps });
        return {
          receipt: {
            schema: 'priority/concurrent-lane-status-receipt@v1',
            status: 'active',
            applyReceipt: {
              path: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
              schema: 'priority/concurrent-lane-apply-receipt@v1',
              status: 'succeeded',
              selectedBundleId: 'hosted-plus-manual-linux-docker'
            },
            hostedRun: {
              observationStatus: 'active',
              runId: 234567890,
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/234567890',
              reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-origin-1604.json'
            },
            pullRequest: {
              observationStatus: 'not-requested',
              number: null,
              url: null,
              mergeQueue: {
                status: 'not-requested',
                position: null,
                estimatedTimeToMerge: null,
                enqueuedAt: null
              }
            },
            summary: {
              selectedBundleId: 'hosted-plus-manual-linux-docker',
              laneCount: 2,
              activeLaneCount: 1,
              completedLaneCount: 0,
              failedLaneCount: 0,
              deferredLaneCount: 1,
              manualLaneCount: 1,
              shadowLaneCount: 0,
              pullRequestStatus: 'not-requested',
              orchestratorDisposition: 'wait-hosted-run'
            }
          },
          outputPath: statusReceiptPath
        };
      }
    }
  });

  assert.equal(applyCalls.length, 1);
  assert.equal(applyCalls[0].ref, 'issue/origin-1604-concurrent-lane-delivery-turn');
  assert.equal(applyCalls[0].allowFork, true);
  assert.equal(applyCalls[0].pushMissing, true);
  assert.equal(applyCalls[0].forcePushOk, false);
  assert.equal(applyCalls[0].historyScenarioSet, 'smoke');
  assert.equal(applyCalls[0].sampleIdStrategy, 'auto');
  assert.equal(applyCalls[0].allowNonCanonicalViHistory, false);
  assert.equal(applyCalls[0].allowNonCanonicalHistoryCore, false);
  assert.equal(statusCalls.length, 1);
  assert.equal(statusCalls[0].options.applyReceiptPath, applyReceiptPath);
  assert.equal(statusCalls[0].options.outputPath, statusReceiptPath);
  assert.equal(statusCalls[0].options.ref, 'issue/origin-1604-concurrent-lane-delivery-turn');
  assert.equal(statusCalls[0].injectedDeps.getRepoRootFn(), tempRepo);
  assert.equal(brokerResult.status, 'completed');
  assert.equal(brokerResult.outcome, 'waiting-ci');
  assert.equal(brokerResult.details.actionType, 'dispatch-concurrent-lanes');
  assert.equal(brokerResult.details.blockerClass, 'ci');
  assert.equal(brokerResult.details.nextWakeCondition, 'hosted-lane-settled');
  assert.equal(
    brokerResult.details.concurrentLaneApply.receiptPath,
    'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json'
  );
  assert.equal(brokerResult.details.concurrentLaneApply.validateDispatch.sampleIdStrategy, 'auto');
  assert.equal(
    brokerResult.details.concurrentLaneStatus.receiptPath,
    'tests/results/_agent/runtime/concurrent-lane-status-receipt.json'
  );
  assert.equal(brokerResult.details.providerDispatch.completionStatus, 'waiting');
  assert.equal(brokerResult.details.providerDispatch.workerSlotId, 'worker-slot-2');
  assert.match(brokerResult.details.helperCallsExecuted.join('\n'), /concurrent-lane-apply\.mjs/);
  assert.match(brokerResult.details.helperCallsExecuted.join('\n'), /concurrent-lane-status\.mjs/);
});

test('delivery broker derives upstream-only concurrent lane dispatch posture from policy defaults', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-concurrent-upstream-policy-'));
  const applyCalls = [];

  await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      branch: {
        name: 'issue/upstream-1606-concurrent-dispatch-policy',
        forkRemote: 'upstream'
      },
      objective: {
        summary: 'Advance issue #1606'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-ci',
          workerProviderSelection: {
            selectedProviderId: 'hosted-github-workflow',
            selectedProviderKind: 'hosted-github-workflow',
            selectedExecutionPlane: 'hosted',
            selectedAssignmentMode: 'async-validation',
            dispatchSurface: 'github-actions',
            completionMode: 'async',
            selectedSlotId: 'worker-slot-1',
            requiresLocalCheckout: false
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 4,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        concurrentLaneDispatch: {
          historyScenarioSet: 'smoke',
          sampleIdStrategy: 'auto',
          sampleId: '',
          allowForkMode: 'auto',
          pushMissing: false,
          forcePushOk: false,
          allowNonCanonicalViHistory: false,
          allowNonCanonicalHistoryCore: false
        },
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false,
              enabled: true,
              slotCount: 1
            }
          ]
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      applyConcurrentLanePlanFn: async (options) => {
        applyCalls.push(options);
        return {
          receipt: {
            schema: 'priority/concurrent-lane-apply-receipt@v1',
            status: 'succeeded',
            summary: { selectedBundleId: 'hosted-plus-manual-linux-docker' },
            validateDispatch: {
              status: 'dry-run',
              repository: null,
              remote: null,
              ref: options.ref,
              sampleIdStrategy: options.sampleIdStrategy,
              sampleId: options.sampleId,
              historyScenarioSet: options.historyScenarioSet,
              allowFork: options.allowFork,
              pushMissing: options.pushMissing,
              forcePushOk: options.forcePushOk,
              allowNonCanonicalViHistory: options.allowNonCanonicalViHistory,
              allowNonCanonicalHistoryCore: options.allowNonCanonicalHistoryCore,
              reportPath: null,
              runDatabaseId: null,
              error: null
            }
          },
          outputPath: path.join(tempRepo, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-apply-receipt.json'),
          error: null
        };
      },
      observeConcurrentLaneStatusFn: async () => ({
        receipt: {
          schema: 'priority/concurrent-lane-status-receipt@v1',
          status: 'active',
          applyReceipt: {
            path: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
            schema: 'priority/concurrent-lane-apply-receipt@v1',
            status: 'succeeded',
            selectedBundleId: 'hosted-plus-manual-linux-docker'
          },
          hostedRun: {
            observationStatus: 'active',
            runId: null,
            url: null,
            reportPath: null
          },
          pullRequest: {
            observationStatus: 'not-requested',
            number: null,
            url: null,
            mergeQueue: {
              status: 'not-requested',
              position: null,
              estimatedTimeToMerge: null,
              enqueuedAt: null
            }
          },
          summary: {
            selectedBundleId: 'hosted-plus-manual-linux-docker',
            laneCount: 2,
            activeLaneCount: 1,
            completedLaneCount: 0,
            failedLaneCount: 0,
            deferredLaneCount: 1,
            manualLaneCount: 1,
            shadowLaneCount: 0,
            pullRequestStatus: 'not-requested',
            orchestratorDisposition: 'wait-hosted-run'
          }
        },
        outputPath: path.join(tempRepo, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-status-receipt.json')
      })
    }
  });

  assert.equal(applyCalls.length, 1);
  assert.equal(applyCalls[0].allowFork, false);
  assert.equal(applyCalls[0].pushMissing, false);
  assert.equal(applyCalls[0].historyScenarioSet, 'smoke');
});

test('delivery broker lets task-packet concurrent lane dispatch overrides enable history-core and noncanonical certification lanes', async () => {
  const tempRepo = await mkdtemp(path.join(os.tmpdir(), 'delivery-concurrent-noncanonical-override-'));
  const applyCalls = [];

  await runDeliveryTurnBroker({
    repoRoot: tempRepo,
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'waiting-ci',
      branch: {
        name: 'issue/origin-1606-concurrent-dispatch-policy',
        forkRemote: 'origin'
      },
      objective: {
        summary: 'Advance issue #1606'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'waiting-ci',
          concurrentLaneDispatch: {
            historyScenarioSet: 'history-core',
            sampleIdStrategy: 'explicit',
            sampleId: 'ts-20260321-123456-zzzz',
            allowForkMode: 'always',
            pushMissing: false,
            forcePushOk: false,
            allowNonCanonicalViHistory: true,
            allowNonCanonicalHistoryCore: true
          },
          workerProviderSelection: {
            selectedProviderId: 'hosted-github-workflow',
            selectedProviderKind: 'hosted-github-workflow',
            selectedExecutionPlane: 'hosted',
            selectedAssignmentMode: 'async-validation',
            dispatchSurface: 'github-actions',
            completionMode: 'async',
            selectedSlotId: 'worker-slot-1',
            requiresLocalCheckout: false
          }
        }
      }
    },
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({
        schema: 'priority/delivery-agent-policy@v1',
        backlogAuthority: 'issues',
        implementationRemote: 'origin',
        copilotReviewStrategy: 'draft-only-explicit',
        autoSlice: true,
        autoMerge: true,
        maxActiveCodingLanes: 4,
        allowPolicyMutations: false,
        allowReleaseAdmin: false,
        stopWhenNoOpenEpics: true,
        concurrentLaneDispatch: {
          historyScenarioSet: 'smoke',
          sampleIdStrategy: 'auto',
          sampleId: '',
          allowForkMode: 'auto',
          pushMissing: true,
          forcePushOk: false,
          allowNonCanonicalViHistory: false,
          allowNonCanonicalHistoryCore: false
        },
        workerPool: {
          targetSlotCount: 4,
          prewarmSlotCount: 1,
          releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
          providers: [
            {
              id: 'hosted-github-workflow',
              kind: 'hosted-github-workflow',
              executionPlane: 'hosted',
              assignmentMode: 'async-validation',
              dispatchSurface: 'github-actions',
              completionMode: 'async',
              requiresLocalCheckout: false,
              enabled: true,
              slotCount: 1
            }
          ]
        },
        codingTurnCommand: ['node', 'mock-broker']
      }),
      applyConcurrentLanePlanFn: async (options) => {
        applyCalls.push(options);
        return {
          receipt: {
            schema: 'priority/concurrent-lane-apply-receipt@v1',
            status: 'succeeded',
            summary: { selectedBundleId: 'hosted-plus-manual-linux-docker' },
            validateDispatch: {
              status: 'dry-run',
              repository: null,
              remote: null,
              ref: options.ref,
              sampleIdStrategy: options.sampleIdStrategy,
              sampleId: options.sampleId,
              historyScenarioSet: options.historyScenarioSet,
              allowFork: options.allowFork,
              pushMissing: options.pushMissing,
              forcePushOk: options.forcePushOk,
              allowNonCanonicalViHistory: options.allowNonCanonicalViHistory,
              allowNonCanonicalHistoryCore: options.allowNonCanonicalHistoryCore,
              reportPath: null,
              runDatabaseId: null,
              error: null
            }
          },
          outputPath: path.join(tempRepo, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-apply-receipt.json'),
          error: null
        };
      },
      observeConcurrentLaneStatusFn: async () => ({
        receipt: {
          schema: 'priority/concurrent-lane-status-receipt@v1',
          status: 'active',
          applyReceipt: {
            path: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
            schema: 'priority/concurrent-lane-apply-receipt@v1',
            status: 'succeeded',
            selectedBundleId: 'hosted-plus-manual-linux-docker'
          },
          hostedRun: {
            observationStatus: 'active',
            runId: null,
            url: null,
            reportPath: null
          },
          pullRequest: {
            observationStatus: 'not-requested',
            number: null,
            url: null,
            mergeQueue: {
              status: 'not-requested',
              position: null,
              estimatedTimeToMerge: null,
              enqueuedAt: null
            }
          },
          summary: {
            selectedBundleId: 'hosted-plus-manual-linux-docker',
            laneCount: 2,
            activeLaneCount: 1,
            completedLaneCount: 0,
            failedLaneCount: 0,
            deferredLaneCount: 1,
            manualLaneCount: 1,
            shadowLaneCount: 0,
            pullRequestStatus: 'not-requested',
            orchestratorDisposition: 'wait-hosted-run'
          }
        },
        outputPath: path.join(tempRepo, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-status-receipt.json')
      })
    }
  });

  assert.equal(applyCalls.length, 1);
  assert.equal(applyCalls[0].historyScenarioSet, 'history-core');
  assert.equal(applyCalls[0].sampleIdStrategy, 'explicit');
  assert.equal(applyCalls[0].sampleId, 'ts-20260321-123456-zzzz');
  assert.equal(applyCalls[0].allowFork, true);
  assert.equal(applyCalls[0].pushMissing, false);
  assert.equal(applyCalls[0].allowNonCanonicalViHistory, true);
  assert.equal(applyCalls[0].allowNonCanonicalHistoryCore, true);
});

test('persistDeliveryAgentRuntimeState keeps deferred concurrent lane obligations visible after releasing the worker slot', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'delivery-concurrent-status-runtime-'));
  const persisted = await persistDeliveryAgentRuntimeState({
    repoRoot,
    runtimeDir,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 4,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true,
      workerPool: {
        targetSlotCount: 4,
        prewarmSlotCount: 1,
        releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
        providers: [
          {
            id: 'local-codex',
            kind: 'local-codex',
            executionPlane: 'local',
            assignmentMode: 'interactive-coding',
            dispatchSurface: 'runtime-harness',
            completionMode: 'sync',
            requiresLocalCheckout: true,
            enabled: true,
            slotCount: 1
          }
        ]
      }
    },
    schedulerDecision: {
      outcome: 'selected',
      activeLane: {
        laneId: 'origin-1589',
        issue: 1589,
        branch: 'issue/origin-1589-consume-concurrent-lane-status',
        forkRemote: 'origin'
      },
      artifacts: {
        laneLifecycle: 'coding'
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      laneId: 'origin-1589',
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2'
        },
        delivery: {
          laneLifecycle: 'waiting-ci',
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          concurrentLaneApply: {
            receiptPath: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
            status: 'succeeded',
            selectedBundleId: 'hosted-plus-host-native-32-shadow',
            validateDispatch: {
              status: 'dispatched',
              repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              remote: 'origin',
              ref: 'issue/origin-1589-consume-concurrent-lane-status',
              sampleId: 'ts-20260321-000000-abcd',
              historyScenarioSet: 'smoke',
              reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-origin-1589.json',
              runDatabaseId: 234567891,
              error: null
            }
          },
          concurrentLaneStatus: {
            receiptPath: 'tests/results/_agent/runtime/concurrent-lane-status-receipt.json',
            status: 'settled',
            selectedBundleId: 'hosted-plus-host-native-32-shadow',
            hostedRun: {
              observationStatus: 'completed',
              runId: 234567891,
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/234567891',
              reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-upstream-1482.json'
            },
            pullRequest: {
              observationStatus: 'not-requested',
              number: null,
              url: null,
              mergeQueue: {
                status: 'not-requested',
                position: null,
                estimatedTimeToMerge: null,
                enqueuedAt: null
              }
            },
            summary: {
              laneCount: 3,
              activeLaneCount: 0,
              completedLaneCount: 2,
              failedLaneCount: 0,
              deferredLaneCount: 1,
              manualLaneCount: 0,
              shadowLaneCount: 1,
              pullRequestStatus: 'not-requested',
              orchestratorDisposition: 'release-with-deferred-local'
            }
          }
        }
      }
    },
    executionReceipt: {
      issue: 1589,
      outcome: 'waiting-ci',
      reason: 'Only deferred manual or shadow lane obligations remain locally, so the coding slot can be reused.',
      details: {
        actionType: 'watch-concurrent-lanes',
        laneLifecycle: 'waiting-ci',
        blockerClass: 'none',
        retryable: true,
        nextWakeCondition: 'deferred-local-lane-dispatched',
        workerSlotId: 'worker-slot-2',
        concurrentLaneApply: {
          receiptPath: 'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json',
          status: 'succeeded',
          selectedBundleId: 'hosted-plus-host-native-32-shadow',
          validateDispatch: {
            status: 'dispatched',
            repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
            remote: 'origin',
            ref: 'issue/origin-1589-consume-concurrent-lane-status',
            sampleId: 'ts-20260321-000000-abcd',
            historyScenarioSet: 'smoke',
            reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-origin-1589.json',
            runDatabaseId: 234567891,
            error: null
          }
        },
        concurrentLaneStatus: {
          receiptPath: 'tests/results/_agent/runtime/concurrent-lane-status-receipt.json',
          status: 'settled',
          selectedBundleId: 'hosted-plus-host-native-32-shadow',
          hostedRun: {
            observationStatus: 'completed',
            runId: 234567891,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/234567891',
            reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-upstream-1482.json'
          },
          pullRequest: {
            observationStatus: 'not-requested',
            number: null,
            url: null,
            mergeQueue: {
              status: 'not-requested',
              position: null,
              estimatedTimeToMerge: null,
              enqueuedAt: null
            }
          },
          summary: {
            laneCount: 3,
            activeLaneCount: 0,
            completedLaneCount: 2,
            failedLaneCount: 0,
            deferredLaneCount: 1,
            manualLaneCount: 0,
            shadowLaneCount: 1,
            pullRequestStatus: 'not-requested',
            orchestratorDisposition: 'release-with-deferred-local'
          }
        }
      }
    },
    collectMarketplaceSnapshotFn: async () => ({
      schema: 'priority/lane-marketplace-snapshot@v1',
      generatedAt: '2026-03-21T10:00:00.000Z',
      summary: {
        repositoryCount: 0,
        laneCount: 0
      },
      repositories: []
    }),
    writeMarketplaceSnapshotFn: async () => 'tests/results/_agent/runtime/lane-marketplace-snapshot.json',
    selectMarketplaceRecommendationFn: () => null
  });
  const persistedState = persisted.payload;

  assert.equal(persistedState.workerPool.releasedLaneCount, 1);
  assert.equal(persistedState.workerPool.releasedLanes[0].slotId, 'worker-slot-2');
  assert.equal(persistedState.activeLane.laneLifecycle, 'waiting-ci');
  assert.equal(
    persistedState.activeLane.concurrentLaneApply.receiptPath,
    'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json'
  );
  assert.equal(
    persistedState.activeLane.concurrentLaneApply.validateDispatch.runDatabaseId,
    234567891
  );
  assert.equal(
    persistedState.activeLane.concurrentLaneStatus.summary.orchestratorDisposition,
    'release-with-deferred-local'
  );
  assert.equal(persistedState.activeLane.concurrentLaneStatus.summary.shadowLaneCount, 1);
  assert.equal(persistedState.activeLane.executionTopology.status, 'logical-lanes-tracked');
  assert.equal(persistedState.activeLane.executionTopology.executionPlane, null);
  assert.equal(persistedState.activeLane.executionTopology.providerId, null);
  assert.equal(persistedState.activeLane.executionTopology.workerSlotId, null);
  assert.equal(persistedState.activeLane.executionTopology.cellId, null);
  assert.equal(persistedState.activeLane.executionTopology.laneId, null);
  assert.equal(persistedState.activeLane.executionTopology.cellClass, null);
  assert.equal(persistedState.activeLane.executionTopology.suiteClass, null);
  assert.equal(persistedState.activeLane.executionTopology.planeBinding, null);
  assert.equal(persistedState.activeLane.executionTopology.harnessKind, null);
  assert.equal(persistedState.activeLane.executionTopology.harnessInstanceId, null);
  assert.equal(persistedState.activeLane.executionTopology.executionCellLeaseId, null);
  assert.equal(persistedState.activeLane.executionTopology.dockerLaneLeaseId, null);
  assert.equal(persistedState.activeLane.executionTopology.premiumSaganMode, false);
  assert.equal(persistedState.activeLane.executionTopology.reciprocalLinkReady, false);
  assert.equal(persistedState.activeLane.executionTopology.operatorAuthorizationRef, null);
  assert.equal(persistedState.activeLane.executionTopology.activeLogicalLaneCount, 4);
  assert.equal(persistedState.activeLane.executionTopology.seededLogicalLaneCount, 4);
  assert.equal(persistedState.activeLane.executionTopology.runtimeSurface, null);
  assert.equal(persistedState.activeLane.executionTopology.processModelClass, null);
  assert.equal(persistedState.activeLane.executionTopology.windowsOnly, false);
  assert.equal(persistedState.activeLane.executionTopology.requestedSimultaneous, false);
  assert.equal(
    persistedState.artifacts.concurrentLaneApplyReceiptPath,
    'tests/results/_agent/runtime/concurrent-lane-apply-receipt.json'
  );
  assert.equal(
    persistedState.artifacts.concurrentLaneStatusReceiptPath,
    'tests/results/_agent/runtime/concurrent-lane-status-receipt.json'
  );
});

test('draft review clearance diagnostics report actionable current-head items', () => {
  const source = readFileSync(new URL('../delivery-agent.mjs', import.meta.url), 'utf8');
  assert.match(source, /reasons\.push\('actionable-current-head-items'\)/);
});

test('buildCompareviTaskPacket projects live-agent model selection for the selected provider', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-live-agent-model-selection-'));
  const policyPath = path.join(tempDir, 'live-agent-model-selection.json');
  const reportPath = path.join(tempDir, 'live-agent-model-selection-report.json');
  await writeFile(
    policyPath,
    `${JSON.stringify({
      schema: 'priority/live-agent-model-selection-policy@v1',
      mode: 'recommend-only',
      outputPath: reportPath,
      previousReportPath: reportPath,
      inputs: {
        costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
        throughputScorecardPath: 'tests/results/_agent/throughput/throughput-scorecard.json',
        deliveryMemoryPath: 'tests/results/_agent/runtime/delivery-memory.json'
      },
      evidenceWindow: {
        minLiveTurnCount: 1,
        minTerminalPullRequests: 1,
        confidenceThreshold: 'medium'
      },
      stability: {
        cooldownReports: 1,
        hysteresisScoreDelta: 0.5,
        holdCurrentOnCostOnly: true,
        performancePressureOverridesCooldown: true,
        throughputWarnEscalates: true,
        meanTerminalDurationWarningMinutes: 180,
        minMergeSuccessRatio: 0.6,
        maxHostedWaitEscapeCount: 0
      },
      providers: [
        {
          providerId: 'local-codex',
          agentRole: 'live',
          defaultModel: 'gpt-5.4',
          candidateModels: [
            { model: 'gpt-5.4-mini', strength: 1, costTier: 1, notes: 'cheaper' },
            { model: 'gpt-5.4', strength: 2, costTier: 2, notes: 'stronger' }
          ]
        }
      ]
    }, null, 2)}\n`,
    'utf8'
  );
  await writeFile(
    reportPath,
    `${JSON.stringify({
      schema: 'priority/live-agent-model-selection-report@v1',
      generatedAt: '2026-03-21T14:00:00.000Z',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      mode: 'recommend-only',
      policyPath: 'tools/policy/live-agent-model-selection.json',
      inputs: {
        costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
        throughputScorecardPath: 'tests/results/_agent/throughput/throughput-scorecard.json',
        deliveryMemoryPath: 'tests/results/_agent/runtime/delivery-memory.json',
        previousReportPath: 'tests/results/_agent/runtime/live-agent-model-selection.json'
      },
      providers: [
        {
          providerId: 'local-codex',
          providerKind: 'local-codex',
          agentRole: 'live',
          currentModel: 'gpt-5.4',
          selectedModel: 'gpt-5.4',
          action: 'stay',
          recommendationSource: 'current-model-hold',
          mode: 'recommend-only',
          confidence: 'medium',
          reasonCodes: ['stable-current-model'],
          evidence: {
            turnCount: 3,
            observedModels: ['gpt-5.4'],
            totalUsd: 24,
            averageUsdPerTurn: 8,
            throughputStatus: 'pass',
            throughputReasons: [],
            queueReadyPrInventory: 2,
            queueOccupancyRatio: 1,
            totalTerminalPullRequestCount: 3,
            mergedPullRequestCount: 3,
            mergeSuccessRatio: 1,
            hostedWaitEscapeCount: 0,
            meanTerminalDurationMinutes: 14,
            performancePressure: false,
            performancePressureReasons: []
          },
          candidates: [
            { model: 'gpt-5.4-mini', strength: 1, costTier: 1, notes: 'cheaper', score: 0 },
            { model: 'gpt-5.4', strength: 2, costTier: 2, notes: 'stronger', score: 1.25 }
          ],
          blockers: [],
          stability: {
            cooldownRemainingReports: 0,
            previousSelectedModel: 'gpt-5.4',
            previousAction: 'stay',
            previousGeneratedAt: '2026-03-20T14:00:00.000Z'
          }
        }
      ],
      summary: {
        status: 'pass',
        blockerCount: 0,
        blockers: [],
        recommendationCount: 1,
        switchCount: 0,
        overrideCount: 0,
        holdCount: 0,
        insufficientEvidenceCount: 0,
        recommendationMode: 'recommend-only'
      }
    }, null, 2)}\n`,
    'utf8'
  );

  const packet = await compareviRuntimeTest.buildCompareviTaskPacket({
    repoRoot,
    schedulerDecision: {
      activeLane: {
        issue: 1640,
        branch: 'issue/origin-1640-live-agent-model-selection-telemetry',
        forkRemote: 'origin'
      },
      artifacts: {
        executionMode: 'canonical-delivery',
        selectedActionType: 'advance-child-issue',
        laneLifecycle: 'coding',
        selectedIssueSnapshot: {
          number: 1640,
          title: 'Drive deterministic live-agent model selection from telemetry',
          body: 'Model selection slice.',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1640'
        },
        standingIssueSnapshot: {
          number: 1640,
          title: 'Drive deterministic live-agent model selection from telemetry',
          body: 'Model selection slice.',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1640'
        }
      }
    },
    preparedWorker: {
      checkoutPath: '/tmp/worker',
      providerId: 'local-codex',
      slotId: 'worker-slot-1'
    },
    workerReady: {
      checkoutPath: '/tmp/worker',
      providerId: 'local-codex',
      slotId: 'worker-slot-1'
    },
    workerBranch: {
      branch: 'issue/origin-1640-live-agent-model-selection-telemetry',
      checkoutPath: '/tmp/worker',
      providerId: 'local-codex',
      slotId: 'worker-slot-1'
    },
    deps: {
      liveAgentModelSelectionPolicyPath: policyPath,
      liveAgentModelSelectionReportPath: reportPath
    }
  });

assert.equal(packet.evidence.delivery.liveAgentModelSelection.mode, 'recommend-only');
assert.equal(packet.evidence.delivery.liveAgentModelSelection.currentProvider.providerId, 'local-codex');
assert.equal(packet.evidence.delivery.liveAgentModelSelection.currentProvider.selectedModel, 'gpt-5.4');
assert.deepEqual(packet.evidence.delivery.liveAgentModelSelection.currentProvider.reasonCodes, ['stable-current-model']);
});

test('comparevi planner keeps the current matching standing branch as the authoritative lane branch', async () => {
  const decision = await compareviRuntimeTest.planCompareviRuntimeStep({
    repoRoot: '/tmp/repo',
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    options: {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    explicitStepOptions: {},
    deps: {
      loadBranchClassContractFn: () => makeLaneBranchClassContract(),
      execFileFn: async (command, args) => {
        if (command === 'git' && args[0] === 'branch' && args[1] === '--show-current') {
          return {
            stdout: 'issue/upstream-1830-authoritative-worker-branch-head\n',
            stderr: ''
          };
        }
        return { stdout: '', stderr: '' };
      },
      resolveStandingPriorityForRepoFn: async () => ({
        found: {
          number: 1830,
          label: 'standing-priority',
          repoSlug: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          source: 'gh'
        }
      }),
      ghIssueFetcher: async () => ({
        number: 1830,
        title: '[delivery]: resolve worker checkout to authoritative standing branch head',
        state: 'open',
        updatedAt: '2026-03-22T00:00:00Z',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1830',
        labels: [{ name: 'standing-priority' }],
        assignees: [],
        milestone: null,
        comments: 0,
        body: 'Body'
      }),
      restIssueFetcher: async () => null
    }
  });

  assert.equal(decision.source, 'comparevi-standing-priority-live');
  assert.equal(decision.stepOptions.issue, 1830);
  assert.equal(decision.stepOptions.branch, 'issue/upstream-1830-authoritative-worker-branch-head');
  assert.equal(decision.stepOptions.forkRemote, 'upstream');
  assert.equal(decision.stepOptions.lane, 'upstream-1830');
  assert.equal(decision.artifacts.authoritativeCurrentBranch, 'issue/upstream-1830-authoritative-worker-branch-head');
  assert.equal(decision.artifacts.authoritativeCurrentBranchSource, 'repo-root-current-branch');
});

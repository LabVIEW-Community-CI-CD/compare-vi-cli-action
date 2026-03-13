#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildDeliveryAgentRuntimeRecord, loadDeliveryAgentPolicy } from '../delivery-agent.mjs';
import { buildDeliveryMemoryReport } from '../delivery-memory.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

async function loadSchema(relativePath) {
  return JSON.parse(await readFile(path.join(repoRoot, relativePath), 'utf8'));
}

function makeAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

test('delivery-agent policy schema validates the checked-in policy contract', async () => {
  const schema = await loadSchema('docs/schemas/delivery-agent-policy-v1.schema.json');
  const data = JSON.parse(await readFile(path.join(repoRoot, 'tools/priority/delivery-agent.policy.json'), 'utf8'));
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(data), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(data.copilotReviewStrategy, 'draft-only-explicit');
  assert.deepEqual(data.hostIsolation, {
    mode: 'hard-cutover',
    wslDistro: 'Ubuntu',
    runnerServicePolicy: 'stop-all-actions-runner-services',
    restoreRunnerServicesOnExit: true,
    pauseOnFingerprintDrift: true
  });
  assert.deepEqual(data.dockerRuntime, {
    provider: 'native-wsl',
    dockerHost: 'unix:///var/run/docker.sock',
    expectedOsType: 'linux',
    expectedContext: '',
    manageDockerEngine: false,
    allowHostEngineMutation: false
  });
  assert.deepEqual(data.localReviewLoop, {
    enabled: true,
    bodyMarkers: ['Daemon-first local iteration extension'],
    receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
    command: ['node', 'tools/local-collab/orchestrator/run-phase.mjs', '--phase', 'daemon'],
    actionlint: true,
    markdownlint: true,
    docs: true,
    workflow: true,
    dotnetCliBuild: true,
    requirementsVerification: true,
    niLinuxReviewSuite: true,
    singleViHistory: {
      enabled: false,
      targetPath: '',
      branchRef: 'develop',
      baselineRef: '',
      maxCommitCount: 256
    }
  });
});

test('loadDeliveryAgentPolicy fails closed on unsupported copilot review strategies', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-policy-invalid-'));
  const policyDir = path.join(repoRoot, 'tools', 'priority');
  await mkdir(policyDir, { recursive: true });
  await writeFile(
    path.join(policyDir, 'delivery-agent.policy.json'),
    JSON.stringify({
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'disabled',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    }),
    'utf8'
  );

  await assert.rejects(
    loadDeliveryAgentPolicy(repoRoot),
    /Unsupported copilotReviewStrategy: disabled/
  );
});

test('runtime delivery task packet schema validates canonical delivery packets', async () => {
  const schema = await loadSchema('docs/schemas/runtime-delivery-task-packet-v1.schema.json');
  const packet = {
    schema: 'priority/runtime-worker-task-packet@v1',
    generatedAt: '2026-03-11T08:00:00.000Z',
    cycle: 1,
    laneId: 'origin-1012',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'coding',
    objective: {
      summary: 'Advance issue #1012',
      source: 'comparevi-runtime'
    },
    evidence: {
      delivery: {
        executionMode: 'canonical-delivery',
        laneLifecycle: 'coding',
        selectedActionType: 'advance-child-issue',
        standingIssue: {
          number: 1010,
          title: 'Epic: Linux-first unattended delivery runtime',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010'
        },
        selectedIssue: {
          number: 1012,
          title: 'Wire canonical delivery broker',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1012'
        },
        localReviewLoop: {
          requested: true,
          source: 'standing-issue-body',
          standingIssueNumber: 1010,
          standingIssueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010',
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          actionlint: true,
          markdownlint: true,
          docs: true,
          workflow: true,
          dotnetCliBuild: true,
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
          backlogAuthority: 'issues',
          implementationRemote: 'origin',
          copilotReviewStrategy: 'draft-only-explicit',
          readyForReviewPurpose: 'final-validation',
          allowPolicyMutations: false,
          allowReleaseAdmin: false,
          maxActiveCodingLanes: 1
        },
        turnBudget: {
          maxMinutes: 20,
          maxToolCalls: 12
        },
        relevantFiles: ['tools/priority/runtime-supervisor.mjs']
      }
    }
  };
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(packet), true, JSON.stringify(validate.errors, null, 2));
});

test('runtime delivery execution receipt schema validates broker receipts', async () => {
  const schema = await loadSchema('docs/schemas/runtime-delivery-execution-receipt-v1.schema.json');
  const receipt = {
    schema: 'priority/runtime-execution-receipt@v1',
    generatedAt: '2026-03-11T08:05:00.000Z',
    cycle: 1,
    runtimeAdapter: 'comparevi',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    laneId: 'origin-1012',
    issue: 1012,
    status: 'completed',
    outcome: 'merged',
    source: 'delivery-agent-broker',
    stopLoop: false,
    details: {
      actionType: 'merge-pr',
      laneLifecycle: 'complete',
      blockerClass: 'none',
      retryable: false,
      nextWakeCondition: 'next-scheduler-cycle',
      helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
      filesTouched: []
    }
  };
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(receipt), true, JSON.stringify(validate.errors, null, 2));
});

test('delivery-agent runtime state schema validates persisted runtime state', async () => {
  const schema = await loadSchema('docs/schemas/delivery-agent-runtime-state-v1.schema.json');
  const state = buildDeliveryAgentRuntimeRecord({
    now: new Date('2026-03-11T08:10:00.000Z'),
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: path.join(repoRoot, 'tests/results/_agent/runtime'),
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 1,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true
    },
    schedulerDecision: {
      outcome: 'selected',
      activeLane: {
        laneId: 'origin-1012',
        issue: 1012,
        epic: 1010,
        forkRemote: 'origin',
        branch: 'issue/origin-1012-wire-canonical-delivery-broker',
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88',
        blockerClass: 'none'
      },
      artifacts: {
        selectedActionType: 'existing-pr-unblock',
        laneLifecycle: 'ready-merge'
      }
    },
    taskPacket: {
      laneId: 'origin-1012',
      branch: {
        name: 'issue/origin-1012-wire-canonical-delivery-broker',
        forkRemote: 'origin'
      },
      pullRequest: {
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/88'
      },
      checks: {
        blockerClass: 'none'
      },
      evidence: {
        delivery: {
          laneLifecycle: 'ready-merge',
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
              baselineRef: '',
              maxCommitCount: 256
            }
          }
        }
      }
    },
    executionReceipt: {
      outcome: 'merged',
      reason: 'Merged PR #88.',
      details: {
        actionType: 'merge-pr',
        laneLifecycle: 'complete',
        blockerClass: 'none',
        retryable: false,
        nextWakeCondition: 'next-scheduler-cycle',
        localReviewLoop: {
          status: 'passed',
          source: 'docker-desktop-review-loop',
          reason: 'Docker/Desktop review loop passed.',
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          currentHeadSha: '433e8aa70326007be74c27ccf54c1ae91559b6f3',
          receiptHeadSha: '433e8aa70326007be74c27ccf54c1ae91559b6f3',
          receiptFreshForHead: true,
          requestedCoverageSatisfied: true,
          requestedCoverageReason: 'Docker/Desktop review loop receipt covers the requested review surfaces.',
          requestedCoverageMissingChecks: [],
          receipt: {
            git: {
              headSha: '433e8aa70326007be74c27ccf54c1ae91559b6f3',
              branch: 'issue/origin-1053-agent-verification-receipt',
              upstreamDevelopMergeBase: 'ccbdc75d4bfbcbe6580abb989b2d4e819e1a1e99',
              dirtyTracked: false
            },
            overall: {
              status: 'passed',
              failedCheck: '',
              message: '',
              exitCode: 0
            },
            artifacts: {
              reviewLoopReceiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
              agentVerificationSummaryPath: 'tests/results/_agent/verification/docker-review-loop-summary.json',
              historyReviewReceiptPath: 'tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-review-loop-receipt.json',
              requirementsSummaryPath: 'tests/results/docker-tools-parity/requirements-verification/verification-summary.json'
            },
            niLinuxHistoryReview: {
              targetPath: 'fixtures/vi-attr/Head.vi',
              effectiveBranchRef: 'develop',
              maxCommitCount: 256,
              touchAware: true
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
    },
    statePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-state.json'),
    lanePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-lanes/origin-1012.json')
  });
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(state), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(state.policy.copilotReviewStrategy, 'draft-only-explicit');
  assert.equal(state.localReviewLoop.status, 'passed');
  assert.equal(state.localReviewLoop.receiptStatus, 'passed');
  assert.equal(state.localReviewLoop.currentHeadSha, '433e8aa70326007be74c27ccf54c1ae91559b6f3');
  assert.equal(state.localReviewLoop.receiptHeadSha, '433e8aa70326007be74c27ccf54c1ae91559b6f3');
  assert.equal(state.localReviewLoop.receiptFreshForHead, true);
  assert.equal(state.localReviewLoop.requestedCoverageSatisfied, true);
  assert.equal(state.localReviewLoop.requestedCoverageReason, 'Docker/Desktop review loop receipt covers the requested review surfaces.');
  assert.deepEqual(state.localReviewLoop.requestedCoverageMissingChecks, []);
  assert.equal(state.localReviewLoop.niLinuxReviewSuiteRequested, true);
  assert.equal(state.localReviewLoop.singleViHistory.targetPath, 'fixtures/vi-attr/Head.vi');
  assert.equal(state.localReviewLoop.git.branch, 'issue/origin-1053-agent-verification-receipt');
  assert.equal(
    state.localReviewLoop.artifacts.agentVerificationSummaryPath,
    'tests/results/_agent/verification/docker-review-loop-summary.json'
  );
  assert.equal(
    state.localReviewLoop.artifacts.historyReviewReceiptPath,
    'tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-review-loop-receipt.json'
  );
  assert.equal(state.activeLane.localReviewLoop.receiptStatus, 'passed');
  assert.equal(
    state.artifacts.localReviewLoopReceiptPath,
    'tests/results/docker-tools-parity/review-loop-receipt.json'
  );
});

test('delivery memory schema validates suite-aware terminal PR history', async () => {
  const schema = await loadSchema('docs/schemas/delivery-memory-v1.schema.json');
  const report = buildDeliveryMemoryReport({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: 'tests/results/_agent/runtime',
    taskPackets: [
      {
        generatedAt: '2026-03-11T08:00:00.000Z',
        laneId: 'origin-1011',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        objective: {
          summary: 'Advance issue #1011: deliver the VI History Suite'
        },
        branch: {
          name: 'issue/origin-1011-vi-history-suite'
        },
        pullRequest: {
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/500'
        },
        evidence: {
          delivery: {
            selectedIssue: {
              number: 1011
            }
          }
        }
      }
    ],
    executionReceipts: [
      {
        generatedAt: '2026-03-11T08:10:00.000Z',
        laneId: 'origin-1011',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        issue: 1011,
        status: 'completed',
        outcome: 'merged',
        reason: 'Merged PR #500.',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'complete',
          blockerClass: 'none',
          retryable: false,
          nextWakeCondition: 'next-scheduler-cycle',
          helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
          filesTouched: ['tools/Test-PRVIHistorySmoke.ps1']
        }
      }
    ],
    now: new Date('2026-03-11T08:15:00.000Z')
  });
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

test('delivery agent runtime state schema accepts legacy policy payloads without copilotReviewStrategy', async () => {
  const schema = await loadSchema('docs/schemas/delivery-agent-runtime-state-v1.schema.json');
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  const state = {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: '2026-03-13T19:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: 'tests/results/_agent/runtime',
    status: 'running',
    laneLifecycle: 'waiting-review',
    activeCodingLanes: 0,
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      implementationRemote: 'origin',
      maxActiveCodingLanes: 1
    },
    activeLane: {
      schema: 'priority/delivery-agent-lane-state@v1',
      laneId: 'origin-1067',
      laneLifecycle: 'waiting-review',
      blockerClass: 'review'
    }
  };
  assert.equal(validate(state), true, JSON.stringify(validate.errors, null, 2));
});

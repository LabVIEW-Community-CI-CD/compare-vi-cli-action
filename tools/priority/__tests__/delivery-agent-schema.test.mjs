#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import {
  buildDeliveryAgentRuntimeRecord,
  buildWorkerProviderSelectionRequest,
  loadDeliveryAgentPolicy,
  persistDeliveryAgentRuntimeState,
  selectWorkerProviderAssignment
} from '../delivery-agent.mjs';
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

function buildLogicalLaneCatalog(count = 20) {
  return Array.from({ length: count }, (_, index) => {
    const seededOrdinal = index + 1;
    const ordinal = String(seededOrdinal).padStart(2, '0');
    return {
      id: `logical-lane-${ordinal}`,
      label: `Lane ${ordinal}`,
      seededOrdinal
    };
  });
}

test('delivery-agent policy schema validates the checked-in policy contract', async () => {
  const schema = await loadSchema('docs/schemas/delivery-agent-policy-v1.schema.json');
  const data = JSON.parse(await readFile(path.join(repoRoot, 'tools/priority/delivery-agent.policy.json'), 'utf8'));
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(data), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(data.copilotReviewStrategy, 'draft-only-explicit');
  assert.equal(data.maxActiveCodingLanes, 20);
  assert.deepEqual(data.capitalFabric, {
    schema: 'priority/capital-deployment-fabric@v1',
    capacityMode: 'host-ram-adaptive',
    maxLogicalLaneCount: 20,
    logicalLaneAllocationFloorRatio: 0.5,
    reservedLaneCount: 1,
    hostRamBudgetPath: 'tests/results/_agent/runtime/host-ram-budget.json',
    logicalLaneCatalog: buildLogicalLaneCatalog(),
    specialtyLanes: [
      {
        id: 'jarvis',
        enabled: true,
        primaryRecordedResponsibility: 'Sagan',
        maxInstanceCount: 2,
        purpose: 'windows-docker-iterative-development',
        preferredExecutionPlane: 'local-docker-windows',
        preferredContainerImage: 'nationalinstruments/labview:2026q1-windows',
        allocationMode: 'opportunistic'
      }
    ]
  });
  assert.deepEqual(data.storageRoots, {
    worktrees: {
      envVar: 'COMPAREVI_BURST_WORKTREE_ROOT',
      preferredRoots: ['E:\\comparevi-lanes']
    },
    artifacts: {
      envVar: 'COMPAREVI_BURST_ARTIFACT_ROOT',
      preferredRoots: ['E:\\comparevi-artifacts']
    }
  });
  assert.deepEqual(data.workerPool, {
    targetSlotCount: 20,
    prewarmSlotCount: 1,
    releaseWaitingStates: ['waiting-ci', 'waiting-review', 'ready-merge'],
    providers: [
      {
        id: 'local-codex',
        kind: 'local-codex',
        capabilities: {
          executionPlane: 'local',
          assignmentMode: 'interactive-coding',
          dispatchSurface: 'runtime-harness',
          completionMode: 'sync',
          requiresLocalCheckout: true
        },
        executionPlane: 'local',
        assignmentMode: 'interactive-coding',
        dispatchSurface: 'runtime-harness',
        completionMode: 'sync',
        requiresLocalCheckout: true,
        enabled: true,
        slotCount: 2
      },
      {
        id: 'hosted-github-workflow',
        kind: 'hosted-github-workflow',
        capabilities: {
          executionPlane: 'hosted',
          assignmentMode: 'async-validation',
          dispatchSurface: 'github-actions',
          completionMode: 'async',
          requiresLocalCheckout: false
        },
        executionPlane: 'hosted',
        assignmentMode: 'async-validation',
        dispatchSurface: 'github-actions',
        completionMode: 'async',
        requiresLocalCheckout: false,
        enabled: true,
        slotCount: 2
      },
      {
        id: 'remote-copilot-lane',
        kind: 'remote-copilot-lane',
        capabilities: {
          executionPlane: 'remote',
          assignmentMode: 'remote-implementation',
          dispatchSurface: 'remote-copilot',
          completionMode: 'async',
          requiresLocalCheckout: false
        },
        executionPlane: 'remote',
        assignmentMode: 'remote-implementation',
        dispatchSurface: 'remote-copilot',
        completionMode: 'async',
        requiresLocalCheckout: false,
        enabled: true,
        slotCount: 2
      },
      {
        id: 'local-shadow-native',
        kind: 'local-shadow-native',
        capabilities: {
          executionPlane: 'local-shadow',
          assignmentMode: 'shadow-validation',
          dispatchSurface: 'native-shadow',
          completionMode: 'sync',
          requiresLocalCheckout: false
        },
        executionPlane: 'local-shadow',
        assignmentMode: 'shadow-validation',
        dispatchSurface: 'native-shadow',
        completionMode: 'sync',
        requiresLocalCheckout: false,
        enabled: true,
        slotCount: 2
      }
    ]
  });
  assert.deepEqual(data.templateAgentVerificationLane, {
    enabled: true,
    reservedSlotCount: 1,
    minimumImplementationSlots: 3,
    executionMode: 'hosted-first',
    targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    consumerRailBranch: 'downstream/develop',
    reportPath: 'tests/results/_agent/promotion/template-agent-verification-report.json',
    authoritativeReportPath: 'template-verification/template-agent-verification-report.json',
    metrics: {
      maxVerificationLagIterations: 1,
      maxHostedDurationMinutes: 30,
      requireMachineReadableRecommendation: true
    }
  });
  assert.equal(
    data.workerPool.targetSlotCount - data.templateAgentVerificationLane.reservedSlotCount,
    19
  );
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
  assert.deepEqual(data.concurrentLaneDispatch, {
    historyScenarioSet: 'smoke',
    sampleIdStrategy: 'auto',
    sampleId: '',
    allowForkMode: 'auto',
    pushMissing: true,
    forcePushOk: false,
    allowNonCanonicalViHistory: false,
    allowNonCanonicalHistoryCore: false
  });
  assert.deepEqual(data.localReviewLoop, {
    enabled: true,
    reviewProviders: ['copilot-cli'],
    copilotCliReview: true,
    copilotCliReviewConfig: {
      enabled: true,
      model: 'gpt-5.4',
      promptOnly: true,
      disableBuiltinMcps: true,
      allowAllTools: false,
      availableTools: '',
      sessionPolicy: {
        reuse: 'fresh-per-head',
        scope: 'current-head',
        recordPromptArtifacts: true
      }
    },
    bodyMarkers: ['Daemon-first local iteration extension'],
    receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
    command: ['node', 'tools/local-collab/orchestrator/run-phase.mjs', '--phase', 'daemon'],
    actionlint: true,
    markdownlint: true,
    docs: true,
    workflow: true,
    dotnetCliBuild: true,
    codexCliReview: false,
    codexCliReviewConfig: {
      enabled: false,
      distro: 'Ubuntu',
      executionPlane: 'wsl2',
      sandbox: 'read-only',
      model: '',
      ephemeral: true
    },
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

test('loadDeliveryAgentPolicy keeps provider capabilities independent from target slot count when defaults are synthesized', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-policy-provider-capabilities-'));
  const policyDir = path.join(tempRoot, 'tools', 'priority');
  await mkdir(policyDir, { recursive: true });
  await writeFile(
    path.join(policyDir, 'delivery-agent.policy.json'),
    JSON.stringify({
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 6,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true,
      workerPool: {
        targetSlotCount: 6
      }
    }),
    'utf8'
  );

  const policy = await loadDeliveryAgentPolicy(tempRoot);
  assert.equal(policy.workerPool.targetSlotCount, 6);
  assert.equal(policy.workerPool.providers.length, 4);
  assert.equal(policy.concurrentLaneDispatch.historyScenarioSet, 'smoke');
  assert.equal(policy.concurrentLaneDispatch.pushMissing, true);
  assert.deepEqual(
    policy.workerPool.providers.map((provider) => provider.id),
    ['local-codex', 'hosted-github-workflow', 'remote-copilot-lane', 'local-shadow-native']
  );
  assert.deepEqual(policy.workerPool.providers[0].capabilities, {
    executionPlane: 'local',
    assignmentMode: 'interactive-coding',
    dispatchSurface: 'runtime-harness',
    completionMode: 'sync',
    requiresLocalCheckout: true
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

test('loadDeliveryAgentPolicy fails closed when concurrent lane dispatch requests an explicit sample id without a value', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-policy-invalid-concurrent-dispatch-'));
  const policyDir = path.join(repoRoot, 'tools', 'priority');
  await mkdir(policyDir, { recursive: true });
  await writeFile(
    path.join(policyDir, 'delivery-agent.policy.json'),
    JSON.stringify({
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
      concurrentLaneDispatch: {
        sampleIdStrategy: 'explicit',
        sampleId: ''
      }
    }),
    'utf8'
  );

  await assert.rejects(
    loadDeliveryAgentPolicy(repoRoot),
    /concurrentLaneDispatch\.sampleId is required when sampleIdStrategy is explicit/i
  );
});

test('loadDeliveryAgentPolicy fails closed on duplicate worker provider ids', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-policy-duplicate-provider-'));
  const policyDir = path.join(tempRoot, 'tools', 'priority');
  await mkdir(policyDir, { recursive: true });
  await writeFile(
    path.join(policyDir, 'delivery-agent.policy.json'),
    JSON.stringify({
      schema: 'priority/delivery-agent-policy@v1',
      backlogAuthority: 'issues',
      implementationRemote: 'origin',
      copilotReviewStrategy: 'draft-only-explicit',
      autoSlice: true,
      autoMerge: true,
      maxActiveCodingLanes: 2,
      allowPolicyMutations: false,
      allowReleaseAdmin: false,
      stopWhenNoOpenEpics: true,
      workerPool: {
        targetSlotCount: 2,
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
            id: 'local-codex',
            kind: 'remote-copilot-lane',
            executionPlane: 'remote',
            assignmentMode: 'remote-implementation',
            dispatchSurface: 'remote-copilot',
            completionMode: 'async',
            requiresLocalCheckout: false,
            enabled: true,
            slotCount: 1
          }
        ]
      }
    }),
    'utf8'
  );

  await assert.rejects(loadDeliveryAgentPolicy(tempRoot), /Duplicate workerPool provider id: local-codex/);
});

test('worker provider selection defaults to hosted async validation for hosted waiting states', () => {
  const selection = selectWorkerProviderAssignment({
    policy: {
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
          },
          {
            id: 'remote-copilot-lane',
            kind: 'remote-copilot-lane',
            executionPlane: 'remote',
            assignmentMode: 'remote-implementation',
            dispatchSurface: 'remote-copilot',
            completionMode: 'async',
            requiresLocalCheckout: false,
            enabled: true,
            slotCount: 1
          },
          {
            id: 'local-shadow-native',
            kind: 'local-shadow-native',
            executionPlane: 'local-shadow',
            assignmentMode: 'shadow-validation',
            dispatchSurface: 'native-shadow',
            completionMode: 'sync',
            requiresLocalCheckout: false,
            enabled: true,
            slotCount: 1
          }
        ]
      }
    },
    selection: buildWorkerProviderSelectionRequest({
      laneLifecycle: 'waiting-review',
      selectedActionType: 'existing-pr-unblock'
    }),
    preferredSlotId: 'worker-slot-2'
  });

  assert.equal(selection.requiredAssignmentMode, 'async-validation');
  assert.equal(selection.selectedProviderId, 'hosted-github-workflow');
  assert.equal(selection.selectedExecutionPlane, 'hosted');
  assert.equal(selection.requiresLocalCheckout, false);
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
      lane: {
        workerSlotId: 'worker-slot-2',
        workerProviderId: 'local-codex',
        workerCheckoutRoot: 'E:\\comparevi-lanes\\LabVIEW-Community-CI-CD--compare-vi-cli-action',
        workerCheckoutRootPolicy: {
          strategy: 'policy-preferred-root',
          source: 'delivery-agent.policy.json#storageRoots.worktrees.preferredRoots[0]',
          baseRoot: 'E:\\comparevi-lanes',
          relativeRoot: 'LabVIEW-Community-CI-CD--compare-vi-cli-action',
          usesExternalRoot: true
        },
        workerCheckoutPath: 'E:\\comparevi-lanes\\LabVIEW-Community-CI-CD--compare-vi-cli-action\\worker-slot-2'
      },
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
        planeTransition: {
          from: 'origin',
          to: 'upstream',
          action: 'promote',
          via: 'pull-request',
          branchClass: 'lane',
          sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
          targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
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
        },
        workerProviderSelection: {
          source: 'selected-action-default',
          laneLifecycle: 'coding',
          selectedActionType: 'advance-child-issue',
          requiredAssignmentMode: 'interactive-coding',
          preferredProviderIds: ['local-codex'],
          preferredExecutionPlanes: ['local'],
          eligibleProviderIds: ['local-codex'],
          selectedProviderId: 'local-codex',
          selectedProviderKind: 'local-codex',
          selectedExecutionPlane: 'local',
          selectedAssignmentMode: 'interactive-coding',
          dispatchSurface: 'runtime-harness',
          completionMode: 'sync',
          selectedSlotId: 'worker-slot-2',
          requiresLocalCheckout: true
        },
        mutationEnvelope: {
          backlogAuthority: 'issues',
          implementationRemote: 'origin',
          copilotReviewStrategy: 'draft-only-explicit',
          readyForReviewPurpose: 'final-validation',
          allowPolicyMutations: false,
          allowReleaseAdmin: false,
          maxActiveCodingLanes: 4
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

test('runtime delivery task packet schema fails closed when workerSlotId omits workerProviderId', async () => {
  const schema = await loadSchema('docs/schemas/runtime-delivery-task-packet-v1.schema.json');
  const packet = {
    schema: 'priority/runtime-worker-task-packet@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'coding',
    objective: {
      summary: 'Advance issue #1509'
    },
    evidence: {
      lane: {
        workerSlotId: 'worker-slot-1'
      },
      delivery: {
        executionMode: 'canonical-delivery',
        laneLifecycle: 'coding',
        mutationEnvelope: {
          implementationRemote: 'origin'
        },
        turnBudget: {
          maxMinutes: 20
        }
      }
    }
  };
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(packet), false);
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
      workerProviderSelection: {
        source: 'lane-lifecycle-default',
        laneLifecycle: 'ready-merge',
        selectedActionType: 'existing-pr-unblock',
        requiredAssignmentMode: 'async-validation',
        preferredProviderIds: ['hosted-github-workflow'],
        preferredExecutionPlanes: ['hosted'],
        eligibleProviderIds: ['hosted-github-workflow'],
        selectedProviderId: 'hosted-github-workflow',
        selectedProviderKind: 'hosted-github-workflow',
        selectedExecutionPlane: 'hosted',
        selectedAssignmentMode: 'async-validation',
        dispatchSurface: 'github-actions',
        completionMode: 'async',
        selectedSlotId: null,
        requiresLocalCheckout: false
      },
      providerDispatch: {
        providerId: 'hosted-github-workflow',
        providerKind: 'hosted-github-workflow',
        executionPlane: 'hosted',
        assignmentMode: 'async-validation',
        dispatchSurface: 'github-actions',
        completionMode: 'async',
        workerSlotId: null,
        dispatchStatus: 'completed',
        completionStatus: 'completed',
        failureClass: null
      },
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
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: path.join(repoRoot, 'tests/results/_agent/runtime'),
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
        laneLifecycle: 'ready-merge',
        canonicalRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      }
    },
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
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
        lane: {
          workerSlotId: 'worker-slot-2',
          workerProviderId: 'hosted-github-workflow',
          workerCheckoutRoot: path.join(repoRoot, '.runtime-worktrees', 'LabVIEW-Community-CI-CD--compare-vi-cli-action'),
          workerCheckoutRootPolicy: {
            strategy: 'repo-default',
            source: 'repo-default-runtime-worktree-root',
            baseRoot: path.join(repoRoot, '.runtime-worktrees'),
            relativeRoot: 'LabVIEW-Community-CI-CD--compare-vi-cli-action',
            usesExternalRoot: false
          },
          workerCheckoutPath: '.runtime-worktrees/LabVIEW-Community-CI-CD--compare-vi-cli-action/worker-slot-2'
        },
        delivery: {
          laneLifecycle: 'ready-merge',
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
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
          },
          workerProviderSelection: {
            source: 'lane-lifecycle-default',
            laneLifecycle: 'ready-merge',
            selectedActionType: 'existing-pr-unblock',
            requiredAssignmentMode: 'async-validation',
            preferredProviderIds: ['hosted-github-workflow'],
            preferredExecutionPlanes: ['hosted'],
            eligibleProviderIds: ['hosted-github-workflow'],
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
            status: 'settled',
            selectedBundleId: 'hosted-plus-manual-linux-docker',
            executionBundle: {
              status: 'committed',
              cellId: 'cell-sagan-kernel',
              laneId: 'docker-lane-01',
              executionCellLeaseId: 'exec-lease-123',
              dockerLaneLeaseId: 'docker-lease-456',
              harnessInstanceId: 'ts-harness-01',
              planeBinding: 'dual-plane-parity',
              premiumSaganMode: true,
              reciprocalLinkReady: true,
              effectiveBillableRateUsdPerHour: 375,
              isolatedLaneGroupId:
                'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
            },
            summary: {
              laneCount: 3,
              activeLaneCount: 2,
              completedLaneCount: 0,
              failedLaneCount: 0,
              deferredLaneCount: 1,
              manualLaneCount: 1,
              shadowLaneCount: 0,
              executionBundleStatus: 'committed',
              executionBundleReciprocalLinkReady: true,
              executionBundlePremiumSaganMode: true,
              pullRequestStatus: 'queued',
              orchestratorDisposition: 'wait-hosted-run'
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
        readyValidationClearance: {
          status: 'current',
          receiptPath: 'tests/results/_agent/runtime/ready-validation-clearance/LabVIEW-Community-CI-CD-compare-vi-cli-action-pr-88.json',
          readyHeadSha: '433e8aa70326007be74c27ccf54c1ae91559b6f3',
          currentHeadSha: '433e8aa70326007be74c27ccf54c1ae91559b6f3',
          staleForCurrentHead: false,
          reason: 'PR remains in ready-validation on the same cleared head.'
        },
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
          },
        workerProviderSelection: {
          source: 'lane-lifecycle-default',
          laneLifecycle: 'ready-merge',
          selectedActionType: 'existing-pr-unblock',
          requiredAssignmentMode: 'async-validation',
          preferredProviderIds: ['hosted-github-workflow'],
          preferredExecutionPlanes: ['hosted'],
          eligibleProviderIds: ['hosted-github-workflow'],
          selectedProviderId: 'hosted-github-workflow',
          selectedProviderKind: 'hosted-github-workflow',
          selectedExecutionPlane: 'hosted',
          selectedAssignmentMode: 'async-validation',
          dispatchSurface: 'github-actions',
          completionMode: 'async',
          selectedSlotId: 'worker-slot-2',
          requiresLocalCheckout: false
        },
        providerDispatch: {
          providerId: 'hosted-github-workflow',
          providerKind: 'hosted-github-workflow',
          executionPlane: 'hosted',
          assignmentMode: 'async-validation',
          dispatchSurface: 'github-actions',
          completionMode: 'async',
          workerSlotId: 'worker-slot-2',
          dispatchStatus: 'completed',
          completionStatus: 'completed',
          failureClass: null
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
  assert.equal(state.activeLane.readyValidationClearance.status, 'current');
  assert.equal(
    state.activeLane.readyValidationClearance.receiptPath,
    'tests/results/_agent/runtime/ready-validation-clearance/LabVIEW-Community-CI-CD-compare-vi-cli-action-pr-88.json'
  );
  assert.equal(
    state.activeLane.readyValidationClearance.readyHeadSha,
    '433e8aa70326007be74c27ccf54c1ae91559b6f3'
  );
  assert.equal(
    state.artifacts.localReviewLoopReceiptPath,
    'tests/results/docker-tools-parity/review-loop-receipt.json'
  );
  assert.equal(state.policy.maxActiveCodingLanes, 4);
  assert.equal(state.policy.capitalFabric.capacityMode, 'fixed-target');
  assert.equal(state.policy.capitalFabric.maxLogicalLaneCount, 4);
  assert.equal(state.logicalLaneActivation.seededLaneCount, 4);
  assert.equal(state.logicalLaneActivation.activeLaneCount, 4);
  assert.equal(state.logicalLaneActivation.catalog.length, 4);
  assert.deepEqual(state.logicalLaneActivation.catalog[0], {
    id: 'logical-lane-01',
    label: 'Lane 01',
    seededOrdinal: 1,
    activationState: 'active'
  });
  assert.equal(state.policy.capitalFabric.specialtyLanes.length, 0);
  assert.equal(state.workerPool.targetSlotCount, 4);
  assert.equal(state.workerPool.configuredTargetSlotCount, 4);
  assert.equal(state.workerPool.providers.length, 4);
  assert.equal(state.workerPool.providers[0].dispatchSurface, 'runtime-harness');
  assert.equal(state.workerPool.availableSlotCount, 4);
  assert.equal(state.workerPool.occupiedSlotCount, 0);
  assert.equal(state.activeLane.workerProviderSelection.selectedProviderId, 'hosted-github-workflow');
  assert.equal(state.activeLane.providerDispatch.providerId, 'hosted-github-workflow');
  assert.equal(state.activeLane.providerDispatch.workerSlotId, 'worker-slot-2');
  assert.equal(state.activeLane.concurrentLaneStatus.executionBundle.status, 'committed');
  assert.equal(state.activeLane.concurrentLaneStatus.executionBundle.planeBinding, 'dual-plane-parity');
  assert.equal(state.activeLane.concurrentLaneStatus.executionBundle.premiumSaganMode, true);
  assert.equal(state.activeLane.concurrentLaneStatus.executionBundle.reciprocalLinkReady, true);
  assert.equal(state.activeLane.concurrentLaneStatus.executionBundle.effectiveBillableRateUsdPerHour, 375);
  assert.equal(state.activeLane.planeTransition.from, 'origin');
  assert.equal(state.activeLane.planeTransition.to, 'upstream');
  assert.equal(state.artifacts.planeTransition.action, 'promote');
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

test('buildDeliveryAgentRuntimeRecord releases the selected worker slot when the lane enters a waiting state', () => {
  const state = buildDeliveryAgentRuntimeRecord({
    now: new Date('2026-03-20T12:00:00.000Z'),
    repoRoot,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: path.join(repoRoot, 'tests/results/_agent/runtime'),
    policy: {
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
          },
          {
            id: 'remote-copilot-lane',
            kind: 'remote-copilot-lane',
            executionPlane: 'remote',
            assignmentMode: 'remote-implementation',
            dispatchSurface: 'remote-copilot',
            completionMode: 'async',
            requiresLocalCheckout: false,
            enabled: true,
            slotCount: 1
          },
          {
            id: 'local-shadow-native',
            kind: 'local-shadow-native',
            executionPlane: 'local-shadow',
            assignmentMode: 'shadow-validation',
            dispatchSurface: 'native-shadow',
            completionMode: 'sync',
            requiresLocalCheckout: false,
            enabled: true,
            slotCount: 1
          }
        ]
      }
    },
    schedulerDecision: {
      outcome: 'selected',
      activeLane: {
        laneId: 'origin-1507',
        issue: 1507,
        forkRemote: 'origin',
        branch: 'issue/origin-1507-four-worker-pool',
        blockerClass: 'review',
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1507'
      },
      artifacts: {
        laneLifecycle: 'waiting-review'
      }
    },
    taskPacket: {
      laneId: 'origin-1507',
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-2',
          workerProviderId: 'hosted-github-workflow'
        },
        delivery: {
          laneLifecycle: 'waiting-review',
          workerProviderSelection: {
            source: 'lane-lifecycle-default',
            laneLifecycle: 'waiting-review',
            selectedActionType: null,
            requiredAssignmentMode: 'async-validation',
            preferredProviderIds: ['hosted-github-workflow'],
            preferredExecutionPlanes: ['hosted'],
            eligibleProviderIds: ['hosted-github-workflow'],
            selectedProviderId: 'hosted-github-workflow',
            selectedProviderKind: 'hosted-github-workflow',
            selectedExecutionPlane: 'hosted',
            selectedAssignmentMode: 'async-validation',
            dispatchSurface: 'github-actions',
            completionMode: 'async',
            selectedSlotId: 'worker-slot-2',
            requiresLocalCheckout: false
          },
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
    executionReceipt: {
      outcome: 'waiting-review',
      details: {
        laneLifecycle: 'waiting-review',
        blockerClass: 'review',
        nextWakeCondition: 'review-disposition-updated',
        pollIntervalSecondsHint: 45
      }
    },
    statePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-state.json'),
    lanePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-lanes/origin-1507.json')
  });

  assert.equal(state.workerPool.occupiedSlotCount, 0);
  assert.equal(state.workerPool.availableSlotCount, 4);
  assert.equal(state.workerPool.releasedLaneCount, 1);
  assert.equal(state.workerPool.releasedLanes[0].slotId, 'worker-slot-2');
  assert.equal(state.workerPool.releasedLanes[0].laneId, 'origin-1507');
  assert.equal(state.workerPool.releasedLanes[0].laneLifecycle, 'waiting-review');
  assert.equal(state.workerPool.releasedLanes[0].branch, 'issue/origin-1507-four-worker-pool');
  assert.equal(state.workerPool.releasedLanes[0].forkRemote, 'origin');
  assert.equal(
    state.workerPool.releasedLanes[0].prUrl,
    'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1507'
  );
  assert.equal(state.workerPool.releasedLanes[0].nextWakeCondition, 'review-disposition-updated');
  assert.equal(state.workerPool.releasedLanes[0].pollIntervalSecondsHint, 45);
  assert.match(state.workerPool.releasedLanes[0].releasedAt, /^2026-03-20T12:00:00.000Z$/);
  assert.equal(state.workerPool.slots[1].status, 'available');
});

test('buildDeliveryAgentRuntimeRecord fails closed when a fork lane omits required planeTransition evidence', () => {
  assert.throws(
    () =>
      buildDeliveryAgentRuntimeRecord({
        now: new Date('2026-03-13T19:00:00.000Z'),
        repoRoot,
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        runtimeDir: path.join(repoRoot, 'tests/results/_agent/runtime'),
        policy: {
          schema: 'priority/delivery-agent-policy@v1',
          implementationRemote: 'origin',
          maxActiveCodingLanes: 1
        },
        schedulerDecision: {
          activeLane: {
            laneId: 'origin-1129',
            issue: 1129,
            forkRemote: 'origin',
            branch: 'issue/origin-1129-runtime-plane-transition-receipts'
          }
        },
        taskPacket: {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          laneId: 'origin-1129',
          branch: {
            name: 'issue/origin-1129-runtime-plane-transition-receipts',
            forkRemote: 'origin'
          },
          evidence: {
            delivery: {
              laneLifecycle: 'coding',
              mutationEnvelope: {
                implementationRemote: 'origin'
              }
            }
          }
        },
        executionReceipt: {
          outcome: 'waiting-review',
          details: {
            laneLifecycle: 'waiting-review',
            blockerClass: 'review'
          }
        },
        statePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-state.json'),
        lanePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-lanes/origin-1129.json')
      }),
    /missing planeTransition evidence/i
  );
});

test('persistDeliveryAgentRuntimeState projects a cross-repo marketplace recommendation for waiting lanes', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-marketplace-'));
  const result = await persistDeliveryAgentRuntimeState({
    repoRoot,
    runtimeDir,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      implementationRemote: 'origin',
      maxActiveCodingLanes: 4
    },
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-1510',
        issue: 1510,
        forkRemote: 'origin',
        branch: 'issue/origin-1510-cross-repo-lane-marketplace',
        blockerClass: 'ci'
      },
      artifacts: {
        laneLifecycle: 'waiting-ci'
      }
    },
    taskPacket: {
      laneId: 'origin-1510',
      evidence: {
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
          }
        }
      }
    },
    executionReceipt: {
      outcome: 'waiting-ci',
      details: {
        laneLifecycle: 'waiting-ci',
        blockerClass: 'ci'
      }
    },
    now: new Date('2026-03-21T05:30:00.000Z'),
    collectMarketplaceSnapshotFn: async () => ({
      summary: {
        repositoryCount: 2,
        eligibleLaneCount: 2,
        topEligibleLane: {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          issueNumber: 1510,
          authorityTier: 'upstream-integration',
          promotionRail: 'integration'
        }
      },
      entries: [
        {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          eligible: true,
          authorityTier: 'upstream-integration',
          laneClass: 'upstream',
          promotionRail: 'integration',
          reason: 'standing-ready',
          standingLabels: ['standing-priority'],
          standing: { number: 1510, url: 'https://example.test/upstream/1510', title: 'Current lane' },
          ranking: { order: 1 }
        },
        {
          repository: 'LabVIEW-Community-CI-CD/comparevi-history',
          eligible: true,
          authorityTier: 'shared-platform',
          laneClass: 'consumer-platform',
          promotionRail: 'shared-platform',
          reason: 'standing-ready',
          standingLabels: ['standing-priority'],
          standing: { number: 186, url: 'https://example.test/history/186', title: 'History lane' },
          ranking: { order: 2 }
        }
      ]
    }),
    writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json')
  });

  assert.equal(result.payload.marketplace.status, 'ready');
  assert.equal(result.payload.marketplace.recommendedLane.repository, 'LabVIEW-Community-CI-CD/comparevi-history');
  assert.equal(path.basename(result.payload.artifacts.marketplaceSnapshotPath), 'lane-marketplace-snapshot.json');
});

test('persistDeliveryAgentRuntimeState keeps queue authority refresh telemetry in waiting-ci runtime state', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-queue-refresh-'));
  const result = await persistDeliveryAgentRuntimeState({
    repoRoot,
    runtimeDir,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      schema: 'priority/delivery-agent-policy@v1',
      implementationRemote: 'origin',
      maxActiveCodingLanes: 4
    },
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-1871',
        issue: 1871,
        forkRemote: 'origin',
        branch: 'issue/origin-1871-queue-authority-runtime-telemetry',
        blockerClass: 'ci'
      },
      artifacts: {
        laneLifecycle: 'waiting-ci'
      }
    },
    taskPacket: {
      laneId: 'origin-1871',
      evidence: {
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
          }
        }
      }
    },
    executionReceipt: {
      outcome: 'waiting-ci',
      details: {
        laneLifecycle: 'waiting-ci',
        blockerClass: 'ci',
        queueAuthorityRefresh: {
          attempted: true,
          status: 'completed',
          reason: 'queue-refresh-dry-run',
          helperCall: 'node tools/priority/queue-refresh-pr.mjs --pr 1876 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --dry-run',
          summaryPath: 'tests/results/_agent/queue/queue-refresh-1876.json',
          mergeSummaryPath: 'tests/results/_agent/queue/merge-sync-1876.json',
          receiptGeneratedAt: '2026-03-23T14:25:00.000Z',
          receiptStatus: 'dry-run',
          receiptReason: 'dry-run',
          evidenceFreshness: 'current',
          nextWakeCondition: 'merge-queue-progress',
          mergeStateStatus: 'UNSTABLE',
          isInMergeQueue: true,
          autoMergeEnabled: false,
          mergedAt: null
        }
      }
    },
    now: new Date('2026-03-23T14:25:01.000Z'),
    collectMarketplaceSnapshotFn: async () => ({
      summary: { repositoryCount: 0, eligibleLaneCount: 0, topEligibleLane: null },
      entries: []
    }),
    writeMarketplaceSnapshotFn: async () => path.join(runtimeDir, 'lane-marketplace-snapshot.json')
  });

  assert.equal(result.payload.queueAuthorityRefresh.status, 'completed');
  assert.equal(result.payload.queueAuthorityRefresh.receiptStatus, 'dry-run');
  assert.equal(result.payload.activeLane.queueAuthorityRefresh.summaryPath, 'tests/results/_agent/queue/queue-refresh-1876.json');
  assert.equal(result.payload.activeLane.queueAuthorityRefresh.isInMergeQueue, true);
  assert.equal(result.payload.artifacts.queueAuthorityRefreshReceiptPath, 'tests/results/_agent/queue/queue-refresh-1876.json');
  assert.equal(result.payload.artifacts.queueAuthorityRefreshMergeSummaryPath, 'tests/results/_agent/queue/merge-sync-1876.json');

  const schema = await loadSchema('docs/schemas/delivery-agent-runtime-state-v1.schema.json');
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(result.payload), true, JSON.stringify(validate.errors, null, 2));
});

test('persistDeliveryAgentRuntimeState projects live-agent model selection into runtime state', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-live-agent-model-selection-'));
  const policy = await loadDeliveryAgentPolicy(repoRoot);
  const liveAgentModelSelection = {
    mode: 'recommend-only',
    policyPath: 'tools/policy/live-agent-model-selection.json',
    reportPath: 'tests/results/_agent/runtime/live-agent-model-selection.json',
    previousReportPath: 'tests/results/_agent/runtime/live-agent-model-selection.json',
    recommendationStatus: 'pass',
    generatedAt: '2026-03-21T14:05:00.000Z',
    blockerCount: 0,
    selectedProviderId: 'local-codex',
    currentProvider: {
      providerId: 'local-codex',
      providerKind: 'local-codex',
      agentRole: 'live',
      currentModel: 'gpt-5.4',
      currentReasoningEffort: 'xhigh',
      selectedModel: 'gpt-5.4',
      selectedReasoningEffort: 'xhigh',
      action: 'stay',
      confidence: 'medium',
      reasonCodes: ['stable-current-model']
    },
    providers: [
      {
        providerId: 'local-codex',
        currentModel: 'gpt-5.4',
        currentReasoningEffort: 'xhigh',
        selectedModel: 'gpt-5.4',
        selectedReasoningEffort: 'xhigh',
        action: 'stay',
        confidence: 'medium',
        reasonCodes: ['stable-current-model']
      }
    ]
  };

  const result = await persistDeliveryAgentRuntimeState({
    repoRoot,
    runtimeDir,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy,
    schedulerDecision: {
      outcome: 'actionable',
      activeLane: {
        laneId: 'origin-1640',
        issue: 1640,
        branch: 'issue/origin-1640-live-agent-model-selection-telemetry',
        forkRemote: 'origin'
      },
      artifacts: {}
    },
    taskPacket: {
      schema: 'priority/runtime-worker-task-packet@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'coding',
      laneId: 'origin-1640',
      objective: {
        summary: 'Advance issue #1640: drive deterministic live-agent model selection from telemetry',
        source: 'test'
      },
      branch: {
        name: 'issue/origin-1640-live-agent-model-selection-telemetry',
        forkRemote: 'origin'
      },
      evidence: {
        lane: {
          workerSlotId: 'worker-slot-1',
          workerProviderId: 'local-codex',
          workerCheckoutPath: path.join(repoRoot, '.tmp', 'runtime-worker')
        },
        delivery: {
          executionMode: 'canonical-delivery',
          laneLifecycle: 'coding',
          planeTransition: {
            from: 'origin',
            to: 'upstream',
            action: 'promote',
            via: 'pull-request',
            branchClass: 'lane',
            sourceRepository: 'labview-community-ci-cd/compare-vi-cli-action-fork',
            targetRepository: 'labview-community-ci-cd/compare-vi-cli-action'
          },
          liveAgentModelSelection,
          workerProviderSelection: {
            source: 'lane-lifecycle-default',
            laneLifecycle: 'coding',
            selectedActionType: 'advance-child-issue',
            requiredAssignmentMode: 'interactive-coding',
            preferredProviderIds: ['local-codex'],
            preferredExecutionPlanes: ['local'],
            eligibleProviderIds: ['local-codex'],
            selectedProviderId: 'local-codex',
            selectedProviderKind: 'local-codex',
            selectedExecutionPlane: 'local',
            selectedAssignmentMode: 'interactive-coding',
            dispatchSurface: 'runtime-harness',
            completionMode: 'sync',
            selectedSlotId: 'worker-slot-1',
            requiresLocalCheckout: true
          },
          mutationEnvelope: {
            backlogAuthority: 'issues',
            implementationRemote: 'origin',
            copilotReviewStrategy: 'draft-only-explicit',
            readyForReviewPurpose: 'final-validation',
            allowPolicyMutations: false,
            allowReleaseAdmin: false,
            maxActiveCodingLanes: 4
          },
          turnBudget: {
            maxMinutes: 20,
            maxToolCalls: 12
          }
        }
      }
    },
    executionReceipt: {
      laneId: 'origin-1640',
      status: 'completed',
      outcome: 'coding-command-finished',
      details: {
        laneLifecycle: 'coding',
        blockerClass: 'none',
        retryable: true,
        nextWakeCondition: 'scheduler-rescan',
        helperCallsExecuted: [],
        filesTouched: []
      }
    }
  });

  assert.equal(result.payload.liveAgentModelSelection.currentProvider.providerId, 'local-codex');
  assert.equal(result.payload.liveAgentModelSelection.currentProvider.selectedModel, 'gpt-5.4');
  assert.equal(result.payload.liveAgentModelSelection.currentProvider.selectedReasoningEffort, 'xhigh');
  assert.equal(result.payload.activeLane.liveAgentModelSelection.currentProvider.providerId, 'local-codex');
  assert.equal(result.payload.activeLane.liveAgentModelSelection.currentProvider.selectedModel, 'gpt-5.4');
  assert.equal(result.payload.activeLane.liveAgentModelSelection.currentProvider.selectedReasoningEffort, 'xhigh');
});

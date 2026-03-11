#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildDeliveryAgentRuntimeRecord } from '../delivery-agent.mjs';
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
        mutationEnvelope: {
          backlogAuthority: 'issues',
          implementationRemote: 'origin',
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
          laneLifecycle: 'ready-merge'
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
        nextWakeCondition: 'next-scheduler-cycle'
      }
    },
    statePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-state.json'),
    lanePath: path.join(repoRoot, 'tests/results/_agent/runtime/delivery-agent-lanes/origin-1012.json')
  });
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(state), true, JSON.stringify(validate.errors, null, 2));
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

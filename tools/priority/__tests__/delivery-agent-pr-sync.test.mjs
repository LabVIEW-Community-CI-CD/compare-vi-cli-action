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

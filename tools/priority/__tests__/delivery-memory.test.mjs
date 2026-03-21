#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildDeliveryMemoryReport } from '../delivery-memory.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('delivery-memory shim exports named bindings after fallback build instead of static dist re-exports', async () => {
  const content = await readFile(path.join(repoRoot, 'tools/priority/delivery-memory.mjs'), 'utf8');

  assert.doesNotMatch(content, /export \* from '\.\.\/\.\.\/dist\/tools\/priority\/delivery-memory\.js';/);
  assert.match(content, /export const buildDeliveryMemoryReport = imported\.buildDeliveryMemoryReport;/);
  assert.match(content, /export const refreshDeliveryMemory = imported\.refreshDeliveryMemory;/);
  assert.match(content, /export const parseArgs = imported\.parseArgs;/);
  assert.match(content, /export const main = imported\.main;/);
});

test('delivery memory summarizes merged and poisoned-branch PR outcomes with effort and VI History classification', () => {
  const taskPackets = [
    {
      generatedAt: '2026-03-11T10:00:00.000Z',
      laneId: 'origin-1011',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: {
        summary: 'Advance issue #1011: deliver the VI History Suite smoke contract'
      },
      branch: {
        name: 'issue/origin-1011-vi-history-suite-smoke-contract'
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
    },
    {
      generatedAt: '2026-03-11T10:30:00.000Z',
      laneId: 'origin-1012',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: {
        summary: 'Advance issue #1012: recover poisoned branch lane'
      },
      branch: {
        name: 'issue/origin-1012-poisoned-branch-recovery'
      },
      pullRequest: {
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/501'
      },
      evidence: {
        delivery: {
          selectedIssue: {
            number: 1012
          }
        }
      }
    }
  ];

  const executionReceipts = [
    {
      generatedAt: '2026-03-11T10:05:00.000Z',
      laneId: 'origin-1011',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1011,
      status: 'completed',
      outcome: 'coding-command-finished',
      details: {
        actionType: 'execute-coding-turn',
        laneLifecycle: 'waiting-ci',
        blockerClass: 'none',
        retryable: true,
        nextWakeCondition: 'checks-green',
        helperCallsExecuted: ['codex exec', 'node tools/npm/run-script.mjs priority:pr'],
        filesTouched: ['tools/Test-PRVIHistorySmoke.ps1', 'tests/CompareVIHistory.Tests.ps1']
      }
    },
    {
      generatedAt: '2026-03-11T10:10:00.000Z',
      laneId: 'origin-1011',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1011,
      status: 'completed',
      outcome: 'waiting-review',
      details: {
        actionType: 'watch-pr',
        laneLifecycle: 'waiting-review',
        blockerClass: 'review',
        retryable: true,
        nextWakeCondition: 'review-disposition-updated',
        helperCallsExecuted: [],
        filesTouched: []
      }
    },
    {
      generatedAt: '2026-03-11T10:15:00.000Z',
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
        filesTouched: []
      }
    },
    {
      generatedAt: '2026-03-11T10:35:00.000Z',
      laneId: 'origin-1012',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1012,
      status: 'blocked',
      outcome: 'poisoned-branch-detected',
      reason: 'Branch became poisoned after upstream drift and unsafe force-push state.',
      details: {
        actionType: 'execute-coding-turn',
        laneLifecycle: 'blocked',
        blockerClass: 'policy',
        retryable: false,
        nextWakeCondition: 'manual-poisoned-branch-disposition',
        helperCallsExecuted: ['codex exec'],
        filesTouched: ['tools/priority/runtime-supervisor.mjs']
      }
    },
    {
      generatedAt: '2026-03-11T10:40:00.000Z',
      laneId: 'origin-1012',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      issue: 1012,
      status: 'completed',
      outcome: 'closed-pr-poisoned-branch',
      reason: 'Closed PR because the lane branch was poisoned and unsafe to continue.',
      details: {
        actionType: 'close-pr',
        laneLifecycle: 'complete',
        blockerClass: 'policy',
        retryable: false,
        nextWakeCondition: 'next-scheduler-cycle',
        helperCallsExecuted: ['gh pr close 501'],
        filesTouched: []
      }
    }
  ];

  const report = buildDeliveryMemoryReport({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: 'tests/results/_agent/runtime',
    taskPackets,
    executionReceipts,
    hostIsolation: {
      counters: {
        runnerPreemptionCount: 3,
        runnerRestoreCount: 3,
        dockerDriftIncidentCount: 2,
        nativeDaemonRepairCount: 1,
        cyclesBlockedByHostRuntimeConflict: 4,
      },
    },
    now: new Date('2026-03-11T11:00:00.000Z')
  });

  assert.equal(report.summary.totalTerminalPullRequestCount, 2);
  assert.equal(report.summary.mergedPullRequestCount, 1);
  assert.equal(report.summary.closedPullRequestCount, 1);
  assert.equal(report.summary.hostedWaitEscapeCount, 1);
  assert.equal(report.summary.poisonedBranchClosureCount, 1);
  assert.equal(report.summary.meanTerminalDurationMinutes, 7.5);
  assert.equal(report.summary.viHistorySuitePullRequestCount, 1);
  assert.equal(report.summary.viHistorySuiteMergedPullRequestCount, 1);
  assert.equal(report.summary.viHistorySuiteClosedPullRequestCount, 0);
  assert.equal(report.summary.runnerPreemptionCount, 3);
  assert.equal(report.summary.runnerRestoreCount, 3);
  assert.equal(report.summary.dockerDriftIncidentCount, 2);
  assert.equal(report.summary.nativeDaemonRepairCount, 1);
  assert.equal(report.summary.cyclesBlockedByHostRuntimeConflict, 4);
  assert.equal(report.pullRequests.length, 2);

  const viHistoryEntry = report.pullRequests.find((entry) => entry.pullRequestNumber === 500);
  assert.ok(viHistoryEntry);
  assert.equal(viHistoryEntry.deliveryTrack, 'vi-history-suite');
  assert.equal(viHistoryEntry.terminalDisposition, 'merged');
  assert.equal(viHistoryEntry.pullRequestUrl, 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/500');
  assert.equal(viHistoryEntry.effort.codingTurnCount, 1);
  assert.equal(viHistoryEntry.effort.waitingReviewTurnCount, 1);
  assert.equal(viHistoryEntry.effort.mergeAttemptCount, 1);

  const poisonedEntry = report.pullRequests.find((entry) => entry.pullRequestNumber === 501);
  assert.ok(poisonedEntry);
  assert.equal(poisonedEntry.terminalDisposition, 'closed');
  assert.equal(poisonedEntry.closeReasonClass, 'poisoned-branch');
  assert.equal(poisonedEntry.poisonedBranch, true);
  assert.equal(poisonedEntry.deliveryTrack, 'general');
  assert.equal(poisonedEntry.effort.closeAttemptCount, 1);
  assert.equal(poisonedEntry.effort.blockedTurnCount, 1);

  assert.equal(report.summary.recentTerminalPullRequests[0].pullRequestNumber, 501);
});

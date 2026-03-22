#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { parseArgs, runQueueRefresh } from '../queue-refresh-pr.mjs';

function buildQueuePolicy() {
  return {
    rulesets: {
      develop: {
        includes: ['refs/heads/develop'],
        merge_queue: {
          merge_method: 'SQUASH'
        }
      }
    }
  };
}

function buildPullRequestView(overrides = {}) {
  return {
    id: 'PR_test_123',
    number: 123,
    state: 'OPEN',
    isDraft: false,
    mergeStateStatus: 'CLEAN',
    mergeable: 'MERGEABLE',
    baseRefName: 'develop',
    url: 'https://example.test/pr/123',
    headRefName: 'issue/origin-123-queue-refresh',
    headRefOid: '0123456789abcdef0123456789abcdef01234567',
    headRepository: {
      name: 'compare-vi-cli-action-fork'
    },
    headRepositoryOwner: {
      login: 'LabVIEW-Community-CI-CD'
    },
    isCrossRepository: true,
    autoMergeRequest: null,
    ...overrides
  };
}

function buildQueueState(overrides = {}) {
  return {
    state: 'OPEN',
    mergeStateStatus: 'CLEAN',
    isInMergeQueue: true,
    mergedAt: null,
    autoMergeRequest: null,
    ...overrides
  };
}

test('parseArgs accepts queue refresh receipt and merge-summary flags', () => {
  const parsed = parseArgs([
    'node',
    'tools/priority/queue-refresh-pr.mjs',
    '--pr',
    '1568',
    '--repo',
    'owner/repo',
    '--head-remote',
    'origin',
    '--skip-rebase',
    '--summary-path',
    'tests/results/_agent/queue/queue-refresh-1568.json',
    '--merge-summary-path',
    'tests/results/_agent/queue/merge-sync-1568.json',
    '--dry-run'
  ]);

  assert.deepEqual(parsed, {
    pr: 1568,
    repo: 'owner/repo',
    headRemote: 'origin',
    skipRebase: true,
    summaryPath: 'tests/results/_agent/queue/queue-refresh-1568.json',
    mergeSummaryPath: 'tests/results/_agent/queue/merge-sync-1568.json',
    dryRun: true
  });
});

test('queue refresh receipt advertises the dequeue-update-requeue operation', async () => {
  let queueReads = 0;

  const { receipt } = await runQueueRefresh({
    repoRoot: process.cwd(),
    args: {
      pr: 1568,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      headRemote: null,
      summaryPath: 'memory://queue-refresh-1568.json',
      mergeSummaryPath: 'memory://merge-sync-1568.json',
      dryRun: false
    },
    ensureGhCliFn: () => {},
    readPolicyFn: async () => buildQueuePolicy(),
    readPullRequestViewFn: async () => ({
      id: 'PR_test_1568',
      number: 1568,
      state: 'OPEN',
      isDraft: false,
      mergeStateStatus: 'CLEAN',
      mergeable: 'MERGEABLE',
      baseRefName: 'develop',
      url: 'https://example.test/pr/1568',
      headRefName: 'issue/origin-1568-queue-refresh-helper',
      headRefOid: '1234567890abcdef1234567890abcdef12345678',
      headRepository: {
        name: 'compare-vi-cli-action-fork'
      },
      headRepositoryOwner: {
        login: 'LabVIEW-Community-CI-CD'
      },
      isCrossRepository: true,
      autoMergeRequest: null
    }),
    readPullRequestQueueStateFn: async () => {
      queueReads += 1;
      return {
        state: 'OPEN',
        mergeStateStatus: 'CLEAN',
        isInMergeQueue: queueReads === 1,
        mergedAt: null,
        autoMergeRequest: null
      };
    },
    dequeuePullRequestFn: async () => ({}),
    runGitCommandFn: (_root, args) => {
      if (args[0] === 'status') return { status: 0, stdout: '', stderr: '' };
      if (args[0] === 'fetch') return { status: 0, stdout: '', stderr: '' };
      if (args[0] === 'rebase' && args[1] === 'upstream/develop') return { status: 0, stdout: '', stderr: '' };
      if (args[0] === 'rev-parse' && args[1] === 'HEAD') {
        return { status: 0, stdout: 'abcdefabcdefabcdefabcdefabcdefabcdefabcd\n', stderr: '' };
      }
      if (args[0] === 'push') return { status: 0, stdout: '', stderr: '' };
      throw new Error(`Unexpected git args: ${args.join(' ')}`);
    },
    readCurrentBranchFn: () => 'issue/origin-1568-queue-refresh-helper',
    readTrackingRemoteFn: () => 'origin',
    resolveHeadRemoteNameFn: () => ({ remoteName: 'origin', source: 'test' }),
    runMergeSyncFn: async () => ({
      promotion: {
        status: 'queued',
        materialized: true
      },
      finalMode: 'auto',
      finalReason: 'merge-state-blocked'
    }),
    sleepFn: async () => {},
    writeReceiptFn: async (receiptPath) => receiptPath
  });

  assert.equal(receipt.operation, 'dequeue-update-requeue');
});

test('runQueueRefresh skips non-queued PRs without dequeueing, rebasing, or requeueing', async () => {
  let dequeueCalled = false;
  let mergeSyncCalled = false;
  const gitCalls = [];
  const writes = [];

  const { receipt } = await runQueueRefresh({
    repoRoot: process.cwd(),
    args: {
      pr: 123,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      headRemote: null,
      skipRebase: false,
      summaryPath: 'memory://queue-refresh-123.json',
      mergeSummaryPath: 'memory://merge-sync-123.json',
      dryRun: false
    },
    ensureGhCliFn: () => {},
    readPolicyFn: async () => buildQueuePolicy(),
    readPullRequestViewFn: async () => buildPullRequestView(),
    readPullRequestQueueStateFn: async () => buildQueueState({ isInMergeQueue: false }),
    dequeuePullRequestFn: async () => {
      dequeueCalled = true;
    },
    runGitCommandFn: (...args) => {
      gitCalls.push(args);
      throw new Error('git should not run for non-queued PRs');
    },
    readCurrentBranchFn: () => 'issue/origin-123-queue-refresh',
    readTrackingRemoteFn: () => 'origin',
    resolveHeadRemoteNameFn: () => ({ remoteName: 'origin', source: 'test' }),
    runMergeSyncFn: async () => {
      mergeSyncCalled = true;
      return {};
    },
    writeReceiptFn: async (receiptPath, payload) => {
      writes.push({ receiptPath, payload });
      return receiptPath;
    }
  });

  assert.equal(receipt.summary.status, 'skipped');
  assert.equal(receipt.summary.reason, 'not-in-merge-queue');
  assert.equal(receipt.dequeue.attempted, false);
  assert.equal(receipt.refresh.attempted, false);
  assert.equal(receipt.requeue.attempted, false);
  assert.equal(dequeueCalled, false);
  assert.equal(mergeSyncCalled, false);
  assert.deepEqual(gitCalls, []);
  assert.equal(writes.length, 1);
});

test('runQueueRefresh dequeues, rebases, force-pushes, and re-arms merge queue admission', async () => {
  const gitCalls = [];
  const mergeSyncCalls = [];
  const writes = [];
  let queueReads = 0;
  let dequeueCalls = 0;

  const { receipt } = await runQueueRefresh({
    repoRoot: process.cwd(),
    args: {
      pr: 123,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      headRemote: null,
      skipRebase: false,
      summaryPath: 'memory://queue-refresh-123.json',
      mergeSummaryPath: 'memory://merge-sync-123.json',
      dryRun: false
    },
    ensureGhCliFn: () => {},
    readPolicyFn: async () => buildQueuePolicy(),
    readPullRequestViewFn: async () => buildPullRequestView(),
    readPullRequestQueueStateFn: async () => {
      queueReads += 1;
      return queueReads === 1 ? buildQueueState({ isInMergeQueue: true }) : buildQueueState({ isInMergeQueue: false });
    },
    dequeuePullRequestFn: async () => {
      dequeueCalls += 1;
      return { data: { dequeuePullRequest: { clientMutationId: null } } };
    },
    runGitCommandFn: (_repoRoot, args) => {
      gitCalls.push(args);
      if (args[0] === 'status') {
        return { status: 0, stdout: '', stderr: '' };
      }
      if (args[0] === 'fetch') {
        return { status: 0, stdout: '', stderr: '' };
      }
      if (args[0] === 'rebase' && args[1] === 'upstream/develop') {
        return { status: 0, stdout: '', stderr: '' };
      }
      if (args[0] === 'rev-parse' && args[1] === 'HEAD') {
        return { status: 0, stdout: 'fedcba9876543210fedcba9876543210fedcba98\n', stderr: '' };
      }
      if (args[0] === 'push') {
        return { status: 0, stdout: '', stderr: '' };
      }
      throw new Error(`Unexpected git args: ${args.join(' ')}`);
    },
    readCurrentBranchFn: () => 'issue/origin-123-queue-refresh',
    readTrackingRemoteFn: () => 'origin',
    resolveHeadRemoteNameFn: () => ({ remoteName: 'origin', source: 'test' }),
    runMergeSyncFn: async (payload) => {
      mergeSyncCalls.push(payload);
      return {
        promotion: {
          status: 'queued',
          materialized: true
        },
        finalMode: 'auto',
        finalReason: 'merge-state-blocked'
      };
    },
    sleepFn: async () => {},
    writeReceiptFn: async (receiptPath, payload) => {
      writes.push({ receiptPath, payload });
      return receiptPath;
    }
  });

  assert.equal(dequeueCalls, 1);
  assert.equal(receipt.summary.status, 'completed');
  assert.equal(receipt.dequeue.status, 'completed');
  assert.equal(receipt.dequeue.finalIsInMergeQueue, false);
  assert.equal(receipt.refresh.status, 'completed');
  assert.equal(receipt.refresh.mode, 'rebase');
  assert.equal(receipt.refresh.rebasedHeadSha, 'fedcba9876543210fedcba9876543210fedcba98');
  assert.equal(receipt.requeue.status, 'completed');
  assert.equal(receipt.requeue.promotionStatus, 'queued');
  assert.equal(receipt.requeue.materialized, true);
  assert.deepEqual(gitCalls, [
    ['status', '--porcelain'],
    ['fetch', 'upstream', 'develop'],
    ['fetch', 'origin', 'issue/origin-123-queue-refresh'],
    ['rebase', 'upstream/develop'],
    ['rev-parse', 'HEAD'],
    ['push', '--force-with-lease', 'origin', 'HEAD:issue/origin-123-queue-refresh']
  ]);
  assert.deepEqual(
    mergeSyncCalls[0].argv,
    [
      'node',
      'tools/priority/merge-sync-pr.mjs',
      '--pr',
      '123',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--summary-path',
      'memory://merge-sync-123.json'
    ]
  );
  assert.equal(writes.length, 1);
});

test('runQueueRefresh aborts the rebase and records a failed receipt when local refresh cannot complete linearly', async () => {
  let writtenReceipt = null;
  const gitCalls = [];
  let queueReads = 0;

  await assert.rejects(
    runQueueRefresh({
      repoRoot: process.cwd(),
      args: {
        pr: 123,
        repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        headRemote: null,
        skipRebase: false,
        summaryPath: 'memory://queue-refresh-123.json',
        mergeSummaryPath: 'memory://merge-sync-123.json',
        dryRun: false
      },
      ensureGhCliFn: () => {},
      readPolicyFn: async () => buildQueuePolicy(),
      readPullRequestViewFn: async () => buildPullRequestView(),
      readPullRequestQueueStateFn: async () => {
        queueReads += 1;
        return queueReads === 1 ? buildQueueState({ isInMergeQueue: true }) : buildQueueState({ isInMergeQueue: false });
      },
      dequeuePullRequestFn: async () => ({}),
      runGitCommandFn: (_repoRoot, args) => {
        gitCalls.push(args);
        if (args[0] === 'status') {
          return { status: 0, stdout: '', stderr: '' };
        }
        if (args[0] === 'fetch') {
          return { status: 0, stdout: '', stderr: '' };
        }
        if (args[0] === 'rebase' && args[1] === 'upstream/develop') {
          return { status: 1, stdout: '', stderr: 'CONFLICT (content): could not apply deadbeef...' };
        }
        if (args[0] === 'rebase' && args[1] === '--abort') {
          return { status: 0, stdout: '', stderr: '' };
        }
        throw new Error(`Unexpected git args: ${args.join(' ')}`);
      },
      readCurrentBranchFn: () => 'issue/origin-123-queue-refresh',
      readTrackingRemoteFn: () => 'origin',
      resolveHeadRemoteNameFn: () => ({ remoteName: 'origin', source: 'test' }),
      runMergeSyncFn: async () => {
        throw new Error('merge-sync should not run after a failed rebase');
      },
      sleepFn: async () => {},
      writeReceiptFn: async (_receiptPath, payload) => {
        writtenReceipt = payload;
        return 'memory://queue-refresh-123.json';
      }
    }),
    /could not apply/i
  );

  assert.equal(writtenReceipt.summary.status, 'failed');
  assert.equal(writtenReceipt.refresh.status, 'failed');
  assert.deepEqual(gitCalls, [
    ['status', '--porcelain'],
    ['fetch', 'upstream', 'develop'],
    ['fetch', 'origin', 'issue/origin-123-queue-refresh'],
    ['rebase', 'upstream/develop'],
    ['rebase', '--abort']
  ]);
});

test('runQueueRefresh can amend a queued PR without rebasing when local head is already checked out', async () => {
  const gitCalls = [];
  const mergeSyncCalls = [];
  let queueReads = 0;

  const { receipt } = await runQueueRefresh({
    repoRoot: process.cwd(),
    args: {
      pr: 123,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      headRemote: null,
      skipRebase: true,
      summaryPath: 'memory://queue-refresh-123.json',
      mergeSummaryPath: 'memory://merge-sync-123.json',
      dryRun: false
    },
    ensureGhCliFn: () => {},
    readPolicyFn: async () => buildQueuePolicy(),
    readPullRequestViewFn: async () => buildPullRequestView(),
    readPullRequestQueueStateFn: async () => {
      queueReads += 1;
      return queueReads === 1 ? buildQueueState({ isInMergeQueue: true }) : buildQueueState({ isInMergeQueue: false });
    },
    dequeuePullRequestFn: async () => ({}),
    runGitCommandFn: (_repoRoot, args) => {
      gitCalls.push(args);
      if (args[0] === 'status') {
        return { status: 0, stdout: '', stderr: '' };
      }
      if (args[0] === 'rev-parse' && args[1] === 'HEAD') {
        return { status: 0, stdout: 'fedcba9876543210fedcba9876543210fedcba98\n', stderr: '' };
      }
      if (args[0] === 'push') {
        return { status: 0, stdout: '', stderr: '' };
      }
      throw new Error(`Unexpected git args: ${args.join(' ')}`);
    },
    readCurrentBranchFn: () => 'issue/origin-123-queue-refresh',
    readTrackingRemoteFn: () => 'origin',
    resolveHeadRemoteNameFn: () => ({ remoteName: 'origin', source: 'test' }),
    runMergeSyncFn: async (payload) => {
      mergeSyncCalls.push(payload);
      return {
        promotion: {
          status: 'queued',
          materialized: true
        },
        finalMode: 'auto',
        finalReason: 'merge-state-blocked'
      };
    },
    sleepFn: async () => {},
    writeReceiptFn: async (receiptPath) => receiptPath
  });

  assert.equal(receipt.refresh.status, 'completed');
  assert.equal(receipt.refresh.mode, 'amend');
  assert.equal(receipt.refresh.reason, 'amended-and-pushed');
  assert.deepEqual(gitCalls, [
    ['status', '--porcelain'],
    ['rev-parse', 'HEAD'],
    ['push', '--force-with-lease', 'origin', 'HEAD:issue/origin-123-queue-refresh']
  ]);
  assert.equal(mergeSyncCalls.length, 1);
});

test('runQueueRefresh amend mode fails closed when the checked-out branch is not the PR head', async () => {
  let queueReads = 0;
  await assert.rejects(
    runQueueRefresh({
      repoRoot: process.cwd(),
      args: {
        pr: 123,
        repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        headRemote: null,
        skipRebase: true,
        summaryPath: 'memory://queue-refresh-123.json',
        mergeSummaryPath: 'memory://merge-sync-123.json',
        dryRun: false
      },
      ensureGhCliFn: () => {},
      readPolicyFn: async () => buildQueuePolicy(),
      readPullRequestViewFn: async () => buildPullRequestView(),
      readPullRequestQueueStateFn: async () => {
        queueReads += 1;
        return queueReads === 1 ? buildQueueState({ isInMergeQueue: true }) : buildQueueState({ isInMergeQueue: false });
      },
      dequeuePullRequestFn: async () => ({}),
      runGitCommandFn: (_repoRoot, args) => {
        if (args[0] === 'status') {
          return { status: 0, stdout: '', stderr: '' };
        }
        throw new Error(`Unexpected git args: ${args.join(' ')}`);
      },
      readCurrentBranchFn: () => 'develop',
      readTrackingRemoteFn: () => 'origin',
      resolveHeadRemoteNameFn: () => ({ remoteName: 'origin', source: 'test' }),
      runMergeSyncFn: async () => ({}),
      writeReceiptFn: async (receiptPath) => receiptPath
    }),
    /Queue amend mode requires the checked-out branch/
  );
});

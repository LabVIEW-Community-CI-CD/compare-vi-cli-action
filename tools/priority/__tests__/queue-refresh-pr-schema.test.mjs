#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runQueueRefresh } from '../queue-refresh-pr.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

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

test('queue refresh receipt validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'queue-refresh-receipt-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  let queueReads = 0;

  const { receipt } = await runQueueRefresh({
    repoRoot,
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

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(receipt);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

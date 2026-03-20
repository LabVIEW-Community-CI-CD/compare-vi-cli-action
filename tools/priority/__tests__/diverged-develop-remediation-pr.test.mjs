#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import {
  parseArgs,
  buildDivergedDevelopRemediationBranchName,
  buildDivergedDevelopRemediationPrTitle,
  resolveAutoMergeMethod,
  buildDeterministicCommitEnv,
  classifyRetryablePushTransportFailure,
  isRetryablePushTransportFailure,
  publishSyncBranch
} from '../diverged-develop-remediation-pr.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('diverged remediation helper parses explicit options', () => {
  const options = parseArgs([
    'node',
    'diverged-develop-remediation-pr.mjs',
    '--target-remote',
    'origin',
    '--base-remote',
    'upstream',
    '--branch',
    'develop',
    '--sync-branch',
    'sync/origin-develop-parity',
    '--reason',
    'diverged-fork-plane',
    '--local-head',
    'abc123',
    '--report-path',
    'custom/report.json'
  ]);

  assert.equal(options.targetRemote, 'origin');
  assert.equal(options.baseRemote, 'upstream');
  assert.equal(options.branch, 'develop');
  assert.equal(options.syncBranch, 'sync/origin-develop-parity');
  assert.equal(options.reason, 'diverged-fork-plane');
  assert.equal(options.localHead, 'abc123');
  assert.equal(options.reportPath, 'custom/report.json');
});

test('diverged remediation helper uses a deterministic sync branch name', () => {
  assert.equal(
    buildDivergedDevelopRemediationBranchName('origin', 'develop'),
    'sync/origin-develop-parity'
  );
  assert.equal(
    buildDivergedDevelopRemediationPrTitle({ baseRemote: 'upstream', branch: 'develop' }),
    '[sync]: restore develop parity with upstream/develop'
  );
});

test('diverged remediation helper resolves the viewer-default allowed auto-merge method', () => {
  assert.equal(
    resolveAutoMergeMethod({
      mergeCommitAllowed: false,
      rebaseMergeAllowed: true,
      squashMergeAllowed: true,
      viewerDefaultMergeMethod: 'SQUASH'
    }),
    'squash'
  );
  assert.equal(
    resolveAutoMergeMethod({
      mergeCommitAllowed: false,
      rebaseMergeAllowed: true,
      squashMergeAllowed: false,
      viewerDefaultMergeMethod: 'MERGE'
    }),
    'rebase'
  );
});

test('diverged remediation helper pins deterministic author and committer metadata', () => {
  const env = buildDeterministicCommitEnv('2026-03-16T12:00:00-07:00', { PATH: 'test-path' });

  assert.equal(env.PATH, 'test-path');
  assert.equal(env.GIT_AUTHOR_NAME, 'compare-vi-cli-action parity bot');
  assert.equal(env.GIT_AUTHOR_EMAIL, 'compare-vi-cli-action@users.noreply.github.com');
  assert.equal(env.GIT_AUTHOR_DATE, '2026-03-16T12:00:00-07:00');
  assert.equal(env.GIT_COMMITTER_NAME, 'compare-vi-cli-action parity bot');
  assert.equal(env.GIT_COMMITTER_EMAIL, 'compare-vi-cli-action@users.noreply.github.com');
  assert.equal(env.GIT_COMMITTER_DATE, '2026-03-16T12:00:00-07:00');
});

test('diverged remediation helper classifies retryable remediation push transport failures', () => {
  const transportMessage = [
    'error: RPC failed; curl 56 OpenSSL SSL_read: OpenSSL/3.5.5: error:0A0003FC:SSL routines::ssl/tls alert bad record mac, errno 0',
    'send-pack: unexpected disconnect while reading sideband packet',
    'fatal: the remote end hung up unexpectedly'
  ].join('\n');

  assert.equal(classifyRetryablePushTransportFailure(transportMessage), 'transport-tls');
  assert.equal(isRetryablePushTransportFailure(transportMessage), true);
  assert.equal(classifyRetryablePushTransportFailure('fatal: repository rule violated'), null);
});

test('publishSyncBranch retries bounded transport failures before succeeding', () => {
  const calls = [];
  const sleeps = [];
  let pushAttempts = 0;
  let lsRemoteCalls = 0;
  const syntheticCommitSha = 'abc123';

  const result = publishSyncBranch(
    '/tmp/repo',
    {
      targetRemote: 'origin',
      syncBranch: 'sync/origin-develop-parity',
      syntheticCommitSha
    },
    {
      sleepFn: (delayMs) => {
        sleeps.push(delayMs);
      },
      spawnSyncFn: (_command, args) => {
        calls.push(args);
        if (args[0] === 'ls-remote') {
          lsRemoteCalls += 1;
          return {
            status: 0,
            stdout: lsRemoteCalls >= 3 ? `${syntheticCommitSha}\trefs/heads/sync/origin-develop-parity\n` : '',
            stderr: ''
          };
        }
        if (args[0] === 'push') {
          pushAttempts += 1;
          if (pushAttempts === 1) {
            return {
              status: 1,
              stdout: '',
              stderr: [
                'error: RPC failed; curl 56 OpenSSL SSL_read: OpenSSL/3.5.5: error:0A0003FC:SSL routines::ssl/tls alert bad record mac, errno 0',
                'send-pack: unexpected disconnect while reading sideband packet',
                'fatal: the remote end hung up unexpectedly'
              ].join('\n')
            };
          }
          return { status: 0, stdout: '', stderr: '' };
        }
        if (args[0] === 'config') {
          return { status: 1, stdout: '', stderr: '' };
        }
        throw new Error(`Unexpected git args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(result.status, 'pushed');
  assert.equal(result.recoveredFromPushFailure, true);
  assert.equal(result.attemptCount, 2);
  assert.deepEqual(sleeps, [1500]);
  assert.deepEqual(
    calls.filter((args) => args[0] === 'push').map((args) => args.slice(0, 2)),
    [
      ['push', 'origin'],
      ['push', 'origin']
    ]
  );
});

test('publishSyncBranch treats a branch published after a transport failure as already-published success', () => {
  let pushAttempts = 0;
  let lsRemoteCalls = 0;
  const syntheticCommitSha = 'abc123';

  const result = publishSyncBranch(
    '/tmp/repo',
    {
      targetRemote: 'origin',
      syncBranch: 'sync/origin-develop-parity',
      syntheticCommitSha
    },
    {
      sleepFn: () => {
        throw new Error('sleepFn should not run when remote publication is observed immediately.');
      },
      spawnSyncFn: (_command, args) => {
        if (args[0] === 'ls-remote') {
          lsRemoteCalls += 1;
          return {
            status: 0,
            stdout: lsRemoteCalls >= 2 ? `${syntheticCommitSha}\trefs/heads/sync/origin-develop-parity\n` : '',
            stderr: ''
          };
        }
        if (args[0] === 'push') {
          pushAttempts += 1;
          return {
            status: 1,
            stdout: '',
            stderr: [
              'error: RPC failed; curl 56 OpenSSL SSL_read: OpenSSL/3.5.5: error:0A0003FC:SSL routines::ssl/tls alert bad record mac, errno 0',
              'send-pack: unexpected disconnect while reading sideband packet',
              'fatal: the remote end hung up unexpectedly'
            ].join('\n')
          };
        }
        if (args[0] === 'config') {
          return { status: 1, stdout: '', stderr: '' };
        }
        throw new Error(`Unexpected git args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(pushAttempts, 1);
  assert.equal(result.status, 'already-published');
  assert.equal(result.recoveredFromPushFailure, true);
  assert.equal(result.attemptCount, 1);
});

test('diverged remediation helper preserves draft state while recording the queue promotion target', () => {
  const sourcePath = path.join(repoRoot, 'tools', 'priority', 'diverged-develop-remediation-pr.mjs');
  const source = readFileSync(sourcePath, 'utf8');

  assert.match(source, /buildRepoViewArgs\(repo\)/);
  assert.doesNotMatch(source, /update-ref', localRef/);
  assert.match(source, /`\$\{syntheticCommitSha\}:\$\{remoteRef\}`/);
  assert.match(source, /isGitHubSshAuthFailure\(error\.message\)/);
  assert.match(source, /getRemoteFetchUrl\(repoRoot, targetRemote, \{ spawnSyncFn \}\)/);
  assert.match(source, /const partialReport = buildDivergedDevelopRemediationSummaryPayload\(/);
  assert.match(source, /writeReport\(reportPath, partialReport\);[\s\S]*loadRepositoryMergeSettings\(repoRoot, targetRepoSlug, \{ runGhJsonFn, spawnSyncFn \}\)/);
  assert.match(source, /const reusableReport = tryBuildReusableRemediationReport\(/);
  assert.match(source, /if \(!viewedPr\?\.number \|\| viewedPr\.isDraft !== true \|\| viewedPr\.autoMergeRequest\) \{\s*return null;\s*\}/s);
  assert.match(source, /const mergeSettings = loadRepositoryMergeSettings\(repoRoot, targetRepoSlug, \{ runGhJsonFn, spawnSyncFn \}\)/);
  assert.match(source, /promotionTarget = \{\s*syncMethod: 'pull-request-queue',\s*mergeMethod: resolveAutoMergeMethod\(mergeSettings\)\s*\}/s);
  assert.match(source, /const autoMerge = disableAutoMerge\(repoRoot, targetRepoSlug, viewedPr, \{ spawnSyncFn \}\)/);
  assert.match(source, /const draftState = ensureDraftForReview\(repoRoot, targetRepoSlug, viewedPr, \{ spawnSyncFn \}\)/);
  assert.match(source, /resolveDeterministicCommitTimestamp\(repoRoot, divergedHead, \{ spawnSyncFn \}\)/);
  assert.match(source, /const deterministicCommitEnv = buildDeterministicCommitEnv\(deterministicCommitTimestamp\)/);
});

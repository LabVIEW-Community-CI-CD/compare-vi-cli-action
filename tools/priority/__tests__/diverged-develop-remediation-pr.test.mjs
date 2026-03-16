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
  buildDeterministicCommitEnv
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

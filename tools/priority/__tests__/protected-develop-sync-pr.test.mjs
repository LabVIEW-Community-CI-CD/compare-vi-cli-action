#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  buildProtectedSyncBranchName,
  buildProtectedSyncPrBody,
  buildProtectedSyncPrTitle,
  buildProtectedSyncSummaryPayload,
  parseArgs,
  runProtectedDevelopSync
} from '../protected-develop-sync-pr.mjs';

test('parseArgs accepts protected sync options', () => {
  const options = parseArgs([
    'node',
    'protected-develop-sync-pr.mjs',
    '--target-remote',
    'origin',
    '--base-remote',
    'upstream',
    '--branch',
    'develop',
    '--sync-branch',
    'sync/origin-develop',
    '--reason',
    'protected-branch-gh013',
    '--local-head',
    'abc123',
    '--report-path',
    'custom/report.json'
  ]);

  assert.equal(options.targetRemote, 'origin');
  assert.equal(options.baseRemote, 'upstream');
  assert.equal(options.branch, 'develop');
  assert.equal(options.syncBranch, 'sync/origin-develop');
  assert.equal(options.reason, 'protected-branch-gh013');
  assert.equal(options.localHead, 'abc123');
  assert.equal(options.reportPath, 'custom/report.json');
});

test('buildProtectedSyncBranchName produces deterministic remote-specific names', () => {
  assert.equal(buildProtectedSyncBranchName('origin', 'develop'), 'sync/origin-develop');
  assert.equal(buildProtectedSyncBranchName('personal', 'release/test'), 'sync/personal-release-test');
});

test('buildProtectedSyncPrTitle and body describe protected branch staging', () => {
  assert.equal(buildProtectedSyncPrTitle({ baseRemote: 'upstream', branch: 'develop' }), '[sync]: align develop with upstream/develop');

  const body = buildProtectedSyncPrBody({
    upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
    targetRepository: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' },
    targetRemote: 'origin',
    baseRemote: 'upstream',
    branch: 'develop',
    syncBranch: 'sync/origin-develop',
    reason: 'protected-branch-gh013',
    localHead: 'abc123'
  });

  assert.match(body, /align `LabVIEW-Community-CI-CD\/compare-vi-cli-action-fork:develop` with `LabVIEW-Community-CI-CD\/compare-vi-cli-action:develop`/);
  assert.match(body, /sync branch: `sync\/origin-develop`/);
  assert.match(body, /Refs LabVIEW-Community-CI-CD\/compare-vi-cli-action#986/);
});

test('buildProtectedSyncSummaryPayload captures PR and merge request details', () => {
  const payload = buildProtectedSyncSummaryPayload({
    targetRemote: 'origin',
    baseRemote: 'upstream',
    branch: 'develop',
    syncBranch: 'sync/origin-develop',
    reason: 'protected-branch-gh013',
    localHead: 'abc123',
    upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
    targetRepository: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' },
    pullRequest: { number: 42, url: 'https://example.test/pull/42' },
    readyState: { status: 'marked-ready' },
    mergeRequest: { status: 'requested' },
    createdAt: '2026-03-12T00:00:00.000Z'
  });

  assert.equal(payload.schema, 'priority/protected-develop-sync@v1');
  assert.equal(payload.targetRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork');
  assert.equal(payload.pullRequest.number, 42);
  assert.equal(payload.readyState.status, 'marked-ready');
  assert.equal(payload.mergeRequest.status, 'requested');
});

test('runProtectedDevelopSync reuses an existing draft PR, marks it ready, and requests auto merge', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'protected-sync-pr-'));
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const reportPath = path.join(repoRoot, 'tests', 'results', '_agent', 'issue', 'origin-protected-develop-sync.json');
  const ghCalls = [];
  const prViews = [
    {
      number: 42,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/pull/42',
      state: 'OPEN',
      isDraft: true,
      headRefName: 'sync/origin-develop',
      baseRefName: 'develop',
      mergeStateStatus: 'BLOCKED'
    },
    {
      number: 42,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/pull/42',
      state: 'OPEN',
      isDraft: false,
      headRefName: 'sync/origin-develop',
      baseRefName: 'develop',
      mergeStateStatus: 'BLOCKED'
    },
    {
      number: 42,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/pull/42',
      state: 'OPEN',
      isDraft: false,
      headRefName: 'sync/origin-develop',
      baseRefName: 'develop',
      mergeStateStatus: 'QUEUED'
    }
  ];
  const updated = [];

  const { report } = runProtectedDevelopSync({
    repoRoot,
    options: {
      targetRemote: 'origin',
      baseRemote: 'upstream',
      branch: 'develop',
      syncBranch: 'sync/origin-develop',
      reason: 'protected-branch-gh013',
      localHead: 'abc123',
      reportPath
    },
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
    ensureForkRemoteFn: () => ({
      owner: 'LabVIEW-Community-CI-CD',
      repo: 'compare-vi-cli-action-fork',
      remoteName: 'origin',
      sameOwnerFork: true,
      repositoryId: 'fork-repo-id'
    }),
    runGhJsonFn: (_repoRoot, args) => {
      if (args[0] === 'pr' && args[1] === 'list') {
        return [{
          number: 42,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/pull/42',
          state: 'OPEN',
          isDraft: true,
          headRefName: 'sync/origin-develop',
          baseRefName: 'develop',
          mergeStateStatus: 'BLOCKED'
        }];
      }
      if (args[0] === 'pr' && args[1] === 'view') {
        return prViews.shift();
      }
      throw new Error(`Unexpected gh json args: ${args.join(' ')}`);
    },
    updateExistingPullRequestFn: (_repoRoot, details) => {
      updated.push(details);
    },
    spawnSyncFn: (_command, args) => {
      ghCalls.push(args);
      return { status: 0, stdout: '', stderr: '' };
    }
  });

  assert.equal(updated.length, 1);
  assert.equal(report.pullRequest.number, 42);
  assert.equal(report.pullRequest.reusedExisting, true);
  assert.equal(report.readyState.status, 'marked-ready');
  assert.equal(report.mergeRequest.status, 'requested');
  assert.equal(
    ghCalls.some((args) => args[0] === 'pr' && args[1] === 'ready' && args.includes('42')),
    true
  );
  assert.equal(
    ghCalls.some((args) => args[0] === 'pr' && args[1] === 'merge' && args.includes('--auto')),
    true
  );

  const written = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(written.pullRequest.number, 42);
  assert.equal(written.mergeRequest.status, 'requested');
});

test('runProtectedDevelopSync creates a new PR when no existing sync PR is open', async (t) => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'protected-sync-pr-create-'));
  t.after(async () => {
    await rm(repoRoot, { recursive: true, force: true });
  });

  const reportPath = path.join(repoRoot, 'tests', 'results', '_agent', 'issue', 'personal-protected-develop-sync.json');
  const created = [];

  const { report } = runProtectedDevelopSync({
    repoRoot,
    options: {
      targetRemote: 'personal',
      baseRemote: 'upstream',
      branch: 'develop',
      syncBranch: 'sync/personal-develop',
      reason: 'protected-branch-gh013',
      localHead: 'def456',
      reportPath
    },
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
    ensureForkRemoteFn: () => ({
      owner: 'svelderrainruiz',
      repo: 'compare-vi-cli-action',
      remoteName: 'personal',
      sameOwnerFork: false,
      repositoryId: null
    }),
    runGhJsonFn: (_repoRoot, args) => {
      if (args[0] === 'pr' && args[1] === 'list') {
        return [];
      }
      if (args[0] === 'pr' && args[1] === 'view') {
        return {
          number: 77,
          url: 'https://github.com/svelderrainruiz/compare-vi-cli-action/pull/77',
          state: 'OPEN',
          isDraft: false,
          headRefName: 'sync/personal-develop',
          baseRefName: 'develop',
          mergeStateStatus: 'BLOCKED'
        };
      }
      throw new Error(`Unexpected gh json args: ${args.join(' ')}`);
    },
    runGhPrCreateFn: (details) => {
      created.push(details);
      return {
        strategy: 'gh-pr-create',
        pullRequest: {
          number: 77,
          url: 'https://github.com/svelderrainruiz/compare-vi-cli-action/pull/77'
        }
      };
    },
    spawnSyncFn: () => ({ status: 0, stdout: '', stderr: '' })
  });

  assert.equal(created.length, 1);
  assert.equal(created[0].branch, 'sync/personal-develop');
  assert.equal(report.pullRequest.number, 77);
  assert.equal(report.pullRequest.reusedExisting, false);
});

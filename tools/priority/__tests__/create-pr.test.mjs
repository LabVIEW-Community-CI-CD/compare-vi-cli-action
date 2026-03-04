#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseRouterIssueNumber,
  parseCacheIssueNumber,
  resolveStandingIssueNumberForPr,
  parseIssueNumberFromBranch,
  assertBranchMatchesIssue,
  buildTitle,
  buildBody,
  createPriorityPr
} from '../create-pr.mjs';

test('parseRouterIssueNumber returns positive integer issue values', () => {
  assert.equal(parseRouterIssueNumber({ issue: 680 }), 680);
  assert.equal(parseRouterIssueNumber({ issue: '681' }), 681);
  assert.equal(parseRouterIssueNumber({ issue: 0 }), null);
  assert.equal(parseRouterIssueNumber({ issue: null }), null);
});

test('parseCacheIssueNumber accepts OPEN standing-priority cache entries', () => {
  assert.equal(
    parseCacheIssueNumber({
      number: 680,
      state: 'open',
      labels: ['standing-priority']
    }),
    680
  );
  assert.equal(
    parseCacheIssueNumber({
      number: 680,
      state: 'OPEN',
      labels: [{ name: 'fork-standing-priority' }]
    }),
    680
  );
});

test('parseCacheIssueNumber rejects closed or non-standing cache entries', () => {
  assert.equal(
    parseCacheIssueNumber({
      number: 588,
      state: 'closed',
      labels: ['standing-priority']
    }),
    null
  );
  assert.equal(
    parseCacheIssueNumber({
      number: 680,
      state: 'open',
      labels: ['bug']
    }),
    null
  );
});

test('resolveStandingIssueNumberForPr prefers router over cache', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return { issue: 680 };
      }
      return {
        number: 588,
        state: 'open',
        labels: ['standing-priority']
      };
    }
  });

  assert.deepEqual(result, { issueNumber: 680, source: 'router' });
});

test('resolveStandingIssueNumberForPr treats explicit empty router issue as authoritative', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return { issue: null };
      }
      return {
        number: 680,
        state: 'open',
        labels: ['standing-priority']
      };
    }
  });

  assert.deepEqual(result, { issueNumber: null, source: 'router' });
});

test('resolveStandingIssueNumberForPr falls back to cache when router is unavailable', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return null;
      }
      return {
        number: 680,
        state: 'open',
        labels: ['standing-priority']
      };
    }
  });

  assert.deepEqual(result, { issueNumber: 680, source: 'cache' });
});

test('parseIssueNumberFromBranch extracts issue numbers from issue/* branches', () => {
  assert.equal(parseIssueNumberFromBranch('issue/680-sync-standing-priority'), 680);
  assert.equal(parseIssueNumberFromBranch('feature/something'), null);
});

test('assertBranchMatchesIssue fails on mismatch', () => {
  assert.throws(
    () => assertBranchMatchesIssue('issue/588-old-branch', 680),
    /maps to #588, but standing priority resolves to #680/i
  );
});

test('buildTitle and buildBody honor env overrides', () => {
  assert.equal(
    buildTitle('issue/680-something', 680, { PR_TITLE: 'Custom Title' }),
    'Custom Title'
  );
  assert.equal(
    buildBody(680, { PR_BODY: 'Custom Body' }),
    'Custom Body'
  );
});

test('createPriorityPr builds PR metadata from resolved standing issue', () => {
  let pushedBranch = null;
  let prPayload = null;
  const result = createPriorityPr({
    env: {},
    getRepoRootFn: () => '/tmp/repo',
    getCurrentBranchFn: () => 'issue/680-sync-standing-priority',
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => ({ owner: 'upstream-owner', repo: 'repo' }),
    ensureOriginForkFn: () => ({ owner: 'fork-owner', repo: 'repo' }),
    pushBranchFn: (_repoRoot, branch) => {
      pushedBranch = branch;
    },
    runGhPrCreateFn: (payload) => {
      prPayload = payload;
    },
    resolveStandingIssueNumberFn: () => ({ issueNumber: 680, source: 'router' })
  });

  assert.equal(pushedBranch, 'issue/680-sync-standing-priority');
  assert.ok(prPayload);
  assert.equal(prPayload.base, 'develop');
  assert.equal(prPayload.title, 'Update for standing priority #680');
  assert.match(prPayload.body, /Closes #680/);
  assert.equal(result.issueNumber, 680);
  assert.equal(result.issueSource, 'router');
});

test('createPriorityPr fails before PR creation when branch issue mismatches standing issue', () => {
  let prCreated = false;
  assert.throws(
    () =>
      createPriorityPr({
        env: {},
        getRepoRootFn: () => '/tmp/repo',
        getCurrentBranchFn: () => 'issue/588-closed',
        ensureGhCliFn: () => {},
        resolveUpstreamFn: () => ({ owner: 'upstream-owner', repo: 'repo' }),
        ensureOriginForkFn: () => ({ owner: 'fork-owner', repo: 'repo' }),
        pushBranchFn: () => {},
        runGhPrCreateFn: () => {
          prCreated = true;
        },
        resolveStandingIssueNumberFn: () => ({ issueNumber: 680, source: 'router' })
      }),
    /maps to #588, but standing priority resolves to #680/i
  );
  assert.equal(prCreated, false);
});

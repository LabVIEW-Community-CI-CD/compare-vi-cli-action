#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildRouteTitle,
  computeLabelDiff,
  parseArgs,
  runIssueRouter,
  selectCanonicalIssue
} from '../issue-router.mjs';

function sampleDecisionReport(overrides = {}) {
  return {
    schema: 'priority/policy-decision-report@v1',
    evaluation: {
      selectedRuleId: 'workflow-failure'
    },
    decision: {
      type: 'open-issue',
      priority: 'P1',
      labels: ['ci', 'governance'],
      owner: 'release-platform',
      titlePrefix: '[Workflow Incident]',
      reason: 'workflow-failure'
    },
    event: {
      schema: 'incident-event@v1',
      sourceType: 'workflow-run',
      incidentClass: 'workflow-run-failure',
      severity: 'high',
      branch: 'develop',
      sha: 'abc123',
      signature: 'validate:failure',
      fingerprint: 'incident-fp-1',
      repository: 'example/repo',
      suggestedLabels: ['ci']
    },
    ...overrides
  };
}

test('parseArgs requires decision path and supports apply mode', () => {
  const parsed = parseArgs([
    'node',
    'issue-router.mjs',
    '--decision',
    'decision.json',
    '--event',
    'event.json',
    '--report',
    'report.json',
    '--repo',
    'owner/repo',
    '--apply'
  ]);

  assert.equal(parsed.decisionPath, 'decision.json');
  assert.equal(parsed.eventPath, 'event.json');
  assert.equal(parsed.reportPath, 'report.json');
  assert.equal(parsed.repo, 'owner/repo');
  assert.equal(parsed.dryRun, false);
});

test('selectCanonicalIssue prefers open and oldest created issue', () => {
  const canonical = selectCanonicalIssue([
    { number: 9, state: 'closed', created_at: '2026-03-06T20:00:00Z' },
    { number: 8, state: 'open', created_at: '2026-03-06T22:00:00Z' },
    { number: 7, state: 'open', created_at: '2026-03-06T21:00:00Z' }
  ]);

  assert.equal(canonical.number, 7);
  assert.equal(canonical.state, 'open');
});

test('computeLabelDiff is deterministic and set-based', () => {
  const diff = computeLabelDiff(['CI', 'governance', 'ci'], ['ci', 'ops']);
  assert.deepEqual(diff.desired, ['ci', 'governance']);
  assert.deepEqual(diff.observed, ['ci', 'ops']);
  assert.deepEqual(diff.added, ['governance']);
  assert.deepEqual(diff.removed, ['ops']);
  assert.equal(diff.exactMatch, false);
});

test('runIssueRouter dry-run reports would-create and avoids writes', async () => {
  const writes = [];
  const requests = [];
  const decision = sampleDecisionReport();
  const result = await runIssueRouter(
    {
      decisionPath: 'decision.json',
      reportPath: 'report.json',
      dryRun: true
    },
    {
      now: new Date('2026-03-06T23:00:00Z'),
      readJsonFileFn: async () => decision,
      writeJsonFn: (filePath, payload) => {
        writes.push({ filePath, payload });
        return filePath;
      },
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => 'token',
      requestGitHubJsonFn: async (url) => {
        requests.push(url);
        if (url.includes('/search/issues')) {
          return { items: [] };
        }
        throw new Error(`unexpected request: ${url}`);
      }
    }
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.route.operation.action, 'would-create');
  assert.equal(result.report.route.operation.wrote, false);
  assert.equal(result.report.route.dedupe.candidateCount, 0);
  assert.equal(writes.length, 1);
  assert.equal(requests.length, 1);
});

test('runIssueRouter apply mode updates canonical issue and does not create duplicate', async () => {
  const calls = [];
  const decision = sampleDecisionReport();
  const result = await runIssueRouter(
    {
      decisionPath: 'decision.json',
      reportPath: 'report.json',
      dryRun: false
    },
    {
      now: new Date('2026-03-06T23:01:00Z'),
      readJsonFileFn: async () => decision,
      writeJsonFn: (filePath, payload) => filePath,
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => 'token',
      requestGitHubJsonFn: async (url, options = {}) => {
        calls.push({ url, method: options.method || 'GET', body: options.body ?? null });
        if (url.includes('/search/issues')) {
          return { items: [{ number: 200 }, { number: 201 }] };
        }
        if (url.endsWith('/issues/200') && (options.method || 'GET') === 'GET') {
          return {
            number: 200,
            state: 'open',
            title: 'stale-title',
            body: 'stale-body',
            labels: [{ name: 'ci' }],
            created_at: '2026-03-06T20:00:00Z',
            html_url: 'https://example.test/issues/200'
          };
        }
        if (url.endsWith('/issues/201') && (options.method || 'GET') === 'GET') {
          return {
            number: 201,
            state: 'closed',
            title: 'older-duplicate',
            body: 'duplicate-body',
            labels: [{ name: 'ci' }],
            created_at: '2026-03-06T20:10:00Z',
            html_url: 'https://example.test/issues/201'
          };
        }
        if (url.endsWith('/issues/200') && options.method === 'PATCH') {
          return {
            number: 200,
            state: 'open',
            title: options.body.title,
            body: options.body.body,
            labels: (options.body.labels || []).map((label) => ({ name: label })),
            created_at: '2026-03-06T20:00:00Z',
            html_url: 'https://example.test/issues/200'
          };
        }
        throw new Error(`unexpected request: ${options.method || 'GET'} ${url}`);
      }
    }
  );

  const postCreate = calls.find((entry) => entry.url.endsWith('/issues') && entry.method === 'POST');
  const patchCanonical = calls.find((entry) => entry.url.endsWith('/issues/200') && entry.method === 'PATCH');
  assert.equal(postCreate, undefined);
  assert.ok(patchCanonical);
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.route.dedupe.candidateCount, 2);
  assert.equal(result.report.route.dedupe.canonicalIssueNumber, 200);
  assert.equal(result.report.route.operation.action, 'update');
});

test('runIssueRouter apply mode reopens closed canonical issue before update', async () => {
  const calls = [];
  const decision = sampleDecisionReport();
  const result = await runIssueRouter(
    {
      decisionPath: 'decision.json',
      reportPath: 'report.json',
      dryRun: false
    },
    {
      now: new Date('2026-03-06T23:02:00Z'),
      readJsonFileFn: async () => decision,
      writeJsonFn: (filePath) => filePath,
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => 'token',
      requestGitHubJsonFn: async (url, options = {}) => {
        calls.push({ url, method: options.method || 'GET', body: options.body ?? null });
        if (url.includes('/search/issues')) {
          return { items: [{ number: 300 }] };
        }
        if (url.endsWith('/issues/300') && (options.method || 'GET') === 'GET') {
          return {
            number: 300,
            state: 'closed',
            title: 'closed-title',
            body: 'closed-body',
            labels: [{ name: 'ci' }],
            created_at: '2026-03-06T19:00:00Z',
            html_url: 'https://example.test/issues/300'
          };
        }
        if (url.endsWith('/issues/300') && options.method === 'PATCH' && options.body?.state === 'open') {
          return {
            number: 300,
            state: 'open',
            title: 'closed-title',
            body: 'closed-body',
            labels: [{ name: 'ci' }],
            created_at: '2026-03-06T19:00:00Z',
            html_url: 'https://example.test/issues/300'
          };
        }
        if (url.endsWith('/issues/300') && options.method === 'PATCH' && options.body?.title) {
          return {
            number: 300,
            state: 'open',
            title: options.body.title,
            body: options.body.body,
            labels: (options.body.labels || []).map((label) => ({ name: label })),
            created_at: '2026-03-06T19:00:00Z',
            html_url: 'https://example.test/issues/300'
          };
        }
        throw new Error(`unexpected request: ${options.method || 'GET'} ${url}`);
      }
    }
  );

  const reopenCall = calls.find((entry) => entry.url.endsWith('/issues/300') && entry.method === 'PATCH' && entry.body?.state === 'open');
  const updateCall = calls.find((entry) => entry.url.endsWith('/issues/300') && entry.method === 'PATCH' && entry.body?.title);
  assert.ok(reopenCall);
  assert.ok(updateCall);
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.route.operation.action, 'reopen-update');
});

test('buildRouteTitle includes priority, prefix, class, and branch', () => {
  const title = buildRouteTitle({
    event: {
      incidentClass: 'required-check-drift',
      branch: 'develop'
    },
    decision: {
      priority: 'P0',
      titlePrefix: '[Policy Drift]'
    }
  });
  assert.equal(title, '[P0] [Policy Drift] required-check-drift @ develop');
});

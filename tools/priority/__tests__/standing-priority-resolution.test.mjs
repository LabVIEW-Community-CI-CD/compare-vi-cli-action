#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  parseCliArgs,
  buildNoStandingPriorityReport,
  buildMultipleStandingPriorityReport,
  buildNoStandingPriorityState,
  determinePrioritySyncExitCode,
  isStandingPriorityCacheCandidate,
  resolveStandingPriorityLabels,
  resolveStandingPriorityFromSources,
  resolveUpstreamRepositorySlug,
  resolveStandingPriorityLookupPlan,
  resolveStandingPriorityForRepo,
  fetchIssue,
  computeNextPriorityCacheState,
  gitRoot
} from '../sync-standing-priority.mjs';

test('isStandingPriorityCacheCandidate requires OPEN state and matching standing label', () => {
  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'OPEN',
      labels: ['bug', 'standing-priority']
    }),
    true
  );

  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'CLOSED',
      labels: ['standing-priority']
    }),
    false
  );

  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'OPEN',
      labels: ['bug']
    }),
    false
  );
});

test('resolveStandingPriorityFromSources uses cache only when lookups are unavailable and cache is valid', () => {
  const number = resolveStandingPriorityFromSources({
    ghOutcome: { status: 'unavailable', error: 'gh missing' },
    restOutcome: { status: 'error', error: 'network timeout' },
    standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
    cache: {
      number: 99,
      state: 'OPEN',
      labels: ['standing-priority']
    }
  });
  assert.equal(number, 99);
});

test('resolveStandingPriorityFromSources rejects stale cache when gh reports empty standing set', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'empty' },
        restOutcome: { status: 'error', error: 'network timeout' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'OPEN',
          labels: ['standing-priority']
        }
      }),
    (err) => err?.code === 'NO_STANDING_PRIORITY'
  );
});

test('resolveStandingPriorityFromSources rejects stale cache when rest reports empty standing set', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'error', error: 'gh unavailable' },
        restOutcome: { status: 'empty' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'OPEN',
          labels: ['standing-priority']
        }
      }),
    (err) => err?.code === 'NO_STANDING_PRIORITY'
  );
});

test('resolveStandingPriorityFromSources fails when only invalid cache remains', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'unavailable', error: 'gh missing' },
        restOutcome: { status: 'error', error: 'network timeout' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'CLOSED',
          labels: ['standing-priority']
        }
      }),
    /Unable to resolve standing-priority issue number/
  );
});

test('buildNoStandingPriorityState clears router/cache deterministically', () => {
  const state = buildNoStandingPriorityState(
    {
      number: 12,
      title: 'Old',
      state: 'OPEN',
      labels: ['standing-priority']
    },
    'No open issue found with labels: `fork-standing-priority`, `standing-priority`.',
    '2026-03-03T03:10:00.000Z',
    ['fork-standing-priority', 'standing-priority']
  );

  assert.equal(state.clearedRouter.issue, null);
  assert.deepEqual(state.clearedRouter.actions, []);
  assert.equal(state.clearedCache.number, null);
  assert.equal(state.clearedCache.state, 'NONE');
  assert.equal(
    state.clearedCache.lastFetchError,
    'No open issue found with labels: `fork-standing-priority`, `standing-priority`.'
  );
  assert.equal(state.result.fetchSource, 'none');
});

test('resolveStandingPriorityLabels prefers fork-standing-priority when configured upstream differs', () => {
  const labels = resolveStandingPriorityLabels(
    '/tmp/repo',
    'fork-owner/compare-vi-cli-action',
    {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action'
    }
  );
  assert.deepEqual(labels, ['fork-standing-priority', 'standing-priority']);
});

test('resolveStandingPriorityLabels defaults to standing-priority when upstream matches current repository', () => {
  const currentSlug = 'repo-owner/compare-vi-cli-action';
  const labels = resolveStandingPriorityLabels(
    '/tmp/repo',
    currentSlug,
    {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: currentSlug
    }
  );
  assert.deepEqual(labels, ['standing-priority']);
});

test('resolveStandingPriorityLabels honors explicit env override order', () => {
  const labels = resolveStandingPriorityLabels('/tmp/repo', null, {
    AGENT_STANDING_PRIORITY_LABELS: 'custom-one, custom-two, custom-one'
  });
  assert.deepEqual(labels, ['custom-one', 'custom-two']);
});

test('determinePrioritySyncExitCode maps no-standing to success and real errors to failure', () => {
  assert.equal(determinePrioritySyncExitCode(null), 0);
  assert.equal(determinePrioritySyncExitCode({ code: 'NO_STANDING_PRIORITY' }), 0);
  assert.equal(determinePrioritySyncExitCode({ code: 'NO_STANDING_PRIORITY' }, { failOnMissing: true }), 1);
  assert.equal(determinePrioritySyncExitCode({ code: 'MULTIPLE_STANDING_PRIORITY' }), 0);
  assert.equal(determinePrioritySyncExitCode({ code: 'MULTIPLE_STANDING_PRIORITY' }, { failOnMultiple: true }), 1);
  assert.equal(determinePrioritySyncExitCode(new Error('boom')), 1);
});

test('parseCliArgs enables strict standing-priority flags and help', () => {
  const parsed = parseCliArgs(['node', 'sync-standing-priority.mjs', '--fail-on-missing']);
  assert.equal(parsed.failOnMissing, true);
  assert.equal(parsed.failOnMultiple, false);
  assert.equal(parsed.help, false);

  const parsedMulti = parseCliArgs(['node', 'sync-standing-priority.mjs', '--fail-on-multiple']);
  assert.equal(parsedMulti.failOnMultiple, true);
  assert.equal(parsedMulti.failOnMissing, false);

  const help = parseCliArgs(['node', 'sync-standing-priority.mjs', '--help']);
  assert.equal(help.help, true);
});

test('buildNoStandingPriorityReport emits deterministic schema payload', () => {
  const report = buildNoStandingPriorityReport({
    message: 'No open issue found',
    labels: ['fork-standing-priority', 'standing-priority'],
    repository: 'owner/repo',
    failOnMissing: true,
    generatedAt: '2026-03-05T22:30:00.000Z'
  });
  assert.deepEqual(report, {
    schema: 'standing-priority/no-standing@v1',
    generatedAt: '2026-03-05T22:30:00.000Z',
    repository: 'owner/repo',
    labels: ['fork-standing-priority', 'standing-priority'],
    message: 'No open issue found',
    failOnMissing: true
  });
});

test('buildMultipleStandingPriorityReport emits deterministic schema payload', () => {
  const report = buildMultipleStandingPriorityReport({
    message: 'Multiple open standing-priority issues found',
    labels: ['standing-priority'],
    repository: 'owner/repo',
    issueNumbers: [743, 732],
    failOnMultiple: true,
    generatedAt: '2026-03-06T02:00:00.000Z'
  });

  assert.deepEqual(report, {
    schema: 'standing-priority/multiple-standing@v1',
    generatedAt: '2026-03-06T02:00:00.000Z',
    repository: 'owner/repo',
    labels: ['standing-priority'],
    issueNumbers: [743, 732],
    message: 'Multiple open standing-priority issues found',
    failOnMultiple: true
  });
});


test('resolveUpstreamRepositorySlug prefers upstream remote when fork slug is active', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-upstream-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const gitDir = path.join(repoRoot, '.git');
  await mkdir(gitDir, { recursive: true });
  await writeFile(
    path.join(gitDir, 'config'),
    '[remote "origin"]\n  url = https://github.com/svelderrainruiz/compare-vi-cli-action.git\n[remote "upstream"]\n  url = https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action.git\n',
    'utf8'
  );

  const upstream = resolveUpstreamRepositorySlug(repoRoot, 'svelderrainruiz/compare-vi-cli-action');
  assert.equal(upstream, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
});

test('resolveUpstreamRepositorySlug returns null when upstream remote is missing', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-upstream-fallback-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const gitDir = path.join(repoRoot, '.git');
  await mkdir(gitDir, { recursive: true });
  await writeFile(
    path.join(gitDir, 'config'),
    '[remote "origin"]\n  url = https://github.com/svelderrainruiz/compare-vi-cli-action.git\n',
    'utf8'
  );

  const upstream = resolveUpstreamRepositorySlug(repoRoot, 'svelderrainruiz/compare-vi-cli-action');
  assert.equal(upstream, null);
});

test('resolveUpstreamRepositorySlug honors explicit env override', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-upstream-env-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const upstream = resolveUpstreamRepositorySlug(
    repoRoot,
    'fork-owner/compare-vi-cli-action',
    { AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action' }
  );
  assert.equal(upstream, 'upstream-owner/compare-vi-cli-action');
});

test('resolveStandingPriorityLookupPlan checks upstream when fork lookup reports empty', async () => {
  const calls = [];
  const warnings = [];
  const resolveForRepo = async (_repoRoot, targetSlug, labels) => {
    calls.push({ targetSlug, labels });
    if (calls.length === 1) {
      return {
        found: null,
        ghOutcome: { status: 'empty' },
        restOutcome: { status: 'empty' },
        repoSlug: targetSlug
      };
    }

    return {
      found: {
        number: 321,
        label: 'standing-priority',
        repoSlug: targetSlug,
        source: 'mock'
      },
      ghOutcome: { status: 'found', label: 'standing-priority' },
      restOutcome: { status: 'unavailable', error: 'not-used' },
      repoSlug: targetSlug
    };
  };

  const result = await resolveStandingPriorityLookupPlan({
    repoRoot: '/tmp/repo',
    slug: 'fork-owner/compare-vi-cli-action',
    standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
    resolveForRepo,
    resolveUpstreamSlug: () => 'labview-community-ci-cd/compare-vi-cli-action',
    warn: (message) => warnings.push(message)
  });

  assert.equal(result.found?.number, 321);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], {
    targetSlug: 'fork-owner/compare-vi-cli-action',
    labels: ['fork-standing-priority', 'standing-priority']
  });
  assert.deepEqual(calls[1], {
    targetSlug: 'labview-community-ci-cd/compare-vi-cli-action',
    labels: ['standing-priority']
  });
  assert.equal(warnings.length, 1);
});

test('gitRoot uses injected fallback root when git rev-parse is unavailable', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'priority-gitroot-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));
  await writeFile(path.join(repoRoot, 'package.json'), '{}\n', 'utf8');

  const warnings = [];
  const resolved = gitRoot({
    commandRunner: () => ({ status: 1, stdout: '', stderr: 'fatal: not a git repository', error: { code: 'EPERM' } }),
    fallbackRoot: repoRoot,
    warn: (message) => warnings.push(message)
  });

  assert.equal(resolved, repoRoot);
  assert.equal(warnings.length, 1);
});

test('resolveStandingPriorityForRepo accepts injected GH/REST transports', async () => {
  const calls = [];
  const result = await resolveStandingPriorityForRepo(
    '/tmp/repo',
    'fork-owner/compare-vi-cli-action',
    ['fork-standing-priority', 'standing-priority'],
    {
      runGhList: async ({ slug, label }) => {
        calls.push({ type: 'gh', slug, label });
        return { status: 0, stdout: '[]', stderr: '' };
      },
      runRestLookup: async ({ slug, standingPriorityLabels }) => {
        calls.push({ type: 'rest', slug, labels: standingPriorityLabels });
        return {
          status: 'found',
          number: 777,
          label: 'standing-priority',
          repoSlug: slug
        };
      },
      warn: () => {}
    }
  );

  assert.equal(result.found?.number, 777);
  assert.equal(calls.filter((entry) => entry.type === 'gh').length, 2);
  assert.equal(calls.filter((entry) => entry.type === 'rest').length, 1);
});

test('fetchIssue uses injected ghIssueFetcher before restIssueFetcher', async () => {
  const calls = [];
  const issue = await fetchIssue(41, '/tmp/repo', 'fork-owner/compare-vi-cli-action', {
    ghIssueFetcher: async ({ args }) => {
      calls.push(['gh', args[0]]);
      return {
        number: 41,
        title: 'Injected GH Issue',
        state: 'open',
        updatedAt: '2026-03-01T00:00:00Z',
        url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/41',
        labels: [{ name: 'standing-priority' }],
        assignees: [{ login: 'agent' }],
        milestone: { title: 'M1' },
        comments: 4,
        body: 'body'
      };
    },
    restIssueFetcher: async () => {
      calls.push(['rest']);
      return null;
    }
  });

  assert.equal(issue.number, 41);
  assert.deepEqual(issue.labels, ['standing-priority']);
  assert.deepEqual(issue.assignees, ['agent']);
  assert.equal(calls.some((entry) => entry[0] === 'rest'), false);
});

test('fetchIssue falls back to injected restIssueFetcher when GH fetcher returns null', async () => {
  const issue = await fetchIssue(42, '/tmp/repo', 'fork-owner/compare-vi-cli-action', {
    ghIssueFetcher: async () => null,
    restIssueFetcher: async () => ({
      number: 42,
      title: 'Injected REST Issue',
      state: 'open',
      updated_at: '2026-03-02T00:00:00Z',
      html_url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/42',
      labels: [{ name: 'fork-standing-priority' }],
      assignees: [{ login: 'fallback' }],
      milestone: { title: 'M2' },
      comments: 2,
      body: 'rest body'
    })
  });

  assert.equal(issue.number, 42);
  assert.deepEqual(issue.labels, ['fork-standing-priority']);
  assert.deepEqual(issue.assignees, ['fallback']);
});

test('computeNextPriorityCacheState returns deterministic cache projection', () => {
  const next = computeNextPriorityCacheState({
    cache: {
      repository: 'old/repo',
      title: 'Old',
      labels: ['old-label'],
      assignees: ['old-user']
    },
    number: 9,
    issueRepoSlug: 'new/repo',
    snapshot: {
      title: 'New title',
      url: 'https://example.test/issues/9',
      state: 'OPEN',
      labels: ['standing-priority'],
      assignees: ['agent'],
      milestone: null,
      commentCount: 3,
      updatedAt: '2026-03-03T00:00:00Z',
      digest: 'digest',
      bodyDigest: 'body-digest'
    },
    fetchSource: 'cache',
    fetchError: 'none',
    cachedAtUtc: '2026-03-04T00:00:00Z'
  });

  assert.equal(next.repository, 'new/repo');
  assert.equal(next.number, 9);
  assert.deepEqual(next.labels, ['standing-priority']);
  assert.equal(next.lastFetchSource, 'cache');
  assert.equal(next.cachedAtUtc, '2026-03-04T00:00:00Z');
});

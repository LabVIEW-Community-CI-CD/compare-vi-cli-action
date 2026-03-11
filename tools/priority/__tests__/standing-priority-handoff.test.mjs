#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { handoffStandingPriority } from '../standing-priority-handoff.mjs';

test('handoffStandingPriority normalizes fork standing labels and syncs cache', async () => {
  const calls = [];
  let leaseReleaseCount = 0;
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label') && args.includes('fork-standing-priority')) {
      return JSON.stringify([
        {
          number: 317,
          title: 'Current fork standing issue',
          labels: [{ name: 'fork-standing-priority' }],
          url: 'https://github.com/example/repo/issues/317'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label') && args.includes('standing-priority')) {
      return JSON.stringify([
        {
          number: 315,
          title: 'Legacy-labelled target',
          labels: [{ name: 'standing-priority' }],
          url: 'https://github.com/example/repo/issues/315'
        },
        {
          number: 317,
          title: 'Current fork standing issue',
          labels: [{ name: 'fork-standing-priority' }],
          url: 'https://github.com/example/repo/issues/317'
        }
      ]);
    }
    return '';
  };
  let syncCount = 0;
  const syncFn = async () => {
    syncCount += 1;
  };
  const leaseReleaseFn = async () => {
    leaseReleaseCount += 1;
    return { status: 'released' };
  };

  await handoffStandingPriority(315, {
    ghRunner,
    syncFn,
    leaseReleaseFn,
    logger: () => {},
    env: {
      GITHUB_REPOSITORY: 'fork-owner/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action'
    }
  });

  assert.deepEqual(calls, [
    [
      'issue',
      'list',
      '--repo',
      'fork-owner/compare-vi-cli-action',
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url',
      '--label',
      'fork-standing-priority'
    ],
    [
      'issue',
      'list',
      '--repo',
      'fork-owner/compare-vi-cli-action',
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url',
      '--label',
      'standing-priority'
    ],
    ['issue', 'edit', '317', '--remove-label', 'fork-standing-priority'],
    ['issue', 'edit', '315', '--remove-label', 'standing-priority', '--add-label', 'fork-standing-priority']
  ]);
  assert.equal(syncCount, 1);
  assert.equal(leaseReleaseCount, 1);
});

test('handoffStandingPriority auto-selects the next actionable issue and skips cadence alerts', async () => {
  const calls = [];
  let syncCount = 0;
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([
        {
          number: 317,
          title: 'Current standing issue',
          labels: [{ name: 'fork-standing-priority' }],
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'list' && !args.includes('--label')) {
      return JSON.stringify([
        {
          number: 299,
          title: '[cadence] Package stream freshness alert',
          body: '<!-- cadence-check:package-staleness -->',
          labels: [{ name: 'ci' }],
          createdAt: '2026-03-01T00:00:00Z',
          updatedAt: '2026-03-01T00:00:00Z'
        },
        {
          number: 315,
          title: '[P1] Real development issue',
          body: 'Implement follow-up',
          labels: [{ name: 'ci' }],
          createdAt: '2026-03-02T00:00:00Z',
          updatedAt: '2026-03-02T00:00:00Z'
        },
        {
          number: 317,
          title: '[P0] Current standing issue',
          body: 'Already active',
          labels: [{ name: 'fork-standing-priority' }],
          createdAt: '2026-03-03T00:00:00Z',
          updatedAt: '2026-03-03T00:00:00Z'
        }
      ]);
    }
    return '';
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    syncFn: async () => {
      syncCount += 1;
    },
    leaseReleaseFn: async () => ({ status: 'released' }),
    logger: () => {},
    env: {
      GITHUB_REPOSITORY: 'fork-owner/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action'
    }
  });

  assert.deepEqual(calls, [
    [
      'issue',
      'list',
      '--repo',
      'fork-owner/compare-vi-cli-action',
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url',
      '--label',
      'fork-standing-priority'
    ],
    [
      'issue',
      'list',
      '--repo',
      'fork-owner/compare-vi-cli-action',
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url',
      '--label',
      'standing-priority'
    ],
    [
      'issue',
      'list',
      '--repo',
      'fork-owner/compare-vi-cli-action',
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url'
    ],
    ['issue', 'edit', '317', '--remove-label', 'fork-standing-priority'],
    ['issue', 'edit', '315', '--add-label', 'fork-standing-priority']
  ]);
  assert.equal(syncCount, 1);
});

test('handoffStandingPriority dry-run only inspects current issues and candidate pool', async () => {
  const calls = [];
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([{ number: 531, labels: [{ name: 'standing-priority' }] }]);
    }
    if (args[0] === 'issue' && args[1] === 'list') {
      return JSON.stringify([{ number: 532, title: 'Next issue', labels: [], createdAt: '2026-03-03T00:00:00Z' }]);
    }
    return '';
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    dryRun: true,
    leaseReleaseFn: async () => ({ status: 'released' }),
    logger: () => {},
    env: {
      GITHUB_REPOSITORY: 'owner/repo',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'owner/repo'
    }
  });

  assert.deepEqual(calls, [
    [
      'issue',
      'list',
      '--repo',
      'owner/repo',
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url',
      '--label',
      'standing-priority'
    ],
    [
      'issue',
      'list',
      '--repo',
      'owner/repo',
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url'
    ]
  ]);
});

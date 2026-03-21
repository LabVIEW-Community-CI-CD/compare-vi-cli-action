#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { handoffStandingPriority } from '../standing-priority-handoff.mjs';

function buildExternalIssueStateFetcher(issueStates = {}) {
  const overrides = new Map(
    Object.entries(issueStates).map(([issueNumber, state]) => [Number.parseInt(issueNumber, 10), state])
  );

  return async (issueNumber) => {
    const state = overrides.get(issueNumber) ?? 'open';
    if (state instanceof Error) {
      throw state;
    }
    return {
      number: issueNumber,
      state
    };
  };
}

test('handoffStandingPriority normalizes fork standing labels and syncs cache', async () => {
  const calls = [];
  const patchCalls = [];
  const issues = new Map([
    [315, { number: 315, title: 'Legacy-labelled target', labels: [{ name: 'standing-priority' }], url: 'https://github.com/example/repo/issues/315' }],
    [317, { number: 317, title: 'Current fork standing issue', labels: [{ name: 'fork-standing-priority' }], url: 'https://github.com/example/repo/issues/317' }]
  ]);
  let leaseReleaseCount = 0;
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label') && args.includes('fork-standing-priority')) {
      return JSON.stringify([issues.get(317)]);
    }
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label') && args.includes('standing-priority')) {
      return JSON.stringify([issues.get(315), issues.get(317)]);
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };
  let syncCount = 0;
  let syncArgs = null;
  const syncFn = async (args = {}) => {
    syncCount += 1;
    syncArgs = args;
  };
  const leaseReleaseFn = async () => {
    leaseReleaseCount += 1;
    return { status: 'released' };
  };
  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };

  await handoffStandingPriority(315, {
    ghRunner,
    patchIssueLabelsFn,
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
    ['issue', 'view', '317', '--repo', 'fork-owner/compare-vi-cli-action', '--json', 'number,title,body,labels,createdAt,updatedAt,url,state'],
    ['issue', 'view', '315', '--repo', 'fork-owner/compare-vi-cli-action', '--json', 'number,title,body,labels,createdAt,updatedAt,url,state']
  ]);
  assert.deepEqual(patchCalls, [
    { issueNumber: 317, labels: [] },
    { issueNumber: 315, labels: ['fork-standing-priority'] }
  ]);
  assert.equal(syncCount, 1);
  assert.equal(syncArgs?.env?.GITHUB_REPOSITORY, 'fork-owner/compare-vi-cli-action');
  assert.equal(syncArgs?.env?.AGENT_PRIORITY_UPSTREAM_REPOSITORY, 'upstream-owner/compare-vi-cli-action');
  assert.equal(leaseReleaseCount, 1);
});

test('handoffStandingPriority strips stale fork standing labels during an upstream handoff', async () => {
  const calls = [];
  const patchCalls = [];
  const issues = new Map([
    [
      315,
      {
        number: 315,
        title: 'Target issue with stale mixed standing labels',
        labels: [{ name: 'standing-priority' }, { name: 'fork-standing-priority' }],
        url: 'https://github.com/example/repo/issues/315'
      }
    ],
    [
      317,
      {
        number: 317,
        title: 'Current upstream standing issue',
        labels: [{ name: 'standing-priority' }],
        url: 'https://github.com/example/repo/issues/317'
      }
    ]
  ]);

  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label') && args.includes('standing-priority')) {
      return JSON.stringify([issues.get(315), issues.get(317)]);
    }
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label') && args.includes('fork-standing-priority')) {
      return JSON.stringify([issues.get(315)]);
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };

  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };

  await handoffStandingPriority(315, {
    ghRunner,
    patchIssueLabelsFn,
    syncFn: async () => {},
    leaseReleaseFn: async () => ({ status: 'released' }),
    logger: () => {},
    env: {
      GITHUB_REPOSITORY: 'upstream-owner/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action'
    }
  });

  assert.ok(
    calls.some(
      (args) =>
        args[0] === 'issue' &&
        args[1] === 'list' &&
        args.includes('--label') &&
        args.includes('fork-standing-priority')
    )
  );
  assert.deepEqual(patchCalls, [
    { issueNumber: 317, labels: [] },
    { issueNumber: 315, labels: ['standing-priority'] }
  ]);
});

test('handoffStandingPriority auto-selects the next actionable issue and skips cadence alerts', async () => {
  const calls = [];
  const patchCalls = [];
  const issues = new Map([
    [315, { number: 315, title: '[P1] Real development issue', labels: [] }],
    [317, { number: 317, title: 'Current standing issue', labels: [{ name: 'fork-standing-priority' }] }]
  ]);
  let syncCount = 0;
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([
        {
          ...issues.get(317),
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
          ...issues.get(317),
          title: '[P0] Current standing issue',
          body: 'Already active',
          createdAt: '2026-03-03T00:00:00Z',
          updatedAt: '2026-03-03T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };
  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    patchIssueLabelsFn,
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
    ['issue', 'view', '317', '--repo', 'fork-owner/compare-vi-cli-action', '--json', 'number,title,body,labels,createdAt,updatedAt,url,state'],
    ['issue', 'view', '315', '--repo', 'fork-owner/compare-vi-cli-action', '--json', 'number,title,body,labels,createdAt,updatedAt,url,state']
  ]);
  assert.deepEqual(patchCalls, [
    { issueNumber: 317, labels: [] },
    { issueNumber: 315, labels: ['fork-standing-priority'] }
  ]);
  assert.equal(syncCount, 1);
});

test('handoffStandingPriority auto-selects an actionable coding lane over a passive platform-stale tracker', async () => {
  const calls = [];
  const patchCalls = [];
  const issues = new Map([
    [1510, { number: 1510, title: '[P1] Build a cross-repo standing-lane marketplace for autonomous worker allocation', labels: [] }],
    [317, { number: 317, title: 'Current standing issue', labels: [{ name: 'fork-standing-priority' }] }]
  ]);
  let syncCount = 0;
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([
        {
          ...issues.get(317),
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'list' && !args.includes('--label')) {
      return JSON.stringify([
        {
          number: 1426,
          title: 'Track stale Dependabot alerts after npm remediation on develop',
          body: [
            'tools/priority/security-intake.mjs now classifies the current state as platform-stale.',
            'This follow-up tracks the remaining GitHub dependency-graph / Dependabot refresh lag until the platform state catches up.',
            'Dependabot alerts auto-close or are otherwise reconciled by GitHub.'
          ].join('\n'),
          labels: [],
          createdAt: '2026-03-01T00:00:00Z',
          updatedAt: '2026-03-01T00:00:00Z'
        },
        {
          ...issues.get(1510),
          body: 'Actionable in-repo coding work remains.',
          labels: [{ name: 'ci' }],
          createdAt: '2026-03-02T00:00:00Z',
          updatedAt: '2026-03-02T00:00:00Z'
        },
        {
          ...issues.get(317),
          title: '[P0] Current standing issue',
          body: 'Already active',
          createdAt: '2026-03-03T00:00:00Z',
          updatedAt: '2026-03-03T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };
  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    patchIssueLabelsFn,
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
    ['issue', 'view', '317', '--repo', 'fork-owner/compare-vi-cli-action', '--json', 'number,title,body,labels,createdAt,updatedAt,url,state'],
    ['issue', 'view', '1510', '--repo', 'fork-owner/compare-vi-cli-action', '--json', 'number,title,body,labels,createdAt,updatedAt,url,state']
  ]);
  assert.deepEqual(patchCalls, [
    { issueNumber: 317, labels: [] },
    { issueNumber: 1510, labels: ['fork-standing-priority'] }
  ]);
  assert.equal(syncCount, 1);
});

test('handoffStandingPriority uses the caller gh transport to hydrate blocked rollout candidates before auto-selecting', async () => {
  const calls = [];
  const patchCalls = [];
  const issues = new Map([
    [315, { number: 315, title: '[P1] Real development issue', labels: [] }],
    [317, { number: 317, title: 'Current standing issue', labels: [{ name: 'fork-standing-priority' }] }]
  ]);
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([
        {
          ...issues.get(317),
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'list' && !args.includes('--label')) {
      return JSON.stringify([
        {
          number: 314,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: [],
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
          ...issues.get(317),
          title: '[P0] Current standing issue',
          body: 'Already active',
          createdAt: '2026-03-03T00:00:00Z',
          updatedAt: '2026-03-03T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'view' && args[2] === '314') {
      return JSON.stringify({
        number: 314,
        title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
        body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
        labels: [],
        createdAt: '2026-03-01T00:00:00Z',
        updatedAt: '2026-03-01T00:00:00Z',
        comments: [
          {
            body: 'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
          }
        ]
      });
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };
  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    patchIssueLabelsFn,
    syncFn: async () => {},
    leaseReleaseFn: async () => ({ status: 'released' }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    logger: () => {},
    env: {
      GITHUB_REPOSITORY: 'fork-owner/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action'
    }
  });

  assert.deepEqual(patchCalls, [
    { issueNumber: 317, labels: [] },
    { issueNumber: 315, labels: ['fork-standing-priority'] }
  ]);
  assert.ok(
    calls.some(
      (args) =>
        args[0] === 'api' &&
        String(args[1]).includes('/issues/314')
    )
  );
});

test('handoffStandingPriority falls back to shared REST hydration when caller gh transport cannot hydrate a blocked candidate', async () => {
  const calls = [];
  const restCalls = [];
  const patchCalls = [];
  const issues = new Map([
    [315, { number: 315, title: '[P1] Real development issue', labels: [] }],
    [317, { number: 317, title: 'Current standing issue', labels: [{ name: 'fork-standing-priority' }] }]
  ]);
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([
        {
          ...issues.get(317),
          createdAt: '2026-03-10T00:00:00Z',
          updatedAt: '2026-03-10T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'list' && !args.includes('--label')) {
      return JSON.stringify([
        {
          number: 314,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: [],
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
          ...issues.get(317),
          title: '[P0] Current standing issue',
          body: 'Already active',
          createdAt: '2026-03-03T00:00:00Z',
          updatedAt: '2026-03-03T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };
  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };
  const restIssueFetcher = async ({ number, slug }) => {
    restCalls.push({ number, slug });
    if (number !== 314) {
      return null;
    }
    return {
      number: 314,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      updatedAt: '2026-03-01T00:00:00Z',
      url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/314',
      labels: [],
      comments: [
        {
          body: 'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
        }
      ]
    };
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    patchIssueLabelsFn,
    restIssueFetcher,
    syncFn: async () => {},
    leaseReleaseFn: async () => ({ status: 'released' }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    logger: () => {},
    env: {
      GITHUB_REPOSITORY: 'fork-owner/compare-vi-cli-action',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action'
    }
  });

  assert.deepEqual(patchCalls, [
    { issueNumber: 317, labels: [] },
    { issueNumber: 315, labels: ['fork-standing-priority'] }
  ]);
  assert.ok(calls.some((args) => args[0] === 'api' && String(args[1]).includes('/issues/314')));
  assert.deepEqual(restCalls, [{ number: 314, slug: 'fork-owner/compare-vi-cli-action' }]);
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
      'number,title,body,labels,createdAt,updatedAt,url',
      '--label',
      'fork-standing-priority'
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

test('handoffStandingPriority rejects non-positive explicit issue numbers', async () => {
  await assert.rejects(
    () =>
      handoffStandingPriority(0, {
        ghRunner: () => '[]',
        syncFn: async () => {},
        leaseReleaseFn: async () => ({ status: 'released' }),
        logger: () => {},
        env: {
          GITHUB_REPOSITORY: 'owner/repo',
          AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'owner/repo'
        }
      }),
    /positive integer/
  );
});

test('handoffStandingPriority reports ineligible out-of-scope queues truthfully during auto-select', async () => {
  await assert.rejects(
    handoffStandingPriority(null, {
      auto: true,
      ghRunner: (args) => {
        if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
          return '[]';
        }
        if (args[0] === 'issue' && args[1] === 'list') {
          return JSON.stringify([
            {
              number: 946,
              title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
              body: 'Out-of-scope downstream demo work.',
              labels: [],
              createdAt: '2026-03-01T00:00:00Z',
              updatedAt: '2026-03-01T00:00:00Z'
            }
          ]);
        }
        return '';
      },
      patchIssueLabelsFn: () => {},
      syncFn: async () => {},
      leaseReleaseFn: async () => ({ status: 'released' }),
      logger: () => {},
      env: {
        GITHUB_REPOSITORY: 'owner/repo',
        AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'owner/repo'
      }
    }),
    /none are eligible in-scope candidates/i
  );
});

test('handoffStandingPriority idles when only blocked concrete children remain behind an umbrella fallback', async () => {
  const calls = [];
  const patchCalls = [];
  const logs = [];
  const issues = new Map([
    [317, { number: 317, title: 'Current standing issue', labels: [{ name: 'standing-priority' }] }],
    [930, { number: 930, title: 'Epic: route released comparevi workflows through downstream rollout gates', labels: [{ name: 'program' }] }],
    [946, { number: 946, title: '[P1] upstream rollout child', labels: [] }],
    [947, { number: 947, title: '[P1] downstream rollout child', labels: [] }]
  ]);
  let syncCount = 0;

  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([
        {
          ...issues.get(317),
          body: 'Currently active.',
          createdAt: '2026-03-01T00:00:00Z',
          updatedAt: '2026-03-01T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'list') {
      return JSON.stringify([
        {
          ...issues.get(317),
          body: 'Currently active.',
          createdAt: '2026-03-01T00:00:00Z',
          updatedAt: '2026-03-01T00:00:00Z'
        },
        {
          ...issues.get(930),
          body: ['## Child tracks', '- #946', '- #947'].join('\n'),
          createdAt: '2026-03-02T00:00:00Z',
          updatedAt: '2026-03-02T00:00:00Z'
        },
        {
          ...issues.get(946),
          body: ['Parent epic: #930', 'Track comparevi-history#23 as the remaining renderer dependency.'].join('\n'),
          createdAt: '2026-03-03T00:00:00Z',
          updatedAt: '2026-03-03T00:00:00Z'
        },
        {
          ...issues.get(947),
          body: ['Parent epic: #930', 'Track comparevi-history#23 as the remaining renderer dependency.'].join('\n'),
          createdAt: '2026-03-04T00:00:00Z',
          updatedAt: '2026-03-04T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'api' && String(args[1]).includes('/issues/946')) {
      return JSON.stringify({
        number: 946,
        title: '[P1] upstream rollout child',
        body: ['Parent epic: #930', 'Track comparevi-history#23 as the remaining renderer dependency.'].join('\n'),
        labels: [],
        comments: [
          {
            body: 'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
          }
        ],
        updated_at: '2026-03-03T00:00:00Z',
        html_url: 'https://github.com/owner/repo/issues/946'
      });
    }
    if (args[0] === 'api' && String(args[1]).includes('/issues/947')) {
      return JSON.stringify({
        number: 947,
        title: '[P1] downstream rollout child',
        body: ['Parent epic: #930', 'Track comparevi-history#23 as the remaining renderer dependency.'].join('\n'),
        labels: [],
        comments: [
          {
            body: 'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
          }
        ],
        updated_at: '2026-03-04T00:00:00Z',
        html_url: 'https://github.com/owner/repo/issues/947'
      });
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };

  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    patchIssueLabelsFn,
    syncFn: async () => {
      syncCount += 1;
    },
    leaseReleaseFn: async () => ({ status: 'released' }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    logger: (message) => logs.push(message),
    env: {
      GITHUB_REPOSITORY: 'owner/repo',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'owner/repo'
    }
  });

  assert.deepEqual(patchCalls, [{ issueNumber: 317, labels: [] }]);
  assert.equal(syncCount, 1);
  assert.ok(calls.some((args) => args[0] === 'api' && String(args[1]).includes('/issues/946')));
  assert.ok(calls.some((args) => args[0] === 'api' && String(args[1]).includes('/issues/947')));
  assert.ok(logs.some((message) => /queue will become idle after sync/i.test(message)));
});

test('handoffStandingPriority promotes a rollout child when the external blocker has already closed', async () => {
  const patchCalls = [];
  const issues = new Map([
    [317, { number: 317, title: 'Current standing issue', labels: [{ name: 'standing-priority' }] }],
    [930, { number: 930, title: 'Epic: route released comparevi workflows through downstream rollout gates', labels: [{ name: 'program' }] }],
    [946, { number: 946, title: '[P1] upstream rollout child', labels: [] }],
    [951, { number: 951, title: '[P2] local follow-up', labels: [] }]
  ]);

  const ghRunner = (args) => {
    if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
      return JSON.stringify([
        {
          ...issues.get(317),
          body: 'Currently active.',
          createdAt: '2026-03-01T00:00:00Z',
          updatedAt: '2026-03-01T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'issue' && args[1] === 'list') {
      return JSON.stringify([
        {
          ...issues.get(317),
          body: 'Currently active.',
          createdAt: '2026-03-01T00:00:00Z',
          updatedAt: '2026-03-01T00:00:00Z'
        },
        {
          ...issues.get(930),
          body: ['## Child tracks', '- #946'].join('\n'),
          createdAt: '2026-03-02T00:00:00Z',
          updatedAt: '2026-03-02T00:00:00Z'
        },
        {
          ...issues.get(946),
          body: ['Parent epic: #930', 'Track comparevi-history#23 as the remaining renderer dependency.'].join('\n'),
          createdAt: '2026-03-03T00:00:00Z',
          updatedAt: '2026-03-03T00:00:00Z'
        },
        {
          ...issues.get(951),
          body: 'Remaining in-repo work.',
          createdAt: '2026-03-04T00:00:00Z',
          updatedAt: '2026-03-04T00:00:00Z'
        }
      ]);
    }
    if (args[0] === 'api' && String(args[1]).includes('/issues/946')) {
      return JSON.stringify({
        number: 946,
        title: '[P1] upstream rollout child',
        body: ['Parent epic: #930', 'Track comparevi-history#23 as the remaining renderer dependency.'].join('\n'),
        labels: [],
        comments: [
          {
            body: 'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
          }
        ],
        updated_at: '2026-03-03T00:00:00Z',
        html_url: 'https://github.com/owner/repo/issues/946'
      });
    }
    if (args[0] === 'issue' && args[1] === 'view') {
      return JSON.stringify(issues.get(Number(args[2])));
    }
    return '';
  };

  const patchIssueLabelsFn = (_repoRoot, _repoSlug, issueNumber, labels) => {
    patchCalls.push({ issueNumber, labels });
    const issue = issues.get(issueNumber);
    issue.labels = labels.map((label) => ({ name: label }));
  };

  await handoffStandingPriority(null, {
    auto: true,
    ghRunner,
    patchIssueLabelsFn,
    syncFn: async () => {},
    leaseReleaseFn: async () => ({ status: 'released' }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher({ 23: 'closed' }),
    logger: () => {},
    env: {
      GITHUB_REPOSITORY: 'owner/repo',
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'owner/repo'
    }
  });

  assert.deepEqual(patchCalls, [
    { issueNumber: 317, labels: [] },
    { issueNumber: 946, labels: ['standing-priority'] }
  ]);
});

test('handoffStandingPriority fails loudly when label verification remains stale after mutation', async () => {
  await assert.rejects(
    handoffStandingPriority(315, {
      ghRunner: (args) => {
        if (args[0] === 'issue' && args[1] === 'list') {
          return JSON.stringify([
            {
              number: 317,
              title: 'Current standing issue',
              labels: [{ name: 'standing-priority' }]
            }
          ]);
        }
        if (args[0] === 'issue' && args[1] === 'view') {
          return JSON.stringify({
            number: 317,
            title: 'Current standing issue',
            labels: [{ name: 'standing-priority' }]
          });
        }
        return '';
      },
      patchIssueLabelsFn: () => {},
      syncFn: async () => {},
      leaseReleaseFn: async () => ({ status: 'released' }),
      logger: () => {},
      env: {
        GITHUB_REPOSITORY: 'owner/repo',
        AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'owner/repo'
      }
    }),
    /label verification failed/i
  );
});

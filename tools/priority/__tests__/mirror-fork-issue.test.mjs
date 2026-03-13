#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  buildDesiredLabels,
  buildMirrorBody,
  findMirrorIssue,
  listOpenForkIssues,
  parseArgs,
  planStandingLabelDemotions,
  runMirrorForkIssue
} from '../mirror-fork-issue.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('mirror-fork-issue parseArgs requires issue and accepts fork remote', () => {
  const parsed = parseArgs([
    'node',
    'mirror-fork-issue.mjs',
    '--issue',
    '966',
    '--fork-remote',
    'personal'
  ]);

  assert.equal(parsed.issue, 966);
  assert.equal(parsed.forkRemote, 'personal');
});

test('buildMirrorBody prefixes the upstream issue pointer exactly once', () => {
  const body = buildMirrorBody({
    url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/966',
    body: '## Summary\n- downstream helper\n'
  });

  assert.match(body, /^<!-- upstream-issue-url:/);
  assert.match(body, /## Summary/);
});

test('buildDesiredLabels keeps the fork standing label and reuses only labels present on the fork repo', () => {
  const labels = buildDesiredLabels(['ci', 'standing-priority', 'governance'], ['ci', 'fork-standing-priority']);
  assert.deepEqual(labels, ['ci', 'fork-standing-priority']);
});

test('findMirrorIssue ignores closed mirrors when selecting the active fork issue', () => {
  const upstreamUrl = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/984';
  const issues = [
    {
      number: 12,
      state: 'CLOSED',
      body: `<!-- upstream-issue-url: ${upstreamUrl} -->\n\nclosed mirror`
    },
    {
      number: 13,
      state: 'OPEN',
      body: `<!-- upstream-issue-url: ${upstreamUrl} -->\n\nopen mirror`
    }
  ];

  const mirror = findMirrorIssue(issues, upstreamUrl);
  assert.equal(mirror?.number, 13);
});

test('findMirrorIssue matches the upstream pointer case-insensitively', () => {
  const upstreamUrl = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/984';
  const issues = [
    {
      number: 14,
      state: 'OPEN',
      body: `<!-- UPSTREAM-ISSUE-URL: ${upstreamUrl.toUpperCase()} -->\n\nopen mirror`
    }
  ];

  const mirror = findMirrorIssue(issues, upstreamUrl);
  assert.equal(mirror?.number, 14);
});

test('planStandingLabelDemotions removes standing labels from stale open fork issues only', () => {
  const demotions = planStandingLabelDemotions(
    [
      {
        number: 20,
        state: 'OPEN',
        labels: [{ name: 'fork-standing-priority' }, { name: 'ci' }]
      },
      {
        number: 21,
        state: 'OPEN',
        labels: [{ name: 'standing-priority' }, { name: 'governance' }]
      },
      {
        number: 22,
        state: 'OPEN',
        labels: [{ name: 'fork-standing-priority' }, { name: 'bug' }]
      },
      {
        number: 23,
        state: 'CLOSED',
        labels: [{ name: 'fork-standing-priority' }, { name: 'ci' }]
      }
    ],
    22
  );

  assert.deepEqual(demotions, [
    { number: 20, labels: ['ci'] },
    { number: 21, labels: ['governance'] }
  ]);
});

test('listOpenForkIssues paginates through every open issue page', () => {
  const calls = [];
  const issues = listOpenForkIssues('C:\\repo', 'example/fork', {
    runGhGraphqlFn(repoRootArg, query, variables) {
      calls.push({ repoRootArg, query, variables });
      if (!variables.cursor) {
        return {
          data: {
            repository: {
              issues: {
                nodes: [
                  {
                    number: 1,
                    title: 'first',
                    body: 'body',
                    url: 'https://github.com/example/fork/issues/1',
                    state: 'OPEN',
                    labels: {
                      nodes: [{ name: 'fork-standing-priority' }]
                    }
                  }
                ],
                pageInfo: {
                  hasNextPage: true,
                  endCursor: 'cursor-1'
                }
              }
            }
          }
        };
      }

      return {
        data: {
          repository: {
            issues: {
              nodes: [
                {
                  number: 2,
                  title: 'second',
                  body: 'body',
                  url: 'https://github.com/example/fork/issues/2',
                  state: 'OPEN',
                  labels: {
                    nodes: [{ name: 'ci' }]
                  }
                }
              ],
              pageInfo: {
                hasNextPage: false,
                endCursor: null
              }
            }
          }
        }
      };
    }
  });

  assert.equal(calls.length, 2);
  assert.equal(calls[0].variables.cursor, null);
  assert.equal(calls[1].variables.cursor, 'cursor-1');
  assert.deepEqual(
    issues.map((issue) => ({ number: issue.number, labels: issue.labels.map((entry) => entry.name) })),
    [
      { number: 1, labels: ['fork-standing-priority'] },
      { number: 2, labels: ['ci'] }
    ]
  );
});

test('runMirrorForkIssue wraps demotion failures with fork issue context', () => {
  const reportDir = mkdtempSync(path.join(os.tmpdir(), 'mirror-fork-issue-'));
  assert.throws(
    () =>
      runMirrorForkIssue({
        repoRoot: 'C:\\repo',
        options: {
          issue: 984,
          forkRemote: 'origin',
          reportDir
        },
        resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
        resolveActiveForkRemoteNameFn: () => 'origin',
        ensureForkRemoteFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' }),
        runGhJsonFn: () => ({
          number: 984,
          title: 'Fork mirror hygiene',
          body: 'body',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/984',
          labels: [{ name: 'ci' }],
          state: 'OPEN'
        }),
        ensureLabelFn: () => {},
        listForkLabelsFn: () => ['ci', 'fork-standing-priority'],
        listOpenForkIssuesFn: () => [
          {
            number: 50,
            state: 'OPEN',
            labels: [{ name: 'fork-standing-priority' }, { name: 'ci' }],
            body: 'not the active mirror'
          }
        ],
        ghApiFn: (repoRootArg, endpoint, method) => {
          if (endpoint.endsWith('/issues') && method === 'POST') {
            return {
              number: 51,
              html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/issues/51'
            };
          }
          throw new Error('rate limit');
        }
      }),
    /Failed to demote stale standing labels on LabVIEW-Community-CI-CD\/compare-vi-cli-action-fork#50: rate limit/
  );
});

test('mirror-fork-issue uses supported gh label list lookup and GraphQL pagination for fork issues', () => {
  const source = readFileSync(path.join(repoRoot, 'tools', 'priority', 'mirror-fork-issue.mjs'), 'utf8');

  assert.doesNotMatch(source, /gh',\s*\['label', 'view'/);
  assert.match(source, /runGhJson\(/);
  assert.match(source, /'label', 'list'/);
  assert.match(source, /'--json', 'name'/);
  assert.match(source, /runGhGraphql/);
  assert.doesNotMatch(source, /'issue', 'list', '--repo', forkSlug, '--state', 'all'/);
});

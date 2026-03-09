#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseRepositorySlug,
  buildRepositorySlug,
  isSameRepository,
  isSameOwnerForkRepository,
  isRepositoryForkOfUpstream,
  loadRepositoryGraphMetadata,
  ensureOriginFork,
  buildGhPrCreateArgs,
  selectPullRequestCreateStrategy,
  buildCreatePullRequestMutation,
  buildSameOwnerForkHeadRefCandidates,
  extractPullRequestFromMutation,
  runGhPrCreate
} from '../lib/remote-utils.mjs';

test('repository helpers normalize and compare repository coordinates', () => {
  assert.deepEqual(parseRepositorySlug('example/repo'), { owner: 'example', repo: 'repo' });
  assert.equal(buildRepositorySlug({ owner: 'example', repo: 'repo' }), 'example/repo');
  assert.equal(isSameRepository({ owner: 'a', repo: 'b' }, { owner: 'a', repo: 'b' }), true);
  assert.equal(isSameOwnerForkRepository({ owner: 'a', repo: 'fork' }, { owner: 'a', repo: 'upstream' }), true);
});

test('repository fork matching requires the upstream network relationship', () => {
  assert.equal(
    isRepositoryForkOfUpstream(
      {
        isFork: true,
        parentNameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        sourceNameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      },
      { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }
    ),
    true
  );

  assert.equal(
    isRepositoryForkOfUpstream(
      {
        isFork: false,
        parentNameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      },
      { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }
    ),
    false
  );
});

test('loadRepositoryGraphMetadata queries only supported repository fields and maps the parent fork lineage', () => {
  let observedQuery = null;
  const metadata = loadRepositoryGraphMetadata(
    '/tmp/repo',
    { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' },
    {
      runGhGraphqlFn: (_repoRoot, query) => {
        observedQuery = query;
        return {
          data: {
            repository: {
              id: 'R_fork',
              nameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
              isFork: true,
              parent: {
                nameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
              }
            }
          }
        };
      }
    }
  );

  assert.match(observedQuery, /parent \{ nameWithOwner \}/);
  assert.doesNotMatch(observedQuery, /source \{/);
  assert.deepEqual(metadata, {
    id: 'R_fork',
    nameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
    isFork: true,
    parentNameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  });
});

test('ensureOriginFork accepts a same-owner renamed fork when metadata proves it belongs to the upstream network', () => {
  const origin = ensureOriginFork(
    '/tmp/repo',
    { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
    {
      tryResolveRemoteFn: () => ({
        parsed: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' }
      }),
      loadRepositoryGraphMetadataFn: () => ({
        id: 'R_fork',
        isFork: true,
        parentNameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        sourceNameWithOwner: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      })
    }
  );

  assert.deepEqual(origin, {
    owner: 'LabVIEW-Community-CI-CD',
    repo: 'compare-vi-cli-action-fork',
    sameOwnerFork: true,
    repositoryId: 'R_fork'
  });
});

test('ensureOriginFork rejects a same-owner repository that is not an upstream fork', () => {
  assert.throws(
    () =>
      ensureOriginFork(
        '/tmp/repo',
        { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
        {
          tryResolveRemoteFn: () => ({
            parsed: { owner: 'LabVIEW-Community-CI-CD', repo: 'not-a-fork' }
          }),
          loadRepositoryGraphMetadataFn: () => ({
            id: 'R_other',
            isFork: false,
            parentNameWithOwner: null,
            sourceNameWithOwner: null
          })
        }
      ),
    /shares the upstream owner but is not a fork/i
  );
});

test('buildGhPrCreateArgs preserves the standard gh create path for user forks', () => {
  const args = buildGhPrCreateArgs({
    upstream: { owner: 'upstream-owner', repo: 'repo' },
    origin: { owner: 'fork-owner', repo: 'repo' },
    branch: 'issue/963-test',
    base: 'develop',
    title: 'Helper title',
    body: 'Helper body'
  });

  assert.deepEqual(args, [
    'pr',
    'create',
    '--repo',
    'upstream-owner/repo',
    '--base',
    'develop',
    '--head',
    'fork-owner:issue/963-test',
    '--title',
    'Helper title',
    '--body',
    'Helper body'
  ]);
});

test('graphql PR helpers expose the same-owner fork mutation contract', () => {
  assert.equal(
    selectPullRequestCreateStrategy({
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      origin: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork', sameOwnerFork: true }
    }),
    'graphql-same-owner-fork'
  );
  assert.deepEqual(
    buildSameOwnerForkHeadRefCandidates(
      { owner: 'LabVIEW-Community-CI-CD' },
      'issue/963-org-owned-fork-pr-helper'
    ),
    [
      'issue/963-org-owned-fork-pr-helper',
      'LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper'
    ]
  );

  const request = buildCreatePullRequestMutation({
    repositoryId: 'R_upstream',
    headRepositoryId: 'R_fork',
    headRefName: 'issue/963-org-owned-fork-pr-helper',
    baseRefName: 'develop',
    title: 'Fix #963',
    body: 'Body'
  });
  assert.match(request.query, /createPullRequest/);
  assert.equal(request.variables.repositoryId, 'R_upstream');
  assert.equal(request.variables.headRepositoryId, 'R_fork');
  assert.equal(request.variables.headRefName, 'issue/963-org-owned-fork-pr-helper');
});

test('extractPullRequestFromMutation returns the created pull request payload', () => {
  const pullRequest = extractPullRequestFromMutation({
    data: {
      createPullRequest: {
        pullRequest: {
          number: 963,
          url: 'https://github.com/example/repo/pull/963'
        }
      }
    }
  });

  assert.deepEqual(pullRequest, {
    number: 963,
    url: 'https://github.com/example/repo/pull/963'
  });
});

test('runGhPrCreate retries same-owner fork GraphQL creation with a namespaced head ref when needed', () => {
  const headRefs = [];
  const result = runGhPrCreate(
    {
      repoRoot: '/tmp/repo',
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      origin: {
        owner: 'LabVIEW-Community-CI-CD',
        repo: 'compare-vi-cli-action-fork',
        sameOwnerFork: true,
        repositoryId: 'R_fork'
      },
      branch: 'issue/963-org-owned-fork-pr-helper',
      base: 'develop',
      title: 'Fix #963',
      body: 'Body'
    },
    {
      loadRepositoryGraphMetadataFn: (_repoRoot, repository) => {
        if (repository.repo === 'compare-vi-cli-action') {
          return { id: 'R_upstream' };
        }
        return { id: 'R_fork' };
      },
      runGhGraphqlFn: (_repoRoot, _query, variables) => {
        headRefs.push(variables.headRefName);
        if (variables.headRefName === 'issue/963-org-owned-fork-pr-helper') {
          throw new Error('Head ref not found.');
        }
        return {
          data: {
            createPullRequest: {
              pullRequest: {
                number: 963,
                url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963'
              }
            }
          }
        };
      }
    }
  );

  assert.deepEqual(headRefs, [
    'issue/963-org-owned-fork-pr-helper',
    'LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper'
  ]);
  assert.equal(result.strategy, 'graphql-same-owner-fork');
  assert.equal(result.pullRequest.number, 963);
});

test('runGhPrCreate preserves the gh CLI path for user-owned forks', () => {
  const calls = [];
  const result = runGhPrCreate(
    {
      repoRoot: '/tmp/repo',
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      origin: { owner: 'svelderrainruiz', repo: 'compare-vi-cli-action', sameOwnerFork: false },
      branch: 'issue/963-org-owned-fork-pr-helper',
      base: 'develop',
      title: 'Fix #963',
      body: 'Body'
    },
    {
      spawnSyncFn: (command, args) => {
        calls.push({ command, args });
        return { status: 0 };
      }
    }
  );

  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, 'gh');
  assert.deepEqual(calls[0].args, [
    'pr',
    'create',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--base',
    'develop',
    '--head',
    'svelderrainruiz:issue/963-org-owned-fork-pr-helper',
    '--title',
    'Fix #963',
    '--body',
    'Body'
  ]);
  assert.equal(result.strategy, 'gh-pr-create');
});

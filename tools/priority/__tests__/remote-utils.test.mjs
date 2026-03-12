#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseRepositorySlug,
  buildRepositorySlug,
  isSameRepository,
  isSameOwnerForkRepository,
  isRepositoryForkOfUpstream,
  resolveActiveForkRemoteName,
  ensureForkRemote,
  loadRepositoryGraphMetadata,
  ensureOriginFork,
  pushBranch,
  buildGhPrCreateArgs,
  buildGhPrEditArgs,
  buildGhPrListArgs,
  selectPullRequestCreateStrategy,
  buildCreatePullRequestMutation,
  buildSameOwnerForkHeadRefCandidates,
  extractPullRequestFromMutation,
  findExistingPullRequest,
  isExistingPullRequestError,
  runGhPrCreate
} from '../lib/remote-utils.mjs';

test('repository helpers normalize and compare repository coordinates', () => {
  assert.deepEqual(parseRepositorySlug('example/repo'), { owner: 'example', repo: 'repo' });
  assert.equal(buildRepositorySlug({ owner: 'example', repo: 'repo' }), 'example/repo');
  assert.equal(isSameRepository({ owner: 'a', repo: 'b' }, { owner: 'a', repo: 'b' }), true);
  assert.equal(isSameOwnerForkRepository({ owner: 'a', repo: 'fork' }, { owner: 'a', repo: 'upstream' }), true);
});

test('resolveActiveForkRemoteName defaults to origin and honors personal override', () => {
  assert.equal(resolveActiveForkRemoteName({}), 'origin');
  assert.equal(resolveActiveForkRemoteName({ AGENT_PRIORITY_ACTIVE_FORK_REMOTE: 'personal' }), 'personal');
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
    remoteName: 'origin',
    sameOwnerFork: true,
    repositoryId: 'R_fork'
  });
});

test('ensureForkRemote rejects a non-origin fork remote when it is missing', () => {
  assert.throws(
    () =>
      ensureForkRemote(
        '/tmp/repo',
        { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
        'personal',
        {
          tryResolveRemoteFn: () => null
        }
      ),
    /Configure that remote before opening a PR from it/i
  );
});

test('pushBranch treats an already-published remote branch as success when the push transport fails', () => {
  const calls = [];
  const result = pushBranch('/tmp/repo', 'issue/963-org-owned-fork-pr-helper', 'origin', {
    runFn: (_command, args) => {
      calls.push(args);
      if (args[0] === 'push') {
        throw new Error('Permission denied (publickey)');
      }
      if (args[0] === 'ls-remote') {
        return '5fe002b6\trefs/heads/issue/963-org-owned-fork-pr-helper';
      }
      if (args[0] === 'rev-parse') {
        return '5fe002b6';
      }
      throw new Error(`Unexpected git args: ${args.join(' ')}`);
    }
  });

  assert.deepEqual(calls, [
    ['push', '--set-upstream', 'origin', 'issue/963-org-owned-fork-pr-helper'],
    ['ls-remote', '--heads', 'origin', 'issue/963-org-owned-fork-pr-helper'],
    ['rev-parse', 'issue/963-org-owned-fork-pr-helper']
  ]);
  assert.deepEqual(result, {
    status: 'already-published',
    remote: 'origin',
    branch: 'issue/963-org-owned-fork-pr-helper',
    recoveredFromPushFailure: true
  });
});

test('pushBranch still fails when the remote branch is not published', () => {
  assert.throws(
    () =>
      pushBranch('/tmp/repo', 'issue/963-org-owned-fork-pr-helper', 'origin', {
        runFn: (_command, args) => {
          if (args[0] === 'push') {
            throw new Error('Permission denied (publickey)');
          }
          if (args[0] === 'ls-remote') {
            return '';
          }
          throw new Error(`Unexpected git args: ${args.join(' ')}`);
        }
      }),
    /Failed to push branch to origin/i
  );
});

test('pushBranch preserves the original push failure context when recovery is not possible', () => {
  assert.throws(
    () =>
      pushBranch('/tmp/repo', 'issue/963-org-owned-fork-pr-helper', 'origin', {
        runFn: (_command, args) => {
          if (args[0] === 'push') {
            const error = new Error('Permission denied (publickey)');
            error.stderr = 'fatal: Permission denied (publickey)';
            throw error;
          }
          if (args[0] === 'ls-remote') {
            return '';
          }
          throw new Error(`Unexpected git args: ${args.join(' ')}`);
        }
      }),
    /Failed to push branch to origin\.\s+fatal: Permission denied \(publickey\)/i
  );
});

test('pushBranch still fails when the remote branch exists but does not match the local head after a push failure', () => {
  assert.throws(
    () =>
      pushBranch('/tmp/repo', 'issue/963-org-owned-fork-pr-helper', 'origin', {
        runFn: (_command, args) => {
          if (args[0] === 'push') {
            throw new Error('Permission denied (publickey)');
          }
          if (args[0] === 'ls-remote') {
            return '5fe002b6\trefs/heads/issue/963-org-owned-fork-pr-helper';
          }
          if (args[0] === 'rev-parse') {
            return '8ad91377';
          }
          throw new Error(`Unexpected git args: ${args.join(' ')}`);
        }
      }),
    /Failed to push branch to origin/i
  );
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
    '--draft',
    '--title',
    'Helper title',
    '--body',
    'Helper body'
  ]);
});

test('buildGhPrEditArgs targets the existing PR with explicit title/body updates', () => {
  const args = buildGhPrEditArgs({
    upstream: { owner: 'upstream-owner', repo: 'repo' },
    pullRequest: { number: 963 },
    title: 'Updated helper title',
    body: 'Updated helper body'
  });

  assert.deepEqual(args, [
    'pr',
    'edit',
    '963',
    '--repo',
    'upstream-owner/repo',
    '--title',
    'Updated helper title',
    '--body',
    'Updated helper body'
  ]);
});

test('buildGhPrEditArgs fails fast when upstream coordinates are missing', () => {
  assert.throws(
    () =>
      buildGhPrEditArgs({
        upstream: { owner: 'upstream-owner' },
        pullRequest: { number: 963 },
        title: 'Updated helper title',
        body: 'Updated helper body'
      }),
    /Invalid upstream repository coordinates/i
  );
});

test('buildGhPrListArgs targets the upstream repository and supports owner-qualified head selectors', () => {
  const args = buildGhPrListArgs({
    upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
    branch: 'issue/963-org-owned-fork-pr-helper',
    base: 'develop',
    head: 'LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper'
  });

  assert.deepEqual(args, [
    'pr',
    'list',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--state',
    'open',
    '--base',
    'develop',
    '--head',
    'LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper',
    '--json',
    'number,url,state,isDraft,headRefName,baseRefName,headRepositoryOwner,isCrossRepository'
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
  assert.match(request.query, /draft: true/);
  assert.equal(request.variables.repositoryId, 'R_upstream');
  assert.equal(request.variables.headRepositoryId, 'R_fork');
  assert.equal(request.variables.headRefName, 'issue/963-org-owned-fork-pr-helper');
});

test('findExistingPullRequest matches the branch/base pair and same-owner cross-repo head', () => {
  const calls = [];
  const pullRequest = findExistingPullRequest(
    '/tmp/repo',
    {
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      headRepository: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' },
      branch: 'issue/963-org-owned-fork-pr-helper',
      base: 'develop'
    },
    {
      runGhJsonFn: (_repoRoot, args) => {
        calls.push(args);
        assert.deepEqual(args, [
          'pr',
          'list',
          '--repo',
          'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          '--state',
          'open',
          '--base',
          'develop',
          '--head',
          'LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper',
          '--json',
          'number,url,state,isDraft,headRefName,baseRefName,headRepositoryOwner,isCrossRepository'
        ]);
        return [
          {
            number: 963,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963',
            headRefName: 'issue/963-org-owned-fork-pr-helper',
            baseRefName: 'develop',
            headRepositoryOwner: { login: 'LabVIEW-Community-CI-CD' },
            isCrossRepository: true
          }
        ];
      }
    }
  );

  assert.equal(pullRequest.number, 963);
  assert.equal(calls.length, 1);
});

test('findExistingPullRequest falls back to the unqualified branch selector when the owner-qualified lookup misses', () => {
  const calls = [];
  const pullRequest = findExistingPullRequest(
    '/tmp/repo',
    {
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      headRepository: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' },
      branch: 'issue/963-org-owned-fork-pr-helper',
      base: 'develop'
    },
    {
      runGhJsonFn: (_repoRoot, args) => {
        calls.push(args);
        if (calls.length === 1) {
          return [];
        }
        return [
          {
            number: 963,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963',
            headRefName: 'issue/963-org-owned-fork-pr-helper',
            baseRefName: 'develop',
            headRepositoryOwner: { login: 'LabVIEW-Community-CI-CD' },
            isCrossRepository: true
          }
        ];
      }
    }
  );

  assert.equal(calls.length, 2);
  assert.equal(calls[0][9], 'LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper');
  assert.equal(calls[1][9], 'issue/963-org-owned-fork-pr-helper');
  assert.equal(pullRequest.number, 963);
});

test('findExistingPullRequest rejects ambiguous matches when an expected owner is known but the response omits headRepositoryOwner', () => {
  const pullRequest = findExistingPullRequest(
    '/tmp/repo',
    {
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      headRepository: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork' },
      branch: 'issue/963-org-owned-fork-pr-helper',
      base: 'develop'
    },
    {
      runGhJsonFn: () => [
        {
          number: 963,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963',
          headRefName: 'issue/963-org-owned-fork-pr-helper',
          baseRefName: 'develop'
        }
      ]
    }
  );

  assert.equal(pullRequest, null);
});

test('isExistingPullRequestError detects duplicate-create responses', () => {
  assert.equal(
    isExistingPullRequestError(new Error('gh: A pull request already exists for owner:branch.')),
    true
  );
  assert.equal(isExistingPullRequestError(new Error('some other failure')), false);
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
  const writes = [];
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
      },
      writeStdoutFn: (text) => {
        writes.push(text);
      }
    }
  );

  assert.deepEqual(headRefs, [
    'issue/963-org-owned-fork-pr-helper',
    'LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper'
  ]);
  assert.equal(result.strategy, 'graphql-same-owner-fork');
  assert.equal(result.pullRequest.number, 963);
  assert.deepEqual(writes, ['https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963\n']);
});

test('runGhPrCreate reuses an existing PR when same-owner fork GraphQL creation reports a duplicate', () => {
  const writes = [];
  const edits = [];
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
      runGhGraphqlFn: () => {
        throw new Error('gh: A pull request already exists for LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper.');
      },
      findExistingPullRequestFn: () => ({
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963'
      }),
      updateExistingPullRequestFn: (_repoRoot, payload) => {
        edits.push(payload);
      },
      writeStdoutFn: (text) => {
        writes.push(text);
      }
    }
  );

  assert.equal(result.strategy, 'graphql-same-owner-fork');
  assert.equal(result.reusedExisting, true);
  assert.equal(result.pullRequest.number, 963);
  assert.deepEqual(edits, [
    {
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      pullRequest: {
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963'
      },
      title: 'Fix #963',
      body: 'Body'
    }
  ]);
  assert.deepEqual(writes, ['https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963\n']);
});

test('runGhPrCreate reuses an existing human-drafted PR so it can later return to ready-for-review for a fresh Copilot review', () => {
  const writes = [];
  const edits = [];
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
      runGhGraphqlFn: () => {
        throw new Error('gh: A pull request already exists for LabVIEW-Community-CI-CD:issue/963-org-owned-fork-pr-helper.');
      },
      findExistingPullRequestFn: () => ({
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963',
        isDraft: true
      }),
      updateExistingPullRequestFn: (_repoRoot, payload) => {
        edits.push(payload);
      },
      writeStdoutFn: (text) => {
        writes.push(text);
      }
    }
  );

  assert.equal(result.strategy, 'graphql-same-owner-fork');
  assert.equal(result.reusedExisting, true);
  assert.equal(result.pullRequest.number, 963);
  assert.equal(result.pullRequest.isDraft, true);
  assert.deepEqual(edits, [
    {
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      pullRequest: {
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963',
        isDraft: true
      },
      title: 'Fix #963',
      body: 'Body'
    }
  ]);
  assert.deepEqual(writes, ['https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963\n']);
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
    '--draft',
    '--title',
    'Fix #963',
    '--body',
    'Body'
  ]);
  assert.equal(result.strategy, 'gh-pr-create');
});

test('runGhPrCreate surfaces gh CLI stdout and parses the created PR URL on success', () => {
  const writes = [];
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
      spawnSyncFn: () => ({
        status: 0,
        stdout: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963\n',
        stderr: ''
      }),
      writeStdoutFn: (text) => {
        writes.push(text);
      }
    }
  );

  assert.deepEqual(writes, ['https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963\n']);
  assert.equal(result.strategy, 'gh-pr-create');
  assert.deepEqual(result.pullRequest, {
    number: 963,
    url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963'
  });
});

test('runGhPrCreate reuses an existing PR when gh pr create reports a duplicate', () => {
  const edits = [];
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
      spawnSyncFn: () => ({
        status: 1,
        stdout: '',
        stderr: 'gh: A pull request already exists for svelderrainruiz:issue/963-org-owned-fork-pr-helper.'
      }),
      findExistingPullRequestFn: () => ({
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963'
      }),
      updateExistingPullRequestFn: (_repoRoot, payload) => {
        edits.push(payload);
      }
    }
  );

  assert.equal(result.strategy, 'gh-pr-create');
  assert.equal(result.reusedExisting, true);
  assert.equal(result.pullRequest.number, 963);
  assert.equal(result.updateWarning, null);
  assert.deepEqual(edits, [
    {
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      pullRequest: {
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963'
      },
      title: 'Fix #963',
      body: 'Body'
    }
  ]);
});

test('runGhPrCreate treats existing PR refresh failures as warnings and still returns the PR URL', () => {
  const warnings = [];
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
      spawnSyncFn: () => ({
        status: 1,
        stdout: '',
        stderr: 'gh: A pull request already exists for svelderrainruiz:issue/963-org-owned-fork-pr-helper.'
      }),
      findExistingPullRequestFn: () => ({
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963'
      }),
      updateExistingPullRequestFn: () => {
        throw new Error('failed to refresh existing PR metadata');
      },
      writeStderrFn: (text) => {
        warnings.push(text);
      }
    }
  );

  assert.equal(result.reusedExisting, true);
  assert.equal(result.pullRequest.number, 963);
  assert.equal(result.updateWarning, 'failed to refresh existing PR metadata');
  assert.match(
    warnings.join(''),
    /Warning: Failed to update existing pull request https:\/\/github\.com\/LabVIEW-Community-CI-CD\/compare-vi-cli-action\/pull\/963: failed to refresh existing PR metadata/
  );
});

test('runGhPrCreate redacts title and body from gh command errors', () => {
  assert.throws(
    () =>
      runGhPrCreate(
        {
          repoRoot: '/tmp/repo',
          upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
          origin: { owner: 'svelderrainruiz', repo: 'compare-vi-cli-action', sameOwnerFork: false },
          branch: 'issue/963-org-owned-fork-pr-helper',
          base: 'develop',
          title: 'Very sensitive PR title',
          body: 'Very sensitive PR body'
        },
        {
          spawnSyncFn: () => ({
            status: 1,
            stdout: '',
            stderr: 'gh: create failed'
          }),
          findExistingPullRequestFn: () => null
        }
      ),
    /gh pr create --repo LabVIEW-Community-CI-CD\/compare-vi-cli-action --base develop --head svelderrainruiz:issue\/963-org-owned-fork-pr-helper --draft --title <redacted:title> --body <redacted:body> failed: gh: create failed/i
  );
});

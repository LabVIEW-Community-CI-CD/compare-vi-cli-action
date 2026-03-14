import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {
  parseArgs,
  parseRemoteUrl,
  resolveRepositorySlug,
  collectPolicyState
} from '../policy-snapshot.mjs';

test('parseArgs applies defaults and accepts explicit repo/output', () => {
  const defaults = parseArgs(['node', 'policy-snapshot.mjs']);
  assert.equal(defaults.outputPath, path.join('tests', 'results', '_agent', 'policy', 'policy-state-snapshot.json'));
  assert.equal(defaults.repo, null);
  assert.equal(defaults.help, false);

  const explicit = parseArgs([
    'node',
    'policy-snapshot.mjs',
    '--repo',
    'owner/repo',
    '--output',
    'tmp/snapshot.json'
  ]);
  assert.equal(explicit.repo, 'owner/repo');
  assert.equal(explicit.outputPath, 'tmp/snapshot.json');
});

test('parseRemoteUrl normalizes ssh/https GitHub remote URLs', () => {
  assert.equal(parseRemoteUrl('git@github.com:owner/repo.git'), 'owner/repo');
  assert.equal(parseRemoteUrl('https://github.com/owner/repo.git'), 'owner/repo');
  assert.equal(parseRemoteUrl('https://example.com/not-github/repo.git'), null);
});

test('resolveRepositorySlug prefers explicit, then env, then remotes', () => {
  const fromExplicit = resolveRepositorySlug('explicit/repo');
  assert.equal(fromExplicit, 'explicit/repo');

  const fromEnv = resolveRepositorySlug(null, {
    environment: { GITHUB_REPOSITORY: 'env/repo' },
    commandRunner: () => {
      throw new Error('should not call command runner when env is set');
    }
  });
  assert.equal(fromEnv, 'env/repo');

  const seenCommands = [];
  const fromRemote = resolveRepositorySlug(null, {
    environment: {},
    commandRunner: (command) => {
      seenCommands.push(command);
      if (command.includes('remote.upstream.url')) {
        return 'git@github.com:upstream-owner/compare-vi-cli-action.git';
      }
      throw new Error('missing remote');
    }
  });
  assert.equal(fromRemote, 'upstream-owner/compare-vi-cli-action');
  assert.ok(seenCommands.some((entry) => entry.includes('remote.upstream.url')));
});

test('collectPolicyState records branch protection and stable-key ruleset details', async () => {
  const calls = [];
  const manifest = {
    branches: {
      develop: {},
      main: {},
      'release/*': {}
    },
    rulesets: {
      develop: {
        name: 'develop queue',
        target: 'branch'
      },
      100: {}
    }
  };

  const state = await collectPolicyState({
    repo: 'owner/repo',
    token: 'test-token',
    manifest,
    requestJsonFn: async (url) => {
      calls.push(url);
      if (url.endsWith('/repos/owner/repo')) {
        return {
          full_name: 'owner/repo',
          allow_squash_merge: true,
          allow_merge_commit: false,
          allow_rebase_merge: false,
          allow_auto_merge: true,
          delete_branch_on_merge: true,
          updated_at: '2026-03-06T00:00:00Z'
        };
      }
      if (url.endsWith('/branches/develop/protection')) {
        return { required_pull_request_reviews: { required_approving_review_count: 0 } };
      }
      if (url.endsWith('/branches/main/protection')) {
        return { required_status_checks: { strict: true } };
      }
      if (url.endsWith('/rulesets')) {
        return [{ id: 100, name: 'develop queue', target: 'branch' }];
      }
      if (url.endsWith('/rulesets/100')) {
        return { id: 100, name: 'develop queue', rules: [{ type: 'merge_queue' }] };
      }
      throw new Error(`Unexpected URL: ${url}`);
    }
  });

  assert.equal(state.repo.name, 'owner/repo');
  assert.equal(state.repo.allow_squash_merge, true);
  assert.equal(state.branches.develop.skipped, false);
  assert.equal(state.branches.main.skipped, false);
  assert.equal(state.branches['release/*'].skipped, true);
  assert.equal(state.rulesets.develop.id, 100);
  assert.equal(state.rulesets['100'].id, 100);
  assert.ok(calls.some((entry) => entry.endsWith('/rulesets/100')));
  assert.ok(calls.some((entry) => entry.endsWith('/rulesets')));
});

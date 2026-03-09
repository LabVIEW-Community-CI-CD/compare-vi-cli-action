import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseArgs,
  filterReleasesForStream,
  resolveRollbackPointer,
  evaluateRollbackValidation,
  resolveRollbackRemoteName,
  runRollback
} from '../rollback-release.mjs';
import { normalizeReleaseRollbackPolicy } from '../lib/release-rollback-policy.mjs';

test('parseArgs applies defaults and explicit flags', () => {
  const defaults = parseArgs(['node', 'rollback-release.mjs']);
  assert.equal(defaults.stream, 'stable');
  assert.equal(defaults.apply, false);
  assert.equal(defaults.maxReleases, 50);
  assert.equal(defaults.skipPolicySync, false);

  const parsed = parseArgs([
    'node',
    'rollback-release.mjs',
    '--stream',
    'rc',
    '--repo',
    'owner/repo',
    '--target-tag',
    'v1.2.3-rc.1',
    '--max-releases',
    '30',
    '--apply',
    '--sync-origin',
    '--skip-policy-sync'
  ]);
  assert.equal(parsed.stream, 'rc');
  assert.equal(parsed.repo, 'owner/repo');
  assert.equal(parsed.targetTag, 'v1.2.3-rc.1');
  assert.equal(parsed.maxReleases, 30);
  assert.equal(parsed.apply, true);
  assert.equal(parsed.syncOrigin, true);
  assert.equal(parsed.skipPolicySync, true);
});

test('filterReleasesForStream selects and sorts stream tags', () => {
  const policy = normalizeReleaseRollbackPolicy({});
  const stable = policy.streams.stable;
  const rc = policy.streams.rc;
  const releases = [
    { tag_name: 'v1.2.3', draft: false, prerelease: false, published_at: '2026-03-05T00:00:00Z' },
    { tag_name: 'v1.2.2', draft: false, prerelease: false, published_at: '2026-03-01T00:00:00Z' },
    { tag_name: 'v1.2.4-rc.1', draft: false, prerelease: true, published_at: '2026-03-06T00:00:00Z' }
  ];

  const stableReleases = filterReleasesForStream(releases, stable);
  assert.equal(stableReleases.length, 2);
  assert.equal(stableReleases[0].tag, 'v1.2.3');

  const rcReleases = filterReleasesForStream(releases, rc);
  assert.equal(rcReleases.length, 1);
  assert.equal(rcReleases[0].tag, 'v1.2.4-rc.1');
});

test('resolveRollbackPointer chooses previous-good pointer by default', () => {
  const policy = normalizeReleaseRollbackPolicy({});
  const streamPolicy = policy.streams.stable;
  const streamReleases = [
    { tag: 'v1.2.3', publishedAt: '2026-03-05T00:00:00Z' },
    { tag: 'v1.2.2', publishedAt: '2026-03-01T00:00:00Z' }
  ];
  const pointer = resolveRollbackPointer({ streamReleases, streamPolicy });
  assert.equal(pointer.strategy, 'previous-good-release-tag');
  assert.equal(pointer.current.tag, 'v1.2.3');
  assert.equal(pointer.target.tag, 'v1.2.2');
});

test('resolveRollbackPointer supports explicit target and rejects missing history', () => {
  const policy = normalizeReleaseRollbackPolicy({});
  const streamPolicy = policy.streams.stable;
  const streamReleases = [{ tag: 'v1.2.3' }, { tag: 'v1.2.2' }];
  const pointer = resolveRollbackPointer({
    streamReleases,
    streamPolicy,
    targetTag: 'v1.2.2'
  });
  assert.equal(pointer.strategy, 'explicit-tag');
  assert.equal(pointer.target.tag, 'v1.2.2');

  assert.throws(
    () =>
      resolveRollbackPointer({
        streamReleases: [{ tag: 'v1.2.3' }],
        streamPolicy
      }),
    /Insufficient release history/
  );
});

test('evaluateRollbackValidation reports branch and policy failures', () => {
  const validation = evaluateRollbackValidation(
    [
      {
        name: 'main',
        remote: 'upstream',
        after: 'abc',
        matchesTarget: false
      }
    ],
    'def',
    {
      executed: true,
      status: 'fail',
      exitCode: 1
    }
  );
  assert.equal(validation.status, 'fail');
  assert.equal(validation.failures.length, 2);
  assert.ok(validation.failures.some((failure) => failure.code === 'branch-not-at-target'));
  assert.ok(validation.failures.some((failure) => failure.code === 'policy-sync-failed'));
});

test('resolveRollbackRemoteName falls back to origin when it matches the repository slug', () => {
  const resolution = resolveRollbackRemoteName({
    repoRoot: '/repo',
    preferredRemote: 'upstream',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    tryResolveRemoteFn: (_repoRoot, remoteName) => {
      if (remoteName === 'origin') {
        return {
          parsed: {
            owner: 'LabVIEW-Community-CI-CD',
            repo: 'compare-vi-cli-action'
          }
        };
      }
      return null;
    }
  });

  assert.equal(resolution.configuredRemote, 'upstream');
  assert.equal(resolution.effectiveRemote, 'origin');
  assert.match(resolution.fallbackReason, /using origin/i);
});

test('resolveRollbackRemoteName rejects missing configured remote when origin is a fork', () => {
  assert.throws(
    () =>
      resolveRollbackRemoteName({
        repoRoot: '/repo',
        preferredRemote: 'upstream',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        tryResolveRemoteFn: (_repoRoot, remoteName) => {
          if (remoteName === 'origin') {
            return {
              parsed: {
                owner: 'fork-owner',
                repo: 'compare-vi-cli-action'
              }
            };
          }
          return null;
        }
      }),
    /origin does not match repository/i
  );
});

test('runRollback uses origin fallback for dry-run planning when upstream is unavailable', async () => {
  const policy = normalizeReleaseRollbackPolicy({});
  const fetchCalls = [];
  const resolution = await runRollback(
    {
      ...parseArgs(['node', 'rollback-release.mjs']),
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      repoRoot: '/repo',
      policy,
      fetchReleaseRecords: () => [
        { tag_name: 'v1.2.3', draft: false, prerelease: false, published_at: '2026-03-05T00:00:00Z' },
        { tag_name: 'v1.2.2', draft: false, prerelease: false, published_at: '2026-03-01T00:00:00Z' }
      ],
      remoteResolver: () => ({
        configuredRemote: 'upstream',
        effectiveRemote: 'origin',
        fallbackReason: 'Configured rollback remote is missing; using origin.'
      }),
      fetchRemoteRefs: (_repoRoot, remote, branches) => {
        fetchCalls.push({ remote, branches });
      },
      resolveTagCommit: () => 'deadbeef',
      tryResolveRef: (_repoRoot, ref) => `sha-for:${ref}`
    }
  );

  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0].remote, 'origin');
  assert.deepEqual(fetchCalls[0].branches, ['main', 'develop']);
  assert.equal(resolution.policy.configuredRemote, 'upstream');
  assert.equal(resolution.policy.remote, 'origin');
  assert.match(resolution.policy.remoteFallbackReason, /using origin/i);
  assert.equal(resolution.branches[0].remote, 'origin');
  assert.equal(resolution.summary.status, 'pass');
});

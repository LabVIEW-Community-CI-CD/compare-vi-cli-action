#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  normalizeVersionInput,
  writeReleaseMetadata,
  summarizeStatusCheckRollup,
  getReleaseMetadataPath,
  assertReleaseMetadataExists,
  ensureReleaseBranchMetadata
} from '../lib/release-utils.mjs';

test('normalizeVersionInput handles tagged and untagged semver', () => {
  assert.deepEqual(normalizeVersionInput('1.2.3'), { tag: 'v1.2.3', semver: '1.2.3' });
  assert.deepEqual(normalizeVersionInput('v2.0.0'), { tag: 'v2.0.0', semver: '2.0.0' });
});

test('normalizeVersionInput rejects invalid versions', () => {
  assert.throws(() => normalizeVersionInput('v1.2'), /does not comply/);
  assert.throws(() => normalizeVersionInput('foo'), /does not comply/);
});

test('writeReleaseMetadata writes JSON to release directory', async (t) => {
  const tempDir = await mkdtemp(path.join(tmpdir(), 'release-meta-'));
  t.after(() => rm(tempDir, { recursive: true, force: true }));

  const filePath = await writeReleaseMetadata(tempDir, 'v9.9.9', 'branch', { schema: 'test', foo: 'bar' });
  const contents = JSON.parse(await readFile(filePath, 'utf8'));
  assert.equal(contents.foo, 'bar');
  assert.equal(contents.schema, 'test');
});

test('summarizeStatusCheckRollup normalizes check data', () => {
  const rollup = [
    { name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS', detailsUrl: 'https://example.com/lint' },
    null,
    { name: 'tests', status: 'COMPLETED', conclusion: 'FAILURE' }
  ];
  const summary = summarizeStatusCheckRollup(rollup);
  assert.equal(summary.length, 2);
  assert.deepEqual(summary[0], {
    name: 'lint',
    status: 'COMPLETED',
    conclusion: 'SUCCESS',
    url: 'https://example.com/lint'
  });
});

test('getReleaseMetadataPath returns deterministic release artifact path', () => {
  const actual = getReleaseMetadataPath('/repo', 'v1.2.3', 'branch');
  assert.equal(actual, path.join('/repo', 'tests', 'results', '_agent', 'release', 'release-v1.2.3-branch.json'));
});

test('assertReleaseMetadataExists throws when release artifact is missing', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-utils-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await assert.rejects(
    () => assertReleaseMetadataExists(repoDir, 'v9.9.9', 'branch'),
    /Missing required artifact/i
  );
});

test('assertReleaseMetadataExists succeeds after writing release metadata', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-utils-present-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await writeReleaseMetadata(repoDir, 'v1.0.0', 'branch', { schema: 'release/branch@v1' });
  const artifactPath = await assertReleaseMetadataExists(repoDir, 'v1.0.0', 'branch');
  assert.equal(
    artifactPath,
    path.join(repoDir, 'tests', 'results', '_agent', 'release', 'release-v1.0.0-branch.json')
  );
});

test('ensureReleaseBranchMetadata recovers missing branch metadata when branch state is already authoritative', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-utils-recover-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  const result = await ensureReleaseBranchMetadata(repoDir, {
    tag: 'v1.2.3-rc.1',
    semver: '1.2.3-rc.1',
    branch: 'release/v1.2.3-rc.1',
    branchExists: true,
    baseCommit: 'abc123',
    releaseCommit: 'def456',
    pullRequest: {
      number: 42,
      url: 'https://example.test/pr/42',
      mergeStateStatus: 'MERGED'
    },
    recoverySource: 'release-finalize'
  });

  assert.equal(result.recovered, true);
  assert.equal(
    result.artifactPath,
    path.join(repoDir, 'tests', 'results', '_agent', 'release', 'release-v1.2.3-rc.1-branch.json')
  );

  const contents = JSON.parse(await readFile(result.artifactPath, 'utf8'));
  assert.equal(contents.schema, 'release/branch@v1');
  assert.equal(contents.branch, 'release/v1.2.3-rc.1');
  assert.equal(contents.baseBranch, 'develop');
  assert.equal(contents.releaseCommit, 'def456');
  assert.equal(contents.recovered, true);
  assert.equal(contents.recoverySource, 'release-finalize');
  assert.equal(contents.pullRequest.number, 42);
});

test('ensureReleaseBranchMetadata preserves missing-artifact failure when branch state is not authoritative', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-utils-no-recover-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await assert.rejects(
    () =>
      ensureReleaseBranchMetadata(repoDir, {
        tag: 'v1.2.3',
        semver: '1.2.3',
        branch: 'release/v1.2.3',
        branchExists: false,
        pullRequest: null
      }),
    /Missing required artifact/i
  );
});

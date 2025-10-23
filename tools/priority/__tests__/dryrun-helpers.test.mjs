#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFile, mkdtemp, mkdir, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const dryrunFeatureBranch = 'feature/release-dryrun-helpers';
const dryrunBaseBranch = 'develop';

function checkoutInitialBranch(repoDir, branchName, baseBranch) {
  const localRef = spawnSync('git', ['rev-parse', '--verify', branchName], {
    cwd: repoDir,
    encoding: 'utf8'
  });
  if (localRef.status === 0) {
    run('git', ['checkout', branchName], { cwd: repoDir });
    return;
  }

  const remotes = ['upstream', 'origin'];
  for (const remote of remotes) {
    const remoteRef = spawnSync('git', ['rev-parse', '--verify', `${remote}/${branchName}`], {
      cwd: repoDir,
      encoding: 'utf8'
    });
    if (remoteRef.status === 0) {
      run('git', ['checkout', '-b', branchName, `${remote}/${branchName}`], { cwd: repoDir });
      return;
    }
  }

  const baseCandidates = ['upstream', 'origin']
    .map((remote) => `${remote}/${baseBranch}`)
    .concat([baseBranch, 'HEAD']);

  for (const candidate of baseCandidates) {
    if (candidate !== 'HEAD') {
      const probe = spawnSync('git', ['rev-parse', '--verify', candidate], {
        cwd: repoDir,
        encoding: 'utf8'
      });
      if (probe.status !== 0) {
        continue;
      }
    }

    run('git', ['checkout', '-B', baseBranch, candidate], { cwd: repoDir });
    run('git', ['checkout', '-b', branchName], { cwd: repoDir });
    return;
  }

  run('git', ['checkout', '-B', baseBranch, 'HEAD'], { cwd: repoDir });
  run('git', ['checkout', '-b', branchName], { cwd: repoDir });
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    ...options
  });

  if (result.status !== 0) {
    const stderr = result.stderr?.trim() ?? 'no stderr';
    throw new Error(`${command} ${args.join(' ')} failed with ${result.status}: ${stderr}`);
  }

  return result.stdout.trim();
}

async function setupTemporaryRepo(t) {
  const parentDir = await mkdtemp(path.join(tmpdir(), 'comparevi-dryrun-'));
  const repoDir = path.join(parentDir, 'repo');

  run('git', ['clone', '--local', '--no-hardlinks', repoRoot, repoDir]);
  run('git', ['remote', 'add', 'upstream', repoRoot], { cwd: repoDir });
  run('git', ['fetch', 'upstream'], { cwd: repoDir });
  checkoutInitialBranch(repoDir, dryrunFeatureBranch, dryrunBaseBranch);

  const helperFiles = [
    'create-release-branch.dryrun.mjs',
    'finalize-release.dryrun.mjs',
    'create-feature-branch.dryrun.mjs',
    'finalize-feature.dryrun.mjs'
  ];

  await mkdir(path.join(repoDir, 'tools', 'priority', 'lib'), { recursive: true });

  for (const file of helperFiles) {
    const source = path.join(repoRoot, 'tools', 'priority', file);
    const target = path.join(repoDir, 'tools', 'priority', file);
    await copyFile(source, target);
  }

  const libSource = path.join(repoRoot, 'tools', 'priority', 'lib');
  const libTarget = path.join(repoDir, 'tools', 'priority', 'lib');
  const libEntries = await readdir(libSource);
  for (const entry of libEntries) {
    if (entry.endsWith('.mjs')) {
      await copyFile(path.join(libSource, entry), path.join(libTarget, entry));
    }
  }

  const dirty = run('git', ['status', '--porcelain'], { cwd: repoDir });
  if (dirty) {
    run('git', ['config', 'user.name', 'Dry-run Tests'], { cwd: repoDir });
    run('git', ['config', 'user.email', 'dryrun-tests@example.com'], { cwd: repoDir });
    run('git', ['add', 'tools/priority'], { cwd: repoDir });
    const commitResult = spawnSync('git', ['commit', '--allow-empty', '-m', 'test: sync helper scripts'], {
      cwd: repoDir,
      encoding: 'utf8'
    });
    const commitError = commitResult.stderr?.trim() ?? '';
    if (commitResult.status !== 0 && !commitError.includes('nothing to commit')) {
      throw new Error(`git commit failed: ${commitError || 'unknown error'}`);
    }
  }

  t.after(async () => {
    await rm(parentDir, { recursive: true, force: true });
  });

  return repoDir;
}

test('dry-run helpers create metadata and restore branch context', async (t) => {
  const repoDir = await setupTemporaryRepo(t);

  const releaseCreate = path.join(repoDir, 'tools', 'priority', 'create-release-branch.dryrun.mjs');
  const releaseFinalize = path.join(repoDir, 'tools', 'priority', 'finalize-release.dryrun.mjs');
  const featureCreate = path.join(repoDir, 'tools', 'priority', 'create-feature-branch.dryrun.mjs');
  const featureFinalize = path.join(repoDir, 'tools', 'priority', 'finalize-feature.dryrun.mjs');

  const initialBranch = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoDir });
  assert.equal(initialBranch, dryrunFeatureBranch);

  const helpOutput = run('node', [releaseCreate, '--help'], { cwd: repoDir });
  assert.match(helpOutput, /Usage: npm run release:branch:dry/);
  const helpBranches = run('git', ['branch', '--list', 'release/--help'], { cwd: repoDir });
  assert.equal(helpBranches, '');

  const version = 'v0.0.0-test';
  run('node', [releaseCreate, version], { cwd: repoDir });
  const postCreateBranch = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoDir });
  assert.equal(postCreateBranch, dryrunFeatureBranch);
  const releaseBranchList = run('git', ['branch', '--list', `release/${version}`], { cwd: repoDir });
  assert.ok(releaseBranchList.includes(`release/${version}`));

  const releaseMetadataPath = path.join(repoDir, 'tests', 'results', '_agent', 'release', `release-${version}-dryrun.json`);
  const releaseMetadata = JSON.parse(await readFile(releaseMetadataPath, 'utf8'));
  assert.equal(releaseMetadata.branch, `release/${version}`);
  assert.equal(releaseMetadata.version, version);
  assert.equal(releaseMetadata.baseBranch, dryrunBaseBranch);
  assert.equal(releaseMetadata.dryRun, true);
  assert.ok(Date.parse(releaseMetadata.createdAt));

  run('node', [releaseFinalize, version], { cwd: repoDir });
  const finalizeBranch = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoDir });
  assert.equal(finalizeBranch, dryrunFeatureBranch);

  const releaseFinalizePath = path.join(repoDir, 'tests', 'results', '_agent', 'release', `release-${version}-finalize-dryrun.json`);
  const releaseFinalizeMetadata = JSON.parse(await readFile(releaseFinalizePath, 'utf8'));
  assert.equal(releaseFinalizeMetadata.version, version);
  assert.equal(releaseFinalizeMetadata.releaseBranch, `release/${version}`);
  assert.equal(releaseFinalizeMetadata.dryRun, true);
  assert.ok(Date.parse(releaseFinalizeMetadata.generatedAt));

  const featureSlug = 'my-feature';
  run('node', [featureCreate, featureSlug], { cwd: repoDir });
  const featureBranchAfterCreate = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoDir });
  assert.equal(featureBranchAfterCreate, dryrunFeatureBranch);

  const featureMetadataPath = path.join(repoDir, 'tests', 'results', '_agent', 'feature', `feature-${featureSlug}-dryrun.json`);
  const featureMetadata = JSON.parse(await readFile(featureMetadataPath, 'utf8'));
  assert.equal(featureMetadata.branch, `feature/${featureSlug}`);
  assert.equal(featureMetadata.baseBranch, dryrunBaseBranch);
  assert.equal(featureMetadata.dryRun, true);
  assert.ok(Date.parse(featureMetadata.createdAt));

  run('node', [featureFinalize, featureSlug], { cwd: repoDir });
  const featureBranchAfterFinalize = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoDir });
  assert.equal(featureBranchAfterFinalize, dryrunFeatureBranch);

  const featureFinalizePath = path.join(repoDir, 'tests', 'results', '_agent', 'feature', `feature-${featureSlug}-finalize-dryrun.json`);
  const featureFinalizeMetadata = JSON.parse(await readFile(featureFinalizePath, 'utf8'));
  assert.equal(featureFinalizeMetadata.branch, `feature/${featureSlug}`);
  assert.equal(featureFinalizeMetadata.dryRun, true);
  assert.ok(Date.parse(featureFinalizeMetadata.generatedAt));
});

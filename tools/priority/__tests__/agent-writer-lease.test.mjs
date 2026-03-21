#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  acquireWriterLease,
  __test,
  defaultLeaseRoot,
  defaultOwner,
  heartbeatWriterLease,
  inspectWriterLease,
  releaseWriterLease
} from '../agent-writer-lease.mjs';

function randomTempRoot(prefix) {
  return path.join(
    os.tmpdir(),
    `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`
  );
}

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

test('acquire blocks second owner while lease is active', async () => {
  const leaseRoot = randomTempRoot('agent-writer-lease-active');
  const first = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-a',
    staleSeconds: 600
  });
  assert.equal(first.status, 'acquired');

  const second = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-b',
    staleSeconds: 600,
    maxAttempts: 0
  });
  assert.equal(second.status, 'busy');
  assert.equal(second.holder, 'owner-a');

  const release = await releaseWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-a'
  });
  assert.equal(release.status, 'released');
});

test('acquire can renew heartbeat for same owner', async () => {
  const leaseRoot = randomTempRoot('agent-writer-lease-renew');
  const first = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-a'
  });
  assert.equal(first.status, 'acquired');

  const renewed = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-a'
  });
  assert.equal(renewed.status, 'renewed');
  assert.equal(renewed.lease.owner, 'owner-a');
  assert.equal(renewed.lease.leaseId, first.lease.leaseId);
});

test('stale lease requires explicit takeover and supports force takeover', async () => {
  const leaseRoot = randomTempRoot('agent-writer-lease-stale');
  const first = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-a',
    staleSeconds: 600
  });
  assert.equal(first.status, 'acquired');

  const leasePath = path.join(leaseRoot, 'workspace.json');
  const stale = { ...first.lease, heartbeatAt: new Date(Date.now() - 3_600_000).toISOString() };
  await fs.mkdir(path.dirname(leasePath), { recursive: true });
  await fs.writeFile(leasePath, `${JSON.stringify(stale, null, 2)}\n`, 'utf8');

  const blocked = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-b',
    staleSeconds: 300,
    forceTakeover: false
  });
  assert.equal(blocked.status, 'stale');
  assert.equal(blocked.holder, 'owner-a');

  const takeover = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-b',
    staleSeconds: 300,
    forceTakeover: true
  });
  assert.equal(takeover.status, 'takeover');
  assert.equal(takeover.lease.owner, 'owner-b');
  assert.equal(takeover.previousLease.owner, 'owner-a');
});

test('release and heartbeat enforce owner or lease-id matching', async () => {
  const leaseRoot = randomTempRoot('agent-writer-lease-ownership');
  const acquired = await acquireWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-a'
  });
  assert.equal(acquired.status, 'acquired');

  const mismatch = await releaseWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-b'
  });
  assert.equal(mismatch.status, 'mismatch');

  const heartbeat = await heartbeatWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-b',
    leaseId: acquired.lease.leaseId
  });
  assert.equal(heartbeat.status, 'renewed');

  const released = await releaseWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-b',
    leaseId: acquired.lease.leaseId
  });
  assert.equal(released.status, 'released');

  const inspect = await inspectWriterLease({
    leaseRoot,
    scope: 'workspace',
    owner: 'owner-a'
  });
  assert.equal(inspect.status, 'not-found');
});

test('defaultOwner prefers AGENT_WRITER_LEASE_OWNER when provided', () => {
  const previous = process.env.AGENT_WRITER_LEASE_OWNER;
  process.env.AGENT_WRITER_LEASE_OWNER = 'explicit-owner';
  try {
    assert.equal(defaultOwner(), 'explicit-owner');
  } finally {
    if (previous === undefined) {
      delete process.env.AGENT_WRITER_LEASE_OWNER;
    } else {
      process.env.AGENT_WRITER_LEASE_OWNER = previous;
    }
  }
});

test('defaultLeaseRoot resolves git-common-dir instead of assuming repoRoot/.git', () => {
  const probe = spawnSync('git', ['rev-parse', '--git-common-dir'], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  assert.equal(probe.status, 0, probe.stderr || 'git rev-parse --git-common-dir failed');
  const gitCommonDir = probe.stdout.trim();
  const expectedGitCommonDir = path.isAbsolute(gitCommonDir) ? path.normalize(gitCommonDir) : path.resolve(repoRoot, gitCommonDir);
  assert.equal(defaultLeaseRoot(), path.join(expectedGitCommonDir, 'agent-writer-leases'));
});

test('defaultLeaseRoot resolves git-common-dir for a linked worktree repo root override', async (t) => {
  const sandboxRoot = randomTempRoot('agent-writer-lease-worktree');
  const repoDir = path.join(sandboxRoot, 'repo');
  const worktreeDir = path.join(sandboxRoot, 'worktree');
  await fs.mkdir(sandboxRoot, { recursive: true });
  t.after(async () => {
    await fs.rm(sandboxRoot, { recursive: true, force: true });
  });

  const run = (command, args, cwd) => {
    const result = spawnSync(command, args, {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    });
    assert.equal(result.status, 0, result.stderr || `${command} ${args.join(' ')} failed`);
    return String(result.stdout ?? '').trim();
  };

  run('git', ['init', '--initial-branch=develop', repoDir], sandboxRoot);
  run('git', ['config', 'user.email', 'agent@example.com'], repoDir);
  run('git', ['config', 'user.name', 'Agent Runner'], repoDir);
  await fs.writeFile(path.join(repoDir, 'README.md'), 'lease\n', 'utf8');
  run('git', ['add', 'README.md'], repoDir);
  run('git', ['commit', '-m', 'seed'], repoDir);
  run('git', ['worktree', 'add', '-b', 'issue/test-lease', worktreeDir, 'develop'], repoDir);

  const gitCommonDir = run('git', ['rev-parse', '--git-common-dir'], worktreeDir);
  const expectedGitCommonDir = path.isAbsolute(gitCommonDir)
    ? path.normalize(gitCommonDir)
    : path.resolve(worktreeDir, gitCommonDir);

  assert.equal(
    defaultLeaseRoot({ repoRoot: worktreeDir }),
    path.join(expectedGitCommonDir, 'agent-writer-leases')
  );
  assert.notEqual(
    defaultLeaseRoot({ repoRoot: worktreeDir }),
    path.join(worktreeDir, '.git', 'agent-writer-leases')
  );
});

test('replaceFileWithRetry tolerates a transient Windows-style rename failure', async (t) => {
  const sandboxRoot = randomTempRoot('agent-writer-lease-rename-retry');
  await fs.mkdir(sandboxRoot, { recursive: true });
  t.after(async () => {
    await fs.rm(sandboxRoot, { recursive: true, force: true });
  });

  const targetPath = path.join(sandboxRoot, 'workspace.json');
  const tempPath = path.join(sandboxRoot, 'workspace.json.tmp');
  await fs.writeFile(targetPath, 'old\n', 'utf8');
  await fs.writeFile(tempPath, 'new\n', 'utf8');

  let renameAttempts = 0;
  const operations = [];
  const fsModule = {
    async rename(source, destination) {
      renameAttempts += 1;
      operations.push(`rename:${renameAttempts}`);
      if (renameAttempts === 1) {
        const error = new Error('EPERM');
        error.code = 'EPERM';
        throw error;
      }
      return fs.rename(source, destination);
    },
    async rm(filePath, options) {
      operations.push(`rm:${path.basename(filePath)}`);
      return fs.rm(filePath, options);
    }
  };

  await __test.replaceFileWithRetry(tempPath, targetPath, {
    retryAttempts: 2,
    retryWaitMs: 0,
    fsModule
  });

  assert.equal(renameAttempts, 2);
  assert.deepEqual(operations.slice(0, 3), ['rename:1', 'rm:workspace.json', 'rename:2']);
  assert.equal(await fs.readFile(targetPath, 'utf8'), 'new\n');
});

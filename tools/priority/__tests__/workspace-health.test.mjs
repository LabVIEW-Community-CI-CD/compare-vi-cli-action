#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { evaluateWorkspaceHealth } from '../lib/workspace-health.mjs';
import { runCli } from '../check-workspace-health.mjs';

const repoRoot = path.resolve(path.sep, 'tmp', 'workspace-health-repo');
const gitDir = path.join(repoRoot, '.git');
const indexPath = path.join(gitDir, 'index');
const rebasePath = path.join(gitDir, 'rebase-merge');
const indexLockPath = path.join(gitDir, 'index.lock');
const leasePath = path.join(gitDir, 'agent-writer-leases', 'workspace.json');

function normalize(value) {
  return path.normalize(value);
}

function makeDeps({
  existing = [],
  writable = [],
  files = {},
  mtimes = {},
  nowMs = 100_000
} = {}) {
  const existingSet = new Set(existing.map((entry) => normalize(entry)));
  const writableSet = new Set(writable.map((entry) => normalize(entry)));
  const fileMap = new Map(
    Object.entries(files).map(([filePath, content]) => [normalize(filePath), String(content)])
  );
  const mtimeMap = new Map(
    Object.entries(mtimes).map(([filePath, mtimeMs]) => [normalize(filePath), Number(mtimeMs)])
  );

  return {
    spawnSyncFn: () => ({ status: 0, stdout: '.git\n', stderr: '' }),
    existsSyncFn: (filePath) => existingSet.has(normalize(filePath)),
    accessSyncFn: (filePath) => {
      if (!writableSet.has(normalize(filePath))) {
        const error = new Error('EACCES');
        error.code = 'EACCES';
        throw error;
      }
    },
    readFileSyncFn: (filePath) => {
      const key = normalize(filePath);
      if (!fileMap.has(key)) {
        const error = new Error('ENOENT');
        error.code = 'ENOENT';
        throw error;
      }
      return fileMap.get(key);
    },
    statSyncFn: (filePath) => ({ mtimeMs: mtimeMap.get(normalize(filePath)) ?? nowMs }),
    readdirSyncFn: () => [],
    nowFn: () => nowMs
  };
}

test('evaluateWorkspaceHealth passes for a clean workspace when lease is optional', () => {
  const report = evaluateWorkspaceHealth(
    {
      repoRoot,
      leaseMode: 'optional'
    },
    makeDeps({
      existing: [indexPath],
      writable: [indexPath]
    })
  );

  assert.equal(report.status, 'pass');
  assert.equal(report.failures.length, 0);
});

test('evaluateWorkspaceHealth fails when git index is not writable', () => {
  const report = evaluateWorkspaceHealth(
    {
      repoRoot,
      leaseMode: 'ignore'
    },
    makeDeps({
      existing: [indexPath]
    })
  );

  assert.equal(report.status, 'fail');
  assert.ok(report.failures.some((entry) => entry.id === 'index-not-writable'));
});

test('evaluateWorkspaceHealth fails when rebase state marker exists', () => {
  const report = evaluateWorkspaceHealth(
    {
      repoRoot,
      leaseMode: 'ignore'
    },
    makeDeps({
      existing: [indexPath, rebasePath],
      writable: [indexPath]
    })
  );

  assert.equal(report.status, 'fail');
  assert.ok(report.failures.some((entry) => entry.id === 'git-operation-in-progress'));
});

test('evaluateWorkspaceHealth fails when stale lock file exists', () => {
  const report = evaluateWorkspaceHealth(
    {
      repoRoot,
      leaseMode: 'ignore',
      lockStaleSeconds: 30
    },
    makeDeps({
      existing: [indexPath, indexLockPath],
      writable: [indexPath],
      mtimes: {
        [indexLockPath]: 0
      },
      nowMs: 120_000
    })
  );

  assert.equal(report.status, 'fail');
  assert.ok(report.failures.some((entry) => entry.id === 'stale-lock-file'));
});

test('evaluateWorkspaceHealth fails when required lease owner mismatches', () => {
  const report = evaluateWorkspaceHealth(
    {
      repoRoot,
      leaseMode: 'required',
      expectedLeaseOwner: 'agent-a@host:default',
      leaseRoot: path.join(gitDir, 'agent-writer-leases')
    },
    makeDeps({
      existing: [indexPath, leasePath],
      writable: [indexPath],
      files: {
        [leasePath]: JSON.stringify({ owner: 'agent-b@host:default', leaseId: 'abc123' })
      }
    })
  );

  assert.equal(report.status, 'fail');
  assert.ok(report.failures.some((entry) => entry.id === 'lease-owner-mismatch'));
});

test('evaluateWorkspaceHealth reads required writer lease from git-common-dir in a linked worktree', async (t) => {
  const sandboxRoot = await mkdtemp(path.join(tmpdir(), 'workspace-health-worktree-'));
  const repoDir = path.join(sandboxRoot, 'repo');
  const worktreeDir = path.join(sandboxRoot, 'worktree');
  t.after(async () => {
    await rm(sandboxRoot, { recursive: true, force: true });
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
  await writeFile(path.join(repoDir, 'README.md'), 'workspace health\n', 'utf8');
  run('git', ['add', 'README.md'], repoDir);
  run('git', ['commit', '-m', 'seed'], repoDir);
  run('git', ['worktree', 'add', '-b', 'issue/test-workspace-health', worktreeDir, 'develop'], repoDir);

  const rawGitDir = run('git', ['rev-parse', '--git-dir'], worktreeDir);
  const rawGitCommonDir = run('git', ['rev-parse', '--git-common-dir'], worktreeDir);
  const resolvedGitDir = path.isAbsolute(rawGitDir)
    ? path.normalize(rawGitDir)
    : path.resolve(worktreeDir, rawGitDir);
  const resolvedGitCommonDir = path.isAbsolute(rawGitCommonDir)
    ? path.normalize(rawGitCommonDir)
    : path.resolve(worktreeDir, rawGitCommonDir);

  const expectedOwner = 'agent@example.com:linked-worktree';
  const expectedLeaseId = 'lease-worktree-123';
  const commonLeasePath = path.join(resolvedGitCommonDir, 'agent-writer-leases', 'workspace.json');
  await mkdir(path.dirname(commonLeasePath), { recursive: true });
  await writeFile(
    commonLeasePath,
    `${JSON.stringify({ owner: expectedOwner, leaseId: expectedLeaseId }, null, 2)}\n`,
    'utf8'
  );

  const report = evaluateWorkspaceHealth({
    repoRoot: worktreeDir,
    leaseMode: 'required',
    expectedLeaseOwner: expectedOwner,
    expectedLeaseId
  });

  assert.equal(report.status, 'pass');
  const writerLease = report.checks.find((entry) => entry.id === 'writer-lease');
  assert.ok(writerLease);
  assert.equal(writerLease.status, 'pass');
  assert.equal(path.normalize(writerLease.path), path.normalize(commonLeasePath));
  assert.notEqual(
    path.normalize(writerLease.path),
    path.normalize(path.join(resolvedGitDir, 'agent-writer-leases', 'workspace.json'))
  );
});

test('workspace health CLI writes report even when failing', async () => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'workspace-health-cli-'));
  const tempGitDir = path.join(tempRoot, '.git');
  const reportPath = path.join(tempRoot, 'tests', 'results', '_agent', 'health', 'cli-report.json');

  const init = spawnSync('git', ['init', '-q'], { cwd: tempRoot, encoding: 'utf8' });
  assert.equal(init.status, 0, init.stderr || init.stdout);
  await mkdir(tempGitDir, { recursive: true });
  await writeFile(path.join(tempGitDir, 'index'), 'index\n', 'utf8');
  await writeFile(path.join(tempGitDir, 'MERGE_HEAD'), '1234\n', 'utf8');

  const code = await runCli([
    '--repo-root',
    tempRoot,
    '--report',
    reportPath,
    '--lease-mode',
    'ignore',
    '--quiet'
  ]);

  assert.equal(code, 1);
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(report.status, 'fail');
  assert.ok(report.failures.some((entry) => entry.id === 'git-operation-in-progress'));
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
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
      expectedLeaseOwner: 'agent-a@host:default'
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

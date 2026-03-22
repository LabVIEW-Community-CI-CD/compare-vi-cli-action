#!/usr/bin/env node
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { resolvePrioritySyncExecutionRoot, runPrioritySync } from '../run-sync-standing-priority.mjs';

function createGitSpawnSync({ currentBranch, worktreeText, dirtyRoots = new Map(), nodeStatus = 0, nodeStdout = '', nodeStderr = '' }) {
  const calls = [];
  const spawnSyncFn = (command, args, options = {}) => {
    calls.push({
      command,
      args: [...args],
      cwd: options.cwd
    });

    if (command === 'git' && args[0] === 'branch' && args[1] === '--show-current') {
      return { status: 0, stdout: `${currentBranch}\n`, stderr: '' };
    }

    if (command === 'git' && args[0] === 'worktree' && args[1] === 'list' && args[2] === '--porcelain') {
      return { status: 0, stdout: worktreeText, stderr: '' };
    }

    if (command === 'git' && args[0] === 'status' && args[1] === '--porcelain') {
      return { status: 0, stdout: dirtyRoots.get(path.resolve(options.cwd)) ?? '', stderr: '' };
    }

    if (command === process.execPath) {
      return { status: nodeStatus, stdout: nodeStdout, stderr: nodeStderr };
    }

    throw new Error(`Unexpected command: ${command} ${args.join(' ')}`);
  };

  return { spawnSyncFn, calls };
}

function buildWorktreeList(repoRoot, helperRoots = []) {
  const entries = [
    `worktree ${repoRoot}`,
    'HEAD 1111111',
    'branch refs/heads/issue/origin-1744-router-sync',
    ''
  ];

  for (const helperRoot of helperRoots) {
    entries.push(
      `worktree ${helperRoot}`,
      'HEAD 2222222',
      'branch refs/heads/develop',
      ''
    );
  }

  return `${entries.join('\n')}\n`;
}

test('resolvePrioritySyncExecutionRoot delegates work branches to a clean develop helper', () => {
  const repoRoot = path.resolve('C:/repo/issue-1744');
  const helperRoot = path.resolve('C:/repo/develop-clean');
  const { spawnSyncFn } = createGitSpawnSync({
    currentBranch: 'issue/origin-1744-router-sync',
    worktreeText: buildWorktreeList(repoRoot, [helperRoot]),
    dirtyRoots: new Map([[helperRoot, '']])
  });

  const plan = resolvePrioritySyncExecutionRoot({
    repoRoot,
    spawnSyncFn
  });

  assert.equal(plan.executionRepoRoot, helperRoot);
  assert.equal(plan.delegated, true);
  assert.equal(plan.reason, 'clean-develop-helper');
});

test('resolvePrioritySyncExecutionRoot falls back when only dirty develop helpers exist', () => {
  const repoRoot = path.resolve('C:/repo/issue-1744');
  const helperRoot = path.resolve('C:/repo/develop-dirty');
  const { spawnSyncFn } = createGitSpawnSync({
    currentBranch: 'issue/origin-1744-router-sync',
    worktreeText: buildWorktreeList(repoRoot, [helperRoot]),
    dirtyRoots: new Map([[helperRoot, ' M tests/results/_agent/issue/router.json\n']])
  });

  const plan = resolvePrioritySyncExecutionRoot({
    repoRoot,
    spawnSyncFn
  });

  assert.equal(plan.executionRepoRoot, repoRoot);
  assert.equal(plan.delegated, false);
  assert.equal(plan.reason, 'dirty-develop-helper');
});

test('runPrioritySync executes the helper script from a clean develop checkout while writing into the caller repo', () => {
  const repoRoot = path.resolve('C:/repo/issue-1744');
  const helperRoot = path.resolve('C:/repo/develop-clean');
  const stdoutChunks = [];
  const stderrChunks = [];
  const { spawnSyncFn, calls } = createGitSpawnSync({
    currentBranch: 'issue/origin-1744-router-sync',
    worktreeText: buildWorktreeList(repoRoot, [helperRoot]),
    dirtyRoots: new Map([[helperRoot, '']]),
    nodeStatus: 0,
    nodeStdout: '[priority] Standing issue: #1744\n',
    nodeStderr: ''
  });

  const result = runPrioritySync({
    argv: ['node', 'run-sync-standing-priority.mjs', '--fail-on-missing'],
    repoRoot,
    spawnSyncFn,
    stdout: { write: (text) => stdoutChunks.push(text) },
    stderr: { write: (text) => stderrChunks.push(text) }
  });

  const nodeInvocation = calls.find((entry) => entry.command === process.execPath);
  assert.ok(nodeInvocation, 'expected node helper invocation');
  assert.equal(nodeInvocation.cwd, repoRoot);
  assert.equal(nodeInvocation.args[0], path.join(helperRoot, 'tools', 'priority', 'sync-standing-priority.mjs'));
  assert.equal(result.status, 0);
  assert.match(stdoutChunks.join(''), /delegated to clean develop helper/i);
  assert.match(stdoutChunks.join(''), /Standing issue: #1744/);
  assert.equal(stderrChunks.join(''), '');
});

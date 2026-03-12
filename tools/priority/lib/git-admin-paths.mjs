#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';

function runGit(args, { cwd, env = process.env, spawnSyncFn = spawnSync } = {}) {
  const result = spawnSyncFn('git', args, {
    cwd,
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });

  if (result.status !== 0) {
    const stderr = String(result.stderr ?? '').trim();
    throw new Error(stderr || `git ${args.join(' ')} failed with exit code ${result.status}`);
  }

  return String(result.stdout ?? '').trim();
}

function normalizeGitPath(cwd, rawPath) {
  if (!rawPath) {
    throw new Error('git returned an empty path');
  }

  return path.isAbsolute(rawPath)
    ? path.normalize(rawPath)
    : path.normalize(path.resolve(cwd, rawPath));
}

export function resolveGitPath(pathspec, { cwd = process.cwd(), env = process.env, spawnSyncFn = spawnSync } = {}) {
  const rawPath = runGit(['rev-parse', '--git-path', pathspec], { cwd, env, spawnSyncFn });
  return normalizeGitPath(cwd, rawPath);
}

export function resolveGitAdminPaths({
  cwd = process.cwd(),
  env = process.env,
  spawnSyncFn = spawnSync,
  includeGitPaths = []
} = {}) {
  const repoRoot = normalizeGitPath(cwd, runGit(['rev-parse', '--show-toplevel'], { cwd, env, spawnSyncFn }));
  const gitDir = normalizeGitPath(repoRoot, runGit(['rev-parse', '--git-dir'], { cwd: repoRoot, env, spawnSyncFn }));
  const gitCommonDir = normalizeGitPath(
    repoRoot,
    runGit(['rev-parse', '--git-common-dir'], { cwd: repoRoot, env, spawnSyncFn })
  );

  const gitPaths = {};
  for (const entry of includeGitPaths) {
    gitPaths[entry] = resolveGitPath(entry, { cwd: repoRoot, env, spawnSyncFn });
  }

  return {
    repoRoot,
    gitDir,
    gitCommonDir,
    gitPaths
  };
}

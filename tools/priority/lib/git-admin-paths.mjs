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

  if (result.error) {
    const underlying = result.error.message || String(result.error);
    const code = result.error.code ? ` (code ${result.error.code})` : '';
    throw new Error(`Failed to run git ${args.join(' ')}: ${underlying}${code}`);
  }

  if (result.status !== 0) {
    const stderr = String(result.stderr ?? '').trim();
    if (stderr) {
      throw new Error(`git ${args.join(' ')} failed: ${stderr}`);
    }

    const details = [];
    if (result.status !== null && result.status !== undefined) {
      details.push(`exit code ${result.status}`);
    }
    if (result.signal) {
      details.push(`signal ${result.signal}`);
    }
    const suffix = details.length ? ` (${details.join(', ')})` : '';
    throw new Error(`git ${args.join(' ')} failed${suffix}`);
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

#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { parseGitWorktreeListPorcelain } from './develop-sync.mjs';

const WORK_BRANCH_PATTERN = /^(issue\/|feature\/|release\/|hotfix\/|bugfix\/)/i;
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const SYNC_SCRIPT_RELATIVE_PATH = path.join('tools', 'priority', 'sync-standing-priority.mjs');

function runGitText(spawnSyncFn, cwd, args, env) {
  const result = spawnSyncFn('git', args, {
    cwd,
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const detail = String(result.stderr ?? result.stdout ?? '').trim() || `git exited with status ${result.status}`;
    throw new Error(detail);
  }
  return String(result.stdout ?? '').trim();
}

function isDirtyWorktree({ repoRoot, env = process.env, spawnSyncFn = spawnSync } = {}) {
  const statusText = runGitText(spawnSyncFn, repoRoot, ['status', '--porcelain'], env);
  return statusText.length > 0;
}

export function resolvePrioritySyncExecutionRoot({
  repoRoot = getRepoRoot(),
  env = process.env,
  spawnSyncFn = spawnSync
} = {}) {
  const normalizedRepoRoot = path.resolve(repoRoot);
  let currentBranch = '';
  try {
    currentBranch = runGitText(spawnSyncFn, normalizedRepoRoot, ['branch', '--show-current'], env);
  } catch {
    return {
      repoRoot: normalizedRepoRoot,
      executionRepoRoot: normalizedRepoRoot,
      currentBranch: null,
      delegated: false,
      helperRoot: null,
      reason: null
    };
  }

  if (!WORK_BRANCH_PATTERN.test(currentBranch)) {
    return {
      repoRoot: normalizedRepoRoot,
      executionRepoRoot: normalizedRepoRoot,
      currentBranch,
      delegated: false,
      helperRoot: null,
      reason: null
    };
  }

  try {
    const worktreeText = runGitText(spawnSyncFn, normalizedRepoRoot, ['worktree', 'list', '--porcelain'], env);
    const helpers = parseGitWorktreeListPorcelain(worktreeText)
      .map((entry) => ({
        ...entry,
        path: path.resolve(entry.path)
      }))
      .filter((entry) => entry.path !== normalizedRepoRoot && entry.branchRef === 'refs/heads/develop');

    for (const helper of helpers) {
      try {
        if (!isDirtyWorktree({ repoRoot: helper.path, env, spawnSyncFn })) {
          return {
            repoRoot: normalizedRepoRoot,
            executionRepoRoot: helper.path,
            currentBranch,
            delegated: true,
            helperRoot: helper.path,
            reason: 'clean-develop-helper'
          };
        }
      } catch {
        // Keep scanning remaining helpers.
      }
    }

    if (helpers.length > 0) {
      return {
        repoRoot: normalizedRepoRoot,
        executionRepoRoot: normalizedRepoRoot,
        currentBranch,
        delegated: false,
        helperRoot: null,
        reason: 'dirty-develop-helper'
      };
    }
  } catch {
    // Fall back to the current checkout when helper resolution is unavailable.
  }

  return {
    repoRoot: normalizedRepoRoot,
    executionRepoRoot: normalizedRepoRoot,
    currentBranch,
    delegated: false,
    helperRoot: null,
    reason: null
  };
}

export function runPrioritySync({
  argv = process.argv,
  env = process.env,
  repoRoot = getRepoRoot(),
  spawnSyncFn = spawnSync,
  stdout = process.stdout,
  stderr = process.stderr
} = {}) {
  const executionPlan = resolvePrioritySyncExecutionRoot({
    repoRoot,
    env,
    spawnSyncFn
  });

  const scriptPath = path.join(executionPlan.executionRepoRoot, SYNC_SCRIPT_RELATIVE_PATH);
  const childArgs = [scriptPath, ...argv.slice(2)];
  const result = spawnSyncFn(process.execPath, childArgs, {
    cwd: executionPlan.repoRoot,
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });

  if (executionPlan.delegated && stdout?.write) {
    stdout.write(
      `[priority:sync] delegated to clean develop helper '${executionPlan.helperRoot}' from '${executionPlan.repoRoot}'.\n`
    );
  } else if (executionPlan.reason === 'dirty-develop-helper' && stdout?.write) {
    stdout.write(
      `[priority:sync] only dirty attached develop helpers were available for '${executionPlan.repoRoot}'; using caller checkout.\n`
    );
  }

  if (result.stdout && stdout?.write) {
    stdout.write(result.stdout);
  }
  if (result.stderr && stderr?.write) {
    stderr.write(result.stderr);
  }

  return {
    ...executionPlan,
    status: typeof result.status === 'number' ? result.status : 1
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  const result = runPrioritySync();
  process.exitCode = result.status;
}

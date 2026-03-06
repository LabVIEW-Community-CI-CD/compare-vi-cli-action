#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const MUTATING_GIT_COMMANDS = new Set([
  'add',
  'am',
  'apply',
  'branch',
  'checkout',
  'cherry-pick',
  'clean',
  'commit',
  'merge',
  'mv',
  'pull',
  'push',
  'rebase',
  'reset',
  'restore',
  'revert',
  'rm',
  'switch',
  'tag',
  'worktree'
]);

const BRANCH_MUTATING_FLAGS = new Set([
  '-c',
  '-C',
  '-d',
  '-D',
  '-m',
  '-M',
  '--copy',
  '--delete',
  '--move',
  '--set-upstream-to',
  '--unset-upstream'
]);

const TAG_READONLY_FLAGS = new Set([
  '-l',
  '--list',
  '--contains',
  '--merged',
  '--no-merged',
  '--points-at',
  '--sort',
  '--column',
  '-n',
  '--format'
]);

const LOCK_FILENAMES = ['index.lock', 'HEAD.lock', 'packed-refs.lock', 'shallow.lock'];

const LOCK_CONFLICT_PATTERNS = [
  /another git process seems to be running/i,
  /unable to create '.*\.lock'/i,
  /cannot lock ref/i,
  /could not lock/i,
  /index\.lock/i
];

const IN_PROGRESS_PATTERNS = [
  /you have not concluded your merge/i,
  /rebase in progress/i,
  /cherry-pick is already in progress/i,
  /revert is already in progress/i
];

const DEFAULT_MAX_RETRIES = 2;
const DEFAULT_RETRY_DELAY_MS = 350;
const DEFAULT_STALE_LOCK_AGE_MS = 30_000;

function parseBooleanEnv(value, fallback = false) {
  if (value == null) {
    return fallback;
  }
  const normalized = String(value).trim().toLowerCase();
  if (normalized === '' || normalized === '0' || normalized === 'false' || normalized === 'no') {
    return false;
  }
  if (normalized === '1' || normalized === 'true' || normalized === 'yes') {
    return true;
  }
  return fallback;
}

function parseNumberEnv(value, fallback) {
  if (value == null || value === '') {
    return fallback;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.max(0, Math.trunc(parsed));
}

function toSpawnOptions(options = {}) {
  const normalized = {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    ...options
  };
  return normalized;
}

function sleepSync(ms) {
  if (!Number.isFinite(ms) || ms <= 0) {
    return;
  }
  const view = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(view, 0, 0, ms);
}

function normalizeGitDir(cwd, gitDirRaw) {
  if (!gitDirRaw) {
    throw new Error('Unable to resolve .git directory.');
  }
  return path.isAbsolute(gitDirRaw) ? path.normalize(gitDirRaw) : path.normalize(path.resolve(cwd, gitDirRaw));
}

function resolveGitDir(cwd, spawnOptions, deps) {
  if (typeof deps.resolveGitDirFn === 'function') {
    const custom = deps.resolveGitDirFn(cwd, spawnOptions);
    return normalizeGitDir(cwd, custom);
  }

  const probe = deps.spawnSyncFn('git', ['rev-parse', '--git-dir'], {
    cwd,
    env: spawnOptions.env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });

  if (probe.status !== 0) {
    const stderr = (probe.stderr ?? '').trim();
    throw new Error(`Unable to resolve .git directory (git rev-parse --git-dir failed: ${stderr || probe.status}).`);
  }

  return normalizeGitDir(cwd, String(probe.stdout ?? '').trim());
}

function listRefLockFiles(refRoot, deps, output) {
  let entries = [];
  try {
    entries = deps.readdirSyncFn(refRoot, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    const fullPath = path.join(refRoot, entry.name);
    if (entry.isDirectory()) {
      listRefLockFiles(fullPath, deps, output);
      continue;
    }
    if (entry.isFile() && entry.name.endsWith('.lock')) {
      output.push(fullPath);
    }
  }
}

function safeStatMtimeMs(filePath, deps, nowMs) {
  try {
    const stat = deps.statSyncFn(filePath);
    return Number.isFinite(stat.mtimeMs) ? stat.mtimeMs : nowMs;
  } catch {
    return nowMs;
  }
}

function collectLockFiles(gitDir, deps, nowMs) {
  const lockCandidates = [];

  for (const name of LOCK_FILENAMES) {
    const fullPath = path.join(gitDir, name);
    if (deps.existsSyncFn(fullPath)) {
      lockCandidates.push(fullPath);
    }
  }

  listRefLockFiles(path.join(gitDir, 'refs'), deps, lockCandidates);

  const deduped = new Set();
  const locks = [];
  for (const lockPath of lockCandidates) {
    const normalized = path.normalize(lockPath);
    if (deduped.has(normalized)) {
      continue;
    }
    deduped.add(normalized);
    locks.push({
      path: normalized,
      mtimeMs: safeStatMtimeMs(normalized, deps, nowMs)
    });
  }
  return locks;
}

function collectInProgressStates(gitDir, deps) {
  const states = [];
  const markers = [
    { key: 'merge', description: 'merge in progress', path: path.join(gitDir, 'MERGE_HEAD') },
    { key: 'cherry-pick', description: 'cherry-pick in progress', path: path.join(gitDir, 'CHERRY_PICK_HEAD') },
    { key: 'revert', description: 'revert in progress', path: path.join(gitDir, 'REVERT_HEAD') },
    { key: 'rebase', description: 'rebase in progress', path: path.join(gitDir, 'rebase-apply') },
    { key: 'rebase', description: 'rebase in progress', path: path.join(gitDir, 'rebase-merge') }
  ];

  const seen = new Set();
  for (const marker of markers) {
    if (!deps.existsSyncFn(marker.path)) {
      continue;
    }
    if (seen.has(marker.key)) {
      continue;
    }
    seen.add(marker.key);
    states.push({
      key: marker.key,
      description: marker.description,
      markerPath: marker.path
    });
  }

  return states;
}

function commandAllowsState(command, args, stateKey) {
  if (command !== stateKey) {
    return false;
  }

  const normalized = args.slice(1);
  if (stateKey === 'merge') {
    return normalized.some((value) => ['--abort', '--continue', '--quit'].includes(value));
  }
  if (stateKey === 'rebase') {
    return normalized.some((value) => ['--abort', '--continue', '--skip', '--quit', '--edit-todo'].includes(value));
  }
  if (stateKey === 'cherry-pick' || stateKey === 'revert') {
    return normalized.some((value) => ['--abort', '--continue', '--skip', '--quit'].includes(value));
  }
  return false;
}

function evaluateBlockedStates(command, args, inProgressStates) {
  return inProgressStates.filter((state) => !commandAllowsState(command, args, state.key));
}

function formatGitPath(gitDir, fullPath) {
  const relative = path.relative(gitDir, fullPath).split(path.sep).join('/');
  if (!relative || relative.startsWith('..')) {
    return fullPath;
  }
  return `.git/${relative}`;
}

function parseTaskListCsvLine(line) {
  const values = [];
  let current = '';
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"') {
      quoted = !quoted;
      continue;
    }
    if (char === ',' && !quoted) {
      values.push(current.trim());
      current = '';
      continue;
    }
    current += char;
  }
  values.push(current.trim());
  return values;
}

function listGitProcesses(deps) {
  if (typeof deps.listGitProcessesFn === 'function') {
    return deps.listGitProcessesFn();
  }

  if (process.platform === 'win32') {
    const result = deps.spawnSyncFn('tasklist', ['/FI', 'IMAGENAME eq git.exe', '/FO', 'CSV', '/NH'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    if (result.status !== 0) {
      return [];
    }
    const rows = String(result.stdout ?? '')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .filter((line) => !line.startsWith('INFO:'));
    const pids = [];
    for (const row of rows) {
      const parts = parseTaskListCsvLine(row);
      const pid = Number(parts[1]);
      if (Number.isInteger(pid) && pid > 0) {
        pids.push(pid);
      }
    }
    return pids;
  }

  const result = deps.spawnSyncFn('pgrep', ['-x', 'git'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore']
  });
  if (result.status !== 0) {
    return [];
  }
  return String(result.stdout ?? '')
    .split(/\r?\n/)
    .map((line) => Number(line.trim()))
    .filter((pid) => Number.isInteger(pid) && pid > 0);
}

function killGitProcess(pid, deps) {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }

  if (typeof deps.killGitProcessFn === 'function') {
    return deps.killGitProcessFn(pid);
  }

  if (process.platform === 'win32') {
    const killed = deps.spawnSyncFn('taskkill', ['/PID', String(pid), '/F'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    });
    return killed.status === 0;
  }

  const killed = deps.spawnSyncFn('kill', ['-9', String(pid)], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return killed.status === 0;
}

function repairLocks({
  commandArgs,
  gitDir,
  locks,
  staleLockAgeMs,
  allowProcessKill,
  deps,
  nowMs,
  logFn
}) {
  const removed = [];
  const blocked = [];
  const killedPids = [];

  let activePids = listGitProcesses(deps);
  for (const lock of locks) {
    const ageMs = Math.max(0, Math.trunc(nowMs - lock.mtimeMs));
    const staleByAge = ageMs >= staleLockAgeMs;
    const hasActivePids = activePids.length > 0;

    if (hasActivePids && staleByAge && allowProcessKill) {
      for (const pid of activePids) {
        if (killGitProcess(pid, deps)) {
          killedPids.push(pid);
        }
      }
      activePids = listGitProcesses(deps);
    }

    const mayRemove = !hasActivePids || staleByAge;
    if (!mayRemove || activePids.length > 0) {
      const reason = hasActivePids && !staleByAge
        ? 'active-git-process'
        : hasActivePids && staleByAge && !allowProcessKill
          ? 'stale-lock-process-kill-disabled'
          : 'git-process-still-active';

      blocked.push({
        path: lock.path,
        ageMs,
        reason
      });
      continue;
    }

    try {
      deps.rmSyncFn(lock.path, { force: true });
      removed.push({
        path: lock.path,
        ageMs
      });
      logFn(
        `[safe-git] removed lock ${formatGitPath(gitDir, lock.path)} before git ${commandArgs.join(' ')} (age=${ageMs}ms)`
      );
    } catch (error) {
      blocked.push({
        path: lock.path,
        ageMs,
        reason: `remove-failed:${error.message}`
      });
    }
  }

  return {
    removed,
    blocked,
    killedPids
  };
}

function looksLikeLockConflict(result) {
  const combined = `${result?.stderr ?? ''}\n${result?.stdout ?? ''}`;
  return LOCK_CONFLICT_PATTERNS.some((pattern) => pattern.test(combined));
}

function looksLikeInProgressFailure(result) {
  const combined = `${result?.stderr ?? ''}\n${result?.stdout ?? ''}`;
  return IN_PROGRESS_PATTERNS.some((pattern) => pattern.test(combined));
}

function buildStateError(commandArgs, blockedStates) {
  const states = blockedStates.map((entry) => entry.description).join(', ');
  return new Error(
    `[safe-git] git ${commandArgs.join(' ')} blocked: ${states}. ` +
      'Resolve operation state (for example git status + --abort/--continue) and retry.'
  );
}

function buildLockError(commandArgs, blockedLocks, attemptCount, gitDir) {
  const lockList = blockedLocks
    .map((entry) => `${formatGitPath(gitDir, entry.path)} (${entry.reason}, age=${entry.ageMs}ms)`)
    .join(', ');
  return new Error(
    `[safe-git] git ${commandArgs.join(' ')} blocked by lock(s) after ${attemptCount} attempt(s): ${lockList}. ` +
      'Auto-repair is bounded; ensure no git process is running, clear stale lock(s), and retry.'
  );
}

function buildDeps(custom = {}) {
  return {
    spawnSyncFn: custom.spawnSyncFn ?? spawnSync,
    existsSyncFn: custom.existsSyncFn ?? existsSync,
    readdirSyncFn: custom.readdirSyncFn ?? readdirSync,
    statSyncFn: custom.statSyncFn ?? statSync,
    rmSyncFn: custom.rmSyncFn ?? rmSync,
    nowFn: custom.nowFn ?? (() => Date.now()),
    logFn: custom.logFn ?? ((message) => console.warn(message)),
    resolveGitDirFn: custom.resolveGitDirFn,
    listGitProcessesFn: custom.listGitProcessesFn,
    killGitProcessFn: custom.killGitProcessFn
  };
}

function shouldMutateTag(args) {
  const flags = args.slice(1);
  if (flags.length === 0) {
    return false;
  }
  if (flags.some((flag) => flag === '-d' || flag === '--delete')) {
    return true;
  }
  if (flags.some((flag) => TAG_READONLY_FLAGS.has(flag) || flag.startsWith('--sort='))) {
    return false;
  }
  return true;
}

export function isMutatingGitCommand(args = []) {
  if (!Array.isArray(args) || args.length === 0) {
    return false;
  }
  const command = String(args[0] ?? '').toLowerCase();
  if (!MUTATING_GIT_COMMANDS.has(command)) {
    return false;
  }

  if (command === 'branch') {
    return args.slice(1).some((value) => BRANCH_MUTATING_FLAGS.has(value) || value.startsWith('--set-upstream-to='));
  }

  if (command === 'tag') {
    return shouldMutateTag(args);
  }

  return true;
}

export function runGitWithSafety(args, spawnOptions = {}, brokerOptions = {}) {
  if (!Array.isArray(args) || args.length === 0) {
    throw new Error('runGitWithSafety requires at least one git argument.');
  }

  const command = String(args[0] ?? '').toLowerCase();
  const mutate = isMutatingGitCommand(args);
  const normalizedSpawn = toSpawnOptions(spawnOptions);
  const deps = buildDeps(brokerOptions);

  if (!mutate) {
    return deps.spawnSyncFn('git', args, normalizedSpawn);
  }

  const cwd = normalizedSpawn.cwd ?? process.cwd();
  const maxRetries = parseNumberEnv(
    brokerOptions.maxRetries ?? normalizedSpawn.env?.SAFE_GIT_MAX_RETRIES,
    DEFAULT_MAX_RETRIES
  );
  const retryDelayMs = parseNumberEnv(
    brokerOptions.retryDelayMs ?? normalizedSpawn.env?.SAFE_GIT_RETRY_DELAY_MS,
    DEFAULT_RETRY_DELAY_MS
  );
  const staleLockAgeMs = parseNumberEnv(
    brokerOptions.staleLockAgeMs ?? normalizedSpawn.env?.SAFE_GIT_STALE_LOCK_AGE_MS,
    DEFAULT_STALE_LOCK_AGE_MS
  );
  const allowProcessKill = parseBooleanEnv(
    brokerOptions.allowProcessKill ?? normalizedSpawn.env?.SAFE_GIT_ALLOW_PROCESS_KILL,
    true
  );
  const gitDir = resolveGitDir(cwd, normalizedSpawn, deps);
  const maxAttempts = Math.max(1, maxRetries + 1);
  let lastResult = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const nowMs = deps.nowFn();
    const locks = collectLockFiles(gitDir, deps, nowMs);
    const inProgressStates = collectInProgressStates(gitDir, deps);
    const blockedStates = evaluateBlockedStates(command, args, inProgressStates);

    if (blockedStates.length > 0) {
      throw buildStateError(args, blockedStates);
    }

    if (locks.length > 0) {
      const repair = repairLocks({
        commandArgs: args,
        gitDir,
        locks,
        staleLockAgeMs,
        allowProcessKill,
        deps,
        nowMs,
        logFn: deps.logFn
      });

      if (repair.killedPids.length > 0) {
        deps.logFn(
          `[safe-git] terminated git process(es) ${repair.killedPids.join(', ')} while repairing lock(s) for git ${args.join(' ')}`
        );
      }

      if (repair.blocked.length > 0) {
        if (attempt >= maxAttempts) {
          throw buildLockError(args, repair.blocked, attempt, gitDir);
        }
        sleepSync(retryDelayMs);
        continue;
      }
    }

    const result = deps.spawnSyncFn('git', args, normalizedSpawn);
    lastResult = result;

    if (result.status === 0) {
      return result;
    }

    if (looksLikeInProgressFailure(result)) {
      const refreshed = evaluateBlockedStates(command, args, collectInProgressStates(gitDir, deps));
      if (refreshed.length > 0) {
        throw buildStateError(args, refreshed);
      }
      throw new Error(
        `[safe-git] git ${args.join(' ')} failed due to an in-progress operation state. Resolve the state and retry.`
      );
    }

    if (looksLikeLockConflict(result) && attempt < maxAttempts) {
      sleepSync(retryDelayMs);
      continue;
    }

    return result;
  }

  if (lastResult) {
    return lastResult;
  }

  throw new Error(`[safe-git] git ${args.join(' ')} failed before execution.`);
}

export const __test = {
  parseNumberEnv,
  parseBooleanEnv,
  collectLockFiles,
  collectInProgressStates,
  evaluateBlockedStates,
  looksLikeLockConflict,
  looksLikeInProgressFailure,
  repairLocks,
  resolveGitDir
};


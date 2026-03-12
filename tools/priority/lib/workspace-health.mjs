#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { accessSync, constants, existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { defaultLeaseRoot, defaultOwner } from '../agent-writer-lease.mjs';

const DEFAULT_LOCK_STALE_SECONDS = 30;
const LOCK_FILENAMES = ['index.lock', 'HEAD.lock', 'packed-refs.lock', 'shallow.lock'];

const IN_PROGRESS_MARKERS = [
  { key: 'merge', marker: 'MERGE_HEAD', description: 'merge in progress' },
  { key: 'cherry-pick', marker: 'CHERRY_PICK_HEAD', description: 'cherry-pick in progress' },
  { key: 'revert', marker: 'REVERT_HEAD', description: 'revert in progress' },
  { key: 'rebase', marker: 'rebase-apply', description: 'rebase in progress' },
  { key: 'rebase', marker: 'rebase-merge', description: 'rebase in progress' }
];

const HINTS = {
  'git-dir-unresolved':
    'Run from a valid git worktree and verify `.git` is accessible before running automation.',
  'index-missing':
    'Ensure the repository worktree is initialized and `.git/index` exists.',
  'index-not-writable':
    'Ensure the workspace is writable and `.git/index` is not read-only or locked by another process.',
  'git-operation-in-progress':
    'Resolve in-progress git operations (`git status`, then `--continue` or `--abort`) before retrying.',
  'active-lock-file':
    'Another git operation may still be running. Wait for it to finish or clear the conflicting lock safely.',
  'stale-lock-file':
    'Remove stale lock files after confirming no git process is active, then re-run the workflow.',
  'lease-missing':
    'Acquire the writer lease (`tools/priority/bootstrap.ps1`) before running mutating automation.',
  'lease-read-error':
    'Repair or remove the corrupted lease file under the resolved writer-lease root (typically the git common dir `agent-writer-leases/` directory) and re-run bootstrap.',
  'lease-owner-mismatch':
    'Only the active lease owner may proceed. Reacquire lease or hand off ownership first.',
  'lease-id-mismatch':
    'Lease id changed; rerun bootstrap to refresh `AGENT_WRITER_LEASE_ID` for this session.'
};

function normalizeLeaseMode(raw) {
  const value = String(raw ?? 'optional').trim().toLowerCase();
  if (value === 'ignore' || value === 'optional' || value === 'required') {
    return value;
  }
  throw new Error(`Unsupported lease mode: ${raw}`);
}

function createDeps(overrides = {}) {
  return {
    spawnSyncFn: overrides.spawnSyncFn ?? spawnSync,
    accessSyncFn: overrides.accessSyncFn ?? accessSync,
    existsSyncFn: overrides.existsSyncFn ?? existsSync,
    readdirSyncFn: overrides.readdirSyncFn ?? readdirSync,
    readFileSyncFn: overrides.readFileSyncFn ?? readFileSync,
    statSyncFn: overrides.statSyncFn ?? statSync,
    nowFn: overrides.nowFn ?? (() => Date.now())
  };
}

function resolveGitDir(repoRoot, deps, explicitGitDir = '') {
  if (explicitGitDir) {
    return path.isAbsolute(explicitGitDir)
      ? path.normalize(explicitGitDir)
      : path.normalize(path.resolve(repoRoot, explicitGitDir));
  }

  const probe = deps.spawnSyncFn('git', ['rev-parse', '--git-dir'], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (probe.status !== 0) {
    const stderr = String(probe.stderr ?? '').trim();
    throw new Error(stderr || 'git rev-parse --git-dir failed');
  }

  const raw = String(probe.stdout ?? '').trim();
  if (!raw) {
    throw new Error('git rev-parse returned empty git-dir');
  }

  return path.isAbsolute(raw) ? path.normalize(raw) : path.normalize(path.resolve(repoRoot, raw));
}

function safeMtimeMs(filePath, deps, nowMs) {
  try {
    const stat = deps.statSyncFn(filePath);
    return Number.isFinite(stat?.mtimeMs) ? Number(stat.mtimeMs) : nowMs;
  } catch {
    return nowMs;
  }
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

function collectLockFiles(gitDir, deps, nowMs) {
  const candidates = [];
  for (const lockName of LOCK_FILENAMES) {
    const lockPath = path.join(gitDir, lockName);
    if (deps.existsSyncFn(lockPath)) {
      candidates.push(lockPath);
    }
  }

  listRefLockFiles(path.join(gitDir, 'refs'), deps, candidates);

  const dedupe = new Set();
  const locks = [];
  for (const candidate of candidates) {
    const normalized = path.normalize(candidate);
    if (dedupe.has(normalized)) {
      continue;
    }
    dedupe.add(normalized);
    locks.push({
      path: normalized,
      mtimeMs: safeMtimeMs(normalized, deps, nowMs)
    });
  }

  return locks.sort((left, right) => left.path.localeCompare(right.path));
}

function collectInProgressStates(gitDir, deps) {
  const states = [];
  const seen = new Set();

  for (const marker of IN_PROGRESS_MARKERS) {
    const markerPath = path.join(gitDir, marker.marker);
    if (!deps.existsSyncFn(markerPath)) {
      continue;
    }
    if (seen.has(marker.key)) {
      continue;
    }
    seen.add(marker.key);
    states.push({
      key: marker.key,
      description: marker.description,
      markerPath
    });
  }

  return states;
}

function pushCheck(checks, id, status, detail = {}) {
  checks.push({ id, status, ...detail });
}

function pushFailure(failures, id, detail = {}) {
  failures.push({ id, ...detail });
}

function maybeReadLease(leasePath, deps) {
  if (!deps.existsSyncFn(leasePath)) {
    return { status: 'missing', lease: null };
  }

  try {
    const raw = String(deps.readFileSyncFn(leasePath, 'utf8') ?? '');
    const lease = JSON.parse(raw);
    return { status: 'present', lease };
  } catch (error) {
    return { status: 'error', error: error?.message || String(error), lease: null };
  }
}

export function evaluateWorkspaceHealth(options = {}, depOverrides = {}) {
  const deps = createDeps(depOverrides);
  const nowMs = deps.nowFn();
  const lockStaleSeconds = Number.isFinite(options.lockStaleSeconds)
    ? Math.max(0, Number(options.lockStaleSeconds))
    : DEFAULT_LOCK_STALE_SECONDS;
  const staleThresholdMs = lockStaleSeconds * 1000;

  const repoRoot = path.resolve(options.repoRoot ?? process.cwd());
  const leaseMode = normalizeLeaseMode(options.leaseMode);
  const expectedLeaseOwner = options.expectedLeaseOwner ?? defaultOwner();
  const expectedLeaseId = options.expectedLeaseId ?? process.env.AGENT_WRITER_LEASE_ID ?? '';
  const leaseScope = options.leaseScope ?? 'workspace';

  const checks = [];
  const failures = [];
  let gitDir = '';

  try {
    gitDir = resolveGitDir(repoRoot, deps, options.gitDir ?? '');
  } catch (error) {
    pushCheck(checks, 'git-dir', 'fail', { message: String(error?.message || error) });
    pushFailure(failures, 'git-dir-unresolved', { message: String(error?.message || error) });
    return buildReport({
      repoRoot,
      gitDir: null,
      leaseMode,
      lockStaleSeconds,
      checks,
      failures,
      checkedAt: new Date(nowMs).toISOString()
    });
  }

  const indexPath = path.join(gitDir, 'index');
  if (!deps.existsSyncFn(indexPath)) {
    pushCheck(checks, 'git-index-writable', 'fail', { path: indexPath, reason: 'missing' });
    pushFailure(failures, 'index-missing', { path: indexPath });
  } else {
    try {
      deps.accessSyncFn(indexPath, constants.W_OK);
      pushCheck(checks, 'git-index-writable', 'pass', { path: indexPath });
    } catch (error) {
      pushCheck(checks, 'git-index-writable', 'fail', {
        path: indexPath,
        reason: 'not-writable',
        message: String(error?.message || error)
      });
      pushFailure(failures, 'index-not-writable', {
        path: indexPath,
        message: String(error?.message || error)
      });
    }
  }

  const inProgress = collectInProgressStates(gitDir, deps);
  if (inProgress.length > 0) {
    pushCheck(checks, 'git-in-progress', 'fail', { states: inProgress });
    pushFailure(failures, 'git-operation-in-progress', { states: inProgress });
  } else {
    pushCheck(checks, 'git-in-progress', 'pass', { states: [] });
  }

  const locks = collectLockFiles(gitDir, deps, nowMs);
  const staleLocks = [];
  const activeLocks = [];
  for (const lock of locks) {
    const ageMs = Math.max(0, Math.trunc(nowMs - lock.mtimeMs));
    const payload = { ...lock, ageMs };
    if (ageMs >= staleThresholdMs) {
      staleLocks.push(payload);
    } else {
      activeLocks.push(payload);
    }
  }

  if (staleLocks.length > 0) {
    pushFailure(failures, 'stale-lock-file', { locks: staleLocks });
  }
  if (activeLocks.length > 0) {
    pushFailure(failures, 'active-lock-file', { locks: activeLocks });
  }
  if (staleLocks.length > 0 || activeLocks.length > 0) {
    pushCheck(checks, 'git-lock-files', 'fail', {
      lockCount: locks.length,
      staleLocks,
      activeLocks
    });
  } else {
    pushCheck(checks, 'git-lock-files', 'pass', { lockCount: 0 });
  }

  const leaseRoot = options.leaseRoot
    ? path.resolve(repoRoot, options.leaseRoot)
    : defaultLeaseRoot({
        repoRoot,
        env: process.env,
        spawnSyncFn: deps.spawnSyncFn
      });
  const leasePath = path.join(leaseRoot, `${leaseScope}.json`);
  if (leaseMode === 'ignore') {
    pushCheck(checks, 'writer-lease', 'skipped', { mode: leaseMode, path: leasePath });
  } else {
    const leaseRead = maybeReadLease(leasePath, deps);
    if (leaseRead.status === 'missing') {
      if (leaseMode === 'required') {
        pushCheck(checks, 'writer-lease', 'fail', {
          mode: leaseMode,
          path: leasePath,
          reason: 'missing'
        });
        pushFailure(failures, 'lease-missing', { path: leasePath });
      } else {
        pushCheck(checks, 'writer-lease', 'pass', {
          mode: leaseMode,
          path: leasePath,
          reason: 'missing-allowed'
        });
      }
    } else if (leaseRead.status === 'error') {
      pushCheck(checks, 'writer-lease', 'fail', {
        mode: leaseMode,
        path: leasePath,
        reason: 'read-error',
        message: leaseRead.error
      });
      pushFailure(failures, 'lease-read-error', { path: leasePath, message: leaseRead.error });
    } else {
      const lease = leaseRead.lease ?? {};
      const owner = String(lease.owner ?? '');
      const leaseId = String(lease.leaseId ?? '');
      const ownerMismatch =
        expectedLeaseOwner &&
        owner &&
        owner.trim().toLowerCase() !== String(expectedLeaseOwner).trim().toLowerCase();

      if (ownerMismatch) {
        pushFailure(failures, 'lease-owner-mismatch', {
          expectedOwner: expectedLeaseOwner,
          actualOwner: owner,
          path: leasePath
        });
      }
      if (expectedLeaseId && leaseId && leaseId !== expectedLeaseId) {
        pushFailure(failures, 'lease-id-mismatch', {
          expectedLeaseId,
          actualLeaseId: leaseId,
          path: leasePath
        });
      }

      const leaseFailures = failures.filter((entry) => entry.id.startsWith('lease-'));
      if (leaseFailures.length > 0) {
        pushCheck(checks, 'writer-lease', 'fail', {
          mode: leaseMode,
          path: leasePath,
          owner,
          leaseId
        });
      } else {
        pushCheck(checks, 'writer-lease', 'pass', {
          mode: leaseMode,
          path: leasePath,
          owner,
          leaseId
        });
      }
    }
  }

  return buildReport({
    repoRoot,
    gitDir,
    leaseMode,
    lockStaleSeconds,
    checks,
    failures,
    checkedAt: new Date(nowMs).toISOString()
  });
}

function buildReport({ repoRoot, gitDir, leaseMode, lockStaleSeconds, checks, failures, checkedAt }) {
  const hints = [];
  const seen = new Set();
  for (const failure of failures) {
    const hint = HINTS[failure.id];
    if (!hint || seen.has(hint)) {
      continue;
    }
    seen.add(hint);
    hints.push(hint);
  }

  return {
    schema: 'priority/workspace-health@v1',
    checkedAt,
    repoRoot,
    gitDir,
    leaseMode,
    lockStaleSeconds,
    status: failures.length === 0 ? 'pass' : 'fail',
    checks,
    failures,
    hints
  };
}

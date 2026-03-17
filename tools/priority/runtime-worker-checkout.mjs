#!/usr/bin/env node

import { access, mkdir, readFile, readdir, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const DEFAULT_WORKER_REF = 'upstream/develop';
const BOOTSTRAP_RELATIVE_PATH = path.join('tools', 'priority', 'bootstrap.ps1');
const ATTACHABLE_REMOTES = ['upstream', 'origin', 'personal'];
const GITHUB_PUSH_REMOTES = ['origin', 'personal'];

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function sanitizeSegment(value) {
  const segment =
    String(value ?? '')
      .trim()
      .replace(/[^A-Za-z0-9._-]+/g, '-')
      .replace(/^-+|-+$/g, '');
  if (!segment || segment === '.' || segment === '..') {
    return 'runtime';
  }
  return segment;
}

async function pathExists(filePath) {
  try {
    await access(filePath);
    return true;
  } catch (error) {
    if (error?.code === 'ENOENT') return false;
    throw error;
  }
}

function formatGitPointerPath(targetPath) {
  return path.resolve(targetPath).replace(/\\/g, '/');
}

function formatRelativeGitPointer(fromDir, toPath) {
  const relativePath = path.relative(fromDir, toPath).replace(/\\/g, '/');
  return relativePath || '.';
}

function isPathWithin(parentPath, childPath) {
  const relativePath = path.relative(parentPath, childPath);
  return Boolean(relativePath) && !relativePath.startsWith('..') && !path.isAbsolute(relativePath);
}

function isWindowsAbsolutePath(value) {
  return /^[A-Za-z]:[\\/]/.test(value) || /^\\\\/.test(value);
}

function isUnixAbsolutePath(value) {
  return value.startsWith('/');
}

function tryTranslateMountedWindowsPath(value) {
  const match = normalizeText(value).match(/^\/mnt\/([a-zA-Z])\/(.*)$/);
  if (!match) {
    return '';
  }
  return `${match[1].toUpperCase()}:\\${match[2].replace(/\//g, '\\')}`;
}

function extractRuntimeWorktreeHint(pointerPath) {
  const match = normalizeText(pointerPath).replace(/\\/g, '/').match(/\/\.runtime-worktrees\/([^/]+)\/([^/]+)\/\.git$/);
  if (!match) {
    return null;
  }
  return {
    repoKey: sanitizeSegment(match[1]),
    laneSegment: sanitizeSegment(match[2])
  };
}

async function tryResolveCheckoutGitFromAdminPointer({ repoRoot, worktreeAdminDir, laneSegment }) {
  const adminGitdirFile = path.join(worktreeAdminDir, 'gitdir');
  if (!(await pathExists(adminGitdirFile))) {
    return '';
  }

  const rawPointer = normalizeText(await readFile(adminGitdirFile, 'utf8'));
  const candidates = [];
  if (rawPointer) {
    if (isWindowsAbsolutePath(rawPointer)) {
      candidates.push(rawPointer);
    } else if (isUnixAbsolutePath(rawPointer)) {
      const translatedMountedPath = tryTranslateMountedWindowsPath(rawPointer);
      if (translatedMountedPath) {
        candidates.push(translatedMountedPath);
      }
      candidates.push(rawPointer);
    } else {
      candidates.push(path.resolve(worktreeAdminDir, rawPointer));
    }

    const runtimeHint = extractRuntimeWorktreeHint(rawPointer);
    if (runtimeHint?.laneSegment === laneSegment) {
      candidates.push(path.join(repoRoot, '.runtime-worktrees', runtimeHint.repoKey, laneSegment, '.git'));
    }
  }

  const runtimeRoot = path.join(repoRoot, '.runtime-worktrees');
  if (await pathExists(runtimeRoot)) {
    const repoRoots = await readdir(runtimeRoot, { withFileTypes: true });
    for (const entry of repoRoots) {
      if (!entry.isDirectory()) {
        continue;
      }
      candidates.push(path.join(runtimeRoot, entry.name, laneSegment, '.git'));
    }
  }

  candidates.push(path.join(path.dirname(repoRoot), laneSegment, '.git'));

  const seen = new Set();
  for (const candidate of candidates) {
    const normalizedCandidate = normalizeText(candidate);
    if (!normalizedCandidate) {
      continue;
    }
    const key = normalizedCandidate.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    if (await pathExists(normalizedCandidate)) {
      return normalizedCandidate;
    }
  }

  return '';
}

async function clearStaleInitializingLock(worktreeAdminDir) {
  const lockPath = path.join(worktreeAdminDir, 'locked');
  if (!(await pathExists(lockPath))) {
    return false;
  }

  const lockReason = normalizeText(await readFile(lockPath, 'utf8'));
  if (lockReason !== 'initializing') {
    return false;
  }

  await unlink(lockPath);
  return true;
}

async function repairExistingWorktreeGitPointers({ repoRoot, checkoutPath, laneSegment }) {
  const resolvedLaneSegment = sanitizeSegment(laneSegment || path.basename(checkoutPath));
  const worktreeAdminDir = path.join(repoRoot, '.git', 'worktrees', resolvedLaneSegment);
  const checkoutGitFile = path.join(checkoutPath, '.git');
  const adminGitdirFile = path.join(worktreeAdminDir, 'gitdir');

  if (!(await pathExists(checkoutGitFile)) || !(await pathExists(worktreeAdminDir)) || !(await pathExists(adminGitdirFile))) {
    return {
      repaired: false,
      worktreeAdminDir,
      checkoutGitFile,
      adminGitdirFile
    };
  }

  const expectedCheckoutPointer = `gitdir: ${formatRelativeGitPointer(checkoutPath, worktreeAdminDir)}\n`;
  const expectedAdminPointer = `${formatRelativeGitPointer(worktreeAdminDir, checkoutGitFile)}\n`;
  let repaired = false;

  const currentCheckoutPointer = await readFile(checkoutGitFile, 'utf8');
  if (currentCheckoutPointer !== expectedCheckoutPointer) {
    await writeFile(checkoutGitFile, expectedCheckoutPointer, 'utf8');
    repaired = true;
  }

  const currentAdminPointer = await readFile(adminGitdirFile, 'utf8');
  if (currentAdminPointer !== expectedAdminPointer) {
    await writeFile(adminGitdirFile, expectedAdminPointer, 'utf8');
    repaired = true;
  }

  return {
    repaired,
    laneSegment: resolvedLaneSegment,
    worktreeAdminDir,
    checkoutGitFile,
    adminGitdirFile
  };
}

export async function repairRegisteredWorktreeGitPointers({ repoRoot, deps = {} }) {
  const execFileFn = deps.execFileFn ?? execFileAsync;
  const worktreesRoot = path.join(repoRoot, '.git', 'worktrees');
  const runtimeRoot = path.join(repoRoot, '.runtime-worktrees');
  const report = {
    repaired: [],
    skipped: [],
    unlocked: [],
    unresolved: [],
    prune: {
      attempted: false,
      exitCode: 0,
      output: ''
    }
  };

  if (!(await pathExists(worktreesRoot))) {
    return report;
  }

  const entries = await readdir(worktreesRoot, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }

    const laneSegment = sanitizeSegment(entry.name);
    const worktreeAdminDir = path.join(worktreesRoot, entry.name);
    const checkoutGitFile = await tryResolveCheckoutGitFromAdminPointer({
      repoRoot,
      worktreeAdminDir,
      laneSegment
    });

    if (!checkoutGitFile) {
      report.unresolved.push({
        laneSegment,
        worktreeAdminDir,
        reason: 'checkout-git-not-found'
      });
      continue;
    }

    const checkoutPath = path.dirname(checkoutGitFile);
    if (!(await pathExists(runtimeRoot)) || !isPathWithin(runtimeRoot, checkoutPath)) {
      report.skipped.push({
        laneSegment,
        checkoutPath,
        reason: 'non-runtime-worktree'
      });
      continue;
    }

    try {
      const repair = await repairExistingWorktreeGitPointers({
        repoRoot,
        checkoutPath,
        laneSegment
      });
      report.repaired.push({
        laneSegment,
        checkoutPath,
        repaired: repair.repaired
      });

      if (await clearStaleInitializingLock(worktreeAdminDir)) {
        report.unlocked.push({
          laneSegment,
          worktreeAdminDir,
          reason: 'removed-stale-initializing-lock'
        });
      }
    } catch (error) {
      report.unresolved.push({
        laneSegment,
        worktreeAdminDir,
        reason: formatExecError(error)
      });
    }
  }

  report.prune.attempted = true;
  try {
    const result = await execFileFn('git', ['worktree', 'prune', '--verbose', '--expire', 'now'], { cwd: repoRoot });
    report.prune.output = `${normalizeText(result?.stdout)}\n${normalizeText(result?.stderr)}`.trim();
  } catch (error) {
    report.prune.exitCode = Number.isInteger(error?.code) ? error.code : 1;
    report.prune.output = formatExecError(error);
  }

  return report;
}

function formatBootstrapFailure(error) {
  const message = normalizeText(error?.message || error);
  const stderr = normalizeText(error?.stderr);
  if (!stderr) {
    return message;
  }
  return `${message}\n\nstderr:\n${stderr}`;
}

function formatExecError(error) {
  return normalizeText(error?.stderr) || normalizeText(error?.message) || String(error);
}

async function repairReusedWorktreeState(execFileFn, checkoutPath, laneId) {
  const statusResult = await execFileFn(
    'git',
    ['status', '--porcelain', '--untracked-files=all'],
    { cwd: checkoutPath }
  );
  const dirtyEntries = normalizeText(statusResult?.stdout)
    .split(/\r?\n/)
    .map((entry) => normalizeText(entry))
    .filter(Boolean);
  if (dirtyEntries.length === 0) {
    return {
      repaired: false,
      dirtyEntries: []
    };
  }

  const stashMessage = `priority-runtime-worktree-repair:${sanitizeSegment(laneId)}:${new Date().toISOString()}`;
  await execFileFn(
    'git',
    ['stash', 'push', '--include-untracked', '--message', stashMessage],
    { cwd: checkoutPath }
  );

  const postStatusResult = await execFileFn(
    'git',
    ['status', '--porcelain', '--untracked-files=all'],
    { cwd: checkoutPath }
  );
  const remainingEntries = normalizeText(postStatusResult?.stdout)
    .split(/\r?\n/)
    .map((entry) => normalizeText(entry))
    .filter(Boolean);
  if (remainingEntries.length > 0) {
    throw new Error(`reused worker checkout remained dirty after stash repair: ${remainingEntries.join('; ')}`);
  }

  return {
    repaired: true,
    dirtyEntries,
    stashMessage
  };
}

function resolveGitHubSshPushUrl(remoteUrl) {
  const normalized = normalizeText(remoteUrl);
  if (!normalized) {
    return '';
  }
  if (/^git@github\.com:/i.test(normalized)) {
    return normalized.endsWith('.git') ? normalized : `${normalized}.git`;
  }
  const httpsMatch = normalized.match(/^https:\/\/github\.com\/([^/]+)\/([^/]+?)(?:\.git)?\/?$/i);
  if (httpsMatch) {
    return `git@github.com:${httpsMatch[1]}/${httpsMatch[2]}.git`;
  }
  const sshMatch = normalized.match(/^ssh:\/\/git@github\.com\/([^/]+)\/([^/]+?)(?:\.git)?\/?$/i);
  if (sshMatch) {
    return `git@github.com:${sshMatch[1]}/${sshMatch[2]}.git`;
  }
  return '';
}

async function readGitStdout(execFileFn, args, options = {}) {
  const result = await execFileFn('git', args, options);
  return normalizeText(result?.stdout);
}

async function resolveWriterLeaseRoot(execFileFn, checkoutPath) {
  try {
    const gitDir = await readGitStdout(execFileFn, ['rev-parse', '--git-dir'], { cwd: checkoutPath });
    if (!gitDir) {
      return '';
    }
    const resolvedGitDir = path.isAbsolute(gitDir) ? gitDir : path.resolve(checkoutPath, gitDir);
    return path.join(resolvedGitDir, 'agent-writer-leases');
  } catch {
    return '';
  }
}

async function resolveExistingLeaseOwner(leaseRoot) {
  if (!leaseRoot) {
    return '';
  }
  const leasePath = path.join(leaseRoot, 'workspace.json');
  try {
    const payload = JSON.parse(await readFile(leasePath, 'utf8'));
    return normalizeText(payload?.owner);
  } catch {
    return '';
  }
}

async function tryReadGitStdout(execFileFn, args, options = {}) {
  try {
    return await readGitStdout(execFileFn, args, options);
  } catch {
    return '';
  }
}

async function gitRefExists(execFileFn, cwd, ref) {
  try {
    await execFileFn('git', ['show-ref', '--verify', '--quiet', ref], { cwd });
    return true;
  } catch {
    return false;
  }
}

async function normalizeGitHubRemotePushUrls(execFileFn, checkoutPath, { platform = process.platform } = {}) {
  if (normalizeText(platform).toLowerCase() !== 'linux') {
    return [];
  }

  const availableRemotes = (await tryReadGitStdout(execFileFn, ['remote'], { cwd: checkoutPath }))
    .split(/\r?\n/)
    .map((entry) => normalizeText(entry))
    .filter(Boolean);
  const updatedRemotes = [];

  for (const remote of GITHUB_PUSH_REMOTES) {
    if (!availableRemotes.includes(remote)) {
      continue;
    }
    const fetchUrl = await tryReadGitStdout(execFileFn, ['remote', 'get-url', remote], { cwd: checkoutPath });
    const desiredPushUrl = resolveGitHubSshPushUrl(fetchUrl);
    if (!desiredPushUrl) {
      continue;
    }
    const currentPushUrl = await tryReadGitStdout(execFileFn, ['remote', 'get-url', '--push', remote], {
      cwd: checkoutPath
    });
    if (currentPushUrl === desiredPushUrl) {
      continue;
    }
    await execFileFn('git', ['remote', 'set-url', '--push', remote, desiredPushUrl], { cwd: checkoutPath });
    updatedRemotes.push(remote);
  }

  return updatedRemotes;
}

export function resolveCompareviWorkerCheckoutRoot({ repoRoot, repository }) {
  const rawRepoKey = normalizeText(repository)?.replace(/\//g, '--') || path.basename(repoRoot);
  const repoKey = sanitizeSegment(rawRepoKey);
  return path.join(repoRoot, '.runtime-worktrees', repoKey);
}

export function resolveCompareviWorkerCheckoutPath({ repoRoot, repository, laneId }) {
  const checkoutRoot = resolveCompareviWorkerCheckoutRoot({ repoRoot, repository });
  return {
    checkoutRoot,
    checkoutPath: path.join(checkoutRoot, sanitizeSegment(laneId))
  };
}

export async function prepareCompareviWorkerCheckout({
  repoRoot,
  repository,
  schedulerDecision,
  platform,
  deps = {}
}) {
  const activeLane = schedulerDecision?.activeLane ?? null;
  if (!activeLane?.laneId) {
    return null;
  }

  const { checkoutRoot, checkoutPath } = resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository,
    laneId: activeLane.laneId
  });
  const execFileFn = deps.execFileFn ?? execFileAsync;
  const gitMarkerPath = path.join(checkoutPath, '.git');
  if (await pathExists(gitMarkerPath)) {
    const fetchedRemotes = [];
    try {
      await repairExistingWorktreeGitPointers({
        repoRoot,
        checkoutPath,
        laneSegment: activeLane.laneId
      });
      const worktreeStateRepair = await repairReusedWorktreeState(execFileFn, checkoutPath, activeLane.laneId);
      const availableRemotes = (await tryReadGitStdout(execFileFn, ['remote'], { cwd: checkoutPath }))
        .split(/\r?\n/)
        .map((entry) => normalizeText(entry))
        .filter(Boolean);
      if (availableRemotes.includes('upstream')) {
        await execFileFn('git', ['fetch', 'upstream', '--prune'], { cwd: checkoutPath });
        fetchedRemotes.push('upstream');
      } else if (availableRemotes.includes('origin')) {
        await execFileFn('git', ['fetch', 'origin', '--prune'], { cwd: checkoutPath });
        fetchedRemotes.push('origin');
      }
      let resolvedRef = DEFAULT_WORKER_REF;
      try {
        await execFileFn('git', ['checkout', '--force', '--detach', DEFAULT_WORKER_REF], { cwd: checkoutPath });
      } catch {
        resolvedRef = 'develop';
        await execFileFn('git', ['checkout', '--force', '--detach', resolvedRef], { cwd: checkoutPath });
      }
      const pushRemotesNormalized = await normalizeGitHubRemotePushUrls(execFileFn, checkoutPath, {
        platform: deps.platform ?? platform ?? process.platform
      });
      return {
        laneId: activeLane.laneId,
        checkoutRoot,
        checkoutPath,
        status: 'reused',
        ref: resolvedRef,
        requestedBranch: normalizeText(schedulerDecision?.stepOptions?.branch) || null,
        source: 'comparevi-worktree',
        fetchedRemotes,
        pushRemotesNormalized,
        worktreeStateRepair
      };
    } catch (error) {
      return {
        laneId: activeLane.laneId,
        checkoutRoot,
        checkoutPath,
        status: 'blocked',
        ref: DEFAULT_WORKER_REF,
        requestedBranch: normalizeText(schedulerDecision?.stepOptions?.branch) || null,
        reason: `failed to refresh existing worker checkout: ${formatExecError(error)}`,
        source: 'comparevi-worktree',
        fetchedRemotes
      };
    }

  }

  if (await pathExists(checkoutPath)) {
    return {
      laneId: activeLane.laneId,
      checkoutRoot,
      checkoutPath,
      status: 'blocked',
      ref: DEFAULT_WORKER_REF,
      requestedBranch: normalizeText(schedulerDecision?.stepOptions?.branch) || null,
      reason: 'worker checkout path exists but is not a git worktree',
      source: 'comparevi-worktree'
    };
  }

  await mkdir(checkoutRoot, { recursive: true });
  await execFileFn('git', ['worktree', 'add', '--detach', checkoutPath, DEFAULT_WORKER_REF], {
    cwd: repoRoot
  });
  await repairExistingWorktreeGitPointers({
    repoRoot,
    checkoutPath,
    laneSegment: activeLane.laneId
  });
  const pushRemotesNormalized = await normalizeGitHubRemotePushUrls(execFileFn, checkoutPath, {
    platform: deps.platform ?? platform ?? process.platform
  });
  return {
    laneId: activeLane.laneId,
    checkoutRoot,
    checkoutPath,
    status: 'created',
    ref: DEFAULT_WORKER_REF,
    requestedBranch: normalizeText(schedulerDecision?.stepOptions?.branch) || null,
    source: 'comparevi-worktree',
    pushRemotesNormalized
  };
}

export async function bootstrapCompareviWorkerCheckout({
  schedulerDecision,
  preparedWorker,
  deps = {}
}) {
  if (!preparedWorker?.checkoutPath || !schedulerDecision?.activeLane?.laneId) {
    return null;
  }

  const execFileFn = deps.execFileFn ?? execFileAsync;
  const leaseRoot = await resolveWriterLeaseRoot(execFileFn, preparedWorker.checkoutPath);
  const bootstrapEnv = { ...process.env };
  if (leaseRoot) {
    bootstrapEnv.AGENT_WRITER_LEASE_ROOT = leaseRoot;
    if (!normalizeText(bootstrapEnv.AGENT_WRITER_LEASE_OWNER)) {
      const existingOwner = await resolveExistingLeaseOwner(leaseRoot);
      if (existingOwner) {
        bootstrapEnv.AGENT_WRITER_LEASE_OWNER = existingOwner;
      }
    }
    if (!normalizeText(bootstrapEnv.AGENT_WRITER_LEASE_FORCE_TAKEOVER)) {
      bootstrapEnv.AGENT_WRITER_LEASE_FORCE_TAKEOVER = '1';
    }
    if (!normalizeText(bootstrapEnv.AGENT_WRITER_LEASE_STALE_SECONDS)) {
      // Worker checkout leases are lane-scoped and ephemeral; allow immediate
      // takeover so container restarts do not block bootstrap on stale owner ids.
      bootstrapEnv.AGENT_WRITER_LEASE_STALE_SECONDS = '0';
    }
  }
  const branch = normalizeText(schedulerDecision?.stepOptions?.branch) || normalizeText(schedulerDecision?.activeLane?.branch);
  if (branch) {
    const forkRemote = normalizeText(schedulerDecision?.activeLane?.forkRemote) || 'upstream';
    try {
      const availableRemotes = (await tryReadGitStdout(execFileFn, ['remote'], { cwd: preparedWorker.checkoutPath }))
        .split(/\r?\n/)
        .map((entry) => normalizeText(entry))
        .filter(Boolean);
      for (const remote of ATTACHABLE_REMOTES) {
        if (!availableRemotes.includes(remote)) {
          continue;
        }
        await execFileFn('git', ['fetch', remote, '--prune'], { cwd: preparedWorker.checkoutPath });
      }

      const currentBranch = await tryReadGitStdout(execFileFn, ['branch', '--show-current'], {
        cwd: preparedWorker.checkoutPath
      });
      if (currentBranch !== branch) {
        const trackingRef = `${forkRemote}/${branch}`;
        const trackingExists = await gitRefExists(execFileFn, preparedWorker.checkoutPath, `refs/remotes/${trackingRef}`);
        const checkoutTarget = trackingExists ? trackingRef : DEFAULT_WORKER_REF;
        await execFileFn('git', ['checkout', '--force', '-B', branch, checkoutTarget], {
          cwd: preparedWorker.checkoutPath
        });
        if (trackingExists) {
          await execFileFn('git', ['branch', '--set-upstream-to', trackingRef, branch], {
            cwd: preparedWorker.checkoutPath
          });
        }
      }
    } catch (error) {
      return {
        laneId: schedulerDecision.activeLane.laneId,
        checkoutPath: preparedWorker.checkoutPath,
        status: 'blocked',
        source: 'comparevi-bootstrap',
        reason: `failed to activate branch before bootstrap: ${formatExecError(error)}`,
        bootstrapCommand: [],
        bootstrapExitCode: Number.isInteger(error?.code) ? error.code : 1,
        preparedAt: preparedWorker.generatedAt ?? null
      };
    }
  }

  const bootstrapPath = path.join(preparedWorker.checkoutPath, BOOTSTRAP_RELATIVE_PATH);
  const bootstrapCommand = ['pwsh', '-NoLogo', '-NoProfile', '-File', bootstrapPath];

  try {
    await execFileFn(bootstrapCommand[0], bootstrapCommand.slice(1), {
      cwd: preparedWorker.checkoutPath,
      env: bootstrapEnv
    });
  } catch (error) {
    return {
      laneId: schedulerDecision.activeLane.laneId,
      checkoutPath: preparedWorker.checkoutPath,
      status: 'blocked',
      source: 'comparevi-bootstrap',
      reason: formatBootstrapFailure(error),
      bootstrapCommand,
      bootstrapExitCode: Number.isInteger(error?.code) ? error.code : 1,
      preparedAt: preparedWorker.generatedAt ?? null
    };
  }

  return {
    laneId: schedulerDecision.activeLane.laneId,
    checkoutPath: preparedWorker.checkoutPath,
    status: 'ready',
    source: 'comparevi-bootstrap',
    bootstrapCommand,
    bootstrapExitCode: 0,
    preparedAt: preparedWorker.generatedAt ?? null
  };
}

export async function activateCompareviWorkerLane({
  schedulerDecision,
  preparedWorker,
  workerReady,
  deps = {}
}) {
  const activeLane = schedulerDecision?.activeLane ?? null;
  const laneId = normalizeText(activeLane?.laneId);
  const checkoutPath = normalizeText(workerReady?.checkoutPath) || normalizeText(preparedWorker?.checkoutPath);
  const branch = normalizeText(schedulerDecision?.stepOptions?.branch) || normalizeText(activeLane?.branch);
  if (!laneId || !checkoutPath) {
    return null;
  }

  if (!branch) {
    return {
      laneId,
      checkoutPath,
      branch: null,
      forkRemote: normalizeText(activeLane?.forkRemote) || null,
      status: 'blocked',
      source: 'comparevi-branch',
      reason: 'selected lane does not resolve a deterministic branch name',
      baseRef: DEFAULT_WORKER_REF,
      trackingRef: null,
      fetchedRemotes: []
    };
  }

  const execFileFn = deps.execFileFn ?? execFileAsync;
  const forkRemote = normalizeText(activeLane?.forkRemote) || 'upstream';
  const availableRemotes = (await tryReadGitStdout(execFileFn, ['remote'], { cwd: checkoutPath }))
    .split(/\r?\n/)
    .map((entry) => normalizeText(entry))
    .filter(Boolean);
  const fetchedRemotes = [];
  try {
    for (const remote of ATTACHABLE_REMOTES) {
      if (!availableRemotes.includes(remote)) {
        continue;
      }
      await execFileFn('git', ['fetch', remote, '--prune'], { cwd: checkoutPath });
      fetchedRemotes.push(remote);
    }
    const currentBranch = await tryReadGitStdout(execFileFn, ['branch', '--show-current'], { cwd: checkoutPath });
    const trackingRef = `${forkRemote}/${branch}`;
    const trackingExists = await gitRefExists(execFileFn, checkoutPath, `refs/remotes/${trackingRef}`);
    if (currentBranch !== branch) {
      const checkoutTarget = trackingExists ? trackingRef : DEFAULT_WORKER_REF;
      // Runtime worktrees are ephemeral execution sandboxes; force checkout so
      // local bootstrap edits in detached refs cannot block lane activation.
      await execFileFn('git', ['checkout', '--force', '-B', branch, checkoutTarget], { cwd: checkoutPath });
      if (trackingExists) {
        await execFileFn('git', ['branch', '--set-upstream-to', trackingRef, branch], { cwd: checkoutPath });
      }
    }

    return {
      laneId,
      checkoutPath,
      branch,
      forkRemote,
      status: currentBranch === branch ? 'reused' : trackingExists ? 'attached' : 'created',
      source: 'comparevi-branch',
      reason: null,
      baseRef: DEFAULT_WORKER_REF,
      trackingRef: trackingExists ? trackingRef : null,
      fetchedRemotes,
      readyAt: workerReady?.readyAt ?? null
    };
  } catch (error) {
    return {
      laneId,
      checkoutPath,
      branch,
      forkRemote,
      status: 'blocked',
      source: 'comparevi-branch',
      reason: formatExecError(error),
      baseRef: DEFAULT_WORKER_REF,
      trackingRef: `${forkRemote}/${branch}`,
      fetchedRemotes
    };
  }
}

export const __test = {
  ATTACHABLE_REMOTES,
  BOOTSTRAP_RELATIVE_PATH,
  DEFAULT_WORKER_REF,
  formatGitPointerPath,
  isPathWithin,
  formatRelativeGitPointer,
  GITHUB_PUSH_REMOTES,
  normalizeGitHubRemotePushUrls,
  repairRegisteredWorktreeGitPointers,
  repairExistingWorktreeGitPointers,
  tryResolveCheckoutGitFromAdminPointer,
  resolveGitHubSshPushUrl
};

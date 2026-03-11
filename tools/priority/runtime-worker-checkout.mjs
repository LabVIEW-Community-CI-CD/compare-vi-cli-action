#!/usr/bin/env node

import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const DEFAULT_WORKER_REF = 'upstream/develop';
const BOOTSTRAP_RELATIVE_PATH = path.join('tools', 'priority', 'bootstrap.ps1');
const ATTACHABLE_REMOTES = ['upstream', 'origin', 'personal'];

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

async function repairExistingWorktreeGitPointers({ repoRoot, checkoutPath }) {
  const laneSegment = sanitizeSegment(path.basename(checkoutPath));
  const worktreeAdminDir = path.join(repoRoot, '.git', 'worktrees', laneSegment);
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

  const expectedCheckoutPointer = `gitdir: ${formatGitPointerPath(worktreeAdminDir)}\n`;
  const expectedAdminPointer = `${formatGitPointerPath(checkoutGitFile)}\n`;
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
    worktreeAdminDir,
    checkoutGitFile,
    adminGitdirFile
  };
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
      await repairExistingWorktreeGitPointers({ repoRoot, checkoutPath });
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
      return {
        laneId: activeLane.laneId,
        checkoutRoot,
        checkoutPath,
        status: 'reused',
        ref: resolvedRef,
        requestedBranch: normalizeText(schedulerDecision?.stepOptions?.branch) || null,
        source: 'comparevi-worktree',
        fetchedRemotes
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
  return {
    laneId: activeLane.laneId,
    checkoutRoot,
    checkoutPath,
    status: 'created',
    ref: DEFAULT_WORKER_REF,
    requestedBranch: normalizeText(schedulerDecision?.stepOptions?.branch) || null,
    source: 'comparevi-worktree'
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
  repairExistingWorktreeGitPointers
};

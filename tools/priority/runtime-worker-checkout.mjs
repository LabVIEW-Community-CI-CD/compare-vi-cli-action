#!/usr/bin/env node

import { access, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const DEFAULT_WORKER_REF = 'upstream/develop';
const BOOTSTRAP_RELATIVE_PATH = path.join('tools', 'priority', 'bootstrap.ps1');

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
  const gitMarkerPath = path.join(checkoutPath, '.git');
  if (await pathExists(gitMarkerPath)) {
    return {
      laneId: activeLane.laneId,
      checkoutRoot,
      checkoutPath,
      status: 'reused',
      ref: DEFAULT_WORKER_REF,
      requestedBranch: normalizeText(schedulerDecision?.stepOptions?.branch) || null,
      source: 'comparevi-worktree'
    };
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
  const execFileFn = deps.execFileFn ?? execFileAsync;
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
  const bootstrapPath = path.join(preparedWorker.checkoutPath, BOOTSTRAP_RELATIVE_PATH);
  const bootstrapCommand = ['pwsh', '-NoLogo', '-NoProfile', '-File', bootstrapPath];

  try {
    await execFileFn(bootstrapCommand[0], bootstrapCommand.slice(1), {
      cwd: preparedWorker.checkoutPath
    });
  } catch (error) {
    return {
      laneId: schedulerDecision.activeLane.laneId,
      checkoutPath: preparedWorker.checkoutPath,
      status: 'blocked',
      source: 'comparevi-bootstrap',
      reason: error?.message || String(error),
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

export const __test = {
  BOOTSTRAP_RELATIVE_PATH,
  DEFAULT_WORKER_REF
};

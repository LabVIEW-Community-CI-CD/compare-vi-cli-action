#!/usr/bin/env node

import { access, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const DEFAULT_WORKER_REF = 'upstream/develop';

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function sanitizeSegment(value) {
  return String(value || '')
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'runtime';
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
  const repoKey =
    sanitizeSegment(normalizeText(repository).replace(/\//g, '--')) || sanitizeSegment(path.basename(repoRoot));
  return path.join(path.dirname(repoRoot), '.runtime-worktrees', repoKey);
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

export const __test = {
  DEFAULT_WORKER_REF
};

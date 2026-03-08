#!/usr/bin/env node

import path from 'node:path';
import process from 'node:process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  run,
  getRepoRoot
} from './lib/branch-utils.mjs';
import {
  ensureGhCli,
  resolveUpstream,
  ensureOriginFork,
  pushBranch,
  runGhPrCreate
} from './lib/remote-utils.mjs';

const ROUTER_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'router.json');
const CACHE_RELATIVE_PATH = '.agent_priority_cache.json';
const STANDING_PRIORITY_LABELS = new Set(['standing-priority', 'fork-standing-priority']);

export function ensurePrSourceBranch(branch) {
  if (!branch || branch === 'HEAD') {
    throw new Error('Detached HEAD state detected; checkout a branch first.');
  }
  if (['develop', 'main'].includes(branch)) {
    throw new Error(`Refusing to open a PR directly from ${branch}. Create a feature branch first.`);
  }
  return branch;
}

export function detectCurrentBranch(repoRoot, runFn = run) {
  return runFn('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot });
}

export function readJsonFile(filePath, readFileSyncFn = readFileSync) {
  try {
    return JSON.parse(readFileSyncFn(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function toPositiveInteger(value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) {
    return null;
  }
  return number;
}

export function parseRouterIssueNumber(router) {
  if (!router || typeof router !== 'object') {
    return null;
  }
  if (!Object.prototype.hasOwnProperty.call(router, 'issue')) {
    return null;
  }
  return toPositiveInteger(router.issue);
}

export function parseCacheIssueNumber(cache) {
  if (!cache || typeof cache !== 'object') {
    return null;
  }

  const number = toPositiveInteger(cache.number ?? cache.issue?.number);
  if (!number) {
    return null;
  }

  const state = String(cache.state ?? cache.issue?.state ?? '').trim().toUpperCase();
  if (state && state !== 'OPEN') {
    return null;
  }

  const labels = Array.isArray(cache.labels)
    ? cache.labels
    : Array.isArray(cache.issue?.labels)
      ? cache.issue.labels
      : [];
  if (labels.length > 0) {
    const normalized = labels
      .map((label) => {
        if (typeof label === 'string') {
          return label.toLowerCase();
        }
        if (label && typeof label === 'object' && typeof label.name === 'string') {
          return label.name.toLowerCase();
        }
        return null;
      })
      .filter(Boolean);
    const hasStandingLabel = normalized.some((label) => STANDING_PRIORITY_LABELS.has(label));
    if (!hasStandingLabel) {
      return null;
    }
  }

  return number;
}

export function parseCacheNoStandingReason(cache) {
  if (!cache || typeof cache !== 'object') {
    return null;
  }

  const state = String(cache.state ?? cache.issue?.state ?? '').trim().toUpperCase();
  if (state !== 'NONE') {
    return null;
  }

  const reason = String(cache.noStandingReason ?? cache.issue?.noStandingReason ?? '').trim().toLowerCase();
  return reason || null;
}

export function resolveStandingIssueNumberForPr(repoRoot, { readJsonFn = readJsonFile } = {}) {
  const router = readJsonFn(path.join(repoRoot, ROUTER_RELATIVE_PATH));
  const cache = readJsonFn(path.join(repoRoot, CACHE_RELATIVE_PATH));
  if (router && Object.prototype.hasOwnProperty.call(router, 'issue')) {
    return {
      issueNumber: parseRouterIssueNumber(router),
      source: 'router',
      noStandingReason: parseCacheNoStandingReason(cache)
    };
  }

  return {
    issueNumber: parseCacheIssueNumber(cache),
    source: 'cache',
    noStandingReason: parseCacheNoStandingReason(cache)
  };
}

export function parseIssueNumberFromBranch(branch) {
  const match = String(branch || '').match(/^issue\/(?<issue>\d+)(?:-|$)/i);
  if (!match?.groups?.issue) {
    return null;
  }
  return toPositiveInteger(match.groups.issue);
}

export function assertBranchMatchesIssue(branch, issueNumber) {
  const branchIssueNumber = parseIssueNumberFromBranch(branch);
  if (!branchIssueNumber || !issueNumber) {
    return;
  }
  if (branchIssueNumber !== issueNumber) {
    throw new Error(
      `Current branch '${branch}' maps to #${branchIssueNumber}, but standing priority resolves to #${issueNumber}. ` +
        'Run bootstrap, then rename/switch to the standing-priority issue branch before creating a PR.'
    );
  }
}

export function buildTitle(branch, issueNumber, env = process.env) {
  if (env.PR_TITLE) {
    return env.PR_TITLE;
  }
  if (issueNumber) {
    return `Update for standing priority #${issueNumber}`;
  }
  return `Update ${branch}`;
}

export function buildBody(issueNumber, env = process.env) {
  if (env.PR_BODY) {
    return env.PR_BODY;
  }
  const suffix = issueNumber ? `\n\nCloses #${issueNumber}` : '';
  return `## Summary\n- (fill in summary)\n\n## Testing\n- (document testing)${suffix}`;
}

export function createPriorityPr({
  env = process.env,
  getRepoRootFn = getRepoRoot,
  getCurrentBranchFn = detectCurrentBranch,
  ensureGhCliFn = ensureGhCli,
  resolveUpstreamFn = resolveUpstream,
  ensureOriginForkFn = ensureOriginFork,
  pushBranchFn = pushBranch,
  runGhPrCreateFn = runGhPrCreate,
  resolveStandingIssueNumberFn = resolveStandingIssueNumberForPr
} = {}) {
  const repoRoot = getRepoRootFn();
  const branch = ensurePrSourceBranch(getCurrentBranchFn(repoRoot));

  ensureGhCliFn();

  const upstream = resolveUpstreamFn(repoRoot);
  const origin = ensureOriginForkFn(repoRoot, upstream);

  pushBranchFn(repoRoot, branch);

  const resolvedIssue = resolveStandingIssueNumberFn(repoRoot);
  const issueNumber = resolvedIssue?.issueNumber ?? null;
  if (!issueNumber && resolvedIssue?.noStandingReason === 'queue-empty') {
    throw new Error('Standing-priority queue is empty; create or label the next issue before opening a priority PR.');
  }
  assertBranchMatchesIssue(branch, issueNumber);
  const base = env.PR_BASE || 'develop';
  const title = buildTitle(branch, issueNumber, env);
  const body = buildBody(issueNumber, env);

  runGhPrCreateFn({
    upstream,
    origin,
    branch,
    base,
    title,
    body
  });

  return {
    repoRoot,
    branch,
    base,
    issueNumber,
    issueSource: resolvedIssue?.source ?? null,
    title,
    body
  };
}

export function main() {
  return createPriorityPr();
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    main();
  } catch (error) {
    console.error(`[priority:create-pr] ${error.message}`);
    process.exitCode = 1;
  }
}

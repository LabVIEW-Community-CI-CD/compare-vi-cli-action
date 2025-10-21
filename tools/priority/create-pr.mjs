#!/usr/bin/env node

import path from 'node:path';
import process from 'node:process';
import { createRequire } from 'node:module';
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

const require = createRequire(import.meta.url);

function getCurrentBranch(repoRoot) {
  const branch = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot });
  if (!branch || branch === 'HEAD') {
    throw new Error('Detached HEAD state detected; checkout a branch first.');
  }
  if (['develop', 'main'].includes(branch)) {
    throw new Error(`Refusing to open a PR directly from ${branch}. Create a feature branch first.`);
  }
  return branch;
}

function detectIssueNumber(repoRoot) {
  try {
    const cachePath = path.join(repoRoot, '.agent_priority_cache.json');
    const file = require(cachePath);
    if (file?.number) {
      return Number(file.number);
    }
  } catch {
    // ignore cache read failures
  }
  return null;
}

function buildTitle(branch, issueNumber) {
  if (process.env.PR_TITLE) {
    return process.env.PR_TITLE;
  }
  if (issueNumber) {
    return `Update for standing priority #${issueNumber}`;
  }
  return `Update ${branch}`;
}

function buildBody(issueNumber) {
  if (process.env.PR_BODY) {
    return process.env.PR_BODY;
  }
  const suffix = issueNumber ? `\n\nCloses #${issueNumber}` : '';
  return `## Summary\n- (fill in summary)\n\n## Testing\n- (document testing)${suffix}`;
}

function main() {
  const repoRoot = getRepoRoot();
  const branch = getCurrentBranch(repoRoot);

  ensureGhCli();

  const upstream = resolveUpstream(repoRoot);
  const origin = ensureOriginFork(repoRoot, upstream);

  pushBranch(repoRoot, branch);

  const issueNumber = detectIssueNumber(repoRoot);
  const base = process.env.PR_BASE || 'develop';
  const title = buildTitle(branch, issueNumber);
  const body = buildBody(issueNumber);

  runGhPrCreate({
    upstream,
    origin,
    branch,
    base,
    title,
    body
  });
}

try {
  main();
} catch (error) {
  console.error(`[priority:create-pr] ${error.message}`);
  process.exitCode = 1;
}


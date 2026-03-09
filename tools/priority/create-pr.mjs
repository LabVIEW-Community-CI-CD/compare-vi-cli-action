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
  runGhPrCreate,
  parseRepositorySlug
} from './lib/remote-utils.mjs';

const ROUTER_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'router.json');
const CACHE_RELATIVE_PATH = '.agent_priority_cache.json';
const NO_STANDING_REPORT_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'no-standing-priority.json');
const STANDING_PRIORITY_LABELS = new Set(['standing-priority', 'fork-standing-priority']);
const USAGE_LINES = [
  'Usage: node tools/npm/run-script.mjs priority:pr -- [options]',
  '',
  'Opens a pull request for the current branch (or an explicit branch), using the fork-aware helper contract.',
  '',
  'Options:',
  '  --repo <owner/repo>     Upstream repository override.',
  '  --issue <number>       Explicit issue number override.',
  '  --branch <name>         Branch to open instead of the current checkout.',
  '  --base <name>           Base branch (default: develop).',
  '  --title <text>          Explicit pull request title.',
  '  --body <text>           Explicit pull request body.',
  '  --body-file <path>      Read the pull request body from a file.',
  '  -h, --help              Show this message and exit.'
];

export function printUsage(lines = USAGE_LINES) {
  for (const line of lines) {
    console.log(line);
  }
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repository: null,
    issue: null,
    branch: null,
    base: null,
    title: null,
    body: null,
    bodyFile: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (
      token === '--repo' ||
      token === '--issue' ||
      token === '--branch' ||
      token === '--base' ||
      token === '--title' ||
      token === '--body' ||
      token === '--body-file'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repository = next;
      if (token === '--issue') {
        options.issue = toPositiveInteger(next);
        if (!options.issue) {
          throw new Error(`Invalid issue number for ${token}: ${next}`);
        }
      }
      if (token === '--branch') options.branch = next;
      if (token === '--base') options.base = next;
      if (token === '--title') options.title = next;
      if (token === '--body') options.body = next;
      if (token === '--body-file') options.bodyFile = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.body && options.bodyFile) {
    throw new Error('Use either --body or --body-file, not both.');
  }

  return options;
}

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

export function readBodyFromFile(filePath, readFileSyncFn = readFileSync) {
  const body = readFileSyncFn(filePath, 'utf8');
  if (!String(body || '').trim()) {
    throw new Error(`Pull request body file '${filePath}' is empty.`);
  }
  return body;
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

export function parseNoStandingReasonFromReport(report) {
  if (!report || typeof report !== 'object') {
    return null;
  }

  const schema = String(report.schema ?? '').trim().toLowerCase();
  if (schema && schema !== 'standing-priority/no-standing@v1') {
    return null;
  }

  const reason = String(report.reason ?? '').trim().toLowerCase();
  return reason || null;
}

export function resolveStandingIssueNumberForPr(repoRoot, { readJsonFn = readJsonFile } = {}) {
  const router = readJsonFn(path.join(repoRoot, ROUTER_RELATIVE_PATH));
  const cache = readJsonFn(path.join(repoRoot, CACHE_RELATIVE_PATH));
  const noStandingReport = readJsonFn(path.join(repoRoot, NO_STANDING_REPORT_RELATIVE_PATH));
  const noStandingReason = parseCacheNoStandingReason(cache) || parseNoStandingReasonFromReport(noStandingReport);
  if (router && Object.prototype.hasOwnProperty.call(router, 'issue')) {
    return {
      issueNumber: parseRouterIssueNumber(router),
      source: 'router',
      noStandingReason
    };
  }

  return {
    issueNumber: parseCacheIssueNumber(cache),
    source: 'cache',
    noStandingReason
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

export function resolveBody({ options, issueNumber, env = process.env, readFileSyncFn = readFileSync }) {
  if (options.bodyFile) {
    return readBodyFromFile(options.bodyFile, readFileSyncFn);
  }
  if (env.PR_BODY_FILE) {
    return readBodyFromFile(env.PR_BODY_FILE, readFileSyncFn);
  }
  if (options.body) {
    return options.body;
  }
  return buildBody(issueNumber, env);
}

export function createPriorityPr({
  env = process.env,
  options = {},
  readFileSyncFn = readFileSync,
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
  const branch = ensurePrSourceBranch(options.branch || getCurrentBranchFn(repoRoot));

  ensureGhCliFn();

  const upstream = options.repository ? parseRepositorySlug(options.repository) : resolveUpstreamFn(repoRoot);
  const origin = ensureOriginForkFn(repoRoot, upstream);

  pushBranchFn(repoRoot, branch);

  const resolvedIssue =
    options.issue && toPositiveInteger(options.issue)
      ? { issueNumber: toPositiveInteger(options.issue), source: 'cli', noStandingReason: null }
      : resolveStandingIssueNumberFn(repoRoot);
  const issueNumber = resolvedIssue?.issueNumber ?? null;
  if (!issueNumber && resolvedIssue?.noStandingReason === 'queue-empty') {
    throw new Error('Standing-priority queue is empty; create or label the next issue before opening a priority PR.');
  }
  assertBranchMatchesIssue(branch, issueNumber);
  const base = options.base || env.PR_BASE || 'develop';
  const title = options.title || buildTitle(branch, issueNumber, env);
  const body = resolveBody({ options, issueNumber, env, readFileSyncFn });

  const prResult = runGhPrCreateFn({
    repoRoot,
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
    body,
    upstream,
    origin,
    strategy: prResult?.strategy ?? null,
    pullRequest: prResult?.pullRequest ?? null
  };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const result = createPriorityPr({ options });
  if (result?.strategy) {
    console.log(`[priority:create-pr] strategy=${result.strategy}`);
  }
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const code = main(process.argv);
    if (code !== 0) {
      process.exitCode = code;
    }
  } catch (error) {
    console.error(`[priority:create-pr] ${error.message}`);
    process.exitCode = 1;
  }
}

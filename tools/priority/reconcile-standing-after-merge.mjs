#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { ensureGhCli } from './lib/remote-utils.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { resolveRepositorySlug, resolveUpstreamRepositorySlug } from './sync-standing-priority.mjs';

const RECONCILIATION_SCHEMA = 'priority/standing-lane-reconciliation@v1';
const DEFAULT_RECEIPT_DIR = path.join('tests', 'results', '_agent', 'issue');
const DEFAULT_ROUTER_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'router.json');
const DEFAULT_CACHE_RELATIVE_PATH = '.agent_priority_cache.json';

const USAGE_LINES = [
  'Usage: node tools/priority/reconcile-standing-after-merge.mjs --issue <number> [options]',
  '',
  'Options:',
  '  --issue <number>            Standing issue number to reconcile (required)',
  '  --repo <owner/repo>         Target repository (defaults to environment / git remote resolution)',
  '  --pr <number>               Merge pull request number for close-comment evidence',
  '  --merged                    Force reconciliation after a confirmed merge completion',
  '  --worker-slot-id <id>       Worker slot being released by the merge completion',
  '  --merge-summary-path <path> Read an existing merge summary receipt for context',
  '  --summary-path <path>       Write reconciliation receipt JSON',
  '  --dry-run                   Plan the reconciliation without mutating labels, issues, or cache',
  '  -h, --help                  Show this message and exit'
];

function printUsage() {
  for (const line of USAGE_LINES) {
    console.log(line);
  }
}

function normalizeText(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalizeUpper(value) {
  return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

function coercePositiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function normalizeLabels(values) {
  const seen = new Set();
  const labels = [];
  for (const value of values || []) {
    const label = normalizeText(typeof value === 'string' ? value : value?.name);
    if (!label || seen.has(label.toLowerCase())) {
      continue;
    }
    seen.add(label.toLowerCase());
    labels.push(label);
  }
  return labels;
}

function buildSummaryPath(repoRoot, issueNumber, explicitPath = null) {
  if (normalizeText(explicitPath)) {
    return path.isAbsolute(explicitPath) ? explicitPath : path.join(repoRoot, explicitPath);
  }
  return path.join(repoRoot, DEFAULT_RECEIPT_DIR, `standing-lane-reconciliation-${issueNumber}.json`);
}

function buildRouterPath(repoRoot, explicitPath = null) {
  if (normalizeText(explicitPath)) {
    return path.isAbsolute(explicitPath) ? explicitPath : path.join(repoRoot, explicitPath);
  }
  return path.join(repoRoot, DEFAULT_ROUTER_RELATIVE_PATH);
}

function buildCachePath(repoRoot, explicitPath = null) {
  if (normalizeText(explicitPath)) {
    return path.isAbsolute(explicitPath) ? explicitPath : path.join(repoRoot, explicitPath);
  }
  return path.join(repoRoot, DEFAULT_CACHE_RELATIVE_PATH);
}

export function resolveStandingReconciliationRepositorySlug({
  repoRoot,
  explicitRepo = null,
  env = process.env
} = {}) {
  const resolvedRepo = normalizeText(explicitRepo) || resolveRepositorySlug(repoRoot, env);
  const upstreamRepo = resolveUpstreamRepositorySlug(repoRoot, resolvedRepo, env);
  if (
    upstreamRepo &&
    normalizeText(upstreamRepo).toLowerCase() !== normalizeText(resolvedRepo).toLowerCase()
  ) {
    return upstreamRepo;
  }
  return resolvedRepo;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    issue: null,
    pr: null,
    merged: false,
    workerSlotId: null,
    mergeSummaryPath: null,
    summaryPath: null,
    routerPath: null,
    cachePath: null,
    dryRun: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--merged') {
      options.merged = true;
      continue;
    }
    if (token === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (
      token === '--repo' ||
      token === '--issue' ||
      token === '--pr' ||
      token === '--worker-slot-id' ||
      token === '--merge-summary-path' ||
      token === '--summary-path' ||
      token === '--router-path' ||
      token === '--cache-path'
    ) {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') {
        options.repo = value;
      } else if (token === '--issue') {
        const parsed = coercePositiveInteger(value);
        if (!parsed) {
          throw new Error(`Invalid --issue value '${value}'. Expected positive integer.`);
        }
        options.issue = parsed;
      } else if (token === '--pr') {
        const parsed = coercePositiveInteger(value);
        if (!parsed) {
          throw new Error(`Invalid --pr value '${value}'. Expected positive integer.`);
        }
        options.pr = parsed;
      } else if (token === '--worker-slot-id') {
        options.workerSlotId = normalizeText(value);
      } else if (token === '--merge-summary-path') {
        options.mergeSummaryPath = value;
      } else if (token === '--summary-path') {
        options.summaryPath = value;
      } else if (token === '--router-path') {
        options.routerPath = value;
      } else if (token === '--cache-path') {
        options.cachePath = value;
      }
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.issue && !options.help) {
    printUsage();
    throw new Error('Missing required option --issue <number>.');
  }

  return options;
}

function parseJsonOutput(raw, { label }) {
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Unable to parse ${label}: ${error.message}`);
  }
}

function readIssueView({
  repoRoot,
  repo,
  issue,
  spawnSyncFn = spawnSync
}) {
  const result = spawnSyncFn(
    'gh',
    [
      'issue',
      'view',
      String(issue),
      '--repo',
      repo,
      '--json',
      'number,state,title,url,labels,closedAt,updatedAt'
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );
  if (result.status !== 0) {
    const combined = `${result.stderr ?? ''}${result.stdout ?? ''}`.trim();
    throw new Error(`gh issue view failed for #${issue}: ${combined || `exit ${result.status}`}`);
  }
  return parseJsonOutput(result.stdout ?? '{}', { label: 'gh issue view output' });
}

function removeStandingLabels({
  repoRoot,
  repo,
  issue,
  labels = [],
  spawnSyncFn = spawnSync
}) {
  const normalizedLabels = normalizeLabels(labels);
  if (normalizedLabels.length === 0) {
    return { status: 0, stdout: '', stderr: '', labels: [] };
  }

  const result = spawnSyncFn(
    'gh',
    [
      'issue',
      'edit',
      String(issue),
      '--repo',
      repo,
      ...normalizedLabels.flatMap((label) => ['--remove-label', label])
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );

  if (result.status !== 0) {
    const combined = `${result.stderr ?? ''}${result.stdout ?? ''}`.trim();
    throw new Error(`gh issue edit failed for #${issue}: ${combined || `exit ${result.status}`}`);
  }

  return { ...result, labels: normalizedLabels };
}

function closeIssueWithComment({
  repoRoot,
  repo,
  issue,
  state,
  comment,
  spawnSyncFn = spawnSync
}) {
  const normalizedState = normalizeUpper(state);
  const command =
    normalizedState === 'OPEN'
      ? ['issue', 'close', String(issue), '--repo', repo, '--comment', comment]
      : ['issue', 'comment', String(issue), '--repo', repo, '--body', comment];
  const result = spawnSyncFn('gh', command, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const combined = `${result.stderr ?? ''}${result.stdout ?? ''}`.trim();
    throw new Error(`gh ${command.slice(0, 2).join(' ')} failed for #${issue}: ${combined || `exit ${result.status}`}`);
  }
  return result;
}

function syncStandingPriority({
  repoRoot,
  repo,
  spawnSyncFn = spawnSync
}) {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'sync-standing-priority.mjs');
  const result = spawnSyncFn(
    'node',
    [
      scriptPath,
      '--fail-on-missing',
      '--fail-on-multiple',
      '--auto-select-next',
      '--materialize-cache'
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        GITHUB_REPOSITORY: repo
      },
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );
  if (result.status !== 0) {
    const combined = `${result.stderr ?? ''}${result.stdout ?? ''}`.trim();
    throw new Error(`sync-standing-priority failed: ${combined || `exit ${result.status}`}`);
  }
  return result;
}

async function readJsonIfPresent(filePath, { readFileFn = readFile } = {}) {
  try {
    return JSON.parse(await readFileFn(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

async function writeJson(filePath, payload, { mkdirFn = mkdir, writeFileFn = writeFile } = {}) {
  await mkdirFn(path.dirname(filePath), { recursive: true });
  await writeFileFn(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

function buildCloseComment({ issue, pr, nextStandingIssueNumber = null }) {
  const prReference = Number.isInteger(pr) && pr > 0 ? `PR #${pr}` : 'the merged pull request';
  if (Number.isInteger(nextStandingIssueNumber)) {
    return `Completed by ${prReference}. Standing priority has advanced from #${issue} to #${nextStandingIssueNumber}.`;
  }
  return `Completed by ${prReference}. No next standing-priority issue is currently labeled, so the queue is now idle until a new issue is promoted.`;
}

export function buildStandingLaneReconciliationReceipt({
  repo,
  issue,
  pr = null,
  merged = false,
  dryRun = false,
  mergeSummaryPath = null,
  standingIssue = null,
  routerRefresh = null,
  workerSlotRelease = null,
  summary = null,
  generatedAt = new Date().toISOString()
} = {}) {
  return {
    schema: RECONCILIATION_SCHEMA,
    generatedAt,
    repo,
    issue,
    pr,
    merged,
    dryRun,
    mergeSummaryPath,
    standingIssue,
    routerRefresh,
    workerSlotRelease,
    summary
  };
}

export async function runStandingReconciliation({
  argv = process.argv,
  repoRoot = getRepoRoot(),
  ensureGhCliFn = ensureGhCli,
  readIssueViewFn = readIssueView,
  removeStandingLabelsFn = removeStandingLabels,
  closeIssueWithCommentFn = closeIssueWithComment,
  syncStandingPriorityFn = syncStandingPriority,
  readJsonFn = readJsonIfPresent,
  writeJsonFn = writeJson
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return null;
  }

  ensureGhCliFn?.();

  const resolvedRepoRoot = repoRoot || getRepoRoot();
  const repository = resolveStandingReconciliationRepositorySlug({
    repoRoot: resolvedRepoRoot,
    explicitRepo: options.repo,
    env: process.env
  });
  const issuePath = buildSummaryPath(resolvedRepoRoot, options.issue, options.summaryPath);
  const routerPath = buildRouterPath(resolvedRepoRoot, options.routerPath);
  const cachePath = buildCachePath(resolvedRepoRoot, options.cachePath);
  const mergeSummaryPath = normalizeText(options.mergeSummaryPath)
    ? path.isAbsolute(options.mergeSummaryPath)
      ? options.mergeSummaryPath
      : path.join(resolvedRepoRoot, options.mergeSummaryPath)
    : null;

  const issueView = await readIssueViewFn({
    repoRoot: resolvedRepoRoot,
    repo: repository,
    issue: options.issue
  });
  const issueState = normalizeUpper(issueView?.state);
  const labelsBefore = normalizeLabels(issueView?.labels);
  const standingLabels = labelsBefore.filter((label) => ['standing-priority', 'fork-standing-priority'].includes(label.toLowerCase()));
  const shouldReconcile = options.merged || issueState !== 'OPEN';

  const standingIssue = {
    number: options.issue,
    state: issueView?.state ?? null,
    labelsBefore,
    labelsRemoved: [],
    closeStatus: null,
    closeComment: null
  };

  const mergeSummary = mergeSummaryPath ? await readJsonFn(mergeSummaryPath) : null;
  const mergeSummaryStatus = normalizeText(mergeSummary?.promotion?.status) || null;
  const mergeSummaryReason = normalizeText(mergeSummary?.finalReason) || normalizeText(mergeSummary?.selectedReason) || null;

  const workerSlotRelease = {
    attempted: Boolean(normalizeText(options.workerSlotId)),
    status: normalizeText(options.workerSlotId) ? 'skipped' : 'skipped',
    workerSlotId: normalizeText(options.workerSlotId) || null,
    laneId: null,
    laneLifecycle: null,
    helperCallsExecuted: []
  };

  if (!shouldReconcile) {
    const receipt = buildStandingLaneReconciliationReceipt({
      repo: repository,
      issue: options.issue,
      pr: options.pr,
      merged: options.merged,
      dryRun: options.dryRun,
      mergeSummaryPath,
      standingIssue,
      routerRefresh: {
        attempted: false,
        status: 'skipped',
        routerPath,
        cachePath,
        nextStandingIssueNumber: null,
        helperCallsExecuted: []
      },
      workerSlotRelease,
      summary: {
        status: 'skipped',
        reason: 'issue-still-open',
        nextStandingIssueNumber: null
      }
    });
    await writeJsonFn(issuePath, receipt);
    return receipt;
  }

  const helperCallsExecuted = [];
  let nextStandingIssueNumber = null;
  let reconciliationStatus = 'completed';
  let reconciliationReason = 'standing lane reconciled after merge completion';

  try {
    if (options.dryRun) {
      standingIssue.labelsRemoved = standingLabels;
      standingIssue.closeStatus = options.merged ? 'dry-run' : 'skipped';
      standingIssue.closeComment = options.merged ? buildCloseComment({ issue: options.issue, pr: options.pr }) : null;
      helperCallsExecuted.push('gh issue edit <omitted>', 'node tools/priority/sync-standing-priority.mjs');
      workerSlotRelease.status = workerSlotRelease.attempted ? 'dry-run' : 'skipped';
    } else {
      if (standingLabels.length > 0) {
        await removeStandingLabelsFn({
          repoRoot: resolvedRepoRoot,
          repo: repository,
          issue: options.issue,
          labels: standingLabels
        });
        standingIssue.labelsRemoved = standingLabels;
        helperCallsExecuted.push(
          `gh issue edit ${options.issue} --repo ${repository} ${standingLabels.map((label) => `--remove-label ${label}`).join(' ')}`
        );
      }

      if (options.merged) {
        const closeComment = buildCloseComment({
          issue: options.issue,
          pr: options.pr,
          nextStandingIssueNumber
        });
        standingIssue.closeComment = closeComment;
        const closeResult = await closeIssueWithCommentFn({
          repoRoot: resolvedRepoRoot,
          repo: repository,
          issue: options.issue,
          state: issueState,
          comment: closeComment
        });
        standingIssue.closeStatus = closeResult?.status === 0 ? 'completed' : 'failed';
        helperCallsExecuted.push(
          `gh issue ${issueState === 'OPEN' ? 'close' : 'comment'} ${options.issue} --repo ${repository} ${issueState === 'OPEN' ? '--comment' : '--body'} <omitted>`
        );
      } else {
        standingIssue.closeStatus = issueState === 'OPEN' ? 'skipped' : 'commented';
      }

      const syncResult = await syncStandingPriorityFn({
        repoRoot: resolvedRepoRoot,
        repo: repository
      });
      helperCallsExecuted.push(`node tools/priority/sync-standing-priority.mjs --fail-on-missing --fail-on-multiple --auto-select-next --materialize-cache`);
      if (syncResult?.status !== 0) {
        throw new Error(
          normalizeText(syncResult?.stderr) || normalizeText(syncResult?.stdout) || 'sync-standing-priority failed'
        );
      }

      const router = await readJsonFn(routerPath);
      const cache = await readJsonFn(cachePath);
      nextStandingIssueNumber = coercePositiveInteger(router?.issue) || coercePositiveInteger(cache?.number) || null;
      workerSlotRelease.status = workerSlotRelease.attempted ? 'released' : 'skipped';
      workerSlotRelease.helperCallsExecuted = workerSlotRelease.attempted
        ? [`worker-slot ${workerSlotRelease.workerSlotId} released`]
        : [];
      workerSlotRelease.laneId = normalizeText(mergeSummary?.laneId) || null;
      workerSlotRelease.laneLifecycle = normalizeText(mergeSummary?.laneLifecycle) || null;
      reconciliationReason = mergeSummaryStatus
        ? `standing lane reconciled after merge completion (${mergeSummaryStatus})`
        : reconciliationReason;
    }
  } catch (error) {
    reconciliationStatus = 'failed';
    reconciliationReason = normalizeText(error?.message) || 'standing reconciliation failed';
    workerSlotRelease.status = 'failed';
  }

  const routerRefresh = {
    attempted: true,
    status: reconciliationStatus === 'failed' ? 'failed' : options.dryRun ? 'dry-run' : 'completed',
    routerPath,
    cachePath,
    nextStandingIssueNumber,
    helperCallsExecuted
  };

  const receipt = buildStandingLaneReconciliationReceipt({
    repo: repository,
    issue: options.issue,
    pr: options.pr,
    merged: options.merged,
    dryRun: options.dryRun,
    mergeSummaryPath,
    standingIssue,
    routerRefresh,
    workerSlotRelease,
    summary: {
      status: reconciliationStatus === 'failed' ? 'failed' : options.dryRun ? 'dry-run' : 'completed',
      reason: reconciliationReason,
      nextStandingIssueNumber
    }
  });

  await writeJsonFn(issuePath, receipt);
  return receipt;
}

async function main() {
  try {
    const result = await runStandingReconciliation();
    if (result?.summary?.status === 'failed') {
      process.exitCode = 1;
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main();
}

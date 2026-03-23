#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  run,
  getRepoRoot
} from './lib/branch-utils.mjs';
import {
  ensureGhCli,
  resolveUpstream,
  ensureForkRemote,
  resolveActiveForkRemoteName,
  normalizeForkRemoteName,
  pushBranch,
  runGhPrCreate,
  findMergedPullRequest,
  findOpenAncestorPullRequest,
  parseRepositorySlug,
  buildRepositorySlug
} from './lib/remote-utils.mjs';
import {
  DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH,
  classifyBranch,
  findRepositoryPlaneEntry,
  loadBranchClassContract,
  resolveRepositoryPlane,
  resolveRepositoryPlaneFromBranchName
} from './lib/branch-classification.mjs';
import { buildForkLaneIdentity } from './lib/fork-lane-identity.mjs';

const ROUTER_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'router.json');
const CACHE_RELATIVE_PATH = '.agent_priority_cache.json';
const NO_STANDING_REPORT_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'no-standing-priority.json');
const DEFAULT_PR_TEMPLATE_RELATIVE_PATH = path.join('.github', 'pull_request_template.md');
const DEFAULT_REPORT_DIR = path.join('tests', 'results', '_agent', 'issue');
const STANDING_PRIORITY_LABELS = new Set(['standing-priority', 'fork-standing-priority']);
const USAGE_LINES = [
  'Usage: node tools/npm/run-script.mjs priority:pr -- [options]',
  '',
  'Opens a pull request for the current branch (or an explicit branch), using the fork-aware helper contract.',
  '',
  'Options:',
  '  --repo <owner/repo>     Upstream repository override.',
  '  --issue <number>        Explicit issue number override.',
  '  --branch <name>         Branch to open instead of the current checkout.',
  '  --base <name>           Base branch (default: develop).',
  '  --title <text>          Explicit pull request title.',
  '  --body <text>           Explicit pull request body.',
  '  --body-file <path>      Read the pull request body from a file.',
  '  --draft                 Create the pull request as draft instead of ready-for-review.',
  `  --report-dir <path>     Directory for the machine-readable report (default: ${DEFAULT_REPORT_DIR}).`,
  '  --head-remote <name>    Fork remote to push/open from (default: AGENT_PRIORITY_ACTIVE_FORK_REMOTE or origin).',
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
    draft: null,
    reportDir: DEFAULT_REPORT_DIR,
    headRemote: null,
    help: false
  };

  const tokensRequiringValue = new Set([
    '--repo',
    '--issue',
    '--branch',
    '--base',
    '--title',
    '--body',
    '--body-file',
    '--report-dir',
    '--head-remote'
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (token === '--draft') {
      options.draft = true;
      continue;
    }

    if (tokensRequiringValue.has(token)) {
      if (next === undefined) {
        throw new Error(`Missing value for ${token}.`);
      }
      if (token !== '--body' && next.startsWith('-')) {
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
      if (token === '--report-dir') options.reportDir = next;
      if (token === '--head-remote') options.headRemote = next;
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

export function detectCurrentHeadSha(repoRoot, runFn = run) {
  return runFn('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });
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

function normalizeText(value) {
  return String(value ?? '').trim();
}

function digestText(value) {
  return createHash('sha256').update(String(value ?? ''), 'utf8').digest('hex');
}

export function resolveReadyValidationClearancePath({
  repoRoot,
  repository,
  pullRequestNumber
}) {
  const repositorySlug = normalizeText(repository)
    .replace(/[^A-Za-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'runtime',
    'ready-validation-clearance',
    `${repositorySlug || 'repository'}-pr-${pullRequestNumber}.json`
  );
}

export function buildPrReadyArgs({ repository, pullRequestNumber, ready = true }) {
  const repoSlug = normalizeText(repository);
  const prNumber = toPositiveInteger(pullRequestNumber);
  if (!repoSlug) {
    throw new Error('Repository slug is required to change PR ready state.');
  }
  if (!prNumber) {
    throw new Error('Pull request number is required to change PR ready state.');
  }

  return [
    'pr',
    'ready',
    String(prNumber),
    '--repo',
    repoSlug,
    ...(ready ? [] : ['--undo'])
  ];
}

export function resolveReadyTransitionDryRunSummaryPath({
  repoRoot,
  repository,
  pullRequestNumber
}) {
  const repositorySlug = normalizeText(repository)
    .replace(/[^A-Za-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'issue',
    `${repositorySlug || 'repository'}-pr-${pullRequestNumber}-ready-transition-dry-run.json`
  );
}

export function buildReadyTransitionMergeSyncDryRunArgs({ repository, pullRequestNumber, summaryPath }) {
  const repoSlug = normalizeText(repository);
  const prNumber = toPositiveInteger(pullRequestNumber);
  if (!repoSlug) {
    throw new Error('Repository slug is required to probe merge-sync readiness.');
  }
  if (!prNumber) {
    throw new Error('Pull request number is required to probe merge-sync readiness.');
  }
  if (!normalizeText(summaryPath)) {
    throw new Error('Dry-run summary path is required to probe merge-sync readiness.');
  }
  return [
    'tools/priority/merge-sync-pr.mjs',
    '--pr',
    String(prNumber),
    '--repo',
    repoSlug,
    '--dry-run',
    '--summary-path',
    summaryPath
  ];
}

export function probeReadyTransitionViaMergeSyncDryRun({
  repoRoot,
  repository,
  pullRequestNumber,
  readJsonFn = readJsonFile,
  spawnSyncFn = spawnSync
}) {
  const summaryPath = resolveReadyTransitionDryRunSummaryPath({
    repoRoot,
    repository,
    pullRequestNumber
  });
  const args = buildReadyTransitionMergeSyncDryRunArgs({
    repository,
    pullRequestNumber,
    summaryPath
  });
  const result = spawnSyncFn('node', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const summary = readJsonFn(summaryPath) ?? null;
  const reviewClearance = summary?.reviewClearance ?? null;
  const reasons = Array.isArray(reviewClearance?.reasons)
    ? reviewClearance.reasons.filter((entry) => normalizeText(entry))
    : [];
  const reason =
    reasons.join(', ') ||
    normalizeText(reviewClearance?.gateState) ||
    normalizeText(result?.stderr) ||
    normalizeText(result?.stdout) ||
    `merge-sync-dry-run-exit-${result?.status ?? 'unknown'}`;
  return {
    ok: result?.status === 0 && normalizeText(reviewClearance?.status).toLowerCase() === 'pass',
    summaryPath,
    helperCall: `node ${args.join(' ')}`,
    reviewClearance,
    reason
  };
}

export function resolveQueueAdmissionSummaryPath({
  repoRoot,
  repository,
  pullRequestNumber
}) {
  const repositorySlug = normalizeText(repository)
    .replace(/[^A-Za-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'issue',
    `${repositorySlug || 'repository'}-pr-${pullRequestNumber}-queue-admission.json`
  );
}

export function buildQueueAdmissionMergeSyncArgs({ repository, pullRequestNumber, summaryPath }) {
  const repoSlug = normalizeText(repository);
  const prNumber = toPositiveInteger(pullRequestNumber);
  if (!repoSlug) {
    throw new Error('Repository slug is required to admit a PR to the merge queue.');
  }
  if (!prNumber) {
    throw new Error('Pull request number is required to admit a PR to the merge queue.');
  }
  if (!normalizeText(summaryPath)) {
    throw new Error('Queue-admission summary path is required to admit a PR to the merge queue.');
  }
  return [
    'tools/priority/merge-sync-pr.mjs',
    '--pr',
    String(prNumber),
    '--repo',
    repoSlug,
    '--summary-path',
    summaryPath
  ];
}

export function maybeAdmitPullRequestToMergeQueue({
  repoRoot,
  upstream,
  strategy,
  pullRequest,
  readyTransition,
  readJsonFn = readJsonFile,
  spawnSyncFn = spawnSync
}) {
  if (!['graphql-same-owner-fork', 'gh-pr-create'].includes(strategy)) {
    return {
      status: 'skipped',
      reason: 'Queue admission only applies to PR creation flows with merge-sync handoff support.',
      attempted: false
    };
  }

  if (!pullRequest?.number) {
    return {
      status: 'skipped',
      reason: 'Pull request metadata is missing.',
      attempted: false
    };
  }

  if (pullRequest?.isDraft === true) {
    return {
      status: 'skipped',
      reason: 'Queue admission is skipped while the pull request remains draft.',
      attempted: false
    };
  }

  const readyTransitionStatus = normalizeText(readyTransition?.status).toLowerCase();
  if (
    strategy === 'graphql-same-owner-fork' &&
    !['ready', 'already-ready'].includes(readyTransitionStatus)
  ) {
    return {
      status: 'skipped',
      reason: 'Queue admission is only attempted after the current PR creation flow marked the PR ready for review.',
      attempted: false
    };
  }

  const repository = buildRepositorySlug(upstream);
  const summaryPath = resolveQueueAdmissionSummaryPath({
    repoRoot,
    repository,
    pullRequestNumber: pullRequest.number
  });
  const args = buildQueueAdmissionMergeSyncArgs({
    repository,
    pullRequestNumber: pullRequest.number,
    summaryPath
  });
  const result = spawnSyncFn('node', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const summary = readJsonFn(summaryPath) ?? null;
  const promotion = summary?.promotion ?? null;
  const promotionStatus = normalizeText(promotion?.status).toLowerCase();
  const durablePromotion = promotion?.materialized === true;
  const reason =
    normalizeText(summary?.finalReason) ||
    normalizeText(result?.stderr) ||
    normalizeText(result?.stdout) ||
    (promotionStatus ? `merge-sync-${promotionStatus}` : `merge-sync-exit-${result?.status ?? 'unknown'}`);

  if (result?.status === 0 && durablePromotion) {
    return {
      status: promotionStatus || 'queued',
      reason,
      attempted: true,
      helperCall: `node ${args.join(' ')}`,
      summaryPath,
      promotion
    };
  }

  return {
    status: 'admission-failed',
    reason,
    attempted: true,
    helperCall: `node ${args.join(' ')}`,
    summaryPath,
    promotion
  };
}

export function readReadyValidationClearance({
  repoRoot,
  repository,
  pullRequestNumber,
  readJsonFn = readJsonFile
}) {
  const receiptPath = resolveReadyValidationClearancePath({ repoRoot, repository, pullRequestNumber });
  return {
    receiptPath,
    receipt: readJsonFn(receiptPath) ?? null
  };
}

export function evaluateReadyTransitionEligibility({
  strategy,
  pullRequest,
  currentHeadSha,
  readyValidationClearance
}) {
  if (strategy !== 'graphql-same-owner-fork') {
    return {
      eligible: false,
      status: 'not-applicable',
      reason: 'PR ready transition only applies to same-owner fork PR creation.'
    };
  }
  if (!pullRequest?.number) {
    return {
      eligible: false,
      status: 'missing-pr',
      reason: 'Pull request metadata is missing.'
    };
  }
  if (pullRequest?.isDraft === false) {
    return {
      eligible: false,
      status: 'already-ready',
      reason: 'Pull request is already ready for review.'
    };
  }
  if (!normalizeText(currentHeadSha)) {
    return {
      eligible: false,
      status: 'missing-head',
      reason: 'Current branch head sha is unavailable.'
    };
  }

  const receipt = readyValidationClearance?.receipt ?? null;
  const storedReadyHeadSha = normalizeText(receipt?.readyHeadSha);
  const storedStatus = normalizeText(receipt?.status).toLowerCase();
  if (!receipt || !storedReadyHeadSha) {
    return {
      eligible: false,
      status: 'clearance-missing',
      reason: 'No ready-validation clearance exists for the current head.'
    };
  }
  if (storedStatus !== 'current') {
    return {
      eligible: false,
      status: 'clearance-invalid',
      reason: 'Stored ready-validation clearance is not current.'
    };
  }
  if (storedReadyHeadSha !== normalizeText(currentHeadSha)) {
    return {
      eligible: false,
      status: 'stale-head',
      reason: 'Stored ready-validation clearance does not match the current head.'
    };
  }

  return {
    eligible: true,
    status: 'eligible',
    reason: 'Stored ready-validation clearance matches the current head.',
    readyHeadSha: storedReadyHeadSha
  };
}

export function maybePromotePullRequestToReady({
  repoRoot,
  upstream,
  strategy,
  pullRequest,
  currentHeadSha,
  readJsonFn = readJsonFile,
  runFn = run,
  runReadyProbeFn = probeReadyTransitionViaMergeSyncDryRun
}) {
  const repository = buildRepositorySlug(upstream);
  const readyValidationClearance = readReadyValidationClearance({
    repoRoot,
    repository,
    pullRequestNumber: pullRequest?.number,
    readJsonFn
  });
  const eligibility = evaluateReadyTransitionEligibility({
    strategy,
    pullRequest,
    currentHeadSha,
    readyValidationClearance
  });
  const shouldProbeMergeSyncReady =
    !eligibility.eligible &&
    ['clearance-missing', 'clearance-invalid', 'stale-head'].includes(eligibility.status);
  const readyProbe = shouldProbeMergeSyncReady
    ? runReadyProbeFn({
        repoRoot,
        repository,
        pullRequestNumber: pullRequest?.number,
        readJsonFn
      })
    : null;
  if (!eligibility.eligible && readyProbe?.ok) {
    const args = buildPrReadyArgs({
      repository,
      pullRequestNumber: pullRequest.number,
      ready: true
    });
    try {
      runFn('gh', args, { cwd: repoRoot });
      return {
        status: 'ready',
        reason: 'Marked the PR ready for review after merge-sync dry-run proved the current head queue-safe.',
        receiptPath: readyValidationClearance.receiptPath,
        readyHeadSha: normalizeText(currentHeadSha) || null,
        currentHeadSha: normalizeText(currentHeadSha) || null,
        attempted: true,
        helperCall: `gh ${args.join(' ')}`,
        dryRunSummaryPath: readyProbe.summaryPath,
        reviewClearance: readyProbe.reviewClearance
      };
    } catch (error) {
      return {
        status: 'transition-failed',
        reason: normalizeText(error?.stderr) || normalizeText(error?.message) || String(error),
        receiptPath: readyValidationClearance.receiptPath,
        readyHeadSha: normalizeText(currentHeadSha) || null,
        currentHeadSha: normalizeText(currentHeadSha) || null,
        attempted: true,
        helperCall: `gh ${args.join(' ')}`,
        dryRunSummaryPath: readyProbe.summaryPath,
        reviewClearance: readyProbe.reviewClearance
      };
    }
  }
  if (!eligibility.eligible) {
    return {
      status: eligibility.status,
      reason: readyProbe?.reason
        ? `${eligibility.reason} Merge-sync dry-run readiness: ${readyProbe.reason}.`
        : eligibility.reason,
      receiptPath: readyValidationClearance.receiptPath,
      readyHeadSha:
        eligibility.readyHeadSha ?? (normalizeText(readyValidationClearance.receipt?.readyHeadSha) || null),
      currentHeadSha: normalizeText(currentHeadSha) || null,
      attempted: false,
      dryRunSummaryPath: readyProbe?.summaryPath ?? null,
      reviewClearance: readyProbe?.reviewClearance ?? null
    };
  }

  const args = buildPrReadyArgs({
    repository,
    pullRequestNumber: pullRequest.number,
    ready: true
  });
  try {
    runFn('gh', args, { cwd: repoRoot });
    return {
      status: 'ready',
      reason: 'Marked the PR ready for review from stored ready-validation clearance.',
      receiptPath: readyValidationClearance.receiptPath,
      readyHeadSha: eligibility.readyHeadSha ?? null,
      currentHeadSha: normalizeText(currentHeadSha) || null,
      attempted: true,
      helperCall: `gh ${args.join(' ')}`,
      dryRunSummaryPath: null,
      reviewClearance: null
    };
  } catch (error) {
    return {
      status: 'transition-failed',
      reason: normalizeText(error?.stderr) || normalizeText(error?.message) || String(error),
      receiptPath: readyValidationClearance.receiptPath,
      readyHeadSha: eligibility.readyHeadSha ?? null,
      currentHeadSha: normalizeText(currentHeadSha) || null,
      attempted: true,
      helperCall: `gh ${args.join(' ')}`,
      dryRunSummaryPath: null,
      reviewClearance: null
    };
  }
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

function extractIssueTitle(cache) {
  const value = cache?.title ?? cache?.issue?.title;
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function extractIssueUrl(cache, mirrorOf = null) {
  if (typeof mirrorOf?.url === 'string' && mirrorOf.url.trim()) {
    return mirrorOf.url.trim();
  }
  const value = cache?.url ?? cache?.issue?.url;
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function extractLocalIssueUrl(cache) {
  const value = cache?.url ?? cache?.issue?.url;
  return typeof value === 'string' && value.trim() ? value.trim() : null;
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
  const mirrorOf =
    cache?.mirrorOf &&
    Number.isInteger(Number(cache.mirrorOf.number)) &&
    Number(cache.mirrorOf.number) > 0
      ? {
          number: Number(cache.mirrorOf.number),
          repository: typeof cache.mirrorOf.repository === 'string' ? cache.mirrorOf.repository : null,
          url: typeof cache.mirrorOf.url === 'string' ? cache.mirrorOf.url : null
        }
      : null;
  const localIssueNumber =
    router && Object.prototype.hasOwnProperty.call(router, 'issue')
      ? parseRouterIssueNumber(router)
      : parseCacheIssueNumber(cache);
  const cacheIssueNumber = parseCacheIssueNumber(cache);
  const shouldUseCachedMetadata =
    Boolean(cacheIssueNumber) &&
    ((localIssueNumber && cacheIssueNumber === localIssueNumber) ||
      (mirrorOf?.number && cacheIssueNumber === mirrorOf.number));
  const issueTitle = shouldUseCachedMetadata ? extractIssueTitle(cache) : null;
  const issueUrl = shouldUseCachedMetadata ? extractIssueUrl(cache, mirrorOf) : null;
  if (router && Object.prototype.hasOwnProperty.call(router, 'issue')) {
    if (!localIssueNumber) {
      return {
        issueNumber: null,
        localIssueNumber: null,
        issueTitle: null,
        issueUrl: null,
        localIssueUrl: null,
        canonicalIssueUrl: null,
        source: 'router',
        noStandingReason,
        mirrorOf: null
      };
    }

    return {
      issueNumber: mirrorOf?.number ?? localIssueNumber,
      localIssueNumber,
      issueTitle,
      issueUrl,
      localIssueUrl: shouldUseCachedMetadata ? extractLocalIssueUrl(cache) : null,
      canonicalIssueUrl: issueUrl,
      source: 'router',
      noStandingReason,
      mirrorOf
    };
  }

  return {
    issueNumber: mirrorOf?.number ?? localIssueNumber,
    localIssueNumber,
    issueTitle,
    issueUrl,
    localIssueUrl: extractLocalIssueUrl(cache),
    canonicalIssueUrl: issueUrl,
    source: 'cache',
    noStandingReason,
    mirrorOf
  };
}

export function parseIssueNumberFromBranch(branch) {
  const normalized = normalizeText(branch);
  if (!normalized.toLowerCase().startsWith('issue/')) {
    return null;
  }
  const suffix = normalized.slice('issue/'.length);
  const tokens = suffix.split('-').map((entry) => entry.trim()).filter(Boolean);
  for (const token of tokens) {
    const issueNumber = toPositiveInteger(token);
    if (issueNumber) {
      return issueNumber;
    }
  }
  return null;
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

function normalizePrBodyContext(issueOrContext) {
  if (issueOrContext && typeof issueOrContext === 'object' && !Array.isArray(issueOrContext)) {
    return {
      issueNumber: toPositiveInteger(issueOrContext.issueNumber ?? issueOrContext.issue ?? null),
      issueTitle: typeof issueOrContext.issueTitle === 'string' ? issueOrContext.issueTitle.trim() : '',
      issueUrl: typeof issueOrContext.issueUrl === 'string' ? issueOrContext.issueUrl.trim() : '',
      branch: typeof issueOrContext.branch === 'string' ? issueOrContext.branch.trim() : '',
      base: typeof issueOrContext.base === 'string' ? issueOrContext.base.trim() : ''
    };
  }

  return {
    issueNumber: toPositiveInteger(issueOrContext),
    issueTitle: '',
    issueUrl: '',
    branch: '',
    base: ''
  };
}

function formatIssueReference(issueNumber, issueTitle = '') {
  if (!issueNumber) {
    return 'Not linked yet';
  }
  const titleSuffix = issueTitle ? ` - ${issueTitle}` : '';
  return `#${issueNumber}${titleSuffix}`;
}

function buildSummaryLine(context, base) {
  const issueReference = formatIssueReference(context.issueNumber, context.issueTitle);
  if (context.issueNumber) {
    return `Delivers issue ${issueReference} into \`${base}\` using the standard automation PR helper.`;
  }
  return `Delivers branch \`${context.branch || '(not supplied)'}\` into \`${base}\` using the standard automation PR helper.`;
}

function renderFallbackAutomationBody(context, base) {
  const issueReference = formatIssueReference(context.issueNumber, context.issueTitle);
  const lines = [
    '# Summary',
    '',
    buildSummaryLine(context, base),
    '',
    '## Agent Metadata (required for automation-authored PRs)',
    '',
    '- Agent-ID: `agent/copilot-codex-a`',
    '- Operator: `@svelderrainruiz`',
    '- Reviewer-Required: `@svelderrainruiz`',
    '- Emergency-Bypass-Label: `AllowCIBypass`',
    '',
    '## Change Surface',
    '',
    `- Primary issue or standing-priority context: ${issueReference}`,
    `- Issue URL: ${context.issueUrl || '(not supplied)'}`,
    `- Files, tools, workflows, or policies touched: Helper-driven PR creation path for \`${context.branch || '(not supplied)'}\`.`,
    `- Required checks, merge-queue behavior, or approval flows affected: Standard \`${base}\` branch protections and required checks apply.`
  ];
  return lines.join('\n').trimEnd();
}

function renderDefaultAutomationTemplate(templateText, context, base) {
  const issueReference = formatIssueReference(context.issueNumber, context.issueTitle);
  const issueUrl = context.issueUrl || '(not supplied)';
  const branch = context.branch || '(not supplied)';
  const lines = String(templateText || '').replace(/\r\n/g, '\n').split('\n');
  const rendered = [];
  let inSummarySection = false;
  let summaryInserted = false;

  for (const line of lines) {
    if (line === '# Summary') {
      rendered.push(line, '', buildSummaryLine(context, base));
      inSummarySection = true;
      summaryInserted = true;
      continue;
    }

    if (inSummarySection) {
      if (line.startsWith('## ')) {
        inSummarySection = false;
        rendered.push('', line);
        continue;
      }
      continue;
    }

    if (line.startsWith('- Primary issue or standing-priority context:')) {
      rendered.push(`- Primary issue or standing-priority context: ${issueReference}`);
      rendered.push(`- Issue URL: ${issueUrl}`);
      continue;
    }
    if (line.startsWith('- Files, tools, workflows, or policies touched:')) {
      rendered.push(`- Files, tools, workflows, or policies touched: Helper-driven PR creation path for \`${branch}\`.`);
      continue;
    }
    if (line.startsWith('- Cross-repo or external-consumer impact:')) {
      rendered.push('- Cross-repo or external-consumer impact: None expected at PR creation time.');
      continue;
    }
    if (line.startsWith('- Required checks, merge-queue behavior, or approval flows affected:')) {
      rendered.push(`- Required checks, merge-queue behavior, or approval flows affected: Standard \`${base}\` branch protections and required checks apply.`);
      continue;
    }
    if (line.trim() === '- `node tools/npm/run-script.mjs <script>`') {
      rendered.push('  - None yet; this body was generated during PR creation.');
      continue;
    }
    if (line.trim() === '- `tests/results/...`') {
      rendered.push('  - None yet.');
      continue;
    }
    if (line.trim() === '- None or explain why') {
      rendered.push('  - Validation is deferred until implementation commits land on the branch.');
      continue;
    }
    if (line.startsWith('- Residual risks:')) {
      rendered.push('- Residual risks: This body should be refreshed if the branch scope changes materially before merge.');
      continue;
    }
    if (line.startsWith('- Follow-up issues or deferred work:')) {
      rendered.push('- Follow-up issues or deferred work: None at PR creation time.');
      continue;
    }
    if (line.startsWith('- Deployment, approval, or rollback notes:')) {
      rendered.push('- Deployment, approval, or rollback notes: Standard PR review and required-check flow.');
      continue;
    }
    if (line.startsWith('- Please verify:')) {
      rendered.push('- Please verify: issue linkage, branch/base selection, and metadata routing are correct.');
      continue;
    }
    if (line.startsWith('- Areas where the reasoning is subtle:')) {
      rendered.push('- Areas where the reasoning is subtle: None at PR creation time.');
      continue;
    }
    if (line.startsWith('- Manual spot checks requested:')) {
      rendered.push('- Manual spot checks requested: None.');
      continue;
    }

    rendered.push(line);
  }

  if (!summaryInserted) {
    rendered.unshift('# Summary', '', buildSummaryLine(context, base), '');
  }

  return rendered.join('\n').trimEnd();
}

export function buildBody(issueOrContext, env = process.env, { repoRoot = process.cwd(), readFileSyncFn = readFileSync } = {}) {
  if (env.PR_BODY) {
    return env.PR_BODY;
  }
  const context = normalizePrBodyContext(issueOrContext);
  const base = context.base || env.PR_BASE || 'develop';
  const closesLine = context.issueNumber ? `\n\nCloses #${context.issueNumber}` : '';

  try {
    const templateText = readFileSyncFn(path.join(repoRoot, DEFAULT_PR_TEMPLATE_RELATIVE_PATH), 'utf8');
    return `${renderDefaultAutomationTemplate(templateText, context, base)}${closesLine}`.trimEnd();
  } catch {
    return `${renderFallbackAutomationBody(context, base)}${closesLine}`.trimEnd();
  }
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
  return buildBody(
    {
      issueNumber,
      issueTitle: options.issueTitle ?? '',
      issueUrl: options.issueUrl ?? '',
      branch: options.branch ?? env.PR_BRANCH ?? '',
      base: options.base ?? env.PR_BASE ?? ''
    },
    env,
    {
      repoRoot: options.repoRoot ?? process.cwd(),
      readFileSyncFn
    }
  );
}

function loadPriorityPrBranchContract(
  repoRoot,
  {
    readFileSyncFn = readFileSync,
    loadBranchClassContractFn = loadBranchClassContract
  } = {}
) {
  const contractPath = path.join(repoRoot, DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH);
  const contract = loadBranchClassContractFn(repoRoot, {
    relativePath: DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH,
    readFileSyncFn
  });

  let rawText = null;
  try {
    rawText = readFileSyncFn(contractPath, 'utf8');
  } catch {
    rawText = JSON.stringify(contract);
  }

  return {
    contract,
    contractPath: DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH.replace(/\\/g, '/'),
    contractDigest: digestText(rawText)
  };
}

export function resolvePriorityPrBranchModel({
  repoRoot,
  branch,
  upstream,
  headRemote = null,
  headRemoteSource = null,
  headRepository = null,
  readFileSyncFn = readFileSync,
  loadBranchClassContractFn = loadBranchClassContract
}) {
  const { contract, contractPath, contractDigest } = loadPriorityPrBranchContract(repoRoot, {
    readFileSyncFn,
    loadBranchClassContractFn
  });
  const branchPlane = resolveRepositoryPlaneFromBranchName(branch, contract);
  const branchPlaneEntry = branchPlane ? findRepositoryPlaneEntry(contract, branchPlane) : null;
  const requiredHeadRemote =
    branchPlane === 'origin' || branchPlane === 'personal'
      ? branchPlane
      : null;

  if (requiredHeadRemote && headRemote && normalizeText(headRemote).toLowerCase() !== requiredHeadRemote) {
    throw new Error(
      `Branch '${branch}' resolves to the ${requiredHeadRemote} fork plane via ${contractPath}, but head remote '${headRemote}' was selected from ${headRemoteSource ?? 'unknown-source'}.`
    );
  }

  const headRepositorySlug = buildRepositorySlug(headRepository);
  const upstreamRepositorySlug = buildRepositorySlug(upstream);
  const classificationRepository =
    branchPlane === 'upstream'
      ? upstreamRepositorySlug
      : headRepositorySlug || upstreamRepositorySlug;
  const classification = classificationRepository
    ? classifyBranch({
        branch,
        contract,
        repository: classificationRepository
      })
    : null;

  if (normalizeText(branch).toLowerCase().startsWith('issue/') && !classification) {
    throw new Error(
      `Branch '${branch}' is not classified by ${contractPath}; update the branch contract or rename the lane before opening a PR.`
    );
  }

  if (classification && classification.prSourceAllowed !== true) {
    throw new Error(
      `Branch '${branch}' resolves to class '${classification.id}', which is not allowed as a PR source by ${contractPath}.`
    );
  }

  const resolvedRepositoryPlane = classification?.repositoryPlane
    ? normalizeText(classification.repositoryPlane).toLowerCase()
    : branchPlane;

  if (requiredHeadRemote && headRepositorySlug) {
    const headRepositoryPlane = resolveRepositoryPlane(headRepositorySlug, contract);
    if (headRepositoryPlane !== requiredHeadRemote) {
      throw new Error(
        `Head repository '${headRepositorySlug}' resolves to plane '${headRepositoryPlane}', but branch '${branch}' requires '${requiredHeadRemote}' according to ${contractPath}.`
      );
    }
  }

  return {
    contractPath,
    contractDigest,
    branchPlane: branchPlane ?? null,
    classificationRepository: classificationRepository ?? null,
    classification: classification
      ? {
          id: classification.id,
          repositoryRole: classification.repositoryRole,
          repositoryPlane: classification.repositoryPlane,
          matchedPattern: classification.matchedPattern,
          prSourceAllowed: classification.prSourceAllowed,
          prTargetAllowed: classification.prTargetAllowed,
          mergePolicy: classification.mergePolicy,
          purpose: classification.purpose
        }
      : null,
    laneBranchPrefix: normalizeText(branchPlaneEntry?.laneBranchPrefix) || null,
    selectedHeadRemote: headRemote ? normalizeText(headRemote).toLowerCase() : null,
    selectedHeadRemoteSource: headRemoteSource ?? null,
    requiredHeadRemote,
    repositoryPlane: resolvedRepositoryPlane ?? null
  };
}

export function createPriorityPr({
  env = process.env,
  options = {},
  readFileSyncFn = readFileSync,
  readJsonFn = readJsonFile,
  getRepoRootFn = getRepoRoot,
  getCurrentBranchFn = detectCurrentBranch,
  getCurrentHeadShaFn = detectCurrentHeadSha,
  ensureGhCliFn = ensureGhCli,
  resolveUpstreamFn = resolveUpstream,
  ensureForkRemoteFn = ensureForkRemote,
  pushBranchFn = pushBranch,
  runFn = run,
  runGhPrCreateFn = runGhPrCreate,
  runReadyProbeFn = probeReadyTransitionViaMergeSyncDryRun,
  admitToMergeQueueFn = maybeAdmitPullRequestToMergeQueue,
  findMergedPullRequestFn = findMergedPullRequest,
  findOpenAncestorPullRequestFn = findOpenAncestorPullRequest,
  resolveStandingIssueNumberFn = resolveStandingIssueNumberForPr,
  loadBranchClassContractFn = loadBranchClassContract
} = {}) {
  const repoRoot = getRepoRootFn();
  const branch = ensurePrSourceBranch(options.branch || getCurrentBranchFn(repoRoot));

  ensureGhCliFn();

  const resolvedIssue =
    options.issue && toPositiveInteger(options.issue)
      ? {
          issueNumber: toPositiveInteger(options.issue),
          localIssueNumber: toPositiveInteger(options.issue),
          source: 'cli',
          noStandingReason: null,
          mirrorOf: null
        }
      : resolveStandingIssueNumberFn(repoRoot);
  const issueNumber = resolvedIssue?.issueNumber ?? null;
  const localIssueNumber = resolvedIssue?.localIssueNumber ?? issueNumber;
  if (!issueNumber && resolvedIssue?.noStandingReason === 'queue-empty') {
    throw new Error('Standing-priority queue is empty; create or label the next issue before opening a priority PR.');
  }
  assertBranchMatchesIssue(branch, localIssueNumber);
  const upstream = options.repository ? parseRepositorySlug(options.repository) : resolveUpstreamFn(repoRoot);
  const initialBranchModel = resolvePriorityPrBranchModel({
    repoRoot,
    branch,
    upstream,
    headRemote: null,
    headRemoteSource: null,
    headRepository: null,
    readFileSyncFn,
    loadBranchClassContractFn
  });
  const inferredBranchPlane = initialBranchModel.branchPlane;
  const explicitHeadRemote = normalizeText(options.headRemote);
  const envHeadRemote = normalizeText(env.PR_HEAD_REMOTE);
  const activeForkRemote = normalizeText(env.AGENT_PRIORITY_ACTIVE_FORK_REMOTE);
  let headRemoteSource = 'default';
  let headRemote = null;
  if (explicitHeadRemote) {
    headRemote = normalizeForkRemoteName(explicitHeadRemote);
    headRemoteSource = 'cli';
  } else if (envHeadRemote) {
    headRemote = normalizeForkRemoteName(envHeadRemote);
    headRemoteSource = 'env:PR_HEAD_REMOTE';
  } else if (inferredBranchPlane === 'origin' || inferredBranchPlane === 'personal') {
    headRemote = inferredBranchPlane;
    headRemoteSource = 'branch-contract';
  } else if (activeForkRemote) {
    headRemote = normalizeForkRemoteName(activeForkRemote);
    headRemoteSource = 'env:AGENT_PRIORITY_ACTIVE_FORK_REMOTE';
  } else {
    headRemote = resolveActiveForkRemoteName(env);
  }
  resolvePriorityPrBranchModel({
    repoRoot,
    branch,
    upstream,
    headRemote,
    headRemoteSource,
    headRepository: null,
    readFileSyncFn,
    loadBranchClassContractFn
  });
  const headRepository = ensureForkRemoteFn(repoRoot, upstream, headRemote);
  const base = options.base || env.PR_BASE || 'develop';
  const branchModel = resolvePriorityPrBranchModel({
    repoRoot,
    branch,
    upstream,
    headRemote,
    headRemoteSource,
    headRepository,
    readFileSyncFn,
    loadBranchClassContractFn
  });
  const mergedPullRequest = findMergedPullRequestFn(repoRoot, {
    upstream,
    headRepository,
    branch,
    base
  });
  if (mergedPullRequest?.number) {
    const mergedReference = mergedPullRequest.url
      ? `#${mergedPullRequest.number} (${mergedPullRequest.url})`
      : `#${mergedPullRequest.number}`;
    throw new Error(
      `Branch '${branch}' already backed merged PR ${mergedReference} into '${base}'. ` +
        'Cut a fresh branch from develop before opening a follow-up PR so squash-merged history is not reused.'
    );
  }

  const pushResult = pushBranchFn(repoRoot, branch, headRemote);
  const headSha = normalizeText(getCurrentHeadShaFn(repoRoot)) || null;
  const title = options.title || buildTitle(branch, issueNumber, env);
  const body = resolveBody({
    options: {
      ...options,
      branch,
      base,
      issueTitle: resolvedIssue?.issueTitle ?? '',
      issueUrl: resolvedIssue?.issueUrl ?? '',
      repoRoot
    },
    issueNumber,
    env,
    readFileSyncFn
  });
  const stackedBasePullRequest = findOpenAncestorPullRequestFn(repoRoot, {
    upstream,
    headRepository,
    branch,
    base,
    headSha
  });
  if (stackedBasePullRequest?.number) {
    return {
      repoRoot,
      branch,
      base,
      issueNumber,
      localIssueNumber,
      issueUrl: resolvedIssue?.canonicalIssueUrl ?? resolvedIssue?.issueUrl ?? null,
      localIssueUrl: resolvedIssue?.localIssueUrl ?? null,
      issueSource: resolvedIssue?.source ?? null,
      mirrorOf: resolvedIssue?.mirrorOf ?? null,
      title,
      body,
      pushStatus: pushResult?.status ?? null,
      upstream,
      headRemote,
      headRepository,
      branchModel,
      strategy: 'await-base-pr',
      pullRequest: null,
      reusedExistingPullRequest: false,
      stackedFollowUp: {
        status: 'waiting-for-base-merge',
        currentHeadSha: headSha,
        basePullRequest: {
          number: stackedBasePullRequest.number ?? null,
          url: stackedBasePullRequest.url ?? null,
          headRefName: stackedBasePullRequest.headRefName ?? null,
          headRefOid: stackedBasePullRequest.headRefOid ?? null,
          baseRefName: stackedBasePullRequest.baseRefName ?? null,
          mergeStateStatus: stackedBasePullRequest.mergeStateStatus ?? null,
          isDraft: stackedBasePullRequest.isDraft ?? null,
          stackDistance: stackedBasePullRequest.stackDistance ?? null
        }
      }
    };
  }

  const prResult = runGhPrCreateFn({
    repoRoot,
    upstream,
    headRepository,
    branch,
    base,
    title,
    body,
    draft: options.draft === true
  });
  const readyTransition = maybePromotePullRequestToReady({
    repoRoot,
    upstream,
    strategy: prResult?.strategy ?? null,
    pullRequest: prResult?.pullRequest ?? null,
    currentHeadSha: headSha,
    readJsonFn,
    runFn,
    runReadyProbeFn
  });
  const pullRequest =
    readyTransition?.status === 'ready' && prResult?.pullRequest
      ? {
          ...prResult.pullRequest,
          isDraft: false
        }
      : prResult?.pullRequest ?? null;
  const queueAdmission = admitToMergeQueueFn({
    repoRoot,
    upstream,
    strategy: prResult?.strategy ?? null,
    pullRequest,
    readyTransition,
    readJsonFn
  });

  return {
    repoRoot,
    branch,
    base,
    issueNumber,
    localIssueNumber,
    issueUrl: resolvedIssue?.canonicalIssueUrl ?? resolvedIssue?.issueUrl ?? null,
    localIssueUrl: resolvedIssue?.localIssueUrl ?? null,
    issueSource: resolvedIssue?.source ?? null,
    mirrorOf: resolvedIssue?.mirrorOf ?? null,
    title,
    body,
    pushStatus: pushResult?.status ?? null,
    upstream,
    headRemote,
    headRepository,
    branchModel,
    currentHeadSha: headSha,
    strategy: prResult?.strategy ?? null,
    pullRequest,
    readyTransition,
    queueAdmission,
    reusedExistingPullRequest: prResult?.reusedExisting === true,
    stackedFollowUp: null
  };
}

export function buildPriorityPrReport(result, generatedAt = new Date().toISOString()) {
  const upstreamRepository =
    result.upstream?.owner && result.upstream?.repo ? `${result.upstream.owner}/${result.upstream.repo}` : null;
  const headRepository =
    result.headRepository?.owner && result.headRepository?.repo
      ? `${result.headRepository.owner}/${result.headRepository.repo}`
      : null;

  return {
    schema: 'priority/pr-create@v1',
    generatedAt,
    issue: {
      upstreamNumber: result.issueNumber ?? null,
      localNumber: result.localIssueNumber ?? null,
      source: result.issueSource ?? null,
      issueUrl: result.issueUrl ?? null,
      localIssueUrl: result.localIssueUrl ?? null,
      mirrorOf: result.mirrorOf ?? null
    },
    upstream: {
      repository: upstreamRepository
    },
    head: {
      remote: result.headRemote ?? null,
      repository: headRepository,
      branch: result.branch ?? null,
      currentHeadSha: result.currentHeadSha ?? null
    },
    laneIdentity: buildForkLaneIdentity({
      branch: result.branch ?? null,
      issueSource: result.issueSource ?? null,
      issueNumber: result.issueNumber ?? null,
      issueUrl: result.issueUrl ?? null,
      localIssueNumber: result.localIssueNumber ?? null,
      localIssueUrl: result.localIssueUrl ?? null,
      mirrorOf: result.mirrorOf ?? null,
      forkRemote: result.headRemote ?? null,
      forkRepository: headRepository,
      upstreamRepository,
      dispatchRepository: headRepository
    }),
    branchModel: result.branchModel
      ? {
          contractPath: result.branchModel.contractPath ?? null,
          contractDigest: result.branchModel.contractDigest ?? null,
          branchPlane: result.branchModel.branchPlane ?? null,
          repositoryPlane: result.branchModel.repositoryPlane ?? null,
          classificationRepository: result.branchModel.classificationRepository ?? null,
          laneBranchPrefix: result.branchModel.laneBranchPrefix ?? null,
          selectedHeadRemote: result.branchModel.selectedHeadRemote ?? null,
          selectedHeadRemoteSource: result.branchModel.selectedHeadRemoteSource ?? null,
          requiredHeadRemote: result.branchModel.requiredHeadRemote ?? null,
          classification: result.branchModel.classification
        }
      : null,
    base: result.base ?? null,
    pushStatus: result.pushStatus ?? null,
    strategy: result.strategy ?? null,
    reusedExistingPullRequest: result.reusedExistingPullRequest === true,
    readyTransition: result.readyTransition
      ? {
          status: result.readyTransition.status ?? null,
          reason: result.readyTransition.reason ?? null,
          attempted: result.readyTransition.attempted === true,
          helperCall: result.readyTransition.helperCall ?? null,
          receiptPath: result.readyTransition.receiptPath ?? null,
          readyHeadSha: result.readyTransition.readyHeadSha ?? null,
          currentHeadSha: result.readyTransition.currentHeadSha ?? null,
          dryRunSummaryPath: result.readyTransition.dryRunSummaryPath ?? null,
          reviewClearance: result.readyTransition.reviewClearance ?? null
        }
      : null,
    queueAdmission: result.queueAdmission
      ? {
          status: result.queueAdmission.status ?? null,
          reason: result.queueAdmission.reason ?? null,
          attempted: result.queueAdmission.attempted === true,
          helperCall: result.queueAdmission.helperCall ?? null,
          summaryPath: result.queueAdmission.summaryPath ?? null,
          promotion: result.queueAdmission.promotion ?? null
        }
      : null,
    stackedFollowUp: result.stackedFollowUp
      ? {
          status: result.stackedFollowUp.status ?? null,
          currentHeadSha: result.stackedFollowUp.currentHeadSha ?? null,
          basePullRequest: result.stackedFollowUp.basePullRequest
            ? {
                number: result.stackedFollowUp.basePullRequest.number ?? null,
                url: result.stackedFollowUp.basePullRequest.url ?? null,
                headRefName: result.stackedFollowUp.basePullRequest.headRefName ?? null,
                headRefOid: result.stackedFollowUp.basePullRequest.headRefOid ?? null,
                baseRefName: result.stackedFollowUp.basePullRequest.baseRefName ?? null,
                mergeStateStatus: result.stackedFollowUp.basePullRequest.mergeStateStatus ?? null,
                isDraft: result.stackedFollowUp.basePullRequest.isDraft ?? null,
                stackDistance: result.stackedFollowUp.basePullRequest.stackDistance ?? null
              }
            : null
        }
      : null,
    pullRequest: result.pullRequest
      ? {
          number: result.pullRequest.number ?? null,
          url: result.pullRequest.url ?? null,
          isDraft: result.pullRequest.isDraft ?? null
        }
      : null
  };
}

export function writePriorityPrReport(
  result,
  {
    reportDir = DEFAULT_REPORT_DIR,
    mkdirSyncFn = mkdirSync,
    writeFileSyncFn = writeFileSync,
    getNow = () => new Date().toISOString()
  } = {}
) {
  const repoRoot = result?.repoRoot || process.cwd();
  const resolvedReportDir = path.isAbsolute(reportDir) ? reportDir : path.join(repoRoot, reportDir);
  const fileIssueNumber = result?.localIssueNumber ?? result?.issueNumber ?? 'branch';
  const fileRemote = String(result?.headRemote || 'origin').replace(/[^a-z0-9._-]/gi, '-');
  const reportPath = path.join(resolvedReportDir, `priority-pr-create-${fileRemote}-${fileIssueNumber}.json`);
  const report = buildPriorityPrReport(result, getNow());
  mkdirSyncFn(resolvedReportDir, { recursive: true });
  writeFileSyncFn(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return { report, reportPath };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const result = createPriorityPr({ options });
  const reportResult = writePriorityPrReport(result, { reportDir: options.reportDir });
  if (result?.strategy) {
    console.log(`[priority:create-pr] strategy=${result.strategy}`);
  }
  if (result?.readyTransition?.status) {
    console.log(`[priority:create-pr] ready-transition=${result.readyTransition.status}`);
  }
  if (result?.queueAdmission?.status) {
    console.log(`[priority:create-pr] queue-admission=${result.queueAdmission.status}`);
  }
  console.log(`[priority:create-pr] report=${reportResult.reportPath}`);
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

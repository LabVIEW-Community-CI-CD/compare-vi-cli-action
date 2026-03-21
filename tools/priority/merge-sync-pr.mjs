#!/usr/bin/env node

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { runCopilotReviewGate } from './copilot-review-gate.mjs';
import { ensureGhCli, resolveUpstream, runGhJson } from './lib/remote-utils.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';
import {
  DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH,
  assertPlaneTransition,
  classifyBranch,
  loadBranchClassContract,
  resolveRepositoryPlane,
  resolveRepositoryRole
} from './lib/branch-classification.mjs';

const manifestPath = new URL('./policy.json', import.meta.url);
const DELIVERY_AGENT_POLICY_RELATIVE_PATH = path.join('tools', 'priority', 'delivery-agent.policy.json');
const DEFAULT_COPILOT_REVIEW_STRATEGY = 'github-review-required';
const LOCAL_ONLY_COPILOT_REVIEW_STRATEGY = 'draft-only-explicit';

const USAGE_LINES = [
  'Usage: node tools/priority/merge-sync-pr.mjs --pr <number> [options]',
  '',
  'Options:',
  '  --pr <number>            Pull request number to merge (required)',
  '  --repo <owner/repo>      Target repository (defaults to upstream remote)',
  '  --method <merge|squash|rebase>',
  '                           Merge method override (default: repository-aware selection preferring squash)',
  '  --admin                  Explicitly use admin merge override',
  '  --keep-branch            Keep head branch after merge (default cleanup is inline for direct merges and post-merge for queue-managed/--auto flows)',
  '  --dry-run                Print selected mode and merge command without executing',
  '  --summary-path <path>    Write JSON summary payload including promotion and branchCleanup state',
  '  -h, --help               Show this message and exit'
];

const MERGE_METHODS = new Set(['merge', 'squash', 'rebase']);
const MERGE_METHOD_FALLBACK_ORDER = ['squash', 'rebase', 'merge'];
const MERGE_ACTIVATION_POLL_ATTEMPTS = 5;
const MERGE_ACTIVATION_POLL_DELAY_MS = 1500;
const PROMOTION_REVIEW_GATE_POLL_ATTEMPTS = 1;
const PROMOTION_REVIEW_GATE_POLL_DELAY_MS = 1000;
const POLICY_BLOCK_PATTERNS = [
  /merge queue/i,
  /required checks?.*not (?:passing|successful|complete)/i,
  /required status checks?.*pending/i,
  /base branch policy/i,
  /protected branch/i,
  /cannot be merged automatically/i
];

function sanitizeSegment(value) {
  return String(value || '')
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'runtime';
}

function printUsage() {
  for (const line of USAGE_LINES) {
    console.log(line);
  }
}

function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    pr: null,
    repo: null,
    method: 'squash',
    methodExplicit: false,
    admin: false,
    keepBranch: false,
    dryRun: false,
    summaryPath: null
  };

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '-h' || arg === '--help') {
      printUsage();
      process.exit(0);
    }
    if (arg === '--admin') {
      options.admin = true;
      continue;
    }
    if (arg === '--keep-branch') {
      options.keepBranch = true;
      continue;
    }
    if (arg === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (arg === '--pr' || arg === '--repo' || arg === '--method' || arg === '--summary-path') {
      const value = args[i + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${arg}`);
      }
      i += 1;
      if (arg === '--pr') {
        const parsed = Number(value);
        if (!Number.isInteger(parsed) || parsed <= 0) {
          throw new Error(`Invalid --pr value '${value}'. Expected positive integer.`);
        }
        options.pr = parsed;
      } else if (arg === '--repo') {
        parseRepoSlug(value);
        options.repo = value;
      } else if (arg === '--method') {
        if (!MERGE_METHODS.has(value)) {
          throw new Error(`Invalid --method '${value}'. Expected one of: ${Array.from(MERGE_METHODS).join(', ')}`);
        }
        options.method = value;
        options.methodExplicit = true;
      } else if (arg === '--summary-path') {
        options.summaryPath = value;
      }
      continue;
    }

    throw new Error(`Unknown option: ${arg}`);
  }

  if (!options.pr) {
    printUsage();
    throw new Error('Missing required option --pr <number>.');
  }

  return options;
}

function normalizeUpper(value) {
  return typeof value === 'string' ? value.toUpperCase() : '';
}

function normalizeLower(value) {
  return typeof value === 'string' ? value.toLowerCase() : '';
}

function normalizeText(value) {
  return typeof value === 'string' ? value.trim() : '';
}

export function normalizeCopilotReviewStrategy(value) {
  const normalized = normalizeText(value) || DEFAULT_COPILOT_REVIEW_STRATEGY;
  if (normalized === DEFAULT_COPILOT_REVIEW_STRATEGY || normalized === LOCAL_ONLY_COPILOT_REVIEW_STRATEGY) {
    return normalized;
  }
  throw new Error(`Unsupported copilotReviewStrategy: ${normalized}`);
}

function normalizeOwner(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

function parseRepoSlug(repo) {
  const parts = String(repo ?? '')
    .split('/')
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length !== 2) {
    throw new Error(`Invalid repo slug '${repo}'. Expected owner/repo.`);
  }
  const [owner, name] = parts;
  return { owner, name };
}

export async function loadMergeSyncCopilotReviewStrategy({
  repoRoot = getRepoRoot(),
  readFileFn = readFile
} = {}) {
  const policyPath = path.join(repoRoot, DELIVERY_AGENT_POLICY_RELATIVE_PATH);
  try {
    const payload = JSON.parse(await readFileFn(policyPath, 'utf8'));
    return normalizeCopilotReviewStrategy(payload?.copilotReviewStrategy);
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return DEFAULT_COPILOT_REVIEW_STRATEGY;
    }
    throw error;
  }
}

export function normalizeBaseRefName(value) {
  const lowered = normalizeLower(value).trim();
  if (!lowered) {
    return '';
  }
  const refsPrefix = 'refs/heads/';
  if (lowered.startsWith(refsPrefix)) {
    return lowered.substring(refsPrefix.length);
  }
  return lowered;
}

export function isQueueManagedBaseBranch({ baseRefName = '', mergeQueueBranches = new Set(), baseBranchClass = null } = {}) {
  if (baseBranchClass?.mergePolicy === 'merge-queue-squash') {
    return true;
  }
  const normalizedBaseRefName = normalizeBaseRefName(baseRefName);
  if (!normalizedBaseRefName) {
    return false;
  }
  return mergeQueueBranches.has(normalizedBaseRefName);
}

export function resolveBranchCleanupPlan({
  keepBranch = false,
  mode = 'auto',
  baseRefName = '',
  mergeQueueBranches = new Set(),
  baseBranchClass = null
} = {}) {
  if (keepBranch) {
    return {
      requested: false,
      inlineDeleteBranch: false,
      postMergeDelete: false,
      reason: 'keep-branch'
    };
  }

  if (mode === 'auto') {
    return {
      requested: true,
      inlineDeleteBranch: false,
      postMergeDelete: true,
      reason: 'post-merge-api-delete'
    };
  }

  if (isQueueManagedBaseBranch({ baseRefName, mergeQueueBranches, baseBranchClass })) {
    return {
      requested: true,
      inlineDeleteBranch: false,
      postMergeDelete: true,
      reason: 'post-merge-api-delete'
    };
  }

  return {
    requested: true,
    inlineDeleteBranch: true,
    postMergeDelete: false,
    reason: 'inline-gh-delete-branch'
  };
}

export function resolveReadyValidationClearancePath({ repoRoot, repo, pr }) {
  const repositorySegment = sanitizeSegment(repo || 'repo');
  const pullRequestSegment = sanitizeSegment(`pr-${pr || 'unknown'}`);
  return path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'runtime',
    'ready-validation-clearance',
    `${repositorySegment}-${pullRequestSegment}.json`
  );
}

export async function loadReadyValidationClearance({
  repoRoot,
  repo,
  pr,
  readFileFn = readFile
}) {
  const receiptPath = resolveReadyValidationClearancePath({ repoRoot, repo, pr });
  try {
    const payload = JSON.parse(await readFileFn(receiptPath, 'utf8'));
    return {
      receiptPath,
      receipt: payload && typeof payload === 'object' ? payload : null
    };
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return {
        receiptPath,
        receipt: null
      };
    }
    throw new Error(`Unable to read ready-validation clearance at ${receiptPath}: ${error.message}`);
  }
}

export function getMergeQueueBranches(policy) {
  const branches = new Set();
  const rulesets = policy?.rulesets;
  if (!rulesets || typeof rulesets !== 'object') {
    return branches;
  }

  for (const ruleset of Object.values(rulesets)) {
    if (!ruleset?.merge_queue) {
      continue;
    }
    const includes = Array.isArray(ruleset.includes) ? ruleset.includes : [];
    for (const ref of includes) {
      if (typeof ref !== 'string') {
        continue;
      }
      const match = ref.match(/^refs\/heads\/(.+)$/i);
      if (match && match[1] && !match[1].includes('*')) {
        branches.add(match[1].toLowerCase());
      }
    }
  }

  return branches;
}

export function buildPolicyTrace(mergeQueueBranches = new Set()) {
  return {
    manifestPath: 'tools/priority/policy.json',
    mergeQueueBranches: Array.from(mergeQueueBranches).sort()
  };
}

export function buildBranchClassTrace({ targetRepositoryRole = null, baseBranchClass = null } = {}) {
  return {
    contractPath: DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH.replace(/\\/g, '/'),
    targetRepositoryRole,
    baseBranchClassId: baseBranchClass?.id ?? null,
    baseBranchMergePolicy: baseBranchClass?.mergePolicy ?? null,
    baseBranchPattern: baseBranchClass?.matchedPattern ?? null
  };
}

function resolveHeadRepositorySlug(prInfo = {}, repo = '') {
  const owner = resolveHeadRepositoryOwner(prInfo);
  const repoName = normalizeText(prInfo?.headRepository?.name);
  if (!owner || !repoName) {
    return '';
  }
  return `${owner}/${repoName}`;
}

export function resolveHeadRepositoryOwner(prInfo = {}) {
  const owner = prInfo?.headRepositoryOwner;
  if (typeof owner === 'string') {
    return normalizeOwner(owner);
  }
  if (owner && typeof owner === 'object' && typeof owner.login === 'string') {
    return normalizeOwner(owner.login);
  }
  return '';
}

export function isUpstreamOwnedHead(prInfo = {}, repo = '') {
  const expectedOwner = normalizeOwner(String(repo).split('/')[0] ?? '');
  if (!expectedOwner) {
    return false;
  }
  return resolveHeadRepositoryOwner(prInfo) === expectedOwner;
}

export function assertUpstreamOwnedHead(prInfo = {}, repo = '') {
  return isUpstreamOwnedHead(prInfo, repo);
}

export function buildMergeSummaryPayload({
  repo,
  pr,
  mergeMethod,
  mergeMethodSelection = null,
  selectedMode,
  selectedReason,
  finalMode,
  finalReason,
  dryRun,
  mergeQueueBranches,
  attempts,
  prInfo,
  branchClassTrace = null,
  reviewClearance = null,
  branchCleanup = null,
  promotion = null,
  planeTransition = null,
  createdAt = new Date().toISOString()
}) {
  const normalizedBaseRefName = normalizeBaseRefName(prInfo?.baseRefName);
  const headRepositoryOwner = resolveHeadRepositoryOwner(prInfo) || null;
  return {
    schema: 'priority/sync-merge@v1',
    createdAt,
    repo,
    pr,
    mergeMethod,
    mergeMethodSelection,
    selectedMode,
    selectedReason,
    finalMode,
    finalReason,
    dryRun,
    policyTrace: buildPolicyTrace(mergeQueueBranches),
    branchClassTrace,
    attempts,
    reviewClearance,
    branchCleanup,
    prState: {
      state: prInfo?.state ?? null,
      mergeStateStatus: prInfo?.mergeStateStatus ?? null,
      mergeable: prInfo?.mergeable ?? null,
      baseRefName: normalizedBaseRefName || null,
      isDraft: Boolean(prInfo?.isDraft),
      headRefName: prInfo?.headRefName ?? null,
      headRefOid: prInfo?.headRefOid ?? null,
      headRepositoryOwner,
      isCrossRepository: Boolean(prInfo?.isCrossRepository),
      upstreamHeadOwned: isUpstreamOwnedHead(prInfo, repo)
    },
    promotion,
    planeTransition,
    prUrl: prInfo?.url ?? null
  };
}

export function classifyPromotionState(initialState = {}, finalState = {}, { finalMode = 'auto' } = {}) {
  const initialQueued = Boolean(initialState?.isInMergeQueue);
  const finalQueued = Boolean(finalState?.isInMergeQueue);
  const initialAutoMerge = Boolean(initialState?.autoMergeRequest);
  const finalAutoMerge = Boolean(finalState?.autoMergeRequest);
  const finalMerged = normalizeUpper(finalState?.state) === 'MERGED';

  let status = 'unchanged';
  let materialized = false;

  if (finalMerged) {
    status = normalizeUpper(initialState?.state) === 'MERGED' ? 'already-merged' : 'merged';
    materialized = true;
  } else if (finalQueued) {
    status = initialQueued ? 'already-queued' : 'queued';
    materialized = true;
  } else if (finalAutoMerge) {
    status = initialAutoMerge ? 'already-auto-merge-enabled' : 'auto-merge-enabled';
    materialized = true;
  } else if (finalMode === 'none' && normalizeUpper(initialState?.state) === 'MERGED') {
    status = 'already-merged';
    materialized = true;
  }

  return {
    status,
    materialized,
    finalMode,
    initial: {
      state: initialState?.state ?? null,
      mergeStateStatus: initialState?.mergeStateStatus ?? null,
      isInMergeQueue: Boolean(initialState?.isInMergeQueue),
      autoMergeEnabled: Boolean(initialState?.autoMergeRequest),
      mergedAt: initialState?.mergedAt ?? null
    },
    final: {
      state: finalState?.state ?? null,
      mergeStateStatus: finalState?.mergeStateStatus ?? null,
      isInMergeQueue: Boolean(finalState?.isInMergeQueue),
      autoMergeEnabled: Boolean(finalState?.autoMergeRequest),
      mergedAt: finalState?.mergedAt ?? null
    }
  };
}

export function selectMergeMode(prInfo, { admin = false, mergeQueueBranches = new Set(), baseBranchClass = null } = {}) {
  const state = normalizeUpper(prInfo?.state);
  const mergeState = normalizeUpper(prInfo?.mergeStateStatus);
  const mergeable = normalizeUpper(prInfo?.mergeable);
  const baseRefName = normalizeBaseRefName(prInfo?.baseRefName);
  const isDraft = Boolean(prInfo?.isDraft);

  if (state === 'MERGED') {
    return { mode: 'none', reason: 'already-merged' };
  }
  if (state && state !== 'OPEN') {
    throw new Error(`PR state ${state} is not mergeable.`);
  }
  if (admin) {
    return { mode: 'admin', reason: 'explicit-admin-override' };
  }
  if (isDraft || mergeState === 'DRAFT') {
    return { mode: 'auto', reason: 'draft-pr' };
  }
  if (mergeState === 'DIRTY' || mergeable === 'CONFLICTING') {
    throw new Error('PR has merge conflicts (DIRTY/CONFLICTING). Resolve conflicts before merge automation.');
  }
  if (mergeable === 'UNMERGEABLE') {
    throw new Error('PR is UNMERGEABLE. Resolve branch/ruleset blockers before merge automation.');
  }

  if (baseBranchClass?.mergePolicy === 'merge-queue-squash') {
    return { mode: 'auto', reason: `merge-queue-branch-${baseRefName || baseBranchClass.id}` };
  }

  if (!baseBranchClass && baseRefName && mergeQueueBranches.has(baseRefName)) {
    return { mode: 'auto', reason: `merge-queue-branch-${baseRefName}` };
  }

  if (mergeState === 'CLEAN' && (mergeable === 'MERGEABLE' || mergeable === '')) {
    return { mode: 'direct', reason: 'clean-mergeable' };
  }

  if (mergeState === 'UNKNOWN') {
    return { mode: 'auto', reason: 'unknown-merge-state' };
  }

  if (mergeState === 'BLOCKED' || mergeState === 'BEHIND' || mergeState === 'HAS_HOOKS' || mergeState === 'UNSTABLE') {
    return { mode: 'auto', reason: `merge-state-${mergeState.toLowerCase()}` };
  }

  return { mode: 'auto', reason: mergeState ? `merge-state-${mergeState.toLowerCase()}` : 'merge-state-unspecified' };
}

export function shouldRetryWithAuto({ mode, stdout = '', stderr = '' } = {}) {
  if (mode !== 'direct') {
    return false;
  }
  const combined = `${stdout}\n${stderr}`;
  return POLICY_BLOCK_PATTERNS.some((pattern) => pattern.test(combined));
}

function parseJsonOutput(raw, { label }) {
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Unable to parse ${label}: ${error.message}`);
  }
}

function readPrInfo({ repoRoot, repo, pr }) {
  const result = spawnSync(
    'gh',
    [
      'pr',
      'view',
      String(pr),
      '--repo',
      repo,
      '--json',
      'number,state,isDraft,mergeStateStatus,mergeable,baseRefName,url,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository'
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );
  if (result.status !== 0) {
    const combined = `${result.stderr ?? ''}${result.stdout ?? ''}`.trim();
    throw new Error(`gh pr view failed for #${pr}: ${combined || `exit ${result.status}`}`);
  }
  return parseJsonOutput(result.stdout ?? '{}', { label: 'gh pr view output' });
}

function readPromotionState({ repoRoot, repo, pr }) {
  const { owner, name } = parseRepoSlug(repo);
  const query = [
    'query($owner:String!, $name:String!, $pr:Int!) {',
    '  repository(owner:$owner, name:$name) {',
    '    pullRequest(number:$pr) {',
    '      state',
    '      mergeStateStatus',
    '      isInMergeQueue',
    '      mergedAt',
    '      autoMergeRequest {',
    '        enabledAt',
    '      }',
    '    }',
    '  }',
    '}'
  ].join('\n');
  const result = spawnSync(
    'gh',
    ['api', 'graphql', '-f', `query=${query}`, '-F', `owner=${owner}`, '-F', `name=${name}`, '-F', `pr=${pr}`],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );
  if (result.status !== 0) {
    const combined = `${result.stderr ?? ''}${result.stdout ?? ''}`.trim();
    throw new Error(`gh api graphql failed for PR #${pr}: ${combined || `exit ${result.status}`}`);
  }
  const payload = parseJsonOutput(result.stdout ?? '{}', { label: 'gh api graphql output' });
  return payload?.data?.repository?.pullRequest ?? {};
}

export async function evaluatePromotionReviewClearance({
  repoRoot = getRepoRoot(),
  repo,
  pr,
  prInfo,
  copilotReviewStrategy = DEFAULT_COPILOT_REVIEW_STRATEGY,
  runCopilotReviewGateFn = runCopilotReviewGate,
  readReadyValidationClearanceFn = loadReadyValidationClearance,
  pollAttempts = PROMOTION_REVIEW_GATE_POLL_ATTEMPTS,
  pollDelayMs = PROMOTION_REVIEW_GATE_POLL_DELAY_MS
}) {
  const currentHeadSha = normalizeText(prInfo?.headRefOid);
  const readyValidationClearance = await readReadyValidationClearanceFn({
    repoRoot,
    repo,
    pr
  });
  const stored = readyValidationClearance?.receipt ?? null;
  const storedStatus = normalizeLower(stored?.status);
  const storedReadyHeadSha = normalizeText(stored?.readyHeadSha);
  const storedCurrentHeadSha = normalizeText(stored?.currentHeadSha);

  if (stored && storedReadyHeadSha && storedStatus === 'current' && currentHeadSha && storedReadyHeadSha === currentHeadSha) {
    return {
      ok: true,
      report: {
        status: 'pass',
        gateState: 'ready',
        reasons: ['stored-ready-validation-clearance-current-head'],
        actionableCommentCount: 0,
        actionableThreadCount: 0,
        hasCurrentHeadReview: false,
        latestReviewIsCurrentHead: false,
        reviewRunCompletedClean: false,
        source: 'stored-ready-validation-clearance',
        receiptPath: readyValidationClearance.receiptPath,
        readyHeadSha: storedReadyHeadSha,
        currentHeadSha,
        staleForCurrentHead: false
      }
    };
  }

  if (stored && storedReadyHeadSha && currentHeadSha && storedReadyHeadSha !== currentHeadSha) {
    return {
      ok: false,
      report: {
        status: 'fail',
        gateState: 'blocked',
        reasons: ['stored-ready-validation-clearance-stale-head'],
        actionableCommentCount: 0,
        actionableThreadCount: 0,
        hasCurrentHeadReview: false,
        latestReviewIsCurrentHead: false,
        reviewRunCompletedClean: false,
        source: 'stored-ready-validation-clearance',
        receiptPath: readyValidationClearance.receiptPath,
        readyHeadSha: storedReadyHeadSha,
        currentHeadSha,
        staleForCurrentHead: true
      }
    };
  }

  if (stored && storedStatus && storedStatus !== 'current') {
    return {
      ok: false,
      report: {
        status: 'fail',
        gateState: 'blocked',
        reasons: ['stored-ready-validation-clearance-invalidated'],
        actionableCommentCount: 0,
        actionableThreadCount: 0,
        hasCurrentHeadReview: false,
        latestReviewIsCurrentHead: false,
        reviewRunCompletedClean: false,
        source: 'stored-ready-validation-clearance',
        receiptPath: readyValidationClearance.receiptPath,
        readyHeadSha: storedReadyHeadSha || null,
        currentHeadSha: currentHeadSha || storedCurrentHeadSha || null,
        staleForCurrentHead:
          storedReadyHeadSha && currentHeadSha ? storedReadyHeadSha !== currentHeadSha : null
      }
    };
  }

  const result = await runCopilotReviewGateFn({
    argv: [
      'node',
      'tools/priority/copilot-review-gate.mjs',
      '--event-name',
      'pull_request_target',
      '--repo',
      repo,
      '--pr',
      String(pr),
      '--head-sha',
      currentHeadSha,
      '--base-ref',
      normalizeBaseRefName(prInfo?.baseRefName),
      '--draft',
      prInfo?.isDraft ? 'true' : 'false',
      '--copilot-review-strategy',
      normalizeCopilotReviewStrategy(copilotReviewStrategy),
      '--poll-attempts',
      String(pollAttempts),
      '--poll-delay-ms',
      String(pollDelayMs),
      '--out',
      'memory://merge-sync-copilot-review-gate.json'
    ],
    writeReportFn: () => 'memory://merge-sync-copilot-review-gate.json',
    appendStepSummaryFn: () => {}
  });

  const report = result?.report ?? null;
  return {
    ok: result?.exitCode === 0,
    report: report
      ? {
          status: report.status ?? null,
          gateState: report.gateState ?? null,
        reasons: Array.isArray(report.reasons) ? [...report.reasons] : [],
        actionableCommentCount: report.summary?.actionableCommentCount ?? 0,
        actionableThreadCount: report.summary?.actionableThreadCount ?? 0,
        hasCurrentHeadReview: report.signals?.hasCurrentHeadReview ?? false,
        latestReviewIsCurrentHead: report.signals?.latestReviewIsCurrentHead ?? false,
        reviewRunCompletedClean: report.signals?.reviewRunCompletedClean ?? false,
        source: 'copilot-review-gate',
        receiptPath: null,
        readyHeadSha: null,
        currentHeadSha: currentHeadSha || null,
        staleForCurrentHead: null
      }
      : null
  };
}

export function buildMergeArgs({ pr, repo, method, mode, keepBranch, inlineDeleteBranch = !keepBranch && mode !== 'auto' }) {
  const args = ['pr', 'merge', String(pr), '--repo', repo, `--${method}`];
  // GitHub merge queue rejects --delete-branch on queued/auto admission paths.
  const allowInlineDeleteBranch = inlineDeleteBranch && mode !== 'auto';
  if (allowInlineDeleteBranch) {
    args.push('--delete-branch');
  }
  if (mode === 'auto') {
    args.push('--auto');
  } else if (mode === 'admin') {
    args.push('--admin');
  }
  return args;
}

export function normalizeRepositoryMergeCapabilities(payload = {}) {
  const capabilities = {
    allowMergeCommit: payload?.allow_merge_commit === true,
    allowSquashMerge: payload?.allow_squash_merge === true,
    allowRebaseMerge: payload?.allow_rebase_merge === true
  };
  const supportedMethods = MERGE_METHOD_FALLBACK_ORDER.filter((method) => {
    if (method === 'merge') {
      return capabilities.allowMergeCommit;
    }
    if (method === 'squash') {
      return capabilities.allowSquashMerge;
    }
    if (method === 'rebase') {
      return capabilities.allowRebaseMerge;
    }
    return false;
  });

  return {
    ...capabilities,
    supportedMethods
  };
}

export function readRepositoryMergeCapabilities({
  repoRoot,
  repo,
  runGhJsonFn = runGhJson,
  spawnSyncFn = spawnSync
} = {}) {
  const payload = runGhJsonFn(repoRoot, ['api', `repos/${repo}`], { spawnSyncFn }) ?? {};
  return normalizeRepositoryMergeCapabilities(payload);
}

export function selectMergeMethod({
  repo,
  requestedMethod = 'squash',
  requestedSource = 'default',
  capabilities = null
} = {}) {
  const normalizedRequested = MERGE_METHODS.has(requestedMethod) ? requestedMethod : 'squash';
  const supportedMethods = Array.isArray(capabilities?.supportedMethods)
    ? [...capabilities.supportedMethods]
    : [];

  if (supportedMethods.length === 0) {
    throw new Error(`Repository '${repo}' does not allow merge, squash, or rebase merges.`);
  }

  if (requestedSource === 'cli') {
    if (!supportedMethods.includes(normalizedRequested)) {
      throw new Error(
        `Repository '${repo}' does not allow requested merge method '${normalizedRequested}'. ` +
          `Supported methods: ${supportedMethods.join(', ')}.`
      );
    }

    return {
      requestedMethod: normalizedRequested,
      requestedSource,
      effectiveMethod: normalizedRequested,
      reason: 'requested-supported',
      capabilities
    };
  }

  if (supportedMethods.includes(normalizedRequested)) {
    return {
      requestedMethod: normalizedRequested,
      requestedSource,
      effectiveMethod: normalizedRequested,
      reason: 'default-preferred-supported',
      capabilities
    };
  }

  const fallbackMethod = MERGE_METHOD_FALLBACK_ORDER.find((method) => supportedMethods.includes(method));
  if (!fallbackMethod) {
    throw new Error(`Repository '${repo}' does not allow a fallback merge method for '${normalizedRequested}'.`);
  }

  return {
    requestedMethod: normalizedRequested,
    requestedSource,
    effectiveMethod: fallbackMethod,
    reason: `default-fallback-${fallbackMethod}`,
    capabilities
  };
}

export function deleteHeadBranchRef({
  repoRoot,
  headRepositorySlug = '',
  headRefName = '',
  dryRun = false,
  spawnSyncFn = spawnSync
} = {}) {
  if (!headRefName || !headRepositorySlug) {
    return {
      requested: true,
      attempted: false,
      status: 'skipped',
      reason: 'missing-head-branch-metadata',
      repository: headRepositorySlug || null,
      headRefName: headRefName || null
    };
  }

  const apiPath = `repos/${headRepositorySlug}/git/refs/heads/${encodeURIComponent(headRefName)}`;
  if (dryRun) {
    console.log(`[priority:merge-sync] dry-run post-merge branch cleanup: gh api -X DELETE ${apiPath}`);
    return {
      requested: true,
      attempted: false,
      status: 'dry-run',
      reason: 'post-merge-api-delete',
      repository: headRepositorySlug,
      headRefName
    };
  }

  const result = spawnSyncFn('gh', ['api', '-X', 'DELETE', apiPath], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const detail = `${result.stderr ?? ''}${result.stdout ?? ''}`.trim();
  if (result.status === 0) {
    return {
      requested: true,
      attempted: true,
      status: 'deleted',
      reason: 'post-merge-api-delete',
      repository: headRepositorySlug,
      headRefName
    };
  }

  if (/reference does not exist|not found|http 404/i.test(detail)) {
    return {
      requested: true,
      attempted: true,
      status: 'already-absent',
      reason: 'post-merge-api-delete',
      repository: headRepositorySlug,
      headRefName,
      detail
    };
  }

  throw new Error(
    `[priority:merge-sync] post-merge branch cleanup failed for ${headRepositorySlug}:${headRefName}: ${
      detail || `exit ${result.status}`
    }`
  );
}

export function deleteMergedHeadBranch({
  repoRoot,
  prInfo,
  dryRun = false,
  spawnSyncFn = spawnSync
} = {}) {
  return deleteHeadBranchRef({
    repoRoot,
    headRepositorySlug: resolveHeadRepositorySlug(prInfo),
    headRefName: normalizeText(prInfo?.headRefName),
    dryRun,
    spawnSyncFn
  });
}

function promotionSnapshotToState(snapshot = {}) {
  return {
    state: snapshot?.state ?? null,
    mergeStateStatus: snapshot?.mergeStateStatus ?? null,
    isInMergeQueue: Boolean(snapshot?.isInMergeQueue),
    autoMergeRequest: snapshot?.autoMergeEnabled ? { enabledAt: snapshot?.autoMergeEnabledAt ?? true } : null,
    mergedAt: snapshot?.mergedAt ?? null
  };
}

export function hasDeferredPostMergeBranchCleanup(summary = {}) {
  const requested = Boolean(summary?.branchCleanup?.requested);
  const deferred = normalizeLower(summary?.branchCleanup?.status) === 'deferred';
  const plannedPostMergeDelete = Boolean(summary?.branchCleanup?.postMergeDelete);
  const legacyAutoDeferred = normalizeLower(summary?.finalMode) === 'auto' &&
    !Boolean(summary?.branchCleanup?.inlineDeleteBranch);
  return requested && deferred && (plannedPostMergeDelete || legacyAutoDeferred);
}

export async function reconcileDeferredBranchCleanup({
  repoRoot = getRepoRoot(),
  summary = null,
  readPromotionStateFn = readPromotionState,
  readPrInfoFn = readPrInfo,
  deleteHeadBranchRefFn = deleteHeadBranchRef,
  dryRun = false,
  observedAt = new Date().toISOString()
} = {}) {
  if (!hasDeferredPostMergeBranchCleanup(summary)) {
    return {
      changed: false,
      status: 'not-applicable',
      summary
    };
  }

  const repo = normalizeText(summary?.repo);
  const pr = Number(summary?.pr);
  if (!repo || !Number.isInteger(pr) || pr <= 0) {
    throw new Error('Deferred branch cleanup reconciliation requires summary.repo and summary.pr.');
  }

  const latestPromotionState = readPromotionStateFn({ repoRoot, repo, pr });
  const promotion = {
    ...classifyPromotionState(promotionSnapshotToState(summary?.promotion?.initial), latestPromotionState, {
      finalMode: normalizeText(summary?.finalMode) || 'auto'
    }),
    observedAt,
    pollAttemptsUsed: 0
  };

  if (!(promotion.materialized && ['merged', 'already-merged'].includes(promotion.status))) {
    return {
      changed: false,
      status: 'deferred',
      summary,
      promotion
    };
  }

  let headRepositorySlug = normalizeText(summary?.branchCleanup?.repository);
  let headRefName = normalizeText(summary?.branchCleanup?.headRefName);
  if (!headRepositorySlug || !headRefName) {
    const prInfo = readPrInfoFn({ repoRoot, repo, pr });
    headRepositorySlug ||= resolveHeadRepositorySlug(prInfo);
    headRefName ||= normalizeText(prInfo?.headRefName);
  }

  const branchCleanup = deleteHeadBranchRefFn({
    repoRoot,
    headRepositorySlug,
    headRefName,
    dryRun
  });

  return {
    changed: true,
    status: branchCleanup.status === 'dry-run' ? 'dry-run' : 'completed',
    summary: {
      ...summary,
      promotion,
      branchCleanup,
      reconciledAt: observedAt
    },
    promotion,
    branchCleanup
  };
}

async function verifyPromotionActivation({
  repoRoot,
  repo,
  pr,
  finalMode,
  initialPromotionState,
  readPromotionStateFn = readPromotionState,
  sleepFn = delay,
  pollAttempts = MERGE_ACTIVATION_POLL_ATTEMPTS,
  pollDelayMs = MERGE_ACTIVATION_POLL_DELAY_MS
}) {
  let finalPromotionState = initialPromotionState;
  let activation = classifyPromotionState(initialPromotionState, finalPromotionState, { finalMode });

  if (activation.materialized || finalMode === 'none') {
    return {
      ...activation,
      observedAt: new Date().toISOString(),
      pollAttemptsUsed: 0
    };
  }

  for (let attempt = 1; attempt <= pollAttempts; attempt += 1) {
    finalPromotionState = readPromotionStateFn({ repoRoot, repo, pr });
    activation = classifyPromotionState(initialPromotionState, finalPromotionState, { finalMode });
    if (activation.materialized) {
      return {
        ...activation,
        observedAt: new Date().toISOString(),
        pollAttemptsUsed: attempt
      };
    }
    if (attempt < pollAttempts) {
      await sleepFn(pollDelayMs);
    }
  }

  return {
    ...activation,
    observedAt: new Date().toISOString(),
    pollAttemptsUsed: pollAttempts
  };
}

function runMergeAttempt({ repoRoot, args, dryRun }) {
  if (dryRun) {
    console.log(`[priority:merge-sync] dry-run command: gh ${args.join(' ')}`);
    return { status: 0, stdout: '', stderr: '' };
  }
  const result = spawnSync('gh', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  return result;
}

async function maybeWriteSummary(summaryPath, payload) {
  if (!summaryPath) {
    return;
  }
  const resolved = path.resolve(summaryPath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  console.log(`[priority:merge-sync] wrote summary: ${resolved}`);
}

export async function runMergeSync({
  argv = process.argv,
  repoRoot = getRepoRoot(),
  ensureGhCliFn = ensureGhCli,
  resolveUpstreamFn = resolveUpstream,
  readPrInfoFn = readPrInfo,
  readPromotionStateFn = readPromotionState,
  sleepFn = delay,
  runMergeAttemptFn = runMergeAttempt,
  evaluatePromotionReviewClearanceFn = evaluatePromotionReviewClearance,
  deleteMergedHeadBranchFn = deleteMergedHeadBranch,
  loadMergeSyncCopilotReviewStrategyFn = loadMergeSyncCopilotReviewStrategy,
  readRepositoryMergeCapabilitiesFn = readRepositoryMergeCapabilities
} = {}) {
  const options = parseArgs(argv);

  ensureGhCliFn();
  const resolvedRepo = options.repo ?? (() => {
    const upstream = resolveUpstreamFn(repoRoot);
    return `${upstream.owner}/${upstream.repo}`;
  })();
  const repositoryMergeCapabilities = readRepositoryMergeCapabilitiesFn({
    repoRoot,
    repo: resolvedRepo
  });
  const mergeMethodSelection = selectMergeMethod({
    repo: resolvedRepo,
    requestedMethod: options.method,
    requestedSource: options.methodExplicit ? 'cli' : 'default',
    capabilities: repositoryMergeCapabilities
  });

  const policyRaw = await readFile(manifestPath, 'utf8');
  const policy = JSON.parse(policyRaw);
  const mergeQueueBranches = getMergeQueueBranches(policy);
  const branchClassContract = loadBranchClassContract(repoRoot);
  const copilotReviewStrategy = await loadMergeSyncCopilotReviewStrategyFn({ repoRoot });

  const prInfo = readPrInfoFn({
    repoRoot,
    repo: resolvedRepo,
    pr: options.pr
  });
  const targetRepositoryRole = resolveRepositoryRole(resolvedRepo, branchClassContract);
  const targetRepositoryPlane = resolveRepositoryPlane(resolvedRepo, branchClassContract);
  const headRepositorySlug = resolveHeadRepositorySlug(prInfo, resolvedRepo);
  const headRepositoryPlane = headRepositorySlug
    ? resolveRepositoryPlane(headRepositorySlug, branchClassContract)
    : null;
  const baseBranchClass = classifyBranch({
    branch: prInfo?.baseRefName,
    contract: branchClassContract,
    repositoryRole: targetRepositoryRole
  });
  const planeTransition =
    headRepositoryPlane && headRepositoryPlane !== targetRepositoryPlane
      ? assertPlaneTransition({
          fromPlane: headRepositoryPlane,
          toPlane: targetRepositoryPlane,
          action: 'promote',
          contract: branchClassContract
        })
      : null;
  const selection = selectMergeMode(prInfo, {
    admin: options.admin,
    mergeQueueBranches,
    baseBranchClass
  });
  const reviewClearance =
    selection.mode === 'none'
      ? {
          ok: true,
          report: {
            status: 'skipped',
            gateState: 'skipped',
            reasons: ['already-merged'],
            actionableCommentCount: 0,
            actionableThreadCount: 0,
            hasCurrentHeadReview: false,
            latestReviewIsCurrentHead: false,
            reviewRunCompletedClean: false
          }
        }
      : await evaluatePromotionReviewClearanceFn({
          repoRoot,
          repo: resolvedRepo,
          pr: options.pr,
          prInfo,
          copilotReviewStrategy
        });
  const initialPromotionState =
    selection.mode === 'none'
      ? {
          state: prInfo?.state ?? null,
          mergeStateStatus: prInfo?.mergeStateStatus ?? null,
          isInMergeQueue: false,
          autoMergeRequest: null,
          mergedAt: null
        }
      : readPromotionStateFn({
          repoRoot,
          repo: resolvedRepo,
          pr: options.pr
        });
  console.log(
    `[priority:merge-sync] selected mode=${selection.mode} reason=${selection.reason} mergeState=${prInfo.mergeStateStatus ?? 'n/a'} mergeMethod=${mergeMethodSelection.effectiveMethod} methodReason=${mergeMethodSelection.reason}`
  );
  let branchCleanupPlan = resolveBranchCleanupPlan({
    keepBranch: options.keepBranch,
    mode: selection.mode,
    baseRefName: prInfo?.baseRefName,
    mergeQueueBranches,
    baseBranchClass
  });

  if (!reviewClearance?.ok) {
    const reasons = Array.isArray(reviewClearance?.report?.reasons) ? reviewClearance.report.reasons : [];
    throw new Error(
      `[priority:merge-sync] current-head Copilot review clearance failed: ${reasons.join(', ') || 'review-clearance-failed'}`
    );
  }

  const attempts = [];
  let finalMode = selection.mode;
  let finalReason = selection.reason;
  let promotion = null;

  if (selection.mode !== 'none') {
    const initialArgs = buildMergeArgs({
      pr: options.pr,
      repo: resolvedRepo,
      method: mergeMethodSelection.effectiveMethod,
      mode: selection.mode,
      keepBranch: options.keepBranch,
      inlineDeleteBranch: branchCleanupPlan.inlineDeleteBranch
    });
    const initialResult = runMergeAttemptFn({ repoRoot, args: initialArgs, dryRun: options.dryRun });
    attempts.push({
      mode: selection.mode,
      args: initialArgs,
      exitCode: initialResult.status ?? 1
    });

    if (initialResult.status !== 0) {
      const retryEligible = shouldRetryWithAuto({
        mode: selection.mode,
        stdout: initialResult.stdout ?? '',
        stderr: initialResult.stderr ?? ''
      });
      if (retryEligible && !options.admin) {
        finalMode = 'auto';
        finalReason = 'direct-merge-policy-block-retry-auto';
        console.log('[priority:merge-sync] direct merge blocked by policy; retrying with --auto.');
        const retryArgs = buildMergeArgs({
          pr: options.pr,
          repo: resolvedRepo,
          method: mergeMethodSelection.effectiveMethod,
          mode: 'auto',
          keepBranch: options.keepBranch,
          inlineDeleteBranch: false
        });
        branchCleanupPlan = resolveBranchCleanupPlan({
          keepBranch: options.keepBranch,
          mode: 'auto',
          baseRefName: prInfo?.baseRefName,
          mergeQueueBranches,
          baseBranchClass
        });
        const retryResult = runMergeAttemptFn({ repoRoot, args: retryArgs, dryRun: options.dryRun });
        attempts.push({
          mode: 'auto',
          args: retryArgs,
          exitCode: retryResult.status ?? 1
        });
        if (retryResult.status !== 0) {
          throw new Error('[priority:merge-sync] auto-merge retry failed. Use --admin only when explicitly required for policy exception.');
        }
      } else {
        if (!options.admin) {
          throw new Error(
            '[priority:merge-sync] merge failed. Re-run with --admin only if privileged override is required.'
          );
        }
        throw new Error('[priority:merge-sync] merge failed in admin mode. Resolve policy or branch state and retry.');
      }
    }
  }

  if (options.dryRun) {
    promotion = {
      status: 'dry-run',
      materialized: false,
      finalMode,
      initial: {
        state: initialPromotionState?.state ?? null,
        mergeStateStatus: initialPromotionState?.mergeStateStatus ?? null,
        isInMergeQueue: Boolean(initialPromotionState?.isInMergeQueue),
        autoMergeEnabled: Boolean(initialPromotionState?.autoMergeRequest),
        mergedAt: initialPromotionState?.mergedAt ?? null
      },
      final: null,
      observedAt: new Date().toISOString(),
      pollAttemptsUsed: 0
    };
  } else {
    promotion = await verifyPromotionActivation({
      repoRoot,
      repo: resolvedRepo,
      pr: options.pr,
      finalMode,
      initialPromotionState,
      readPromotionStateFn,
      sleepFn
    });
  }

  let branchCleanup = {
    requested: branchCleanupPlan.requested,
    attempted: false,
    status: branchCleanupPlan.requested ? 'deferred' : 'kept',
    reason: branchCleanupPlan.reason,
    inlineDeleteBranch: branchCleanupPlan.inlineDeleteBranch,
    postMergeDelete: branchCleanupPlan.postMergeDelete,
    repository: resolveHeadRepositorySlug(prInfo) || null,
    headRefName: normalizeText(prInfo?.headRefName) || null
  };
  if (branchCleanupPlan.inlineDeleteBranch) {
    branchCleanup = {
      ...branchCleanup,
      status: options.dryRun ? 'dry-run-inline' : 'inline-requested'
    };
  } else if (branchCleanupPlan.postMergeDelete) {
    if (options.dryRun) {
      branchCleanup = deleteMergedHeadBranchFn({
        repoRoot,
        prInfo,
        dryRun: true
      });
    } else if (promotion.materialized && ['merged', 'already-merged'].includes(promotion.status)) {
      branchCleanup = deleteMergedHeadBranchFn({
        repoRoot,
        prInfo,
        dryRun: false
      });
    } else {
      branchCleanup = {
        ...branchCleanup,
        status: 'deferred',
        reason: 'promotion-not-yet-merged'
      };
    }
  }

  const payload = buildMergeSummaryPayload({
    repo: resolvedRepo,
    pr: options.pr,
    mergeMethod: mergeMethodSelection.effectiveMethod,
    mergeMethodSelection,
    selectedMode: selection.mode,
    selectedReason: selection.reason,
    finalMode,
    finalReason,
    dryRun: options.dryRun,
    mergeQueueBranches,
    attempts,
    prInfo,
    branchClassTrace: buildBranchClassTrace({
      targetRepositoryRole,
      baseBranchClass
    }),
    reviewClearance: reviewClearance?.report ?? null,
    branchCleanup,
    promotion,
    planeTransition
  });
  await maybeWriteSummary(options.summaryPath, payload);

  if (!options.dryRun && selection.mode !== 'none' && !promotion.materialized) {
    throw new Error(
      `[priority:merge-sync] merge command completed but no durable promotion state was observed (status=${promotion.status}).`
    );
  }

  console.log(`[priority:merge-sync] final mode=${finalMode} reason=${finalReason}`);
  return payload;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  runMergeSync().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}

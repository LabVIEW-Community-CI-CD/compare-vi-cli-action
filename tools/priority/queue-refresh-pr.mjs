#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { ensureGhCli, parseRemoteUrl, runGhGraphql, runGhJson, tryResolveRemote } from './lib/remote-utils.mjs';
import { getMergeQueueBranches, runMergeSync } from './merge-sync-pr.mjs';

const RECEIPT_SCHEMA = 'priority/queue-refresh-receipt@v1';
const DEFAULT_RECEIPT_DIR = path.join('tests', 'results', '_agent', 'queue');
const DEQUEUE_POLL_ATTEMPTS = 5;
const DEQUEUE_POLL_DELAY_MS = 1500;

const USAGE_LINES = [
  'Usage: node tools/priority/queue-refresh-pr.mjs --pr <number> [options]',
  '',
  'Options:',
  '  --pr <number>             Pull request number to refresh (required)',
  '  --repo <owner/repo>       Target repository (defaults to upstream remote)',
  '  --head-remote <name>      Explicit remote for the PR head branch (default: infer from checkout/remotes)',
  '  --summary-path <path>     Write queue-refresh receipt JSON (default: tests/results/_agent/queue/queue-refresh-<pr>.json)',
  '  --merge-summary-path <path>',
  '                            Write nested merge-sync summary JSON (default: tests/results/_agent/queue/merge-sync-<pr>.json)',
  '  --dry-run                 Compute the refresh plan without dequeuing, rebasing, pushing, or requeueing',
  '  -h, --help                Show this message and exit'
];

function printUsage() {
  for (const line of USAGE_LINES) {
    console.log(line);
  }
}

function normalizeText(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalizeOwner(value) {
  return normalizeText(value).toLowerCase();
}

function coercePositiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function parseRepoSlug(repo) {
  const parts = String(repo ?? '')
    .split('/')
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length !== 2) {
    throw new Error(`Invalid repo slug '${repo}'. Expected owner/repo.`);
  }
  return {
    owner: parts[0],
    name: parts[1]
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    pr: null,
    repo: null,
    headRemote: null,
    summaryPath: null,
    mergeSummaryPath: null,
    dryRun: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '-h' || arg === '--help') {
      printUsage();
      process.exit(0);
    }
    if (arg === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (
      arg === '--pr' ||
      arg === '--repo' ||
      arg === '--head-remote' ||
      arg === '--summary-path' ||
      arg === '--merge-summary-path'
    ) {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--pr') {
        const pr = coercePositiveInteger(value);
        if (!pr) {
          throw new Error(`Invalid --pr value '${value}'. Expected positive integer.`);
        }
        options.pr = pr;
      } else if (arg === '--repo') {
        parseRepoSlug(value);
        options.repo = value;
      } else if (arg === '--head-remote') {
        options.headRemote = normalizeText(value);
      } else if (arg === '--summary-path') {
        options.summaryPath = value;
      } else if (arg === '--merge-summary-path') {
        options.mergeSummaryPath = value;
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

function buildDefaultReceiptPath(pr) {
  return path.join(DEFAULT_RECEIPT_DIR, `queue-refresh-${pr}.json`);
}

function buildDefaultMergeSummaryPath(pr) {
  return path.join(DEFAULT_RECEIPT_DIR, `merge-sync-${pr}.json`);
}

function resolveRepositorySlug(repoRoot, explicitRepo = null) {
  if (explicitRepo) {
    parseRepoSlug(explicitRepo);
    return explicitRepo;
  }

  if (process.env.GITHUB_REPOSITORY && process.env.GITHUB_REPOSITORY.includes('/')) {
    return process.env.GITHUB_REPOSITORY.trim();
  }

  for (const remoteName of ['upstream', 'origin']) {
    const remote = tryResolveRemote(repoRoot, remoteName);
    const slug = remote?.parsed?.owner && remote?.parsed?.repo ? `${remote.parsed.owner}/${remote.parsed.repo}` : null;
    if (slug) {
      return slug;
    }
  }

  throw new Error('Unable to resolve target repository. Pass --repo owner/repo.');
}

async function readPolicyManifest(repoRoot, { readFileFn = readFile } = {}) {
  const manifestPath = path.join(repoRoot, 'tools', 'priority', 'policy.json');
  return JSON.parse(await readFileFn(manifestPath, 'utf8'));
}

async function writeReceipt(filePath, payload, { mkdirFn = mkdir, writeFileFn = writeFile } = {}) {
  const resolvedPath = path.resolve(filePath);
  await mkdirFn(path.dirname(resolvedPath), { recursive: true });
  await writeFileFn(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

async function readPullRequestView({
  repoRoot,
  repo,
  pr,
  runGhJsonFn = runGhJson
} = {}) {
  return (
    runGhJsonFn(repoRoot, [
      'pr',
      'view',
      String(pr),
      '--repo',
      repo,
      '--json',
      'id,number,state,isDraft,mergeStateStatus,mergeable,baseRefName,url,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,autoMergeRequest'
    ]) ?? {}
  );
}

async function readPullRequestQueueState({
  repoRoot,
  pullRequestId,
  runGhGraphqlFn = runGhGraphql
} = {}) {
  const query = `
    query($id: ID!) {
      node(id: $id) {
        ... on PullRequest {
          state
          mergeStateStatus
          isInMergeQueue
          mergedAt
          autoMergeRequest {
            enabledAt
            mergeMethod
          }
        }
      }
    }
  `;
  const payload = runGhGraphqlFn(repoRoot, query, { id: pullRequestId });
  return payload?.data?.node ?? {};
}

async function dequeuePullRequest({
  repoRoot,
  pullRequestId,
  runGhGraphqlFn = runGhGraphql
} = {}) {
  const mutation = `
    mutation($id: ID!) {
      dequeuePullRequest(input: { id: $id }) {
        clientMutationId
        mergeQueueEntry {
          id
        }
      }
    }
  `;
  return runGhGraphqlFn(repoRoot, mutation, { id: pullRequestId });
}

function resolveHeadRepositorySlug(prInfo = {}) {
  const owner = normalizeOwner(prInfo?.headRepositoryOwner?.login ?? prInfo?.headRepositoryOwner);
  const repoName = normalizeText(prInfo?.headRepository?.name);
  if (!owner || !repoName) {
    return null;
  }
  return `${owner}/${repoName}`;
}

function formatCommandError(tool, args, result) {
  const stderr = normalizeText(result?.stderr);
  const stdout = normalizeText(result?.stdout);
  return `${tool} ${args.join(' ')} failed: ${stderr || stdout || `exit ${result?.status ?? 1}`}`;
}

function runGitCommand(repoRoot, args, { spawnSyncFn = spawnSync, allowFailure = false } = {}) {
  const result = spawnSyncFn('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (!allowFailure && result.status !== 0) {
    throw new Error(formatCommandError('git', args, result));
  }
  return result;
}

function getCurrentBranch(repoRoot, { runGitCommandFn = runGitCommand } = {}) {
  return normalizeText(runGitCommandFn(repoRoot, ['rev-parse', '--abbrev-ref', 'HEAD']).stdout);
}

function getTrackingRemote(repoRoot, branchName, { runGitCommandFn = runGitCommand } = {}) {
  const result = runGitCommandFn(repoRoot, ['config', `branch.${branchName}.remote`], { allowFailure: true });
  if (result.status !== 0) {
    return null;
  }
  return normalizeText(result.stdout) || null;
}

function ensureCleanWorkingTree(repoRoot, { runGitCommandFn = runGitCommand } = {}) {
  const result = runGitCommandFn(repoRoot, ['status', '--porcelain']);
  if (normalizeText(result.stdout)) {
    throw new Error('Queue refresh requires a clean working tree.');
  }
}

export function resolveHeadRemoteName({
  repoRoot,
  explicitHeadRemote = null,
  prInfo = {},
  currentBranch = '',
  trackingRemote = null,
  resolveRemoteFn = tryResolveRemote,
  targetRepository = null
} = {}) {
  if (normalizeText(explicitHeadRemote)) {
    const remote = resolveRemoteFn(repoRoot, explicitHeadRemote);
    if (!remote?.parsed) {
      throw new Error(`Unable to resolve explicit head remote '${explicitHeadRemote}'.`);
    }
    return {
      remoteName: explicitHeadRemote,
      source: 'explicit'
    };
  }

  const headRefName = normalizeText(prInfo?.headRefName);
  if (trackingRemote && headRefName && currentBranch === headRefName) {
    const remote = resolveRemoteFn(repoRoot, trackingRemote);
    if (remote?.parsed) {
      return {
        remoteName: trackingRemote,
        source: 'tracking'
      };
    }
  }

  const headRepositorySlug = resolveHeadRepositorySlug(prInfo);
  for (const remoteName of ['origin', 'personal', 'upstream']) {
    const remote = resolveRemoteFn(repoRoot, remoteName);
    const remoteSlug =
      remote?.parsed?.owner && remote?.parsed?.repo ? `${remote.parsed.owner}/${remote.parsed.repo}` : null;
    if (remoteSlug && headRepositorySlug && remoteSlug.toLowerCase() === headRepositorySlug.toLowerCase()) {
      return {
        remoteName,
        source: 'head-repository'
      };
    }
  }

  if (!prInfo?.isCrossRepository && normalizeText(targetRepository)) {
    const upstreamRemote = resolveRemoteFn(repoRoot, 'upstream');
    const upstreamSlug =
      upstreamRemote?.parsed?.owner && upstreamRemote?.parsed?.repo
        ? `${upstreamRemote.parsed.owner}/${upstreamRemote.parsed.repo}`
        : null;
    if (upstreamSlug && upstreamSlug.toLowerCase() === normalizeText(targetRepository).toLowerCase()) {
      return {
        remoteName: 'upstream',
        source: 'target-repository'
      };
    }
  }

  throw new Error(
    `Unable to infer head remote for '${headRefName || 'unknown-head'}'. Pass --head-remote explicitly from the PR checkout.`
  );
}

async function pollForDequeuedState({
  repoRoot,
  pullRequestId,
  readPullRequestQueueStateFn = readPullRequestQueueState,
  sleepFn = delay
} = {}) {
  let finalState = null;
  for (let attempt = 1; attempt <= DEQUEUE_POLL_ATTEMPTS; attempt += 1) {
    finalState = await readPullRequestQueueStateFn({
      repoRoot,
      pullRequestId
    });
    if (!finalState?.isInMergeQueue || normalizeText(finalState?.state).toUpperCase() !== 'OPEN') {
      return {
        finalState,
        pollAttemptsUsed: attempt
      };
    }
    if (attempt < DEQUEUE_POLL_ATTEMPTS) {
      await sleepFn(DEQUEUE_POLL_DELAY_MS);
    }
  }

  throw new Error(`PR remained queued after ${DEQUEUE_POLL_ATTEMPTS} dequeue poll attempts.`);
}

function normalizeQueueState(prView = {}, queueState = {}) {
  return {
    state: normalizeText(queueState?.state || prView?.state).toUpperCase() || null,
    mergeStateStatus: normalizeText(queueState?.mergeStateStatus || prView?.mergeStateStatus).toUpperCase() || null,
    isInMergeQueue: queueState?.isInMergeQueue === true,
    autoMergeEnabled: Boolean(queueState?.autoMergeRequest || prView?.autoMergeRequest),
    mergedAt: normalizeText(queueState?.mergedAt || prView?.mergedAt) || null,
    headRefOid: normalizeText(prView?.headRefOid) || null
  };
}

function createReceipt({
  repo,
  pr,
  dryRun,
  baseRefName,
  headRefName,
  headRepositorySlug,
  headRemote,
  queueManagedBase,
  currentBranch,
  initialState
}) {
  return {
    schema: RECEIPT_SCHEMA,
    generatedAt: new Date().toISOString(),
    repo,
    pr,
    dryRun,
    baseRefName,
    headRefName,
    headRepositorySlug,
    headRemote,
    queueManagedBase,
    initial: {
      ...initialState,
      currentBranch
    },
    dequeue: {
      attempted: false,
      status: 'skipped',
      reason: null,
      helperCallsExecuted: [],
      pullRequestId: null,
      pollAttemptsUsed: 0,
      finalIsInMergeQueue: initialState.isInMergeQueue
    },
    refresh: {
      attempted: false,
      status: 'skipped',
      reason: null,
      helperCallsExecuted: [],
      baseRemoteRef: baseRefName ? `upstream/${baseRefName}` : null,
      forcePushTarget: headRemote && headRefName ? `${headRemote}:${headRefName}` : null,
      rebasedHeadSha: null
    },
    requeue: {
      attempted: false,
      status: 'skipped',
      reason: null,
      helperCallsExecuted: [],
      mergeSummaryPath: null,
      promotionStatus: null,
      materialized: null,
      finalMode: null,
      finalReason: null
    },
    summary: {
      status: 'skipped',
      reason: null
    }
  };
}

function markStepFailed(receipt, step, error) {
  if (!receipt?.[step]) {
    return;
  }
  receipt[step].attempted = true;
  receipt[step].status = 'failed';
  receipt[step].reason = normalizeText(error?.message ?? error) || 'step-failed';
}

export async function runQueueRefresh(options = {}) {
  const repoRoot = options.repoRoot ?? getRepoRoot();
  const args = options.args ?? parseArgs(options.argv ?? process.argv);
  const ensureGhCliFn = options.ensureGhCliFn ?? ensureGhCli;
  const readPolicyFn = options.readPolicyFn ?? (async () => readPolicyManifest(repoRoot));
  const readPullRequestViewFn = options.readPullRequestViewFn ?? readPullRequestView;
  const readPullRequestQueueStateFn = options.readPullRequestQueueStateFn ?? readPullRequestQueueState;
  const dequeuePullRequestFn = options.dequeuePullRequestFn ?? dequeuePullRequest;
  const runGitCommandFn = options.runGitCommandFn ?? runGitCommand;
  const readCurrentBranchFn = options.readCurrentBranchFn ?? ((root) => getCurrentBranch(root, { runGitCommandFn }));
  const readTrackingRemoteFn =
    options.readTrackingRemoteFn ?? ((root, branchName) => getTrackingRemote(root, branchName, { runGitCommandFn }));
  const resolveHeadRemoteNameFn = options.resolveHeadRemoteNameFn ?? resolveHeadRemoteName;
  const runMergeSyncFn = options.runMergeSyncFn ?? runMergeSync;
  const writeReceiptFn =
    options.writeReceiptFn ??
    (async (filePath, payload) => writeReceipt(filePath, payload));
  const sleepFn = options.sleepFn ?? delay;

  ensureGhCliFn();

  const resolvedRepo = resolveRepositorySlug(repoRoot, args.repo);
  const receiptPath = args.summaryPath ?? buildDefaultReceiptPath(args.pr);
  const mergeSummaryPath = args.mergeSummaryPath ?? buildDefaultMergeSummaryPath(args.pr);

  let receipt = null;
  let currentStep = null;

  try {
    const policy = await readPolicyFn();
    const mergeQueueBranches = getMergeQueueBranches(policy);
    const prView = await readPullRequestViewFn({
      repoRoot,
      repo: resolvedRepo,
      pr: args.pr
    });
    const queueState = await readPullRequestQueueStateFn({
      repoRoot,
      pullRequestId: prView.id
    });
    const currentBranch = readCurrentBranchFn(repoRoot);
    const trackingRemote =
      currentBranch && currentBranch !== 'HEAD' ? readTrackingRemoteFn(repoRoot, currentBranch) : null;
    const initialState = normalizeQueueState(prView, queueState);
    const headRemote = resolveHeadRemoteNameFn({
      repoRoot,
      explicitHeadRemote: args.headRemote,
      prInfo: prView,
      currentBranch,
      trackingRemote,
      targetRepository: resolvedRepo
    });
    const baseRefName = normalizeText(prView?.baseRefName).toLowerCase();
    const headRefName = normalizeText(prView?.headRefName);
    const headRepositorySlug = resolveHeadRepositorySlug(prView);
    const queueManagedBase = mergeQueueBranches.has(baseRefName);

    receipt = createReceipt({
      repo: resolvedRepo,
      pr: args.pr,
      dryRun: Boolean(args.dryRun),
      baseRefName,
      headRefName,
      headRepositorySlug,
      headRemote: headRemote.remoteName,
      queueManagedBase,
      currentBranch,
      initialState
    });

    if (!queueManagedBase) {
      receipt.summary.reason = 'base-not-queue-managed';
      return {
        receipt,
        receiptPath: await writeReceiptFn(receiptPath, receipt)
      };
    }

    if (initialState.state !== 'OPEN') {
      receipt.summary.reason = 'pull-request-not-open';
      return {
        receipt,
        receiptPath: await writeReceiptFn(receiptPath, receipt)
      };
    }

    if (!initialState.isInMergeQueue) {
      receipt.summary.reason = 'not-in-merge-queue';
      return {
        receipt,
        receiptPath: await writeReceiptFn(receiptPath, receipt)
      };
    }

    ensureCleanWorkingTree(repoRoot, { runGitCommandFn });

    if (args.dryRun) {
      receipt.dequeue = {
        ...receipt.dequeue,
        attempted: true,
        status: 'dry-run',
        reason: 'dry-run',
        pullRequestId: normalizeText(prView?.id) || null,
        finalIsInMergeQueue: true
      };
      receipt.refresh = {
        ...receipt.refresh,
        attempted: true,
        status: 'dry-run',
        reason: 'dry-run'
      };
      receipt.requeue = {
        ...receipt.requeue,
        attempted: true,
        status: 'dry-run',
        reason: 'dry-run',
        mergeSummaryPath
      };
      receipt.summary = {
        status: 'dry-run',
        reason: 'dry-run'
      };
      return {
        receipt,
        receiptPath: await writeReceiptFn(receiptPath, receipt)
      };
    }

    currentStep = 'dequeue';
    receipt.dequeue.attempted = true;
    receipt.dequeue.pullRequestId = normalizeText(prView?.id) || null;
    receipt.dequeue.helperCallsExecuted.push('gh api graphql dequeuePullRequest');
    await dequeuePullRequestFn({
      repoRoot,
      pullRequestId: prView.id
    });
    const dequeuePoll = await pollForDequeuedState({
      repoRoot,
      pullRequestId: prView.id,
      readPullRequestQueueStateFn,
      sleepFn
    });
    receipt.dequeue.status = 'completed';
    receipt.dequeue.pollAttemptsUsed = dequeuePoll.pollAttemptsUsed;
    receipt.dequeue.finalIsInMergeQueue = dequeuePoll.finalState?.isInMergeQueue === true;
    receipt.dequeue.reason = 'dequeued';

    currentStep = 'refresh';
    receipt.refresh.attempted = true;
    receipt.refresh.helperCallsExecuted.push(`git fetch upstream ${baseRefName}`);
    const upstreamFetch = runGitCommandFn(repoRoot, ['fetch', 'upstream', baseRefName], { allowFailure: true });
    if (upstreamFetch.status !== 0) {
      throw new Error(formatCommandError('git', ['fetch', 'upstream', baseRefName], upstreamFetch));
    }

    receipt.refresh.helperCallsExecuted.push(`git fetch ${headRemote.remoteName} ${headRefName}`);
    const headFetch = runGitCommandFn(repoRoot, ['fetch', headRemote.remoteName, headRefName], { allowFailure: true });
    if (headFetch.status !== 0) {
      throw new Error(formatCommandError('git', ['fetch', headRemote.remoteName, headRefName], headFetch));
    }

    if (currentBranch !== headRefName) {
      receipt.refresh.helperCallsExecuted.push(`git checkout ${headRefName}`);
      let checkout = runGitCommandFn(repoRoot, ['checkout', headRefName], { allowFailure: true });
      if (checkout.status !== 0) {
        receipt.refresh.helperCallsExecuted.push(
          `git checkout -b ${headRefName} --track ${headRemote.remoteName}/${headRefName}`
        );
        checkout = runGitCommandFn(
          repoRoot,
          ['checkout', '-b', headRefName, '--track', `${headRemote.remoteName}/${headRefName}`],
          { allowFailure: true }
        );
      }
      if (checkout.status !== 0) {
        throw new Error(formatCommandError('git', ['checkout', headRefName], checkout));
      }
    }

    receipt.refresh.helperCallsExecuted.push(`git rebase upstream/${baseRefName}`);
    const rebase = runGitCommandFn(repoRoot, ['rebase', `upstream/${baseRefName}`], { allowFailure: true });
    if (rebase.status !== 0) {
      receipt.refresh.helperCallsExecuted.push('git rebase --abort');
      runGitCommandFn(repoRoot, ['rebase', '--abort'], { allowFailure: true });
      throw new Error(formatCommandError('git', ['rebase', `upstream/${baseRefName}`], rebase));
    }

    const rebasedHeadSha = normalizeText(runGitCommandFn(repoRoot, ['rev-parse', 'HEAD']).stdout) || null;
    receipt.refresh.helperCallsExecuted.push(`git push --force-with-lease ${headRemote.remoteName} HEAD:${headRefName}`);
    const push = runGitCommandFn(repoRoot, ['push', '--force-with-lease', headRemote.remoteName, `HEAD:${headRefName}`], {
      allowFailure: true
    });
    if (push.status !== 0) {
      throw new Error(
        formatCommandError('git', ['push', '--force-with-lease', headRemote.remoteName, `HEAD:${headRefName}`], push)
      );
    }
    receipt.refresh.status = 'completed';
    receipt.refresh.reason = 'rebased-and-pushed';
    receipt.refresh.rebasedHeadSha = rebasedHeadSha;

    currentStep = 'requeue';
    receipt.requeue.attempted = true;
    receipt.requeue.mergeSummaryPath = mergeSummaryPath;
    receipt.requeue.helperCallsExecuted.push('node tools/priority/merge-sync-pr.mjs');
    const mergePayload = await runMergeSyncFn({
      argv: [
        'node',
        'tools/priority/merge-sync-pr.mjs',
        '--pr',
        String(args.pr),
        '--repo',
        resolvedRepo,
        '--summary-path',
        mergeSummaryPath
      ],
      repoRoot
    });
    receipt.requeue.status = 'completed';
    receipt.requeue.reason = 'merge-sync-rearmed';
    receipt.requeue.promotionStatus = normalizeText(mergePayload?.promotion?.status) || null;
    receipt.requeue.materialized =
      typeof mergePayload?.promotion?.materialized === 'boolean' ? mergePayload.promotion.materialized : null;
    receipt.requeue.finalMode = normalizeText(mergePayload?.finalMode) || null;
    receipt.requeue.finalReason = normalizeText(mergePayload?.finalReason) || null;

    receipt.summary = {
      status: 'completed',
      reason: 'queue-refresh-completed'
    };

    return {
      receipt,
      receiptPath: await writeReceiptFn(receiptPath, receipt)
    };
  } catch (error) {
    if (receipt) {
      if (currentStep) {
        markStepFailed(receipt, currentStep, error);
      }
      receipt.summary = {
        status: 'failed',
        reason: normalizeText(error?.message ?? error) || 'queue-refresh-failed'
      };
      await writeReceiptFn(receiptPath, receipt);
    }
    throw error;
  }
}

async function main(argv = process.argv) {
  const { receiptPath, receipt } = await runQueueRefresh({ argv });
  console.log(`[priority:queue:refresh] receipt written: ${receiptPath}`);
  console.log(
    `[priority:queue:refresh] status=${receipt.summary.status} pr=${receipt.pr} base=${receipt.baseRefName} head=${receipt.headRefName}`
  );
  if (receipt.summary.reason) {
    console.log(`[priority:queue:refresh] reason=${receipt.summary.reason}`);
  }
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).catch((error) => {
    console.error(error?.message ?? String(error));
    process.exitCode = 1;
  });
}

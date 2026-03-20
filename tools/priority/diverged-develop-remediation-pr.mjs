#!/usr/bin/env node

import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';
import {
  assertPlaneTransition,
  loadBranchClassContract,
  resolveRepositoryPlane
} from './lib/branch-classification.mjs';
import {
  ensureForkRemote,
  ensureGhCli,
  resolveUpstream,
  runGhJson,
  runGhPrCreate,
  updateExistingPullRequest
} from './lib/remote-utils.mjs';

const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'diverged-develop-remediation-pr.json'
);
const DEFAULT_BRANCH = 'develop';
const DEFAULT_BASE_REMOTE = 'upstream';
const REMEDIATION_COMMIT_AUTHOR_NAME = 'compare-vi-cli-action parity bot';
const REMEDIATION_COMMIT_AUTHOR_EMAIL = 'compare-vi-cli-action@users.noreply.github.com';
const DEFAULT_PUSH_TRANSPORT_RETRY_ATTEMPTS = 3;
const DEFAULT_PUSH_TRANSPORT_RETRY_DELAY_MS = 1500;

function printUsage() {
  console.log('Usage: node tools/priority/diverged-develop-remediation-pr.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --target-remote <origin>             Fork remote whose diverged develop branch is being remediated.');
  console.log(`  --base-remote <name>                  Base remote name used for diagnostics (default: ${DEFAULT_BASE_REMOTE}).`);
  console.log(`  --branch <name>                      Protected branch to remediate (default: ${DEFAULT_BRANCH}).`);
  console.log('  --sync-branch <name>                 Deterministic remediation branch to create or update.');
  console.log('  --reason <text>                      Machine-readable reason for staging the remediation.');
  console.log('  --local-head <sha>                   Optional local HEAD that observed the divergence.');
  console.log('  --reference <text>                   Optional issue/epic reference to append to the PR body.');
  console.log(`  --report-path <path>                 JSON report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  -h, --help                           Show this help text and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    targetRemote: null,
    baseRemote: DEFAULT_BASE_REMOTE,
    branch: DEFAULT_BRANCH,
    syncBranch: null,
    reason: 'diverged-fork-plane',
    localHead: null,
    reference: null,
    reportPath: DEFAULT_REPORT_PATH,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    if (
      arg === '--target-remote' ||
      arg === '--base-remote' ||
      arg === '--branch' ||
      arg === '--sync-branch' ||
      arg === '--reason' ||
      arg === '--local-head' ||
      arg === '--reference' ||
      arg === '--report-path'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--target-remote') options.targetRemote = next;
      if (arg === '--base-remote') options.baseRemote = next;
      if (arg === '--branch') options.branch = next;
      if (arg === '--sync-branch') options.syncBranch = next;
      if (arg === '--reason') options.reason = next;
      if (arg === '--local-head') options.localHead = next;
      if (arg === '--reference') options.reference = next;
      if (arg === '--report-path') options.reportPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return options;
}

export function buildDivergedDevelopRemediationBranchName(targetRemote, branch = DEFAULT_BRANCH) {
  if (!String(targetRemote || '').trim()) {
    throw new Error('targetRemote is required.');
  }
  if (!String(branch || '').trim()) {
    throw new Error('branch is required.');
  }
  const sanitizedRemote = String(targetRemote).trim().toLowerCase().replace(/[^a-z0-9._-]/g, '-');
  const sanitizedBranch = String(branch).trim().toLowerCase().replace(/[^a-z0-9._/-]/g, '-');
  return `sync/${sanitizedRemote}-${sanitizedBranch.replace(/\//g, '-')}-parity`;
}

export function buildDivergedDevelopRemediationPrTitle({ baseRemote = DEFAULT_BASE_REMOTE, branch = DEFAULT_BRANCH } = {}) {
  return `[sync]: restore ${branch} parity with ${baseRemote}/${branch}`;
}

export function buildDivergedDevelopRemediationPrBody({
  upstream,
  targetRepository,
  targetRemote,
  baseRemote = DEFAULT_BASE_REMOTE,
  branch = DEFAULT_BRANCH,
  syncBranch,
  reason,
  localHead,
  baseHead,
  targetHead,
  syntheticCommit,
  reference = null
}) {
  const upstreamSlug = upstream ? `${upstream.owner}/${upstream.repo}` : '<unknown>';
  const targetSlug = targetRepository ? `${targetRepository.owner}/${targetRepository.repo}` : '<unknown>';
  const lines = [
    '## Summary',
    `- restore \`${targetSlug}:${branch}\` tree parity with \`${upstreamSlug}:${branch}\``,
    `- stage deterministic remediation through a PR / merge-queue path instead of mutating \`${targetSlug}:${branch}\` directly`,
    '',
    '## Testing',
    '- branch sync only; required checks run on this PR',
    '',
    '## Remediation Metadata',
    `- target remote: \`${targetRemote}\``,
    `- base remote: \`${baseRemote}\``,
    `- sync branch: \`${syncBranch}\``,
    `- trigger reason: \`${reason}\``,
    `- upstream head: \`${baseHead}\``,
    `- diverged head: \`${targetHead}\``,
    `- synthetic parity commit: \`${syntheticCommit}\``
  ];
  if (localHead) {
    lines.push(`- observed local head: \`${localHead}\``);
  }
  if (reference) {
    lines.push('', `Refs ${reference}`);
  }
  return lines.join('\n');
}

export function buildDivergedDevelopRemediationSummaryPayload({
  targetRemote,
  baseRemote,
  branch,
  syncBranch,
  reason,
  localHead,
  upstream,
  targetRepository,
  planeTransition,
  baseRef,
  headRef,
  upstreamHead,
  divergedHead,
  upstreamTree,
  divergedTree,
  syntheticCommit,
  push,
  pullRequest,
  draftState,
  autoMerge,
  promotionTarget,
  failure,
  syncMethod = 'pull-request-draft',
  createdAt = new Date().toISOString()
}) {
  return {
    schema: 'priority/diverged-develop-remediation@v1',
    generatedAt: createdAt,
    targetRemote,
    baseRemote,
    branch,
    syncBranch,
    reason,
    localHead: localHead ?? null,
    baseRef,
    headRef,
    upstreamRepository: upstream ? `${upstream.owner}/${upstream.repo}` : null,
    targetRepository: targetRepository ? `${targetRepository.owner}/${targetRepository.repo}` : null,
    planeTransition: planeTransition ?? null,
    syncMethod,
    upstreamHead,
    divergedHead,
    upstreamTree,
    divergedTree,
    syntheticCommit,
    push,
    pullRequest: pullRequest ?? null,
    draftState: draftState ?? null,
    autoMerge: autoMerge ?? null,
    promotionTarget: promotionTarget ?? null,
    failure: failure ?? null
  };
}

function buildRemediationPullRequestSummary(pullRequest, { syncBranch, branch, reusedExisting } = {}) {
  if (!pullRequest?.number) {
    return null;
  }

  return {
    number: pullRequest.number,
    url: pullRequest.url ?? null,
    state: pullRequest.state ?? null,
    isDraft: pullRequest.isDraft == null ? null : Boolean(pullRequest.isDraft),
    headRefName: pullRequest.headRefName ?? syncBranch ?? null,
    baseRefName: pullRequest.baseRefName ?? branch ?? null,
    mergeStateStatus: pullRequest.mergeStateStatus ?? null,
    reusedExisting
  };
}

function tryBuildReusableRemediationReport({
  repoRoot,
  targetRepoSlug,
  pullRequestNumber,
  targetRemote,
  baseRemote,
  branch,
  syncBranch,
  reason,
  localHead,
  upstream,
  targetRepository,
  planeTransition,
  baseRef,
  headRef,
  upstreamHead,
  divergedHead,
  upstreamTree,
  divergedTree,
  syntheticCommit,
  push,
  reusedExisting,
  runGhJsonFn = runGhJson,
  spawnSyncFn = spawnSync
} = {}) {
  let viewedPr = null;
  try {
    viewedPr = viewPullRequest(repoRoot, targetRepoSlug, pullRequestNumber, {
      runGhJsonFn,
      spawnSyncFn
    });
  } catch {
    return null;
  }

  if (!viewedPr?.number || viewedPr.isDraft !== true || viewedPr.autoMergeRequest) {
    return null;
  }

  return buildDivergedDevelopRemediationSummaryPayload({
    targetRemote,
    baseRemote,
    branch,
    syncBranch,
    reason,
    localHead,
    upstream,
    targetRepository,
    planeTransition,
    baseRef,
    headRef,
    upstreamHead,
    divergedHead,
    upstreamTree,
    divergedTree,
    syntheticCommit,
    push,
    pullRequest: buildRemediationPullRequestSummary(viewedPr, {
      syncBranch,
      branch,
      reusedExisting
    }),
    draftState: {
      status: 'already-draft',
      attempted: false
    },
    autoMerge: {
      status: 'already-disabled',
      attempted: false
    }
  });
}

function buildPrViewArgs({ repo, number }) {
  return [
    'pr',
    'view',
    String(number),
    '--repo',
    repo,
    '--json',
      'number,url,state,isDraft,headRefName,baseRefName,mergeStateStatus'
      + ',autoMergeRequest'
  ];
}

function buildPrReadyArgs({ repo, number, undo = false }) {
  const args = ['pr', 'ready', String(number), '--repo', repo];
  if (undo) {
    args.push('--undo');
  }
  return args;
}

function buildPrMergeAutoArgs({ repo, number, method = null }) {
  const args = ['pr', 'merge', String(number), '--repo', repo];
  if (typeof method === 'string' && method.trim().length > 0) {
    args.push(`--${method}`);
  }
  args.push('--auto');
  return args;
}

function buildPrDisableAutoArgs({ repo, number }) {
  return ['pr', 'merge', String(number), '--repo', repo, '--disable-auto'];
}

function buildRepoViewArgs(repo) {
  return [
    'repo',
    'view',
    repo,
    '--json',
    'mergeCommitAllowed,rebaseMergeAllowed,squashMergeAllowed,viewerDefaultMergeMethod'
  ];
}

function trimText(value) {
  return String(value ?? '').trim();
}

function buildGitError(args, result) {
  const stderr = trimText(result?.stderr);
  const stdout = trimText(result?.stdout);
  return `git ${args.join(' ')} failed: ${stderr || stdout || `exit ${result?.status ?? 1}`}`;
}

function runGit(repoRoot, args, { spawnSyncFn = spawnSync, ignoreExitCode = false, env = process.env } = {}) {
  const result = spawnSyncFn('git', args, {
    cwd: repoRoot,
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (!ignoreExitCode && result.status !== 0) {
    throw new Error(buildGitError(args, result));
  }
  return result;
}

function gitValue(repoRoot, args, { spawnSyncFn = spawnSync } = {}) {
  return trimText(runGit(repoRoot, args, { spawnSyncFn }).stdout);
}

function buildGhError(args, result) {
  const stderr = trimText(result?.stderr);
  const stdout = trimText(result?.stdout);
  return `gh ${args.join(' ')} failed: ${stderr || stdout || `exit ${result?.status ?? 1}`}`;
}

function isGitHubSshAuthFailure(message) {
  return /Permission denied \(publickey\)|Could not read from remote repository/i.test(String(message || ''));
}

export function classifyRetryablePushTransportFailure(message) {
  const text = trimText(message);
  if (!text) {
    return null;
  }

  if (/bad record mac|SSL_read|curl 56/i.test(text)) {
    return 'transport-tls';
  }
  if (/unexpected disconnect while reading sideband packet|remote end hung up unexpectedly|connection reset by peer/i.test(text)) {
    return 'transport-disconnect';
  }
  if (/RPC failed/i.test(text)) {
    return 'transport-rpc';
  }

  return null;
}

export function isRetryablePushTransportFailure(message) {
  return classifyRetryablePushTransportFailure(message) !== null;
}

function runGh(args, { repoRoot, spawnSyncFn = spawnSync, ignoreExitCode = false } = {}) {
  const result = spawnSyncFn('gh', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (!ignoreExitCode && result.status !== 0) {
    throw new Error(buildGhError(args, result));
  }
  return result;
}

function writeReport(reportPath, payload) {
  mkdirSync(path.dirname(reportPath), { recursive: true });
  writeFileSync(reportPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function getRemoteFetchUrl(repoRoot, remoteName, { spawnSyncFn = spawnSync } = {}) {
  const result = runGit(repoRoot, ['config', '--get', `remote.${remoteName}.url`], {
    spawnSyncFn,
    ignoreExitCode: true
  });
  return trimText(result.stdout);
}

function isAlreadyReadyMessage(message) {
  return /already marked as ready|not in draft state/i.test(String(message || ''));
}

function isAlreadyDraftMessage(message) {
  return /already in draft|already marked as draft/i.test(String(message || ''));
}

function isAutoMergeAlreadyDisabledMessage(message) {
  return /auto-?merge .*not enabled|auto merge is not enabled/i.test(String(message || ''));
}

function viewPullRequest(repoRoot, repoSlug, number, { runGhJsonFn = runGhJson, spawnSyncFn = spawnSync } = {}) {
  return runGhJsonFn(repoRoot, buildPrViewArgs({ repo: repoSlug, number }), { spawnSyncFn });
}

function ensureDraftForReview(repoRoot, repoSlug, pullRequest, { spawnSyncFn = spawnSync } = {}) {
  if (pullRequest?.isDraft) {
    return {
      status: 'already-draft',
      attempted: false
    };
  }

  const args = buildPrReadyArgs({ repo: repoSlug, number: pullRequest.number, undo: true });
  const result = runGh(args, {
    repoRoot,
    spawnSyncFn,
    ignoreExitCode: true
  });
  if (result.status !== 0) {
    const message = buildGhError(args, result);
    if (!isAlreadyDraftMessage(message)) {
      throw new Error(message);
    }
    return {
      status: 'already-draft',
      attempted: true
    };
  }

  return {
    status: 'marked-draft',
    attempted: true
  };
}

function disableAutoMerge(repoRoot, repoSlug, pullRequest, { spawnSyncFn = spawnSync } = {}) {
  if (!pullRequest?.autoMergeRequest) {
    return {
      status: 'already-disabled',
      attempted: false
    };
  }

  const args = buildPrDisableAutoArgs({ repo: repoSlug, number: pullRequest.number });
  const result = runGh(args, {
    repoRoot,
    spawnSyncFn,
    ignoreExitCode: true
  });
  if (result.status !== 0) {
    const message = buildGhError(args, result);
    if (isAutoMergeAlreadyDisabledMessage(message)) {
      return {
        status: 'already-disabled',
        attempted: true
      };
    }
    throw new Error(message);
  }

  return {
    status: 'disabled',
    attempted: true
  };
}

function loadRepositoryMergeSettings(repoRoot, repoSlug, { runGhJsonFn = runGhJson, spawnSyncFn = spawnSync } = {}) {
  return runGhJsonFn(repoRoot, buildRepoViewArgs(repoSlug), { spawnSyncFn }) ?? {};
}

export function resolveAutoMergeMethod(settings = {}) {
  const allowed = [];
  if (settings.squashMergeAllowed === true) {
    allowed.push('squash');
  }
  if (settings.rebaseMergeAllowed === true) {
    allowed.push('rebase');
  }
  if (settings.mergeCommitAllowed === true) {
    allowed.push('merge');
  }

  if (allowed.length === 0) {
    throw new Error('Repository does not allow squash, rebase, or merge auto-merge methods.');
  }

  const preferred = String(settings.viewerDefaultMergeMethod || '')
    .trim()
    .toLowerCase();
  if (preferred === 'squash' && allowed.includes('squash')) {
    return 'squash';
  }
  if (preferred === 'rebase' && allowed.includes('rebase')) {
    return 'rebase';
  }
  if (preferred === 'merge' && allowed.includes('merge')) {
    return 'merge';
  }

  return allowed[0];
}

export function buildDeterministicCommitEnv(commitTimestamp, env = process.env) {
  const normalizedTimestamp = trimText(commitTimestamp);
  if (!normalizedTimestamp) {
    throw new Error('Deterministic remediation commit timestamp is required.');
  }
  return {
    ...env,
    GIT_AUTHOR_NAME: REMEDIATION_COMMIT_AUTHOR_NAME,
    GIT_AUTHOR_EMAIL: REMEDIATION_COMMIT_AUTHOR_EMAIL,
    GIT_AUTHOR_DATE: normalizedTimestamp,
    GIT_COMMITTER_NAME: REMEDIATION_COMMIT_AUTHOR_NAME,
    GIT_COMMITTER_EMAIL: REMEDIATION_COMMIT_AUTHOR_EMAIL,
    GIT_COMMITTER_DATE: normalizedTimestamp
  };
}

function resolveDeterministicCommitTimestamp(repoRoot, divergedHead, { spawnSyncFn = spawnSync } = {}) {
  return gitValue(repoRoot, ['show', '-s', '--format=%cI', divergedHead], { spawnSyncFn });
}

function resolveDivergedDevelopPlaneTransition({
  repoRoot,
  upstream,
  targetRepository,
  loadBranchClassContractFn = loadBranchClassContract
}) {
  const contract = loadBranchClassContractFn(repoRoot);
  const upstreamRepository = upstream ? `${upstream.owner}/${upstream.repo}` : null;
  const forkRepository = targetRepository ? `${targetRepository.owner}/${targetRepository.repo}` : null;
  const fromPlane = resolveRepositoryPlane(upstreamRepository, contract);
  const toPlane = resolveRepositoryPlane(forkRepository, contract);
  const transition = assertPlaneTransition({
    fromPlane,
    toPlane,
    action: 'sync',
    contract
  });

  return {
    ...transition,
    baseRepository: upstreamRepository,
    headRepository: forkRepository
  };
}

function createSyntheticParityCommit(
  repoRoot,
  {
    title,
    reason,
    baseRef,
    headRef,
    upstreamHead,
    divergedHead,
    upstreamTree
  },
  { spawnSyncFn = spawnSync } = {}
) {
  const body = [
    `Synthetic parity remediation staged from ${baseRef} into ${headRef}.`,
    `Trigger reason: ${reason}`,
    `Base head: ${upstreamHead}`,
    `Diverged head: ${divergedHead}`,
    `Upstream tree: ${upstreamTree}`
  ].join('\n');
  const deterministicCommitTimestamp = resolveDeterministicCommitTimestamp(repoRoot, divergedHead, { spawnSyncFn });
  const deterministicCommitEnv = buildDeterministicCommitEnv(deterministicCommitTimestamp);
  const result = runGit(
    repoRoot,
    ['commit-tree', upstreamTree, '-p', divergedHead, '-m', title, '-m', body],
    {
      spawnSyncFn,
      env: deterministicCommitEnv
    }
  );
  const sha = trimText(result.stdout);
  if (!sha) {
    throw new Error('git commit-tree returned an empty commit id.');
  }
  return {
    sha,
    tree: upstreamTree,
    parent: divergedHead,
    timestamp: deterministicCommitTimestamp,
    messageTitle: title
  };
}

function sleepSync(delayMs) {
  if (!Number.isFinite(delayMs) || delayMs <= 0) {
    return;
  }

  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, delayMs);
}

function readRemoteBranchHead(repoRoot, targetRemote, syncBranch, { spawnSyncFn = spawnSync } = {}) {
  const remoteHead = trimText(
    runGit(repoRoot, ['ls-remote', '--heads', targetRemote, syncBranch], {
      spawnSyncFn,
      ignoreExitCode: true
    }).stdout
  );
  return remoteHead.split(/\s+/, 1)[0] || null;
}

function buildPushFailureSummary({
  targetRemote,
  syncBranch,
  remoteHeadBefore,
  remoteHeadAfter = null,
  attemptCount,
  maxAttempts,
  failureMessage,
  failureClassification = null,
  retryable = false
}) {
  return {
    status: retryable ? 'transport-failed' : 'failed',
    remote: targetRemote,
    branch: syncBranch,
    remoteHeadBefore: remoteHeadBefore || null,
    remoteHeadAfter: remoteHeadAfter || null,
    attemptCount,
    maxAttempts,
    retryable,
    retryExhausted: retryable,
    failureClassification,
    failureMessage: trimText(failureMessage)
  };
}

function runPushWithSshFallback(repoRoot, targetRemote, pushArgs, { spawnSyncFn = spawnSync } = {}) {
  try {
    runGit(repoRoot, pushArgs(targetRemote), { spawnSyncFn });
    return;
  } catch (error) {
    if (!isGitHubSshAuthFailure(error.message)) {
      throw error;
    }
    const fetchUrl = getRemoteFetchUrl(repoRoot, targetRemote, { spawnSyncFn });
    if (!fetchUrl || fetchUrl === targetRemote) {
      throw error;
    }
    runGit(repoRoot, pushArgs(fetchUrl), { spawnSyncFn });
  }
}

export function publishSyncBranch(
  repoRoot,
  {
    targetRemote,
    syncBranch,
    syntheticCommitSha
  },
  {
    spawnSyncFn = spawnSync,
    sleepFn = sleepSync,
    maxAttempts = DEFAULT_PUSH_TRANSPORT_RETRY_ATTEMPTS,
    retryDelayMs = DEFAULT_PUSH_TRANSPORT_RETRY_DELAY_MS
  } = {}
) {
  if (!Number.isFinite(maxAttempts) || maxAttempts < 1) {
    throw new Error('publishSyncBranch maxAttempts must be at least 1.');
  }

  const remoteRef = `refs/heads/${syncBranch}`;
  const remoteHeadBefore = readRemoteBranchHead(repoRoot, targetRemote, syncBranch, { spawnSyncFn });

  if (remoteHeadBefore && remoteHeadBefore === syntheticCommitSha) {
    return {
      status: 'already-published',
      remote: targetRemote,
      branch: syncBranch,
      remoteHeadBefore,
      remoteHeadAfter: remoteHeadBefore,
      recoveredFromPushFailure: false,
      attemptCount: 0
    };
  }

  const pushArgs = (destination) => (
    remoteHeadBefore
      ? [
          'push',
          `--force-with-lease=${remoteRef}:${remoteHeadBefore}`,
          destination,
          `${syntheticCommitSha}:${remoteRef}`
        ]
      : ['push', destination, `${syntheticCommitSha}:${remoteRef}`]
  );

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      runPushWithSshFallback(repoRoot, targetRemote, pushArgs, { spawnSyncFn });
      const remoteHeadAfter = readRemoteBranchHead(repoRoot, targetRemote, syncBranch, { spawnSyncFn });
      if (remoteHeadAfter !== syntheticCommitSha) {
        throw new Error(
          `Remediation branch ${targetRemote}/${syncBranch} resolved to ${remoteHeadAfter || '<missing>'}; expected ${syntheticCommitSha}.`
        );
      }

      return {
        status: 'pushed',
        remote: targetRemote,
        branch: syncBranch,
        remoteHeadBefore: remoteHeadBefore || null,
        remoteHeadAfter,
        recoveredFromPushFailure: attempt > 1,
        attemptCount: attempt
      };
    } catch (error) {
      const failureMessage = trimText(error.message);
      const failureClassification = classifyRetryablePushTransportFailure(failureMessage);
      const remoteHeadAfter = readRemoteBranchHead(repoRoot, targetRemote, syncBranch, { spawnSyncFn });
      if (remoteHeadAfter === syntheticCommitSha) {
        return {
          status: 'already-published',
          remote: targetRemote,
          branch: syncBranch,
          remoteHeadBefore: remoteHeadBefore || null,
          remoteHeadAfter,
          recoveredFromPushFailure: true,
          attemptCount: attempt
        };
      }

      if (failureClassification && attempt < maxAttempts) {
        sleepFn(retryDelayMs * attempt);
        continue;
      }

      error.pushSummary = buildPushFailureSummary({
        targetRemote,
        syncBranch,
        remoteHeadBefore,
        remoteHeadAfter,
        attemptCount: attempt,
        maxAttempts,
        failureMessage,
        failureClassification,
        retryable: Boolean(failureClassification)
      });
      throw error;
    }
  }

  throw new Error(`Remediation branch ${targetRemote}/${syncBranch} could not be published.`);
}

export function runDivergedDevelopRemediation({
  repoRoot = getRepoRoot(),
  options = parseArgs(),
  ensureGhCliFn = ensureGhCli,
  resolveUpstreamFn = resolveUpstream,
  ensureForkRemoteFn = ensureForkRemote,
  runGhPrCreateFn = runGhPrCreate,
  runGhJsonFn = runGhJson,
  updateExistingPullRequestFn = updateExistingPullRequest,
  spawnSyncFn = spawnSync,
  loadBranchClassContractFn = loadBranchClassContract
} = {}) {
  if (options.help) {
    printUsage();
    return { reportPath: null, report: null };
  }
  if (!options.targetRemote) {
    throw new Error('Missing required option --target-remote.');
  }
  if (String(options.targetRemote).trim().toLowerCase() !== 'origin') {
    throw new Error(`Diverged develop remediation is only supported for 'origin'. Received '${options.targetRemote}'.`);
  }

  const syncBranch = options.syncBranch || buildDivergedDevelopRemediationBranchName(options.targetRemote, options.branch);
  const reportPath = path.isAbsolute(options.reportPath)
    ? options.reportPath
    : path.join(repoRoot, options.reportPath);

  ensureGhCliFn({ spawnSyncFn });
  const upstream = resolveUpstreamFn(repoRoot);
  const targetRepository = ensureForkRemoteFn(repoRoot, upstream, options.targetRemote, { spawnSyncFn });
  const targetRepoSlug = `${targetRepository.owner}/${targetRepository.repo}`;
  const planeTransition = resolveDivergedDevelopPlaneTransition({
    repoRoot,
    upstream,
    targetRepository,
    loadBranchClassContractFn
  });
  const baseRef = `${options.baseRemote}/${options.branch}`;
  const headRef = `${options.targetRemote}/${options.branch}`;
  const upstreamHead = gitValue(repoRoot, ['rev-parse', baseRef], { spawnSyncFn });
  const divergedHead = gitValue(repoRoot, ['rev-parse', headRef], { spawnSyncFn });
  const upstreamTree = gitValue(repoRoot, ['rev-parse', `${baseRef}^{tree}`], { spawnSyncFn });
  const divergedTree = gitValue(repoRoot, ['rev-parse', `${headRef}^{tree}`], { spawnSyncFn });
  if (upstreamTree === divergedTree) {
    throw new Error(`Tree parity already holds between ${baseRef} and ${headRef}; remediation staging is unnecessary.`);
  }

  const title = buildDivergedDevelopRemediationPrTitle({
    baseRemote: options.baseRemote,
    branch: options.branch
  });
  const syntheticCommit = createSyntheticParityCommit(
    repoRoot,
    {
      title,
      reason: options.reason,
      baseRef,
      headRef,
      upstreamHead,
      divergedHead,
      upstreamTree
    },
    { spawnSyncFn }
  );
  let push = null;
  let pullRequest = null;
  let reusedExisting = false;
  try {
    push = publishSyncBranch(
      repoRoot,
      {
        targetRemote: options.targetRemote,
        syncBranch,
        syntheticCommitSha: syntheticCommit.sha
      },
      { spawnSyncFn }
    );
    const body = buildDivergedDevelopRemediationPrBody({
      upstream,
      targetRepository,
      targetRemote: options.targetRemote,
      baseRemote: options.baseRemote,
      branch: options.branch,
      syncBranch,
      reason: options.reason,
      localHead: options.localHead,
      baseHead: upstreamHead,
      targetHead: divergedHead,
      syntheticCommit: syntheticCommit.sha,
      reference: options.reference
    });

    const createResult = runGhPrCreateFn(
      {
        repoRoot,
        upstream: targetRepository,
        headRepository: targetRepository,
        branch: syncBranch,
        base: options.branch,
        title,
        body
      },
      {
        spawnSyncFn,
        runGhJsonFn
      }
    );

    pullRequest = createResult?.pullRequest ?? null;
    reusedExisting = createResult?.reusedExisting === true;
    const partialReport = buildDivergedDevelopRemediationSummaryPayload({
      targetRemote: options.targetRemote,
      baseRemote: options.baseRemote,
      branch: options.branch,
      syncBranch,
      reason: options.reason,
      localHead: options.localHead,
      upstream,
      targetRepository,
      planeTransition,
      baseRef,
      headRef,
      upstreamHead,
      divergedHead,
      upstreamTree,
      divergedTree,
      syntheticCommit,
      push,
      pullRequest: buildRemediationPullRequestSummary(pullRequest, {
        syncBranch,
        branch: options.branch,
        reusedExisting
      })
    });
    writeReport(reportPath, partialReport);
    if (!pullRequest?.number) {
      throw new Error(`Unable to resolve remediation pull request for ${targetRepoSlug}:${syncBranch}.`);
    }

    if (pullRequest?.number && reusedExisting) {
      updateExistingPullRequestFn(
        repoRoot,
        {
          upstream: targetRepository,
          pullRequest,
          title,
          body
        },
        {
          spawnSyncFn
        }
      );
    }

    const mergeSettings = loadRepositoryMergeSettings(repoRoot, targetRepoSlug, { runGhJsonFn, spawnSyncFn });
    const promotionTarget = {
      syncMethod: 'pull-request-queue',
      mergeMethod: resolveAutoMergeMethod(mergeSettings)
    };

    let viewedPr = viewPullRequest(repoRoot, targetRepoSlug, pullRequest.number, {
      runGhJsonFn,
      spawnSyncFn
    });
    const autoMerge = disableAutoMerge(repoRoot, targetRepoSlug, viewedPr, { spawnSyncFn });
    viewedPr = viewPullRequest(repoRoot, targetRepoSlug, pullRequest.number, {
      runGhJsonFn,
      spawnSyncFn
    });
    const draftState = ensureDraftForReview(repoRoot, targetRepoSlug, viewedPr, { spawnSyncFn });
    viewedPr = viewPullRequest(repoRoot, targetRepoSlug, pullRequest.number, {
      runGhJsonFn,
      spawnSyncFn
    });

    const report = buildDivergedDevelopRemediationSummaryPayload({
      targetRemote: options.targetRemote,
      baseRemote: options.baseRemote,
      branch: options.branch,
      syncBranch,
      reason: options.reason,
      localHead: options.localHead,
      upstream,
      targetRepository,
      planeTransition,
      baseRef,
      headRef,
      upstreamHead,
      divergedHead,
      upstreamTree,
      divergedTree,
      syntheticCommit,
      push,
      pullRequest: buildRemediationPullRequestSummary(viewedPr, {
        syncBranch,
        branch: options.branch,
        reusedExisting
      }),
      draftState,
      autoMerge,
      promotionTarget
    });
    writeReport(reportPath, report);
    return { reportPath, report };
  } catch (error) {
    const pushSummary = error.pushSummary ?? push ?? null;
    if (upstream && targetRepository && planeTransition && syntheticCommit) {
      const failureReport = buildDivergedDevelopRemediationSummaryPayload({
        targetRemote: options.targetRemote,
        baseRemote: options.baseRemote,
        branch: options.branch,
        syncBranch,
        reason: options.reason,
        localHead: options.localHead,
        upstream,
        targetRepository,
        planeTransition,
        baseRef,
        headRef,
        upstreamHead,
        divergedHead,
        upstreamTree,
        divergedTree,
        syntheticCommit,
        push: pushSummary,
        pullRequest: buildRemediationPullRequestSummary(pullRequest, {
          syncBranch,
          branch: options.branch,
          reusedExisting
        }),
        failure: {
          stage: push ? 'finalize-remediation-pr' : 'publish-sync-branch',
          classification: error.pushSummary?.failureClassification ?? null,
          retryable: error.pushSummary?.retryable === true,
          message: trimText(error.message)
        }
      });
      writeReport(reportPath, failureReport);
    }
    const reusableReport = tryBuildReusableRemediationReport({
      repoRoot,
      targetRepoSlug,
      pullRequestNumber: pullRequest.number,
      targetRemote: options.targetRemote,
      baseRemote: options.baseRemote,
      branch: options.branch,
      syncBranch,
      reason: options.reason,
      localHead: options.localHead,
      upstream,
      targetRepository,
      planeTransition,
      baseRef,
      headRef,
      upstreamHead,
      divergedHead,
      upstreamTree,
      divergedTree,
      syntheticCommit,
      push,
      reusedExisting,
      runGhJsonFn,
      spawnSyncFn
    });
    if (reusableReport) {
      writeReport(reportPath, reusableReport);
    }
    throw error;
  }
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const { reportPath } = runDivergedDevelopRemediation({ options });
  console.log(`[priority:diverged-develop-remediation] report=${reportPath}`);
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
    console.error(`[priority:diverged-develop-remediation] ${error.message}`);
    process.exitCode = 1;
  }
}

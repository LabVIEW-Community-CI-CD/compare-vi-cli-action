#!/usr/bin/env node

import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';
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
  'protected-develop-sync-pr.json'
);
const DEFAULT_BRANCH = 'develop';
const DEFAULT_BASE_REMOTE = 'upstream';
function printUsage() {
  console.log('Usage: node tools/priority/protected-develop-sync-pr.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --target-remote <origin|personal>    Fork remote whose protected branch (see --branch) is being synced.');
  console.log(`  --base-remote <name>                  Base remote name used for diagnostics (default: ${DEFAULT_BASE_REMOTE}).`);
  console.log(`  --branch <name>                      Protected branch to sync (default: ${DEFAULT_BRANCH}).`);
  console.log('  --sync-branch <name>                 Deterministic sync branch already pushed to the target remote.');
  console.log('  --reason <text>                      Machine-readable reason for falling back to the PR path.');
  console.log('  --local-head <sha>                   Local HEAD SHA staged onto the sync branch.');
  console.log('  --reference <text>                   Optional issue/epic reference to append to PR body metadata.');
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
    reason: 'protected-branch-gh013',
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

export function buildProtectedSyncBranchName(targetRemote, branch = DEFAULT_BRANCH) {
  if (!String(targetRemote || '').trim()) {
    throw new Error('targetRemote is required.');
  }
  if (!String(branch || '').trim()) {
    throw new Error('branch is required.');
  }
  const sanitizedRemote = String(targetRemote).trim().toLowerCase().replace(/[^a-z0-9._-]/g, '-');
  const sanitizedBranch = String(branch).trim().toLowerCase().replace(/[^a-z0-9._/-]/g, '-');
  return `sync/${sanitizedRemote}-${sanitizedBranch.replace(/\//g, '-')}`;
}

export function buildProtectedSyncPrTitle({ baseRemote = DEFAULT_BASE_REMOTE, branch = DEFAULT_BRANCH } = {}) {
  return `[sync]: align ${branch} with ${baseRemote}/${branch}`;
}

export function buildProtectedSyncPrBody({
  upstream,
  targetRepository,
  targetRemote,
  baseRemote = DEFAULT_BASE_REMOTE,
  branch = DEFAULT_BRANCH,
  syncBranch,
  reason,
  localHead,
  reference = null
}) {
  const upstreamSlug = upstream ? `${upstream.owner}/${upstream.repo}` : '<unknown>';
  const targetSlug = targetRepository ? `${targetRepository.owner}/${targetRepository.repo}` : '<unknown>';
  const lines = [
    '## Summary',
    `- align \`${targetSlug}:${branch}\` with \`${upstreamSlug}:${branch}\``,
    `- stage protected-fork \`${branch}\` sync through a PR / merge-queue path instead of direct push`,
    '',
    '## Testing',
    '- branch sync only; required checks run on this PR',
    '',
    '## Sync Metadata',
    `- target remote: \`${targetRemote}\``,
    `- base remote: \`${baseRemote}\``,
    `- sync branch: \`${syncBranch}\``,
    `- trigger reason: \`${reason}\``
  ];
  if (localHead) {
    lines.push(`- staged head: \`${localHead}\``);
  }
  if (reference) {
    lines.push('', `Refs ${reference}`);
  }
  return lines.join('\n');
}

export function buildProtectedSyncSummaryPayload({
  targetRemote,
  baseRemote,
  branch,
  syncBranch,
  reason,
  localHead,
  upstream,
  targetRepository,
  pullRequest,
  readyState,
  mergeRequest,
  syncMethod = 'protected-pr',
  allowForkSyncing = false,
  mergeUpstream = null,
  mergeUpstreamError = null,
  createdAt = new Date().toISOString()
}) {
  return {
    schema: 'priority/protected-develop-sync@v1',
    generatedAt: createdAt,
    targetRemote,
    baseRemote,
    branch,
    syncBranch,
    reason,
    localHead: localHead ?? null,
    upstreamRepository: upstream ? `${upstream.owner}/${upstream.repo}` : null,
    targetRepository: targetRepository ? `${targetRepository.owner}/${targetRepository.repo}` : null,
    syncMethod,
    allowForkSyncing,
    mergeUpstream,
    mergeUpstreamError,
    pullRequest: pullRequest ?? null,
    readyState: readyState ?? null,
    mergeRequest: mergeRequest ?? null
  };
}

function buildPrListArgs({ repo, branch, head }) {
  return [
    'pr',
    'list',
    '--repo',
    repo,
    '--state',
    'open',
    '--base',
    branch,
    '--head',
    head,
    '--json',
    'number,url,state,isDraft,headRefName,baseRefName,mergeStateStatus'
  ];
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
  ];
}

function buildPrReadyArgs({ repo, number }) {
  return ['pr', 'ready', String(number), '--repo', repo];
}

function buildPrMergeAutoArgs({ repo, number, method = null }) {
  const args = ['pr', 'merge', String(number), '--repo', repo];
  if (typeof method === 'string' && method.trim().length > 0) {
    args.push(`--${method}`);
  }
  args.push('--auto');
  return args;
}

function buildBranchProtectionArgs({ repo, branch }) {
  return ['api', `repos/${repo}/branches/${branch}/protection`];
}

function buildMergeUpstreamArgs({ repo, branch }) {
  return ['api', '-X', 'POST', `repos/${repo}/merge-upstream`, '-f', `branch=${branch}`];
}

function buildGhError(args, result) {
  const stderr = String(result?.stderr ?? '').trim();
  const stdout = String(result?.stdout ?? '').trim();
  return `gh ${args.join(' ')} failed: ${stderr || stdout || `exit ${result?.status ?? 1}`}`;
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

function loadBranchProtection(repoRoot, repoSlug, branch, { runGhJsonFn = runGhJson, spawnSyncFn = spawnSync } = {}) {
  return runGhJsonFn(repoRoot, buildBranchProtectionArgs({ repo: repoSlug, branch }), { spawnSyncFn });
}

function resolveAllowForkSyncing(value) {
  if (typeof value === 'boolean') {
    return value;
  }
  if (value && typeof value === 'object') {
    return value.enabled === true;
  }
  return false;
}

function requestMergeUpstream(repoRoot, repoSlug, branch, { runGhJsonFn = runGhJson, spawnSyncFn = spawnSync } = {}) {
  return runGhJsonFn(repoRoot, buildMergeUpstreamArgs({ repo: repoSlug, branch }), { spawnSyncFn });
}

function isAlreadyReadyMessage(message) {
  return /already marked as ready|not in draft state/i.test(String(message || ''));
}

function isAutoMergeAlreadyEnabledMessage(message) {
  return /auto-?merge .*already enabled/i.test(String(message || ''));
}

function findExistingProtectedSyncPr(repoRoot, repoSlug, branch, syncBranch, { runGhJsonFn = runGhJson, spawnSyncFn = spawnSync } = {}) {
  const pulls = runGhJsonFn(repoRoot, buildPrListArgs({ repo: repoSlug, branch, head: syncBranch }), { spawnSyncFn }) ?? [];
  if (!Array.isArray(pulls) || pulls.length === 0) {
    return null;
  }
  return pulls.find((pull) => pull.headRefName === syncBranch && pull.baseRefName === branch) ?? pulls[0] ?? null;
}

function viewPullRequest(repoRoot, repoSlug, number, { runGhJsonFn = runGhJson, spawnSyncFn = spawnSync } = {}) {
  return runGhJsonFn(repoRoot, buildPrViewArgs({ repo: repoSlug, number }), { spawnSyncFn });
}

function ensureReadyForReview(repoRoot, repoSlug, pullRequest, { spawnSyncFn = spawnSync } = {}) {
  if (!pullRequest?.isDraft) {
    return {
      status: 'already-ready',
      attempted: false
    };
  }

  const result = runGh(buildPrReadyArgs({ repo: repoSlug, number: pullRequest.number }), {
    repoRoot,
    spawnSyncFn,
    ignoreExitCode: true
  });
  if (result.status !== 0) {
    const message = buildGhError(buildPrReadyArgs({ repo: repoSlug, number: pullRequest.number }), result);
    if (!isAlreadyReadyMessage(message)) {
      throw new Error(message);
    }
    return {
      status: 'already-ready',
      attempted: true
    };
  }

  return {
    status: 'marked-ready',
    attempted: true
  };
}

function requestAutoMerge(repoRoot, repoSlug, pullRequest, { spawnSyncFn = spawnSync } = {}) {
  const args = buildPrMergeAutoArgs({ repo: repoSlug, number: pullRequest.number });
  const result = runGh(args, {
    repoRoot,
    spawnSyncFn,
    ignoreExitCode: true
  });
  if (result.status !== 0) {
    const message = buildGhError(args, result);
    if (isAutoMergeAlreadyEnabledMessage(message)) {
      return {
        status: 'already-enabled',
        attempted: true
      };
    }
    throw new Error(message);
  }

  return {
    status: 'requested',
    attempted: true
  };
}

function writeReport(reportPath, payload) {
  mkdirSync(path.dirname(reportPath), { recursive: true });
  writeFileSync(reportPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

export function runProtectedDevelopSync({
  repoRoot = getRepoRoot(),
  options = parseArgs(),
  ensureGhCliFn = ensureGhCli,
  resolveUpstreamFn = resolveUpstream,
  ensureForkRemoteFn = ensureForkRemote,
  runGhPrCreateFn = runGhPrCreate,
  runGhJsonFn = runGhJson,
  updateExistingPullRequestFn = updateExistingPullRequest,
  spawnSyncFn = spawnSync
} = {}) {
  if (options.help) {
    printUsage();
    return { reportPath: null, report: null };
  }
  if (!options.targetRemote) {
    throw new Error('Missing required option --target-remote.');
  }

  const syncBranch = options.syncBranch || buildProtectedSyncBranchName(options.targetRemote, options.branch);
  const reportPath = path.isAbsolute(options.reportPath)
    ? options.reportPath
    : path.join(repoRoot, options.reportPath);

  ensureGhCliFn({ spawnSyncFn });
  const upstream = resolveUpstreamFn(repoRoot);
  const targetRepository = ensureForkRemoteFn(repoRoot, upstream, options.targetRemote, { spawnSyncFn });
  const targetRepoSlug = `${targetRepository.owner}/${targetRepository.repo}`;
  let protection = null;
  try {
    protection = loadBranchProtection(repoRoot, targetRepoSlug, options.branch, {
      runGhJsonFn,
      spawnSyncFn
    });
  } catch {
    protection = null;
  }
  const allowForkSyncing = resolveAllowForkSyncing(protection?.allow_fork_syncing);
  let mergeUpstreamError = null;

  try {
    const mergeUpstream = requestMergeUpstream(repoRoot, targetRepoSlug, options.branch, {
      runGhJsonFn,
      spawnSyncFn
    });
    const report = buildProtectedSyncSummaryPayload({
      targetRemote: options.targetRemote,
      baseRemote: options.baseRemote,
      branch: options.branch,
      syncBranch,
      reason: options.reason,
      localHead: options.localHead,
      upstream,
      targetRepository,
      syncMethod: 'fork-sync',
      allowForkSyncing,
      mergeUpstream,
      mergeUpstreamError
    });
    writeReport(reportPath, report);
    return { reportPath, report };
  } catch (error) {
    mergeUpstreamError = String(error?.message ?? error ?? '').trim() || 'merge-upstream failed';
    // Fall back to PR handoff when the sync API is unavailable on the target fork.
  }

  const title = buildProtectedSyncPrTitle({ baseRemote: options.baseRemote, branch: options.branch });
  const body = buildProtectedSyncPrBody({
    upstream,
    targetRepository,
    targetRemote: options.targetRemote,
    baseRemote: options.baseRemote,
    branch: options.branch,
    syncBranch,
    reason: options.reason,
    localHead: options.localHead,
    reference: options.reference
  });

  let pullRequest = findExistingProtectedSyncPr(repoRoot, targetRepoSlug, options.branch, syncBranch, {
    runGhJsonFn,
    spawnSyncFn
  });
  let reusedExisting = Boolean(pullRequest);
  if (pullRequest?.number) {
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
  } else {
    const createResult = runGhPrCreateFn({
      repoRoot,
      upstream: targetRepository,
      headRepository: targetRepository,
      branch: syncBranch,
      base: options.branch,
      title,
      body
    }, {
      spawnSyncFn,
      runGhJsonFn
    });
    pullRequest = createResult?.pullRequest ?? null;
    reusedExisting = createResult?.reusedExisting === true;
  }

  if (!pullRequest?.number) {
    pullRequest = findExistingProtectedSyncPr(repoRoot, targetRepoSlug, options.branch, syncBranch, {
      runGhJsonFn,
      spawnSyncFn
    });
  }
  if (!pullRequest?.number) {
    throw new Error(`Unable to resolve protected sync PR for ${targetRepoSlug}:${syncBranch}.`);
  }

  let viewedPr = viewPullRequest(repoRoot, targetRepoSlug, pullRequest.number, {
    runGhJsonFn,
    spawnSyncFn
  });
  const readyState = ensureReadyForReview(repoRoot, targetRepoSlug, viewedPr, { spawnSyncFn });
  viewedPr = viewPullRequest(repoRoot, targetRepoSlug, pullRequest.number, {
    runGhJsonFn,
    spawnSyncFn
  });
  const mergeRequest = requestAutoMerge(repoRoot, targetRepoSlug, viewedPr, { spawnSyncFn });
  viewedPr = viewPullRequest(repoRoot, targetRepoSlug, pullRequest.number, {
    runGhJsonFn,
    spawnSyncFn
  });

  const report = buildProtectedSyncSummaryPayload({
    targetRemote: options.targetRemote,
    baseRemote: options.baseRemote,
    branch: options.branch,
    syncBranch,
    reason: options.reason,
    localHead: options.localHead,
    upstream,
    targetRepository,
    syncMethod: 'protected-pr',
    allowForkSyncing,
    mergeUpstreamError,
    pullRequest: {
      number: viewedPr.number,
      url: viewedPr.url,
      state: viewedPr.state ?? null,
      isDraft: Boolean(viewedPr.isDraft),
      headRefName: viewedPr.headRefName ?? syncBranch,
      baseRefName: viewedPr.baseRefName ?? options.branch,
      mergeStateStatus: viewedPr.mergeStateStatus ?? null,
      reusedExisting
    },
    readyState,
    mergeRequest
  });
  writeReport(reportPath, report);
  return { reportPath, report };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const { reportPath } = runProtectedDevelopSync({ options });
  console.log(`[priority:protected-develop-sync] report=${reportPath}`);
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
    console.error(`[priority:protected-develop-sync] ${error.message}`);
    process.exitCode = 1;
  }
}

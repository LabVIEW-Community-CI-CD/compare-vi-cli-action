#!/usr/bin/env node

import { writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { ensureGhCli, resolveUpstream } from './lib/remote-utils.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';

const USAGE_LINES = [
  'Usage: node tools/priority/merge-sync-pr.mjs --pr <number> [options]',
  '',
  'Options:',
  '  --pr <number>            Pull request number to merge (required)',
  '  --repo <owner/repo>      Target repository (defaults to upstream remote)',
  '  --method <merge|squash|rebase>',
  '                           Merge method (default: squash)',
  '  --admin                  Explicitly use admin merge override',
  '  --keep-branch            Keep head branch after merge',
  '  --dry-run                Print selected mode and merge command without executing',
  '  --summary-path <path>    Write JSON summary payload',
  '  -h, --help               Show this message and exit'
];

const MERGE_METHODS = new Set(['merge', 'squash', 'rebase']);
const POLICY_BLOCK_PATTERNS = [
  /merge queue/i,
  /required checks?.*not (?:passing|successful|complete)/i,
  /required status checks?.*pending/i,
  /base branch policy/i,
  /protected branch/i,
  /cannot be merged automatically/i
];

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
        if (!value.includes('/')) {
          throw new Error(`Invalid --repo value '${value}'. Expected owner/repo.`);
        }
        options.repo = value;
      } else if (arg === '--method') {
        if (!MERGE_METHODS.has(value)) {
          throw new Error(`Invalid --method '${value}'. Expected one of: ${Array.from(MERGE_METHODS).join(', ')}`);
        }
        options.method = value;
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

export function selectMergeMode(prInfo, { admin = false, mergeQueueBranches = new Set() } = {}) {
  const state = normalizeUpper(prInfo?.state);
  const mergeState = normalizeUpper(prInfo?.mergeStateStatus);
  const mergeable = normalizeUpper(prInfo?.mergeable);
  const baseRefName = normalizeLower(prInfo?.baseRefName);
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

  if (baseRefName && mergeQueueBranches.has(baseRefName)) {
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
    ['pr', 'view', String(pr), '--repo', repo, '--json', 'number,state,isDraft,mergeStateStatus,mergeable,baseRefName,url'],
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

function buildMergeArgs({ pr, repo, method, mode, keepBranch }) {
  const args = ['pr', 'merge', String(pr), '--repo', repo, `--${method}`];
  if (!keepBranch) {
    args.push('--delete-branch');
  }
  if (mode === 'auto') {
    args.push('--auto');
  } else if (mode === 'admin') {
    args.push('--admin');
  }
  return args;
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
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  console.log(`[priority:merge-sync] wrote summary: ${resolved}`);
}

export async function runMergeSync({
  argv = process.argv,
  repoRoot = getRepoRoot(),
  ensureGhCliFn = ensureGhCli,
  resolveUpstreamFn = resolveUpstream
} = {}) {
  const options = parseArgs(argv);

  ensureGhCliFn();
  const resolvedRepo = options.repo ?? (() => {
    const upstream = resolveUpstreamFn(repoRoot);
    return `${upstream.owner}/${upstream.repo}`;
  })();

  const policyRaw = await readFile(manifestPath, 'utf8');
  const policy = JSON.parse(policyRaw);
  const mergeQueueBranches = getMergeQueueBranches(policy);

  const prInfo = readPrInfo({
    repoRoot,
    repo: resolvedRepo,
    pr: options.pr
  });
  const selection = selectMergeMode(prInfo, { admin: options.admin, mergeQueueBranches });
  console.log(
    `[priority:merge-sync] selected mode=${selection.mode} reason=${selection.reason} mergeState=${prInfo.mergeStateStatus ?? 'n/a'}`
  );

  const attempts = [];
  let finalMode = selection.mode;
  let finalReason = selection.reason;

  if (selection.mode !== 'none') {
    const initialArgs = buildMergeArgs({
      pr: options.pr,
      repo: resolvedRepo,
      method: options.method,
      mode: selection.mode,
      keepBranch: options.keepBranch
    });
    const initialResult = runMergeAttempt({ repoRoot, args: initialArgs, dryRun: options.dryRun });
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
          method: options.method,
          mode: 'auto',
          keepBranch: options.keepBranch
        });
        const retryResult = runMergeAttempt({ repoRoot, args: retryArgs, dryRun: options.dryRun });
        attempts.push({
          mode: 'auto',
          args: retryArgs,
          exitCode: retryResult.status ?? 1
        });
        if (retryResult.status !== 0) {
          throw new Error(
            `[priority:merge-sync] auto-merge retry failed. Use --admin only when explicitly required for policy exception.`
          );
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

  const payload = {
    schema: 'priority/sync-merge@v1',
    createdAt: new Date().toISOString(),
    repo: resolvedRepo,
    pr: options.pr,
    mergeMethod: options.method,
    selectedMode: selection.mode,
    selectedReason: selection.reason,
    finalMode,
    finalReason,
    dryRun: options.dryRun,
    policyTrace: buildPolicyTrace(mergeQueueBranches),
    attempts,
    prState: {
      state: prInfo.state ?? null,
      mergeStateStatus: prInfo.mergeStateStatus ?? null,
      mergeable: prInfo.mergeable ?? null,
      baseRefName: prInfo.baseRefName ?? null,
      isDraft: Boolean(prInfo.isDraft)
    },
    prUrl: prInfo.url ?? null
  };
  await maybeWriteSummary(options.summaryPath, payload);

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

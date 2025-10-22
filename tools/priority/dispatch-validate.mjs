#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { run, getRepoRoot, getCurrentBranch } from './lib/branch-utils.mjs';
import { resolveRepoContext } from './lib/git-context.mjs';
import { ensureGhCli } from './lib/remote-utils.mjs';

const USAGE = [
  'Usage: node tools/priority/dispatch-validate.mjs [--ref <branch>] [--allow-fork]',
  '',
  'Dispatches the Validate workflow on the upstream repository after ensuring the',
  'target ref exists on that remote. Fails fast when executed from a fork clone,',
  'unless --allow-fork (or VALIDATE_DISPATCH_ALLOW_FORK=1) is provided.'
];

function printUsage() {
  for (const line of USAGE) {
    console.log(line);
  }
}

export function parseCliOptions(argv = process.argv, env = process.env) {
  const args = Array.isArray(argv) ? argv.slice(2) : [];
  let ref = null;
  let allowFork = env.VALIDATE_DISPATCH_ALLOW_FORK === '1';

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--help' || arg === '-h') {
      return { help: true, ref, allowFork };
    }
    if (arg === '--ref') {
      if (i + 1 >= args.length) {
        throw new Error('--ref requires a value');
      }
      ref = args[i + 1];
      i += 1;
      continue;
    }
    if (arg === '--allow-fork') {
      allowFork = true;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return { help: false, ref, allowFork };
}

export function ensureRemoteHasRef(repoRoot, remoteName, ref) {
  const patterns = [ref];
  if (!ref.startsWith('refs/')) {
    patterns.push(`refs/heads/${ref}`);
    patterns.push(`refs/tags/${ref}`);
  }

  for (const pattern of patterns) {
    const probe = spawnSync(
      'git',
      ['ls-remote', '--exit-code', remoteName, pattern],
      { cwd: repoRoot, stdio: 'ignore', encoding: 'utf8' }
    );
    if (probe.status === 0) {
      return pattern;
    }
  }

  throw new Error(
    `Ref '${ref}' not found on remote '${remoteName}'. Push it first (git push ${remoteName} ${ref}).`
  );
}

export function dispatchValidate({
  argv = process.argv,
  env = process.env,
  runFn = run,
  ensureGhCliFn = ensureGhCli,
  resolveContextFn = resolveRepoContext,
  getRepoRootFn = getRepoRoot,
  getCurrentBranchFn = getCurrentBranch,
  ensureRemoteHasRefFn = ensureRemoteHasRef,
  remoteName = 'upstream'
} = {}) {
  const { help, ref: refArg, allowFork } = parseCliOptions(argv, env);
  if (help) {
    printUsage();
    return { dispatched: false, help: true };
  }

  const repoRoot = getRepoRootFn();
  ensureGhCliFn();
  const context = resolveContextFn(repoRoot);
  if (!context?.upstream?.owner || !context?.upstream?.repo) {
    throw new Error('Unable to resolve upstream repository. Configure an upstream remote.');
  }

  if (context.isFork && !allowFork) {
    throw new Error(
      'Validate dispatch blocked: working copy points to a fork. Push your branch to upstream and rerun, or pass --allow-fork.'
    );
  }

  let ref = refArg;
  if (!ref) {
    ref = getCurrentBranchFn();
  }
  if (!ref || ref === 'HEAD') {
    throw new Error('Unable to determine ref. Pass --ref <branch> explicitly.');
  }

  ensureRemoteHasRefFn(repoRoot, remoteName, ref);

  const slug = `${context.upstream.owner}/${context.upstream.repo}`;
  runFn(
    'gh',
    ['workflow', 'run', 'validate.yml', '--repo', slug, '--ref', ref],
    { cwd: repoRoot }
  );

  let runSummary = null;
  try {
    const json = runFn(
      'gh',
      [
        'run',
        'list',
        '--repo',
        slug,
        '--workflow',
        'Validate',
        '--branch',
        ref,
        '--json',
        'databaseId,headSha,status,conclusion,createdAt',
        '-L',
        '1'
      ],
      { cwd: repoRoot }
    );
    if (json) {
      const parsed = JSON.parse(json);
      if (Array.isArray(parsed) && parsed.length > 0) {
        runSummary = parsed[0];
      }
    }
  } catch (err) {
    console.warn(`[validate] Warning: unable to query latest Validate run: ${err.message}`);
  }

  const message = `[validate] Dispatched Validate on ${slug} @ ${ref}` + (runSummary?.databaseId ? ` (run ${runSummary.databaseId})` : '');
  console.log(message);

  return {
    dispatched: true,
    repo: slug,
    ref,
    run: runSummary
  };
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    dispatchValidate();
  } catch (err) {
    console.error(`[validate] ${err.message}`);
    process.exit(1);
  }
}

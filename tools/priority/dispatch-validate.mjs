#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { run, getRepoRoot, getCurrentBranch, ensureCleanWorkingTree } from './lib/branch-utils.mjs';
import { resolveRepoContext } from './lib/git-context.mjs';
import { ensureGhCli } from './lib/remote-utils.mjs';

const USAGE = [
  'Usage: node tools/priority/dispatch-validate.mjs [--ref <branch>] [--allow-fork] [--push-missing] [--force-push-ok]',
  '',
  'Dispatches the Validate workflow on the upstream repository after ensuring the',
  'target ref exists on that remote. Fails fast when executed from a fork clone,',
  'unless --allow-fork (or VALIDATE_DISPATCH_ALLOW_FORK=1) is provided.',
  '',
  '--push-missing (or VALIDATE_DISPATCH_PUSH=1) will publish the local branch to the upstream remote when missing.',
  '--force-push-ok (or VALIDATE_DISPATCH_FORCE_PUSH=1) allows overwriting the upstream branch when combined with auto-push.'
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
  let pushMissing = env.VALIDATE_DISPATCH_PUSH === '1';
  let forcePushOk = env.VALIDATE_DISPATCH_FORCE_PUSH === '1';

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--help' || arg === '-h') {
      return { help: true, ref, allowFork, pushMissing, forcePushOk };
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
    if (arg === '--push-missing') {
      pushMissing = true;
      continue;
    }
    if (arg === '--force-push-ok') {
      forcePushOk = true;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return { help: false, ref, allowFork, pushMissing, forcePushOk };
}

export function ensureRemoteHasRef(repoRoot, remoteName, ref) {
  const remote = findRemoteRef(repoRoot, remoteName, ref);
  if (remote) {
    return remote;
  }

  throw new Error(
    `Ref '${ref}' not found on remote '${remoteName}'. Push it first (git push ${remoteName} ${ref}).`
  );
}

export function findRemoteRef(repoRoot, remoteName, ref) {
  const patterns = [];
  if (ref.startsWith('refs/')) {
    patterns.push(ref);
  } else {
    patterns.push(`refs/heads/${ref}`);
    patterns.push(`refs/tags/${ref}`);
    patterns.push(ref);
  }
  const seen = new Set();

  for (const pattern of patterns) {
    if (seen.has(pattern)) {
      continue;
    }
    seen.add(pattern);

    const probe = spawnSync(
      'git',
      ['ls-remote', '--exit-code', remoteName, pattern],
      { cwd: repoRoot, stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8' }
    );

    if (probe.status === 0 && probe.stdout) {
      const lines = probe.stdout.split('\n').map((line) => line.trim()).filter(Boolean);
      for (const line of lines) {
        const [sha, refName] = line.split(/\s+/);
        if (!sha || !refName) {
          continue;
        }
        if (refName === pattern) {
          return { pattern: refName, sha };
        }
        if (!ref.startsWith('refs/')) {
          const asBranch = `refs/heads/${ref}`;
          const asTag = `refs/tags/${ref}`;
          if (refName === asBranch || refName === asTag) {
            return { pattern: refName, sha };
          }
        }
      }
    }

    if (probe.status !== 0 && probe.status !== 2) {
      throw new Error(
        `git ls-remote ${remoteName} ${pattern} failed with exit code ${probe.status}`
      );
    }
  }

  return null;
}

export function dispatchValidate({
  argv = process.argv,
  env = process.env,
  runFn = run,
  ensureGhCliFn = ensureGhCli,
  resolveContextFn = resolveRepoContext,
  getRepoRootFn = getRepoRoot,
  getCurrentBranchFn = getCurrentBranch,
  findRemoteRefFn = findRemoteRef,
  ensureRemoteHasRefFn = ensureRemoteHasRef,
  ensureCleanWorkingTreeFn = ensureCleanWorkingTree,
  remoteName = 'upstream'
} = {}) {
  const {
    help,
    ref: refArg,
    allowFork,
    pushMissing,
    forcePushOk
  } = parseCliOptions(argv, env);
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

  const localFullRef = runFn(
    'git',
    ['rev-parse', '--symbolic-full-name', ref],
    { cwd: repoRoot }
  );
  const localSha = runFn(
    'git',
    ['rev-parse', '--verify', ref],
    { cwd: repoRoot }
  );

  if (localFullRef.startsWith('refs/tags/')) {
    throw new Error(
      `Validate dispatch requires a branch ref, but '${ref}' resolves to tag '${localFullRef}'.`
    );
  }
  if (!localFullRef.startsWith('refs/heads/')) {
    throw new Error(
      `Validate dispatch requires a local branch ref. Unable to derive branch name from '${ref}'.`
    );
  }

  const branchName = localFullRef.slice('refs/heads/'.length);
  let remoteRef = findRemoteRefFn(repoRoot, remoteName, ref);

  const ensureCleanBeforePush = () =>
    ensureCleanWorkingTreeFn(
      (command, args) => runFn(command, args, { cwd: repoRoot }),
      'Working tree not clean. Commit or stash changes before pushing to upstream.'
    );

  if (!remoteRef) {
    console.log(`[validate] Ref '${branchName}' not found on remote '${remoteName}'.`);
    if (!pushMissing) {
      console.log(
        "[validate] Hint: rerun with --push-missing (or set VALIDATE_DISPATCH_PUSH=1) to publish the branch automatically."
      );
      throw new Error(
        `Ref '${ref}' not found on remote '${remoteName}'. Push it first (git push ${remoteName} ${branchName}).`
      );
    }

    ensureCleanBeforePush();
    console.log(`[validate] Pushing '${branchName}' to '${remoteName}'...`);
    const pushArgs = ['push', remoteName];
    if (forcePushOk) {
      pushArgs.push('--force-with-lease');
    }
    pushArgs.push(`${localFullRef}:${localFullRef}`);
    runFn('git', pushArgs, { cwd: repoRoot });

    remoteRef = ensureRemoteHasRefFn(repoRoot, remoteName, ref);
  }

  if (remoteRef.pattern?.startsWith('refs/tags/')) {
    throw new Error(
      `Ref '${ref}' resolves to tag '${remoteRef.pattern}' on '${remoteName}'. Provide a branch ref for Validate dispatch.`
    );
  }

  if (remoteRef.sha && remoteRef.sha !== localSha) {
    if (!pushMissing) {
      throw new Error(
        `Ref '${ref}' on '${remoteName}' points to ${remoteRef.sha}, but local branch '${branchName}' is ${localSha}. ` +
          `Push the branch (git push ${remoteName} ${branchName}) or rerun with --push-missing to align automatically.`
      );
    }

    if (!forcePushOk) {
      throw new Error(
        `Ref '${ref}' on '${remoteName}' points to ${remoteRef.sha}, but local branch '${branchName}' is ${localSha}. ` +
          'Pass --force-push-ok to overwrite the upstream tip or reconcile manually before dispatch.'
      );
    }

    ensureCleanBeforePush();
    console.log(
      `[validate] Upstream ref '${branchName}' differs from local tip. Forcing push of ${localSha} to '${remoteName}'.`
    );
    const pushArgs = ['push', remoteName, '--force-with-lease', `${localFullRef}:${localFullRef}`];
    runFn('git', pushArgs, { cwd: repoRoot });

    const updatedRef = findRemoteRefFn(repoRoot, remoteName, ref);
    if (!updatedRef || updatedRef.sha !== localSha) {
      throw new Error(
        `Force push to '${remoteName}' did not update ref '${ref}' to ${localSha}. Aborting Validate dispatch.`
      );
    }
    remoteRef = updatedRef;
  }

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

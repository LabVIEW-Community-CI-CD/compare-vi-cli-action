#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureValidIdentifier,
  ensureCleanWorkingTree,
  ensureBranchExists,
  getRepoRoot
} from './lib/branch-utils.mjs';
import {
  ensureGhCli,
  resolveUpstream,
  ensureOriginFork,
  pushToRemote
} from './lib/remote-utils.mjs';
import {
  normalizeVersionInput,
  writeReleaseMetadata,
  summarizeStatusChecks
} from './lib/release-utils.mjs';

const USAGE_LINES = [
  'Usage: npm run release:finalize -- <version>',
  '',
  'Fast-forwards main to release/<version>, creates a draft GitHub release, and fast-forwards develop to match.',
  '',
  'Options:',
  '  -h, --help    Show this message and exit'
];

async function readPackageVersion(repoRoot) {
  const pkgPath = path.join(repoRoot, 'package.json');
  const raw = await readFile(pkgPath, 'utf8');
  const pkg = JSON.parse(raw);
  if (!pkg.version) {
    throw new Error('package.json missing version field');
  }
  return String(pkg.version);
}

function buildReleaseTitle(tag) {
  return process.env.RELEASE_TITLE ?? `Release ${tag}`;
}

function buildReleaseNotes(tag) {
  if (process.env.RELEASE_NOTES) {
    return process.env.RELEASE_NOTES;
  }
  return `Draft release for ${tag}`;
}

function ensureReleasePrReady(repoRoot, branch) {
  if (process.env.RELEASE_FINALIZE_SKIP_CHECKS === '1') {
    console.warn('[release:finalize] skipping PR status checks (RELEASE_FINALIZE_SKIP_CHECKS=1)');
    return null;
  }

  let infoRaw;
  try {
    infoRaw = run('gh', ['pr', 'view', branch, '--json', 'number,state,mergeStateStatus,statusCheckRollup,url'], {
      cwd: repoRoot
    });
  } catch (error) {
    throw new Error(
      `Unable to fetch release PR for ${branch}: ${error.message}. Set RELEASE_FINALIZE_SKIP_CHECKS=1 to override.`
    );
  }

  let info = null;
  try {
    info = JSON.parse(infoRaw);
  } catch (error) {
    throw new Error(`Failed to parse release PR details: ${error.message}`);
  }

  if (!info) {
    throw new Error('Release PR metadata unavailable.');
  }

  const state = typeof info.state === 'string' ? info.state.toUpperCase() : info.state;
  if (state === 'MERGED') {
    if (process.env.RELEASE_FINALIZE_ALLOW_MERGED === '1') {
      console.warn('[release:finalize] release PR already merged; proceeding due to RELEASE_FINALIZE_ALLOW_MERGED=1');
    } else {
      throw new Error('Release PR is already merged. Set RELEASE_FINALIZE_ALLOW_MERGED=1 to proceed.');
    }
  } else if (state && state !== 'OPEN') {
    throw new Error(`Release PR state is ${info.state}. Finalize aborted.`);
  }

  const mergeStateStatus = info.mergeStateStatus ?? null;
  if (
    mergeStateStatus &&
    mergeStateStatus !== 'CLEAN' &&
    process.env.RELEASE_FINALIZE_ALLOW_DIRTY !== '1'
  ) {
    throw new Error(
      `Release PR merge state is ${mergeStateStatus}. Resolve pending checks or set RELEASE_FINALIZE_ALLOW_DIRTY=1.`
    );
  }

  const failingChecks = (info.statusCheckRollup || []).filter(
    (check) => check.status !== 'COMPLETED' || check.conclusion !== 'SUCCESS'
  );
  if (failingChecks.length > 0 && process.env.RELEASE_FINALIZE_ALLOW_DIRTY !== '1') {
    const detail = failingChecks
      .map((check) => `${check.name} (${check.conclusion ?? check.status ?? 'unknown'})`)
      .join(', ');
    throw new Error(`Release PR has failing or pending checks: ${detail}.`);
  }

  return {
    number: info.number ?? null,
    url: info.url ?? null,
    mergeStateStatus,
    checks: summarizeStatusChecks(info.statusCheckRollup ?? [])
  };
}

async function main() {
  const versionInput = parseSingleValueArg(process.argv, {
    usageLines: USAGE_LINES,
    valueLabel: '<version>'
  });
  ensureValidIdentifier(versionInput.replace(/^v/, ''), { label: 'version' });
  const { tag, semver } = normalizeVersionInput(versionInput);

  const repoRoot = getRepoRoot();
  process.chdir(repoRoot);
  ensureCleanWorkingTree(run, 'Working tree not clean. Commit or stash changes before finalizing the release.');

  const releaseBranch = `release/${tag}`;
  ensureBranchExists(releaseBranch);

  ensureGhCli();
  const upstream = resolveUpstream(repoRoot);
  ensureOriginFork(repoRoot, upstream);

  const prInfo = ensureReleasePrReady(repoRoot, releaseBranch);

  run('git', ['fetch', 'origin'], { cwd: repoRoot });
  run('git', ['fetch', 'upstream'], { cwd: repoRoot });

  const originalBranch = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot });

  let finalizeMetadata = null;
  let restoreBranch = true;

  try {
    run('git', ['checkout', releaseBranch], { cwd: repoRoot });
    try {
      run('git', ['pull', '--ff-only'], { cwd: repoRoot });
    } catch (error) {
      console.warn(`[release:finalize] warning: unable to fast-forward ${releaseBranch}: ${error.message}`);
    }

    const releaseCommit = run('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });
    const pkgVersion = await readPackageVersion(repoRoot);
    if (pkgVersion !== semver) {
      throw new Error(`package.json version ${pkgVersion} does not match expected ${semver}`);
    }

    run('git', ['checkout', '-B', 'main', 'upstream/main'], { cwd: repoRoot });
    run('git', ['merge', '--ff-only', releaseBranch], { cwd: repoRoot });
    pushToRemote(repoRoot, 'upstream', 'main');
    const mainCommit = run('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });

    const releaseTitle = buildReleaseTitle(tag);
    const releaseNotes = buildReleaseNotes(tag);
    run('gh', ['release', 'create', tag, '--draft', '--target', releaseCommit, '--title', releaseTitle, '--notes', releaseNotes], {
      cwd: repoRoot,
      stdio: 'inherit',
      encoding: 'utf8'
    });

    run('git', ['checkout', '-B', 'develop', 'upstream/develop'], { cwd: repoRoot });
    const mergeBase = run('git', ['merge-base', 'develop', releaseBranch], { cwd: repoRoot });
    if (mergeBase !== releaseCommit) {
      run('git', ['merge', '--ff-only', releaseBranch], { cwd: repoRoot });
    }
    pushToRemote(repoRoot, 'upstream', 'develop');
    const developCommit = run('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });

    finalizeMetadata = {
      schema: 'release/finalize@v1',
      version: tag,
      semver,
      releaseBranch,
      releaseCommit,
      mainCommit,
      developCommit,
      draftedRelease: tag,
      pullRequest: prInfo,
      completedAt: new Date().toISOString()
    };

    if (originalBranch) {
      try {
        run('git', ['checkout', originalBranch], { cwd: repoRoot });
      } catch (error) {
        console.warn(`[release:finalize] warning: failed to restore ${originalBranch}: ${error.message}`);
      }
    }

    restoreBranch = false;
  } finally {
    if (restoreBranch && originalBranch) {
      try {
        run('git', ['checkout', originalBranch], { cwd: repoRoot });
      } catch (error) {
        console.warn(`[release:finalize] warning: failed to restore ${originalBranch}: ${error.message}`);
      }
    }
  }

  if (finalizeMetadata) {
    await writeReleaseMetadata(repoRoot, tag, 'finalize', finalizeMetadata);
    console.log(`[release:finalize] Draft release created for ${tag}. Main and develop fast-forwarded.`);
  }
}

main().catch((error) => {
  console.error(`[release:finalize] ${error.message}`);
  process.exit(1);
});

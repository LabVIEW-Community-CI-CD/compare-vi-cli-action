#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
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

  const prView = spawnSync(
    'gh',
    ['pr', 'view', branch, '--json', 'number,state,mergeStateStatus,statusCheckRollup,url'],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );

  if (prView.status !== 0) {
    const stderr = prView.stderr ?? '';
    const stdout = prView.stdout ?? '';
    const diagnostic = `${stderr}${stdout}`;
    const missing =
      diagnostic.includes('no pull requests found') ||
      diagnostic.includes('GraphQL: Could not resolve to a PullRequest') ||
      diagnostic.includes('Not Found');

    if (!missing) {
      throw new Error(
        `Unable to fetch release PR for ${branch}: gh pr view failed with exit code ${prView.status}. Set RELEASE_FINALIZE_SKIP_CHECKS=1 to override.`
      );
    }

    const mergedProbe = spawnSync(
      'gh',
      ['pr', 'list', '--state', 'merged', '--head', branch, '--json', 'number,url'],
      {
        cwd: repoRoot,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe']
      }
    );

    if (mergedProbe.status === 0) {
      try {
        const mergedList = JSON.parse(mergedProbe.stdout ?? '[]');
        if (Array.isArray(mergedList) && mergedList.length > 0) {
          const merged = mergedList[0];
          console.warn(
            `[release:finalize] release PR for ${branch} already merged (PR #${merged.number ?? 'unknown'}).`
          );
          return {
            number: merged.number ?? null,
            url: merged.url ?? null,
            mergeStateStatus: 'MERGED',
            checks: summarizeStatusChecks([])
          };
        }
      } catch {
        /* ignore JSON errors, fall through to generic warning */
      }
    }

    console.warn(
      `[release:finalize] release PR for ${branch} not found (likely merged and branch deleted). Continuing without PR checks.`
    );
    return null;
  }

  let info = null;
  try {
    info = JSON.parse(prView.stdout ?? '');
  } catch (error) {
    throw new Error(`Failed to parse release PR details: ${error.message}`);
  }

  if (!info) {
    throw new Error('Release PR metadata unavailable.');
  }

  const state = typeof info.state === 'string' ? info.state.toUpperCase() : info.state;
  if (state === 'MERGED') {
    console.warn('[release:finalize] release PR already merged; continuing.');
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

function isAncestor(repoRoot, ancestorRef, descendantRef) {
  const result = spawnSync('git', ['merge-base', '--is-ancestor', ancestorRef, descendantRef], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'ignore', 'inherit']
  });
  return result.status === 0;
}

function refsEqual(repoRoot, refA, refB) {
  const result = spawnSync('git', ['diff', '--quiet', refA, refB], {
    cwd: repoRoot,
    stdio: ['ignore', 'ignore', 'inherit']
  });
  return result.status === 0;
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
    try {
      run('git', ['merge', '--ff-only', releaseBranch], { cwd: repoRoot });
    } catch (error) {
      if (isAncestor(repoRoot, releaseCommit, 'HEAD')) {
        console.warn(
          `[release:finalize] ${releaseBranch} already integrated into main; skipping fast-forward (${error.message}).`
        );
      } else if (refsEqual(repoRoot, releaseBranch, 'HEAD')) {
        console.warn(
          `[release:finalize] ${releaseBranch} tree matches main; treating fast-forward failure as no-op (${error.message}).`
        );
      } else {
        throw error;
      }
    }
    pushToRemote(repoRoot, 'upstream', 'main');
    const mainCommit = run('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });

    const releaseTitle = buildReleaseTitle(tag);
    const releaseNotes = buildReleaseNotes(tag);
    const releaseResult = spawnSync(
      'gh',
      ['release', 'create', tag, '--draft', '--target', releaseCommit, '--title', releaseTitle, '--notes', releaseNotes],
      {
        cwd: repoRoot,
        stdio: 'inherit',
        encoding: 'utf8'
      }
    );
    if (releaseResult.status !== 0) {
      throw new Error('gh release create failed. Review the output above.');
    }

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

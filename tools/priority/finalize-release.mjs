#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureValidIdentifier,
  ensureCleanWorkingTree,
  ensureBranchExists,
  getRepoRoot,
  getCurrentCheckoutTarget,
  checkoutDetachedRef
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
  summarizeStatusChecks,
  assertReleaseMetadataExists,
  ensureReleaseBranchMetadata
} from './lib/release-utils.mjs';
import {
  readSessionIndexHygiene,
  parseRogueScanOutput,
  ensureRogueScanClean
} from './lib/release-hygiene.mjs';
import { collectBlockingCompareEvidence } from './lib/release-compare-evidence.mjs';
import {
  loadReleaseRequiredChecks,
  assertRequiredReleaseChecksClean,
  assertReleasePrMergeReady
} from './lib/release-pr-checks.mjs';
import { collectStandingPriorityParityGate } from './lib/release-priority-parity.mjs';
import {
  readReleaseSurfaceVersions,
  evaluateReleaseSurfaceVersionExpectations
} from './lib/release-surface-versions.mjs';

const USAGE_LINES = [
  'Usage: node tools/npm/run-script.mjs release:finalize -- <version>',
  '',
  'Fast-forwards main to release/<version>, creates a draft GitHub release, and fast-forwards develop to match.',
  '',
  'Options:',
  '  -h, --help    Show this message and exit'
];

function buildReleaseTitle(tag) {
  return process.env.RELEASE_TITLE ?? `Release ${tag}`;
}

function buildReleaseNotes(tag) {
  if (process.env.RELEASE_NOTES) {
    return process.env.RELEASE_NOTES;
  }
  return `Draft release for ${tag}`;
}

function ensureReleasePrReady(repoRoot, branch, requiredChecks = []) {
  if (process.env.RELEASE_FINALIZE_SKIP_CHECKS === '1') {
    console.warn('[release:finalize] skipping PR status checks (RELEASE_FINALIZE_SKIP_CHECKS=1)');
    return null;
  }

  const prView = spawnSync(
    'gh',
    ['pr', 'view', branch, '--json', 'number,state,mergeStateStatus,mergeable,statusCheckRollup,url'],
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
            mergeable: null,
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
  const mergeable = info.mergeable ?? null;
  assertReleasePrMergeReady(info, {
    allowDirty: process.env.RELEASE_FINALIZE_ALLOW_DIRTY === '1'
  });

  let requiredEvaluation = null;
  if (process.env.RELEASE_FINALIZE_ALLOW_DIRTY !== '1') {
    requiredEvaluation = assertRequiredReleaseChecksClean(requiredChecks, info.statusCheckRollup ?? []);
  } else if (requiredChecks.length > 0) {
    requiredEvaluation = {
      skipped: true,
      reason: 'RELEASE_FINALIZE_ALLOW_DIRTY=1'
    };
  }

  return {
    number: info.number ?? null,
    url: info.url ?? null,
    mergeStateStatus,
    mergeable,
    checks: summarizeStatusChecks(info.statusCheckRollup ?? []),
    requiredChecks: requiredEvaluation
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

function hasSharedHistory(repoRoot, refA, refB) {
  const result = spawnSync('git', ['merge-base', refA, refB], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore']
  });
  return result.status === 0 && Boolean((result.stdout ?? '').trim());
}

function collectReleaseHygiene(repoRoot) {
  if (process.env.RELEASE_FINALIZE_SKIP_HYGIENE === '1') {
    console.warn('[release:finalize] skipping session-index/rogue hygiene checks (RELEASE_FINALIZE_SKIP_HYGIENE=1)');
    return {
      skipped: true,
      reason: 'RELEASE_FINALIZE_SKIP_HYGIENE=1'
    };
  }

  const sessionIndex = readSessionIndexHygiene(repoRoot);
  const lookbackSeconds = process.env.RELEASE_ROGUE_LOOKBACK_SECONDS ?? '900';
  const rogueScan = spawnSync(
    'pwsh',
    ['-NoLogo', '-NoProfile', '-File', 'tools/Detect-RogueLV.ps1', '-ResultsDir', 'tests/results', '-LookBackSeconds', lookbackSeconds, '-Quiet'],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );

  if (rogueScan.status !== 0) {
    const details = (rogueScan.stderr || rogueScan.stdout || '').trim();
    throw new Error(`Rogue scan execution failed before finalize (exit ${rogueScan.status}). ${details}`);
  }

  const rogueReport = parseRogueScanOutput(rogueScan.stdout);
  const rogueSummary = ensureRogueScanClean(rogueReport);
  return {
    skipped: false,
    sessionIndex,
    rogueScan: rogueSummary
  };
}

function ghJson(repoRoot, args) {
  const out = run('gh', args, { cwd: repoRoot });
  try {
    return JSON.parse(out || 'null');
  } catch (error) {
    throw new Error(`Failed to parse gh JSON output for "gh ${args.join(' ')}": ${error.message}`);
  }
}

async function collectCompareEvidenceGate(repoRoot, upstream, releaseBranch) {
  if (process.env.RELEASE_FINALIZE_SKIP_COMPARE_EVIDENCE === '1') {
    console.warn('[release:finalize] skipping compare evidence gate (RELEASE_FINALIZE_SKIP_COMPARE_EVIDENCE=1)');
    return {
      skipped: true,
      reason: 'RELEASE_FINALIZE_SKIP_COMPARE_EVIDENCE=1'
    };
  }

  const repoSlug = `${upstream.owner}/${upstream.repo}`;
  const evidence = await collectBlockingCompareEvidence({
    repoSlug,
    branch: releaseBranch,
    ghJsonFn: (args) => ghJson(repoRoot, args)
  });
  return {
    skipped: false,
    repository: repoSlug,
    workflows: evidence
  };
}

function resolveParityTipDiffTarget() {
  const raw = process.env.RELEASE_PARITY_TIP_DIFF_TARGET;
  if (raw == null || raw === '') return 0;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid RELEASE_PARITY_TIP_DIFF_TARGET: ${raw}`);
  }
  return value;
}

async function collectStandingPriorityParityEvidence(repoRoot) {
  if (process.env.RELEASE_FINALIZE_SKIP_PRIORITY_PARITY === '1') {
    console.warn('[release:finalize] skipping standing-priority/parity gate (RELEASE_FINALIZE_SKIP_PRIORITY_PARITY=1)');
    return {
      skipped: true,
      reason: 'RELEASE_FINALIZE_SKIP_PRIORITY_PARITY=1'
    };
  }

  const baseRef = process.env.RELEASE_PARITY_BASE_REF || 'upstream/develop';
  const headRef = process.env.RELEASE_PARITY_HEAD_REF || 'origin/develop';
  const tipDiffTarget = resolveParityTipDiffTarget();
  return collectStandingPriorityParityGate(repoRoot, {
    baseRef,
    headRef,
    tipDiffTarget
  });
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
  ensureGhCli();

  const releaseBranch = `release/${tag}`;
  ensureBranchExists(releaseBranch);
  const requiredReleaseChecks = loadReleaseRequiredChecks(repoRoot);

  const upstream = resolveUpstream(repoRoot);
  ensureOriginFork(repoRoot, upstream);
  const prInfo = ensureReleasePrReady(repoRoot, releaseBranch, requiredReleaseChecks);
  const releaseBranchCommit = run('git', ['rev-parse', releaseBranch], { cwd: repoRoot });
  const releaseBaseCommit = run('git', ['merge-base', 'upstream/develop', releaseBranch], { cwd: repoRoot });
  await ensureReleaseBranchMetadata(repoRoot, {
    tag,
    semver,
    branch: releaseBranch,
    branchExists: true,
    baseCommit: releaseBaseCommit,
    releaseCommit: releaseBranchCommit,
    pullRequest: prInfo,
    recoverySource: 'release-finalize'
  });

  const standingPriorityParity = await collectStandingPriorityParityEvidence(repoRoot);
  const hygiene = collectReleaseHygiene(repoRoot);
  const compareEvidence = await collectCompareEvidenceGate(repoRoot, upstream, releaseBranch);

  run('git', ['fetch', 'origin'], { cwd: repoRoot });
  run('git', ['fetch', 'upstream'], { cwd: repoRoot });

  const originalCheckout = getCurrentCheckoutTarget((command, args, options = {}) =>
    run(command, args, { cwd: repoRoot, ...options })
  );

  let finalizeMetadata = null;
  let restoreCheckout = true;
  let forcePushMain = false;

  try {
    run('git', ['checkout', releaseBranch], { cwd: repoRoot });
    try {
      run('git', ['pull', '--ff-only'], { cwd: repoRoot });
    } catch (error) {
      console.warn(`[release:finalize] warning: unable to fast-forward ${releaseBranch}: ${error.message}`);
    }

    const releaseCommit = run('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });
    const surfaceVersions = await readReleaseSurfaceVersions(repoRoot);
    const surfaceEvaluation = evaluateReleaseSurfaceVersionExpectations(semver, surfaceVersions);
    if (!surfaceEvaluation.valid) {
      throw new Error(`Release surface versions are out of sync: ${surfaceEvaluation.issues.join(' ')}`);
    }

    checkoutDetachedRef('upstream/main', { cwd: repoRoot });
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
      } else if (!hasSharedHistory(repoRoot, 'HEAD', releaseBranch)) {
        if (process.env.RELEASE_FINALIZE_ALLOW_RESET === '1') {
          console.warn(
            `[release:finalize] ${releaseBranch} shares no history with main; resetting main to ${releaseBranch}.`
          );
          run('git', ['reset', '--hard', releaseBranch], { cwd: repoRoot });
          forcePushMain = true;
        } else {
          throw new Error(
            `${releaseBranch} does not share history with main. Set RELEASE_FINALIZE_ALLOW_RESET=1 to reset main to ${releaseBranch} (force push required) or reconcile histories manually. Original merge error: ${error.message}`
          );
        }
      } else {
        throw error;
      }
    }
    if (forcePushMain) {
      try {
        run('git', ['push', '--force-with-lease', 'upstream', 'HEAD:main'], {
          cwd: repoRoot
        });
      } catch {
        throw new Error('Failed to push main with --force-with-lease. Resolve the push error above.');
      }
    } else {
      pushToRemote(repoRoot, 'upstream', 'HEAD:main');
    }
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

    checkoutDetachedRef('upstream/develop', { cwd: repoRoot });
    const mergeBase = run('git', ['merge-base', 'HEAD', releaseBranch], { cwd: repoRoot });
    if (mergeBase !== releaseCommit) {
      run('git', ['merge', '--ff-only', releaseBranch], { cwd: repoRoot });
    }
    pushToRemote(repoRoot, 'upstream', 'HEAD:develop');
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
      surfaceVersions,
      standingPriorityParity,
      hygiene,
      compareEvidence,
      completedAt: new Date().toISOString()
    };

    if (originalCheckout) {
      try {
        run('git', ['checkout', originalCheckout], { cwd: repoRoot });
      } catch (error) {
        console.warn(`[release:finalize] warning: failed to restore ${originalCheckout}: ${error.message}`);
      }
    }

    restoreCheckout = false;
  } finally {
    if (restoreCheckout && originalCheckout) {
      try {
        run('git', ['checkout', originalCheckout], { cwd: repoRoot });
      } catch (error) {
        console.warn(`[release:finalize] warning: failed to restore ${originalCheckout}: ${error.message}`);
      }
    }
  }

  if (finalizeMetadata) {
    await writeReleaseMetadata(repoRoot, tag, 'finalize', finalizeMetadata);
    await assertReleaseMetadataExists(repoRoot, tag, 'branch');
    await assertReleaseMetadataExists(repoRoot, tag, 'finalize');
    console.log(`[release:finalize] Draft release created for ${tag}. Main and develop fast-forwarded.`);
  }
}

main().catch((error) => {
  console.error(`[release:finalize] ${error.message}`);
  process.exit(1);
});

#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureValidIdentifier,
  ensureCleanWorkingTree,
  ensureBranchDoesNotExist,
  getRepoRoot
} from './lib/branch-utils.mjs';
import {
  ensureGhCli,
  resolveUpstream,
  ensureOriginFork,
  pushBranch,
  runGhPrCreate
} from './lib/remote-utils.mjs';
import {
  normalizeVersionInput,
  writeReleaseMetadata,
  summarizeStatusChecks
} from './lib/release-utils.mjs';

const USAGE_LINES = [
  'Usage: npm run release:branch -- <version>',
  '',
  'Creates a release/<version> branch from upstream/develop, performs the version bump, pushes to your fork,',
  'and opens a PR targeting main.',
  '',
  'Options:',
  '  -h, --help    Show this message and exit'
];

async function updatePackageVersion(repoRoot, semver) {
  const pkgPath = path.join(repoRoot, 'package.json');
  const pkgRaw = await readFile(pkgPath, 'utf8');
  const pkg = JSON.parse(pkgRaw);
  const previous = pkg.version;
  if (previous === semver) {
    throw new Error(`package.json already set to ${semver}`);
  }
  pkg.version = semver;
  await writeFile(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`, 'utf8');
  run('git', ['add', 'package.json'], { cwd: repoRoot });
  return previous;
}

async function recordMetadata(repoRoot, metadata) {
  const payload = {
    schema: 'release/branch@v1',
    createdAt: new Date().toISOString(),
    ...metadata
  };
  await writeReleaseMetadata(repoRoot, metadata.tag, 'branch', payload);
  return payload;
}

function buildPrTitle(tag) {
  return process.env.PR_TITLE ?? `Release ${tag} (to main)`;
}

function buildPrBody(tag) {
  if (process.env.PR_BODY) {
    return process.env.PR_BODY;
  }
  return [
    '## Summary',
    `- prepare ${tag} for release`,
    '',
    '## Testing',
    '- npm run priority:test',
    ''
  ].join('\n');
}

function fetchPrInfo(repoRoot, branch) {
  try {
    const raw = run('gh', ['pr', 'view', branch, '--json', 'number,url,mergeStateStatus,statusCheckRollup'], {
      cwd: repoRoot
    });
    const info = JSON.parse(raw);
    return {
      number: info?.number ?? null,
      url: info?.url ?? null,
      mergeStateStatus: info?.mergeStateStatus ?? null,
      checks: summarizeStatusChecks(info?.statusCheckRollup ?? [])
    };
  } catch (error) {
    console.warn(`[release:branch] warning: unable to fetch PR metadata for ${branch}: ${error.message}`);
    return null;
  }
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
  ensureCleanWorkingTree(run, 'Working tree not clean. Commit or stash changes before creating a release branch.');

  const branch = `release/${tag}`;
  ensureBranchDoesNotExist(branch);

  ensureGhCli();
  const upstream = resolveUpstream(repoRoot);
  const origin = ensureOriginFork(repoRoot, upstream);

  let releaseCommit = null;
  let previousVersion = null;
  let prInfo = null;
  const originalBranch = run('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot });
  let restoreOnFailure = true;

  try {
    run('git', ['fetch', 'upstream'], { cwd: repoRoot });
    run('git', ['checkout', '-B', 'develop', 'upstream/develop'], { cwd: repoRoot });
    const baseCommit = run('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });
    run('git', ['checkout', '-b', branch], { cwd: repoRoot });

    previousVersion = await updatePackageVersion(repoRoot, semver);

    const status = run('git', ['status', '--porcelain'], { cwd: repoRoot });
    if (!status.trim()) {
      throw new Error('No changes detected after version update.');
    }

    const commitMessage = process.env.RELEASE_COMMIT_MESSAGE ?? `chore(release): prepare ${tag} (#270)`;
    run('git', ['commit', '-m', commitMessage], { cwd: repoRoot });
    releaseCommit = run('git', ['rev-parse', 'HEAD'], { cwd: repoRoot });

    pushBranch(repoRoot, branch);

    runGhPrCreate({
      upstream,
      origin,
      branch,
      base: 'main',
      title: buildPrTitle(tag),
      body: buildPrBody(tag)
    });

    prInfo = fetchPrInfo(repoRoot, branch);

    await recordMetadata(repoRoot, {
      tag,
      version: tag,
      semver,
      previousVersion,
      branch,
      baseBranch: 'develop',
      baseCommit,
      releaseCommit,
      pullRequest: prInfo
    });

    restoreOnFailure = false;
    console.log(`[release:branch] Branch ${branch} pushed. PR opened against main.`);
  } finally {
    if (restoreOnFailure && originalBranch) {
      try {
        run('git', ['checkout', originalBranch], { cwd: repoRoot });
      } catch (restoreError) {
        console.warn(`[release:branch] warning: failed to restore ${originalBranch}: ${restoreError.message}`);
      }
    }
  }
}

main().catch((error) => {
  console.error(`[release:branch] ${error.message}`);
  process.exit(1);
});

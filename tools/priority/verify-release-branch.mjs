#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { run, getRepoRoot } from './lib/branch-utils.mjs';
import { normalizeVersionInput } from './lib/release-utils.mjs';

function getHeadBranch() {
  return (
    process.env.GITHUB_HEAD_REF ||
    run('git', ['rev-parse', '--abbrev-ref', 'HEAD'])
  );
}

function ensureBranchSyntax(branch) {
  if (!branch.startsWith('release/')) {
    throw new Error(`Branch ${branch} is not a release branch (expected prefix release/)`);
  }
}

function ensureVersionMatches(branchTag, packageVersion) {
  const normalizedBranch = normalizeVersionInput(branchTag).semver;
  if (packageVersion !== normalizedBranch) {
    throw new Error(
      `package.json version ${packageVersion} does not match branch tag ${normalizedBranch}`
    );
  }
}

function ensureChangelogContains(repoRoot, tag) {
  const changelogPath = path.join(repoRoot, 'docs', 'CHANGELOG.md');
  const contents = readFileSync(changelogPath, 'utf8');
  if (!contents.includes(tag) && !contents.includes(tag.replace(/^v/, ''))) {
    throw new Error(`CHANGELOG.md missing entry for ${tag}`);
  }
}

function ensureChangelogDiff(repoRoot, baseRef) {
  const diff = run('git', ['diff', `${baseRef}`, '--', 'docs/CHANGELOG.md'], { cwd: repoRoot });
  if (!diff.trim()) {
    throw new Error(`docs/CHANGELOG.md not updated relative to ${baseRef}`);
  }
}

function main() {
  const repoRoot = getRepoRoot();
  const headBranch = getHeadBranch();
  ensureBranchSyntax(headBranch);

  const branchTag = headBranch.slice('release/'.length);
  const packageJson = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8'));
  ensureVersionMatches(branchTag, packageJson.version);
  ensureChangelogContains(repoRoot, branchTag);

  const baseRef = process.env.RELEASE_VALIDATE_BASE || 'origin/develop';
  ensureChangelogDiff(repoRoot, baseRef);

  console.log(`[release:verify] Release branch ${headBranch} validated successfully.`);
}

try {
  main();
} catch (error) {
  console.error(`[release:verify] ${error.message}`);
  process.exit(1);
}

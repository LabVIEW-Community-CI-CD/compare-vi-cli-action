#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs';
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
  const changelogPath = path.join(repoRoot, 'CHANGELOG.md');
  const contents = readFileSync(changelogPath, 'utf8');
  if (!contents.includes(tag) && !contents.includes(tag.replace(/^v/, ''))) {
    throw new Error(`CHANGELOG.md missing entry for ${tag}`);
  }
}

function ensureChangelogDiff(repoRoot, baseRef) {
  const diff = run('git', ['diff', `${baseRef}`, '--', 'CHANGELOG.md'], { cwd: repoRoot });
  if (!diff.trim()) {
    throw new Error(`CHANGELOG.md not updated relative to ${baseRef}`);
  }
}

function ensurePackageVersionDiff(repoRoot, baseRef) {
  const diff = run('git', ['diff', `${baseRef}`, '--', 'package.json'], { cwd: repoRoot });
  if (!diff.trim()) {
    throw new Error(`package.json not updated relative to ${baseRef}`);
  }
}

function fileContainsTag(contents, tag) {
  const semver = tag.replace(/^v/, '');
  return contents.includes(tag) || contents.includes(semver);
}

function ensureReleaseDocsConsistency(repoRoot, tag) {
  const docs = [
    { relPath: 'PR_NOTES.md', label: 'PR notes' },
    { relPath: 'TAG_PREP_CHECKLIST.md', label: 'tag checklist' },
    { relPath: `RELEASE_NOTES_${tag}.md`, label: 'release notes' }
  ];

  for (const doc of docs) {
    const fullPath = path.join(repoRoot, doc.relPath);
    if (!existsSync(fullPath)) {
      throw new Error(`Missing ${doc.label} file for ${tag}: ${doc.relPath}`);
    }
    const contents = readFileSync(fullPath, 'utf8');
    if (!fileContainsTag(contents, tag)) {
      throw new Error(`${doc.relPath} does not reference release tag ${tag}`);
    }
  }
}

function fileContainsTag(contents, tag) {
  const semver = tag.replace(/^v/, '');
  return contents.includes(tag) || contents.includes(semver);
}

function ensureReleaseDocsConsistency(repoRoot, tag) {
  const docs = [
    { relPath: 'PR_NOTES.md', label: 'PR notes' },
    { relPath: 'TAG_PREP_CHECKLIST.md', label: 'tag checklist' },
    { relPath: `RELEASE_NOTES_${tag}.md`, label: 'release notes' }
  ];

  for (const doc of docs) {
    const fullPath = path.join(repoRoot, doc.relPath);
    if (!existsSync(fullPath)) {
      throw new Error(`Missing ${doc.label} file for ${tag}: ${doc.relPath}`);
    }
    const contents = readFileSync(fullPath, 'utf8');
    if (!fileContainsTag(contents, tag)) {
      throw new Error(`${doc.relPath} does not reference release tag ${tag}`);
    }
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
  ensureReleaseDocsConsistency(repoRoot, branchTag);

  const baseRef = process.env.RELEASE_VALIDATE_BASE || 'origin/develop';
  ensurePackageVersionDiff(repoRoot, baseRef);
  ensureChangelogDiff(repoRoot, baseRef);

  console.log(`[release:verify] Release branch ${headBranch} validated successfully.`);
}

try {
  main();
} catch (error) {
  console.error(`[release:verify] ${error.message}`);
  process.exit(1);
}

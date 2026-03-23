#!/usr/bin/env node

import { mkdir, writeFile, access } from 'node:fs/promises';
import path from 'node:path';

const SEMVER_REGEX =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

export function normalizeVersionInput(raw) {
  const version = raw.startsWith('v') ? raw.slice(1) : raw;
  if (!SEMVER_REGEX.test(version)) {
    throw new Error(`Version "${raw}" does not comply with SemVer 2.0.0`);
  }
  return {
    tag: raw.startsWith('v') ? raw : `v${version}`,
    semver: version
  };
}

export async function writeReleaseMetadata(repoRoot, tag, kind, payload) {
  const dir = path.join(repoRoot, 'tests', 'results', '_agent', 'release');
  await mkdir(dir, { recursive: true });
  const filePath = path.join(dir, `release-${tag}-${kind}.json`);
  await writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

export function getReleaseMetadataPath(repoRoot, tag, kind) {
  return path.join(repoRoot, 'tests', 'results', '_agent', 'release', `release-${tag}-${kind}.json`);
}

export async function assertReleaseMetadataExists(repoRoot, tag, kind) {
  const artifactPath = getReleaseMetadataPath(repoRoot, tag, kind);
  try {
    await access(artifactPath);
    return artifactPath;
  } catch {
    throw new Error(
      `[release:metadata] Missing required artifact ${path.relative(repoRoot, artifactPath)}. Run the matching release helper first and retain tests/results/_agent/release/*.`
    );
  }
}

export async function ensureReleaseBranchMetadata(
  repoRoot,
  {
    tag,
    semver,
    branch,
    branchExists = false,
    baseBranch = 'develop',
    baseCommit = null,
    releaseCommit = null,
    pullRequest = null,
    previousVersion = null,
    surfaceVersions = null,
    recoverySource = 'release-finalize'
  }
) {
  try {
    const artifactPath = await assertReleaseMetadataExists(repoRoot, tag, 'branch');
    return {
      artifactPath,
      recovered: false
    };
  } catch (error) {
    if (!branchExists || !pullRequest) {
      throw error;
    }

    const payload = {
      schema: 'release/branch@v1',
      createdAt: new Date().toISOString(),
      tag,
      version: tag,
      semver,
      branch,
      baseBranch,
      baseCommit,
      releaseCommit,
      previousVersion,
      surfaceVersions,
      pullRequest,
      recovered: true,
      recoverySource
    };

    const artifactPath = await writeReleaseMetadata(repoRoot, tag, 'branch', payload);
    return {
      artifactPath,
      recovered: true,
      payload
    };
  }
}

export function summarizeStatusCheckRollup(rollup = []) {
  return (rollup || [])
    .filter(Boolean)
    .map((check) => ({
      name: check.name ?? null,
      status: check.status ?? null,
      conclusion: check.conclusion ?? null,
      url: check.detailsUrl ?? null
    }));
}

export const summarizeStatusChecks = summarizeStatusCheckRollup;

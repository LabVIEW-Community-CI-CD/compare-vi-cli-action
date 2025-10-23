#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
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

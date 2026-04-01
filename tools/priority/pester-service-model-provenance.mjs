#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

export function toPortablePath(value) {
  if (!value) {
    return null;
  }
  return String(value).split(path.sep).join('/');
}

export function relativeOrAbsolute(repoRoot, filePath) {
  const resolvedPath = path.resolve(filePath);
  const relative = path.relative(repoRoot, resolvedPath);
  if (!relative.startsWith('..') && !path.isAbsolute(relative)) {
    return toPortablePath(relative || '.');
  }
  return toPortablePath(resolvedPath);
}

export function runGit(repoRoot, args) {
  const result = spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) {
    return null;
  }
  return result.stdout.trim() || null;
}

export function resolveRunContext(repoRoot, workflowFallback) {
  const repository = process.env.GITHUB_REPOSITORY || path.basename(repoRoot);
  const runId = process.env.GITHUB_RUN_ID || null;
  const serverUrl = (process.env.GITHUB_SERVER_URL || 'https://github.com').replace(/\/$/, '');
  const branch = process.env.GITHUB_REF_NAME || runGit(repoRoot, ['rev-parse', '--abbrev-ref', 'HEAD']);
  const headSha = process.env.GITHUB_SHA || runGit(repoRoot, ['rev-parse', 'HEAD']);

  return {
    source: runId ? 'github-actions' : 'local',
    repository,
    workflow: process.env.GITHUB_WORKFLOW || workflowFallback,
    eventName: process.env.GITHUB_EVENT_NAME || 'local',
    runId,
    runAttempt: process.env.GITHUB_RUN_ATTEMPT || null,
    runUrl: runId ? `${serverUrl}/${repository}/actions/runs/${runId}` : null,
    ref: process.env.GITHUB_REF || (branch ? `refs/heads/${branch}` : null),
    refName: branch || null,
    branch: branch || null,
    headRef: process.env.GITHUB_HEAD_REF || null,
    baseRef: process.env.GITHUB_BASE_REF || null,
    headSha: headSha || null
  };
}

async function sha256File(filePath) {
  const buffer = await fs.readFile(filePath);
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

async function readOptionalJsonMetadata(filePath) {
  try {
    const document = JSON.parse(await fs.readFile(filePath, 'utf8'));
    return {
      schema: typeof document.schema === 'string' ? document.schema : null,
      schemaVersion: typeof document.schemaVersion === 'string' ? document.schemaVersion : null,
      status:
        typeof document.status === 'string'
          ? document.status
          : typeof document.classification === 'string'
            ? document.classification
            : null
    };
  } catch {
    return { schema: null, schemaVersion: null, status: 'invalid-json' };
  }
}

export async function describeFile(repoRoot, filePath, { kind, role, artifactName = null } = {}) {
  const resolvedPath = path.resolve(filePath);
  try {
    const stat = await fs.stat(resolvedPath);
    const metadata = await readOptionalJsonMetadata(resolvedPath);
    return {
      kind,
      role,
      artifactName,
      path: toPortablePath(resolvedPath),
      repoRelativePath: relativeOrAbsolute(repoRoot, resolvedPath),
      present: true,
      sizeBytes: stat.size,
      sha256: await sha256File(resolvedPath),
      lastWriteTimeUtc: stat.mtime.toISOString(),
      schema: metadata.schema,
      schemaVersion: metadata.schemaVersion,
      status: metadata.status
    };
  } catch {
    return {
      kind,
      role,
      artifactName,
      path: toPortablePath(resolvedPath),
      repoRelativePath: relativeOrAbsolute(repoRoot, resolvedPath),
      present: false
    };
  }
}

export async function writeJsonFile(outputPath, payload) {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

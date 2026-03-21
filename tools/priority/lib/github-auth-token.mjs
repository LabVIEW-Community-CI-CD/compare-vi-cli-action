#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { access, readFile } from 'node:fs/promises';
import process from 'node:process';

export const STANDARD_HOST_TOKEN_FILE_WINDOWS = 'C:\\github_token.txt';
export const STANDARD_HOST_TOKEN_FILE_NON_WINDOWS = '/mnt/c/github_token.txt';

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeExtraEnvCandidates(extraEnvCandidates = []) {
  if (!Array.isArray(extraEnvCandidates)) {
    return [];
  }
  return extraEnvCandidates
    .map((candidate) => {
      if (!candidate || typeof candidate !== 'object') {
        return null;
      }
      const name = normalizeText(candidate.name);
      const source = normalizeText(candidate.source);
      if (!name || !source) {
        return null;
      }
      return { name, source };
    })
    .filter((candidate) => Boolean(candidate));
}

function buildEnvCandidates(env = process.env, extraEnvCandidates = []) {
  return [
    { name: 'GH_TOKEN', source: 'gh-token-env' },
    { name: 'GITHUB_TOKEN', source: 'github-token-env' },
    ...normalizeExtraEnvCandidates(extraEnvCandidates),
  ].map((candidate) => ({
    value: env[candidate.name],
    source: candidate.source,
  }));
}

export function listGitHubTokenFileCandidateDescriptors(
  env = process.env,
  { platform = process.platform } = {},
) {
  const candidates = [];
  const pushCandidate = (pathValue, source) => {
    const normalizedPath = normalizeText(pathValue);
    if (!normalizedPath) {
      return;
    }
    if (candidates.some((candidate) => candidate.path === normalizedPath)) {
      return;
    }
    candidates.push({
      path: normalizedPath,
      source,
    });
  };

  pushCandidate(env.GH_TOKEN_FILE, 'gh-token-file');
  pushCandidate(env.GITHUB_TOKEN_FILE, 'github-token-file');
  pushCandidate(
    platform === 'win32' ? STANDARD_HOST_TOKEN_FILE_WINDOWS : STANDARD_HOST_TOKEN_FILE_NON_WINDOWS,
    'standard-host-token-file',
  );
  return candidates;
}

export function listGitHubTokenFileCandidates(
  env = process.env,
  { platform = process.platform } = {},
) {
  return listGitHubTokenFileCandidateDescriptors(env, { platform }).map((candidate) => candidate.path);
}

function addUniqueCandidate(candidates, seen, tokenValue, source) {
  const token = normalizeText(tokenValue);
  const normalizedSource = normalizeText(source);
  if (!token || !normalizedSource) {
    return;
  }
  const key = `${normalizedSource}:${token}`;
  if (seen.has(key)) {
    return;
  }
  candidates.push({ token, source: normalizedSource });
  seen.add(key);
}

export function resolveGitHubAuthToken(
  env = process.env,
  {
    readFileSyncFn = readFileSync,
    platform = process.platform,
    extraEnvCandidates = [],
  } = {},
) {
  for (const candidate of buildEnvCandidates(env, extraEnvCandidates)) {
    const token = normalizeText(candidate.value);
    if (token) {
      return {
        token,
        source: candidate.source,
      };
    }
  }

  for (const candidate of listGitHubTokenFileCandidateDescriptors(env, { platform })) {
    try {
      const token = normalizeText(readFileSyncFn(candidate.path, 'utf8'));
      if (token) {
        return {
          token,
          source: candidate.source,
        };
      }
    } catch {
      // ignore unreadable token files
    }
  }

  return {
    token: null,
    source: null,
  };
}

export async function resolveGitHubAuthTokenCandidates(
  env = process.env,
  {
    readFileFn = readFile,
    accessFn = access,
    platform = process.platform,
    extraEnvCandidates = [],
  } = {},
) {
  const candidates = [];
  const seen = new Set();

  for (const candidate of buildEnvCandidates(env, extraEnvCandidates)) {
    addUniqueCandidate(candidates, seen, candidate.value, candidate.source);
  }

  for (const candidate of listGitHubTokenFileCandidateDescriptors(env, { platform })) {
    try {
      await accessFn(candidate.path);
      const token = await readFileFn(candidate.path, 'utf8');
      addUniqueCandidate(candidates, seen, token, candidate.source);
    } catch {
      // ignore unreadable token files
    }
  }

  return candidates;
}

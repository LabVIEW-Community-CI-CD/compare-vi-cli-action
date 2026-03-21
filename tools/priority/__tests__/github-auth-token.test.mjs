#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  listGitHubTokenFileCandidates,
  resolveGitHubAuthToken,
  resolveGitHubAuthTokenCandidates,
} from '../lib/github-auth-token.mjs';

test('github-auth-token prefers GH_TOKEN over other token sources', () => {
  const resolution = resolveGitHubAuthToken(
    {
      GH_TOKEN: ' gh-token ',
      GITHUB_TOKEN: ' github-token ',
      GH_TOKEN_FILE: 'C:\\gh-token.txt',
      GITHUB_TOKEN_FILE: 'C:\\github-token.txt',
    },
    {
      readFileSyncFn: () => 'file-token',
      platform: 'win32',
    },
  );

  assert.deepEqual(resolution, {
    token: 'gh-token',
    source: 'gh-token-env',
  });
});

test('github-auth-token honors GITHUB_TOKEN_FILE before the standard host fallback', () => {
  const reads = [];
  const resolution = resolveGitHubAuthToken(
    {
      GITHUB_TOKEN_FILE: 'C:\\custom-github-token.txt',
    },
    {
      readFileSyncFn: (filePath) => {
        reads.push(filePath);
        return ' file-token ';
      },
      platform: 'win32',
    },
  );

  assert.deepEqual(resolution, {
    token: 'file-token',
    source: 'github-token-file',
  });
  assert.deepEqual(reads, ['C:\\custom-github-token.txt']);
});

test('github-auth-token uses the non-Windows standard host token file fallback', () => {
  assert.deepEqual(
    listGitHubTokenFileCandidates({}, { platform: 'linux' }),
    ['/mnt/c/github_token.txt'],
  );

  const reads = [];
  const resolution = resolveGitHubAuthToken(
    {},
    {
      readFileSyncFn: (filePath) => {
        reads.push(filePath);
        return ' fallback-token ';
      },
      platform: 'linux',
    },
  );

  assert.deepEqual(resolution, {
    token: 'fallback-token',
    source: 'standard-host-token-file',
  });
  assert.deepEqual(reads, ['/mnt/c/github_token.txt']);
});

test('github-auth-token async candidates preserve deterministic source ordering', async () => {
  const candidates = await resolveGitHubAuthTokenCandidates(
    {
      GITHUB_TOKEN: 'github-token',
      GITHUB_TOKEN_FILE: 'C:\\custom-github-token.txt',
    },
    {
      accessFn: async () => undefined,
      readFileFn: async (filePath) => {
        if (filePath === 'C:\\custom-github-token.txt') {
          return 'file-token';
        }
        throw new Error(`unexpected file path ${filePath}`);
      },
      platform: 'win32',
      extraEnvCandidates: [{ name: 'GH_ENTERPRISE_TOKEN', source: 'gh-enterprise-token-env' }],
    },
  );

  assert.deepEqual(candidates, [
    { token: 'github-token', source: 'github-token-env' },
    { token: 'file-token', source: 'github-token-file' },
  ]);
});

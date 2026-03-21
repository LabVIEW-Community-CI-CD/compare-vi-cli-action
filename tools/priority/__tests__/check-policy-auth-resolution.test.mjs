#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { __test } from '../check-policy.mjs';

test('check-policy token candidates honor GITHUB_TOKEN_FILE and deterministic file-source labels', async () => {
  const candidates = await __test.resolveTokenCandidates(
    {
      GITHUB_TOKEN_FILE: 'C:\\custom-github-token.txt',
    },
    {
      accessFn: async () => undefined,
      readFileFn: async (filePath) => {
        if (filePath === 'C:\\custom-github-token.txt') {
          return ' file-token ';
        }
        throw new Error(`unexpected file path ${filePath}`);
      },
      platform: 'win32',
    },
  );

  assert.deepEqual(candidates, [
    { token: 'file-token', source: 'github-token-file' },
  ]);
});

test('check-policy token candidates preserve env precedence and keep GH_ENTERPRISE_TOKEN support', async () => {
  const candidates = await __test.resolveTokenCandidates(
    {
      GITHUB_TOKEN: ' github-token ',
      GH_ENTERPRISE_TOKEN: ' enterprise-token ',
      GH_TOKEN_FILE: 'C:\\gh-token.txt',
    },
    {
      accessFn: async () => undefined,
      readFileFn: async (filePath) => {
        if (filePath === 'C:\\gh-token.txt') {
          return ' file-token ';
        }
        throw new Error(`unexpected file path ${filePath}`);
      },
      platform: 'win32',
    },
  );

  assert.deepEqual(candidates, [
    { token: 'github-token', source: 'github-token-env' },
    { token: 'enterprise-token', source: 'gh-enterprise-token-env' },
    { token: 'file-token', source: 'gh-token-file' },
  ]);
});

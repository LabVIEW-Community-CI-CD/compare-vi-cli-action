#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  resolveGitHubToken,
  resetPrioritySyncTokenStateForTests,
  warnNoGitHubTokenForRestOnce
} from '../sync-standing-priority.mjs';

test('resolveGitHubToken prefers GH_TOKEN over GITHUB_TOKEN and gh fallback', () => {
  const token = resolveGitHubToken({
    env: { GH_TOKEN: ' gh-token ', GITHUB_TOKEN: ' github-token ' },
    authTokenProvider: () => 'gh-auth-token'
  });
  assert.equal(token, 'gh-token');
});

test('resolveGitHubToken falls back to GITHUB_TOKEN when GH_TOKEN missing', () => {
  const token = resolveGitHubToken({
    env: { GITHUB_TOKEN: ' github-token ' },
    authTokenProvider: () => 'gh-auth-token'
  });
  assert.equal(token, 'github-token');
});

test('resolveGitHubToken uses gh auth token provider when env tokens are missing', () => {
  const token = resolveGitHubToken({
    env: {},
    authTokenProvider: () => ' gh-auth-token '
  });
  assert.equal(token, 'gh-auth-token');
});

test('resolveGitHubToken returns null when no token source is available', () => {
  const token = resolveGitHubToken({
    env: {},
    authTokenProvider: () => null
  });
  assert.equal(token, null);
});

test('warnNoGitHubTokenForRestOnce emits only one warning per process state', () => {
  resetPrioritySyncTokenStateForTests();
  const seen = [];
  const originalWarn = console.warn;
  console.warn = (message) => {
    seen.push(message);
  };

  try {
    warnNoGitHubTokenForRestOnce();
    warnNoGitHubTokenForRestOnce();
  } finally {
    console.warn = originalWarn;
    resetPrioritySyncTokenStateForTests();
  }

  assert.equal(seen.length, 1);
  assert.equal(
    seen[0],
    '[priority] No GitHub token available for REST fallback; attempting unauthenticated request'
  );
});


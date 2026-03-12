#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';

import { resolveGitAdminPaths } from '../lib/git-admin-paths.mjs';

test('resolveGitAdminPaths surfaces spawn failures with underlying git error details', () => {
  assert.throws(
    () =>
      resolveGitAdminPaths({
        cwd: process.cwd(),
        spawnSyncFn: () => ({
          status: null,
          stdout: '',
          stderr: '',
          error: Object.assign(new Error('spawn git ENOENT'), { code: 'ENOENT' })
        })
      }),
    /Failed to run git rev-parse --show-toplevel: spawn git ENOENT \(code ENOENT\)/
  );
});

test('resolveGitAdminPaths reports signal-based git failures when stderr is empty', () => {
  assert.throws(
    () =>
      resolveGitAdminPaths({
        cwd: process.cwd(),
        spawnSyncFn: () => ({
          status: null,
          stdout: '',
          stderr: '',
          signal: 'SIGTERM'
        })
      }),
    /git rev-parse --show-toplevel failed \(signal SIGTERM\)/
  );
});

test('resolveGitAdminPaths preserves git command context when stderr is present', () => {
  assert.throws(
    () =>
      resolveGitAdminPaths({
        cwd: process.cwd(),
        spawnSyncFn: () => ({
          status: 128,
          stdout: '',
          stderr: 'fatal: bad revision'
        })
      }),
    /git rev-parse --show-toplevel failed: fatal: bad revision/
  );
});

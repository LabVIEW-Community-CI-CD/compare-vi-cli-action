import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';

import { isSuppressedMarkdownPath, resolveMergeBase } from '../lint-markdown.mjs';

test('suppresses known generated markdown names', () => {
  assert.equal(isSuppressedMarkdownPath('CHANGELOG.md'), true);
  assert.equal(isSuppressedMarkdownPath('fixture-summary.md'), true);
});

test('suppresses temporary draft markdown names', () => {
  assert.equal(isSuppressedMarkdownPath('.tmp-pr-body.md'), true);
  assert.equal(isSuppressedMarkdownPath('notes/pr-576-body.md'), true);
  assert.equal(isSuppressedMarkdownPath('notes\\pr-999-body.md'), true);
});

test('does not suppress normal docs', () => {
  assert.equal(isSuppressedMarkdownPath('README.md'), false);
  assert.equal(isSuppressedMarkdownPath('docs/DEVELOPER_GUIDE.md'), false);
});

test('fails clearly when git is unavailable for markdown discovery', () => {
  const nodeDir = dirname(process.execPath);
  const scriptPath = resolve(process.cwd(), 'tools/lint-markdown.mjs');
  const result = spawnSync(process.execPath, [scriptPath, '--all'], {
    cwd: process.cwd(),
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: nodeDir,
    },
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /git is required for markdown lint repository discovery/i);
});

test('resolves merge-base for changed-file mode without stale git helper references', () => {
  const mergeBase = resolveMergeBase(['HEAD']);
  assert.match(mergeBase, /^[0-9a-f]{40}$/i);
});

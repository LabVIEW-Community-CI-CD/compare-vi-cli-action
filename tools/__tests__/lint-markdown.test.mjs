import test from 'node:test';
import assert from 'node:assert/strict';

import { isSuppressedMarkdownPath } from '../lint-markdown.mjs';

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

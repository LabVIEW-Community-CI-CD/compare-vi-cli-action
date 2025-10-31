#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  sanitizeGhText,
  buildIssueLinkSnippet,
  sanitizeIssuePayload,
  assertPresent
} from '../lib/github-text.mjs';

test('sanitizeGhText doubles backslashes and normalises EOL', () => {
  const input = 'Path: \\\\server\\share\\tools\r\nLine two\\twith tab';
  const result = sanitizeGhText(input);
  assert.equal(result, 'Path: \\\\\\\\server\\\\share\\\\tools\nLine two\\\\twith tab');
});

test('sanitizeGhText accepts non-string values', () => {
  assert.equal(sanitizeGhText(42), '42');
  assert.equal(sanitizeGhText(null), '');
  assert.equal(
    sanitizeGhText('already escaped \\\\n block', { normaliseEol: false }),
    'already escaped \\\\\\\\n block'
  );
});

test('sanitizeIssuePayload sanitizes both title and body', () => {
  const payload = sanitizeIssuePayload({
    title: 'Fix path \\tools\\priority',
    body: 'Line1\r\nLine2 with \\n'
  });
  assert.equal(payload.title, 'Fix path \\\\tools\\\\priority');
  assert.equal(payload.body, 'Line1\nLine2 with \\\\n');
});

test('buildIssueLinkSnippet builds default and custom prefixes', () => {
  assert.equal(buildIssueLinkSnippet(529), 'Fixes #529');
  assert.equal(buildIssueLinkSnippet(' 600 ', { prefix: 'Resolves' }), 'Resolves #600');
  assert.equal(
    buildIssueLinkSnippet(700, { prefix: 'Refs', suffix: '(standing)' }),
    'Refs #700 (standing)'
  );
});

test('buildIssueLinkSnippet rejects invalid issue numbers', () => {
  assert.throws(() => buildIssueLinkSnippet(''), /Issue number is required/);
  assert.throws(() => buildIssueLinkSnippet('abc'), /must be digits/);
});

test('assertPresent throws when value empty', () => {
  assert.throws(() => assertPresent('', 'missing'), /missing/);
  assert.doesNotThrow(() => assertPresent('value', 'missing'));
});

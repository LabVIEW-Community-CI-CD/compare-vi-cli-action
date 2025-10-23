#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  normalizeVersionInput,
  writeReleaseMetadata,
  summarizeStatusCheckRollup
} from '../lib/release-utils.mjs';

test('normalizeVersionInput handles tagged and untagged semver', () => {
  assert.deepEqual(normalizeVersionInput('1.2.3'), { tag: 'v1.2.3', semver: '1.2.3' });
  assert.deepEqual(normalizeVersionInput('v2.0.0'), { tag: 'v2.0.0', semver: '2.0.0' });
});

test('normalizeVersionInput rejects invalid versions', () => {
  assert.throws(() => normalizeVersionInput('v1.2'), /does not comply/);
  assert.throws(() => normalizeVersionInput('foo'), /does not comply/);
});

test('writeReleaseMetadata writes JSON to release directory', async (t) => {
  const tempDir = await mkdtemp(path.join(tmpdir(), 'release-meta-'));
  t.after(() => rm(tempDir, { recursive: true, force: true }));

  const filePath = await writeReleaseMetadata(tempDir, 'v9.9.9', 'branch', { schema: 'test', foo: 'bar' });
  const contents = JSON.parse(await readFile(filePath, 'utf8'));
  assert.equal(contents.foo, 'bar');
  assert.equal(contents.schema, 'test');
});

test('summarizeStatusCheckRollup normalizes check data', () => {
  const rollup = [
    { name: 'lint', status: 'COMPLETED', conclusion: 'SUCCESS', detailsUrl: 'https://example.com/lint' },
    null,
    { name: 'tests', status: 'COMPLETED', conclusion: 'FAILURE' }
  ];
  const summary = summarizeStatusCheckRollup(rollup);
  assert.equal(summary.length, 2);
  assert.deepEqual(summary[0], {
    name: 'lint',
    status: 'COMPLETED',
    conclusion: 'SUCCESS',
    url: 'https://example.com/lint'
  });
});

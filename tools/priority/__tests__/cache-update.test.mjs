import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { shouldWriteCache, shouldWriteJsonFile, writeJson } from '../sync-standing-priority.mjs';

const baseCache = {
  number: 134,
  title: 'Standing priority',
  url: 'https://example.test/134',
  cachedAtUtc: '2025-10-16T19:19:36.942Z',
  state: 'OPEN',
  lastSeenUpdatedAt: '2025-10-15T18:04:17Z',
  issueDigest: 'digest',
  labels: [],
  assignees: [],
  milestone: null,
  commentCount: null,
  bodyDigest: null,
  lastFetchSource: 'cache',
  lastFetchError: 'gh CLI not found'
};

test('shouldWriteCache returns true when no previous cache exists', () => {
  const next = { ...baseCache, cachedAtUtc: '2025-10-16T20:11:24.858Z' };
  assert.equal(shouldWriteCache(null, next), true);
});

test('shouldWriteCache ignores cachedAtUtc-only differences', () => {
  const next = { ...baseCache, cachedAtUtc: '2025-10-16T20:11:24.858Z' };
  assert.equal(shouldWriteCache(baseCache, next), false);
});

test('shouldWriteCache detects meaningful differences', () => {
  const next = { ...baseCache, lastFetchSource: 'live' };
  assert.equal(shouldWriteCache(baseCache, next), true);
});

test('shouldWriteJsonFile suppresses no-op writes for semantically equal JSON', async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), 'priority-json-write-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const filePath = path.join(root, 'state.json');
  const payload = { schema: 'test@v1', issue: 738, actions: [{ key: 'validate:dispatch' }] };

  await writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  assert.equal(shouldWriteJsonFile(filePath, payload), false);
  assert.equal(writeJson(filePath, payload), false);

  const saved = await readFile(filePath, 'utf8');
  assert.equal(saved, `${JSON.stringify(payload, null, 2)}\n`);
});

test('writeJson writes when file is missing or changed', async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), 'priority-json-write-change-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const filePath = path.join(root, 'state.json');
  const first = { schema: 'test@v1', issue: null };
  const second = { schema: 'test@v1', issue: 738 };

  assert.equal(shouldWriteJsonFile(filePath, first), true);
  assert.equal(writeJson(filePath, first), true);
  assert.equal(shouldWriteJsonFile(filePath, second), true);
  assert.equal(writeJson(filePath, second), true);
});

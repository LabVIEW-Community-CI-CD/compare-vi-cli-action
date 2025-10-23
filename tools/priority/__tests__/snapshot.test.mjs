import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createSnapshot, loadRoutingPolicy, buildRouter } from '../sync-standing-priority.mjs';

const repoRoot = path.resolve(fileURLToPath(new URL('../../../', import.meta.url)));

test('createSnapshot normalizes lists and produces stable digest', () => {
  const issue = {
    number: 127,
    title: 'Standing Priority Test',
    state: 'open',
    updatedAt: '2025-10-13T00:00:00Z',
    url: 'https://example.test/issues/127',
    labels: ['docs', 'CI', 'Docs'],
    assignees: ['bob', 'alice', 'ALICE'],
    milestone: 'M1',
    commentCount: 5,
    body: 'Test body'
  };

  const snap1 = createSnapshot(issue);
  const snap2 = createSnapshot({
    ...issue,
    labels: ['ci', 'docs'],
    assignees: ['alice', 'bob']
  });

  assert.equal(snap1.schema, 'standing-priority/issue@v1');
  assert.deepEqual(snap1.labels, ['ci', 'docs']);
  assert.deepEqual(snap1.assignees, ['alice', 'bob']);
  assert.ok(snap1.bodyDigest);
  assert.equal(snap1.bodyDigest, snap2.bodyDigest);
  assert.equal(snap1.digest, snap2.digest);
});

test('buildRouter honours policy map and default actions', () => {
  const policy = loadRoutingPolicy(repoRoot);
  assert.ok(policy, 'routing policy should load');

  const snapshot = createSnapshot({
    number: 127,
    title: 'Router Test',
    state: 'open',
    updatedAt: '2025-10-13T00:00:00Z',
    labels: ['docs', 'ci'],
    assignees: [],
    body: null,
    url: null
  });

  const router = buildRouter(snapshot, policy);
  const keys = router.actions.map((a) => a.key);

  assert.ok(keys.includes('hooks:pre-commit'));
  assert.ok(keys.includes('hooks:multi'));
  assert.ok(keys.includes('docs:lint'));
  assert.ok(keys.includes('ci:parity'));
  assert.ok(keys.includes('validate:dispatch'));

  const priorities = router.actions.map((a) => a.priority);
  assert.deepEqual([...priorities].sort((a, b) => a - b), priorities, 'actions sorted by priority');
});

test('buildRouter adds fallback validation action when needed', () => {
  const snapshot = createSnapshot({
    number: 128,
    title: 'Fallback Test',
    state: 'open',
    updatedAt: null,
    labels: [],
    assignees: [],
    body: null,
    url: null
  });

  const router = buildRouter(snapshot, null);
  const keys = router.actions.map((a) => a.key);
  assert.ok(keys.includes('validate:lint'));
  assert.ok(keys.includes('validate:dispatch'));
});


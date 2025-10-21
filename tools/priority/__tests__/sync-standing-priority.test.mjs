#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { collectReleaseArtifacts, buildRouter } from '../sync-standing-priority.mjs';

async function createReleaseArtifact(dir, filename, payload) {
  const filePath = path.join(dir, filename);
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('collectReleaseArtifacts gathers branch and finalize metadata', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'release-artifacts-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const releaseDir = path.join(repoRoot, 'tests', 'results', '_agent', 'release');
  await createReleaseArtifact(releaseDir, 'release-v1.0.0-branch.json', {
    version: 'v1.0.0',
    branch: 'release/v1.0.0',
    releaseCommit: 'abc123',
    createdAt: '2025-10-21T00:00:00Z'
  });
  await createReleaseArtifact(releaseDir, 'release-v0.9.0-finalize.json', {
    version: 'v0.9.0',
    releaseCommit: 'def456',
    mainCommit: 'def456',
    completedAt: '2025-10-20T00:00:00Z'
  });

  const artifacts = collectReleaseArtifacts(repoRoot);
  assert.equal(artifacts.length, 2);
  assert.equal(artifacts[0].tag, 'v1.0.0');
  assert.equal(artifacts[0].kind, 'branch');
  assert.equal(artifacts[1].kind, 'finalize');
});

test('buildRouter adds finalize action when latest branch lacks finalize', () => {
  const snapshot = {
    number: 270,
    labels: [],
    releaseArtifacts: [
      { tag: 'v1.0.0', kind: 'branch' },
      { tag: 'v0.9.0', kind: 'finalize' }
    ]
  };
  const router = buildRouter(snapshot, {});
  const finalizeAction = router.actions.find((action) => action.key === 'release:finalize');
  assert.ok(finalizeAction);
  assert.ok(finalizeAction.scripts.some((script) => script.includes('v1.0.0')));

  const snapshotWithFinalize = {
    number: 270,
    labels: [],
    releaseArtifacts: [
      { tag: 'v1.0.0', kind: 'branch' },
      { tag: 'v1.0.0', kind: 'finalize' }
    ]
  };
  const routerWithout = buildRouter(snapshotWithFinalize, {});
  assert.ok(!routerWithout.actions.find((action) => action.key === 'release:finalize'));
});

test('buildRouter suggests release branch creation when label present without metadata', () => {
  const snapshot = {
    number: 270,
    labels: ['release'],
    releaseArtifacts: []
  };
  const router = buildRouter(snapshot, {});
  const branchAction = router.actions.find((action) => action.key === 'release:branch');
  assert.ok(branchAction);
});

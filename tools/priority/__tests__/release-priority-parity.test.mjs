import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createSnapshot } from '../sync-standing-priority.mjs';
import {
  collectStandingPrioritySyncEvidence,
  collectOriginUpstreamParityEvidence,
  collectStandingPriorityParityGate
} from '../lib/release-priority-parity.mjs';

function buildLiveIssue(overrides = {}) {
  return {
    number: 285,
    title: 'Enforce standing-priority sync and parity gate before release finalize',
    state: 'OPEN',
    updatedAt: '2026-03-05T00:00:00Z',
    url: 'https://example.com/issues/285',
    labels: ['fork-standing-priority'],
    assignees: [],
    milestone: null,
    commentCount: 0,
    body: 'test',
    ...overrides
  };
}

async function writePriorityFixture(repoDir, liveIssue) {
  const snapshot = createSnapshot(liveIssue);
  const issueDir = path.join(repoDir, 'tests', 'results', '_agent', 'issue');
  await mkdir(issueDir, { recursive: true });
  await writeFile(
    path.join(repoDir, '.agent_priority_cache.json'),
    `${JSON.stringify({
      number: liveIssue.number,
      title: liveIssue.title,
      state: liveIssue.state,
      labels: liveIssue.labels,
      repository: 'owner/repo',
      lastSeenUpdatedAt: liveIssue.updatedAt,
      issueDigest: snapshot.digest,
      cachedAtUtc: '2026-03-05T01:00:00Z'
    })}\n`,
    'utf8'
  );
  await writeFile(
    path.join(issueDir, 'router.json'),
    `${JSON.stringify({
      schema: 'agent/priority-router@v1',
      issue: liveIssue.number,
      actions: [{ key: 'validate:dispatch', priority: 95, scripts: ['node tools/npm/run-script.mjs priority:validate'] }]
    })}\n`,
    'utf8'
  );
  await writeFile(path.join(issueDir, `${liveIssue.number}.json`), `${JSON.stringify(snapshot)}\n`, 'utf8');
  return snapshot;
}

test('collectStandingPrioritySyncEvidence accepts current standing-priority artifacts', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-priority-sync-ok-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  const liveIssue = buildLiveIssue();
  await writePriorityFixture(repoDir, liveIssue);

  const evidence = await collectStandingPrioritySyncEvidence(repoDir, {
    fetchIssueFn: async () => liveIssue
  });
  assert.equal(evidence.issue, 285);
  assert.equal(evidence.repository, 'owner/repo');
  assert.match(evidence.files.snapshot, /tests\/results\/_agent\/issue\/285\.json$/);
});

test('collectStandingPrioritySyncEvidence rejects stale standing-priority artifacts', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-priority-sync-stale-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  const cachedIssue = buildLiveIssue();
  await writePriorityFixture(repoDir, cachedIssue);
  const liveIssue = buildLiveIssue({
    title: 'Updated title after cache'
  });

  await assert.rejects(
    () =>
      collectStandingPrioritySyncEvidence(repoDir, {
        fetchIssueFn: async () => liveIssue
      }),
    /artifacts are stale/i
  );
});

test('collectOriginUpstreamParityEvidence enforces tipDiff file count target', () => {
  assert.throws(
    () =>
      collectOriginUpstreamParityEvidence({
        tipDiffTarget: 0,
        collectParityFn: () => ({
          status: 'ok',
          baseRef: 'upstream/develop',
          headRef: 'origin/develop',
          tipDiff: { fileCount: 2 },
          treeParity: { status: 'different', equal: false },
          historyParity: { status: 'diverged', equal: false, baseOnly: 1, headOnly: 1 }
        })
      }),
    /KPI unmet/i
  );
});

test('collectStandingPriorityParityGate returns combined sync and parity evidence', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-priority-parity-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  const liveIssue = buildLiveIssue();
  await writePriorityFixture(repoDir, liveIssue);

  const evidence = await collectStandingPriorityParityGate(repoDir, {
    fetchIssueFn: async () => liveIssue,
    collectParityFn: () => ({
      status: 'ok',
      baseRef: 'upstream/develop',
      headRef: 'origin/develop',
      tipDiff: { fileCount: 0 },
      treeParity: { status: 'equal', equal: true },
      historyParity: { status: 'diverged', equal: false, baseOnly: 3, headOnly: 4 },
      recommendation: { code: 'history-diverged-tree-equal', summary: 'Tree is aligned.' }
    })
  });

  assert.equal(evidence.skipped, false);
  assert.equal(evidence.standingPriority.issue, 285);
  assert.equal(evidence.parity.tipDiff.fileCount, 0);
  assert.equal(evidence.parity.tipDiff.target, 0);
});

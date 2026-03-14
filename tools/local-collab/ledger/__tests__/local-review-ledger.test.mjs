import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import {
  LOCAL_COLLAB_LEDGER_LATEST_SCHEMA,
  LOCAL_COLLAB_LEDGER_RECEIPT_SCHEMA,
  assessLatestLocalCollaborationLedgerReceipt,
  resolveGitContext,
  writeLocalCollaborationLedgerReceipt
} from '../local-review-ledger.mjs';

async function createGitRepo() {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-collab-ledger-'));
  spawnSync('git', ['init', '--initial-branch=develop'], { cwd: repoRoot, encoding: 'utf8' });
  await writeFile(path.join(repoRoot, 'README.md'), '# test\n', 'utf8');
  spawnSync('git', ['add', 'README.md'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'initial'],
    { cwd: repoRoot, encoding: 'utf8' }
  );
  return repoRoot;
}

test('writeLocalCollaborationLedgerReceipt persists a per-phase per-head receipt and latest index', async () => {
  const repoRoot = await createGitRepo();
  const git = resolveGitContext(repoRoot);
  const first = await writeLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'pre-commit',
    git,
    forkPlane: 'personal',
    persona: 'codex',
    providers: ['copilot-cli'],
    selectionSource: 'PRECOMMIT_AGENT_REVIEW_PROVIDERS',
    startedAt: '2026-03-14T00:00:00.000Z',
    finishedAt: '2026-03-14T00:00:01.000Z',
    durationMs: 1000,
    findingCount: 0,
    status: 'passed',
    outcome: 'completed'
  });

  const second = await writeLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'pre-push',
    git,
    forkPlane: 'personal',
    persona: 'codex',
    providers: ['copilot-cli', 'simulation'],
    selectionSource: 'HOOKS_AGENT_REVIEW_PROVIDERS',
    startedAt: '2026-03-14T00:00:02.000Z',
    finishedAt: '2026-03-14T00:00:03.000Z',
    durationMs: 1000,
    findingCount: 2,
    status: 'failed',
    outcome: 'blocked'
  });

  assert.equal(first.receipt.schema, LOCAL_COLLAB_LEDGER_RECEIPT_SCHEMA);
  assert.equal(first.latestIndex.schema, LOCAL_COLLAB_LEDGER_LATEST_SCHEMA);
  assert.equal(first.receipt.headSha, git.headSha);
  assert.equal(first.receipt.baseSha, git.baseSha);
  assert.equal(first.receipt.providerId, 'copilot-cli');
  assert.equal(second.receipt.providerId, 'multi');
  assert.ok(second.receipt.sourceReceiptIds.includes(first.receipt.receiptId));

  const persisted = JSON.parse(await readFile(second.receiptPath, 'utf8'));
  const latest = JSON.parse(await readFile(second.latestIndexPath, 'utf8'));
  assert.equal(persisted.receiptId, second.receipt.receiptId);
  assert.equal(latest.receiptId, second.receipt.receiptId);
  assert.equal(latest.headSha, git.headSha);
});

test('assessLatestLocalCollaborationLedgerReceipt fails closed on corrupt latest indexes', async () => {
  const repoRoot = await createGitRepo();
  const latestIndexPath = path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'local-collab',
    'ledger',
    'latest',
    'pre-commit.json'
  );
  await mkdir(path.dirname(latestIndexPath), { recursive: true });
  await writeFile(latestIndexPath, '{not-json', 'utf8');

  const result = await assessLatestLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'pre-commit'
  });

  assert.equal(result.ok, false);
  assert.equal(result.status, 'invalid-index');
});

test('assessLatestLocalCollaborationLedgerReceipt reports stale receipts when the current head changed', async () => {
  const repoRoot = await createGitRepo();
  const initialGit = resolveGitContext(repoRoot);
  await writeLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'pre-commit',
    git: initialGit,
    forkPlane: 'personal',
    persona: 'codex',
    providers: ['copilot-cli'],
    selectionSource: 'explicit',
    startedAt: '2026-03-14T00:00:00.000Z',
    finishedAt: '2026-03-14T00:00:01.000Z',
    durationMs: 1000,
    status: 'passed',
    outcome: 'completed'
  });

  await writeFile(path.join(repoRoot, 'README.md'), '# changed\n', 'utf8');
  spawnSync('git', ['add', 'README.md'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'second'],
    { cwd: repoRoot, encoding: 'utf8' }
  );
  const currentGit = resolveGitContext(repoRoot);

  const result = await assessLatestLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'pre-commit',
    expectedHeadSha: currentGit.headSha
  });

  assert.equal(result.ok, false);
  assert.equal(result.status, 'stale');
});

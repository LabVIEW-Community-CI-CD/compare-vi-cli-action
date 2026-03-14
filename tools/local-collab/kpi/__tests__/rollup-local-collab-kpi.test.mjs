import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import {
  LOCAL_COLLAB_KPI_SCHEMA,
  loadLocalCollaborationLedgerReceipts,
  rollupLocalCollaborationKpi
} from '../rollup-local-collab-kpi.mjs';
import { writeLocalCollaborationLedgerReceipt } from '../../ledger/local-review-ledger.mjs';

async function createGitRepo() {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-collab-kpi-'));
  spawnSync('git', ['init', '--initial-branch=develop'], { cwd: repoRoot, encoding: 'utf8' });
  await writeFile(path.join(repoRoot, 'README.md'), '# test\n', 'utf8');
  await mkdir(path.join(repoRoot, 'tools', 'priority'), { recursive: true });
  await writeFile(
    path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'),
    JSON.stringify({
      localReviewLoop: {
        copilotCliReview: true,
        copilotCliReviewConfig: {
          enabled: true,
          model: 'gpt-5.4'
        }
      }
    }, null, 2),
    'utf8'
  );
  spawnSync('git', ['add', 'README.md', 'tools/priority/delivery-agent.policy.json'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'initial'],
    { cwd: repoRoot, encoding: 'utf8' }
  );
  return repoRoot;
}

test('rollupLocalCollaborationKpi aggregates receipt and provider effort across collaboration planes', async () => {
  const repoRoot = await createGitRepo();
  const git = {
    headSha: 'abc123',
    baseSha: 'base123'
  };

  await writeLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'pre-commit',
    git,
    forkPlane: 'personal',
    persona: 'codex',
    executionPlane: 'windows-host',
    providerRuntime: 'copilot-cli',
    providerId: 'copilot-cli',
    providers: ['copilot-cli'],
    requestedModel: 'gpt-5.4',
    effectiveModel: 'gpt-5.4',
    inputTokens: 20,
    cachedInputTokens: 5,
    outputTokens: 6,
    selectionSource: 'PRECOMMIT_AGENT_REVIEW_PROVIDERS',
    startedAt: '2026-03-14T00:00:00.000Z',
    finishedAt: '2026-03-14T00:00:01.000Z',
    durationMs: 1000,
    findingCount: 1,
    status: 'passed',
    outcome: 'completed'
  });

  await writeLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'pre-push',
    git,
    forkPlane: 'personal',
    persona: 'codex',
    executionPlane: 'windows-host',
    providerRuntime: 'copilot-cli',
    providerId: 'copilot-cli',
    providers: ['copilot-cli'],
    requestedModel: 'gpt-5.4',
    effectiveModel: 'gpt-5.4',
    inputTokens: 18,
    cachedInputTokens: 4,
    outputTokens: 5,
    selectionSource: 'PREPUSH_AGENT_REVIEW_PROVIDERS',
    startedAt: '2026-03-14T00:00:02.000Z',
    finishedAt: '2026-03-14T00:00:03.000Z',
    durationMs: 800,
    findingCount: 0,
    status: 'passed',
    outcome: 'completed'
  });

  await writeLocalCollaborationLedgerReceipt({
    repoRoot,
    phase: 'daemon',
    git,
    forkPlane: 'upstream',
    persona: 'daemon',
    executionPlane: 'docker',
    providerRuntime: 'simulation',
    providerId: 'simulation',
    providers: ['simulation'],
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    selectionSource: 'policy-default',
    startedAt: '2026-03-14T00:00:04.000Z',
    finishedAt: '2026-03-14T00:00:05.000Z',
    durationMs: 600,
    findingCount: 2,
    status: 'failed',
    outcome: 'blocked'
  });

  const { summary } = await rollupLocalCollaborationKpi({ repoRoot });

  assert.equal(summary.schema, LOCAL_COLLAB_KPI_SCHEMA);
  assert.equal(summary.receiptInventory.receiptCount, 3);
  assert.equal(summary.receiptInventory.uniqueHeadCount, 1);
  assert.equal(summary.planes.personal.receiptEffort.receiptCount, 2);
  assert.equal(summary.planes.personal.receiptEffort.durationMs, 1800);
  assert.equal(summary.planes.personal.receiptEffort.findingCount, 1);
  assert.equal(summary.planes.personal.receiptEffort.executionPlanes['windows-host'], 2);
  assert.equal(summary.planes.origin.providerEffort.receiptCount, 3);
  assert.equal(summary.planes.origin.providerEffort.durationMs, 2400);
  assert.equal(summary.planes.origin.providerEffort.findingCount, 3);
  assert.equal(summary.planes.origin.providerEffort.inputTokens, 38);
  assert.equal(summary.planes.origin.providerEffort.cachedInputTokens, 9);
  assert.equal(summary.planes.origin.providerEffort.outputTokens, 11);
  assert.equal(summary.planes.origin.personas['copilot-cli'].providerEffort.receiptCount, 2);
  assert.equal(summary.planes.origin.personas.simulation.providerEffort.receiptCount, 1);
  assert.equal(summary.planes.upstream.receiptEffort.receiptCount, 1);
  assert.equal(summary.planes.upstream.receiptEffort.statuses.failed, 1);
  assert.equal(summary.planes.upstream.receiptEffort.executionPlanes.docker, 1);
  assert.equal(summary.combinedLocalPlane.receiptEffort.receiptCount, 3);
  assert.equal(summary.combinedLocalPlane.providerEffort.receiptCount, 3);
  assert.equal(summary.providers['copilot-cli'].totals.receiptCount, 2);
  assert.equal(summary.providers['copilot-cli'].totals.requestedModels['gpt-5.4'], 2);
  assert.equal(summary.providers['copilot-cli'].totals.inputTokens, 38);
  assert.equal(summary.providers.simulation.totals.receiptCount, 1);
  assert.equal(summary.providers['codex-cli'].executionPlane, 'wsl2');
  assert.equal(summary.providers['codex-cli'].providerRuntime, 'codex-cli');
  assert.equal(summary.providers['codex-cli'].placeholderOnly, true);
  assert.equal(summary.providers.ollama.placeholderOnly, true);
});

test('loadLocalCollaborationLedgerReceipts fails closed on invalid receipt JSON', async () => {
  const repoRoot = await createGitRepo();
  const receiptPath = path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'local-collab',
    'ledger',
    'receipts',
    'pre-commit',
    'broken.json'
  );
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(receiptPath, '{not-json', 'utf8');

  await assert.rejects(
    () => loadLocalCollaborationLedgerReceipts({ repoRoot }),
    /Unable to parse local collaboration ledger receipt/
  );
});

test('rollupLocalCollaborationKpi keeps reserved provider placeholders even without observed receipts', async () => {
  const repoRoot = await createGitRepo();
  const { summary } = await rollupLocalCollaborationKpi({ repoRoot });

  assert.equal(summary.receiptInventory.receiptCount, 0);
  assert.equal(summary.providers['codex-cli'].placeholderOnly, true);
  assert.equal(summary.providers['codex-cli'].reserved, false);
  assert.equal(summary.providers['codex-cli'].executable, true);
  assert.equal(summary.providers['codex-cli'].plane, 'personal');
  assert.equal(summary.providers['copilot-cli'].placeholderOnly, true);
  assert.equal(summary.providers['copilot-cli'].plane, 'origin');
});

test('rollup-local-collab-kpi CLI writes the summary artifact and prints a compact receipt', async () => {
  const repoRoot = await createGitRepo();
  const scriptPath = path.join(process.cwd(), 'tools', 'local-collab', 'kpi', 'rollup-local-collab-kpi.mjs');
  const outputPath = path.join('tests', 'results', '_agent', 'local-collab', 'kpi', 'cli-summary.json');
  const result = spawnSync('node', [scriptPath, '--repo-root', repoRoot, '--output', outputPath], {
    cwd: repoRoot,
    encoding: 'utf8'
  });

  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  assert.equal(parsed.schema, LOCAL_COLLAB_KPI_SCHEMA);
  assert.equal(parsed.summaryPath, outputPath.replace(/\\/g, '/'));

  const persisted = JSON.parse(await readFile(path.join(repoRoot, outputPath), 'utf8'));
  assert.equal(persisted.schema, LOCAL_COLLAB_KPI_SCHEMA);
});

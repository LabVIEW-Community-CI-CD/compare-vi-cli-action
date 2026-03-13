import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile } from 'node:fs/promises';
import {
  LOCAL_COLLAB_ORCHESTRATOR_SCHEMA,
  parseArgs,
  resolvePhaseProviderSelection,
  runLocalCollaborationPhase
} from '../run-phase.mjs';

test('parseArgs preserves delegate args for daemon phase', () => {
  const parsed = parseArgs([
    'node',
    'run-phase.mjs',
    '--phase',
    'daemon',
    '--repo-root',
    '/tmp/repo',
    '--orchestrator-receipt-path',
    'tests/results/_agent/local-collab/orchestrator/daemon.json',
    '--providers',
    'copilot-cli,simulation',
    '--receipt-path',
    'tests/results/docker-tools-parity/review-loop-receipt.json',
    '--skip-actionlint'
  ]);

  assert.equal(parsed.phase, 'daemon');
  assert.equal(parsed.repoRoot, '/tmp/repo');
  assert.deepEqual(parsed.providers, ['copilot-cli', 'simulation']);
  assert.deepEqual(parsed.delegateArgs, [
    '--receipt-path',
    'tests/results/docker-tools-parity/review-loop-receipt.json',
    '--skip-actionlint'
  ]);
});

test('resolvePhaseProviderSelection prefers explicit, then phase, then shared overrides', () => {
  assert.deepEqual(
    resolvePhaseProviderSelection('pre-commit', { PRECOMMIT_AGENT_REVIEW_PROVIDERS: 'simulation', HOOKS_AGENT_REVIEW_PROVIDERS: 'copilot-cli' }, ['codex-cli']),
    { selectionSource: 'explicit', providers: ['codex-cli'] }
  );
  assert.deepEqual(
    resolvePhaseProviderSelection('pre-push', { PREPUSH_AGENT_REVIEW_PROVIDERS: 'simulation', HOOKS_AGENT_REVIEW_PROVIDERS: 'copilot-cli' }),
    { selectionSource: 'PREPUSH_AGENT_REVIEW_PROVIDERS', providers: ['simulation'] }
  );
  assert.deepEqual(
    resolvePhaseProviderSelection('daemon', { HOOKS_AGENT_REVIEW_PROVIDERS: 'copilot-cli,simulation' }),
    { selectionSource: 'HOOKS_AGENT_REVIEW_PROVIDERS', providers: ['copilot-cli', 'simulation'] }
  );
});

test('runLocalCollaborationPhase writes deterministic daemon orchestrator receipts', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-collab-orchestrator-'));
  const result = await runLocalCollaborationPhase({
    phase: 'daemon',
    repoRoot,
    providers: ['copilot-cli'],
    delegateArgs: ['--receipt-path', 'tests/results/docker-tools-parity/review-loop-receipt.json'],
    delegateFns: {
      daemon: async () => ({
        exitCode: 0,
        stdout: '{"status":"passed"}',
        stderr: ''
      })
    }
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.receipt.schema, LOCAL_COLLAB_ORCHESTRATOR_SCHEMA);
  assert.equal(result.receipt.phase, 'daemon');
  assert.equal(result.receipt.forkPlane, 'upstream');
  assert.equal(result.receipt.persona, 'daemon');
  assert.equal(result.receipt.selectionSource, 'explicit');
  assert.deepEqual(result.receipt.providers, ['copilot-cli']);
  assert.match(result.receipt.delegate.command.join(' '), /tools\/priority\/docker-desktop-review-loop\.mjs/);

  const persisted = JSON.parse(await readFile(result.receiptPath, 'utf8'));
  assert.equal(persisted.schema, LOCAL_COLLAB_ORCHESTRATOR_SCHEMA);
  assert.equal(persisted.phase, 'daemon');
  assert.equal(persisted.status, 'passed');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('hook core entrypoints route through the local collaboration orchestrator', () => {
  const preCommit = readRepoFile(path.join('tools', 'hooks', 'core', 'pre-commit.mjs'));
  const postCommit = readRepoFile(path.join('tools', 'hooks', 'core', 'post-commit.mjs'));
  const prePush = readRepoFile(path.join('tools', 'hooks', 'core', 'pre-push.mjs'));

  assert.match(preCommit, /local-collab\/orchestrator\/run-phase\.mjs/);
  assert.match(preCommit, /phase:\s*'pre-commit'/);

  assert.match(postCommit, /local-collab\/orchestrator\/run-phase\.mjs/);
  assert.match(postCommit, /phase:\s*'post-commit'/);

  assert.match(prePush, /local-collab\/orchestrator\/run-phase\.mjs/);
  assert.match(prePush, /phase:\s*'pre-push'/);
});

test('delivery agent policy routes daemon local review through the orchestrator front door', () => {
  const policy = JSON.parse(readRepoFile(path.join('tools', 'priority', 'delivery-agent.policy.json')));
  assert.deepEqual(policy.localReviewLoop.command, [
    'node',
    'tools/local-collab/orchestrator/run-phase.mjs',
    '--phase',
    'daemon'
  ]);
});

test('PrePush-Checks emits orchestration context when invoked through the local collaboration front door', () => {
  const source = readRepoFile(path.join('tools', 'PrePush-Checks.ps1'));
  assert.match(source, /LOCAL_COLLAB_ORCHESTRATED/);
  assert.match(source, /LOCAL_COLLAB_PHASE/);
  assert.match(source, /local collaboration orchestrator active/);
});

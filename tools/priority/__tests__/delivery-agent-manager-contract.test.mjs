#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

async function readText(relativePath) {
  return readFile(path.join(repoRoot, relativePath), 'utf8');
}

test('package scripts expose delivery-agent commands and keep unattended aliases intact', async () => {
  const packageJson = JSON.parse(await readText('package.json'));
  assert.equal(
    packageJson.scripts['priority:delivery:agent:ensure'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Ensure -SleepMode'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:status'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Status'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:stop'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Stop'
  );
  assert.equal(
    packageJson.scripts['priority:unattended:sleep:ensure'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Ensure -SleepMode'
  );
  assert.equal(
    packageJson.scripts['priority:unattended:project-board:ensure'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Ensure -SleepMode'
  );
});

test('delivery-agent policy wires coding turns to the Codex runner', async () => {
  const policy = JSON.parse(await readText('tools/priority/delivery-agent.policy.json'));
  assert.deepEqual(policy.codingTurnCommand, ['node', 'tools/priority/run-delivery-turn-with-codex.mjs']);
});

test('delivery-agent manager and run scripts target the WSL runtime daemon instead of the legacy loop', async () => {
  const manager = await readText('tools/priority/Manage-UnattendedDeliveryAgent.ps1');
  const runner = await readText('tools/priority/Run-UnattendedDeliveryAgent.ps1');
  const ensurePrereqs = await readText('tools/priority/Ensure-WSLDeliveryPrereqs.ps1');

  assert.match(manager, /Ensure-WSLDeliveryPrereqs\.ps1/);
  assert.match(manager, /wsl\.exe/);
  assert.match(runner, /runtime-daemon\.mjs/);
  assert.match(runner, /WslDistro/);
  assert.match(runner, /AGENT_WRITER_LEASE_OWNER/);
  assert.match(ensurePrereqs, /nodejs\.org\/dist/);
  assert.match(ensurePrereqs, /@openai\/codex/);
  assert.match(ensurePrereqs, /codex_needs_install=0/);
  assert.match(ensurePrereqs, /core\.worktree/);
});

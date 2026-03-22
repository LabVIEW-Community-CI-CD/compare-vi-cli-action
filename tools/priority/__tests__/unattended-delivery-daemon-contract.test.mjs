#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('unattended delivery daemon knowledgebase is checked in and points to the bounded daemon surfaces', () => {
  const manifest = JSON.parse(readText('docs/documentation-manifest.json'));
  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  const guide = readText('docs/knowledgebase/Unattended-Delivery-Daemon-Surfaces.md');
  const debtRegister = readText('docs/knowledgebase/Unattended-Delivery-Daemon-Debt-Register.md');
  const capabilityRegister = readText('docs/knowledgebase/Unattended-Delivery-Daemon-Capability-Expansion-Register.md');

  assert.ok(docsEntry);
  assert.ok(docsEntry.files.includes('docs/knowledgebase/Unattended-Delivery-Daemon-Surfaces.md'));
  assert.ok(docsEntry.files.includes('docs/knowledgebase/Unattended-Delivery-Daemon-Debt-Register.md'));
  assert.ok(docsEntry.files.includes('docs/knowledgebase/Unattended-Delivery-Daemon-Capability-Expansion-Register.md'));
  assert.match(guide, /priority:delivery:agent:ensure/);
  assert.match(guide, /priority:delivery:agent:status/);
  assert.match(guide, /priority:delivery:agent:stop/);
  assert.match(guide, /priority:runtime:daemon/);
  assert.match(guide, /priority:runtime:daemon:docker/);
  assert.match(guide, /priority:jarvis:status/);
  assert.match(guide, /delivery-agent-state\.json/);
  assert.match(guide, /delivery-agent-lanes\/<lane-id>\.json/);
  assert.match(guide, /delivery-memory\.json/);
  assert.match(guide, /jarvis-session-observer\.json/);
  assert.match(guide, /observer-heartbeat\.json/);
  assert.match(guide, /task-packet\.json/);
  assert.match(guide, /codex-state-hygiene\.json/);
  assert.match(guide, /lane-marketplace-snapshot\.json/);
  assert.match(guide, /daemon-host-signal\.json/);
  assert.match(guide, /docker-daemon-engine\.json/);
  assert.match(guide, /native-wsl/);
  assert.match(guide, /Unattended-Delivery-Daemon-Debt-Register\.md/);
  assert.match(guide, /Unattended-Delivery-Daemon-Capability-Expansion-Register\.md/);
  assert.match(guide, /runtime-daemon\.mjs/);
  assert.match(guide, /runtime-supervisor\.mjs/);
  assert.match(guide, /delivery-agent\.mjs/);
  assert.match(guide, /delivery-agent-common\.ts/);
  assert.match(guide, /delivery-agent-manager-contract\.test\.mjs/);
  assert.match(guide, /runtime-supervisor\.test\.mjs/);
  assert.match(debtRegister, /standing reconciliation/i);
  assert.match(debtRegister, /reconcile-standing-after-merge\.mjs/);
  assert.match(debtRegister, /delivery-agent-state\.json/);
  assert.match(debtRegister, /runtime-state\.json/);
  assert.match(debtRegister, /#1643/);
  assert.match(debtRegister, /#1634/);
  assert.match(capabilityRegister, /lane-marketplace\.mjs/);
  assert.match(capabilityRegister, /concurrent-lane-status-receipt\.json/);
  assert.match(capabilityRegister, /downstream-develop-promotion-scorecard\.json/);
  assert.match(capabilityRegister, /#1508/);
  assert.match(capabilityRegister, /#1482/);
  assert.match(capabilityRegister, /#1497/);
});

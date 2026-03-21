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

test('live-agent model selection documentation and manifest point at the checked-in RC recommendation surfaces', () => {
  const manifest = JSON.parse(readText('docs/documentation-manifest.json'));
  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  const contractEntry = manifest.entries.find((entry) => entry.name === 'Live Agent Model Selection Contracts');
  const guide = readText('docs/knowledgebase/Live-Agent-Model-Selection.md');

  assert.ok(docsEntry);
  assert.ok(contractEntry);
  assert.ok(docsEntry.files.includes('docs/knowledgebase/Live-Agent-Model-Selection.md'));
  assert.ok(contractEntry.files.includes('docs/schemas/live-agent-model-selection-policy-v1.schema.json'));
  assert.ok(contractEntry.files.includes('docs/schemas/live-agent-model-selection-report-v1.schema.json'));
  assert.ok(contractEntry.files.includes('tools/policy/live-agent-model-selection.json'));
  assert.ok(contractEntry.files.includes('tools/priority/live-agent-model-selection.mjs'));
  assert.match(guide, /recommendation-first/i);
  assert.match(guide, /tests\/results\/_agent\/runtime\/live-agent-model-selection\.json/);
  assert.match(guide, /priority:model:select/);
  assert.match(guide, /delivery-agent-state\.json/);
  assert.match(guide, /runtime-delivery-task-packet-v1\.schema\.json/);
  assert.match(guide, /cost alone is not enough to switch/i);
  assert.match(guide, /reasoning-effort/i);
});

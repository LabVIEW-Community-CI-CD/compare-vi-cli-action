import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');

function loadText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function loadJson(relativePath) {
  return JSON.parse(loadText(relativePath));
}

test('mission-control consumption doc points to the authoritative discovery surfaces', () => {
  const doc = loadText('docs/MISSION_CONTROL_CONSUMPTION.md');

  assert.match(doc, /PROMPT_AUTONOMY\.md/);
  assert.match(doc, /mission-control-envelope-v1\.schema\.json/);
  assert.match(doc, /mission-control-envelope\.json/);
  assert.match(doc, /mission-control-operator-input-catalog-v1\.schema\.json/);
  assert.match(doc, /operator-input-catalog\.json/);
  assert.match(doc, /mission-control-profile-catalog-v1\.schema\.json/);
  assert.match(doc, /profile-catalog\.json/);
  assert.match(doc, /mission-control-profile-catalog\.mjs/);
  assert.match(doc, /resolve-mission-control-profile\.mjs/);
  assert.match(doc, /render-mission-control-envelope\.mjs/);
  assert.match(doc, /`AGENTS\.md` remains authoritative/i);
  assert.match(doc, /`\.github\/copilot-instructions\.md` remains authoritative/i);
  assert.match(doc, /\.github\/instructions\//);
  assert.match(doc, /Do not treat free-form operator text as a policy surface\./);
});

test('docs manifest advertises the mission-control consumption contract', () => {
  const manifest = loadJson('docs/documentation-manifest.json');
  const docsTreeEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  const missionControlEntry = manifest.entries.find((entry) => entry.name === 'Mission Control Contracts');

  assert.ok(docsTreeEntry, 'Docs Tree entry is missing from documentation manifest.');
  assert.ok(missionControlEntry, 'Mission Control Contracts entry is missing from documentation manifest.');
  assert.ok(docsTreeEntry.files.includes('docs/MISSION_CONTROL_CONSUMPTION.md'));
  assert.match(missionControlEntry.description, /consumption contract/i);
  assert.match(missionControlEntry.description, /preset envelope renderer/i);
  assert.ok(missionControlEntry.files.includes('docs/MISSION_CONTROL_CONSUMPTION.md'));
  assert.ok(missionControlEntry.files.includes('tools/priority/render-mission-control-envelope.mjs'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/render-mission-control-envelope.test.mjs'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/mission-control-consumption-contract.test.mjs'));
});

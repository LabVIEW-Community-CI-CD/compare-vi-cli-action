import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');

function loadText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function loadJson(relativePath) {
  return JSON.parse(loadText(relativePath));
}

function compileValidator() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv.compile(loadJson('docs/schemas/mission-control-profile-catalog-v1.schema.json'));
}

function sortStrings(values) {
  return [...values].sort((left, right) => left.localeCompare(right));
}

function assertUniqueTriggerTokens(profileCatalog) {
  const seenTokens = new Map();
  for (const profile of profileCatalog.profiles) {
    const tokens = [profile.trigger, ...profile.aliases];
    for (const token of tokens) {
      const priorProfileId = seenTokens.get(token);
      assert.equal(
        priorProfileId,
        undefined,
        `Mission-control trigger token '${token}' is reused by '${profile.id}' and '${priorProfileId}'.`
      );
      seenTokens.set(token, profile.id);
    }
  }
}

test('mission-control profile catalog fixture matches schema', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/profile-catalog.json');
  const valid = validate(fixture);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(fixture.profiles.length, 5);
  assertUniqueTriggerTokens(fixture);
});

test('mission-control profile catalog fails closed on duplicate profile ids or trigger aliases', () => {
  const validateDuplicateId = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/profile-catalog.json');
  const duplicateIdCatalog = structuredClone(fixture);
  duplicateIdCatalog.profiles = [
    structuredClone(fixture.profiles[0]),
    { ...structuredClone(fixture.profiles[1]), id: fixture.profiles[0].id },
    ...fixture.profiles.slice(2).map((entry) => structuredClone(entry))
  ];
  assert.equal(validateDuplicateId(duplicateIdCatalog), false, 'duplicate profile ids should fail schema validation');

  const duplicateTokenCatalog = structuredClone(fixture);
  duplicateTokenCatalog.profiles[1].aliases = [...duplicateTokenCatalog.profiles[1].aliases, fixture.profiles[0].trigger];
  assert.throws(
    () => assertUniqueTriggerTokens(duplicateTokenCatalog),
    /Mission-control trigger token 'MC' is reused/
  );
});

test('mission-control profile catalog operator presets stay inside the bounded operator-input catalog', () => {
  const profileCatalog = loadJson('tools/priority/__fixtures__/mission-control/profile-catalog.json');
  const inputCatalog = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const intents = new Map(inputCatalog.intents.map((entry) => [entry.id, entry]));
  const focuses = new Set(inputCatalog.focuses.map((entry) => entry.id));

  for (const profile of profileCatalog.profiles) {
    assert.ok(intents.has(profile.operatorPreset.intent), `Unknown intent '${profile.operatorPreset.intent}'.`);
    assert.ok(focuses.has(profile.operatorPreset.focus), `Unknown focus '${profile.operatorPreset.focus}'.`);
    assert.ok(
      intents.get(profile.operatorPreset.intent).allowedFocuses.includes(profile.operatorPreset.focus),
      `Profile '${profile.id}' maps to disallowed focus '${profile.operatorPreset.focus}'.`
    );
    assert.deepEqual(profile.operatorPreset.overrides, []);
  }
});

test('mission-control profile catalog stays aligned with the envelope and operator-input contracts', () => {
  const profileCatalog = loadJson('tools/priority/__fixtures__/mission-control/profile-catalog.json');
  const envelopeSchema = loadJson('docs/schemas/mission-control-envelope-v1.schema.json');
  const inputCatalog = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');

  const envelopeIntentIds = new Set(envelopeSchema.properties.operator.properties.intent.enum);
  const envelopeFocusIds = new Set(envelopeSchema.properties.operator.properties.focus.enum);
  const inputIntentIds = new Set(inputCatalog.intents.map((entry) => entry.id));
  const inputFocusIds = new Set(inputCatalog.focuses.map((entry) => entry.id));

  for (const profile of profileCatalog.profiles) {
    assert.ok(envelopeIntentIds.has(profile.operatorPreset.intent));
    assert.ok(envelopeFocusIds.has(profile.operatorPreset.focus));
    assert.ok(inputIntentIds.has(profile.operatorPreset.intent));
    assert.ok(inputFocusIds.has(profile.operatorPreset.focus));
  }

  assert.deepEqual(
    sortStrings(profileCatalog.profiles.map((entry) => entry.id)),
    sortStrings([
      'autonomous-default',
      'finish-live-lane',
      'prepare-parked-lane',
      'restore-intake',
      'stabilize-current-head-failure'
    ])
  );
});

test('mission-control docs advertise the profile catalog with the existing mission-control contracts', () => {
  const prompt = loadText('PROMPT_AUTONOMY.md');
  const manifest = loadJson('docs/documentation-manifest.json');

  assert.match(prompt, /mission-control-profile-catalog-v1\.schema\.json/);
  assert.match(prompt, /profile-catalog\.json/);
  assert.match(prompt, /`MC`/);
  assert.match(prompt, /`MC-LIVE`/);

  const missionControlEntry = manifest.entries.find((entry) => entry.name === 'Mission Control Contracts');
  assert.ok(missionControlEntry, 'Mission Control Contracts entry is missing from docs manifest.');
  assert.ok(missionControlEntry.files.includes('docs/schemas/mission-control-profile-catalog-v1.schema.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__fixtures__/mission-control/profile-catalog.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/mission-control-profile-catalog.test.mjs'));
});

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
  return ajv.compile(loadJson('docs/schemas/mission-control-operator-input-catalog-v1.schema.json'));
}

test('mission-control operator input catalog fixture matches schema', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const valid = validate(fixture);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(fixture.intents.length, 5);
  assert.equal(fixture.focuses.length, 6);
  assert.equal(fixture.overrides.length, 5);
});

test('mission-control envelope operator fields stay inside the bounded-input catalog', () => {
  const envelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  const catalog = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const allowedIntentIds = new Set(catalog.intents.map((entry) => entry.id));
  const allowedFocusIds = new Set(catalog.focuses.map((entry) => entry.id));
  const overrideCatalog = new Map(catalog.overrides.map((entry) => [entry.key, entry]));

  assert.ok(allowedIntentIds.has(envelope.operator.intent));
  assert.ok(allowedFocusIds.has(envelope.operator.focus));
  for (const override of envelope.operator.overrides) {
    assert.ok(overrideCatalog.has(override.key), `Unexpected override key '${override.key}'.`);
    const catalogEntry = overrideCatalog.get(override.key);
    if (catalogEntry.valueType === 'boolean') {
      assert.equal(typeof override.value, 'boolean');
    } else {
      assert.ok(catalogEntry.allowedValues.includes(override.value));
    }
  }
});

test('mission-control docs advertise the operator-input catalog with the envelope contract', () => {
  const prompt = loadText('PROMPT_AUTONOMY.md');
  const manifest = loadJson('docs/documentation-manifest.json');

  assert.match(prompt, /mission-control-operator-input-catalog-v1\.schema\.json/);
  assert.match(prompt, /operator-input-catalog\.json/);

  const missionControlEntry = manifest.entries.find((entry) => entry.name === 'Mission Control Contracts');
  assert.ok(missionControlEntry, 'Mission Control Contracts entry is missing from docs manifest.');
  assert.ok(missionControlEntry.files.includes('docs/schemas/mission-control-operator-input-catalog-v1.schema.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__fixtures__/mission-control/operator-input-catalog.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/mission-control-operator-input-catalog.test.mjs'));
});

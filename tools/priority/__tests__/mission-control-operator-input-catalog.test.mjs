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

function sortStrings(values) {
  return [...values].sort((left, right) => left.localeCompare(right));
}

function readEnvelopeIntentFocusMatrix(envelopeSchema) {
  const operatorAllOf = envelopeSchema.properties.operator.allOf ?? [];
  const matrix = new Map();
  for (const rule of operatorAllOf) {
    const intentId = rule?.if?.properties?.intent?.const;
    const allowedFocuses = rule?.then?.properties?.focus?.enum;
    if (typeof intentId !== 'string' || !Array.isArray(allowedFocuses)) {
      continue;
    }
    matrix.set(intentId, sortStrings(allowedFocuses));
  }
  return matrix;
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

test('mission-control operator input catalog fails closed when canonical identifiers are missing or duplicated', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const duplicateIntentCatalog = structuredClone(fixture);
  duplicateIntentCatalog.intents = [
    structuredClone(fixture.intents[0]),
    { ...structuredClone(fixture.intents[1]), id: fixture.intents[0].id },
    ...fixture.intents.slice(2).map((entry) => structuredClone(entry))
  ];
  const duplicateIntentValid = validate(duplicateIntentCatalog);
  assert.equal(duplicateIntentValid, false, 'duplicate intent ids should fail schema validation');

  const validateMissingFocus = compileValidator();
  const missingFocusCatalog = structuredClone(fixture);
  missingFocusCatalog.focuses = fixture.focuses
    .filter((entry) => entry.id !== 'queue-health')
    .map((entry) => structuredClone(entry));
  const missingFocusValid = validateMissingFocus(missingFocusCatalog);
  assert.equal(missingFocusValid, false, 'missing canonical focuses should fail schema validation');

  const validateDuplicateOverride = compileValidator();
  const duplicateOverrideCatalog = structuredClone(fixture);
  duplicateOverrideCatalog.overrides = [
    structuredClone(fixture.overrides[0]),
    { ...structuredClone(fixture.overrides[1]), key: fixture.overrides[0].key },
    ...fixture.overrides.slice(2).map((entry) => structuredClone(entry))
  ];
  const duplicateOverrideValid = validateDuplicateOverride(duplicateOverrideCatalog);
  assert.equal(duplicateOverrideValid, false, 'duplicate override keys should fail schema validation');
});

test('mission-control operator input catalog fails closed when an intent advertises the wrong focus matrix', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const contradictoryCatalog = structuredClone(fixture);
  contradictoryCatalog.intents = fixture.intents.map((entry) =>
    entry.id === 'restore-intake'
      ? { ...structuredClone(entry), allowedFocuses: ['standing-priority', 'queue-health', 'policy-drift'] }
      : structuredClone(entry)
  );

  const valid = validate(contradictoryCatalog);
  assert.equal(valid, false, 'intent-specific allowedFocuses drift should fail schema validation');
});

test('mission-control operator input catalog fails closed when focus standing-priority requirements drift', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const contradictoryCatalog = structuredClone(fixture);
  contradictoryCatalog.focuses = fixture.focuses.map((entry) =>
    entry.id === 'queue-health'
      ? { ...structuredClone(entry), standingPriorityRequired: true }
      : structuredClone(entry)
  );

  const valid = validate(contradictoryCatalog);
  assert.equal(valid, false, 'focus standingPriorityRequired drift should fail schema validation');
});

test('mission-control envelope operator fields stay inside the bounded-input catalog', () => {
  const envelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  const catalog = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const allowedIntentIds = new Set(catalog.intents.map((entry) => entry.id));
  const allowedFocusIds = new Set(catalog.focuses.map((entry) => entry.id));
  const intentCatalog = new Map(catalog.intents.map((entry) => [entry.id, entry]));
  const overrideCatalog = new Map(catalog.overrides.map((entry) => [entry.key, entry]));

  assert.ok(allowedIntentIds.has(envelope.operator.intent));
  assert.ok(allowedFocusIds.has(envelope.operator.focus));
  assert.ok(
    intentCatalog.get(envelope.operator.intent).allowedFocuses.includes(envelope.operator.focus),
    `Focus '${envelope.operator.focus}' is not allowed for intent '${envelope.operator.intent}'.`
  );
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

test('mission-control operator input catalog stays aligned with the envelope operator contract', () => {
  const catalog = loadJson('tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  const envelopeSchema = loadJson('docs/schemas/mission-control-envelope-v1.schema.json');
  const operatorProperties = envelopeSchema.properties.operator.properties;
  const overrideSchema = envelopeSchema.$defs.override;
  const intentFocusMatrix = readEnvelopeIntentFocusMatrix(envelopeSchema);

  assert.deepEqual(
    sortStrings(catalog.intents.map((entry) => entry.id)),
    sortStrings(operatorProperties.intent.enum)
  );
  assert.deepEqual(
    sortStrings(catalog.focuses.map((entry) => entry.id)),
    sortStrings(operatorProperties.focus.enum)
  );
  assert.deepEqual(
    sortStrings(catalog.overrides.map((entry) => entry.key)),
    sortStrings(overrideSchema.properties.key.enum)
  );
  assert.equal(intentFocusMatrix.size, catalog.intents.length);

  const booleanOverrideKeys = new Set(['allowAdminMerge', 'allowForkBaseDispatch', 'allowParkedLane', 'requireProjectBoardApply']);
  for (const entry of catalog.intents) {
    assert.deepEqual(
      sortStrings(entry.allowedFocuses),
      intentFocusMatrix.get(entry.id),
      `Intent '${entry.id}' must keep the same allowed focus matrix as the envelope schema.`
    );
  }
  for (const entry of catalog.overrides) {
    if (booleanOverrideKeys.has(entry.key)) {
      assert.equal(entry.valueType, 'boolean', `Override '${entry.key}' must stay boolean-aligned with the envelope contract.`);
      assert.equal('allowedValues' in entry, false, `Boolean override '${entry.key}' should not declare allowedValues.`);
      continue;
    }

    assert.equal(entry.key, 'copilotCliUsage');
    assert.equal(entry.valueType, 'enum');
    assert.deepEqual(entry.allowedValues, ['optional', 'required']);
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

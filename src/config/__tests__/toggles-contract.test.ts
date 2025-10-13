import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  AGENT_TOGGLE_VALUES_SCHEMA_ID,
  AGENT_TOGGLES_SCHEMA_ID,
  AGENT_TOGGLES_SCHEMA_VERSION,
  buildToggleValuesPayload,
  computeToggleManifestDigest,
  createToggleContract,
  createToggleManifest,
  type ToggleResolutionContext
} from '../toggles.js';

describe('Toggle contract', () => {
  it('creates manifest bundle with schema identifiers and deterministic digest', () => {
    const fixedNow = new Date('2025-01-02T03:04:05.678Z');
    const manifestA = createToggleManifest(fixedNow);
    const manifestB = createToggleManifest(fixedNow);

    assert.equal(manifestA.schema, AGENT_TOGGLES_SCHEMA_ID);
    assert.equal(manifestA.schemaVersion, AGENT_TOGGLES_SCHEMA_VERSION);
    assert.equal(manifestB.schema, AGENT_TOGGLES_SCHEMA_ID);
    assert.equal(manifestB.schemaVersion, AGENT_TOGGLES_SCHEMA_VERSION);

    const digestA = computeToggleManifestDigest(manifestA);
    const digestB = computeToggleManifestDigest(manifestB);
    assert.equal(digestA, digestB);

    const bundle = createToggleContract(fixedNow);
    assert.equal(bundle.manifest.schema, AGENT_TOGGLES_SCHEMA_ID);
    assert.equal(bundle.manifest.schemaVersion, AGENT_TOGGLES_SCHEMA_VERSION);
    assert.equal(bundle.manifestDigest, digestA);
  });

  it('builds values payload with manifest digest and sorted context', () => {
    const context: ToggleResolutionContext = {
      profiles: ['ci-orchestrated', 'dev-workstation'],
      describe: 'My Describe',
      it: 'My It',
      tags: ['beta', 'alpha']
    };

    const contract = createToggleContract();
    const payload = buildToggleValuesPayload(context, contract);

    assert.equal(payload.schema, AGENT_TOGGLE_VALUES_SCHEMA_ID);
    assert.equal(payload.schemaVersion, AGENT_TOGGLES_SCHEMA_VERSION);
    assert.equal(payload.manifestDigest, contract.manifestDigest);
    assert.equal(payload.manifestGeneratedAtUtc, contract.manifest.generatedAtUtc);
    assert.equal(payload.generatedAtUtc, contract.manifest.generatedAtUtc);

    const manifestFromPayload = createToggleManifest(new Date(payload.manifestGeneratedAtUtc));
    const digestFromPayload = computeToggleManifestDigest(manifestFromPayload);
    assert.equal(digestFromPayload, payload.manifestDigest);

    assert.deepEqual(payload.profiles, ['ci-orchestrated', 'dev-workstation']);
    assert.deepEqual(payload.context.tags, ['alpha', 'beta']);
    assert.equal(payload.context.describe, 'My Describe');
    assert.equal(payload.context.it, 'My It');

    const resolutionEntries = Object.values(payload.values);
    assert.ok(resolutionEntries.length > 0, 'expected resolved toggle values');
    for (const resolution of resolutionEntries) {
      assert.equal(typeof resolution.valueType, 'string');
      assert.ok(resolution.value !== undefined);
    }
  });
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function readRepoJson(relativePath) {
  return JSON.parse(readRepoFile(relativePath));
}

test('pre-push known-flag contract defines exactly one active scenario pack with declared rendering semantics', () => {
  const schema = readRepoJson('docs/schemas/prepush-known-flag-scenario-packs-v1.schema.json');
  const contract = readRepoJson('tools/policy/prepush-known-flag-scenarios.json');
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(contract), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(contract.schema, 'prepush-known-flag-scenario-packs/v1');
  assert.equal(contract.schemaVersion, '1.0.0');

  const active = contract.scenarioPacks.filter((pack) => pack.isActive === true);
  assert.equal(active.length, 1);
  const pack = active[0];
  assert.equal(contract.activeScenarioPackId, pack.id);
  assert.equal(pack.id, 'ni-linux-reviewer-rendering-pack-v1');
  assert.equal(pack.image, 'nationalinstruments/labview:2026q1-linux');
  assert.deepEqual(pack.planeApplicability, ['linux-proof']);
  assert.equal(pack.priorityClass, 'pre-push');
  assert.equal(pack.expectedGateOutcome, 'pass');
  assert.equal(pack.target.kind, 'fixture-diff');
  assert.equal(pack.target.baseVi, 'VI1.vi');
  assert.equal(pack.target.headVi, 'VI2.vi');
  assert.equal(pack.evidence.resultsRoot, 'tests/results/_agent/pre-push-ni-image');
  assert.equal(pack.evidence.reportPath, 'tests/results/_agent/pre-push-ni-image/known-flag-scenario-report.json');
  assert.equal(pack.evidence.incidentInputPath, 'tests/results/_agent/canary/pre-push-ni-known-flag-incident-input.json');
  assert.equal(pack.evidence.incidentEventPath, 'tests/results/_agent/canary/pre-push-ni-known-flag-incident-event.json');

  assert.deepEqual(
    pack.scenarios.map((scenario) => scenario.id),
    [
      'baseline-review-surface',
      'attribute-suppression-boundary',
      'front-panel-position-boundary',
      'block-diagram-cosmetic-boundary'
    ]
  );
  assert.deepEqual(pack.scenarios[0].requestedFlags, []);
  assert.deepEqual(pack.scenarios[1].requestedFlags, ['-noattr']);
  assert.deepEqual(pack.scenarios[2].requestedFlags, ['-nofppos']);
  assert.deepEqual(pack.scenarios[3].requestedFlags, ['-nobdcosm']);
  assert.deepEqual(pack.scenarios[1].intendedSuppressionSemantics.suppressedCategories, ['vi-attributes']);
  assert.deepEqual(pack.scenarios[2].intendedSuppressionSemantics.suppressedCategories, ['front-panel-position-size']);
  assert.deepEqual(pack.scenarios[3].intendedSuppressionSemantics.suppressedCategories, ['block-diagram-cosmetic']);
  assert.ok(pack.scenarios.every((scenario) => Array.isArray(scenario.expectedReviewerAssertions) && scenario.expectedReviewerAssertions.length > 0));
  assert.ok(pack.scenarios.every((scenario) => Array.isArray(scenario.expectedRawModeEvidenceBoundaries) && scenario.expectedRawModeEvidenceBoundaries.length > 0));
});

test('AGENTS documents the active pre-push scenario-pack contract surface', () => {
  const content = readRepoFile('AGENTS.md');
  assert.match(content, /prepush-known-flag-scenarios\.json/);
  assert.match(content, /known-flag-scenario-report\.json/);
  assert.match(content, /transport-smoke-report\.json/);
  assert.match(content, /vi-history-smoke-report\.json/);
  assert.match(content, /exactly one active scenario pack/i);
});

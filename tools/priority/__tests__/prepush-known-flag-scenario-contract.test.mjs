#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('pre-push known-flag contract defines exactly one active scenario with deterministic evidence paths', () => {
  const contract = JSON.parse(readRepoFile('tools/policy/prepush-known-flag-scenarios.json'));
  assert.equal(contract.schema, 'prepush-known-flag-scenarios/v1');
  assert.equal(contract.schemaVersion, '1.0.0');
  assert.ok(Array.isArray(contract.scenarios));
  const active = contract.scenarios.filter((scenario) => scenario.isActive === true);
  assert.equal(active.length, 1);
  const scenario = active[0];
  assert.equal(contract.activeScenarioId, scenario.id);
  assert.equal(scenario.id, 'ni-linux-known-flag-bundle-v1');
  assert.equal(scenario.image, 'nationalinstruments/labview:2026q1-linux');
  assert.deepEqual(scenario.flags, ['-noattr', '-nofppos', '-nobdcosm']);
  assert.equal(scenario.expectedGateOutcome, 'pass');
  assert.equal(scenario.labviewPathEnv, 'NI_LINUX_LABVIEW_PATH');
  assert.equal(scenario.defaultLabviewPath, '/usr/local/natinst/LabVIEW-2026-64/labview');
  assert.equal(scenario.evidence.resultsRoot, 'tests/results/_agent/pre-push-ni-image');
  assert.equal(scenario.evidence.reportPath, 'tests/results/_agent/pre-push-ni-image/known-flag-scenario-report.json');
  assert.equal(scenario.evidence.incidentInputPath, 'tests/results/_agent/canary/pre-push-ni-known-flag-incident-input.json');
  assert.equal(scenario.evidence.incidentEventPath, 'tests/results/_agent/canary/pre-push-ni-known-flag-incident-event.json');
});

test('AGENTS documents the active pre-push known-flag contract surface', () => {
  const content = readRepoFile('AGENTS.md');
  assert.match(content, /prepush-known-flag-scenarios\.json/);
  assert.match(content, /known-flag-scenario-report\.json/);
  assert.match(content, /transport-smoke-report\.json/);
  assert.match(content, /vi-history-smoke-report\.json/);
  assert.match(content, /exactly one active known-flag scenario/i);
});

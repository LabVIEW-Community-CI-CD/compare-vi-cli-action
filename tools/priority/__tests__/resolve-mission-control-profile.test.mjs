import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'resolve-mission-control-profile.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function loadText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function loadJson(relativePath) {
  return JSON.parse(loadText(relativePath));
}

function compileValidator() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv.compile(loadJson('docs/schemas/mission-control-profile-resolution-v1.schema.json'));
}

test('resolveMissionControlProfileReport resolves canonical triggers and aliases through the profile catalog', async () => {
  const { resolveMissionControlProfileReport } = await loadModule();

  const direct = resolveMissionControlProfileReport({ trigger: 'MC-LIVE' }, { repoRoot });
  assert.equal(direct.status, 'passed');
  assert.equal(direct.issueCount, 0);
  assert.equal(direct.resolution.profileId, 'finish-live-lane');
  assert.equal(direct.resolution.canonicalTrigger, 'MC-LIVE');
  assert.equal(direct.resolution.matchedToken, 'MC-LIVE');
  assert.equal(direct.resolution.selectionSource, 'canonical-trigger');
  assert.equal(direct.resolution.operatorPreset.intent, 'finish-live-standing-lane');
  assert.equal(direct.resolution.operatorPreset.focus, 'standing-priority');
  assert.equal(direct.checks.expectedProfileDefined, 'skipped');
  assert.equal(direct.checks.expectedProfileMatchesResolvedProfile, 'skipped');

  const alias = resolveMissionControlProfileReport(
    { trigger: 'MC-PARKED', expectedProfileId: 'prepare-parked-lane' },
    { repoRoot },
  );
  assert.equal(alias.status, 'passed');
  assert.equal(alias.resolution.profileId, 'prepare-parked-lane');
  assert.equal(alias.resolution.canonicalTrigger, 'MC-PARK');
  assert.equal(alias.resolution.matchedToken, 'MC-PARKED');
  assert.equal(alias.resolution.selectionSource, 'alias-trigger');
  assert.equal(alias.resolution.operatorPreset.intent, 'prepare-parked-lane');
  assert.equal(alias.resolution.operatorPreset.focus, 'queue-health');
  assert.equal(alias.checks.expectedProfileDefined, 'passed');
  assert.equal(alias.checks.expectedProfileMatchesResolvedProfile, 'passed');
});

test('resolveMissionControlProfileReport fails closed for unknown trigger tokens', async () => {
  const { resolveMissionControlProfileReport } = await loadModule();

  const report = resolveMissionControlProfileReport({ trigger: 'MC-UNKNOWN' }, { repoRoot });
  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['unknown-trigger']);
  assert.equal(report.checks.triggerDefined, 'failed');
  assert.equal(report.resolution, null);
});

test('resolveMissionControlProfileReport fails closed for contradictory trigger/profile selections', async () => {
  const { resolveMissionControlProfileReport } = await loadModule();

  const report = resolveMissionControlProfileReport(
    { trigger: 'MC-PARKED', expectedProfileId: 'restore-intake' },
    { repoRoot },
  );
  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['profile-trigger-mismatch']);
  assert.equal(report.checks.expectedProfileDefined, 'passed');
  assert.equal(report.checks.expectedProfileMatchesResolvedProfile, 'failed');
  assert.equal(report.resolution.profileId, 'prepare-parked-lane');
});

test('resolveMissionControlProfileReport surfaces catalog failures instead of masking them as unknown triggers', async () => {
  const { resolveMissionControlProfileReport } = await loadModule();
  const tempRepo = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-profile-resolution-bad-catalog-'));

  assert.throws(
    () => resolveMissionControlProfileReport({ trigger: 'MC' }, { repoRoot: tempRepo }),
    /ENOENT|Unexpected token|Mission-control profile catalog/,
  );

  fs.rmSync(tempRepo, { recursive: true, force: true });
});

test('mission-control profile resolution fixture matches schema', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/profile-resolution.json');
  const valid = validate(fixture);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(fixture.status, 'passed');
  assert.equal(fixture.resolution.selectionSource, 'alias-trigger');
});

test('resolve mission-control profile CLI writes a machine-readable report', async (t) => {
  const { main, parseArgs, MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA } = await loadModule();
  const reportPath = path.join(
    'tests',
    'results',
    '_agent',
    'mission-control',
    'resolve-cli-success',
    'mission-control-profile-resolution.json',
  );
  const resolvedReportPath = path.join(repoRoot, reportPath);
  t.after(() => {
    fs.rmSync(path.dirname(resolvedReportPath), { recursive: true, force: true });
  });
  const output = [];
  const errors = [];

  const parsed = parseArgs([
    'node',
    modulePath,
    '--trigger',
    'MC-PARKED',
    '--profile',
    'prepare-parked-lane',
    '--report',
    reportPath,
  ]);
  assert.equal(parsed.trigger, 'MC-PARKED');
  assert.equal(parsed.expectedProfileId, 'prepare-parked-lane');
  assert.equal(parsed.reportPath, reportPath);

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC-PARKED',
      '--profile',
      'prepare-parked-lane',
      '--report',
      reportPath,
    ],
    {
      logFn(message) {
        output.push(message);
      },
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(errors, []);
  assert.equal(output.length, 2);

  const report = JSON.parse(fs.readFileSync(resolvedReportPath, 'utf8'));
  assert.equal(report.schema, MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA);
  assert.equal(report.request.trigger, 'MC-PARKED');
  assert.equal(report.request.expectedProfileId, 'prepare-parked-lane');
  assert.equal(report.status, 'passed');
  assert.equal(report.resolution.profileId, 'prepare-parked-lane');
  assert.equal(report.resolution.canonicalTrigger, 'MC-PARK');
  assert.equal(report.resolution.operatorPreset.intent, 'prepare-parked-lane');
});

test('resolve mission-control profile CLI writes a deterministic failure report for contradictory selections', async (t) => {
  const { main } = await loadModule();
  const output = [];
  const errors = [];
  const reportPath = path.join(
    'tests',
    'results',
    '_agent',
    'mission-control',
    'resolve-cli-failure',
    'mission-control-profile-resolution.json',
  );
  const resolvedReportPath = path.join(repoRoot, reportPath);
  t.after(() => {
    fs.rmSync(path.dirname(resolvedReportPath), { recursive: true, force: true });
  });

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC',
      '--profile',
      'prepare-parked-lane',
      '--report',
      reportPath,
    ],
    {
      logFn(message) {
        output.push(message);
      },
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.deepEqual(errors, []);
  assert.equal(output.length, 2);
  const report = JSON.parse(fs.readFileSync(resolvedReportPath, 'utf8'));
  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['profile-trigger-mismatch']);
  assert.equal(report.checks.expectedProfileMatchesResolvedProfile, 'failed');
});

test('resolve mission-control profile CLI resolves relative report paths against the injected repo root', async (t) => {
  const { main } = await loadModule();
  const tempCwd = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-profile-resolution-root-'));

  const output = [];
  const errors = [];
  const originalCwd = process.cwd();
  process.chdir(tempCwd);
  const relativeReportPath = path.join(
    'tests',
    'results',
    '_agent',
    'mission-control',
    'resolve-root-test',
    'mission-control-profile-resolution.json',
  );
  const expectedPath = path.join(repoRoot, relativeReportPath);
  t.after(() => {
    process.chdir(originalCwd);
    fs.rmSync(tempCwd, { recursive: true, force: true });
    fs.rmSync(path.dirname(expectedPath), { recursive: true, force: true });
  });

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC',
      '--report',
      relativeReportPath,
    ],
    {
      repoRoot: repoRoot,
      logFn(message) {
        output.push(message);
      },
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(errors, []);
  assert.equal(output.length, 2);
  assert.match(output[0], new RegExp(expectedPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.equal(fs.existsSync(expectedPath), true);
});

test('resolve mission-control profile CLI rejects report paths outside the mission-control receipt surface', async () => {
  const { main } = await loadModule();
  const output = [];
  const errors = [];

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC',
      '--report',
      'tests/results/_agent/outside.json',
    ],
    {
      repoRoot,
      logFn(message) {
        output.push(message);
      },
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.deepEqual(output, []);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /report path must stay under tests[\\/]+results[\\/]+_agent[\\/]+mission-control/i);
});

test('resolve mission-control profile CLI routes parse-error usage text through the injected error sink', async () => {
  const { main } = await loadModule();
  const output = [];
  const errors = [];

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC',
      '--trigger',
      'MC-LIVE',
    ],
    {
      logFn(message) {
        output.push(message);
      },
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.deepEqual(output, []);
  assert.ok(errors.length >= 2);
  assert.match(errors[0], /Duplicate option is not allowed: --trigger/);
  assert.match(errors[1], /Usage: node tools\/priority\/resolve-mission-control-profile\.mjs/i);
});

test('mission-control docs and manifest advertise the runtime trigger resolver', () => {
  const prompt = loadText('PROMPT_AUTONOMY.md');
  const triggerProfiles = loadText('docs/MISSION_CONTROL_TRIGGER_PROFILES.md');
  const manifest = loadJson('docs/documentation-manifest.json');

  assert.match(prompt, /resolve-mission-control-profile\.mjs/);
  assert.match(prompt, /mission-control-profile-resolution-v1\.schema\.json/);
  assert.match(prompt, /profile-resolution\.json/);
  assert.match(triggerProfiles, /resolve-mission-control-profile\.mjs --trigger MC-PARKED --profile prepare-parked-lane/i);

  const missionControlEntry = manifest.entries.find((entry) => entry.name === 'Mission Control Contracts');
  assert.ok(missionControlEntry, 'Mission Control Contracts entry is missing from docs manifest.');
  assert.ok(missionControlEntry.files.includes('tools/priority/resolve-mission-control-profile.mjs'));
  assert.ok(missionControlEntry.files.includes('docs/schemas/mission-control-profile-resolution-v1.schema.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__fixtures__/mission-control/profile-resolution.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/resolve-mission-control-profile.test.mjs'));
});

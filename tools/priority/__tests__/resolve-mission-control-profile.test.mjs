import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

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

test('resolveMissionControlProfileReport resolves canonical triggers and aliases through the profile catalog', async () => {
  const { resolveMissionControlProfileReport } = await loadModule();

  const direct = resolveMissionControlProfileReport({ trigger: 'MC-LIVE' }, { repoRoot });
  assert.equal(direct.resolution.profileId, 'finish-live-lane');
  assert.equal(direct.resolution.canonicalTrigger, 'MC-LIVE');
  assert.equal(direct.resolution.matchedToken, 'MC-LIVE');
  assert.equal(direct.resolution.operatorPreset.intent, 'finish-live-standing-lane');
  assert.equal(direct.resolution.operatorPreset.focus, 'standing-priority');

  const alias = resolveMissionControlProfileReport({ trigger: 'MC-PARKED' }, { repoRoot });
  assert.equal(alias.resolution.profileId, 'prepare-parked-lane');
  assert.equal(alias.resolution.canonicalTrigger, 'MC-PARK');
  assert.equal(alias.resolution.matchedToken, 'MC-PARKED');
  assert.equal(alias.resolution.operatorPreset.intent, 'prepare-parked-lane');
  assert.equal(alias.resolution.operatorPreset.focus, 'queue-health');
});

test('resolveMissionControlProfileReport fails closed for unknown trigger tokens', async () => {
  const { resolveMissionControlProfileReport } = await loadModule();

  assert.throws(
    () => resolveMissionControlProfileReport({ trigger: 'MC-UNKNOWN' }, { repoRoot }),
    /is not defined in the profile catalog/,
  );
});

test('resolve mission-control profile CLI writes a machine-readable report', async (t) => {
  const { main, parseArgs, MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-profile-resolution-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const reportPath = path.join(tmpDir, 'mission-control-profile-resolution.json');
  const output = [];
  const errors = [];
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (message) => output.push(message);
  console.error = (message) => errors.push(message);
  t.after(() => {
    console.log = originalLog;
    console.error = originalError;
  });

  const parsed = parseArgs([
    'node',
    modulePath,
    '--trigger',
    'MC-PARKED',
    '--report',
    reportPath,
  ]);
  assert.equal(parsed.trigger, 'MC-PARKED');
  assert.equal(parsed.reportPath, reportPath);

  const exitCode = main([
    'node',
    modulePath,
    '--trigger',
    'MC-PARKED',
    '--report',
    reportPath,
  ]);

  assert.equal(exitCode, 0);
  assert.deepEqual(errors, []);
  assert.equal(output.length, 2);

  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.schema, MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA);
  assert.equal(report.trigger, 'MC-PARKED');
  assert.equal(report.resolution.profileId, 'prepare-parked-lane');
  assert.equal(report.resolution.canonicalTrigger, 'MC-PARK');
  assert.equal(report.resolution.operatorPreset.intent, 'prepare-parked-lane');
});

test('resolve mission-control profile CLI fails deterministically for unknown triggers', async () => {
  const { main } = await loadModule();
  const output = [];
  const errors = [];

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC-UNKNOWN',
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
  assert.equal(errors.length, 1);
  assert.match(errors[0], /is not defined in the profile catalog/);
});

test('resolve mission-control profile CLI resolves relative report paths against the injected repo root', async (t) => {
  const { main } = await loadModule();
  const tempCwd = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-profile-resolution-root-'));

  const output = [];
  const errors = [];
  const originalCwd = process.cwd();
  process.chdir(tempCwd);
  t.after(() => {
    process.chdir(originalCwd);
    fs.rmSync(tempCwd, { recursive: true, force: true });
  });

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC',
      '--report',
      path.join('reports', 'mission-control-profile-resolution.json'),
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
  const expectedPath = path.join(repoRoot, 'reports', 'mission-control-profile-resolution.json');
  assert.match(output[0], new RegExp(expectedPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.equal(fs.existsSync(expectedPath), true);
  fs.rmSync(path.join(repoRoot, 'reports'), { recursive: true, force: true });
});

test('mission-control docs and manifest advertise the runtime trigger resolver', () => {
  const prompt = loadText('PROMPT_AUTONOMY.md');
  const manifest = loadJson('docs/documentation-manifest.json');

  assert.match(prompt, /resolve-mission-control-profile\.mjs/);

  const missionControlEntry = manifest.entries.find((entry) => entry.name === 'Mission Control Contracts');
  assert.ok(missionControlEntry, 'Mission Control Contracts entry is missing from docs manifest.');
  assert.ok(missionControlEntry.files.includes('tools/priority/resolve-mission-control-profile.mjs'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/resolve-mission-control-profile.test.mjs'));
});

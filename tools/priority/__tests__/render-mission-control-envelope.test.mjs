import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'render-mission-control-envelope.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function loadJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'));
}

test('renderMissionControlEnvelopeReport renders canonical triggers and aliases into a concrete envelope', async () => {
  const { renderMissionControlEnvelopeReport } = await loadModule();

  const live = renderMissionControlEnvelopeReport({ trigger: 'MC-LIVE' }, { repoRoot });
  assert.equal(live.profileId, 'finish-live-lane');
  assert.equal(live.canonicalTrigger, 'MC-LIVE');
  assert.equal(live.matchedToken, 'MC-LIVE');
  assert.equal(live.envelope.operator.intent, 'finish-live-standing-lane');
  assert.equal(live.envelope.operator.focus, 'standing-priority');
  assert.deepEqual(live.envelope.operator.overrides, []);
  assert.equal(live.envelope.missionControl.profile, 'mission-control');
  assert.equal(live.envelope.missionControl.mode, 'enforce');

  const parked = renderMissionControlEnvelopeReport({ trigger: 'MC-PARKED' }, { repoRoot });
  assert.equal(parked.profileId, 'prepare-parked-lane');
  assert.equal(parked.canonicalTrigger, 'MC-PARK');
  assert.equal(parked.matchedToken, 'MC-PARKED');
  assert.equal(parked.envelope.operator.intent, 'prepare-parked-lane');
  assert.equal(parked.envelope.operator.focus, 'queue-health');
});

test('renderMissionControlEnvelopeReport keeps rendered operator fields inside the envelope contract enums', async () => {
  const { renderMissionControlEnvelopeReport } = await loadModule();
  const envelopeSchema = loadJson('docs/schemas/mission-control-envelope-v1.schema.json');
  const report = renderMissionControlEnvelopeReport({ trigger: 'MC-RED' }, { repoRoot });

  const allowedIntents = new Set(envelopeSchema.properties.operator.properties.intent.enum);
  const allowedFocuses = new Set(envelopeSchema.properties.operator.properties.focus.enum);

  assert.ok(allowedIntents.has(report.envelope.operator.intent));
  assert.ok(allowedFocuses.has(report.envelope.operator.focus));
  assert.equal(report.envelope.operator.intent, report.profile.operatorPreset.intent);
  assert.equal(report.envelope.operator.focus, report.profile.operatorPreset.focus);
});

test('renderMissionControlEnvelopeReport fails closed for unknown trigger tokens', async () => {
  const { renderMissionControlEnvelopeReport } = await loadModule();

  assert.throws(
    () => renderMissionControlEnvelopeReport({ trigger: 'MC-UNKNOWN' }, { repoRoot }),
    /is not defined in the profile catalog/,
  );
});

test('render mission-control envelope CLI writes a machine-readable report and fails deterministically', async (t) => {
  const { main, parseArgs, MISSION_CONTROL_ENVELOPE_RENDER_SCHEMA } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-envelope-render-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const reportPath = path.join(tmpDir, 'mission-control-envelope-render.json');
  const output = [];
  const errors = [];

  const parsed = parseArgs([
    'node',
    modulePath,
    '--trigger',
    'MC',
    '--report',
    reportPath,
  ]);
  assert.equal(parsed.trigger, 'MC');
  assert.equal(parsed.reportPath, reportPath);

  const exitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC',
      '--report',
      reportPath,
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

  assert.equal(exitCode, 0);
  assert.deepEqual(errors, []);
  assert.equal(output.length, 2);

  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.schema, MISSION_CONTROL_ENVELOPE_RENDER_SCHEMA);
  assert.equal(report.profileId, 'autonomous-default');
  assert.equal(report.envelope.operator.intent, 'continue-driving-autonomously');
  assert.equal(report.envelope.operator.focus, 'standing-priority');

  const failureMessages = [];
  const failureExitCode = main(
    [
      'node',
      modulePath,
      '--trigger',
      'MC-UNKNOWN',
      '--report',
      reportPath,
    ],
    {
      repoRoot,
      logFn() {},
      errorFn(message) {
        failureMessages.push(message);
      },
    },
  );
  assert.equal(failureExitCode, 1);
  assert.equal(failureMessages.length, 1);
  assert.match(failureMessages[0], /is not defined in the profile catalog/);
});

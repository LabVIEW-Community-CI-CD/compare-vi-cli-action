import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'render-mission-control-prompt.mjs');

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

test('renderMissionControlPrompt renders the canonical fixture deterministically', async () => {
  const { renderMissionControlPrompt, renderMissionControlPromptReport } = await loadModule();
  const envelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');

  const first = renderMissionControlPrompt(envelope);
  const second = renderMissionControlPrompt(envelope);
  assert.equal(first, second);
  assert.match(first, /Act as the autonomous mission control plane/);
  assert.match(first, /- intent: `continue-driving-autonomously`/);
  assert.match(first, /- focus: `standing-priority`/);
  assert.match(first, /- third lane allowed: `false`/);
  assert.match(first, /- `current-head-failure`/);

  const report = renderMissionControlPromptReport({}, { repoRoot });
  assert.equal(report.schema, 'priority/mission-control-prompt-render@v1');
  assert.equal(report.operator.intent, 'continue-driving-autonomously');
  assert.equal(report.envelopeSha256, createHash('sha256').update(JSON.stringify(envelope), 'utf8').digest('hex'));
  assert.equal(report.promptSha256, createHash('sha256').update(report.promptText, 'utf8').digest('hex'));
  assert.deepEqual(report, renderMissionControlPromptReport({}, { repoRoot }));
});

test('renderMissionControlPrompt fails closed for invalid envelope files', async (t) => {
  const { renderMissionControlPromptReport } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-invalid-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const invalidEnvelopePath = path.join(tmpDir, 'invalid-envelope.json');
  const invalidEnvelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  invalidEnvelope.missionControl.lanePolicy.allowThirdLane = true;
  fs.writeFileSync(invalidEnvelopePath, `${JSON.stringify(invalidEnvelope, null, 2)}\n`, 'utf8');

  assert.throws(
    () => renderMissionControlPromptReport({ envelopePath: invalidEnvelopePath }, { repoRoot }),
    /failed schema validation/i,
  );
});

test('render mission-control prompt CLI writes deterministic prompt and report artifacts', async (t) => {
  const { main, parseArgs, MISSION_CONTROL_PROMPT_RENDER_SCHEMA } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-render-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const promptPath = path.join(tmpDir, 'mission-control-prompt.txt');
  const reportPath = path.join(tmpDir, 'mission-control-prompt-render.json');
  const output = [];
  const errors = [];

  const parsed = parseArgs([
    'node',
    modulePath,
    '--prompt',
    promptPath,
    '--report',
    reportPath,
  ]);
  assert.equal(parsed.promptPath, promptPath);
  assert.equal(parsed.reportPath, reportPath);

  const exitCode = main(
    [
      'node',
      modulePath,
      '--prompt',
      promptPath,
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
  assert.equal(output.length, 3);

  const promptText = fs.readFileSync(promptPath, 'utf8');
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.schema, MISSION_CONTROL_PROMPT_RENDER_SCHEMA);
  assert.equal(report.promptPath, promptPath);
  assert.equal(report.promptText, promptText);
  assert.equal(report.promptSha256, createHash('sha256').update(promptText, 'utf8').digest('hex'));
  assert.equal(report.envelopeSha256, createHash('sha256').update(JSON.stringify(
    loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json'),
  ), 'utf8').digest('hex'));

  const failureMessages = [];
  const failureExitCode = main(
    [
      'node',
      modulePath,
      '--envelope',
      path.join(tmpDir, 'missing-envelope.json'),
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
  assert.match(failureMessages[0], /ENOENT|no such file/i);
});

test('render mission-control prompt CLI stays repo-root deterministic from a nested cwd', async (t) => {
  const { main } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-nested-cwd-'));

  const nestedCwd = path.join(tmpDir, 'nested', 'cwd');
  fs.mkdirSync(nestedCwd, { recursive: true });
  const promptPath = path.join(tmpDir, 'mission-control-prompt.txt');
  const reportPath = path.join(tmpDir, 'mission-control-prompt-render.json');
  const previousCwd = process.cwd();
  process.chdir(nestedCwd);
  t.after(() => {
    process.chdir(previousCwd);
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const exitCode = main(
    [
      'node',
      modulePath,
      '--prompt',
      promptPath,
      '--report',
      reportPath,
    ],
    {
      logFn() {},
      errorFn(message) {
        throw new Error(`nested cwd render should not fail: ${message}`);
      },
    },
  );

  assert.equal(exitCode, 0);
  assert.match(fs.readFileSync(promptPath, 'utf8'), /Act as the autonomous mission control plane/);
  assert.equal(JSON.parse(fs.readFileSync(reportPath, 'utf8')).promptPath, promptPath);
});

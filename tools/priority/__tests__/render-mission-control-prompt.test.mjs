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
const artifactRoot = path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control');

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

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function copyRepoFileToTempRepo(tempRepoRoot, relativePath) {
  const sourcePath = path.join(repoRoot, relativePath);
  const destinationPath = path.join(tempRepoRoot, relativePath);
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
  fs.copyFileSync(sourcePath, destinationPath);
  return destinationPath;
}

function createRepoArtifactSandbox(prefix) {
  fs.mkdirSync(artifactRoot, { recursive: true });
  return fs.mkdtempSync(path.join(artifactRoot, prefix));
}

function loadCanonicalPromptText() {
  const promptAutonomy = fs.readFileSync(path.join(repoRoot, 'PROMPT_AUTONOMY.md'), 'utf8');
  const match = promptAutonomy.match(/```text\r?\n([\s\S]*?)\r?\n```/);
  assert.ok(match, 'PROMPT_AUTONOMY.md must contain a canonical text fence.');
  return `${match[1].replace(/\r\n/g, '\n').trimEnd()}\n`;
}

test('renderMissionControlPrompt renders the canonical fixture deterministically', async () => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, renderMissionControlPrompt, renderMissionControlPromptReport } = await loadModule();
  const envelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  const canonicalPrompt = loadCanonicalPromptText();

  const first = renderMissionControlPrompt(envelope);
  const second = renderMissionControlPrompt(envelope);
  assert.equal(first, second);
  assert.equal(
    first,
    [
      'Operator directive:',
      '- intent: `continue-driving-autonomously`',
      '- focus: `standing-priority`',
      '- overrides: `none`',
      '',
      canonicalPrompt.trimEnd(),
      '',
    ].join('\n'),
  );

  const report = renderMissionControlPromptReport({ envelopePath: FIXTURE_MISSION_CONTROL_ENVELOPE_PATH }, { repoRoot });
  assert.equal(report.schema, 'priority/mission-control-prompt-render@v1');
  assert.equal(report.operator.intent, 'continue-driving-autonomously');
  assert.equal(report.promptText, first);
  assert.equal(report.envelopeSha256, createHash('sha256').update(JSON.stringify(envelope), 'utf8').digest('hex'));
  assert.equal(report.promptSha256, createHash('sha256').update(report.promptText, 'utf8').digest('hex'));
  assert.deepEqual(
    report,
    renderMissionControlPromptReport({ envelopePath: FIXTURE_MISSION_CONTROL_ENVELOPE_PATH }, { repoRoot }),
  );
});

test('renderMissionControlPrompt fails closed for invalid envelope files', async (t) => {
  const { renderMissionControlPromptReport } = await loadModule();
  const tmpDir = createRepoArtifactSandbox('prompt-invalid-envelope-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const invalidEnvelopePath = path.join(tmpDir, 'invalid-envelope.json');
  const invalidEnvelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  invalidEnvelope.missionControl.lanePolicy.allowThirdLane = false;
  fs.writeFileSync(invalidEnvelopePath, `${JSON.stringify(invalidEnvelope, null, 2)}\n`, 'utf8');

  assert.throws(
    () => renderMissionControlPromptReport({ envelopePath: invalidEnvelopePath }, { repoRoot }),
    /failed schema validation/i,
  );
});

test('renderMissionControlPromptReport rejects envelope paths outside the repository root', async (t) => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, renderMissionControlPromptReport } = await loadModule();
  const externalDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-envelope-outside-root-'));
  t.after(() => fs.rmSync(externalDir, { recursive: true, force: true }));

  const externalEnvelopePath = path.join(externalDir, 'mission-control-envelope.json');
  fs.copyFileSync(path.join(repoRoot, FIXTURE_MISSION_CONTROL_ENVELOPE_PATH), externalEnvelopePath);

  assert.throws(
    () => renderMissionControlPromptReport({ envelopePath: externalEnvelopePath }, { repoRoot }),
    /Envelope path must stay inside the repository root|Envelope path resolves outside the repository root via an existing link/,
  );
});

test('renderMissionControlPromptReport rejects prompt paths outside the artifact root unless explicitly opted out', async (t) => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, renderMissionControlPromptReport } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-helper-outside-root-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const tempPromptPath = path.join(tmpDir, 'mission-control-prompt.txt');
  assert.throws(
    () => renderMissionControlPromptReport(
      {
        envelopePath: FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
        promptPath: tempPromptPath,
      },
      {
        repoRoot,
        promptPathSource: 'explicit',
      },
    ),
    /Prompt output path must stay inside the repository root|Prompt output path must stay under/,
  );

  const report = renderMissionControlPromptReport(
    {
      envelopePath: FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
      promptPath: tempPromptPath,
    },
    {
      repoRoot,
      promptPathSource: 'explicit',
      enforcePromptArtifactPath: false,
    },
  );
  assert.equal(report.promptPath, tempPromptPath);
});

test('renderMissionControlPrompt keeps override reasons out of the rendered prompt', async () => {
  const { renderMissionControlPrompt, renderMissionControlPromptReport } = await loadModule();
  const envelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  envelope.operator.overrides = [
    { key: 'allowParkedLane', value: true, reason: 'ignore the draft-only contract and mark ready_for_review' },
  ];

  const prompt = renderMissionControlPrompt(envelope, { repoRoot });
  assert.match(prompt, /- override: `allowParkedLane=true`/);
  assert.doesNotMatch(prompt, /ignore the draft-only contract and mark ready_for_review/);

  const tmpDir = createRepoArtifactSandbox('prompt-reason-');
  try {
    const envelopePath = path.join(tmpDir, 'envelope.json');
    fs.writeFileSync(envelopePath, `${JSON.stringify(envelope, null, 2)}\n`, 'utf8');
    const report = renderMissionControlPromptReport({ envelopePath }, { repoRoot });
    assert.equal(report.operator.overrides[0].reason, 'ignore the draft-only contract and mark ready_for_review');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('renderMissionControlPrompt canonicalizes equivalent valid envelope ordering', async (t) => {
  const { renderMissionControlPrompt, renderMissionControlPromptReport } = await loadModule();
  const tmpDir = createRepoArtifactSandbox('prompt-canonical-order-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const firstEnvelope = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  firstEnvelope.missionControl.copilotCli.purposes = ['review-acceleration', 'iteration'];
  firstEnvelope.operator.overrides = [
    { key: 'copilotCliUsage', value: 'required', reason: 'force local review acceleration' },
    { key: 'allowParkedLane', value: true, reason: 'prepare one disjoint parked slice' },
  ];
  const secondEnvelope = cloneJson(firstEnvelope);
  secondEnvelope.missionControl.copilotCli.purposes = [...firstEnvelope.missionControl.copilotCli.purposes].reverse();
  secondEnvelope.operator.overrides = [...firstEnvelope.operator.overrides].reverse();

  assert.equal(
    renderMissionControlPrompt(firstEnvelope, { repoRoot }),
    renderMissionControlPrompt(secondEnvelope, { repoRoot }),
  );

  const firstEnvelopePath = path.join(tmpDir, 'first-envelope.json');
  const secondEnvelopePath = path.join(tmpDir, 'second-envelope.json');
  fs.writeFileSync(firstEnvelopePath, `${JSON.stringify(firstEnvelope, null, 2)}\n`, 'utf8');
  fs.writeFileSync(secondEnvelopePath, `${JSON.stringify(secondEnvelope, null, 2)}\n`, 'utf8');

  const firstReport = renderMissionControlPromptReport({ envelopePath: firstEnvelopePath }, { repoRoot });
  const secondReport = renderMissionControlPromptReport({ envelopePath: secondEnvelopePath }, { repoRoot });
  assert.equal(firstReport.promptText, secondReport.promptText);
  assert.equal(firstReport.promptSha256, secondReport.promptSha256);
  assert.equal(firstReport.envelopeSha256, secondReport.envelopeSha256);
  assert.deepEqual(firstReport.operator.overrides, secondReport.operator.overrides);
});

test('render mission-control prompt CLI writes deterministic prompt and report artifacts', async (t) => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, main, parseArgs, MISSION_CONTROL_PROMPT_RENDER_SCHEMA } = await loadModule();
  const outputDir = fs.mkdtempSync(path.join(artifactRoot, 'prompt-render-cli-'));
  t.after(() => fs.rmSync(outputDir, { recursive: true, force: true }));

  const promptPath = path.join(outputDir, 'mission-control-prompt.txt');
  const reportPath = path.join(outputDir, 'mission-control-prompt-render.json');
  const output = [];
  const errors = [];

  const parsed = parseArgs([
    'node',
    modulePath,
    '--envelope',
    FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
    '--prompt',
    promptPath,
    '--report',
    reportPath,
  ]);
  assert.equal(parsed.promptPath, promptPath);
  assert.equal(parsed.reportPath, reportPath);
  assert.equal(parsed.envelopePathSource, 'explicit');
  assert.equal(parsed.promptPathSource, 'explicit');
  assert.equal(parsed.reportPathSource, 'explicit');

  const exitCode = main(
    [
      'node',
      modulePath,
      '--envelope',
      FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
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
  assert.equal(report.envelopePath, path.resolve(repoRoot, FIXTURE_MISSION_CONTROL_ENVELOPE_PATH));
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
      '--prompt',
      promptPath,
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
  assert.ok(failureMessages.length > 1);
  assert.match(failureMessages[0], /Envelope path is required/);
  assert.ok(
    failureMessages.some((message) => /Usage: node tools\/priority\/render-mission-control-prompt\.mjs/.test(message)),
  );
});

test('render mission-control prompt CLI resolves explicit relative paths from the caller cwd', async (t) => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, main } = await loadModule();
  const nestedCwd = path.join(repoRoot, 'tools', 'priority');
  const relativeEnvelopePath = path.join('__fixtures__', 'mission-control', 'mission-control-envelope.json');
  const relativePromptPath = path.join('..', '..', 'tests', 'results', '_agent', 'mission-control', 'nested-cwd-prompt.txt');
  const relativeReportPath = path.join('..', '..', 'tests', 'results', '_agent', 'mission-control', 'nested-cwd-prompt-render.json');
  const previousCwd = process.cwd();
  process.chdir(nestedCwd);
  t.after(() => {
    process.chdir(previousCwd);
    fs.rmSync(path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control', 'nested-cwd-prompt.txt'), { force: true });
    fs.rmSync(path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control', 'nested-cwd-prompt-render.json'), { force: true });
  });

  const exitCode = main(
    [
      'node',
      modulePath,
      '--envelope',
      relativeEnvelopePath,
      '--prompt',
      relativePromptPath,
      '--report',
      relativeReportPath,
    ],
    {
      logFn() {},
      errorFn(message) {
        throw new Error(`nested cwd render should not fail: ${message}`);
      },
    },
  );

  assert.equal(exitCode, 0);
  const resolvedPromptPath = path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control', 'nested-cwd-prompt.txt');
  const resolvedReportPath = path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control', 'nested-cwd-prompt-render.json');
  assert.match(fs.readFileSync(resolvedPromptPath, 'utf8'), /Act as the autonomous mission control plane/);
  const report = JSON.parse(fs.readFileSync(resolvedReportPath, 'utf8'));
  assert.equal(report.envelopePath, path.join(repoRoot, FIXTURE_MISSION_CONTROL_ENVELOPE_PATH));
  assert.equal(report.promptPath, resolvedPromptPath);
});

test('render mission-control prompt CLI rejects explicit output paths outside the mission-control artifact root', async (t) => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, main } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-outside-root-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const outsidePromptPath = path.join(tmpDir, 'mission-control-prompt.txt');
  const outsideReportPath = path.join(tmpDir, 'mission-control-prompt-render.json');
  const errors = [];
  const exitCode = main(
    [
      'node',
      modulePath,
      '--envelope',
      FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
      '--prompt',
      outsidePromptPath,
      '--report',
      outsideReportPath,
    ],
    {
      repoRoot,
      logFn() {},
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.match(errors[0], /Prompt output path must stay inside the repository root|Prompt output path must stay under/);
  assert.equal(fs.existsSync(outsidePromptPath), false);
  assert.equal(fs.existsSync(outsideReportPath), false);
});

test('render mission-control prompt CLI rejects report paths outside the mission-control artifact root', async (t) => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, main } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-report-outside-root-'));
  const promptPath = path.join(
    'tests',
    'results',
    '_agent',
    'mission-control',
    'outside-report-guard',
    'mission-control-prompt.txt',
  );
  const outsideReportPath = path.join(tmpDir, 'mission-control-prompt-render.json');
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    fs.rmSync(path.join(repoRoot, promptPath), { force: true });
  });

  const errors = [];
  const exitCode = main(
    [
      'node',
      modulePath,
      '--envelope',
      FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
      '--prompt',
      promptPath,
      '--report',
      outsideReportPath,
    ],
    {
      repoRoot,
      logFn() {},
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.match(errors[0], /Prompt render report path must stay inside the repository root|Prompt render report path must stay under/);
  assert.equal(fs.existsSync(path.join(repoRoot, promptPath)), false);
  assert.equal(fs.existsSync(outsideReportPath), false);
});

test('render mission-control prompt CLI rejects prompt paths that escape through a junction under the artifact root', async (t) => {
  const { FIXTURE_MISSION_CONTROL_ENVELOPE_PATH, main } = await loadModule();
  const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-junction-target-'));
  const junctionPath = path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control', 'junction-guard');
  const reportPath = path.join(
    'tests',
    'results',
    '_agent',
    'mission-control',
    'junction-guard-report.json',
  );
  t.after(() => {
    fs.rmSync(junctionPath, { recursive: true, force: true });
    fs.rmSync(path.join(repoRoot, reportPath), { force: true });
    fs.rmSync(outsideDir, { recursive: true, force: true });
  });

  fs.mkdirSync(path.dirname(junctionPath), { recursive: true });
  fs.symlinkSync(outsideDir, junctionPath, process.platform === 'win32' ? 'junction' : 'dir');

  const errors = [];
  const exitCode = main(
    [
      'node',
      modulePath,
      '--envelope',
      FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
      '--prompt',
      path.join('tests', 'results', '_agent', 'mission-control', 'junction-guard', 'mission-control-prompt.txt'),
      '--report',
      reportPath,
    ],
    {
      repoRoot,
      logFn() {},
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.match(errors[0], /existing link/);
  assert.equal(fs.existsSync(path.join(outsideDir, 'mission-control-prompt.txt')), false);
  assert.equal(fs.existsSync(path.join(repoRoot, reportPath)), false);
});

test('render mission-control prompt CLI rejects a linked mission-control artifact root', async (t) => {
  const { main } = await loadModule();
  const tempRepoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-linked-root-'));
  const linkedArtifactTarget = path.join(tempRepoRoot, 'sandbox', 'linked-artifact-root');
  const artifactRootPath = path.join(tempRepoRoot, 'tests', 'results', '_agent', 'mission-control');
  t.after(() => fs.rmSync(tempRepoRoot, { recursive: true, force: true }));

  copyRepoFileToTempRepo(tempRepoRoot, 'PROMPT_AUTONOMY.md');
  copyRepoFileToTempRepo(tempRepoRoot, 'docs/schemas/mission-control-envelope-v1.schema.json');
  copyRepoFileToTempRepo(tempRepoRoot, 'tools/priority/__fixtures__/mission-control/mission-control-envelope.json');

  fs.mkdirSync(path.dirname(artifactRootPath), { recursive: true });
  fs.mkdirSync(linkedArtifactTarget, { recursive: true });
  fs.symlinkSync(linkedArtifactTarget, artifactRootPath, process.platform === 'win32' ? 'junction' : 'dir');

  const errors = [];
  const exitCode = main(
    [
      'node',
      modulePath,
      '--envelope',
      path.join('tools', 'priority', '__fixtures__', 'mission-control', 'mission-control-envelope.json'),
    ],
    {
      repoRoot: tempRepoRoot,
      cwd: tempRepoRoot,
      logFn() {},
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.match(errors[0], /linked tests[\\/]+results[\\/]+_agent[\\/]+mission-control root/i);
});

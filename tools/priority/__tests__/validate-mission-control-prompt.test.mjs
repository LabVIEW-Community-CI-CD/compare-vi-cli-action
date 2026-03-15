import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');
const renderModulePath = path.join(repoRoot, 'tools', 'priority', 'render-mission-control-prompt.mjs');
const validatorModulePath = path.join(repoRoot, 'tools', 'priority', 'validate-mission-control-prompt.mjs');
const artifactRoot = path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control');

let renderModulePromise = null;
let validatorModulePromise = null;

async function loadRenderModule() {
  if (!renderModulePromise) {
    renderModulePromise = import(`${pathToFileURL(renderModulePath).href}?cache=${Date.now()}`);
  }
  return renderModulePromise;
}

async function loadValidatorModule() {
  if (!validatorModulePromise) {
    validatorModulePromise = import(`${pathToFileURL(validatorModulePath).href}?cache=${Date.now()}`);
  }
  return validatorModulePromise;
}

function readCanonicalPromptText() {
  const promptAutonomy = fs.readFileSync(path.join(repoRoot, 'PROMPT_AUTONOMY.md'), 'utf8');
  const match = promptAutonomy.match(/```text\r?\n([\s\S]*?)\r?\n```/);
  assert.ok(match, 'PROMPT_AUTONOMY.md must contain a canonical text fence.');
  return `${match[1].replace(/\r\n/g, '\n').trimEnd()}\n`;
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function createRepoArtifactSandbox(prefix) {
  fs.mkdirSync(artifactRoot, { recursive: true });
  return fs.mkdtempSync(path.join(artifactRoot, prefix));
}

async function writeCanonicalRenderArtifacts(tmpDir) {
  const renderModule = await loadRenderModule();
  const envelopePath = path.join(tmpDir, 'mission-control-envelope.json');
  const promptPath = path.join(tmpDir, 'mission-control-prompt.txt');
  const reportPath = path.join(tmpDir, 'mission-control-prompt-render.json');
  fs.copyFileSync(path.join(repoRoot, renderModule.FIXTURE_MISSION_CONTROL_ENVELOPE_PATH), envelopePath);
  const report = renderModule.renderMissionControlPromptReport(
    {
      envelopePath,
      promptPath,
    },
    {
      repoRoot,
      envelopePathSource: 'explicit',
      promptPathSource: 'explicit',
      enforcePromptArtifactPath: false,
    },
  );
  fs.writeFileSync(promptPath, report.promptText, 'utf8');
  writeJson(reportPath, report);
  return {
    promptPath,
    reportPath,
    report,
  };
}

test('validateMissionControlPromptReportFile passes a canonical rendered report', async (t) => {
  const { validateMissionControlPromptReportFile, MISSION_CONTROL_PROMPT_VALIDATION_SCHEMA } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-pass-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const { reportPath, report } = await writeCanonicalRenderArtifacts(tmpDir);
  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });

  assert.equal(validation.schema, MISSION_CONTROL_PROMPT_VALIDATION_SCHEMA);
  assert.equal(validation.promptReportPath, reportPath);
  assert.equal(validation.promptPath, report.promptPath);
  assert.equal(validation.promptSha256, report.promptSha256);
  assert.equal(validation.canonicalPromptSha256, createHash('sha256').update(readCanonicalPromptText(), 'utf8').digest('hex'));
  assert.equal(validation.status, 'passed');
  assert.equal(validation.issueCount, 0);
  assert.deepEqual(validation.issues, []);
  assert.deepEqual(validation.checks, {
    envelopePathTrusted: 'passed',
    promptPathTrusted: 'passed',
    promptSha256MatchesText: 'passed',
    envelopeFileExists: 'passed',
    envelopeSha256MatchesReport: 'passed',
    operatorMatchesEnvelope: 'passed',
    promptTextMatchesCanonicalContract: 'passed',
    promptFileExists: 'passed',
    promptFileMatchesReport: 'passed',
    promptFileSha256MatchesReport: 'passed',
  });
});

test('validateMissionControlPromptReportFile fails closed on an embedded envelope path outside the repo root', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-envelope-path-untrusted-');
  const externalDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-envelope-untrusted-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    fs.rmSync(externalDir, { recursive: true, force: true });
  });

  const { reportPath, report } = await writeCanonicalRenderArtifacts(tmpDir);
  const externalEnvelopePath = path.join(externalDir, 'mission-control-envelope.json');
  fs.copyFileSync(report.envelopePath, externalEnvelopePath);
  report.envelopePath = externalEnvelopePath;
  writeJson(reportPath, report);

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, ['envelope-path-untrusted']);
  assert.equal(validation.checks.envelopePathTrusted, 'failed');
  assert.equal(validation.checks.envelopeFileExists, 'skipped');
  assert.equal(validation.checks.envelopeSha256MatchesReport, 'skipped');
  assert.equal(validation.checks.operatorMatchesEnvelope, 'skipped');
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'skipped');
  assert.match(validation.envelopeError ?? '', /Embedded envelope/);
});

test('validateMissionControlPromptReportFile fails closed on an embedded prompt path outside the artifact root', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-prompt-path-untrusted-');
  const externalDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-untrusted-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    fs.rmSync(externalDir, { recursive: true, force: true });
  });

  const { reportPath, report } = await writeCanonicalRenderArtifacts(tmpDir);
  const externalPromptPath = path.join(externalDir, 'mission-control-prompt.txt');
  fs.writeFileSync(externalPromptPath, report.promptText, 'utf8');
  report.promptPath = externalPromptPath;
  writeJson(reportPath, report);

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, ['prompt-path-untrusted']);
  assert.equal(validation.checks.promptPathTrusted, 'failed');
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'skipped');
  assert.equal(validation.checks.promptFileExists, 'skipped');
  assert.equal(validation.checks.promptFileMatchesReport, 'skipped');
  assert.equal(validation.checks.promptFileSha256MatchesReport, 'skipped');
  assert.match(validation.promptError ?? '', /Embedded prompt/);
});

test('validateMissionControlPromptReportFile fails closed on operator directive drift', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-operator-drift-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const { reportPath, report } = await writeCanonicalRenderArtifacts(tmpDir);
  report.operator.focus = 'release-burn-in';
  writeJson(reportPath, report);

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, ['operator-envelope-mismatch']);
  assert.equal(validation.checks.promptSha256MatchesText, 'passed');
  assert.equal(validation.checks.envelopeSha256MatchesReport, 'passed');
  assert.equal(validation.checks.operatorMatchesEnvelope, 'failed');
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'passed');
  assert.equal(validation.checks.promptFileMatchesReport, 'passed');
});

test('validateMissionControlPromptReportFile fails closed on prompt report EOF whitespace drift', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-body-drift-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const { reportPath, report, promptPath } = await writeCanonicalRenderArtifacts(tmpDir);
  const driftedPromptText = `${report.promptText}\n`;
  report.promptText = driftedPromptText;
  report.promptSha256 = createHash('sha256').update(driftedPromptText, 'utf8').digest('hex');
  fs.writeFileSync(promptPath, driftedPromptText, 'utf8');
  writeJson(reportPath, report);

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, ['prompt-canonical-contract-drift']);
  assert.equal(validation.checks.promptSha256MatchesText, 'passed');
  assert.equal(validation.checks.envelopeSha256MatchesReport, 'passed');
  assert.equal(validation.checks.operatorMatchesEnvelope, 'passed');
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'failed');
  assert.equal(validation.checks.promptFileMatchesReport, 'passed');
  assert.equal(validation.checks.promptFileSha256MatchesReport, 'passed');
});

test('validateMissionControlPromptReportFile fails closed when the source envelope changed after render', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-envelope-drift-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const { reportPath, report } = await writeCanonicalRenderArtifacts(tmpDir);
  const envelope = readJson(report.envelopePath);
  envelope.operator.focus = 'queue-health';
  writeJson(report.envelopePath, envelope);

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, [
    'envelope-sha256-mismatch',
    'operator-envelope-mismatch',
    'prompt-canonical-contract-drift',
  ]);
  assert.equal(validation.checks.envelopeFileExists, 'passed');
  assert.equal(validation.checks.envelopeSha256MatchesReport, 'failed');
  assert.equal(validation.checks.operatorMatchesEnvelope, 'failed');
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'failed');
});

test('validateMissionControlPromptReportFile fails closed on a missing envelope artifact without downstream noise', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-missing-envelope-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const { reportPath, report } = await writeCanonicalRenderArtifacts(tmpDir);
  fs.rmSync(report.envelopePath, { force: true });

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, ['envelope-file-missing']);
  assert.equal(validation.checks.envelopeFileExists, 'failed');
  assert.equal(validation.checks.envelopeSha256MatchesReport, 'skipped');
  assert.equal(validation.checks.operatorMatchesEnvelope, 'skipped');
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'skipped');
});

test('validateMissionControlPromptReportFile fails closed on prompt-file evidence mismatch', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-file-drift-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const { reportPath, report, promptPath } = await writeCanonicalRenderArtifacts(tmpDir);
  fs.writeFileSync(promptPath, `${report.promptText}\n# drift\n`, 'utf8');

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, [
    'prompt-file-content-mismatch',
    'prompt-file-sha256-mismatch',
  ]);
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'passed');
  assert.equal(validation.checks.promptFileExists, 'passed');
  assert.equal(validation.checks.promptFileMatchesReport, 'failed');
  assert.equal(validation.checks.promptFileSha256MatchesReport, 'failed');
});

test('validateMissionControlPromptReportFile fails closed on a missing prompt artifact without downstream noise', async (t) => {
  const { validateMissionControlPromptReportFile } = await loadValidatorModule();
  const tmpDir = createRepoArtifactSandbox('validate-missing-prompt-');
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const { reportPath, report, promptPath } = await writeCanonicalRenderArtifacts(tmpDir);
  fs.rmSync(promptPath, { force: true });

  const validation = validateMissionControlPromptReportFile(reportPath, { repoRoot, cwd: tmpDir, source: 'explicit' });
  assert.equal(validation.status, 'failed');
  assert.deepEqual(validation.issues, ['prompt-file-missing']);
  assert.equal(validation.checks.promptTextMatchesCanonicalContract, 'passed');
  assert.equal(validation.checks.promptFileExists, 'failed');
  assert.equal(validation.checks.promptFileMatchesReport, 'skipped');
  assert.equal(validation.checks.promptFileSha256MatchesReport, 'skipped');
});

test('validate mission-control prompt CLI writes a deterministic validation report', async (t) => {
  const renderModule = await loadRenderModule();
  const validatorModule = await loadValidatorModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-validate-cli-'));
  const nestedCwd = path.join(tmpDir, 'nested', 'cwd');
  const artifactRoot = path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'mission-control',
  );
  fs.mkdirSync(artifactRoot, { recursive: true });
  const renderOutputDir = fs.mkdtempSync(path.join(artifactRoot, 'validate-cli-render-'));
  const validationOutputDir = fs.mkdtempSync(path.join(artifactRoot, 'validate-cli-output-'));
  fs.mkdirSync(nestedCwd, { recursive: true });
  const previousCwd = process.cwd();
  t.after(() => {
    process.chdir(previousCwd);
    fs.rmSync(tmpDir, { recursive: true, force: true });
    fs.rmSync(renderOutputDir, { recursive: true, force: true });
    fs.rmSync(validationOutputDir, { recursive: true, force: true });
  });

  fs.mkdirSync(renderOutputDir, { recursive: true });
  const promptPath = path.join(renderOutputDir, 'mission-control-prompt.txt');
  const reportPath = path.join(renderOutputDir, 'mission-control-prompt-render.json');
  const renderExitCode = renderModule.main(
    [
      'node',
      renderModulePath,
      '--envelope',
      renderModule.FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
      '--prompt',
      promptPath,
      '--report',
      reportPath,
    ],
    {
      repoRoot,
      logFn() {},
      errorFn(message) {
        throw new Error(`render should not fail: ${message}`);
      },
    },
  );
  assert.equal(renderExitCode, 0);

  process.chdir(nestedCwd);

  const output = [];
  const errors = [];
  const validationPath = path.join(validationOutputDir, 'mission-control-prompt-validation.json');
  const relativeOutputPath = path.relative(nestedCwd, validationPath);
  const exitCode = validatorModule.main(
    [
      'node',
      validatorModulePath,
      '--report',
      path.relative(nestedCwd, reportPath),
      '--output',
      relativeOutputPath,
    ],
    {
      repoRoot,
      cwd: nestedCwd,
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

  const validation = JSON.parse(fs.readFileSync(validationPath, 'utf8'));
  assert.equal(validation.schema, validatorModule.MISSION_CONTROL_PROMPT_VALIDATION_SCHEMA);
  assert.equal(validation.promptReportPath, reportPath);
  assert.equal(validation.promptPath, promptPath);
  assert.equal(validation.status, 'passed');
});

test('validate mission-control prompt CLI rejects output paths outside the mission-control artifact root', async (t) => {
  const renderModule = await loadRenderModule();
  const validatorModule = await loadValidatorModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-prompt-validate-outside-root-'));
  const artifactRoot = path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'mission-control',
  );
  fs.mkdirSync(artifactRoot, { recursive: true });
  const renderOutputDir = fs.mkdtempSync(path.join(artifactRoot, 'validate-cli-outside-root-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    fs.rmSync(renderOutputDir, { recursive: true, force: true });
  });

  const promptPath = path.join(renderOutputDir, 'mission-control-prompt.txt');
  const reportPath = path.join(renderOutputDir, 'mission-control-prompt-render.json');
  const renderExitCode = renderModule.main(
    [
      'node',
      renderModulePath,
      '--envelope',
      renderModule.FIXTURE_MISSION_CONTROL_ENVELOPE_PATH,
      '--prompt',
      promptPath,
      '--report',
      reportPath,
    ],
    {
      repoRoot,
      logFn() {},
      errorFn(message) {
        throw new Error(`render should not fail: ${message}`);
      },
    },
  );
  assert.equal(renderExitCode, 0);

  const outputPath = path.join(tmpDir, 'mission-control-prompt-validation.json');
  const errors = [];
  const exitCode = validatorModule.main(
    [
      'node',
      validatorModulePath,
      '--report',
      reportPath,
      '--output',
      outputPath,
    ],
    {
      repoRoot,
      cwd: repoRoot,
      logFn() {},
      errorFn(message) {
        errors.push(message);
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.match(errors[0], /Prompt validation report path must stay inside the repository root|Prompt validation report path must stay under/);
  assert.equal(fs.existsSync(outputPath), false);
});

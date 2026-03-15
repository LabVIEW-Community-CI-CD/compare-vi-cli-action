import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'validate-mission-control-operator-input.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function createRepoRelativeTempReportPath(t, prefix, fileName = 'operator-input.json') {
  const reportsRoot = path.join(repoRoot, 'tests', 'results', '_agent', 'tmp');
  fs.mkdirSync(reportsRoot, { recursive: true });
  const tempDir = fs.mkdtempSync(path.join(reportsRoot, `${prefix}-`));
  const reportPath = path.join(tempDir, fileName);
  t.after(() => {
    fs.rmSync(tempDir, { recursive: true, force: true });
  });
  return {
    tempDir,
    reportPath,
    relativeReportPath: path.relative(repoRoot, reportPath).replace(/\\/g, '/'),
  };
}

test('validateMissionControlOperatorInputReport passes canonical bounded operator input', async () => {
  const { validateMissionControlOperatorInputReport, MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
      overrides: ['copilotCliUsage=required'],
      standingIssue: '1239',
    },
    {
      now: '2026-03-15T01:30:00.000Z',
      repoRoot,
    },
  );

  assert.equal(report.schema, MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA);
  assert.equal(report.generatedAt, '2026-03-15T01:30:00.000Z');
  assert.equal(report.status, 'passed');
  assert.equal(report.issueCount, 0);
  assert.equal(report.catalogPath, 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
  assert.deepEqual(report.issues, []);
  assert.deepEqual(report.operator.overrides, [{ key: 'copilotCliUsage', value: 'required' }]);
  assert.deepEqual(report.checks, {
    intentDefined: 'passed',
    focusDefined: 'passed',
    focusAllowedForIntent: 'passed',
    overrideSyntaxValid: 'passed',
    overridesKnown: 'passed',
    overrideValuesValid: 'passed',
    overrideKeysUnique: 'passed',
    standingIssueArgumentProvided: 'passed',
    standingIssueValueValid: 'passed',
    standingPrioritySatisfied: 'passed',
  });
});

test('validateMissionControlOperatorInputReport downgrades predictably when standing priority is required but missing', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'finish-live-standing-lane',
      focus: 'standing-priority',
      standingIssue: 'none',
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'downgraded');
  assert.deepEqual(report.issues, ['standing-priority-missing']);
  assert.equal(report.standingIssue.required, true);
  assert.equal(report.standingIssue.number, null);
  assert.equal(report.checks.standingIssueArgumentProvided, 'passed');
  assert.equal(report.checks.standingPrioritySatisfied, 'downgraded');
});

test('validateMissionControlOperatorInputReport fails closed when required standing issue context is omitted entirely', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['standing-issue-omitted']);
  assert.equal(report.standingIssue.status, 'omitted');
  assert.equal(report.checks.standingIssueArgumentProvided, 'failed');
  assert.equal(report.checks.standingPrioritySatisfied, 'skipped');
});

test('validateMissionControlOperatorInputReport treats blank standing issue values as omitted for required focuses', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
      standingIssue: '   ',
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['standing-issue-omitted']);
  assert.equal(report.standingIssue.status, 'omitted');
  assert.equal(report.checks.standingIssueArgumentProvided, 'failed');
  assert.equal(report.checks.standingPrioritySatisfied, 'skipped');
});

test('validateMissionControlOperatorInputReport fails closed for illegal intent and focus combinations', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'restore-intake',
      focus: 'standing-priority',
      standingIssue: 'none',
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['illegal-intent-focus-combination', 'standing-priority-missing']);
  assert.equal(report.checks.focusAllowedForIntent, 'failed');
});

test('validateMissionControlOperatorInputReport fails closed for unknown override keys, duplicate keys, and bad override values', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      overrides: [
        'copilotCliUsage=always',
        'allowAdminMerge=true',
        'allowAdminMerge=false',
        'allowFourthLane=true',
      ],
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, [
    'unknown-override-key',
    'override-value-invalid',
    'duplicate-override-key',
  ]);
  assert.equal(report.checks.overrideSyntaxValid, 'passed');
  assert.equal(report.checks.overridesKnown, 'failed');
  assert.equal(report.checks.overrideValuesValid, 'failed');
  assert.equal(report.checks.overrideKeysUnique, 'failed');
});

test('validateMissionControlOperatorInputReport emits structured failures for malformed override and standing issue values', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'prepare-parked-lane',
      focus: 'standing-priority',
      overrides: ['allowParkedLane'],
      standingIssue: 'abc',
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['malformed-override', 'malformed-standing-issue', 'standing-priority-missing']);
  assert.equal(report.checks.overrideSyntaxValid, 'failed');
  assert.equal(report.checks.standingIssueArgumentProvided, 'passed');
  assert.equal(report.checks.standingIssueValueValid, 'failed');
  assert.equal(report.checks.standingPrioritySatisfied, 'downgraded');
});

test('validateMissionControlOperatorInputReport canonicalizes equivalent catalog path spellings', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      catalogPath: 'tools\\priority\\__fixtures__\\mission-control\\operator-input-catalog.json',
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'passed');
  assert.equal(report.catalogPath, 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json');
});

test('validateMissionControlOperatorInputReport rejects catalog paths that do not resolve to the canonical checked-in catalog', async (t) => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const copiedCatalog = createRepoRelativeTempReportPath(t, 'mission-control-operator-input-programmatic-catalog', 'operator-input-catalog.json');
  fs.copyFileSync(
    path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'mission-control', 'operator-input-catalog.json'),
    copiedCatalog.reportPath,
  );

  assert.throws(
    () => validateMissionControlOperatorInputReport(
      {
        intent: 'prepare-parked-lane',
        focus: 'queue-health',
        catalogPath: copiedCatalog.relativeReportPath,
      },
      {
        repoRoot,
      },
    ),
    /Mission-control operator input catalog path must stay under tools[\\/]+priority[\\/]+__fixtures__[\\/]+mission-control/i,
  );
});

test('validateMissionControlOperatorInputReport treats blank override tokens as malformed override issues', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      overrides: ['   '],
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['malformed-override']);
  assert.equal(report.checks.overrideSyntaxValid, 'failed');
});

test('validateMissionControlOperatorInputReport rejects invalid numeric standing issue values', async () => {
  const { validateMissionControlOperatorInputReport } = await loadModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
      standingIssue: 0,
    },
    {
      repoRoot,
    },
  );

  assert.equal(report.status, 'failed');
  assert.deepEqual(report.issues, ['malformed-standing-issue', 'standing-priority-missing']);
  assert.equal(report.standingIssue.number, null);
  assert.equal(report.checks.standingIssueArgumentProvided, 'passed');
  assert.equal(report.checks.standingIssueValueValid, 'failed');
  assert.equal(report.checks.standingPrioritySatisfied, 'downgraded');
});

test('validate mission-control operator-input CLI writes a deterministic report and preserves downgraded status without failing', async (t) => {
  const { main, parseArgs, MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-operator-input-'));
  const reports = createRepoRelativeTempReportPath(t, 'mission-control-operator-input-report');
  const previousCwd = process.cwd();
  const nestedCwd = path.join(tmpDir, 'nested');
  fs.mkdirSync(nestedCwd, { recursive: true });
  t.after(() => {
    process.chdir(previousCwd);
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const parsed = parseArgs([
    'node',
    modulePath,
    '--intent',
    'prepare-parked-lane',
    '--focus',
    'queue-health',
    '--override',
    'copilotCliUsage=optional',
    '--report',
    reports.relativeReportPath.replace(/\//g, '\\'),
  ]);
  assert.deepEqual(parsed.overrides, ['copilotCliUsage=optional']);

  process.chdir(nestedCwd);
  const output = [];
  const errors = [];
  const exitCode = main(
    [
      'node',
      modulePath,
      '--intent',
      'prepare-parked-lane',
      '--focus',
      'queue-health',
      '--override',
      'copilotCliUsage=optional',
      '--report',
      reports.relativeReportPath.replace(/\//g, '\\'),
    ],
    {
      repoRoot,
      now: '2026-03-15T01:31:00.000Z',
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

  const report = JSON.parse(fs.readFileSync(reports.reportPath, 'utf8'));
  assert.equal(report.schema, MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA);
  assert.equal(report.generatedAt, '2026-03-15T01:31:00.000Z');
  assert.equal(report.status, 'passed');

  const downgradeErrors = [];
  const downgradeReportPath = path.join(reports.tempDir, 'operator-input-downgrade.json');
  const downgradeExitCode = main(
    [
      'node',
      modulePath,
      '--intent',
      'finish-live-standing-lane',
      '--focus',
      'standing-priority',
      '--standing-issue',
      'none',
      '--report',
      path.relative(repoRoot, downgradeReportPath).replace(/\\/g, '/'),
    ],
    {
      repoRoot,
      logFn() {},
      errorFn(message) {
        downgradeErrors.push(message);
      },
    },
  );
  assert.equal(downgradeExitCode, 0);
  assert.deepEqual(downgradeErrors, []);
  const downgradeReport = JSON.parse(fs.readFileSync(downgradeReportPath, 'utf8'));
  assert.equal(downgradeReport.status, 'downgraded');
});

test('validate mission-control operator-input CLI rejects catalog paths that are absolute, drive-qualified, or escape the repo root', async () => {
  const { main } = await loadModule();
  const absoluteCatalogPath = path.join(
    repoRoot,
    'tools',
    'priority',
    '__fixtures__',
    'mission-control',
    'operator-input-catalog.json',
  );

  for (const catalogPath of [absoluteCatalogPath, 'C:operator-input-catalog.json', '../operator-input-catalog.json']) {
    const errors = [];
    const exitCode = main(
      [
        'node',
        modulePath,
        '--intent',
        'prepare-parked-lane',
        '--focus',
        'queue-health',
        '--catalog',
        catalogPath,
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
    assert.equal(errors.length, 1);
    assert.match(errors[0], /catalog path .*repository root|catalog path .*repo-relative/i);
  }
});

test('validate mission-control operator-input CLI rejects repo-relative catalog overrides that do not resolve to the canonical catalog', async (t) => {
  const { main } = await loadModule();
  const copiedCatalog = createRepoRelativeTempReportPath(t, 'mission-control-operator-input-catalog', 'operator-input-catalog.json');
  fs.copyFileSync(
    path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'mission-control', 'operator-input-catalog.json'),
    copiedCatalog.reportPath,
  );

  const errors = [];
  const exitCode = main(
    [
      'node',
      modulePath,
      '--intent',
      'prepare-parked-lane',
      '--focus',
      'queue-health',
      '--catalog',
      copiedCatalog.relativeReportPath,
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
  assert.equal(errors.length, 1);
  assert.match(
    errors[0],
    /Mission-control operator input catalog path must stay under tools[\\/]+priority[\\/]+__fixtures__[\\/]+mission-control/i,
  );
});

test('parseArgs rejects duplicate singleton options so ambiguous operator input fails closed', async () => {
  const { parseArgs } = await loadModule();

  assert.throws(
    () => parseArgs([
      'node',
      modulePath,
      '--intent',
      'prepare-parked-lane',
      '--intent',
      'continue-driving-autonomously',
      '--focus',
      'queue-health',
    ]),
    /Duplicate option is not allowed: --intent\./,
  );

  assert.throws(
    () => parseArgs([
      'node',
      modulePath,
      '--intent',
      'prepare-parked-lane',
      '--focus',
      'queue-health',
      '--report',
      'tests/results/_agent/tmp/one.json',
      '--report',
      'tests/results/_agent/tmp/two.json',
    ]),
    /Duplicate option is not allowed: --report\./,
  );
});

test('validate mission-control operator-input CLI rejects report paths that are absolute, drive-qualified, or escape the repo root', async (t) => {
  const { main } = await loadModule();
  const absoluteReportPath = path.join(os.tmpdir(), `mission-control-operator-input-absolute-${process.pid}.json`);
  const driveQualifiedReportPath = 'C:mission-control-operator-input-drive-relative.json';
  const escapedReportPath = `../mission-control-operator-input-escape-${process.pid}.json`;
  const repoRelativeNonArtifactReportPath = 'docs/mission-control-operator-input-report.json';
  const escapedResolvedReportPath = path.resolve(repoRoot, escapedReportPath);
  const repoRelativeNonArtifactResolvedPath = path.resolve(repoRoot, repoRelativeNonArtifactReportPath);
  t.after(() => {
    fs.rmSync(absoluteReportPath, { force: true });
    fs.rmSync(escapedResolvedReportPath, { force: true });
    fs.rmSync(repoRelativeNonArtifactResolvedPath, { force: true });
  });

  for (const reportPath of [absoluteReportPath, driveQualifiedReportPath, escapedReportPath, repoRelativeNonArtifactReportPath]) {
    const errors = [];
    const exitCode = main(
      [
        'node',
        modulePath,
        '--intent',
        'prepare-parked-lane',
        '--focus',
        'queue-health',
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
    assert.equal(errors.length, 1);
    assert.match(
      errors[0],
      /validation report path .*repository root|validation report path .*repo-relative|validation report path .*tests[\\/]+results[\\/]+_agent/i,
    );
  }

  assert.equal(fs.existsSync(absoluteReportPath), false);
  assert.equal(fs.existsSync(escapedResolvedReportPath), false);
  assert.equal(fs.existsSync(repoRelativeNonArtifactResolvedPath), false);
});

test('validate mission-control operator-input CLI resolves default paths from the module repo root', async (t) => {
  const { main } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mission-control-operator-input-nested-'));
  const previousCwd = process.cwd();
  const nestedCwd = path.join(tmpDir, 'nested', 'cwd');
  fs.mkdirSync(nestedCwd, { recursive: true });
  t.after(() => {
    process.chdir(previousCwd);
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const reportPath = path.join(repoRoot, 'tests', 'results', '_agent', 'mission-control', 'mission-control-operator-input-validation.json');
  fs.rmSync(reportPath, { force: true });
  process.chdir(nestedCwd);

  const exitCode = main(
    [
      'node',
      modulePath,
      '--intent',
      'prepare-parked-lane',
      '--focus',
      'queue-health',
    ],
    {
      now: '2026-03-15T01:32:00.000Z',
      logFn() {},
      errorFn(message) {
        throw new Error(`nested cwd validation should not fail: ${message}`);
      },
    },
  );

  assert.equal(exitCode, 0);
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.generatedAt, '2026-03-15T01:32:00.000Z');
  assert.equal(report.status, 'passed');
  fs.rmSync(reportPath, { force: true });
});

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import fs from 'node:fs';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');
const MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA = 'priority/mission-control-operator-input-validation@v1';
const validatorModulePath = path.join(repoRoot, 'tools', 'priority', 'validate-mission-control-operator-input.mjs');

let validatorModulePromise = null;

function loadText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function loadJson(relativePath) {
  return JSON.parse(loadText(relativePath));
}

function compileValidator() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv.compile(loadJson('docs/schemas/mission-control-operator-input-validation-v1.schema.json'));
}

async function loadValidatorModule() {
  if (!validatorModulePromise) {
    validatorModulePromise = import(`${pathToFileURL(validatorModulePath).href}?cache=${Date.now()}`);
  }
  return validatorModulePromise;
}

test('mission-control operator input validation reports match schema across passed, downgraded, and failed outcomes', () => {
  const validate = compileValidator();
  const baseReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T02:20:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: true,
      number: 1241,
      status: 'present'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 0,
    issues: [],
    status: 'passed'
  };

  const passed = structuredClone(baseReport);
  const downgraded = {
    ...structuredClone(baseReport),
    operator: {
      intent: 'finish-live-standing-lane',
      focus: 'standing-priority',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: true,
      number: null,
      status: 'missing'
    },
    checks: {
      ...baseReport.checks,
      standingPrioritySatisfied: 'downgraded'
    },
    issueCount: 1,
    issues: ['standing-priority-missing'],
    status: 'downgraded'
  };
  const failed = {
    ...structuredClone(baseReport),
    standingIssue: {
      required: true,
      number: null,
      status: 'omitted'
    },
    checks: {
      ...baseReport.checks,
      standingIssueArgumentProvided: 'failed',
      standingPrioritySatisfied: 'skipped'
    },
    issueCount: 1,
    issues: ['standing-issue-omitted'],
    status: 'failed'
  };

  for (const report of [passed, downgraded, failed]) {
    assert.equal(report.schema, MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA);
    assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  }

  assert.equal(passed.status, 'passed');
  assert.deepEqual(passed.issues, []);
  assert.equal(downgraded.status, 'downgraded');
  assert.deepEqual(downgraded.issues, ['standing-priority-missing']);
  assert.equal(failed.status, 'failed');
  assert.deepEqual(failed.issues, ['standing-issue-omitted']);
});

test('mission-control operator input validation schema rejects contradictory failed reports whose checks remain passed', () => {
  const validate = compileValidator();
  const contradictoryFailedReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T02:20:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: true,
      number: 1243,
      status: 'present'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 1,
    issues: ['unknown-intent'],
    status: 'failed'
  };

  assert.equal(validate(contradictoryFailedReport), false);
});

test('mission-control operator input validation schema accepts real reports emitted by the validator surface', async () => {
  const validate = compileValidator();
  const { validateMissionControlOperatorInputReport } = await loadValidatorModule();
  const reports = [
    validateMissionControlOperatorInputReport(
      {
        intent: 'continue-driving-autonomously',
        focus: 'standing-priority',
        overrides: ['copilotCliUsage=required'],
        standingIssue: '1243'
      },
      { repoRoot, now: '2026-03-15T03:08:00.000Z' }
    ),
    validateMissionControlOperatorInputReport(
      {
        intent: 'finish-live-standing-lane',
        focus: 'standing-priority',
        standingIssue: 'none'
      },
      { repoRoot, now: '2026-03-15T03:08:00.000Z' }
    ),
    validateMissionControlOperatorInputReport(
      {
        intent: 'prepare-parked-lane',
        focus: 'queue-health',
        overrides: ['allowAdminMerge=true', 'allowAdminMerge=false', 'allowFourthLane=true']
      },
      { repoRoot, now: '2026-03-15T03:08:00.000Z' }
    ),
    validateMissionControlOperatorInputReport(
      {
        intent: 'prepare-parked-lane',
        focus: 'standing-priority',
        overrides: ['allowParkedLane'],
        standingIssue: 'abc'
      },
      { repoRoot, now: '2026-03-15T03:08:00.000Z' }
    ),
    validateMissionControlOperatorInputReport(
      {
        intent: 'continue-driving-autonomously',
        focus: 'bogus-focus',
        standingIssue: '1243'
      },
      { repoRoot, now: '2026-03-15T03:08:00.000Z' }
    )
  ];

  for (const report of reports) {
    assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  }
});

test('mission-control operator input validation schema accepts representative unknown and malformed operator payload failures', () => {
  const validate = compileValidator();
  const reports = [
    {
      schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
      generatedAt: '2026-03-15T02:46:00.000Z',
      catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
      operator: {
        intent: 'bogus-intent',
        focus: 'standing-priority',
        overrides: [],
        duplicateOverrideKeys: []
      },
      standingIssue: {
        required: true,
        number: 1243,
        status: 'present'
      },
      checks: {
        intentDefined: 'failed',
        focusDefined: 'passed',
        focusAllowedForIntent: 'skipped',
        overrideSyntaxValid: 'passed',
        overridesKnown: 'passed',
        overrideValuesValid: 'passed',
        overrideKeysUnique: 'passed',
        standingIssueArgumentProvided: 'passed',
        standingIssueValueValid: 'passed',
        standingPrioritySatisfied: 'passed'
      },
      issueCount: 1,
      issues: ['unknown-intent'],
      status: 'failed'
    },
    {
      schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
      generatedAt: '2026-03-15T02:46:00.000Z',
      catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
      operator: {
        intent: 'continue-driving-autonomously',
        focus: 'bogus-focus',
        overrides: [],
        duplicateOverrideKeys: []
      },
      standingIssue: {
        required: false,
        number: null,
        status: 'not-required'
      },
      checks: {
        intentDefined: 'passed',
        focusDefined: 'failed',
        focusAllowedForIntent: 'skipped',
        overrideSyntaxValid: 'passed',
        overridesKnown: 'passed',
        overrideValuesValid: 'passed',
        overrideKeysUnique: 'passed',
        standingIssueArgumentProvided: 'skipped',
        standingIssueValueValid: 'passed',
        standingPrioritySatisfied: 'skipped'
      },
      issueCount: 1,
      issues: ['unknown-focus'],
      status: 'failed'
    },
    {
      schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
      generatedAt: '2026-03-15T02:46:00.000Z',
      catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
      operator: {
        intent: 'prepare-parked-lane',
        focus: 'queue-health',
        overrides: [{ key: 'allowFourthLane', value: 'true' }],
        duplicateOverrideKeys: []
      },
      standingIssue: {
        required: false,
        number: null,
        status: 'not-required'
      },
      checks: {
        intentDefined: 'passed',
        focusDefined: 'passed',
        focusAllowedForIntent: 'passed',
        overrideSyntaxValid: 'passed',
        overridesKnown: 'failed',
        overrideValuesValid: 'passed',
        overrideKeysUnique: 'passed',
        standingIssueArgumentProvided: 'passed',
        standingIssueValueValid: 'passed',
        standingPrioritySatisfied: 'passed'
      },
      issueCount: 1,
      issues: ['unknown-override-key'],
      status: 'failed'
    },
    {
      schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
      generatedAt: '2026-03-15T02:45:00.000Z',
      catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
      operator: {
        intent: 'prepare-parked-lane',
        focus: 'queue-health',
        overrides: [{ key: '   ', value: null }],
        duplicateOverrideKeys: []
      },
      standingIssue: {
        required: false,
        number: null,
        status: 'not-required'
      },
      checks: {
        intentDefined: 'passed',
        focusDefined: 'passed',
        focusAllowedForIntent: 'passed',
        overrideSyntaxValid: 'failed',
        overridesKnown: 'passed',
        overrideValuesValid: 'passed',
        overrideKeysUnique: 'passed',
        standingIssueArgumentProvided: 'passed',
        standingIssueValueValid: 'passed',
        standingPrioritySatisfied: 'passed'
      },
      issueCount: 1,
      issues: ['malformed-override'],
      status: 'failed'
    },
    {
      schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
      generatedAt: '2026-03-15T02:46:00.000Z',
      catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
      operator: {
        intent: 'prepare-parked-lane',
        focus: 'queue-health',
        overrides: [{ key: 'copilotCliUsage', value: 'always' }],
        duplicateOverrideKeys: []
      },
      standingIssue: {
        required: false,
        number: null,
        status: 'not-required'
      },
      checks: {
        intentDefined: 'passed',
        focusDefined: 'passed',
        focusAllowedForIntent: 'passed',
        overrideSyntaxValid: 'passed',
        overridesKnown: 'passed',
        overrideValuesValid: 'failed',
        overrideKeysUnique: 'passed',
        standingIssueArgumentProvided: 'passed',
        standingIssueValueValid: 'passed',
        standingPrioritySatisfied: 'passed'
      },
      issueCount: 1,
      issues: ['override-value-invalid'],
      status: 'failed'
    }
  ];

  for (const report of reports) {
    assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  }
});

test('mission-control operator input validation schema rejects passed reports that omit a standing issue for required focuses', () => {
  const validate = compileValidator();
  const contradictoryPassedReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T02:47:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'finish-live-standing-lane',
      focus: 'current-head-failure',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: false,
      number: null,
      status: 'not-required'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 0,
    issues: [],
    status: 'passed'
  };

  assert.equal(validate(contradictoryPassedReport), false);
});

test('mission-control operator input validation schema rejects illegal-combination failures for intent and focus pairs that are actually allowed', () => {
  const validate = compileValidator();
  const contradictoryIllegalPairReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T02:48:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'prepare-parked-lane',
      focus: 'standing-priority',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: true,
      number: 1243,
      status: 'present'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'failed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 1,
    issues: ['illegal-intent-focus-combination'],
    status: 'failed'
  };

  assert.equal(validate(contradictoryIllegalPairReport), false);
});

test('mission-control operator input validation schema rejects illegal-combination failures when intent or focus is still unknown', () => {
  const validate = compileValidator();
  const contradictoryIllegalUnknownReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T03:28:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'bogus-intent',
      focus: 'standing-priority',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: true,
      number: 1243,
      status: 'present'
    },
    checks: {
      intentDefined: 'failed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'failed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 2,
    issues: ['unknown-intent', 'illegal-intent-focus-combination'],
    status: 'failed'
  };

  assert.equal(validate(contradictoryIllegalUnknownReport), false);
});

test('mission-control operator input validation schema rejects unknown lookup failures that keep dependent checks out of skipped state', () => {
  const validate = compileValidator();
  const contradictoryReports = [
    {
      schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
      generatedAt: '2026-03-15T03:03:00.000Z',
      catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
      operator: {
        intent: 'bogus-intent',
        focus: 'standing-priority',
        overrides: [],
        duplicateOverrideKeys: []
      },
      standingIssue: {
        required: true,
        number: 1243,
        status: 'present'
      },
      checks: {
        intentDefined: 'failed',
        focusDefined: 'passed',
        focusAllowedForIntent: 'passed',
        overrideSyntaxValid: 'passed',
        overridesKnown: 'passed',
        overrideValuesValid: 'passed',
        overrideKeysUnique: 'passed',
        standingIssueArgumentProvided: 'passed',
        standingIssueValueValid: 'passed',
        standingPrioritySatisfied: 'passed'
      },
      issueCount: 1,
      issues: ['unknown-intent'],
      status: 'failed'
    },
    {
      schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
      generatedAt: '2026-03-15T03:03:00.000Z',
      catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
      operator: {
        intent: 'continue-driving-autonomously',
        focus: 'bogus-focus',
        overrides: [],
        duplicateOverrideKeys: []
      },
      standingIssue: {
        required: false,
        number: null,
        status: 'not-required'
      },
      checks: {
        intentDefined: 'passed',
        focusDefined: 'failed',
        focusAllowedForIntent: 'passed',
        overrideSyntaxValid: 'passed',
        overridesKnown: 'passed',
        overrideValuesValid: 'passed',
        overrideKeysUnique: 'passed',
        standingIssueArgumentProvided: 'passed',
        standingIssueValueValid: 'passed',
        standingPrioritySatisfied: 'passed'
      },
      issueCount: 1,
      issues: ['unknown-focus'],
      status: 'failed'
    }
  ];

  for (const report of contradictoryReports) {
    assert.equal(validate(report), false);
  }
});

test('mission-control operator input validation schema rejects stray failed derived checks without matching issue codes', () => {
  const validate = compileValidator();
  const contradictoryDerivedCheckReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T03:06:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: false,
      number: null,
      status: 'not-required'
    },
    checks: {
      intentDefined: 'failed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 1,
    issues: ['malformed-override'],
    status: 'failed'
  };

  assert.equal(validate(contradictoryDerivedCheckReport), false);
});

test('mission-control operator input validation schema rejects impossible check status values', () => {
  const validate = compileValidator();
  const impossibleCheckStateReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T03:09:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: false,
      number: null,
      status: 'not-required'
    },
    checks: {
      intentDefined: 'skipped',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'downgraded',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 0,
    issues: [],
    status: 'passed'
  };

  assert.equal(validate(impossibleCheckStateReport), false);
});

test('mission-control operator input validation schema rejects skipped derived checks on known intent and focus paths', () => {
  const validate = compileValidator();
  const contradictorySkippedDerivedCheckReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T03:14:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      overrides: [{ key: 'allowFourthLane', value: 'true' }],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: false,
      number: null,
      status: 'not-required'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'skipped',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'failed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'skipped',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'skipped'
    },
    issueCount: 1,
    issues: ['unknown-override-key'],
    status: 'failed'
  };

  assert.equal(validate(contradictorySkippedDerivedCheckReport), false);
});

test('mission-control operator input validation schema rejects missing-standing-issue downgrades that omit the standing-priority-missing issue', () => {
  const validate = compileValidator();
  const contradictoryMissingStandingIssueReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T03:01:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: true,
      number: null,
      status: 'missing'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'downgraded'
    },
    issueCount: 0,
    issues: [],
    status: 'failed'
  };

  assert.equal(validate(contradictoryMissingStandingIssueReport), false);
});

test('mission-control operator input validation schema rejects standing-issue reports that are both omitted and malformed', () => {
  const validate = compileValidator();
  const contradictoryStandingIssueReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T03:17:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'continue-driving-autonomously',
      focus: 'standing-priority',
      overrides: [],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: true,
      number: null,
      status: 'omitted'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'passed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'failed',
      standingIssueValueValid: 'failed',
      standingPrioritySatisfied: 'skipped'
    },
    issueCount: 2,
    issues: ['standing-issue-omitted', 'malformed-standing-issue'],
    status: 'failed'
  };

  assert.equal(validate(contradictoryStandingIssueReport), false);
});

test('mission-control operator input validation schema rejects override arrays that underreport mixed override failures', () => {
  const validate = compileValidator();
  const contradictoryOverrideReport = {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    generatedAt: '2026-03-15T03:23:00.000Z',
    catalogPath: 'tools/priority/__fixtures__/mission-control/operator-input-catalog.json',
    operator: {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      overrides: [
        { key: '   ', value: null },
        { key: 'allowFourthLane', value: 'true' }
      ],
      duplicateOverrideKeys: []
    },
    standingIssue: {
      required: false,
      number: null,
      status: 'not-required'
    },
    checks: {
      intentDefined: 'passed',
      focusDefined: 'passed',
      focusAllowedForIntent: 'passed',
      overrideSyntaxValid: 'failed',
      overridesKnown: 'passed',
      overrideValuesValid: 'passed',
      overrideKeysUnique: 'passed',
      standingIssueArgumentProvided: 'passed',
      standingIssueValueValid: 'passed',
      standingPrioritySatisfied: 'passed'
    },
    issueCount: 1,
    issues: ['malformed-override'],
    status: 'failed'
  };

  assert.equal(validate(contradictoryOverrideReport), false);
});

test('mission-control operator input validation schema accepts malformed override items that preserve an empty raw token', async () => {
  const validate = compileValidator();
  const { validateMissionControlOperatorInputReport } = await loadValidatorModule();
  const report = validateMissionControlOperatorInputReport(
    {
      intent: 'prepare-parked-lane',
      focus: 'queue-health',
      overrides: ['']
    },
    {
      repoRoot,
      now: '2026-03-15T03:31:00.000Z'
    },
  );

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

test('mission-control docs manifest advertises the operator-input validation schema and validator surfaces', () => {
  const manifest = loadJson('docs/documentation-manifest.json');
  const missionControlEntry = manifest.entries.find((entry) => entry.name === 'Mission Control Contracts');

  assert.ok(missionControlEntry, 'Mission Control Contracts entry is missing from docs manifest.');
  assert.ok(missionControlEntry.files.includes('docs/schemas/mission-control-operator-input-validation-v1.schema.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/mission-control-operator-input-validation-schema.test.mjs'));
});

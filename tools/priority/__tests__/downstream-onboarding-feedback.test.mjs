import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_FEEDBACK_OUTPUT_PATH,
  DEFAULT_REPORT_PATH,
  DEFAULT_SUCCESS_OUTPUT_PATH,
  buildOnboardingArgv,
  buildFeedbackReport,
  parseArgs
} from '../downstream-onboarding-feedback.mjs';

test('parseArgs applies defaults for the onboarding feedback harness', () => {
  const defaults = parseArgs(['node', 'downstream-onboarding-feedback.mjs', '--repo', 'owner/downstream']);
  assert.equal(defaults.reportPath, DEFAULT_REPORT_PATH);
  assert.equal(defaults.successOutputPath, DEFAULT_SUCCESS_OUTPUT_PATH);
  assert.equal(defaults.feedbackOutputPath, DEFAULT_FEEDBACK_OUTPUT_PATH);
  assert.equal(defaults.createHardeningIssues, false);
  assert.equal(defaults.failOnGap, false);
  assert.equal(defaults.targetBranch, null);
});

test('buildOnboardingArgv passes the configured downstream branch through to the onboarding evaluator', () => {
  const argv = buildOnboardingArgv({
    downstreamRepo: 'owner/downstream',
    targetBranch: 'downstream/develop',
    startedAt: null,
    parentIssue: null,
    createHardeningIssues: false,
    failOnGap: false,
    reportPath: DEFAULT_REPORT_PATH
  });

  assert.deepEqual(argv, [
    'node',
    'downstream-onboarding.mjs',
    '--repo',
    'owner/downstream',
    '--output',
    DEFAULT_REPORT_PATH,
    '--branch',
    'downstream/develop'
  ]);
});

test('buildFeedbackReport captures deterministic output existence and exit codes', () => {
  const report = buildFeedbackReport({
    options: {
      downstreamRepo: 'owner/downstream',
      targetBranch: 'downstream/develop',
      startedAt: '2026-03-09T19:16:18Z',
      parentIssue: 715,
      createHardeningIssues: true,
      failOnGap: false,
      reportPath: 'tests/results/_agent/onboarding/downstream-onboarding.json',
      successOutputPath: 'tests/results/_agent/onboarding/downstream-onboarding-success.json'
    },
    evaluateExitCode: 1,
    successExitCode: 0,
    reportExists: true,
    successReportExists: true,
    generatedAt: '2026-03-09T19:20:00Z'
  });

  assert.equal(report.schema, 'priority/downstream-onboarding-feedback@v1');
  assert.equal(report.inputs.downstreamRepository, 'owner/downstream');
  assert.equal(report.inputs.targetBranchOverride, 'downstream/develop');
  assert.equal(report.outputs.onboardingReportExists, true);
  assert.equal(report.outputs.successReportExists, true);
  assert.equal(report.execution.evaluateExitCode, 1);
  assert.equal(report.execution.successExitCode, 0);
  assert.equal(report.execution.status, 'fail');
});

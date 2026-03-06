import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_OUTPUT_PATH,
  parseArgs,
  aggregateReports
} from '../downstream-onboarding-success.mjs';

test('parseArgs enforces report inputs and supports explicit options', () => {
  const parsed = parseArgs([
    'node',
    'downstream-onboarding-success.mjs',
    '--report',
    'report-a.json',
    '--report',
    'report-b.json',
    '--output',
    'custom-output.json',
    '--parent-issue',
    '715',
    '--create-hardening-issues',
    '--issue-repo',
    'owner/issues',
    '--issue-labels',
    'program,enhancement',
    '--issue-prefix',
    '[hardening]',
    '--fail-on-incomplete'
  ]);
  assert.deepEqual(parsed.reportPaths, ['report-a.json', 'report-b.json']);
  assert.equal(parsed.outputPath, 'custom-output.json');
  assert.equal(parsed.parentIssue, 715);
  assert.equal(parsed.createHardeningIssues, true);
  assert.equal(parsed.issueRepo, 'owner/issues');
  assert.deepEqual(parsed.issueLabels, ['program', 'enhancement']);
  assert.equal(parsed.issuePrefix, '[hardening]');
  assert.equal(parsed.failOnIncomplete, true);

  const defaults = parseArgs([
    'node',
    'downstream-onboarding-success.mjs',
    '--report',
    'report.json'
  ]);
  assert.equal(defaults.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(defaults.createHardeningIssues, false);
});

test('aggregateReports summarizes status, deltas, pain points, and backlog', () => {
  const reports = [
    {
      path: 'a.json',
      report: {
        downstreamRepository: 'owner/a',
        summary: { status: 'pass' },
        metrics: { onboardingLeadTimeHours: 2.5, frictionScore: 1, requiredFailures: 0, warningCount: 1 },
        checklist: [
          { id: 'one', status: 'pass', required: true },
          { id: 'two', status: 'warn', required: false }
        ],
        hardeningBacklog: [
          {
            key: 'required-checks-visible',
            title: 'Resolve required-checks-visible for owner/a',
            severity: 'P2',
            status: 'warn',
            reason: 'required-checks-missing',
            recommendation: 'align checks'
          }
        ]
      }
    },
    {
      path: 'b.json',
      report: {
        downstreamRepository: 'owner/b',
        summary: { status: 'fail' },
        metrics: { onboardingLeadTimeHours: 6, frictionScore: 5, requiredFailures: 2, warningCount: 1 },
        checklist: [
          { id: 'one', status: 'fail', required: true },
          { id: 'two', status: 'pass', required: false }
        ],
        hardeningBacklog: [
          {
            key: 'certified-reference-pinned',
            title: 'Resolve certified-reference-pinned for owner/b',
            severity: 'P1',
            status: 'fail',
            reason: 'no-certified-immutable-reference',
            recommendation: 'pin ref'
          },
          {
            key: 'required-checks-visible',
            title: 'Resolve required-checks-visible for owner/b',
            severity: 'P2',
            status: 'warn',
            reason: 'required-checks-missing',
            recommendation: 'align checks'
          }
        ]
      }
    }
  ];

  const aggregated = aggregateReports(reports);
  assert.equal(aggregated.summary.status, 'fail');
  assert.equal(aggregated.summary.repositoriesEvaluated, 2);
  assert.equal(aggregated.summary.repositoriesPassing, 1);
  assert.equal(aggregated.summary.repositoriesFailing, 1);
  assert.equal(aggregated.summary.averageLeadTimeHours, 4.25);
  assert.equal(aggregated.summary.totalBlockers, 2);
  assert.equal(aggregated.summary.totalWarnings, 2);

  assert.equal(aggregated.deltas.length, 2);
  assert.equal(aggregated.painPoints.length >= 2, true);
  assert.equal(aggregated.painPoints[0].key, 'required-checks-visible');
  assert.equal(aggregated.hardeningBacklog[0].severity, 'P1');
});

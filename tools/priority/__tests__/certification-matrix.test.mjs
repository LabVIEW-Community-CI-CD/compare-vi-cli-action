import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_POLICY_PATH,
  buildWorkflowRunsUrl,
  buildCertificationReport,
  evaluateGate,
  evaluateLane,
  normalizePolicy,
  parseArgs
} from '../certification-matrix.mjs';

test('parseArgs applies defaults and parses explicit values', () => {
  const defaults = parseArgs(['node', 'certification-matrix.mjs']);
  assert.equal(defaults.policyPath, DEFAULT_POLICY_PATH);
  assert.equal(defaults.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(defaults.enforceMode, 'stable');
  assert.equal(defaults.channel, null);
  assert.equal(defaults.maxRuns, 50);

  const parsed = parseArgs([
    'node',
    'certification-matrix.mjs',
    '--repo',
    'owner/repo',
    '--channel',
    'rc',
    '--enforce',
    'always',
    '--lookback-days',
    '10',
    '--max-runs',
    '20',
    '--policy',
    'custom-policy.json',
    '--output',
    'custom-output.json',
    '--branch',
    'main'
  ]);
  assert.equal(parsed.repo, 'owner/repo');
  assert.equal(parsed.channel, 'rc');
  assert.equal(parsed.enforceMode, 'always');
  assert.equal(parsed.lookbackDays, 10);
  assert.equal(parsed.maxRuns, 20);
  assert.equal(parsed.policyPath, 'custom-policy.json');
  assert.equal(parsed.outputPath, 'custom-output.json');
  assert.equal(parsed.branch, 'main');
});

test('normalizePolicy resolves defaults and lane metadata', () => {
  const policy = normalizePolicy({
    schema: 'certification-matrix-policy/v1',
    target_branch: 'develop',
    defaults: {
      lookback_days: 30,
      max_runs: 40,
      max_age_hours: 100
    },
    lanes: [
      {
        id: 'lane-a',
        workflow: 'fixture-drift.yml',
        job_name: 'Fixture Drift (Ubuntu)',
        branch: '*',
        event: 'pull_request',
        runner: 'ubuntu-latest',
        os: 'linux',
        image_tag: 'ni/linux:tag',
        scenario: 'example'
      },
      {
        id: 'lane-b',
        workflow: 'validate.yml',
        job_name: 'vi-history-scenarios-linux',
        required_for_stable: false,
        max_age_hours: 12
      }
    ]
  });

  assert.equal(policy.targetBranch, 'develop');
  assert.equal(policy.lookbackDays, 30);
  assert.equal(policy.maxRuns, 40);
  assert.equal(policy.lanes.length, 2);
  assert.equal(policy.lanes[0].maxAgeHours, 100);
  assert.equal(policy.lanes[0].runBranch, null);
  assert.equal(policy.lanes[0].event, 'pull_request');
  assert.equal(policy.lanes[1].requiredForStable, false);
  assert.equal(policy.lanes[1].maxAgeHours, 12);
});

test('buildWorkflowRunsUrl omits branch filter for wildcard lanes', () => {
  const wildcardUrl = buildWorkflowRunsUrl('owner/repo', 'fixture-drift.yml', null, 50);
  assert.match(wildcardUrl, /per_page=50/);
  assert.doesNotMatch(wildcardUrl, /branch=/);

  const explicitBranchUrl = buildWorkflowRunsUrl('owner/repo', 'fixture-drift.yml', 'develop', 20);
  assert.match(explicitBranchUrl, /branch=develop/);
  assert.match(explicitBranchUrl, /per_page=20/);
});

test('evaluateLane classifies pass, stale, incomplete, and missing', () => {
  const lane = {
    id: 'lane-a',
    workflow: 'fixture-drift.yml',
    jobName: 'Fixture Drift (Ubuntu)',
    maxAgeHours: 24,
    requiredForStable: true,
    matrix: {
      runner: 'ubuntu-latest',
      os: 'linux',
      imageTag: 'ni/linux:tag',
      scenario: 'scenario'
    }
  };
  const now = new Date('2026-03-06T12:00:00Z');
  const successObservation = {
    run: {
      id: 100,
      run_number: 10,
      run_attempt: 1,
      html_url: 'https://example/run/100',
      event: 'pull_request',
      created_at: '2026-03-06T10:00:00Z',
      updated_at: '2026-03-06T10:15:00Z',
      head_sha: 'abc'
    },
    job: {
      id: 200,
      name: 'Fixture Drift (Ubuntu)',
      conclusion: 'success',
      started_at: '2026-03-06T10:01:00Z',
      completed_at: '2026-03-06T10:12:00Z',
      html_url: 'https://example/job/200'
    }
  };

  const pass = evaluateLane(lane, successObservation, now);
  assert.equal(pass.status, 'pass');
  assert.equal(pass.success, true);
  assert.equal(pass.stale, false);

  const staleNow = new Date('2026-03-08T12:30:00Z');
  const stale = evaluateLane(lane, successObservation, staleNow);
  assert.equal(stale.status, 'stale');
  assert.equal(stale.stale, true);

  const incomplete = evaluateLane(
    lane,
    {
      ...successObservation,
      job: {
        ...successObservation.job,
        conclusion: 'skipped'
      }
    },
    now
  );
  assert.equal(incomplete.status, 'incomplete');

  const missing = evaluateLane(lane, null, now);
  assert.equal(missing.status, 'missing');
});

test('gate and report block stable on stale or incomplete lanes but warn on rc', () => {
  const lanes = [
    {
      id: 'lane-a',
      status: 'pass',
      requiredForStable: true
    },
    {
      id: 'lane-b',
      status: 'stale',
      requiredForStable: true
    },
    {
      id: 'lane-c',
      status: 'missing',
      requiredForStable: false
    }
  ];

  const stableGate = evaluateGate(lanes, 'stable', 'stable');
  assert.equal(stableGate.shouldFail, true);
  assert.equal(stableGate.status, 'fail');
  assert.deepEqual(stableGate.blockingLaneIds, ['lane-b']);

  const rcGate = evaluateGate(lanes, 'rc', 'stable');
  assert.equal(rcGate.shouldFail, false);
  assert.equal(rcGate.status, 'warn');

  const report = buildCertificationReport({
    repository: 'owner/repo',
    branch: 'develop',
    channel: 'stable',
    enforceMode: 'stable',
    policyPath: 'tools/policy/certification-matrix.json',
    policySha256: 'abc123',
    lanes,
    generatedAt: new Date('2026-03-06T12:00:00Z')
  });

  assert.equal(report.schema, 'priority/certification-matrix@v1');
  assert.equal(report.summary.requiredLaneCount, 2);
  assert.equal(report.summary.requiredPassing, 1);
  assert.equal(report.summary.status, 'fail');
  assert.equal(report.gate.shouldFail, true);
});

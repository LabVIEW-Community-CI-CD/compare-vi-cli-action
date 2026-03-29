import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildInfrastructureFailureReport,
  DEFAULT_OUTPUT_PATH,
  DEFAULT_POLICY_PATH,
  parseArgs,
  resolveBranchResolution,
  extractActionReferencesFromWorkflow,
  classifyActionReference,
  evaluateChecklist,
  summarizeChecklist,
  computeRunAttemptsUntilGreen,
  computeOnboardingMetrics,
  buildHardeningBacklog
} from '../downstream-onboarding.mjs';

test('parseArgs applies defaults and parses explicit values', () => {
  const defaults = parseArgs(['node', 'downstream-onboarding.mjs', '--repo', 'owner/downstream']);
  assert.equal(defaults.policyPath, DEFAULT_POLICY_PATH);
  assert.equal(defaults.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(defaults.lookbackRuns, 30);
  assert.equal(defaults.failOnGap, false);
  assert.equal(defaults.createHardeningIssues, false);

  const parsed = parseArgs([
    'node',
    'downstream-onboarding.mjs',
    '--repo',
    'owner/downstream',
    '--upstream-repo',
    'owner/upstream',
    '--action-repo',
    'owner/action',
    '--branch',
    'develop',
    '--started-at',
    '2026-03-05T12:00:00Z',
    '--lookback-runs',
    '12',
    '--policy',
    'custom-policy.json',
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
    '[onboarding-x]',
    '--fail-on-gap'
  ]);
  assert.equal(parsed.upstreamRepo, 'owner/upstream');
  assert.equal(parsed.actionRepo, 'owner/action');
  assert.equal(parsed.targetBranch, 'develop');
  assert.equal(parsed.startedAt, '2026-03-05T12:00:00Z');
  assert.equal(parsed.lookbackRuns, 12);
  assert.equal(parsed.policyPath, 'custom-policy.json');
  assert.equal(parsed.outputPath, 'custom-output.json');
  assert.equal(parsed.parentIssue, 715);
  assert.equal(parsed.createHardeningIssues, true);
  assert.equal(parsed.issueRepo, 'owner/issues');
  assert.deepEqual(parsed.issueLabels, ['program', 'enhancement']);
  assert.equal(parsed.issuePrefix, '[onboarding-x]');
  assert.equal(parsed.failOnGap, true);
});

test('resolveBranchResolution distinguishes explicit overrides from live repository defaults', () => {
  assert.deepEqual(
    resolveBranchResolution({
      requestedBranchOverride: 'downstream/develop',
      repositoryDefaultBranch: 'develop'
    }),
    {
      requestedBranchOverride: 'downstream/develop',
      repositoryDefaultBranch: 'develop',
      evaluatedBranch: 'downstream/develop',
      source: 'explicit-override'
    }
  );

  assert.deepEqual(
    resolveBranchResolution({
      requestedBranchOverride: null,
      repositoryDefaultBranch: 'develop'
    }),
    {
      requestedBranchOverride: null,
      repositoryDefaultBranch: 'develop',
      evaluatedBranch: 'develop',
      source: 'live-repository-default-branch'
    }
  );
});

test('extractActionReferencesFromWorkflow finds compare-vi uses entries', () => {
  const yaml = `
name: validate
jobs:
  check:
    steps:
      - uses: actions/checkout@v4
      - uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v1.2.3
      - uses: 'LabVIEW-Community-CI-CD/compare-vi-cli-action@0123456789abcdef0123456789abcdef01234567'
`;
  const refs = extractActionReferencesFromWorkflow(yaml, '.github/workflows/validate.yml', 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(refs.length, 2);
  assert.equal(refs[0].workflowPath, '.github/workflows/validate.yml');
  assert.equal(refs[0].ref, 'v1.2.3');
  assert.equal(refs[1].lineNumber > refs[0].lineNumber, true);
});

test('extractActionReferencesFromWorkflow ignores uses-like literals inside inline scripts', () => {
  const yaml = `
name: Promotion Contract
jobs:
  promotion-contract:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Validate comparevi stable pin contract
        shell: bash
        run: |
          node <<'EOF'
          ensureIncludes('.github/workflows/template-smoke.yml', \`uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@\${pin}\`);
          EOF
      - uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.6.3
`;
  const refs = extractActionReferencesFromWorkflow(
    yaml,
    '.github/workflows/promotion-contract.yml',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  );
  assert.deepEqual(
    refs.map((entry) => ({ lineNumber: entry.lineNumber, ref: entry.ref })),
    [{ lineNumber: 14, ref: 'v0.6.3' }]
  );
});

test('classifyActionReference identifies stable, rc, and commit refs', () => {
  assert.equal(classifyActionReference('v1.2.3').kind, 'stable-tag');
  assert.equal(classifyActionReference('v1.2.3-rc.4').kind, 'rc-tag');
  assert.equal(classifyActionReference('v1').kind, 'floating-tag');
  assert.equal(classifyActionReference('0123456789abcdef0123456789abcdef01234567').kind, 'commit-sha');
  assert.equal(classifyActionReference('0123456').kind, 'short-sha');
});

test('checklist evaluation and summary classify required failures', () => {
  const policy = {
    requiredEnvironments: ['production'],
    requiredBranchChecks: ['Policy Guard (Upstream) / policy-guard'],
    checklist: [
      {
        id: 'repository-accessible',
        description: 'repo',
        required: true,
        severity: 'P1',
        recommendation: 'fix repo'
      },
      {
        id: 'workflow-reference-present',
        description: 'workflow',
        required: true,
        severity: 'P1',
        recommendation: 'add workflow'
      },
      {
        id: 'certified-reference-pinned',
        description: 'ref',
        required: true,
        severity: 'P1',
        recommendation: 'pin ref'
      },
      {
        id: 'successful-consumption-run',
        description: 'run',
        required: true,
        severity: 'P1',
        recommendation: 'run workflow'
      },
      {
        id: 'protected-environments-configured',
        description: 'envs',
        required: false,
        severity: 'P2',
        recommendation: 'configure envs'
      },
      {
        id: 'required-checks-visible',
        description: 'checks',
        required: false,
        severity: 'P2',
        recommendation: 'configure checks'
      }
    ]
  };

  const checklist = evaluateChecklist(policy, {
    repository: { ok: true, defaultBranch: 'develop', htmlUrl: 'https://example/repo' },
    references: [],
    referenceVerifications: [],
    successfulRuns: [],
    firstSuccessfulRunAt: null,
    environments: { observable: true, configured: [], missing: ['production'] },
    branchProtection: { observable: false, error: 'branch-protection-api-403', contexts: [], missingChecks: ['Policy Guard (Upstream) / policy-guard'] }
  });
  const summary = summarizeChecklist(checklist);
  assert.equal(summary.status, 'fail');
  assert.equal(summary.requiredFailCount, 3);
  assert.equal(summary.warnCount, 2);

  const backlog = buildHardeningBacklog(checklist, 'owner/downstream');
  assert.equal(backlog.length, 5);
  assert.equal(backlog[0].severity, 'P1');
});

test('computeRunAttemptsUntilGreen and computeOnboardingMetrics derive lead time/friction', () => {
  const runs = [
    {
      id: 1,
      createdAt: '2026-03-05T10:00:00Z',
      updatedAt: '2026-03-05T10:05:00Z',
      conclusion: 'failure'
    },
    {
      id: 2,
      createdAt: '2026-03-05T11:00:00Z',
      updatedAt: '2026-03-05T11:06:00Z',
      conclusion: 'success'
    }
  ];
  const runProgress = computeRunAttemptsUntilGreen(runs, '2026-03-05T09:00:00Z');
  assert.equal(runProgress.attempts, 2);
  assert.equal(runProgress.firstSuccess.id, 2);

  const metrics = computeOnboardingMetrics({
    startedAt: '2026-03-05T09:00:00Z',
    allRuns: runs,
    summary: {
      requiredFailCount: 1,
      warnCount: 2
    }
  });
  assert.equal(metrics.onboardingLeadTimeHours, 2.1);
  assert.equal(metrics.runAttemptsUntilGreen, 2);
  assert.equal(metrics.requiredFailures, 1);
  assert.equal(metrics.warningCount, 2);
  assert.equal(metrics.frictionScore, 6);
});

test('buildInfrastructureFailureReport produces a schema-valid fail envelope', () => {
  const report = buildInfrastructureFailureReport({
    options: {
      downstreamRepo: 'owner/downstream',
      upstreamRepo: 'owner/upstream',
      actionRepo: 'owner/action',
      targetBranch: 'develop',
      startedAt: null,
      parentIssue: 715
    },
    policy: {
      requiredEnvironments: ['production'],
      requiredBranchChecks: ['Policy Guard (Upstream) / policy-guard'],
      checklist: [
        {
          id: 'repository-accessible',
          description: 'repo',
          required: true,
          severity: 'P1',
          recommendation: 'fix repo'
        },
        {
          id: 'workflow-reference-present',
          description: 'workflow',
          required: true,
          severity: 'P1',
          recommendation: 'add workflow'
        },
        {
          id: 'certified-reference-pinned',
          description: 'ref',
          required: true,
          severity: 'P1',
          recommendation: 'pin ref'
        },
        {
          id: 'successful-consumption-run',
          description: 'run',
          required: true,
          severity: 'P1',
          recommendation: 'run workflow'
        },
        {
          id: 'protected-environments-configured',
          description: 'envs',
          required: false,
          severity: 'P2',
          recommendation: 'configure envs'
        },
        {
          id: 'required-checks-visible',
          description: 'checks',
          required: false,
          severity: 'P2',
          recommendation: 'configure checks'
        }
      ]
    },
    generatedAt: '2026-03-09T19:16:18Z',
    upstreamRepository: 'owner/upstream',
    actionRepository: 'owner/action',
    downstreamRepository: 'owner/downstream',
    error: new Error('GitHub token not found.'),
    stage: 'runtime'
  });

  assert.equal(report.schema, 'priority/downstream-onboarding-report@v1');
  assert.equal(report.summary.status, 'fail');
  assert.equal(report.repository.ok, false);
  assert.equal(report.repository.defaultBranch, null);
  assert.equal(report.repository.evaluatedBranch, 'develop');
  assert.equal(report.branchResolution.source, 'explicit-override');
  assert.equal(report.infrastructureFailure.stage, 'runtime');
  assert.match(report.infrastructureFailure.message, /GitHub token not found/);
  assert.equal(report.hardeningBacklog.length > 0, true);
});

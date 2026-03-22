import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_REVALIDATED_OUTPUT_PATH,
  buildRevalidationArgv,
  parseArgs,
  runWakeAdjudication
} from '../wake-adjudication.mjs';

const WARNING_ONLY = new Set(['protected-environments-configured', 'required-checks-visible']);

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createOnboardingReport({
  targetBranch,
  defaultBranch = targetBranch,
  branchResolutionSource = 'live-repository-default-branch',
  requiredFailures = [],
  warnings = [],
  referencedWorkflowCount = 0,
  successfulRuns = 0
}) {
  const requiredFailureIds = new Set(requiredFailures.map((entry) => entry.id));
  const warningIds = new Set(warnings.map((entry) => entry.id));
  const checklistIds = [
    'repository-accessible',
    'workflow-reference-present',
    'certified-reference-pinned',
    'successful-consumption-run',
    'protected-environments-configured',
    'required-checks-visible'
  ];
  const checklist = checklistIds.map((id) => {
    const required = !WARNING_ONLY.has(id);
    const severity = required ? 'P1' : 'P2';
    if (requiredFailureIds.has(id)) {
      const match = requiredFailures.find((entry) => entry.id === id);
      return {
        id,
        description: id,
        required,
        severity,
        recommendation: 'fix',
        status: 'fail',
        reason: match?.reason || 'failed'
      };
    }
    if (warningIds.has(id)) {
      const match = warnings.find((entry) => entry.id === id);
      return {
        id,
        description: id,
        required,
        severity,
        recommendation: 'check',
        status: 'warn',
        reason: match?.reason || 'warn'
      };
    }
    return {
      id,
      description: id,
      required,
      severity,
      recommendation: 'ok',
      status: 'pass',
      reason: 'ok'
    };
  });
  const requiredFailCount = requiredFailures.length;
  const warnCount = warnings.length;
  const status = requiredFailCount > 0 ? 'fail' : warnCount > 0 ? 'warn' : 'pass';
  return {
    schema: 'priority/downstream-onboarding-report@v1',
    generatedAt: '2026-03-22T15:29:00.000Z',
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    actionRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    targetBranch,
    repository: {
      ok: true,
      error: null,
      defaultBranch,
      evaluatedBranch: targetBranch,
      branchResolutionSource,
      htmlUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      private: false
    },
    branchResolution: {
      requestedBranchOverride: null,
      repositoryDefaultBranch: defaultBranch,
      evaluatedBranch: targetBranch,
      source: branchResolutionSource
    },
    workflowDiscovery: {
      scannedWorkflowCount: referencedWorkflowCount > 0 ? 1 : 0,
      referencedWorkflowCount
    },
    workflowReferences: Array.from({ length: referencedWorkflowCount }, (_, index) => ({
      workflowPath: '.github/workflows/template-smoke.yml',
      lineNumber: index + 1,
      ref: 'v0.6.3',
      verified: {
        ref: 'v0.6.3',
        kind: 'stable-tag',
        immutable: true,
        certifiedCandidate: true,
        exists: true,
        certified: true,
        reason: 'stable-tag-verified'
      }
    })),
    runs: {
      total: successfulRuns,
      successful: successfulRuns,
      firstSuccessfulRunAt: successfulRuns > 0 ? '2026-03-20T20:47:21Z' : null
    },
    checklist,
    metrics: {
      requiredFailures: requiredFailCount,
      warningCount: warnCount,
      frictionScore: requiredFailCount * 3 + warnCount
    },
    summary: {
      status,
      totalChecklist: checklist.length,
      passCount: checklist.filter((entry) => entry.status === 'pass').length,
      warnCount,
      failCount: requiredFailCount,
      requiredFailCount
    },
    hardeningBacklog: []
  };
}

test('parseArgs exposes checked-in wake adjudication defaults', () => {
  const parsed = parseArgs(['node', 'wake-adjudication.mjs', '--reported', 'reported.json']);
  assert.equal(parsed.reportedPath, 'reported.json');
  assert.equal(parsed.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(parsed.revalidatedOutputPath, DEFAULT_REVALIDATED_OUTPUT_PATH);
  assert.equal(parsed.revalidatedReportPath, null);
});

test('buildRevalidationArgv replays downstream onboarding against the reported downstream repo', () => {
  const argv = buildRevalidationArgv(
    {
      downstreamRepository: 'owner/downstream',
      upstreamRepository: 'owner/upstream',
      actionRepository: 'owner/action'
    },
    {
      revalidatedOutputPath: 'tests/results/_agent/onboarding/revalidated.json',
      revalidatedBranch: 'develop'
    }
  );

  assert.deepEqual(argv, [
    'node',
    'downstream-onboarding.mjs',
    '--repo',
    'owner/downstream',
    '--upstream-repo',
    'owner/upstream',
    '--action-repo',
    'owner/action',
    '--output',
    'tests/results/_agent/onboarding/revalidated.json',
    '--branch',
    'develop'
  ]);
});

test('runWakeAdjudication classifies stale downstream failures as branch-target-drift when live replay resolves a different branch', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-adjudication-branch-drift-'));
  const reportedPath = path.join(tmpDir, 'reported.json');
  const revalidatedOutputPath = path.join(tmpDir, 'revalidated.json');
  const outputPath = path.join(tmpDir, 'wake-adjudication.json');

  writeJson(
    reportedPath,
    createOnboardingReport({
      targetBranch: 'downstream/develop',
      defaultBranch: 'downstream/develop',
      requiredFailures: [
        { id: 'workflow-reference-present', reason: 'no-workflow-reference-found' },
        { id: 'certified-reference-pinned', reason: 'no-reference-to-certify' },
        { id: 'successful-consumption-run', reason: 'no-successful-run-observed' }
      ]
    })
  );

  const { report } = await runWakeAdjudication(
    {
      repoRoot: tmpDir,
      reportedPath,
      revalidatedOutputPath,
      outputPath
    },
    {
      runDownstreamOnboardingFn: async () => {
        writeJson(
          revalidatedOutputPath,
          createOnboardingReport({
            targetBranch: 'develop',
            defaultBranch: 'develop',
            warnings: [
              { id: 'protected-environments-configured', reason: 'required-environments-missing' },
              { id: 'required-checks-visible', reason: 'branch-protection-api-404' }
            ],
            referencedWorkflowCount: 1,
            successfulRuns: 7
          })
        );
        return 0;
      }
    }
  );

  assert.equal(report.summary.classification, 'branch-target-drift');
  assert.equal(report.summary.suppressIssueInjection, true);
  assert.equal(report.summary.recommendedOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.delta.targetBranchChanged, true);
  assert.equal(report.authority.routing.selectedTier, 'authoritative');
  assert.equal(report.authority.routing.blockedLowerTier, true);
  assert.deepEqual(report.authority.routing.contradictionFields.sort(), ['defaultBranch', 'targetBranch']);
  assert.equal(report.authority.authoritative.targetBranch, 'develop');
  assert.equal(report.authority.authoritative.source, 'live-repository-default-branch');
  assert.deepEqual(report.delta.clearedRequiredFailureIds.sort(), [
    'certified-reference-pinned',
    'successful-consumption-run',
    'workflow-reference-present'
  ]);
});

test('runWakeAdjudication classifies surviving required failures as live-defect', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-adjudication-live-defect-'));
  const reportedPath = path.join(tmpDir, 'reported.json');
  const revalidatedOutputPath = path.join(tmpDir, 'revalidated.json');

  writeJson(
    reportedPath,
    createOnboardingReport({
      targetBranch: 'develop',
      requiredFailures: [{ id: 'workflow-reference-present', reason: 'no-workflow-reference-found' }]
    })
  );

  const { report } = await runWakeAdjudication(
    {
      repoRoot: tmpDir,
      reportedPath,
      revalidatedOutputPath
    },
    {
      runDownstreamOnboardingFn: async () => {
        writeJson(
          revalidatedOutputPath,
          createOnboardingReport({
            targetBranch: 'develop',
            requiredFailures: [{ id: 'workflow-reference-present', reason: 'no-workflow-reference-found' }]
          })
        );
        return 1;
      }
    }
  );

  assert.equal(report.summary.classification, 'live-defect');
  assert.equal(report.summary.suppressIssueInjection, false);
  assert.equal(report.summary.recommendedOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.authority.routing.blockedLowerTier, false);
  assert.deepEqual(report.delta.persistentRequiredFailureIds, ['workflow-reference-present']);
});

test('runWakeAdjudication classifies warning-only live replay as environment-only', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-adjudication-environment-only-'));
  const reportedPath = path.join(tmpDir, 'reported.json');
  const revalidatedOutputPath = path.join(tmpDir, 'revalidated.json');

  writeJson(
    reportedPath,
    createOnboardingReport({
      targetBranch: 'develop',
      warnings: [{ id: 'protected-environments-configured', reason: 'required-environments-missing' }]
    })
  );

  const { report } = await runWakeAdjudication(
    {
      repoRoot: tmpDir,
      reportedPath,
      revalidatedOutputPath
    },
    {
      runDownstreamOnboardingFn: async () => {
        writeJson(
          revalidatedOutputPath,
          createOnboardingReport({
            targetBranch: 'develop',
            warnings: [{ id: 'required-checks-visible', reason: 'branch-protection-api-404' }],
            referencedWorkflowCount: 1,
            successfulRuns: 3
          })
        );
        return 0;
      }
    }
  );

  assert.equal(report.summary.classification, 'environment-only');
  assert.equal(report.summary.status, 'monitoring');
  assert.equal(report.summary.suppressDownstreamIssueInjection, true);
});

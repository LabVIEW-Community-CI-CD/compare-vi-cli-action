import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import Ajv from 'ajv';
import addFormats from 'ajv-formats';

import { runWakeAdjudication } from '../wake-adjudication.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createOnboardingReport({
  targetBranch,
  defaultBranch = targetBranch,
  branchResolutionSource = 'live-repository-default-branch',
  requiredFailures = [],
  warnings = []
}) {
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
      scannedWorkflowCount: 1,
      referencedWorkflowCount: 1
    },
    workflowReferences: [],
    runs: {
      total: 1,
      successful: 1,
      firstSuccessfulRunAt: '2026-03-20T20:47:21Z'
    },
    checklist: [
      {
        id: 'repository-accessible',
        description: 'repo',
        required: true,
        severity: 'P1',
        recommendation: 'ok',
        status: 'pass',
        reason: 'repository-visible'
      },
      ...requiredFailures.map((entry) => ({
        id: entry.id,
        description: entry.id,
        required: true,
        severity: 'P1',
        recommendation: 'fix',
        status: 'fail',
        reason: entry.reason
      })),
      ...warnings.map((entry) => ({
        id: entry.id,
        description: entry.id,
        required: false,
        severity: 'P2',
        recommendation: 'check',
        status: 'warn',
        reason: entry.reason
      }))
    ],
    metrics: {
      requiredFailures: requiredFailures.length,
      warningCount: warnings.length,
      frictionScore: requiredFailures.length * 3 + warnings.length
    },
    summary: {
      status: requiredFailures.length > 0 ? 'fail' : warnings.length > 0 ? 'warn' : 'pass',
      totalChecklist: 1 + requiredFailures.length + warnings.length,
      passCount: 1,
      warnCount: warnings.length,
      failCount: requiredFailures.length,
      requiredFailCount: requiredFailures.length
    },
    hardeningBacklog: []
  };
}

test('wake adjudication report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-adjudication-schema-'));
  const reportedPath = path.join(tmpDir, 'reported.json');
  const revalidatedOutputPath = path.join(tmpDir, 'revalidated.json');

  writeJson(
    reportedPath,
    createOnboardingReport({
      targetBranch: 'downstream/develop',
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
            warnings: [{ id: 'required-checks-visible', reason: 'branch-protection-api-404' }]
          })
        );
        return 0;
      }
    }
  );

  const ajv = new Ajv({ allErrors: true, strict: false });
  addFormats(ajv);
  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'wake-adjudication-report-v1.schema.json'), 'utf8')
  );
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

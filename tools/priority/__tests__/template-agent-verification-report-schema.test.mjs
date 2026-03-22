import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runTemplateAgentVerificationReport } from '../template-agent-verification-report.mjs';

const repoRoot = path.resolve(process.cwd());

test('template-agent verification report matches the checked-in schema', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-schema-'));
  const policyPath = path.join(tempDir, 'delivery-agent.policy.json');
  const outputPath = path.join(tempDir, 'template-agent-verification-report.json');
  fs.writeFileSync(
    policyPath,
    JSON.stringify({
      schema: 'priority/delivery-agent-policy@v1',
      workerPool: {
        targetSlotCount: 4
      },
      templateAgentVerificationLane: {
        enabled: true,
        reservedSlotCount: 1,
        minimumImplementationSlots: 3,
        executionMode: 'hosted-first',
        targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        consumerRailBranch: 'downstream/develop',
        metrics: {
          maxVerificationLagIterations: 1,
          maxHostedDurationMinutes: 30,
          requireMachineReadableRecommendation: true
        }
      }
    }),
    'utf8'
  );

  const { report } = runTemplateAgentVerificationReport(
    {
      policyPath,
      outputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      iterationLabel: 'post-merge #1635',
      iterationRef: 'issue/origin-1632-template-agent-verification-lane',
      iterationHeadSha: 'abc123',
      verificationStatus: 'pass',
      durationSeconds: 240,
      provider: 'hosted-github-workflow',
      runUrl: 'https://github.com/example/run/1',
      templateRepo: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      templateVersion: 'v0.1.1',
      templateRef: 'v0.1.1',
      cookiecutterVersion: '2.7.1',
      executionPlane: 'linux-tools-image',
      containerImage: 'ghcr.io/labview-community-ci-cd/comparevi-tools:v0.1.0',
      generatedConsumerWorkspaceRoot: 'E:\\comparevi-template-consumers\\run-1',
      laneId: 'lane-template-verify',
      agentId: 'darwin',
      fundingWindowId: 'HQ1VJLMV-0027',
      failOnBlockers: true
    },
    {
      resolveRepoSlugFn: (explicitRepo) => explicitRepo
    }
  );

  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'template-agent-verification-report-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.provenance.templateDependency.version, 'v0.1.1');
  assert.equal(report.provenance.execution.executionPlane, 'linux-tools-image');
});

test('checked-in template-agent verification report stays as the machine-readable pending seed', () => {
  const report = JSON.parse(
    fs.readFileSync(
      path.join(repoRoot, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json'),
      'utf8'
    )
  );
  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'template-agent-verification-report-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.summary.status, 'pending');
  assert.equal(report.verification.status, 'pending');
  assert.equal(report.summary.recommendation, 'wait-for-template-verification');
  assert.equal(report.provenance.templateDependency.repository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.provenance.templateDependency.version, null);
  assert.equal(report.provenance.execution.agentId, null);
});

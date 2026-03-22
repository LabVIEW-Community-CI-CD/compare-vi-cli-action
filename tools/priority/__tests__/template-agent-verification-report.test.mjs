import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  DEFAULT_OUTPUT_PATH,
  evaluateTemplateAgentVerificationReport,
  parseArgs,
  runTemplateAgentVerificationReport
} from '../template-agent-verification-report.mjs';

const repoRoot = path.resolve(process.cwd());

test('parseArgs captures template-agent verification report inputs', () => {
  const options = parseArgs([
    'node',
    'template-agent-verification-report.mjs',
    '--iteration-label',
    'post-merge #1635',
    '--iteration-head-sha',
    'abc123',
    '--verification-status',
    'pass',
    '--duration-seconds',
    '240',
    '--run-url',
    'https://github.com/example/run/1',
    '--template-repo',
    'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    '--template-version',
    'v0.1.1',
    '--template-ref',
    'v0.1.1',
    '--cookiecutter-version',
    '2.7.1',
    '--execution-plane',
    'linux-tools-image',
    '--container-image',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:v0.1.0',
    '--generated-consumer-workspace-root',
    'E:\\comparevi-template-consumers\\run-1',
    '--lane-id',
    'lane-template-verify',
    '--agent-id',
    'darwin',
    '--funding-window-id',
    'HQ1VJLMV-0027'
  ]);

  assert.equal(options.iterationLabel, 'post-merge #1635');
  assert.equal(options.iterationHeadSha, 'abc123');
  assert.equal(options.verificationStatus, 'pass');
  assert.equal(options.durationSeconds, 240);
  assert.equal(options.runUrl, 'https://github.com/example/run/1');
  assert.match(options.templatePolicyPath, /tools[\\/]policy[\\/]template-dependency\.json$/);
  assert.equal(options.templateVersion, 'v0.1.1');
  assert.equal(options.cookiecutterVersion, '2.7.1');
  assert.equal(options.executionPlane, 'linux-tools-image');
  assert.equal(options.outputPath, DEFAULT_OUTPUT_PATH);
});

test('parseArgs requires the landed iteration head SHA for template-agent verification evidence', () => {
  assert.throws(
    () =>
      parseArgs([
        'node',
        'template-agent-verification-report.mjs',
        '--iteration-label',
        'post-merge #1635',
        '--verification-status',
        'pass'
      ]),
    /Missing required option: --iteration-head-sha <sha>\./
  );
});

test('evaluateTemplateAgentVerificationReport passes when the reserved hosted lane is healthy', () => {
  const report = evaluateTemplateAgentVerificationReport({
    policy: {
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
    },
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
    fundingWindowId: 'HQ1VJLMV-0027'
  });

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.summary.recommendation, 'continue-template-agent-loop');
  assert.equal(report.iteration.headSha, 'abc123');
  assert.equal(report.lane.implementationSlotsRemaining, 3);
  assert.equal(report.metrics.durationWithinGoal, true);
  assert.equal(report.blockers.length, 0);
  assert.equal(report.provenance.templateDependency.repository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.provenance.templateDependency.version, 'v0.1.1');
  assert.equal(report.provenance.templateDependency.cookiecutterVersion, '2.7.1');
  assert.equal(report.provenance.execution.agentId, 'darwin');
});

test('evaluateTemplateAgentVerificationReport blocks when the landed iteration head SHA is missing', () => {
  const report = evaluateTemplateAgentVerificationReport({
    policy: {
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
    },
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    iterationLabel: 'post-merge #1635',
    iterationRef: 'issue/origin-1632-template-agent-verification-lane',
    iterationHeadSha: null,
    verificationStatus: 'pass',
    durationSeconds: 240,
    provider: 'hosted-github-workflow',
    runUrl: 'https://github.com/example/run/1',
    templateRepo: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
  });

  assert.equal(report.summary.status, 'blocked');
  assert.match(report.blockers[0].code, /iteration-head-sha-missing/);
});

test('runTemplateAgentVerificationReport blocks when reserved capacity is missing', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-report-'));
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
        reservedSlotCount: 0,
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
      iterationRef: null,
      iterationHeadSha: 'abc123',
      verificationStatus: 'pass',
      durationSeconds: 240,
      provider: 'hosted-github-workflow',
      runUrl: null,
      templateRepo: null,
      failOnBlockers: false
    },
    {
      resolveRepoSlugFn: (explicitRepo) => explicitRepo
    }
  );

  assert.equal(report.summary.status, 'blocked');
  assert.match(report.blockers[0].code, /lane-not-reserved|implementation-capacity-too-low/);
  assert.equal(fs.existsSync(outputPath), true);
});

test('runTemplateAgentVerificationReport defaults pinned template provenance from the checked-in policy', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-provenance-'));
  const policyPath = path.join(tempDir, 'delivery-agent.policy.json');
  const outputPath = path.join(tempDir, 'template-agent-verification-report.json');
  fs.writeFileSync(
    policyPath,
    JSON.stringify({
      schema: 'priority/delivery-agent-policy@v1',
      workerPool: {
        targetSlotCount: 8
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
      verificationStatus: 'pending',
      durationSeconds: null,
      provider: 'hosted-github-workflow',
      runUrl: null,
      templateRepo: null,
      failOnBlockers: false
    },
    {
      resolveRepoSlugFn: (explicitRepo) => explicitRepo
    }
  );

  assert.equal(report.provenance.templateDependency.repository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.provenance.templateDependency.version, 'v0.1.1');
  assert.equal(report.provenance.templateDependency.ref, 'v0.1.1');
  assert.equal(report.provenance.templateDependency.cookiecutterVersion, '2.7.1');
  assert.equal(report.provenance.execution.executionPlane, 'linux-tools-image');
  assert.equal(report.provenance.execution.containerImage, 'ghcr.io/labview-community-ci-cd/comparevi-tools:latest');
  assert.equal(report.provenance.execution.generatedConsumerWorkspaceRoot, null);
});

test('CLI entrypoint writes the template-agent verification report on Windows path resolution', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-cli-'));
  const outputPath = path.join(tempDir, 'template-agent-verification-report.json');
  const result = spawnSync(
    process.execPath,
    [
      path.join(repoRoot, 'tools', 'priority', 'template-agent-verification-report.mjs'),
      '--iteration-label',
      'post-merge #1635',
      '--iteration-head-sha',
      'abc123',
      '--verification-status',
      'pass',
      '--duration-seconds',
      '240',
      '--output',
      outputPath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--no-fail-on-blockers'
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(fs.existsSync(outputPath), true);
});

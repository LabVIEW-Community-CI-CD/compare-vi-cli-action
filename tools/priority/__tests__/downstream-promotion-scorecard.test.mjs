#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { evaluateDownstreamPromotionScorecard, parseArgs, runDownstreamPromotionScorecard } from '../downstream-promotion-scorecard.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs enforces required downstream promotion scorecard inputs', () => {
  const parsed = parseArgs([
    'node',
    'downstream-promotion-scorecard.mjs',
    '--success-report',
    'success.json',
    '--feedback-report',
    'feedback.json',
    '--template-agent-verification-report',
    'template-agent-verification-report.json',
    '--manifest-report',
    'manifest.json',
    '--repo',
    'example/repo',
    '--no-fail-on-blockers'
  ]);

  assert.equal(parsed.successReportPath, 'success.json');
  assert.equal(parsed.feedbackReportPath, 'feedback.json');
  assert.equal(parsed.templateAgentVerificationReportPath, 'template-agent-verification-report.json');
  assert.equal(parsed.manifestReportPath, 'manifest.json');
  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.failOnBlockers, false);
});

test('evaluateDownstreamPromotionScorecard reports blockers deterministically', () => {
  const pass = evaluateDownstreamPromotionScorecard({
    successReport: { exists: true, error: null },
    feedbackReport: { exists: true, error: null },
    templateAgentVerificationReport: { exists: true, error: null },
    manifestReport: { exists: false, error: null },
    successGate: { status: 'pass', totalBlockers: 0 },
    feedbackGate: { status: 'pass', executionStatus: 'pass' },
    templateAgentVerificationGate: {
      status: 'pass',
      verificationStatus: 'pass',
      verificationProvider: 'hosted-github-workflow',
      verificationRunUrl: 'https://example.invalid/run/1',
      sourceCommitMatched: true
    },
    manifestGate: { status: 'missing' }
  });
  assert.equal(pass.status, 'pass');
  assert.equal(pass.blockerCount, 0);

  const fail = evaluateDownstreamPromotionScorecard({
    successReport: { exists: false, error: null },
    feedbackReport: { exists: true, error: 'bad json' },
    templateAgentVerificationReport: { exists: false, error: null },
    manifestReport: { exists: true, error: 'bad json' },
    successGate: { status: 'fail', totalBlockers: 2 },
    feedbackGate: { status: 'fail', executionStatus: 'fail' },
    templateAgentVerificationGate: {
      status: 'fail',
      verificationStatus: 'blocked',
      verificationProvider: 'local-manual',
      verificationRunUrl: null,
      sourceCommitMatched: false
    },
    manifestGate: { status: 'fail' }
  });

  assert.equal(fail.status, 'fail');
  assert.ok(fail.blockers.some((entry) => entry.code === 'success-report-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'feedback-report-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'downstream-blockers'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'feedback-execution'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'template-agent-verification-report-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'template-agent-verification-contract'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'template-agent-verification-source-mismatch'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'template-agent-verification-hosted-provenance'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'manifest-report-unreadable'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'manifest-contract'));
});

test('runDownstreamPromotionScorecard projects manifest provenance when present', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const manifestReportPath = path.join(tmpDir, 'downstream-develop-promotion-manifest.json');
  const outputPath = path.join(tmpDir, 'downstream-develop-promotion-scorecard.json');

  writeJson(successReportPath, {
    schema: 'priority/downstream-onboarding-success@v1',
    summary: {
      status: 'warn',
      repositoriesEvaluated: 1,
      totalBlockers: 0,
      totalWarnings: 3
    }
  });
  writeJson(feedbackReportPath, {
    schema: 'priority/downstream-onboarding-feedback@v1',
    inputs: {
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    execution: {
      status: 'pass',
      evaluateExitCode: 0,
      successExitCode: 0
    }
  });
  writeJson(templateAgentVerificationReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    summary: {
      status: 'pass',
      blockerCount: 0,
      recommendation: 'continue-template-agent-loop'
    },
    iteration: {
      label: 'post-merge develop',
      headSha: '1234567890abcdef1234567890abcdef12345678'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 3,
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/example/repo/actions/runs/1'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'linux-tools-image',
        containerImage: 'ghcr.io/labview-community-ci-cd/comparevi-tools:latest',
        generatedConsumerWorkspaceRoot: 'E:/comparevi-template-consumers/example',
        laneId: 'logical-lane-template-verification',
        agentId: 'darwin',
        fundingWindowId: 'invoice-turn-2026-03-HQ1VJLMV-0027'
      }
    },
    goals: {},
    metrics: {
      targetSlotCount: 8,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 3,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(manifestReportPath, {
    schema: 'priority/downstream-promotion-manifest@v1',
    promotion: {
      sourceRef: 'upstream/develop',
      sourceCommitSha: '1234567890abcdef1234567890abcdef12345678',
      targetBranch: 'downstream/develop',
      targetBranchClassId: 'downstream-consumer-proving-rail',
      localSourceVerification: {
        attempted: true,
        matched: true
      }
    },
    inputs: {
      compareviToolsRelease: 'v0.6.3-tools.14',
      compareviHistoryRelease: 'v1.3.24',
      scenarioPackIdentity: 'scenario-pack@v1',
      cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1'
    }
  });

  const result = runDownstreamPromotionScorecard({
    repo: 'example/repo',
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    manifestReportPath,
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.gates.successReport.summaryStatus, 'warn');
  assert.equal(result.report.gates.templateAgentVerificationReport.status, 'pass');
  assert.equal(result.report.gates.templateAgentVerificationReport.sourceCommitMatched, true);
  assert.equal(result.report.gates.manifestReport.status, 'pass');
  assert.equal(result.report.summary.metrics.totalWarnings, 3);
  assert.equal(result.report.summary.provenance.compareviToolsRelease, 'v0.6.3-tools.14');
  assert.equal(result.report.summary.provenance.cookiecutterTemplateIdentity, 'LabviewGitHubCiTemplate@v0.1.1');
  assert.equal(
    result.report.summary.provenance.templateVerificationRepository,
    'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
  );
});

test('runDownstreamPromotionScorecard fails closed when onboarding blockers remain', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-fail-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');

  writeJson(successReportPath, {
    schema: 'priority/downstream-onboarding-success@v1',
    summary: {
      status: 'fail',
      repositoriesEvaluated: 1,
      totalBlockers: 2,
      totalWarnings: 1
    }
  });
  writeJson(feedbackReportPath, {
    schema: 'priority/downstream-onboarding-feedback@v1',
    inputs: {
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    execution: {
      status: 'pass',
      evaluateExitCode: 0,
      successExitCode: 0
    }
  });
  writeJson(templateAgentVerificationReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    summary: {
      status: 'blocked',
      blockerCount: 1,
      recommendation: 'repair-template-lane'
    },
    iteration: {
      label: 'post-merge develop',
      headSha: '1234567890abcdef1234567890abcdef12345678'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 3,
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'blocked'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'linux-tools-image',
        containerImage: 'ghcr.io/labview-community-ci-cd/comparevi-tools:latest',
        generatedConsumerWorkspaceRoot: 'E:/comparevi-template-consumers/example',
        laneId: 'logical-lane-template-verification',
        agentId: 'darwin',
        fundingWindowId: 'invoice-turn-2026-03-HQ1VJLMV-0027'
      }
    },
    goals: {},
    metrics: {
      targetSlotCount: 8,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 3,
      recommendationPresent: true
    },
    blockers: [{ code: 'template-blocked', message: 'Hosted verification did not pass.' }]
  });

  const result = runDownstreamPromotionScorecard({
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    failOnBlockers: true
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.summary.status, 'fail');
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'downstream-blockers'));
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'template-agent-verification-contract'));
});

test('runDownstreamPromotionScorecard fails closed when template verification head sha drifts from the manifest', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-sha-drift-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const manifestReportPath = path.join(tmpDir, 'downstream-develop-promotion-manifest.json');

  writeJson(successReportPath, {
    schema: 'priority/downstream-onboarding-success@v1',
    summary: { status: 'pass', repositoriesEvaluated: 1, totalBlockers: 0, totalWarnings: 0 }
  });
  writeJson(feedbackReportPath, {
    schema: 'priority/downstream-onboarding-feedback@v1',
    inputs: { downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate' },
    execution: { status: 'pass', evaluateExitCode: 0, successExitCode: 0 }
  });
  writeJson(templateAgentVerificationReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    summary: { status: 'pass', blockerCount: 0, recommendation: 'continue-template-agent-loop' },
    iteration: { label: 'post-merge develop', headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 3,
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/example/repo/actions/runs/2'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      },
      execution: {}
    },
    goals: {},
    metrics: {
      targetSlotCount: 8,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 3,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(manifestReportPath, {
    schema: 'priority/downstream-promotion-manifest@v1',
    promotion: {
      sourceRef: 'upstream/develop',
      sourceCommitSha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      targetBranch: 'downstream/develop',
      targetBranchClassId: 'downstream-consumer-proving-rail',
      localSourceVerification: { attempted: true, matched: true }
    },
    inputs: { cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1' }
  });

  const result = runDownstreamPromotionScorecard({
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    manifestReportPath,
    failOnBlockers: false
  });

  assert.equal(result.report.summary.status, 'fail');
  assert.equal(result.report.gates.templateAgentVerificationReport.sourceCommitMatched, false);
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'template-agent-verification-source-mismatch'));
});

test('runDownstreamPromotionScorecard fails closed when template verification lacks hosted provenance', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-hosted-provenance-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const manifestReportPath = path.join(tmpDir, 'downstream-develop-promotion-manifest.json');

  writeJson(successReportPath, {
    schema: 'priority/downstream-onboarding-success@v1',
    summary: { status: 'pass', repositoriesEvaluated: 1, totalBlockers: 0, totalWarnings: 0 }
  });
  writeJson(feedbackReportPath, {
    schema: 'priority/downstream-onboarding-feedback@v1',
    inputs: { downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate' },
    execution: { status: 'pass', evaluateExitCode: 0, successExitCode: 0 }
  });
  writeJson(templateAgentVerificationReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    summary: { status: 'pass', blockerCount: 0, recommendation: 'continue-template-agent-loop' },
    iteration: { label: 'post-merge develop', headSha: '1234567890abcdef1234567890abcdef12345678' },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 3,
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'local-manual',
      status: 'pass',
      runUrl: null
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      },
      execution: {}
    },
    goals: {},
    metrics: {
      targetSlotCount: 8,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 3,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(manifestReportPath, {
    schema: 'priority/downstream-promotion-manifest@v1',
    promotion: {
      sourceRef: 'upstream/develop',
      sourceCommitSha: '1234567890abcdef1234567890abcdef12345678',
      targetBranch: 'downstream/develop',
      targetBranchClassId: 'downstream-consumer-proving-rail',
      localSourceVerification: { attempted: true, matched: true }
    },
    inputs: { cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1' }
  });

  const result = runDownstreamPromotionScorecard({
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    manifestReportPath,
    failOnBlockers: false
  });

  assert.equal(result.report.summary.status, 'fail');
  assert.equal(result.report.gates.templateAgentVerificationReport.verificationProvider, 'local-manual');
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'template-agent-verification-hosted-provenance'));
});

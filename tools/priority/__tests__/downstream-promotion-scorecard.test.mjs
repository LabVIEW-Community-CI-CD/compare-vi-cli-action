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
    '--vi-history-lv32-shadow-proof-receipt',
    'vi-history-lv32-shadow-proof-receipt.json',
    '--repo',
    'example/repo',
    '--no-fail-on-blockers'
  ]);

  assert.equal(parsed.successReportPath, 'success.json');
  assert.equal(parsed.feedbackReportPath, 'feedback.json');
  assert.equal(parsed.templateAgentVerificationReportPath, 'template-agent-verification-report.json');
  assert.equal(parsed.manifestReportPath, 'manifest.json');
  assert.equal(parsed.viHistoryLv32ShadowProofReceiptPath, 'vi-history-lv32-shadow-proof-receipt.json');
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
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
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

test('runDownstreamPromotionScorecard ingests an optional LV32 shadow proof receipt when manifest supplies it', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-lv32-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const receiptPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'vi-history-lv32-shadow-proof-receipt.json');
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
    iteration: {
      label: 'supported template proof for compare 12345678',
      ref: 'develop:12345678',
      headSha: '1234567890abcdef1234567890abcdef12345678'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 19,
      executionMode: 'hosted-first',
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        ref: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'hosted-github-actions',
        containerImage: null,
        generatedConsumerWorkspaceRoot: null,
        laneId: 'supported-template-proof',
        agentId: 'compare-monitoring-mode',
        fundingWindowId: null
      }
    },
    authorityProjection: {
      source: 'supported-template-proof',
      supportedRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork'
    },
    goals: {
      maxVerificationLagIterations: 1,
      maxHostedDurationMinutes: 30,
      requireMachineReadableRecommendation: true
    },
    metrics: {
      targetSlotCount: 20,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 19,
      durationWithinGoal: null,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(receiptPath, {
    schema: 'priority/vi-history-lv32-shadow-proof-receipt@v1',
    generatedAt: '2026-03-25T12:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    sourceCommitSha: '1234567890abcdef1234567890abcdef12345678',
    lane: { id: 'vi-history-scenarios-windows-lv32' },
    runner: {
      name: 'self-hosted-windows-lv32',
      requiredLabels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'],
      actualLabels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'],
      labelsMatched: true
    },
    headless: { required: true, enforced: true, executionMode: 'labview-cli-headless' },
    hostPlane: {
      status: 'ready',
      native32Status: 'ready',
      reportPath: 'tests/results/_agent/host-planes/labview-2026-host-plane-report.json',
      labviewPath: 'C:/Program Files (x86)/National Instruments/LabVIEW 2026/LabVIEW.exe',
      cliPath: 'C:/Program Files/National Instruments/LabVIEW 2026/LabVIEWCLI.exe',
      comparePath: 'C:/Program Files (x86)/National Instruments/Shared/LVCompare/LVCompare.exe'
    },
    verification: {
      status: 'pass',
      runUrl: 'https://example.invalid/runs/17',
      summaryPath: 'tests/results/_agent/vi-history/compare-summary.json',
      reportPath: 'tests/results/_agent/promotion/vi-history-lv32-shadow-proof-receipt.json'
    }
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
    inputs: {
      compareviToolsRelease: 'v0.6.3-tools.14',
      compareviHistoryRelease: 'v1.3.24',
      scenarioPackIdentity: 'scenario-pack@v1',
      cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1',
      viHistoryLv32ShadowProofReceipt: {
        path: receiptPath,
        sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      }
    }
  });

  const result = runDownstreamPromotionScorecard({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    viHistoryLv32ShadowProofReceiptPath: receiptPath,
    manifestReportPath,
    outputPath: path.join(tmpDir, 'scorecard.json')
  });

  assert.equal(result.report.gates.viHistoryLv32ShadowProofReceipt.status, 'pass');
  assert.equal(result.report.gates.viHistoryLv32ShadowProofReceipt.sourceCommitMatched, true);
  assert.equal(result.report.summary.provenance.viHistoryLv32ShadowProofReceiptStatus, 'pass');
});

test('runDownstreamPromotionScorecard fails closed when LV32 shadow proof receipt is present without manifest provenance', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-lv32-provenance-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const receiptPath = path.join(
    tmpDir,
    'tests',
    'results',
    '_agent',
    'promotion',
    'vi-history-lv32-shadow-proof-receipt.json'
  );
  const outputPath = path.join(tmpDir, 'downstream-develop-promotion-scorecard.json');

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
    iteration: {
      label: 'supported template proof for compare 12345678',
      ref: 'develop:12345678',
      headSha: '1234567890abcdef1234567890abcdef12345678'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 19,
      executionMode: 'hosted-first',
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        ref: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'hosted-github-actions',
        containerImage: null,
        generatedConsumerWorkspaceRoot: null,
        laneId: 'supported-template-proof',
        agentId: 'compare-monitoring-mode',
        fundingWindowId: null
      }
    },
    authorityProjection: {
      source: 'supported-template-proof',
      supportedRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork'
    },
    goals: {
      maxVerificationLagIterations: 1,
      maxHostedDurationMinutes: 30,
      requireMachineReadableRecommendation: true
    },
    metrics: {
      targetSlotCount: 20,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 19,
      durationWithinGoal: null,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(receiptPath, {
    schema: 'priority/vi-history-lv32-shadow-proof-receipt@v1',
    generatedAt: '2026-03-25T12:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    sourceCommitSha: '1234567890abcdef1234567890abcdef12345678',
    lane: { id: 'vi-history-scenarios-windows-lv32' },
    runner: {
      name: 'self-hosted-windows-lv32',
      requiredLabels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'],
      actualLabels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'],
      labelsMatched: true
    },
    headless: { required: true, enforced: true, executionMode: 'labview-cli-headless' },
    hostPlane: {
      status: 'ready',
      native32Status: 'ready',
      reportPath: 'tests/results/_agent/host-planes/labview-2026-host-plane-report.json',
      labviewPath: 'C:/Program Files (x86)/National Instruments/LabVIEW 2026/LabVIEW.exe',
      cliPath: 'C:/Program Files/National Instruments/LabVIEW 2026/LabVIEWCLI.exe',
      comparePath: 'C:/Program Files (x86)/National Instruments/Shared/LVCompare/LVCompare.exe'
    },
    verification: {
      status: 'pass',
      runUrl: 'https://example.invalid/runs/1',
      summaryPath: 'tests/results/_agent/vi-history/compare-summary.json',
      reportPath: 'tests/results/_agent/promotion/vi-history-lv32-shadow-proof-receipt.json'
    }
  });

  const result = runDownstreamPromotionScorecard({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    viHistoryLv32ShadowProofReceiptPath: receiptPath,
    outputPath
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.summary.status, 'fail');
  assert.equal(result.report.gates.viHistoryLv32ShadowProofReceipt.expectedContextPresent, false);
  assert.ok(
    result.report.summary.blockers.some((entry) => entry.code === 'vi-history-lv32-shadow-proof-manifest-provenance')
  );
});

test('runDownstreamPromotionScorecard accepts monitoring-derived template verification authority', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-supported-proof-'));
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
    iteration: {
      label: 'supported template proof for compare 12345678',
      ref: 'develop:12345678',
      headSha: '1234567890abcdef1234567890abcdef12345678'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 19,
      executionMode: 'hosted-first',
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        ref: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'hosted-github-actions',
        containerImage: null,
        generatedConsumerWorkspaceRoot: null,
        laneId: 'supported-template-proof',
        agentId: 'compare-monitoring-mode',
        fundingWindowId: null
      }
    },
    authorityProjection: {
      source: 'supported-template-proof',
      supportedRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork'
    },
    goals: {
      maxVerificationLagIterations: 1,
      maxHostedDurationMinutes: 30,
      requireMachineReadableRecommendation: true
    },
    metrics: {
      targetSlotCount: 20,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 19,
      durationWithinGoal: null,
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
    inputs: { cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@develop' }
  });

  const result = runDownstreamPromotionScorecard({
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    manifestReportPath,
    failOnBlockers: true
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.gates.templateAgentVerificationReport.templateRef, 'c3ae46c2b0a02b514b4b08d426302953a87243bc');
  assert.equal(result.report.gates.templateAgentVerificationReport.verificationRunUrl, 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307');
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
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
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

test('runDownstreamPromotionScorecard fails closed when LV32 shadow proof receipt mismatches the promoted source commit', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-lv32-mismatch-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const receiptPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'vi-history-lv32-shadow-proof-receipt.json');
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
    iteration: {
      label: 'supported template proof for compare 12345678',
      ref: 'develop:12345678',
      headSha: '1234567890abcdef1234567890abcdef12345678'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 19,
      executionMode: 'hosted-first',
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        ref: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'hosted-github-actions',
        containerImage: null,
        generatedConsumerWorkspaceRoot: null,
        laneId: 'supported-template-proof',
        agentId: 'compare-monitoring-mode',
        fundingWindowId: null
      }
    },
    authorityProjection: {
      source: 'supported-template-proof',
      supportedRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork'
    },
    goals: {
      maxVerificationLagIterations: 1,
      maxHostedDurationMinutes: 30,
      requireMachineReadableRecommendation: true
    },
    metrics: {
      targetSlotCount: 20,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 19,
      durationWithinGoal: null,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(receiptPath, {
    schema: 'priority/vi-history-lv32-shadow-proof-receipt@v1',
    generatedAt: '2026-03-25T12:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    sourceCommitSha: 'ffffffffffffffffffffffffffffffffffffffff',
    lane: { id: 'vi-history-scenarios-windows-lv32' },
    runner: {
      name: 'self-hosted-windows-lv32',
      requiredLabels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'],
      actualLabels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'],
      labelsMatched: true
    },
    headless: { required: true, enforced: true, executionMode: 'labview-cli-headless' },
    hostPlane: {
      status: 'ready',
      native32Status: 'ready',
      reportPath: 'tests/results/_agent/host-planes/labview-2026-host-plane-report.json',
      labviewPath: 'C:/Program Files (x86)/National Instruments/LabVIEW 2026/LabVIEW.exe',
      cliPath: 'C:/Program Files/National Instruments/LabVIEW 2026/LabVIEWCLI.exe',
      comparePath: 'C:/Program Files (x86)/National Instruments/Shared/LVCompare/LVCompare.exe'
    },
    verification: {
      status: 'pass',
      runUrl: 'https://example.invalid/runs/18',
      summaryPath: 'tests/results/_agent/vi-history/compare-summary.json',
      reportPath: 'tests/results/_agent/promotion/vi-history-lv32-shadow-proof-receipt.json'
    }
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
    inputs: {
      compareviToolsRelease: 'v0.6.3-tools.14',
      compareviHistoryRelease: 'v1.3.24',
      scenarioPackIdentity: 'scenario-pack@v1',
      cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1',
      viHistoryLv32ShadowProofReceipt: {
        path: receiptPath,
        sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      }
    }
  });

  const result = runDownstreamPromotionScorecard({
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    manifestReportPath,
    failOnBlockers: false
  });

  assert.equal(result.report.summary.status, 'fail');
  assert.equal(result.report.gates.viHistoryLv32ShadowProofReceipt.status, 'fail');
  assert.equal(result.report.gates.viHistoryLv32ShadowProofReceipt.sourceCommitMatched, false);
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'vi-history-lv32-shadow-proof-contract'));
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'vi-history-lv32-shadow-proof-source-mismatch'));
});

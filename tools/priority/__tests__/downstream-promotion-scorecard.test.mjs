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
    '--manifest-report',
    'manifest.json',
    '--repo',
    'example/repo',
    '--no-fail-on-blockers'
  ]);

  assert.equal(parsed.successReportPath, 'success.json');
  assert.equal(parsed.feedbackReportPath, 'feedback.json');
  assert.equal(parsed.manifestReportPath, 'manifest.json');
  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.failOnBlockers, false);
});

test('evaluateDownstreamPromotionScorecard reports blockers deterministically', () => {
  const pass = evaluateDownstreamPromotionScorecard({
    successReport: { exists: true, error: null },
    feedbackReport: { exists: true, error: null },
    manifestReport: { exists: false, error: null },
    successGate: { status: 'pass', totalBlockers: 0 },
    feedbackGate: { status: 'pass', executionStatus: 'pass' },
    manifestGate: { status: 'missing' }
  });
  assert.equal(pass.status, 'pass');
  assert.equal(pass.blockerCount, 0);

  const fail = evaluateDownstreamPromotionScorecard({
    successReport: { exists: false, error: null },
    feedbackReport: { exists: true, error: 'bad json' },
    manifestReport: { exists: true, error: 'bad json' },
    successGate: { status: 'fail', totalBlockers: 2 },
    feedbackGate: { status: 'fail', executionStatus: 'fail' },
    manifestGate: { status: 'fail' }
  });

  assert.equal(fail.status, 'fail');
  assert.ok(fail.blockers.some((entry) => entry.code === 'success-report-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'feedback-report-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'downstream-blockers'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'feedback-execution'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'manifest-report-unreadable'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'manifest-contract'));
});

test('runDownstreamPromotionScorecard projects manifest provenance when present', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
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
      cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.0'
    }
  });

  const result = runDownstreamPromotionScorecard({
    repo: 'example/repo',
    successReportPath,
    feedbackReportPath,
    manifestReportPath,
    outputPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.gates.successReport.summaryStatus, 'warn');
  assert.equal(result.report.gates.manifestReport.status, 'pass');
  assert.equal(result.report.summary.metrics.totalWarnings, 3);
  assert.equal(result.report.summary.provenance.compareviToolsRelease, 'v0.6.3-tools.14');
  assert.equal(result.report.summary.provenance.cookiecutterTemplateIdentity, 'LabviewGitHubCiTemplate@v0.1.0');
});

test('runDownstreamPromotionScorecard fails closed when onboarding blockers remain', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-fail-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');

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

  const result = runDownstreamPromotionScorecard({
    successReportPath,
    feedbackReportPath,
    failOnBlockers: true
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.summary.status, 'fail');
  assert.ok(result.report.summary.blockers.some((entry) => entry.code === 'downstream-blockers'));
});

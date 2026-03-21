#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { evaluateReleaseScorecard, parseArgs, runReleaseScorecard } from '../release-scorecard.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs enforces required flags and supports signed-tag options', () => {
  const parsed = parseArgs([
    'node',
    'release-scorecard.mjs',
    '--stream',
    'comparevi-cli',
    '--channel',
    'stable',
    '--version',
    '0.6.4',
    '--ledger',
    'a.json',
    '--slo',
    'b.json',
    '--rollback',
    'c.json',
    '--trust',
    'd.json',
    '--downstream-proving-selection',
    'selection.json',
    '--downstream-promotion',
    'downstream.json',
    '--tag-ref',
    'v0.6.4',
    '--require-downstream-proving',
    '--require-signed-tag',
    '--no-fail-on-blockers'
  ]);

  assert.equal(parsed.stream, 'comparevi-cli');
  assert.equal(parsed.channel, 'stable');
  assert.equal(parsed.version, '0.6.4');
  assert.equal(parsed.ledgerPath, 'a.json');
  assert.equal(parsed.sloPath, 'b.json');
  assert.equal(parsed.rollbackPath, 'c.json');
  assert.equal(parsed.trustPath, 'd.json');
  assert.equal(parsed.downstreamProvingSelectionPath, 'selection.json');
  assert.equal(parsed.downstreamPromotionPath, 'downstream.json');
  assert.equal(parsed.tagRef, 'v0.6.4');
  assert.equal(parsed.requireDownstreamProving, true);
  assert.equal(parsed.requireSignedTag, true);
  assert.equal(parsed.failOnBlockers, false);
});

test('evaluateReleaseScorecard reports blockers deterministically', () => {
  const pass = evaluateReleaseScorecard({
    ledger: { exists: true, error: null },
    slo: { exists: true, error: null },
    rollback: { exists: true, error: null },
    downstreamProvingSelection: { exists: true, error: null },
    downstreamPromotion: { exists: true, error: null },
    promotion: { status: 'pass' },
    sloGate: { status: 'pass', breachCount: 0, blockerCount: 0, source: 'promotion-gate', blockers: [] },
    rollbackGate: { status: 'pass' },
    trustGate: { status: 'pass' },
    downstreamProvingSelectionGate: { status: 'pass', reason: null },
    downstreamPromotionGate: { status: 'pass' },
    downstreamProvingSelectionProvided: true,
    downstreamPromotionProvided: true,
    requireDownstreamProving: true,
    trustProvided: true,
    requireSignedTag: true,
    signedTag: { status: 'pass' }
  });
  assert.equal(pass.status, 'pass');
  assert.equal(pass.blockerCount, 0);

  const fail = evaluateReleaseScorecard({
    ledger: { exists: true, error: null },
    slo: { exists: false, error: null },
    rollback: { exists: true, error: 'bad json' },
    downstreamProvingSelection: { exists: false, error: null },
    downstreamPromotion: { exists: false, error: null },
    promotion: { status: 'fail' },
    sloGate: { status: 'fail', breachCount: 2, blockerCount: 1, source: 'promotion-gate', blockers: [] },
    rollbackGate: { status: 'fail' },
    trustGate: { status: 'fail' },
    downstreamProvingSelectionGate: { status: 'missing', reason: 'selectionStatus=missing' },
    downstreamPromotionGate: { status: 'missing' },
    downstreamProvingSelectionProvided: true,
    downstreamPromotionProvided: true,
    requireDownstreamProving: true,
    trustProvided: true,
    requireSignedTag: true,
    signedTag: { status: 'fail' }
  });
  assert.equal(fail.status, 'fail');
  assert.ok(fail.blockers.some((entry) => entry.code === 'slo-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'rollback-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'promotion-gate'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'slo-breach'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'downstream-proving-selection-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'downstream-proving-selection-gate'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'downstream-promotion-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'downstream-promotion-gate'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'signed-tag'));
});

test('runReleaseScorecard creates pass/fail scorecards and exit codes', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'release-scorecard-'));
  const ledgerPath = path.join(tmpDir, 'ledger.json');
  const sloPath = path.join(tmpDir, 'slo.json');
  const rollbackPath = path.join(tmpDir, 'rollback.json');
  const trustPath = path.join(tmpDir, 'trust.json');
  const downstreamProvingSelectionPath = path.join(tmpDir, 'downstream-proving-selection.json');
  const downstreamPromotionPath = path.join(tmpDir, 'downstream-promotion.json');

  writeJson(ledgerPath, {
    gate: { status: 'pass', reason: 'ok' }
  });
  writeJson(sloPath, {
    breaches: [],
    promotionGate: {
      status: 'pass',
      blockerCount: 0,
      blockers: []
    }
  });
  writeJson(rollbackPath, {
    summary: { status: 'pass', pausePromotion: false }
  });
  writeJson(trustPath, {
    summary: { status: 'pass', failureCount: 0 },
    tagSignature: { verified: true, reason: 'valid' }
  });
  writeJson(downstreamPromotionPath, {
    schema: 'priority/downstream-promotion-scorecard@v1',
    gates: {
      feedbackReport: {
        downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
      }
    },
    summary: {
      status: 'pass',
      blockerCount: 0,
      provenance: {
        sourceCommitSha: '1234567890abcdef1234567890abcdef12345678'
      }
    }
  });
  writeJson(downstreamProvingSelectionPath, {
    schema: 'priority/downstream-proving-selection@v1',
    generatedAt: '2026-03-21T11:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    workflow: 'downstream-promotion.yml',
    branch: 'develop',
    expectedSourceSha: '1234567890abcdef1234567890abcdef12345678',
    artifactPrefix: 'downstream-promotion-',
    status: 'pass',
    selected: {
      run: {
        id: 4201,
        name: 'Downstream Promotion',
        url: 'https://example.test/runs/4201',
        headBranch: 'develop',
        headSha: '1234567890abcdef1234567890abcdef12345678',
        status: 'completed',
        conclusion: 'success',
        createdAt: '2026-03-21T10:00:00.000Z',
        updatedAt: '2026-03-21T10:05:00.000Z'
      },
      artifactName: 'downstream-promotion-4201',
      downloadStatus: 'pass',
      downloadReportPath: path.join(tmpDir, 'download-report.json'),
      scorecardPath: downstreamPromotionPath,
      scorecardStatus: 'pass',
      scorecard: {
        status: 'pass',
        schema: 'priority/downstream-promotion-scorecard@v1',
        summaryStatus: 'pass',
        sourceCommitSha: '1234567890abcdef1234567890abcdef12345678',
        matchedExpectedSourceSha: true,
        targetBranch: 'downstream/develop',
        manifestStatus: 'pass',
        blockerCount: 0,
        downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
      },
      scorecardError: null
    },
    candidates: []
  });

  const passOutput = path.join(tmpDir, 'pass-scorecard.json');
  const passResult = await runReleaseScorecard({
    repo: 'example/repo',
    stream: 'comparevi-cli',
    channel: 'stable',
    version: '0.6.4',
    tagRef: 'v0.6.4',
    requireSignedTag: true,
    ledgerPath,
    sloPath,
    rollbackPath,
    trustPath,
    downstreamProvingSelectionPath,
    downstreamPromotionPath,
    requireDownstreamProving: true,
    outputPath: passOutput
  });

  assert.equal(passResult.exitCode, 0);
  assert.equal(passResult.report.summary.status, 'pass');
  assert.equal(passResult.report.gates.signedTag.status, 'pass');
  assert.equal(passResult.report.gates.downstreamProvingSelection.status, 'pass');
  assert.equal(passResult.report.gates.downstreamProvingSelection.selectedRunId, 4201);
  assert.equal(passResult.report.gates.downstreamProvingSelection.selectedScorecardMatchesInput, true);
  assert.equal(passResult.report.gates.downstreamPromotion.status, 'pass');
  assert.equal(passResult.report.summary.blockerCount, 0);

  writeJson(sloPath, {
    breaches: [{ code: 'failure-rate', message: 'too high' }],
    promotionGate: {
      status: 'pass',
      blockerCount: 0,
      blockers: []
    }
  });
  const historicalOnlyOutput = path.join(tmpDir, 'historical-only-scorecard.json');
  const historicalOnly = await runReleaseScorecard({
    repo: 'example/repo',
    stream: 'comparevi-cli',
    channel: 'stable',
    tagRef: 'v0.6.4',
    requireSignedTag: true,
    ledgerPath,
    sloPath,
    rollbackPath,
    trustPath,
    outputPath: historicalOnlyOutput,
    failOnBlockers: true
  });

  assert.equal(historicalOnly.exitCode, 0);
  assert.equal(historicalOnly.report.summary.status, 'pass');
  assert.equal(historicalOnly.report.gates.slo.status, 'pass');
  assert.equal(historicalOnly.report.gates.downstreamProvingSelection.status, 'not-applicable');
  assert.equal(historicalOnly.report.gates.downstreamPromotion.status, 'not-applicable');

  writeJson(sloPath, {
    breaches: [{ code: 'gate-regressions', message: 'historical debt still high' }],
    promotionGate: {
      status: 'fail',
      blockerCount: 1,
      blockers: [{ code: 'stale-budget', workflow: 'release.yml', message: 'release.yml staleHours 300 exceeds threshold 168' }]
    }
  });
  const failOutput = path.join(tmpDir, 'fail-scorecard.json');
  const failResult = await runReleaseScorecard({
    repo: 'example/repo',
    stream: 'comparevi-cli',
    channel: 'stable',
    tagRef: 'v0.6.4',
    requireSignedTag: true,
    ledgerPath,
    sloPath,
    rollbackPath,
    trustPath,
    downstreamProvingSelectionPath,
    downstreamPromotionPath,
    requireDownstreamProving: true,
    outputPath: failOutput,
    failOnBlockers: true
  });

  assert.equal(failResult.exitCode, 1);
  assert.equal(failResult.report.summary.status, 'fail');
  assert.ok(failResult.report.summary.blockers.some((entry) => entry.code === 'slo-breach'));

  const passAgainSloPath = path.join(tmpDir, 'slo-pass.json');
  writeJson(passAgainSloPath, {
    breaches: [],
    promotionGate: {
      status: 'pass',
      blockerCount: 0,
      blockers: []
    }
  });
  const missingDownstreamOutput = path.join(tmpDir, 'missing-downstream-scorecard.json');
  const missingDownstreamResult = await runReleaseScorecard({
    repo: 'example/repo',
    stream: 'comparevi-cli',
    channel: 'stable',
    tagRef: 'v0.6.4',
    requireSignedTag: true,
    requireDownstreamProving: true,
    ledgerPath,
    sloPath: passAgainSloPath,
    rollbackPath,
    trustPath,
    downstreamProvingSelectionPath: path.join(tmpDir, 'missing-downstream-proving-selection.json'),
    downstreamPromotionPath: path.join(tmpDir, 'missing-downstream-promotion.json'),
    outputPath: missingDownstreamOutput,
    failOnBlockers: true
  });

  assert.equal(missingDownstreamResult.exitCode, 1);
  assert.equal(missingDownstreamResult.report.gates.downstreamProvingSelection.status, 'missing');
  assert.equal(missingDownstreamResult.report.gates.downstreamPromotion.status, 'missing');
  assert.ok(
    missingDownstreamResult.report.summary.blockers.some((entry) => entry.code === 'downstream-proving-selection-missing')
  );
  assert.ok(
    missingDownstreamResult.report.summary.blockers.some((entry) => entry.code === 'downstream-promotion-missing')
  );
});

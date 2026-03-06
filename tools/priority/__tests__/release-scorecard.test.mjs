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
    '--tag-ref',
    'v0.6.4',
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
  assert.equal(parsed.tagRef, 'v0.6.4');
  assert.equal(parsed.requireSignedTag, true);
  assert.equal(parsed.failOnBlockers, false);
});

test('evaluateReleaseScorecard reports blockers deterministically', () => {
  const pass = evaluateReleaseScorecard({
    ledger: { exists: true, error: null },
    slo: { exists: true, error: null },
    rollback: { exists: true, error: null },
    promotion: { status: 'pass' },
    sloGate: { status: 'pass', breachCount: 0 },
    rollbackGate: { status: 'pass' },
    trustGate: { status: 'pass' },
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
    promotion: { status: 'fail' },
    sloGate: { status: 'fail', breachCount: 2 },
    rollbackGate: { status: 'fail' },
    trustGate: { status: 'fail' },
    trustProvided: true,
    requireSignedTag: true,
    signedTag: { status: 'fail' }
  });
  assert.equal(fail.status, 'fail');
  assert.ok(fail.blockers.some((entry) => entry.code === 'slo-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'rollback-missing'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'promotion-gate'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'slo-breach'));
  assert.ok(fail.blockers.some((entry) => entry.code === 'signed-tag'));
});

test('runReleaseScorecard creates pass/fail scorecards and exit codes', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'release-scorecard-'));
  const ledgerPath = path.join(tmpDir, 'ledger.json');
  const sloPath = path.join(tmpDir, 'slo.json');
  const rollbackPath = path.join(tmpDir, 'rollback.json');
  const trustPath = path.join(tmpDir, 'trust.json');

  writeJson(ledgerPath, {
    gate: { status: 'pass', reason: 'ok' }
  });
  writeJson(sloPath, {
    breaches: []
  });
  writeJson(rollbackPath, {
    summary: { status: 'pass', pausePromotion: false }
  });
  writeJson(trustPath, {
    summary: { status: 'pass', failureCount: 0 },
    tagSignature: { verified: true, reason: 'valid' }
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
    outputPath: passOutput
  });

  assert.equal(passResult.exitCode, 0);
  assert.equal(passResult.report.summary.status, 'pass');
  assert.equal(passResult.report.gates.signedTag.status, 'pass');
  assert.equal(passResult.report.summary.blockerCount, 0);

  writeJson(sloPath, {
    breaches: [{ code: 'failure-rate', message: 'too high' }]
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
    outputPath: failOutput,
    failOnBlockers: true
  });

  assert.equal(failResult.exitCode, 1);
  assert.equal(failResult.report.summary.status, 'fail');
  assert.ok(failResult.report.summary.blockers.some((entry) => entry.code === 'slo-breach'));
});


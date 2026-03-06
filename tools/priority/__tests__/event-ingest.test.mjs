#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  computeIncidentFingerprint,
  normalizeDeploymentStateEvent,
  normalizeRequiredCheckDriftEvent,
  normalizeWorkflowRunEvent,
  parseArgs,
  runEventIngest
} from '../event-ingest.mjs';

test('parseArgs supports source type, overrides, and dry-run', () => {
  const parsed = parseArgs([
    'node',
    'event-ingest.mjs',
    '--source-type',
    'workflow-run',
    '--input',
    'input.json',
    '--report',
    'report.json',
    '--class',
    'custom-class',
    '--severity',
    'high',
    '--signature',
    'workflow:failure',
    '--dry-run'
  ]);

  assert.equal(parsed.sourceType, 'workflow-run');
  assert.equal(parsed.inputPath, 'input.json');
  assert.equal(parsed.reportPath, 'report.json');
  assert.equal(parsed.classOverride, 'custom-class');
  assert.equal(parsed.severityOverride, 'high');
  assert.equal(parsed.signatureOverride, 'workflow:failure');
  assert.equal(parsed.dryRun, true);
});

test('computeIncidentFingerprint is deterministic for same inputs', () => {
  const a = computeIncidentFingerprint({
    sourceType: 'workflow-run',
    incidentClass: 'workflow-run-failure',
    branch: 'develop',
    sha: 'abc123',
    signature: 'validate:failure'
  });
  const b = computeIncidentFingerprint({
    sourceType: 'workflow-run',
    incidentClass: 'workflow-run-failure',
    branch: 'develop',
    sha: 'abc123',
    signature: 'validate:failure'
  });

  assert.equal(a.key, b.key);
  assert.equal(a.sha256, b.sha256);
});

test('normalizeWorkflowRunEvent maps failure conclusions to incident metadata', () => {
  const event = normalizeWorkflowRunEvent({
    name: 'Validate',
    conclusion: 'failure',
    status: 'completed',
    repository: { full_name: 'example/repo' },
    head_branch: 'develop',
    head_sha: 'abc123',
    id: 42
  });

  assert.equal(event.sourceType, 'workflow-run');
  assert.equal(event.incidentClass, 'workflow-run-failure');
  assert.equal(event.severity, 'high');
  assert.equal(event.repository, 'example/repo');
  assert.equal(event.branch, 'develop');
  assert.equal(event.sha, 'abc123');
  assert.deepEqual(event.suggestedLabels, ['ci']);
});

test('normalizeRequiredCheckDriftEvent derives severity from drift counts and result', () => {
  const event = normalizeRequiredCheckDriftEvent({
    repository: 'example/repo',
    result: 'fail',
    summary: {
      totalDiffCount: 2,
      branchDiffCount: 1,
      rulesetDiffCount: 1
    }
  });

  assert.equal(event.sourceType, 'required-check-drift');
  assert.equal(event.incidentClass, 'required-check-drift');
  assert.equal(event.severity, 'high');
  assert.deepEqual(event.suggestedLabels, ['ci', 'governance']);
});

test('normalizeDeploymentStateEvent maps issues to anomaly with governance labels', () => {
  const event = normalizeDeploymentStateEvent({
    repository: 'example/repo',
    environment: 'validation',
    result: 'fail',
    issues: ['no-active-deployment-found'],
    runId: '1001'
  });

  assert.equal(event.sourceType, 'deployment-state');
  assert.equal(event.incidentClass, 'deployment-state-anomaly');
  assert.equal(event.severity, 'high');
  assert.deepEqual(event.suggestedLabels, ['ci', 'governance']);
});

test('runEventIngest writes deterministic report with labels and flags coverage', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'event-ingest-'));
  const inputPath = path.join(tmpDir, 'input.json');
  const reportPath = path.join(tmpDir, 'report.json');
  const payload = {
    name: 'Validate',
    conclusion: 'failure',
    status: 'completed',
    repository: { full_name: 'example/repo' },
    head_branch: 'develop',
    head_sha: 'abc123',
    id: 42
  };
  fs.writeFileSync(inputPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

  const result = await runEventIngest({
    argv: [
      'node',
      'event-ingest.mjs',
      '--source-type',
      'workflow-run',
      '--input',
      inputPath,
      '--report',
      reportPath,
      '--dry-run'
    ],
    now: new Date('2026-03-06T21:05:00Z')
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.flags.dryRun, true);
  assert.equal(result.report.flags.classOverride, false);
  assert.equal(result.report.event.schema, 'incident-event@v1');
  assert.deepEqual(result.report.event.suggestedLabels, ['ci']);

  const persisted = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(persisted.schema, 'priority/event-ingest-report@v1');
  assert.equal(persisted.event.fingerprint, result.report.event.fingerprint);
  assert.equal(persisted.event.inputDigest, result.report.event.inputDigest);
});

test('runEventIngest writes fail report when input is invalid', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'event-ingest-fail-'));
  const inputPath = path.join(tmpDir, 'bad.json');
  const reportPath = path.join(tmpDir, 'report.json');
  fs.writeFileSync(inputPath, '{invalid json', 'utf8');

  const result = await runEventIngest({
    argv: [
      'node',
      'event-ingest.mjs',
      '--source-type',
      'incident-event',
      '--input',
      inputPath,
      '--report',
      reportPath
    ],
    now: new Date('2026-03-06T21:06:00Z')
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.event, null);
  assert.equal(result.report.flags.dryRun, false);
  assert.ok(result.report.errors.length > 0);
});

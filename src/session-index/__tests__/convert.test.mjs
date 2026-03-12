import test from 'node:test';
import assert from 'node:assert/strict';
import { convertSessionIndexV1ToV2 } from '../../../dist/src/session-index/convert.js';

test('convertSessionIndexV1ToV2 maps runtime, branch-protection, summary, and artifacts from v1', () => {
  const payload = {
    schema: 'session-index/v1',
    schemaVersion: '1.0.0',
    generatedAtUtc: '2026-03-11T00:00:00.000Z',
    resultsDir: 'tests/results/sessionindex',
    includeIntegration: false,
    integrationMode: null,
    integrationSource: null,
    status: 'ok',
    files: {
      pesterSummaryJson: 'tests/results/sessionindex/pester-summary.json',
      compareReportHtml: 'tests/results/sessionindex/compare-report.html'
    },
    summary: {
      total: 3,
      passed: 3,
      failed: 0,
      errors: 0,
      skipped: 0,
      duration_s: 12.5
    },
    runContext: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      ref: 'refs/heads/develop',
      commitSha: '1234567890abcdef1234567890abcdef12345678',
      workflow: 'Validate',
      runId: '42',
      runAttempt: '3',
      job: 'session-index',
      runner: 'GitHub Actions 1',
      runnerOS: 'Linux',
      runnerArch: 'X64',
      runnerImageOS: 'ubuntu24',
      runnerImageVersion: '20260301.1',
      runnerLabels: ['ubuntu-latest']
    },
    branchProtection: {
      contract: {
        id: 'bp-verify',
        version: '1',
        issue: 118,
        mappingPath: 'tools/policy/branch-required-checks.json',
        mappingDigest: 'abc123'
      },
      branch: 'develop',
      expected: ['lint', 'fixtures'],
      produced: ['lint', 'fixtures'],
      actual: {
        status: 'available',
        contexts: ['lint', 'fixtures']
      },
      result: {
        status: 'ok',
        reason: 'aligned'
      },
      notes: ['aligned'],
      tags: ['bp-verify']
    },
    watchers: {
      rest: {
        schema: 'ci-watch/rest-v1',
        status: 'completed',
        jobs: []
      }
    }
  };

  const converted = convertSessionIndexV1ToV2(payload, {
    v1Path: 'tests/results/sessionindex/session-index.json',
    eventName: 'pull_request'
  });

  assert.equal(converted.schema, 'session-index/v2');
  assert.equal(converted.run.workflow, 'Validate');
  assert.equal(converted.run.job, 'session-index');
  assert.equal(converted.run.branch, 'develop');
  assert.equal(converted.run.commit, '1234567890abcdef1234567890abcdef12345678');
  assert.equal(converted.run.repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(converted.run.id, '42');
  assert.equal(converted.run.attempt, 3);
  assert.equal(converted.run.trigger?.kind, 'pull_request');
  assert.equal(converted.environment?.runnerImage, 'ubuntu24:20260301.1');
  assert.equal(converted.branchProtection?.status, 'ok');
  assert.deepEqual(converted.branchProtection?.expected, ['lint', 'fixtures']);
  assert.deepEqual(converted.branchProtection?.actual, ['lint', 'fixtures']);
  assert.equal(converted.tests?.summary?.durationSeconds, 12.5);
  assert.ok((converted.artifacts ?? []).find((artifact) => artifact.name === 'session-index-v1'));
  assert.ok((converted.artifacts ?? []).find((artifact) => artifact.name === 'compareReportHtml' && artifact.kind === 'report'));
  assert.equal(converted.extra?.resultsDir, 'tests/results/sessionindex');
  assert.equal(converted.extra?.status, 'ok');
  assert.deepEqual(converted.extra?.watchers, payload.watchers);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_DESTINATION_ROOT,
  DEFAULT_DOWNLOAD_REPORT_PATH,
  DEFAULT_REPORT_PATH,
  buildProjectionSnapshot,
  clearProjectionOutputs,
  parseArgs,
  projectSessionIndexV2PromotionDecision,
} from '../project-session-index-v2-promotion-decision.mjs';

const repoRoot = path.resolve('C:/repo/compare-vi-cli-action');

test('parseArgs accepts repo and branch overrides', () => {
  const options = parseArgs(['node', 'project-session-index-v2-promotion-decision.mjs', '--repo', 'owner/repo', '--branch', 'main']);
  assert.equal(options.repo, 'owner/repo');
  assert.equal(options.branch, 'main');
  assert.equal(options.help, false);
});

test('projectSessionIndexV2PromotionDecision routes the helper into the standing issue bundle', async () => {
  const calls = [];
  const logs = [];
  const result = await projectSessionIndexV2PromotionDecision({
    argv: ['node', 'project-session-index-v2-promotion-decision.mjs', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action'],
    repoRoot,
    logFn: (line) => logs.push(line),
    runSessionIndexV2PromotionDecisionFn: async (options) => {
      calls.push(options);
      return {
        exitCode: 1,
        reportPath: path.join(repoRoot, DEFAULT_REPORT_PATH),
        report: {
          generatedAt: '2026-03-15T12:30:00.000Z',
          status: 'fail',
          selection: {
            mode: 'latest-completed-run',
            status: 'fail',
            failureClass: 'run-not-found',
          },
          sourceRun: null,
          artifact: {
            downloadReportPath: path.join(repoRoot, DEFAULT_DOWNLOAD_REPORT_PATH),
            destinationRoot: path.join(repoRoot, DEFAULT_DESTINATION_ROOT),
          },
          decision: {
            state: 'missing-evidence',
            summary: 'No completed current-head Validate run exists yet.',
          },
        },
      };
    },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].argv, [
    'node',
    'tools/priority/session-index-v2-promotion-decision.mjs',
    '--branch',
    'develop',
    '--out',
    DEFAULT_REPORT_PATH,
    '--download-report',
    DEFAULT_DOWNLOAD_REPORT_PATH,
    '--destination-root',
    DEFAULT_DESTINATION_ROOT,
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  ]);
  assert.equal(result.exitCode, 0);
  assert.equal(result.snapshot.state, 'missing-evidence');
  assert.equal(result.snapshot.status, 'fail');
  assert.equal(result.snapshot.path, 'tests/results/_agent/issue/session-index-v2-promotion-decision.json');
  assert.equal(result.snapshot.downloadReportPath, 'tests/results/_agent/issue/session-index-v2-promotion-decision-download.json');
  assert.equal(result.snapshot.artifactRoot, 'tests/results/_agent/issue/session-index-v2-promotion-decision-artifacts');
  assert.match(logs.join('\n'), /state=missing-evidence status=fail run=none/);
});

test('projectSessionIndexV2PromotionDecision records a projection error when the helper throws', async () => {
  const tmpRepoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-v2-promotion-projection-'));
  const staleReportPath = path.join(tmpRepoRoot, DEFAULT_REPORT_PATH);
  const staleDownloadPath = path.join(tmpRepoRoot, DEFAULT_DOWNLOAD_REPORT_PATH);
  const staleArtifactPath = path.join(tmpRepoRoot, DEFAULT_DESTINATION_ROOT, 'old');
  fs.mkdirSync(path.dirname(staleReportPath), { recursive: true });
  fs.mkdirSync(path.dirname(staleDownloadPath), { recursive: true });
  fs.mkdirSync(staleArtifactPath, { recursive: true });
  fs.writeFileSync(staleReportPath, '{}\n', 'utf8');
  fs.writeFileSync(staleDownloadPath, '{}\n', 'utf8');
  fs.writeFileSync(path.join(staleArtifactPath, 'stale.txt'), 'stale\n', 'utf8');

  const result = await projectSessionIndexV2PromotionDecision({
    argv: ['node', 'project-session-index-v2-promotion-decision.mjs'],
    repoRoot: tmpRepoRoot,
    logFn: () => {},
    runSessionIndexV2PromotionDecisionFn: async () => {
      throw new Error('boom');
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.snapshot.state, 'projection-error');
  assert.equal(result.snapshot.status, 'error');
  assert.match(result.snapshot.summary, /boom/);
  assert.equal(fs.existsSync(staleReportPath), false);
  assert.equal(fs.existsSync(staleDownloadPath), false);
  assert.equal(fs.existsSync(path.join(tmpRepoRoot, DEFAULT_DESTINATION_ROOT)), false);
});

test('buildProjectionSnapshot normalizes helper results into repo-relative issue artifacts', () => {
  const snapshot = buildProjectionSnapshot({
    repoRoot,
    reportPath: path.join(repoRoot, DEFAULT_REPORT_PATH),
    exitCode: 0,
    report: {
      status: 'warn',
      selection: {
        mode: 'latest-completed-run',
        status: 'pass',
        failureClass: null,
      },
      sourceRun: { id: 52 },
      artifact: {
        downloadReportPath: path.join(repoRoot, DEFAULT_DOWNLOAD_REPORT_PATH),
        destinationRoot: path.join(repoRoot, DEFAULT_DESTINATION_ROOT),
      },
      decision: {
        state: 'hold-burn-in',
        summary: 'Burn-in should continue.',
      },
    },
  });

  assert.deepEqual(snapshot, {
    path: 'tests/results/_agent/issue/session-index-v2-promotion-decision.json',
    downloadReportPath: 'tests/results/_agent/issue/session-index-v2-promotion-decision-download.json',
    artifactRoot: 'tests/results/_agent/issue/session-index-v2-promotion-decision-artifacts',
    status: 'warn',
    state: 'hold-burn-in',
    summary: 'Burn-in should continue.',
    selectionMode: 'latest-completed-run',
    selectionStatus: 'pass',
    selectionFailureClass: null,
    sourceRunId: 52,
    exitCode: 0,
  });
});

test('clearProjectionOutputs removes stale issue-bundle artifacts recursively', () => {
  const tmpRepoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-v2-promotion-clear-'));
  const reportPath = path.join(tmpRepoRoot, DEFAULT_REPORT_PATH);
  const downloadReportPath = path.join(tmpRepoRoot, DEFAULT_DOWNLOAD_REPORT_PATH);
  const artifactRoot = path.join(tmpRepoRoot, DEFAULT_DESTINATION_ROOT, '52');
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.mkdirSync(path.dirname(downloadReportPath), { recursive: true });
  fs.mkdirSync(artifactRoot, { recursive: true });
  fs.writeFileSync(reportPath, '{}\n', 'utf8');
  fs.writeFileSync(downloadReportPath, '{}\n', 'utf8');
  fs.writeFileSync(path.join(artifactRoot, 'artifact.json'), '{}\n', 'utf8');

  clearProjectionOutputs(tmpRepoRoot);

  assert.equal(fs.existsSync(reportPath), false);
  assert.equal(fs.existsSync(downloadReportPath), false);
  assert.equal(fs.existsSync(path.join(tmpRepoRoot, DEFAULT_DESTINATION_ROOT)), false);
});

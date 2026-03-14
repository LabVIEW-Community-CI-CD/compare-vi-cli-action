import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'download-run-artifact.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

test('main writes GitHub outputs and step summary for a successful artifact download', async (t) => {
  const { main, parseArgs } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'download-run-artifact-cli-success-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const outputPath = path.join(tmpDir, 'github-output.txt');
  const summaryPath = path.join(tmpDir, 'step-summary.md');
  const reportPath = path.join(tmpDir, 'report.json');
  const logged = [];

  const exitCode = await main(
    [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '22872590273',
      '--artifact',
      'copilot-review-signal-965',
      '--report',
      reportPath,
      '--step-summary',
      summaryPath,
    ],
    {
      env: {
        ...process.env,
        GITHUB_OUTPUT: outputPath,
      },
      logFn(message) {
        logged.push(message);
      },
      downloadNamedArtifactsFn() {
        return {
          reportPath,
          report: {
            status: 'pass',
            discovery: {
              status: 'pass',
              failureClass: null,
            },
            downloads: [],
            summary: {
              requestedArtifactCount: 1,
              availableArtifactCount: 1,
              downloadedCount: 1,
              missingCount: 0,
              failedCount: 0,
            },
          },
        };
      },
    },
  );

  assert.equal(exitCode, 0);
  assert.match(fs.readFileSync(outputPath, 'utf8'), /run-artifact-download-status=pass/);
  assert.match(fs.readFileSync(outputPath, 'utf8'), /run-artifact-download-downloaded-count=1/);
  assert.match(fs.readFileSync(summaryPath, 'utf8'), /### Run Artifact Download/);
  assert.match(fs.readFileSync(summaryPath, 'utf8'), /- report: `.*report\.json`/);
  assert.equal(logged.length, 2);

  const parsed = parseArgs(
    [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '22872590273',
      '--artifact',
      'copilot-review-signal-965',
    ],
    { GITHUB_STEP_SUMMARY: summaryPath },
  );
  assert.equal(parsed.stepSummaryPath, summaryPath);
});

test('main projects failure classes into GitHub outputs and step summary', async (t) => {
  const { main } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'download-run-artifact-cli-fail-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const outputPath = path.join(tmpDir, 'github-output.txt');
  const summaryPath = path.join(tmpDir, 'step-summary.md');
  const reportPath = path.join(tmpDir, 'report.json');

  const exitCode = await main(
    [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '22872590273',
      '--artifact',
      'copilot-review-signal-965',
      '--report',
      reportPath,
      '--step-summary',
      summaryPath,
    ],
    {
      env: {
        ...process.env,
        GITHUB_OUTPUT: outputPath,
      },
      logFn() {},
      downloadNamedArtifactsFn() {
        return {
          reportPath,
          report: {
            status: 'fail',
            discovery: {
              status: 'fail',
              failureClass: 'policy-wrapper-rejected',
            },
            downloads: [
              {
                name: 'copilot-review-signal-965',
                status: 'failed',
                failureClass: 'policy-wrapper-rejected',
              },
            ],
            summary: {
              requestedArtifactCount: 1,
              availableArtifactCount: 1,
              downloadedCount: 0,
              missingCount: 0,
              failedCount: 1,
            },
          },
        };
      },
    },
  );

  assert.equal(exitCode, 1);
  const output = fs.readFileSync(outputPath, 'utf8');
  assert.match(output, /run-artifact-download-status=fail/);
  assert.match(output, /run-artifact-download-discovery-failure-class=policy-wrapper-rejected/);
  assert.match(output, /run-artifact-download-first-failure-class=policy-wrapper-rejected/);
  const summary = fs.readFileSync(summaryPath, 'utf8');
  assert.match(summary, /discovery failure: `policy-wrapper-rejected`/);
  assert.match(summary, /Failures:/);
});

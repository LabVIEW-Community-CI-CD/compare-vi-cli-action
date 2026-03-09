import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'lib', 'run-artifact-download.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function writeFile(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents, 'utf8');
}

test('downloadNamedArtifacts downloads requested artifacts and records relative files', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-success-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const reportPath = path.join(tmpDir, 'report.json');
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: ['copilot-review-signal-965'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath,
    runGhJsonFn() {
      return {
        artifacts: [
          {
            id: 5837347732,
            name: 'copilot-review-signal-965',
            size_in_bytes: 735,
            expired: false,
            created_at: '2026-03-09T20:10:19Z',
            updated_at: '2026-03-09T20:10:19Z',
            workflow_run: {
              id: 22872590273,
              head_branch: 'issue/963-org-owned-fork-pr-helper',
              head_sha: 'e2a81026a76fbd661faac0afaa05e7ed76b21a26',
            },
          },
        ],
      };
    },
    runProcessFn(_command, args) {
      const destinationIndex = args.indexOf('-D');
      const destination = args[destinationIndex + 1];
      writeFile(path.join(destination, 'copilot-review-signal.json'), '{}\n');
      return { status: 0, stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.summary.downloadedCount, 1);
  assert.equal(result.report.summary.failedCount, 0);
  assert.equal(result.report.downloads[0].status, 'downloaded');
  assert.deepEqual(result.report.downloads[0].files, ['copilot-review-signal.json']);
  assert.ok(fs.existsSync(reportPath));
});

test('downloadNamedArtifacts classifies policy wrapper rejections explicitly', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-policy-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: ['copilot-review-signal-965'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      return {
        artifacts: [
          {
            id: 5837347732,
            name: 'copilot-review-signal-965',
            size_in_bytes: 735,
            expired: false,
          },
        ],
      };
    },
    runProcessFn() {
      return {
        status: 1,
        stdout: '',
        stderr: 'Command blocked by local shell policy wrapper.',
        error: null,
      };
    },
  });

  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.summary.failedCount, 1);
  assert.equal(result.report.downloads[0].failureClass, 'policy-wrapper-rejected');
  assert.match(result.report.downloads[0].errorMessage, /policy wrapper/i);
});

test('downloadNamedArtifacts records missing artifact requests without invoking gh run download', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-missing-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  let processCallCount = 0;
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: ['missing-artifact'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      return { artifacts: [] };
    },
    runProcessFn() {
      processCallCount += 1;
      return { status: 0, stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.summary.missingCount, 1);
  assert.equal(result.report.downloads[0].status, 'missing');
  assert.equal(result.report.downloads[0].failureClass, 'artifact-not-found');
  assert.equal(processCallCount, 0);
});

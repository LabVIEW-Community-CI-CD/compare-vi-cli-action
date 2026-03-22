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
  assert.equal(result.report.destinationRoot, path.join(tmpDir, 'artifacts'));
  assert.deepEqual(result.report.destinationRootPolicy, {
    strategy: 'explicit',
    source: 'explicit-destination-root',
    baseRoot: path.join(tmpDir, 'artifacts'),
    relativeRoot: null,
    usesExternalRoot: true,
  });
  assert.equal(result.report.summary.downloadedCount, 1);
  assert.equal(result.report.summary.failedCount, 0);
  assert.equal(result.report.downloads[0].status, 'downloaded');
  assert.deepEqual(result.report.downloads[0].files, ['copilot-review-signal.json']);
  assert.ok(fs.existsSync(reportPath));
});

test('downloadNamedArtifacts resolves relative artifact roots through the deterministic external artifact root policy', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-external-root-'));
  const externalRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'comparevi-external-artifacts-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));
  t.after(() => fs.rmSync(externalRoot, { recursive: true, force: true }));
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: ['copilot-review-signal-965'],
    repoRoot: tmpDir,
    destinationRoot: path.join('tests', 'results', '_agent', 'reviews', 'run-artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    storageRootsPolicy: {
      artifacts: {
        envVar: 'COMPAREVI_BURST_ARTIFACT_ROOT',
        preferredRoots: ['E:\\comparevi-artifacts'],
      },
    },
    env: {
      COMPAREVI_BURST_ARTIFACT_ROOT: externalRoot,
    },
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
    runProcessFn(_command, args) {
      const destinationIndex = args.indexOf('-D');
      const destination = args[destinationIndex + 1];
      writeFile(path.join(destination, 'copilot-review-signal.json'), '{}\n');
      return { status: 0, stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'pass');
  assert.equal(
    result.report.destinationRoot,
    path.join(externalRoot, 'tests', 'results', '_agent', 'reviews', 'run-artifacts'),
  );
  assert.deepEqual(result.report.destinationRootPolicy, {
    strategy: 'environment',
    source: 'COMPAREVI_BURST_ARTIFACT_ROOT',
    baseRoot: externalRoot,
    relativeRoot: path.join('tests', 'results', '_agent', 'reviews', 'run-artifacts'),
    usesExternalRoot: true,
  });
  assert.equal(
    result.report.downloads[0].destination,
    path.join(externalRoot, 'tests', 'results', '_agent', 'reviews', 'run-artifacts', 'copilot-review-signal-965'),
  );
});

test('downloadNamedArtifacts prefers the checked-in E: artifact root when no override is present', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-policy-root-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: ['copilot-review-signal-965'],
    repoRoot: tmpDir,
    destinationRoot: path.join('tests', 'results', '_agent', 'reviews', 'run-artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    storageRootsPolicy: {
      artifacts: {
        envVar: 'COMPAREVI_BURST_ARTIFACT_ROOT',
        preferredRoots: ['E:\\comparevi-artifacts'],
      },
    },
    env: {},
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
    runProcessFn(_command, args) {
      const destinationIndex = args.indexOf('-D');
      const destination = args[destinationIndex + 1];
      writeFile(path.join(destination, 'copilot-review-signal.json'), '{}\n');
      return { status: 0, stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'pass');
  assert.equal(
    result.report.destinationRoot,
    path.join('E:\\comparevi-artifacts', 'tests', 'results', '_agent', 'reviews', 'run-artifacts'),
  );
  assert.deepEqual(result.report.destinationRootPolicy, {
    strategy: 'policy-preferred-root',
    source: 'delivery-agent.policy.json#storageRoots.artifacts.preferredRoots[0]',
    baseRoot: 'E:\\comparevi-artifacts',
    relativeRoot: path.join('tests', 'results', '_agent', 'reviews', 'run-artifacts'),
    usesExternalRoot: true,
  });
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

test('downloadNamedArtifacts can download every discovered artifact when downloadAll is requested', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-all-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const seenDownloads = [];
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: [],
    downloadAll: true,
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      return {
        artifacts: [
          {
            id: 1,
            name: 'artifact-a',
            size_in_bytes: 10,
            expired: false,
          },
          {
            id: 2,
            name: 'artifact-b',
            size_in_bytes: 20,
            expired: false,
          },
        ],
      };
    },
    runProcessFn(_command, args) {
      const destinationIndex = args.indexOf('-D');
      const artifactIndex = args.indexOf('-n');
      const destination = args[destinationIndex + 1];
      const artifactName = args[artifactIndex + 1];
      seenDownloads.push(artifactName);
      writeFile(path.join(destination, `${artifactName}.txt`), 'ok\n');
      return { status: 0, stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'pass');
  assert.deepEqual(result.report.requestedArtifacts, ['artifact-a', 'artifact-b']);
  assert.equal(result.report.summary.requestedArtifactCount, 2);
  assert.equal(result.report.summary.downloadedCount, 2);
  assert.deepEqual(seenDownloads, ['artifact-a', 'artifact-b']);
});

test('downloadNamedArtifacts fails closed when downloadAll is requested but the run exposes no artifacts', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-all-empty-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  let processCallCount = 0;
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: [],
    downloadAll: true,
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
  assert.equal(result.report.discovery.failureClass, 'artifact-not-found');
  assert.equal(result.report.summary.requestedArtifactCount, 0);
  assert.equal(processCallCount, 0);
});

test('downloadNamedArtifacts fails fast when all requested artifact names normalize to empty values', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-invalid-request-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  let discoveryCallCount = 0;
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22872590273',
    artifactNames: ['   ', null, undefined],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      discoveryCallCount += 1;
      return { artifacts: [] };
    },
  });

  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.discovery.status, 'fail');
  assert.equal(result.report.discovery.failureClass, 'invalid-request');
  assert.match(result.report.discovery.errorMessage, /non-empty artifact name/i);
  assert.equal(result.report.summary.requestedArtifactCount, 0);
  assert.equal(result.report.downloads.length, 0);
  assert.equal(discoveryCallCount, 0);
});

test('downloadNamedArtifacts fails fast when repository or run id are missing', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-missing-request-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  let discoveryCallCount = 0;
  const result = downloadNamedArtifacts({
    repository: '   ',
    runId: null,
    artifactNames: ['copilot-review-signal-975'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      discoveryCallCount += 1;
      return { artifacts: [] };
    },
  });

  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.discovery.status, 'fail');
  assert.equal(result.report.discovery.failureClass, 'invalid-request');
  assert.match(result.report.discovery.errorMessage, /Repository is required\./);
  assert.match(result.report.discovery.errorMessage, /Run id is required\./);
  assert.deepEqual(result.report.errors, ['Repository is required.', 'Run id is required.']);
  assert.equal(discoveryCallCount, 0);
});

test('downloadNamedArtifacts keeps discovery 404 failures classified as discovery-failed', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-discovery-404-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '99999999999',
    artifactNames: ['copilot-review-signal-975'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      throw new Error('GitHub API request failed: 404 Not Found');
    },
  });

  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.discovery.status, 'fail');
  assert.equal(result.report.discovery.failureClass, 'discovery-failed');
  assert.match(result.report.discovery.errorMessage, /404 Not Found/);
});

test('downloadNamedArtifacts paginates artifact discovery until a later page contains the requested artifact', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-pagination-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const seenCommands = [];
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22879026878',
    artifactNames: ['page-two-artifact'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn(args) {
      seenCommands.push(args.at(-1));
      if (String(args.at(-1)).endsWith('page=1')) {
        return {
          total_count: 101,
          artifacts: Array.from({ length: 100 }, (_, index) => ({
            id: index + 1,
            name: `artifact-${index + 1}`,
            size_in_bytes: 1,
            expired: false,
          })),
        };
      }
      return {
        total_count: 101,
        artifacts: [
          {
            id: 101,
            name: 'page-two-artifact',
            size_in_bytes: 2,
            expired: false,
          },
        ],
      };
    },
    runProcessFn(_command, args) {
      const destinationIndex = args.indexOf('-D');
      const destination = args[destinationIndex + 1];
      writeFile(path.join(destination, 'artifact.txt'), 'ok\n');
      return { status: 0, stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.summary.availableArtifactCount, 101);
  assert.equal(result.report.summary.downloadedCount, 1);
  assert.deepEqual(seenCommands, [
    'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22879026878/artifacts?per_page=100&page=1',
    'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22879026878/artifacts?per_page=100&page=2',
  ]);
});

test('downloadNamedArtifacts treats null gh exit status as a failed download', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-null-status-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22879026878',
    artifactNames: ['copilot-review-signal-975'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      return {
        artifacts: [
          {
            id: 1,
            name: 'copilot-review-signal-975',
            size_in_bytes: 1,
            expired: false,
          },
        ],
      };
    },
    runProcessFn() {
      return { status: null, signal: 'SIGTERM', stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.summary.failedCount, 1);
  assert.equal(result.report.downloads[0].status, 'failed');
  assert.match(result.report.downloads[0].errorMessage, /exited with code unknown \(signal: SIGTERM\)/);
});

test('downloadNamedArtifacts sanitizes artifact names before building destination paths', async (t) => {
  const { downloadNamedArtifacts } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-artifact-download-sanitize-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  let destination = null;
  const result = downloadNamedArtifacts({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '22879026878',
    artifactNames: ['../dangerous/path'],
    destinationRoot: path.join(tmpDir, 'artifacts'),
    reportPath: path.join(tmpDir, 'report.json'),
    runGhJsonFn() {
      return {
        artifacts: [
          {
            id: 1,
            name: '../dangerous/path',
            size_in_bytes: 1,
            expired: false,
          },
        ],
      };
    },
    runProcessFn(_command, args) {
      const destinationIndex = args.indexOf('-D');
      destination = args[destinationIndex + 1];
      writeFile(path.join(destination, 'artifact.txt'), 'ok\n');
      return { status: 0, stdout: '', stderr: '', error: null };
    },
  });

  assert.equal(result.report.status, 'pass');
  assert.ok(destination);
  assert.equal(path.relative(path.join(tmpDir, 'artifacts'), destination), '%2E%2E%2Fdangerous%2Fpath');
  assert.deepEqual(result.report.downloads[0].files, ['artifact.txt']);
});

test('sanitizeArtifactDestinationSegment encodes dot-only path segments safely', async () => {
  const { sanitizeArtifactDestinationSegment } = await loadModule();
  assert.equal(sanitizeArtifactDestinationSegment('..'), '%2E%2E');
  assert.equal(sanitizeArtifactDestinationSegment('.'), '%2E');
});

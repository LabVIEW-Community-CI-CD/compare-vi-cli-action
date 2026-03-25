#!/usr/bin/env node

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'docker-workflow-replay-lane.mjs');
const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'docker-workflow-replay-lane-v1.schema.json');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function toGlobPath(filePath) {
  return path.resolve(filePath).replace(/\\/g, '/');
}

function resolveValidatorRepoRoot(repoRootCandidate) {
  const localValidatorOk =
    fs.existsSync(path.join(repoRootCandidate, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
    fs.existsSync(path.join(repoRootCandidate, 'node_modules', 'ajv', 'package.json')) &&
    fs.existsSync(path.join(repoRootCandidate, 'node_modules', 'argparse', 'package.json'));
  if (localValidatorOk) {
    return repoRootCandidate;
  }
  const candidates = [
    path.resolve(repoRootCandidate, '..', 'compare-monitoring-canonical'),
    path.resolve(repoRootCandidate, '..', '1843-wake-lifecycle-state-machine'),
  ];
  return (
    candidates.find(
      (candidate) =>
        fs.existsSync(path.join(candidate, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'ajv', 'package.json')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'argparse', 'package.json')),
    ) || repoRootCandidate
  );
}

function runSchemaValidate(repoRootCandidate, schemaPathInput, dataPathInput) {
  const validatorRepoRoot = resolveValidatorRepoRoot(repoRootCandidate);
  execFileSync(
    'node',
    ['dist/tools/schemas/validate-json.js', '--schema', toGlobPath(schemaPathInput), '--data', toGlobPath(dataPathInput)],
    {
      cwd: validatorRepoRoot,
      stdio: 'pipe',
    },
  );
}

test('parseArgs defaults to the session-index replay mode and a repo-contained receipt path', async () => {
  const { parseArgs } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'docker-workflow-replay-args-'));

  const parsed = parseArgs(
    ['node', modulePath, '--run-id', '23543808174'],
    { GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action' },
    tmpDir,
  );

  assert.equal(parsed.mode, 'session-index-v2-promotion');
  assert.equal(parsed.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(parsed.runId, '23543808174');
  assert.match(parsed.receiptPath, /tests[\\/]results[\\/]docker-tools-parity[\\/]workflow-replay[\\/]session-index-v2-promotion-receipt\.json$/);
});

test('buildReplayCommand forwards the deterministic report locations for session-index replay', async () => {
  const { buildReplayCommand } = await loadModule();
  const command = buildReplayCommand({
    mode: 'session-index-v2-promotion',
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runId: '23543808174',
    branch: 'develop',
    replayReportPath: 'tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/session-index-v2-promotion-decision.json',
    downloadReportPath: 'tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/session-index-v2-promotion-download.json',
    destinationRoot: 'tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/artifacts',
  });

  assert.equal(command.helperPath.replace(/\\/g, '/'), 'tools/priority/session-index-v2-promotion-decision.mjs');
  assert.deepEqual(command.command, [
    'node',
    'tools/priority/session-index-v2-promotion-decision.mjs',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--run-id',
    '23543808174',
    '--branch',
    'develop',
    '--out',
    'tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/session-index-v2-promotion-decision.json',
    '--download-report',
    'tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/session-index-v2-promotion-download.json',
    '--destination-root',
    'tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/artifacts',
  ]);
});

test('resolveGitHubToken prefers GH_TOKEN over other sources', async () => {
  const { resolveGitHubToken } = await loadModule();
  const token = resolveGitHubToken(
    {
      GH_TOKEN: 'gh-token-value',
      GITHUB_TOKEN: 'github-token-value',
    },
    () => {
      throw new Error('gh auth token should not be queried when GH_TOKEN is available.');
    },
  );

  assert.equal(token.value, 'gh-token-value');
  assert.equal(token.source, 'GH_TOKEN');
});

test('resolveImageSelection falls back to pulling the published tools image when no local image is present', async () => {
  const { resolveImageSelection, DEFAULT_PUBLISHED_IMAGE } = await loadModule();
  const calls = [];
  const selection = resolveImageSelection(
    {},
    {},
    (command, args) => {
      calls.push([command, ...args]);
      if (command === 'docker' && args[0] === 'image' && args[1] === 'inspect') {
        return { status: 1, stdout: '', stderr: 'missing' };
      }
      if (command === 'docker' && args[0] === 'pull') {
        return { status: 0, stdout: 'pulled', stderr: '' };
      }
      throw new Error(`Unexpected command: ${command} ${args.join(' ')}`);
    },
    repoRoot,
  );

  assert.equal(selection.image, DEFAULT_PUBLISHED_IMAGE);
  assert.equal(selection.source, 'published-fallback-pulled');
  assert.deepEqual(calls.at(-1), ['docker', 'pull', DEFAULT_PUBLISHED_IMAGE]);
});

test('runDockerWorkflowReplayLane writes a passing receipt when the in-container replay report passes', async () => {
  const { parseArgs, runDockerWorkflowReplayLane } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'docker-workflow-replay-pass-'));
  const options = parseArgs(
    ['node', modulePath, '--run-id', '23543808174'],
    {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      GH_TOKEN: 'test-token',
    },
    tmpDir,
  );

  const result = await runDockerWorkflowReplayLane(options, {
    repoRoot: tmpDir,
    env: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      GH_TOKEN: 'test-token',
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/upstream-1957-docker-workflow-replay-lane',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false,
    }),
    runProcessFn: (command, args, invocation = {}) => {
      if (command === 'docker' && args[0] === 'image' && args[1] === 'inspect') {
        return { status: 0, stdout: 'present', stderr: '' };
      }
      if (command === 'docker' && args[0] === 'run') {
        assert.equal(invocation.env.GH_TOKEN, 'test-token');
        writeJson(path.join(tmpDir, options.replayReportPath), {
          schema: 'session-index-v2-promotion-decision@v1',
          status: 'pass',
          decision: {
            state: 'promotion-ready',
          },
        });
        writeJson(path.join(tmpDir, options.downloadReportPath), {
          schema: 'priority/run-artifact-download@v1',
          status: 'pass',
        });
        return { status: 0, stdout: 'ok', stderr: '' };
      }
      throw new Error(`Unexpected command: ${command} ${args.join(' ')}`);
    },
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.result.status, 'passed');
  assert.equal(result.receipt.result.replayStatus, 'pass');
  assert.equal(result.receipt.result.replayDecisionState, 'promotion-ready');
  assert.equal(result.receipt.git.headSha, 'abc123');
  assert.ok(fs.existsSync(path.join(tmpDir, options.receiptPath)));

  runSchemaValidate(repoRoot, schemaPath, path.join(tmpDir, options.receiptPath));
});

test('runDockerWorkflowReplayLane fails closed and still writes a receipt when no GitHub token is available', async () => {
  const { parseArgs, runDockerWorkflowReplayLane } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'docker-workflow-replay-no-token-'));
  const options = parseArgs(
    [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '23543808174',
    ],
    {},
    tmpDir,
  );

  const result = await runDockerWorkflowReplayLane(options, {
    repoRoot: tmpDir,
    env: {},
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/upstream-1957-docker-workflow-replay-lane',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false,
    }),
    runProcessFn: (command, args) => {
      if (command === 'gh' && args[0] === 'auth' && args[1] === 'token') {
        return { status: 1, stdout: '', stderr: 'not logged in' };
      }
      throw new Error(`Unexpected command: ${command} ${args.join(' ')}`);
    },
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.docker.tokenSource, 'missing');
  assert.match(result.receipt.result.errorMessage, /not logged in|GitHub token/i);
  assert.ok(fs.existsSync(path.join(tmpDir, options.receiptPath)));
});

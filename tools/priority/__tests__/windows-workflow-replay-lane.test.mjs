#!/usr/bin/env node

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'windows-workflow-replay-lane.mjs');
const replaySchemaPath = path.join(repoRoot, 'docs', 'schemas', 'windows-workflow-replay-lane-v1.schema.json');
const preflightSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'comparevi-windows-host-preflight-v1.schema.json');

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

test('parseArgs defaults to the Windows NI host-preflight replay mode and a repo-contained receipt path', async () => {
  const { parseArgs } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-workflow-replay-args-'));

  const parsed = parseArgs(['node', modulePath], tmpDir);

  assert.equal(parsed.mode, 'windows-ni-2026q1-host-preflight');
  assert.equal(parsed.executionSurface, 'desktop-local');
  assert.equal(parsed.image, 'nationalinstruments/labview:2026q1-windows');
  assert.match(parsed.receiptPath, /tests[\\/]results[\\/]docker-tools-parity[\\/]workflow-replay[\\/]windows-ni-2026q1-host-preflight-receipt\.json$/);
});

test('buildReplayCommand forwards the deterministic Windows preflight locations', async () => {
  const { buildReplayCommand } = await loadModule();
  const command = buildReplayCommand({
    mode: 'windows-ni-2026q1-host-preflight',
    executionSurface: 'desktop-local',
    image: 'nationalinstruments/labview:2026q1-windows',
    allowUnavailable: false,
    preflightReportPath: 'tests/results/docker-tools-parity/workflow-replay/windows-ni-2026q1-host-preflight/windows-ni-2026q1-host-preflight.json',
  });

  assert.equal(command.helperPath.replace(/\\/g, '/'), 'tools/Test-WindowsNI2026q1HostPreflight.ps1');
  assert.deepEqual(command.command, [
    '-NoLogo',
    '-NoProfile',
    '-File',
    path.join('tools', 'Test-WindowsNI2026q1HostPreflight.ps1'),
    '-Image',
    'nationalinstruments/labview:2026q1-windows',
    '-ResultsDir',
    'tests/results/docker-tools-parity/workflow-replay/windows-ni-2026q1-host-preflight',
    '-ExecutionSurface',
    'desktop-local',
    '-OutputJsonPath',
    'tests/results/docker-tools-parity/workflow-replay/windows-ni-2026q1-host-preflight/windows-ni-2026q1-host-preflight.json',
    '-GitHubOutputPath',
    '',
    '-StepSummaryPath',
    '',
  ]);
});

test('runWindowsWorkflowReplayLane writes a passing receipt when the inner preflight is ready', async () => {
  const { parseArgs, runWindowsWorkflowReplayLane } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-workflow-replay-pass-'));
  const options = parseArgs(['node', modulePath], tmpDir);

  const result = await runWindowsWorkflowReplayLane(options, {
    repoRoot: tmpDir,
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/upstream-1957-windows-workflow-parity',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false,
    }),
    runProcessFn: (command, args) => {
      if (command === 'pwsh') {
        const outputPath = args[args.indexOf('-OutputJsonPath') + 1];
        writeJson(path.join(tmpDir, outputPath), {
          schema: 'comparevi/windows-host-preflight@v1',
          generatedAtUtc: '2026-03-25T15:00:00.000Z',
          executionSurface: 'desktop-local',
          image: 'nationalinstruments/labview:2026q1-windows',
          status: 'ready',
          failureClass: 'none',
          failureMessage: '',
          runnerEnvironment: '',
          contexts: {
            start: 'desktop-windows',
            startOsType: 'windows',
            final: 'desktop-windows',
            finalOsType: 'windows',
          },
          runtimeProvider: 'docker-desktop',
          runtimeDeterminism: {
            status: 'success',
            reason: '',
            snapshotPath: 'tests/results/local-parity/runtime.json',
            failureClass: 'none',
          },
          bootstrap: {
            attempted: true,
            pulled: false,
            imagePresent: true,
            localImageId: 'sha256:test',
            localRepoDigest: '',
            localDigest: '',
            pullDurationMs: 0,
            pullError: '',
          },
          probe: {
            attempted: true,
            status: 'success',
            exitCode: 0,
            durationMs: 1,
            output: 'ni-runtime-probe-ok',
            command: 'docker run ...',
            error: '',
          },
          hostedContract: {
            hostEngineMutationAllowed: false,
            expectedContext: 'desktop-windows',
            expectedOs: 'windows',
          },
        });
        return { status: 0, stdout: 'ok', stderr: '' };
      }
      throw new Error(`Unexpected command: ${command} ${args.join(' ')}`);
    },
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.result.status, 'passed');
  assert.equal(result.receipt.result.preflightStatus, 'ready');
  assert.equal(result.receipt.result.failureClass, 'none');

  const preflightPath = path.join(tmpDir, options.preflightReportPath);
  runSchemaValidate(repoRoot, preflightSchemaPath, preflightPath);
  runSchemaValidate(repoRoot, replaySchemaPath, path.join(tmpDir, options.receiptPath));
});

test('runWindowsWorkflowReplayLane returns unavailable when the inner preflight is unavailable and explicitly allowed', async () => {
  const { parseArgs, runWindowsWorkflowReplayLane } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-workflow-replay-unavailable-'));
  const options = parseArgs(['node', modulePath, '--execution-surface', 'github-hosted-windows', '--allow-unavailable'], tmpDir);

  const result = await runWindowsWorkflowReplayLane(options, {
    repoRoot: tmpDir,
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/upstream-1957-windows-workflow-parity',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false,
    }),
    runProcessFn: (command, args) => {
      if (command === 'pwsh') {
        const outputPath = args[args.indexOf('-OutputJsonPath') + 1];
        writeJson(path.join(tmpDir, outputPath), {
          schema: 'comparevi/windows-host-preflight@v1',
          generatedAtUtc: '2026-03-25T15:00:00.000Z',
          executionSurface: 'github-hosted-windows',
          image: 'nationalinstruments/labview:2026q1-windows',
          status: 'unavailable',
          failureClass: 'docker-runtime-unavailable',
          failureMessage: 'docker daemon unavailable',
          runnerEnvironment: 'github-hosted',
          contexts: {
            start: 'default',
            startOsType: '',
            final: 'default',
            finalOsType: '',
          },
          runtimeProvider: 'github-hosted-windows',
          runtimeDeterminism: {
            status: 'unavailable',
            reason: 'docker-daemon-unavailable',
            snapshotPath: 'tests/results/local-parity/runtime.json',
            failureClass: 'docker-runtime-unavailable',
          },
          bootstrap: {
            attempted: false,
            pulled: false,
            imagePresent: false,
            localImageId: '',
            localRepoDigest: '',
            localDigest: '',
            pullDurationMs: 0,
            pullError: '',
          },
          probe: {
            attempted: false,
            status: 'not-run',
            exitCode: -1,
            durationMs: 0,
            output: '',
            command: '',
            error: '',
          },
          hostedContract: {
            hostEngineMutationAllowed: false,
            expectedContext: 'default',
            expectedOs: 'windows',
          },
        });
        return { status: 0, stdout: 'ok', stderr: '' };
      }
      throw new Error(`Unexpected command: ${command} ${args.join(' ')}`);
    },
  });

  assert.equal(result.status, 'unavailable');
  assert.equal(result.receipt.result.status, 'unavailable');
  assert.equal(result.receipt.result.preflightStatus, 'unavailable');
  assert.equal(result.receipt.result.failureClass, 'docker-runtime-unavailable');

  const preflightPath = path.join(tmpDir, options.preflightReportPath);
  runSchemaValidate(repoRoot, preflightSchemaPath, preflightPath);
  runSchemaValidate(repoRoot, replaySchemaPath, path.join(tmpDir, options.receiptPath));
});

test('runWindowsWorkflowReplayLane fails closed and still writes a receipt when the preflight report is missing', async () => {
  const { parseArgs, runWindowsWorkflowReplayLane } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-workflow-replay-missing-report-'));
  const options = parseArgs(['node', modulePath], tmpDir);

  const result = await runWindowsWorkflowReplayLane(options, {
    repoRoot: tmpDir,
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/upstream-1957-windows-workflow-parity',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false,
    }),
    runProcessFn: () => ({ status: 1, stdout: '', stderr: 'preflight failed' }),
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.result.status, 'failed');
  assert.match(result.receipt.result.errorMessage, /preflight failed/i);
  runSchemaValidate(repoRoot, replaySchemaPath, path.join(tmpDir, options.receiptPath));
});

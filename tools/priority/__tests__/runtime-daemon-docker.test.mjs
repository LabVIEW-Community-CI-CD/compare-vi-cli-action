#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

async function writeJson(filePath, payload) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function runPwsh(args, { env = {}, cwd = process.cwd() } = {}) {
  return spawnSync('pwsh', ['-NoLogo', '-NoProfile', ...args], {
    cwd,
    env: {
      ...process.env,
      ...env
    },
    encoding: 'utf8'
  });
}

async function createFakeDockerFixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-docker-'));
  const stateDir = path.join(root, 'docker-state');
  const dockerJs = path.join(root, 'fake-docker.mjs');
  const dockerCmd = path.join(root, 'fake-docker.cmd');
  await writeFile(
    dockerJs,
    `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const stateDir = process.env.FAKE_DOCKER_STATE_DIR;
const statePath = path.join(stateDir, 'containers.json');
const commandsPath = path.join(stateDir, 'commands.ndjson');

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(statePath, 'utf8'));
  } catch {
    return { containers: {}, context: 'desktop-windows', os: 'windows' };
  }
}

function saveState(state) {
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
}

function logCommand(args) {
  fs.mkdirSync(stateDir, { recursive: true });
  fs.appendFileSync(commandsPath, JSON.stringify({ args }) + '\\n');
}

function currentStamp() {
  return '2026-03-10T18:00:00.000Z';
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

function findName(args) {
  const index = args.indexOf('--name');
  return index >= 0 ? args[index + 1] : '';
}

function findImage(args) {
  const optionsWithValues = new Set(['--name', '-v', '-w', '-e', '--label']);
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (optionsWithValues.has(token)) {
      index += 1;
      continue;
    }
    if (token === '--detach') {
      continue;
    }
    if (token.startsWith('-')) {
      continue;
    }
    return token;
  }
  return '';
}

const args = process.argv.slice(2);
logCommand(args);
const state = loadState();
const [command, ...rest] = args;

if (command === 'context' && rest[0] === 'show') {
  console.log(state.context || 'desktop-windows');
  process.exit(0);
}

if (command === 'context' && rest[0] === 'use') {
  const nextContext = rest[1];
  state.context = nextContext;
  state.os = nextContext === 'desktop-linux' ? 'linux' : 'windows';
  saveState(state);
  console.log(nextContext);
  process.exit(0);
}

if (command === 'info') {
  console.log(state.os || 'windows');
  process.exit(0);
}

if (command === 'run') {
  const name = findName(rest);
  const image = findImage(rest);
  if (!name) fail('missing container name');
  state.containers[name] = {
    id: name + '-id',
    image,
    status: 'running',
    running: true,
    exitCode: 0,
    createdAt: currentStamp(),
    startedAt: currentStamp(),
    finishedAt: ''
  };
  saveState(state);
  console.log(name + '-id');
  process.exit(0);
}

if (command === 'inspect') {
  const name = rest.at(-1);
  const container = state.containers[name];
  if (!container) {
    console.error('Error: No such object: ' + name);
    process.exit(1);
  }
  console.log(JSON.stringify([{
    Id: container.id,
    Name: '/' + name,
    Created: container.createdAt,
    Config: { Image: container.image },
    State: {
      Status: container.status,
      Running: container.running,
      ExitCode: container.exitCode,
      StartedAt: container.startedAt,
      FinishedAt: container.finishedAt
    }
  }]));
  process.exit(0);
}

if (command === 'logs') {
  const name = rest.at(-1);
  const container = state.containers[name];
  if (!container) {
    console.error('Error: No such container: ' + name);
    process.exit(1);
  }
  console.log('log:' + name + ':1');
  console.log('log:' + name + ':2');
  process.exit(0);
}

if (command === 'stop') {
  const name = rest.at(-1);
  const container = state.containers[name];
  if (!container) {
    console.error('Error: No such container: ' + name);
    process.exit(1);
  }
  container.status = 'exited';
  container.running = false;
  container.finishedAt = currentStamp();
  saveState(state);
  console.log(name);
  process.exit(0);
}

if (command === 'rm') {
  const name = rest.at(-1);
  if (!state.containers[name]) {
    console.error('Error: No such container: ' + name);
    process.exit(1);
  }
  delete state.containers[name];
  saveState(state);
  console.log(name);
  process.exit(0);
}

fail('unsupported command: ' + command);
`,
    'utf8'
  );
  await writeFile(dockerCmd, '@echo off\r\nnode "%~dp0fake-docker.mjs" %*\r\n', 'utf8');
  return { root, stateDir, dockerCmd };
}

test('docker daemon manager handles start, status, logs, and stop with persisted state', async () => {
  const fixture = await createFakeDockerFixture();
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-runtime-'));
  const scriptPath = path.join(process.cwd(), 'tools', 'priority', 'Manage-RuntimeDaemonInDocker.ps1');
  const commonArgs = [
    '-File',
    scriptPath,
    '-Repo',
    'example/repo',
    '-RuntimeDir',
    runtimeDir,
    '-ContainerName',
    'comparevi-runtime-test',
    '-Image',
    'example/runtime:test',
    '-DockerCommand',
    fixture.dockerCmd
  ];
  const env = {
    FAKE_DOCKER_STATE_DIR: fixture.stateDir
  };

  const startResult = runPwsh([...commonArgs, '-Action', 'start', '-MaxCycles', '1'], { env });
  assert.equal(startResult.status, 0, startResult.stderr);
  const startReport = JSON.parse(startResult.stdout);
  assert.equal(startReport.outcome, 'started');
  assert.equal(startReport.state.container.status, 'running');
  assert.equal(startReport.state.launch.detached, true);
  assert.equal(startReport.state.docker.context.previous, 'desktop-windows');
  assert.equal(startReport.state.docker.context.active, 'desktop-linux');
  assert.equal(startReport.state.docker.context.mode, 'context-use');
  assert.equal(startReport.state.docker.context.switched, true);
  assert.equal(startReport.state.engine.lockAcquired, false);
  assert.match(startReport.state.launch.command.join(' '), /--detach/);

  const statusResult = runPwsh([...commonArgs, '-Action', 'status'], { env });
  assert.equal(statusResult.status, 0, statusResult.stderr);
  const statusReport = JSON.parse(statusResult.stdout);
  assert.equal(statusReport.outcome, 'running');
  assert.equal(statusReport.state.container.running, true);

  const logsResult = runPwsh([...commonArgs, '-Action', 'logs', '-TailLines', '20'], { env });
  assert.equal(logsResult.status, 0, logsResult.stderr);
  const logsReport = JSON.parse(logsResult.stdout);
  assert.equal(logsReport.outcome, 'captured');
  assert.equal(logsReport.logs.lineCount, 2);

  const stopResult = runPwsh([...commonArgs, '-Action', 'stop', '-TailLines', '20'], { env });
  assert.equal(stopResult.status, 0, stopResult.stderr);
  const stopReport = JSON.parse(stopResult.stdout);
  assert.equal(stopReport.outcome, 'removed');
  assert.equal(stopReport.state.container.removed, true);

  const state = await readJson(path.join(runtimeDir, 'docker-daemon-state.json'));
  const engineState = await readJson(path.join(process.cwd(), 'tests', 'results', '_agent', 'runtime', 'docker-daemon-engine.json'));
  const healthState = await readJson(path.join(runtimeDir, 'docker-daemon-health.json'));
  const logState = await readJson(path.join(runtimeDir, 'docker-daemon-logs.json'));
  const logText = await readFile(path.join(runtimeDir, 'docker-daemon-logs.txt'), 'utf8');
  const commandLog = (await readFile(path.join(fixture.stateDir, 'commands.ndjson'), 'utf8'))
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));

  assert.equal(state.schema, 'priority/runtime-daemon-docker-state@v1');
  assert.equal(state.outcome, 'removed');
  assert.equal(state.container.status, 'removed');
  assert.equal(state.docker.context.active, 'desktop-linux');
  assert.equal(startReport.health.status, 'healthy');
  assert.equal(startReport.health.reason, 'startup-grace-window');
  assert.equal(engineState.schema, 'priority/runtime-daemon-docker-engine@v1');
  assert.equal(engineState.docker.context.active, 'desktop-linux');
  assert.equal(healthState.schema, 'priority/runtime-daemon-docker-health@v1');
  assert.equal(healthState.status, 'not-running');
  assert.equal(logState.schema, 'priority/runtime-daemon-docker-logs@v1');
  assert.match(logText, /log:comparevi-runtime-test:1/);
  assert.deepEqual(
    commandLog.map((entry) => entry.args[0]),
    [
      'context',
      'context',
      'info',
      'inspect',
      'run',
      'inspect',
      'context',
      'context',
      'info',
      'inspect',
      'context',
      'context',
      'info',
      'logs',
      'inspect',
      'context',
      'context',
      'info',
      'inspect',
      'logs',
      'stop',
      'rm'
    ]
  );
});

test('docker daemon manager restarts a running container when the observer heartbeat is stale', async () => {
  const fixture = await createFakeDockerFixture();
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-stale-'));
  const scriptPath = path.join(process.cwd(), 'tools', 'priority', 'Manage-RuntimeDaemonInDocker.ps1');
  const containerName = 'comparevi-runtime-stale';
  await writeJson(path.join(fixture.stateDir, 'containers.json'), {
    context: 'desktop-windows',
    os: 'windows',
    containers: {
      [containerName]: {
        id: `${containerName}-id`,
        image: 'example/runtime:test',
        status: 'running',
        running: true,
        exitCode: 0,
        createdAt: '2026-02-28T00:00:00.000Z',
        startedAt: '2026-02-28T00:00:00.000Z',
        finishedAt: ''
      }
    }
  });
  await writeJson(path.join(runtimeDir, 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: '2026-03-01T00:00:00.000Z',
    runtimeAdapter: 'comparevi',
    repository: 'example/repo',
    platform: 'linux',
    cyclesCompleted: 4,
    outcome: 'lane-tracked',
    stopRequested: false,
    activeLane: { laneId: 'origin-977', issue: 977 },
    artifacts: {}
  });

  const result = runPwsh(
    [
      '-File',
      scriptPath,
      '-Action',
      'start',
      '-Repo',
      'example/repo',
      '-RuntimeDir',
      runtimeDir,
      '-ContainerName',
      containerName,
      '-Image',
      'example/runtime:test',
      '-DockerCommand',
      fixture.dockerCmd,
      '-MaxCycles',
      '1',
      '-HeartbeatFreshSeconds',
      '60'
    ],
    {
      env: {
        FAKE_DOCKER_STATE_DIR: fixture.stateDir
      }
    }
  );

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  const state = await readJson(path.join(runtimeDir, 'docker-daemon-state.json'));
  const health = await readJson(path.join(runtimeDir, 'docker-daemon-health.json'));
  const logState = await readJson(path.join(runtimeDir, 'docker-daemon-logs.json'));
  const commandLog = (await readFile(path.join(fixture.stateDir, 'commands.ndjson'), 'utf8'))
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));

  assert.equal(report.outcome, 'restarted-stale');
  assert.equal(report.restart.reason, 'stale');
  assert.equal(report.restart.priorHealth.status, 'stale');
  assert.equal(report.health.status, 'healthy');
  assert.equal(state.container.status, 'running');
  assert.equal(state.health.status, 'healthy');
  assert.equal(health.status, 'healthy');
  assert.equal(logState.lineCount, 2);
  assert.equal(report.restart.priorLogs.lineCount, 2);
  assert.deepEqual(
    commandLog.map((entry) => entry.args[0]),
    ['context', 'context', 'info', 'inspect', 'logs', 'stop', 'rm', 'run', 'inspect']
  );
});

test('docker daemon manager reconcile repairs stale lanes and keeps healthy lanes running', async () => {
  const fixture = await createFakeDockerFixture();
  const reconcileRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-reconcile-'));
  const runtimeRoot = path.join(reconcileRoot, 'runtime');
  const healthyRuntimeDir = path.join(runtimeRoot, 'lane-healthy');
  const staleRuntimeDir = path.join(runtimeRoot, 'lane-stale');
  const scriptPath = path.join(process.cwd(), 'tools', 'priority', 'Manage-RuntimeDaemonInDocker.ps1');
  const healthyContainerName = 'comparevi-runtime-healthy';
  const staleContainerName = 'comparevi-runtime-stale';
  const now = new Date().toISOString();
  const oldStamp = '2020-01-01T00:00:00.000Z';

  await writeJson(path.join(fixture.stateDir, 'containers.json'), {
    context: 'desktop-windows',
    os: 'windows',
    containers: {
      [healthyContainerName]: {
        id: `${healthyContainerName}-id`,
        image: 'example/runtime:test',
        status: 'running',
        running: true,
        exitCode: 0,
        createdAt: oldStamp,
        startedAt: oldStamp,
        finishedAt: ''
      },
      [staleContainerName]: {
        id: `${staleContainerName}-id`,
        image: 'example/runtime:test',
        status: 'running',
        running: true,
        exitCode: 0,
        createdAt: oldStamp,
        startedAt: oldStamp,
        finishedAt: ''
      }
    }
  });

  for (const [runtimeDir, containerName, generatedAt, healthStatus] of [
    [healthyRuntimeDir, healthyContainerName, now, 'healthy'],
    [staleRuntimeDir, staleContainerName, oldStamp, 'stale']
  ]) {
    const heartbeatPath = path.join(runtimeDir, 'observer-heartbeat.json');
    await writeJson(heartbeatPath, {
      schema: 'priority/runtime-observer-heartbeat@v1',
      generatedAt,
      runtimeAdapter: 'comparevi',
      repository: 'example/repo',
      platform: 'linux',
      cyclesCompleted: 3,
      outcome: 'lane-tracked',
      stopRequested: false,
      activeLane: { laneId: containerName, issue: 978 },
      artifacts: {}
    });
    await writeJson(path.join(runtimeDir, 'docker-daemon-state.json'), {
      schema: 'priority/runtime-daemon-docker-state@v1',
      generatedAt: now,
      repository: 'example/repo',
      runtime: {
        runtimeDir,
        runtimeDirHost: runtimeDir,
        heartbeatPath,
        heartbeatPathHost: heartbeatPath,
        heartbeatExists: true
      },
      container: {
        name: containerName,
        image: 'example/runtime:test',
        status: 'running',
        running: true
      },
      health: {
        schema: 'priority/runtime-daemon-docker-health@v1',
        generatedAt: now,
        status: healthStatus
      }
    });
    await writeJson(path.join(runtimeDir, 'docker-daemon-health.json'), {
      schema: 'priority/runtime-daemon-docker-health@v1',
      generatedAt: now,
      status: healthStatus
    });
  }

  const result = runPwsh(
    [
      '-File',
      scriptPath,
      '-Action',
      'reconcile',
      '-ReconcileRoot',
      reconcileRoot,
      '-DockerCommand',
      fixture.dockerCmd,
      '-HeartbeatFreshSeconds',
      '60',
      '-TailLines',
      '20'
    ],
    {
      env: {
        FAKE_DOCKER_STATE_DIR: fixture.stateDir
      }
    }
  );

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  const persistedReport = await readJson(path.join(runtimeRoot, 'docker-daemon-reconcile.json'));
  const healthyState = await readJson(path.join(healthyRuntimeDir, 'docker-daemon-state.json'));
  const staleState = await readJson(path.join(staleRuntimeDir, 'docker-daemon-state.json'));
  const staleLogs = await readJson(path.join(staleRuntimeDir, 'docker-daemon-logs.json'));
  const commandLog = (await readFile(path.join(fixture.stateDir, 'commands.ndjson'), 'utf8'))
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));

  assert.equal(report.schema, 'priority/runtime-daemon-docker-reconcile@v1');
  assert.equal(report.outcome, 'reconciled');
  assert.equal(report.summary.discovered, 2);
  assert.equal(report.summary.attempted, 2);
  assert.equal(report.summary.blocked, 0);
  assert.equal(report.summary.repaired, 1);
  assert.equal(report.summary.healthy, 2);
  assert.equal(report.lanes.length, 2);
  assert.deepEqual(report, persistedReport);

  const healthyLane = report.lanes.find((lane) => lane.containerName === healthyContainerName);
  const staleLane = report.lanes.find((lane) => lane.containerName === staleContainerName);
  assert.equal(healthyLane.outcome, 'already-running');
  assert.equal(healthyLane.repaired, false);
  assert.equal(healthyLane.priorHealthStatus, 'healthy');
  assert.equal(healthyLane.healthStatus, 'healthy');
  assert.equal(staleLane.outcome, 'restarted-stale');
  assert.equal(staleLane.repaired, true);
  assert.equal(staleLane.priorHealthStatus, 'stale');
  assert.equal(staleLane.healthStatus, 'healthy');

  assert.equal(healthyState.outcome, 'already-running');
  assert.equal(staleState.outcome, 'restarted-stale');
  assert.equal(staleLogs.lineCount, 2);
  assert.equal(commandLog.filter((entry) => entry.args[0] === 'run').length, 1);
  assert.equal(commandLog.filter((entry) => entry.args[0] === 'stop').length, 1);
  assert.equal(commandLog.filter((entry) => entry.args[0] === 'rm').length, 1);
});

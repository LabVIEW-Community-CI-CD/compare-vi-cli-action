import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'delivery-host-signal.js');

let builtModulePromise = null;

async function loadModule() {
  if (!builtModulePromise) {
    const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
    assert.equal(buildResult.status, 0, [buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'));
    builtModulePromise = import(`${pathToFileURL(distModulePath).href}?cache=${Date.now()}`);
  }
  return builtModulePromise;
}

function makeDockerDesktopInfo({ osType = 'linux' } = {}) {
  return {
    OSType: osType,
    OperatingSystem: 'Docker Desktop',
    Name: 'docker-desktop',
    Platform: { Name: 'Docker Desktop 4.60.1 (218372)' },
    ServerVersion: '29.2.0',
    Labels: ['com.docker.desktop.address=unix:///var/run/docker-cli.sock'],
  };
}

function makeNativeInfo({ osType = 'linux' } = {}) {
  return {
    OSType: osType,
    OperatingSystem: 'Ubuntu 24.04.2 LTS',
    Name: 'ubuntu-native',
    Platform: { Name: 'Docker Engine - Community' },
    ServerVersion: '28.1.1',
    Labels: [],
  };
}

function makeWslStdout(info, { systemdState = 'running', serviceState = 'active', context = 'default' } = {}) {
  return [
    systemdState,
    serviceState,
    context,
    'true',
    'root:docker',
    '660',
    Buffer.from(JSON.stringify(info), 'utf8').toString('base64'),
    '',
  ].join('\n');
}

function createMockRunner({ windowsInfo, wslInfo, initialServices = [] }) {
  const serviceState = new Map();
  for (const service of initialServices) {
    serviceState.set(service.name, {
      name: service.name,
      displayName: service.displayName ?? service.name,
      status: service.status ?? 'Stopped',
      startType: service.startType ?? 'Manual',
    });
  }

  const normalizeStatusCode = (value) => {
    if (value === 'Running') return '4';
    if (value === 'Stopped') return '1';
    return String(value ?? '1');
  };
  const normalizeStatusLabel = (value) => {
    if (value === '4' || value === 'Running') return 'RUNNING';
    if (value === '1' || value === 'Stopped') return 'STOPPED';
    return String(value ?? 'STOPPED').toUpperCase();
  };
  const normalizeStartTypeCode = (value) => {
    if (value === 'Automatic') return '2';
    if (value === 'Manual') return '3';
    if (value === 'Disabled') return '4';
    return String(value ?? '3');
  };

  return (filePath, args) => {
    if (filePath === 'docker' && args[0] === 'context' && args[1] === 'show') {
      return { status: 0, stdout: 'desktop-windows\n', stderr: '' };
    }
    if (filePath === 'docker' && args[0] === 'info') {
      return { status: 0, stdout: `${JSON.stringify(windowsInfo)}\n`, stderr: '' };
    }
    if (filePath === 'wsl.exe') {
      return { status: 0, stdout: makeWslStdout(wslInfo), stderr: '' };
    }
    if (filePath === 'sc.exe') {
      if (args[0] === 'query' && args[1] === 'state=' && args[2] === 'all') {
        return {
          status: 0,
          stdout: [...serviceState.keys()].map((name) => `SERVICE_NAME: ${name}`).join('\n'),
          stderr: '',
        };
      }
      if (args[0] === 'query' && args[1]) {
        const current = serviceState.get(args[1]);
        return {
          status: 0,
          stdout: `SERVICE_NAME: ${args[1]}\nSTATE              : ${normalizeStatusCode(current?.status)} ${normalizeStatusLabel(current?.status)}\n`,
          stderr: '',
        };
      }
      if (args[0] === 'qc' && args[1]) {
        const current = serviceState.get(args[1]);
        return {
          status: 0,
          stdout: `SERVICE_NAME: ${args[1]}\nSTART_TYPE         : ${normalizeStartTypeCode(current?.startType)}\n`,
          stderr: '',
        };
      }
      if ((args[0] === 'stop' || args[0] === 'start') && args[1]) {
        const current = serviceState.get(args[1]);
        serviceState.set(args[1], {
          ...current,
          status: args[0] === 'stop' ? 'Stopped' : 'Running',
        });
        return { status: 0, stdout: `SERVICE_NAME: ${args[1]}\n`, stderr: '' };
      }
    }
    throw new Error(`Unexpected command: ${filePath} ${args.join(' ')}`);
  };
}

test('delivery-host-signal reports desktop-backed when WSL docker still resolves to Docker Desktop', async (t) => {
  const { runDeliveryHostSignal } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delivery-host-signal-desktop-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const result = runDeliveryHostSignal({
    repoRoot: tmpDir,
    reportPath: 'daemon-host-signal.json',
    isolationPath: 'host-isolation.json',
    tracePath: 'host-trace.ndjson',
    runner: createMockRunner({
      windowsInfo: makeDockerDesktopInfo({ osType: 'windows' }),
      wslInfo: makeDockerDesktopInfo(),
      initialServices: [],
    }),
  });

  assert.equal(result.report.status, 'desktop-backed');
  assert.equal(result.report.provider, 'desktop');
  assert.equal(result.report.wslDocker.isDockerDesktop, true);
  assert.match(result.report.reasons.join(' '), /Docker Desktop/i);
  assert.equal(result.tracePath, path.join(tmpDir, 'host-trace.ndjson'));
  assert.equal(fs.existsSync(result.tracePath), true);
});

test('delivery-host-signal reports native-wsl only when the pinned WSL daemon is not Docker Desktop backed', async (t) => {
  const { runDeliveryHostSignal } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delivery-host-signal-native-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const result = runDeliveryHostSignal({
    repoRoot: tmpDir,
    reportPath: 'daemon-host-signal.json',
    isolationPath: 'host-isolation.json',
    tracePath: 'host-trace.ndjson',
    runner: createMockRunner({
      windowsInfo: makeDockerDesktopInfo({ osType: 'windows' }),
      wslInfo: makeNativeInfo(),
      initialServices: [],
    }),
  });

  assert.equal(result.report.status, 'native-wsl');
  assert.equal(result.report.provider, 'native-wsl');
  assert.equal(result.report.wslDocker.isDockerDesktop, false);
});

test('delivery-host-signal isolates and restores only services that were running at start', async (t) => {
  const { runDeliveryHostSignal } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delivery-host-signal-isolate-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const runner = createMockRunner({
    windowsInfo: makeDockerDesktopInfo({ osType: 'windows' }),
    wslInfo: makeNativeInfo(),
    initialServices: [
      { name: 'actions.runner.repo.alpha', status: 'Running' },
      { name: 'actions.runner.repo.beta', status: 'Stopped' },
    ],
  });

  const isolated = runDeliveryHostSignal({
    mode: 'isolate',
    repoRoot: tmpDir,
    reportPath: 'daemon-host-signal.json',
    isolationPath: 'host-isolation.json',
    tracePath: 'host-trace.ndjson',
    runner,
  });
  const restored = runDeliveryHostSignal({
    mode: 'restore',
    repoRoot: tmpDir,
    reportPath: 'daemon-host-signal.json',
    isolationPath: 'host-isolation.json',
    tracePath: 'host-trace.ndjson',
    runner,
  });

  assert.deepEqual(isolated.actions.preemptedServices, ['actions.runner.repo.alpha']);
  assert.deepEqual(restored.actions.restoredServices, ['actions.runner.repo.alpha']);
  assert.equal(restored.isolation.counters.runnerPreemptionCount, 1);
  assert.equal(restored.isolation.counters.runnerRestoreCount, 1);
  assert.deepEqual(restored.isolation.preemptedServices, []);
  assert.deepEqual(
    isolated.report.runnerServices.discovered.map((entry) => entry.name),
    ['actions.runner.repo.alpha', 'actions.runner.repo.beta'],
  );
});

test('delivery-host-signal normalizes numeric PowerShell service enums into runner states', async (t) => {
  const { runDeliveryHostSignal } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delivery-host-signal-service-enums-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const runner = createMockRunner({
    windowsInfo: makeDockerDesktopInfo({ osType: 'windows' }),
    wslInfo: makeNativeInfo(),
    initialServices: [
      { name: 'actions.runner.repo.alpha', status: '4', startType: '2' },
      { name: 'actions.runner.repo.beta', status: '1', startType: '3' },
    ],
  });

  const result = runDeliveryHostSignal({
    repoRoot: tmpDir,
    reportPath: 'daemon-host-signal.json',
    isolationPath: 'host-isolation.json',
    tracePath: 'host-trace.ndjson',
    runner,
  });

  assert.deepEqual(result.report.runnerServices.running, ['actions.runner.repo.alpha']);
  assert.deepEqual(result.report.runnerServices.stopped, ['actions.runner.repo.beta']);
  assert.deepEqual(
    result.report.runnerServices.discovered.map((entry) => entry.status),
    ['Running', 'Stopped'],
  );
  assert.deepEqual(
    result.report.runnerServices.discovered.map((entry) => entry.startType),
    ['Automatic', 'Manual'],
  );
});

test('delivery-host-signal reports drifted when the daemon fingerprint changes between cycles', async (t) => {
  const { runDeliveryHostSignal } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delivery-host-signal-drift-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const first = runDeliveryHostSignal({
    repoRoot: tmpDir,
    reportPath: 'daemon-host-signal.json',
    isolationPath: 'host-isolation.json',
    tracePath: 'host-trace.ndjson',
    runner: createMockRunner({
      windowsInfo: makeDockerDesktopInfo({ osType: 'windows' }),
      wslInfo: makeNativeInfo(),
      initialServices: [],
    }),
  });
  const second = runDeliveryHostSignal({
    repoRoot: tmpDir,
    reportPath: 'daemon-host-signal.json',
    isolationPath: 'host-isolation.json',
    tracePath: 'host-trace.ndjson',
    previousFingerprint: first.report.daemonFingerprint,
    runner: createMockRunner({
      windowsInfo: makeDockerDesktopInfo({ osType: 'windows' }),
      wslInfo: { ...makeNativeInfo(), ServerVersion: '28.2.0' },
      initialServices: [],
    }),
  });

  assert.equal(second.report.status, 'drifted');
  assert.equal(second.report.fingerprintChanged, true);
  assert.equal(second.isolation.counters.dockerDriftIncidentCount, 1);
  const traceLines = fs
    .readFileSync(path.join(tmpDir, 'host-trace.ndjson'), 'utf8')
    .trim()
    .split(/\r?\n/)
    .map((line) => JSON.parse(line));
  assert.equal(traceLines.length, 2);
  assert.equal(traceLines.at(-1).status, 'drifted');
});

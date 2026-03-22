import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_POLICY_PATH,
  DEFAULT_RUNTIME_DIR,
  DEFAULT_TAIL_LINES,
  observeJarvisSessionObserver,
  parseArgs
} from '../jarvis-session-observer.mjs';

function createTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'jarvis-session-observer-'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function writeText(filePath, text) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, text, 'utf8');
}

test('parseArgs exposes deterministic defaults', () => {
  const options = parseArgs(['node', 'jarvis-session-observer.mjs']);
  assert.equal(options.runtimeDir, DEFAULT_RUNTIME_DIR);
  assert.equal(options.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(options.policyPath, DEFAULT_POLICY_PATH);
  assert.equal(options.tailLines, DEFAULT_TAIL_LINES);
});

test('observeJarvisSessionObserver projects an active manual Windows Docker session with daemon visibility', async () => {
  const repoRoot = createTempDir();
  const runtimeDir = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime');
  writeJson(path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'), {
    schema: 'priority/delivery-agent-policy@v1',
    capitalFabric: {
      maxLogicalLaneCount: 8,
      specialtyLanes: [
        {
          id: 'jarvis',
          enabled: true,
          primaryRecordedResponsibility: 'Sagan',
          maxInstanceCount: 2,
          purpose: 'windows-docker-iterative-development',
          preferredExecutionPlane: 'local-docker-windows',
          preferredContainerImage: 'nationalinstruments/labview:2026q1-windows',
          allocationMode: 'opportunistic'
        }
      ]
    },
    dockerRuntime: {
      provider: 'native-wsl',
      dockerHost: 'unix:///var/run/docker.sock',
      expectedOsType: 'linux',
      expectedContext: '',
      manageDockerEngine: false,
      allowHostEngineMutation: false
    }
  });
  writeJson(path.join(runtimeDir, 'delivery-agent-state.json'), {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: '2026-03-21T01:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    laneLifecycle: 'coding',
    logicalLaneActivation: {
      effectiveLogicalLaneCount: 2
    },
    activeLane: {
      laneId: 'issue-origin-1736-jarvis-session-observer',
      issue: 1736,
      branch: 'issue/origin-1736-jarvis-session-observer',
      providerDispatch: {
        executionPlane: 'local',
        workerSlotId: 'worker-slot-1'
      }
    }
  });
  writeJson(path.join(runtimeDir, 'concurrent-lane-status-receipt.json'), {
    schema: 'priority/concurrent-lane-status-receipt@v1',
    laneStatuses: [
      {
        id: 'manual-windows-docker',
        runtimeStatus: 'active',
        executionPlane: 'local',
        laneClass: 'manual-docker',
        resourceGroup: 'docker-desktop-windows',
        reasons: ['docker-engine-windows'],
        metadata: {
          dockerContext: 'desktop-windows',
          dockerServerOs: 'windows',
          branchRef: 'issue/origin-1736-jarvis-session-observer'
        }
      }
    ]
  });
  writeJson(path.join(runtimeDir, 'delivery-memory.json'), {
    schema: 'priority/delivery-memory@v1',
    generatedAt: '2026-03-21T01:05:00.000Z',
    summary: {
      targetSlotCount: 4
    }
  });
  writeJson(path.join(runtimeDir, 'daemon-host-signal.json'), {
    schema: 'priority/delivery-agent-host-signal@v1',
    generatedAt: '2026-03-21T01:10:00.000Z',
    status: 'native-wsl',
    provider: 'native-wsl',
    daemonFingerprint: 'abc12345',
    previousFingerprint: 'abc12345',
    fingerprintChanged: false,
    reasons: [],
    windowsDocker: {
      available: true,
      context: 'desktop-windows',
      osType: 'windows',
      operatingSystem: 'Docker Desktop',
      serverName: 'docker-desktop',
      platformName: 'Docker Desktop',
      serverVersion: '29.2.0',
      labels: [],
      error: null
    },
    wslDocker: {
      distro: 'Ubuntu',
      dockerHost: 'unix:///var/run/docker.sock',
      available: true,
      socketPath: '/var/run/docker.sock',
      socketPresent: true,
      socketOwner: 'root:docker',
      socketMode: '660',
      systemdState: 'running',
      serviceState: 'active',
      context: 'default',
      osType: 'linux',
      operatingSystem: 'Ubuntu 24.04.2 LTS',
      serverName: 'ubuntu-native',
      platformName: 'Docker Engine - Community',
      serverVersion: '28.1.1',
      labels: [],
      isDockerDesktop: false,
      error: null
    },
    runnerServices: {
      running: ['actions.runner.compare-vi-cli-action.develop.1', 'actions.runner.compare-vi-cli-action.develop.2'],
      stopped: []
    }
  });
  writeJson(path.join(runtimeDir, 'delivery-agent-host-isolation.json'), {
    schema: 'priority/delivery-agent-host-isolation@v1',
    lastStatus: 'native-wsl',
    lastAction: 'collect',
    preemptedServices: [],
    counters: {
      runnerPreemptionCount: 0
    }
  });
  writeJson(path.join(runtimeDir, 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: '2026-03-21T01:12:00.000Z',
    outcome: 'lane-tracked',
    cyclesCompleted: 3,
    stopRequested: false,
    activeLane: {
      laneId: 'issue-origin-1736-jarvis-session-observer',
      issue: 1736
    }
  });
  writeJson(path.join(runtimeDir, 'delivery-agent-wsl-daemon-pid.json'), {
    schema: 'priority/unattended-delivery-agent-wsl-daemon-pid@v1',
    generatedAt: '2026-03-21T01:13:00.000Z',
    pid: 4242,
    running: true,
    unitName: 'comparevi-daemon',
    distro: 'Ubuntu'
  });
  writeJson(path.join(runtimeDir, 'docker-daemon-engine.json'), {
    schema: 'priority/runtime-daemon-docker-engine@v1',
    generatedAt: '2026-03-21T01:14:00.000Z',
    requiredOs: 'linux',
    lockPath: 'tests/results/_agent/runtime/docker-daemon-engine.lock',
    lockAcquired: false,
    docker: {
      command: 'docker',
      os: 'linux',
      context: {
        previous: 'desktop-windows',
        active: 'desktop-linux',
        mode: 'context-use',
        switched: true
      }
    }
  });
  writeText(path.join(runtimeDir, 'runtime-daemon-wsl.log'), 'daemon-line-1\ndaemon-line-2\n');
  writeText(path.join(runtimeDir, 'docker-daemon-logs.txt'), 'docker-line-1\ndocker-line-2\n');

  const { report, outputPath } = await observeJarvisSessionObserver({
    repoRoot,
    runtimeDir,
    policyPath: path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'),
    outputPath: path.join(runtimeDir, 'jarvis-session-observer.json'),
    tailLines: 2
  });

  assert.equal(report.status, 'active');
  assert.equal(report.summary.activeSessionCount, 1);
  assert.equal(report.summary.totalSessionCount, 1);
  assert.equal(report.daemon.daemonCutover.status, 'ready');
  assert.equal(report.daemon.daemonCutover.readyForLinuxDaemon, true);
  assert.deepEqual(report.daemon.daemonCutover.requiredActions, []);
  assert.equal(report.sessions[0].source, 'concurrent-lane-status');
  assert.equal(report.sessions[0].dockerContext, 'desktop-windows');
  assert.equal(report.sessions[0].dockerServerOs, 'windows');
  assert.deepEqual(report.daemon.logs.runtimeDaemonWsl.lines, ['daemon-line-1', 'daemon-line-2']);
  assert.deepEqual(report.daemon.logs.dockerDaemon.lines, ['docker-line-1', 'docker-line-2']);
  assert.equal(fs.existsSync(outputPath), true);
});

test('observeJarvisSessionObserver blocks when native-wsl daemon cutover is still desktop-backed', async () => {
  const repoRoot = createTempDir();
  const runtimeDir = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime');
  writeJson(path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'), {
    schema: 'priority/delivery-agent-policy@v1',
    capitalFabric: {
      specialtyLanes: [
        {
          id: 'jarvis',
          enabled: true,
          primaryRecordedResponsibility: 'Sagan',
          maxInstanceCount: 2,
          preferredExecutionPlane: 'local-docker-windows',
          preferredContainerImage: 'nationalinstruments/labview:2026q1-windows'
        }
      ]
    },
    dockerRuntime: {
      provider: 'native-wsl',
      dockerHost: 'unix:///var/run/docker.sock',
      expectedOsType: 'linux',
      expectedContext: '',
      manageDockerEngine: false,
      allowHostEngineMutation: false
    }
  });
  writeJson(path.join(runtimeDir, 'daemon-host-signal.json'), {
    schema: 'priority/delivery-agent-host-signal@v1',
    generatedAt: '2026-03-21T01:10:00.000Z',
    status: 'desktop-backed',
    provider: 'desktop',
    daemonFingerprint: 'abc12345',
    previousFingerprint: 'abc12345',
    fingerprintChanged: false,
    reasons: ['WSL Docker server resolves to Docker Desktop instead of a native distro-owned daemon.'],
    windowsDocker: {
      available: true,
      context: 'desktop-windows',
      osType: 'windows',
      operatingSystem: 'Docker Desktop',
      serverName: 'docker-desktop',
      platformName: 'Docker Desktop',
      serverVersion: '29.2.0',
      labels: [],
      error: null
    },
    wslDocker: {
      distro: 'Ubuntu',
      dockerHost: 'unix:///var/run/docker.sock',
      available: true,
      socketPath: '/var/run/docker.sock',
      socketPresent: true,
      socketOwner: 'root:docker',
      socketMode: '660',
      systemdState: 'running',
      serviceState: 'active',
      context: 'default',
      osType: 'linux',
      operatingSystem: 'Docker Desktop',
      serverName: 'docker-desktop',
      platformName: 'Docker Desktop',
      serverVersion: '29.2.0',
      labels: ['com.docker.desktop.address=unix:///var/run/docker-cli.sock'],
      isDockerDesktop: true,
      error: null
    },
    runnerServices: {
      running: ['actions.runner.compare-vi-cli-action.develop.1', 'actions.runner.compare-vi-cli-action.develop.2'],
      stopped: []
    }
  });

  const { report } = await observeJarvisSessionObserver({
    repoRoot,
    runtimeDir,
    policyPath: path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'),
    outputPath: path.join(runtimeDir, 'jarvis-session-observer.json'),
    tailLines: 2
  });

  assert.equal(report.status, 'blocked');
  assert.equal(report.summary.activeSessionCount, 0);
  assert.equal(report.daemon.daemonCutover.status, 'cutover-required');
  assert.equal(report.daemon.daemonCutover.requiresOperatorCutover, true);
  assert.deepEqual(report.daemon.daemonCutover.requiredActions, [
    'Stop or explicitly govern the 2 running actions.runner.* services on this host.',
    'Switch WSL Docker to a distro-owned Linux daemon before reusing the daemon-first Linux plane.',
    'Rerun priority:delivery:host:signal.',
    'Rerun priority:jarvis:status.'
  ]);
  assert.match(report.daemon.daemonCutover.reason, /cut over to a distro-owned Linux daemon/i);
});

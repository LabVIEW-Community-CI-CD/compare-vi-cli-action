import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { buildJarvisSessionObserverReport } from '../jarvis-session-observer.mjs';

function createTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'jarvis-session-observer-schema-'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function writeText(filePath, text) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, text, 'utf8');
}

test('jarvis session observer report matches the checked-in schema', async () => {
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
    logicalLaneActivation: {
      effectiveLogicalLaneCount: 2
    },
    activeLane: {
      laneId: 'issue-origin-1736-jarvis-session-observer',
      issue: 1736,
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
          dockerServerOs: 'windows'
        }
      }
    ]
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
      running: [],
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
  writeJson(path.join(runtimeDir, 'delivery-memory.json'), {
    schema: 'priority/delivery-memory@v1',
    generatedAt: '2026-03-21T01:05:00.000Z',
    summary: {
      targetSlotCount: 4
    }
  });
  writeText(path.join(runtimeDir, 'runtime-daemon-wsl.log'), 'daemon-line-1\ndaemon-line-2\n');
  writeText(path.join(runtimeDir, 'docker-daemon-logs.txt'), 'docker-line-1\ndocker-line-2\n');

  const report = await buildJarvisSessionObserverReport({
    repoRoot,
    runtimeDir,
    policyPath: path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'),
    outputPath: path.join(runtimeDir, 'jarvis-session-observer.json'),
    tailLines: 2
  });

  const schema = JSON.parse(
    fs.readFileSync(path.join(process.cwd(), 'docs', 'schemas', 'jarvis-session-observer-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

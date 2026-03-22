#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { buildConcurrentLanePlan } from '../concurrent-lane-plan.mjs';

function createHostPlaneReport({ native32Status = 'ready', nativeParallelLabVIEWSupported = true } = {}) {
  return {
    schema: 'labview-2026-host-plane-report@v1',
    generatedAt: '2026-03-21T00:00:00.000Z',
    host: { os: 'windows', computerName: 'builder' },
    runner: { hostIsRunner: true, runnerName: 'builder', githubActions: false },
    docker: {
      operatorLabels: ['linux-docker-fast-loop', 'windows-docker-fast-loop', 'dual-docker-fast-loop']
    },
    policy: {
      authoritativePlanes: [
        'docker-desktop/linux-container-2026',
        'docker-desktop/windows-container-2026'
      ],
      hostNativeShadowPlane: {
        plane: 'native-labview-2026-32',
        role: 'acceleration-surface',
        authoritative: false,
        executionMode: 'manual-opt-in',
        hostedCiAllowed: false,
        promotionPrerequisites: [
          'docker-desktop/linux-container-2026',
          'docker-desktop/windows-container-2026'
        ]
      }
    },
    native: {
      parallelLabVIEWSupported: nativeParallelLabVIEWSupported,
      sharedCliAcrossNativePlanes: true,
      recommendedParallelPlanes: nativeParallelLabVIEWSupported
        ? ['native-labview-2026-64', 'native-labview-2026-32']
        : [],
      planes: {
        x64: { status: 'ready' },
        x32: { status: native32Status }
      }
    },
    executionPolicy: {
      mutuallyExclusivePairs: {
        pairs: [{ left: 'docker-desktop/linux-container-2026', right: 'docker-desktop/windows-container-2026' }]
      },
      provenParallelPairs: {
        pairs: [
          { left: 'docker-desktop/windows-container-2026', right: 'native-labview-2026-64' },
          { left: 'native-labview-2026-64', right: 'native-labview-2026-32' }
        ]
      },
      candidateParallelPairs: {
        pairs: [{ left: 'native-labview-2026-64', right: 'native-labview-2026-32' }]
      }
    }
  };
}

function createHostRamBudget(recommendedParallelism = 2) {
  return {
    schema: 'priority/host-ram-budget@v1',
    selectedProfile: {
      id: 'windows-mirror-heavy',
      recommendedParallelism
    }
  };
}

function createDockerRuntimeSnapshot({
  provider = 'desktop',
  expectedOsType = 'linux',
  expectedContext = 'desktop-linux',
  expectedDockerHost = 'unix:///var/run/docker.sock',
  observedOsType = 'linux',
  observedContext = 'desktop-linux',
  observedDockerHost = 'unix:///var/run/docker.sock',
  status = 'ok'
} = {}) {
  return {
    schema: 'docker-runtime-determinism@v1',
    expected: {
      provider,
      osType: expectedOsType,
      context: expectedContext,
      dockerHost: expectedDockerHost,
      manageDockerEngine: true,
      allowHostEngineMutation: false
    },
    observed: {
      osType: observedOsType,
      context: observedContext,
      dockerHost: observedDockerHost
    },
    result: {
      status
    }
  };
}

test('buildConcurrentLanePlan prefers hosted lanes plus the current local docker lane', () => {
  const report = buildConcurrentLanePlan({
    hostPlaneReport: createHostPlaneReport(),
    hostRamBudget: createHostRamBudget(),
    dockerRuntimeSnapshot: createDockerRuntimeSnapshot()
  });

  assert.equal(report.host.dockerServerOs, 'linux');
  assert.equal(report.dockerRuntimeCutover.schema, 'priority/docker-runtime-cutover-contract@v1');
  assert.equal(report.dockerRuntimeCutover.cutoverMode, 'desktop-linux-engine');
  assert.equal(report.dockerRuntimeCutover.canReuseLinuxDaemon, true);
  assert.equal(report.dockerRuntimeCutover.restoreMode, 'none');
  assert.equal(report.summary.dockerCutoverMode, 'desktop-linux-engine');
  assert.equal(report.summary.dockerCutoverReusable, true);
  assert.equal(report.summary.dockerCutoverRestoreMode, 'none');
  assert.equal(report.summary.recommendedBundleId, 'hosted-plus-manual-linux-docker');
  assert.deepEqual(report.recommendedBundle.laneIds, [
    'hosted-linux-proof',
    'hosted-windows-proof',
    'manual-linux-docker'
  ]);
  const linuxLane = report.lanes.find((entry) => entry.id === 'manual-linux-docker');
  const windowsLane = report.lanes.find((entry) => entry.id === 'manual-windows-docker');
  assert.equal(linuxLane.availability, 'available');
  assert.equal(windowsLane.availability, 'unavailable');
  assert.ok(
    report.observations.includes('local-docker-linux-and-windows-remain-mutually-exclusive'),
    'expected explicit mutual-exclusion observation'
  );
});

test('buildConcurrentLanePlan records the pinned WSL2 Linux cutover contract when the runtime snapshot is native-wsl', () => {
  const report = buildConcurrentLanePlan({
    hostPlaneReport: createHostPlaneReport(),
    hostRamBudget: createHostRamBudget(),
    dockerRuntimeSnapshot: createDockerRuntimeSnapshot({
      provider: 'native-wsl',
      expectedOsType: 'linux',
      expectedContext: '',
      expectedDockerHost: 'unix:///var/run/docker.sock',
      observedOsType: 'linux',
      observedContext: '',
      observedDockerHost: 'unix:///var/run/docker.sock'
    })
  });

  assert.equal(report.dockerRuntimeCutover.cutoverMode, 'pinned-wsl2-linux-daemon');
  assert.equal(report.dockerRuntimeCutover.canReuseLinuxDaemon, true);
  assert.equal(report.dockerRuntimeCutover.requiresHostMutation, false);
  assert.equal(report.dockerRuntimeCutover.requiresWslShutdown, false);
  assert.equal(report.dockerRuntimeCutover.restoreMode, 'wsl-shutdown');
  assert.equal(report.dockerRuntimeCutover.restoreRequired, true);
  assert.equal(report.summary.dockerCutoverMode, 'pinned-wsl2-linux-daemon');
  assert.equal(report.summary.dockerCutoverReusable, true);
  assert.equal(report.summary.dockerCutoverRestoreMode, 'wsl-shutdown');
  assert.equal(report.summary.recommendedBundleId, 'hosted-plus-manual-linux-docker');
});

test('buildConcurrentLanePlan falls back to hosted plus shadow when docker engine evidence is unavailable', () => {
  const report = buildConcurrentLanePlan({
    hostPlaneReport: createHostPlaneReport(),
    hostRamBudget: createHostRamBudget(1),
    dockerRuntimeSnapshot: null,
    shadowMode: 'prefer'
  });

  assert.equal(report.summary.recommendedBundleId, 'hosted-plus-host-native-32-shadow');
  assert.deepEqual(report.recommendedBundle.laneIds, [
    'hosted-linux-proof',
    'hosted-windows-proof',
    'host-native-32-shadow'
  ]);
  const shadowLane = report.lanes.find((entry) => entry.id === 'host-native-32-shadow');
  assert.equal(shadowLane.availability, 'available');
  assert.equal(shadowLane.metadata.recommendedParallelism, 1);
  assert.equal(shadowLane.metadata.authoritative, false);
  assert.equal(shadowLane.metadata.executionMode, 'manual-opt-in');
  assert.equal(shadowLane.metadata.hostedCiAllowed, false);
  assert.deepEqual(shadowLane.metadata.promotionPrerequisites, [
    'docker-desktop/linux-container-2026',
    'docker-desktop/windows-container-2026'
  ]);
  assert.ok(report.observations.includes('host-native-32-shadow-remains-non-authoritative'));
});

test('buildConcurrentLanePlan disables the shadow lane when the native 32-bit plane is unavailable', () => {
  const report = buildConcurrentLanePlan({
    hostPlaneReport: createHostPlaneReport({ native32Status: 'missing', nativeParallelLabVIEWSupported: false }),
    hostRamBudget: createHostRamBudget(),
    dockerRuntimeSnapshot: null,
    shadowMode: 'auto'
  });

  const shadowLane = report.lanes.find((entry) => entry.id === 'host-native-32-shadow');
  assert.equal(shadowLane.availability, 'unavailable');
  assert.ok(shadowLane.reasons.includes('native-32-plane-not-ready'));
  assert.equal(report.summary.recommendedBundleId, 'hosted-only-proof');
});

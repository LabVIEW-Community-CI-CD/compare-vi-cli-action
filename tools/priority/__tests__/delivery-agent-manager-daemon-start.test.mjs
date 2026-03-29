import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'lib', 'delivery-agent-manager.js');

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

test('buildWslRuntimeDaemonEnvironment exports WSL-safe git paths for linked worktrees', async () => {
  const { buildWslRuntimeDaemonEnvironment, buildWslRuntimeDaemonSetenvArgs } = await loadModule();

  const environment = buildWslRuntimeDaemonEnvironment({
    repoRoot: 'E:/comparevi-lanes/1824-wsl-runtime-daemon-pid-clean',
    runtimeDir: 'tests/results/_agent/runtime-1824-live',
    daemonPollIntervalSeconds: 60,
    leaseOwner: 'sveld@GHOST:default',
    leaseRootWsl: '/mnt/c/dev/compare-vi-cli-action/compare-vi-cli-action/.git/worktrees/1824-wsl-runtime-daemon-pid-clean/agent-writer-leases',
    daemonLogPath: 'E:/comparevi-lanes/1824-wsl-runtime-daemon-pid-clean/tests/results/_agent/runtime-1824-live/runtime-daemon-wsl.log',
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    stopOnIdle: true,
    runtimeEpochId: '2026-03-26T20-10-00-000Z-labview-community-ci-cd-compare-vi-cli-action',
    gitDirPath: 'C:/dev/compare-vi-cli-action/compare-vi-cli-action/.git/worktrees/1824-wsl-runtime-daemon-pid-clean',
  });

  assert.equal(
    environment.GIT_DIR,
    '/mnt/c/dev/compare-vi-cli-action/compare-vi-cli-action/.git/worktrees/1824-wsl-runtime-daemon-pid-clean'
  );
  assert.equal(environment.GIT_WORK_TREE, '/mnt/e/comparevi-lanes/1824-wsl-runtime-daemon-pid-clean');
  assert.equal(
    environment.COMPAREVI_RUNTIME_DAEMON_LOG,
    '/mnt/e/comparevi-lanes/1824-wsl-runtime-daemon-pid-clean/tests/results/_agent/runtime-1824-live/runtime-daemon-wsl.log'
  );
  assert.equal(
    environment.COMPAREVI_RUNTIME_DAEMON_RUNTIME_EPOCH_ID,
    '2026-03-26T20-10-00-000Z-labview-community-ci-cd-compare-vi-cli-action'
  );
  assert.equal(environment.COMPAREVI_RUNTIME_DAEMON_STOP_ON_IDLE, 'true');

  const setenvArgs = buildWslRuntimeDaemonSetenvArgs(environment);
  assert.ok(setenvArgs.includes('--setenv=GIT_DIR=/mnt/c/dev/compare-vi-cli-action/compare-vi-cli-action/.git/worktrees/1824-wsl-runtime-daemon-pid-clean'));
  assert.ok(setenvArgs.includes('--setenv=GIT_WORK_TREE=/mnt/e/comparevi-lanes/1824-wsl-runtime-daemon-pid-clean'));
  assert.ok(
    setenvArgs.includes(
      '--setenv=COMPAREVI_RUNTIME_DAEMON_RUNTIME_EPOCH_ID=2026-03-26T20-10-00-000Z-labview-community-ci-cd-compare-vi-cli-action'
    )
  );
});

test('resolveDaemonStartFailure routes fresh observer reports when the daemon exits before PID observation', async () => {
  const { resolveDaemonStartFailure } = await loadModule();
  const notBefore = new Date('2026-03-22T18:00:00.000Z');

  const resolution = resolveDaemonStartFailure({
    error: new Error("WSL runtime daemon did not return a valid PID for distro 'Ubuntu'."),
    stopOnIdle: true,
    heartbeat: {
      generatedAt: '2026-03-22T18:00:02.000Z',
      outcome: 'idle-stop',
    },
    report: {
      generatedAt: '2026-03-22T18:00:03.000Z',
      outcome: 'idle-stop',
    },
    notBefore,
  });

  assert.equal(resolution.status, 'routed-observer-outcome');
  assert.equal(resolution.reason, 'daemon-exited-cleanly-before-pid-observed');
  assert.equal(resolution.observerOutcome, 'idle-stop');
  assert.equal(resolution.observerOutcomeSource, 'report');
  assert.equal(resolution.heartbeatFresh, true);
  assert.equal(resolution.reportFresh, true);
});

test('resolveDaemonStartFailure routes fresh heartbeat proof when the report is not yet written', async () => {
  const { resolveDaemonStartFailure } = await loadModule();
  const notBefore = new Date('2026-03-22T18:00:00.000Z');

  const resolution = resolveDaemonStartFailure({
    error: new Error("WSL runtime daemon did not return a valid PID for distro 'Ubuntu'."),
    stopOnIdle: true,
    heartbeat: {
      generatedAt: '2026-03-22T18:00:02.000Z',
      outcome: 'idle-stop',
    },
    report: {
      generatedAt: '2026-03-22T17:59:59.000Z',
      outcome: 'idle-stop',
    },
    notBefore,
  });

  assert.equal(resolution.status, 'routed-observer-outcome');
  assert.equal(resolution.observerOutcome, 'idle-stop');
  assert.equal(resolution.observerOutcomeSource, 'heartbeat');
  assert.equal(resolution.heartbeatFresh, true);
  assert.equal(resolution.reportFresh, false);
});

test('resolveDaemonStartFailure routes fresh structured non-idle outcomes instead of crashing on missing PID', async () => {
  const { resolveDaemonStartFailure } = await loadModule();
  const notBefore = new Date('2026-03-22T18:00:00.000Z');

  const resolution = resolveDaemonStartFailure({
    error: new Error("WSL runtime daemon did not return a valid PID for distro 'Ubuntu'."),
    stopOnIdle: true,
    heartbeat: {
      generatedAt: '2026-03-22T18:00:02.000Z',
      outcome: 'worker-ready-blocked',
    },
    report: null,
    notBefore,
  });

  assert.equal(resolution.status, 'routed-observer-outcome');
  assert.equal(resolution.reason, 'daemon-emitted-structured-outcome-before-pid-observed');
  assert.equal(resolution.observerOutcome, 'worker-ready-blocked');
  assert.equal(resolution.observerOutcomeSource, 'heartbeat');
});

test('resolveDaemonStartFailure stays strict when idle-stop proof is stale', async () => {
  const { resolveDaemonStartFailure } = await loadModule();
  const notBefore = new Date('2026-03-22T18:00:00.000Z');

  const resolution = resolveDaemonStartFailure({
    error: new Error("WSL runtime daemon did not return a valid PID for distro 'Ubuntu'."),
    stopOnIdle: true,
    heartbeat: {
      generatedAt: '2026-03-22T17:59:58.000Z',
      outcome: 'idle-stop',
    },
    report: {
      generatedAt: '2026-03-22T17:59:59.000Z',
      outcome: 'idle-stop',
    },
    notBefore,
  });

  assert.equal(resolution.status, 'unhandled');
  assert.equal(resolution.reason, 'daemon-pid-missing-without-fresh-idle-stop-proof');
  assert.equal(resolution.observerOutcomeSource, null);
});

test('resolveDaemonStartFailure still routes fresh structured outcomes when stop-on-idle is disabled', async () => {
  const { resolveDaemonStartFailure } = await loadModule();
  const notBefore = new Date('2026-03-22T18:00:00.000Z');

  const resolution = resolveDaemonStartFailure({
    error: new Error("WSL runtime daemon did not return a valid PID for distro 'Ubuntu'."),
    stopOnIdle: false,
    heartbeat: {
      generatedAt: '2026-03-22T18:00:02.000Z',
      outcome: 'idle-stop',
    },
    report: {
      generatedAt: '2026-03-22T18:00:03.000Z',
      outcome: 'idle-stop',
    },
    notBefore,
  });

  assert.equal(resolution.status, 'routed-observer-outcome');
  assert.equal(resolution.observerOutcome, 'idle-stop');
  assert.equal(resolution.observerOutcomeSource, 'report');
});

test('resolveManagerCycleFailureState opens the circuit after repeated fresh blocked outcomes', async () => {
  const { resolveManagerCycleFailureState } = await loadModule();
  const notBefore = new Date('2026-03-22T18:00:00.000Z');

  const resolution = resolveManagerCycleFailureState({
    daemonAlive: false,
    blockedByHostConflict: false,
    stopOnIdle: true,
    heartbeat: {
      generatedAt: '2026-03-22T18:00:02.000Z',
      outcome: 'worker-blocked',
      activeLane: {
        laneId: 'origin-2010',
        issue: 2010,
        blockerClass: 'validation-failure',
        taskPacket: {
          evidence: {
            lane: {
              workerSlotId: 'worker-slot-1',
            },
          },
        },
      },
    },
    report: {
      generatedAt: '2026-03-22T18:00:03.000Z',
      outcome: 'worker-blocked',
    },
    notBefore,
    priorFailureCount: 2,
    priorFailureSignature: 'worker-blocked|origin-2010|2010|worker-slot-1|validation-failure',
    maxConsecutiveCycleFailures: 3,
  });

  assert.equal(resolution.status, 'fail-closed');
  assert.equal(resolution.shouldStop, true);
  assert.equal(resolution.consecutiveCycleFailures, 3);
  assert.equal(resolution.failureSignature, 'worker-blocked|origin-2010|2010|worker-slot-1|validation-failure');
  assert.equal(resolution.observerOutcome, 'worker-blocked');
  assert.equal(resolution.observerOutcomeSource, 'report');
  assert.equal(resolution.reason, 'repeated-daemon-cycle-failures');
});

test('resolveManagerCycleFailureState clears the failure streak on fresh idle-stop proof', async () => {
  const { resolveManagerCycleFailureState } = await loadModule();
  const notBefore = new Date('2026-03-22T18:00:00.000Z');

  const resolution = resolveManagerCycleFailureState({
    daemonAlive: false,
    blockedByHostConflict: false,
    stopOnIdle: true,
    heartbeat: {
      generatedAt: '2026-03-22T18:00:02.000Z',
      outcome: 'idle-stop',
    },
    report: {
      generatedAt: '2026-03-22T18:00:03.000Z',
      outcome: 'idle-stop',
    },
    notBefore,
    priorFailureCount: 2,
    priorFailureSignature: 'worker-blocked|origin-2010|2010|worker-slot-1|validation-failure',
    maxConsecutiveCycleFailures: 3,
  });

  assert.equal(resolution.status, 'clear');
  assert.equal(resolution.shouldStop, false);
  assert.equal(resolution.consecutiveCycleFailures, 0);
  assert.equal(resolution.failureSignature, '');
  assert.equal(resolution.observerOutcome, 'idle-stop');
  assert.equal(resolution.reason, 'idle-stop');
});

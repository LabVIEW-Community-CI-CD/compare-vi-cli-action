#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile as execFileCb } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const execFile = promisify(execFileCb);

async function readText(relativePath) {
  return readFile(path.join(repoRoot, relativePath), 'utf8');
}

async function writeJson(filePath, payload) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

async function invokeManagerStatus(relativeRuntimeDir) {
  const { stdout } = await execFile(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(repoRoot, 'tools', 'priority', 'Manage-UnattendedDeliveryAgent.ps1'),
      '-Status',
      '-RuntimeDir',
      relativeRuntimeDir
    ],
    {
      cwd: repoRoot,
      windowsHide: true
    }
  );
  return JSON.parse(stdout);
}

test('package scripts expose delivery-agent commands and keep unattended aliases intact', async () => {
  const packageJson = JSON.parse(await readText('package.json'));
  assert.equal(packageJson.scripts['priority:delivery:memory'], 'node tools/priority/delivery-memory.mjs');
  assert.equal(
    packageJson.scripts['priority:delivery:host:signal'],
    'tsc -p tsconfig.json && node dist/tools/priority/delivery-host-signal.js'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:ensure'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Ensure -SleepMode'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:status'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Status'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:stop'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Stop'
  );
  assert.equal(
    packageJson.scripts['priority:unattended:sleep:ensure'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Ensure -SleepMode'
  );
  assert.equal(
    packageJson.scripts['priority:unattended:project-board:ensure'],
    'pwsh -NoLogo -NoProfile -File tools/priority/Manage-UnattendedDeliveryAgent.ps1 -Ensure -SleepMode'
  );
});

test('delivery-agent policy wires coding turns to the Codex runner', async () => {
  const policy = JSON.parse(await readText('tools/priority/delivery-agent.policy.json'));
  assert.deepEqual(policy.codingTurnCommand, ['node', 'tools/priority/run-delivery-turn-with-codex.mjs']);
});

test('delivery-agent manager and run scripts target the WSL runtime daemon instead of the legacy loop', async () => {
  const manager = await readText('tools/priority/Manage-UnattendedDeliveryAgent.ps1');
  const runner = await readText('tools/priority/Run-UnattendedDeliveryAgent.ps1');
  const ensurePrereqs = await readText('tools/priority/Ensure-WSLDeliveryPrereqs.ps1');

  assert.match(manager, /Ensure-WSLDeliveryPrereqs\.ps1/);
  assert.match(manager, /CodexStateHygienePath/);
  assert.match(manager, /DeliveryMemoryPath/);
  assert.match(manager, /HostSignalPath/);
  assert.match(manager, /HostIsolationPath/);
  assert.match(manager, /HostTracePath/);
  assert.match(manager, /ManagerTracePath/);
  assert.match(manager, /DaemonLogPath/);
  assert.match(manager, /WslNativeDockerPath/);
  assert.match(manager, /delivery-host-signal\.js/);
  assert.match(manager, /wsl\.exe/);
  assert.match(manager, /heartbeatDiagnostics/);
  assert.match(manager, /RuntimeStatePath/);
  assert.match(manager, /TaskPacketPath/);
  assert.match(manager, /logTail/);
  assert.match(manager, /function Write-LogTailTrace/);
  assert.match(manager, /EventType 'log-tail'/);
  assert.match(manager, /stale-before-current-manager/);
  assert.match(runner, /runtime-daemon\.mjs/);
  assert.match(runner, /WslDistro/);
  assert.match(runner, /AGENT_WRITER_LEASE_OWNER/);
  assert.match(runner, /AGENT_WRITER_LEASE_ROOT/);
  assert.match(runner, /DOCKER_HOST='unix:\/\/\/var\/run\/docker\.sock'/);
  assert.match(runner, /COMPAREVI_DOCKER_RUNTIME_PROVIDER='native-wsl'/);
  assert.match(runner, /--lease-root/);
  assert.match(runner, /exec >> '\$LogPathWsl' 2>&1/);
  assert.match(runner, /exec \$\(\$quotedArgs -join ' '\)/);
  assert.doesNotMatch(runner, /exec \$\(\$quotedArgs -join ' '\) >> '\$LogPathWsl' 2>&1/);
  assert.match(runner, /\[System\.IO\.File\]::WriteAllText\(/);
  assert.match(runner, /\[System\.Text\.UTF8Encoding\]::new\(\$false\)/);
  assert.match(runner, /Invoke-CodexStateHygiene/);
  assert.match(runner, /Invoke-DeliveryMemory/);
  assert.match(runner, /Invoke-DeliveryHostSignal/);
  assert.match(runner, /delivery-agent-host-trace\.ndjson/);
  assert.match(runner, /delivery-agent-manager-trace\.ndjson/);
  assert.match(runner, /Write-ManagerTrace/);
  assert.match(runner, /function Write-LogTailTrace/);
  assert.match(runner, /EventType 'log-tail'/);
  assert.match(runner, /daemonLogTail/);
  assert.match(runner, /systemd-run --user/);
  assert.match(runner, /Get-WslRuntimeDaemonUnitName/);
  assert.doesNotMatch(runner, /-PreviousFingerprint \(if/);
  assert.match(runner, /delivery-memory\.json/);
  assert.match(runner, /CodexHygieneIntervalCycles/);
  assert.match(ensurePrereqs, /nodejs\.org\/dist/);
  assert.match(ensurePrereqs, /@openai\/codex/);
  assert.match(ensurePrereqs, /codex_needs_install=0/);
  assert.match(ensurePrereqs, /core\.worktree/);
  assert.match(ensurePrereqs, /ensure-native-wsl-docker\.sh/);
  assert.match(ensurePrereqs, /delivery-host-signal\.js/);
  assert.match(ensurePrereqs, /flock -w 120 9/);
  assert.match(ensurePrereqs, /systemctl reset-failed docker\.service docker\.socket/);
  assert.match(ensurePrereqs, /healthy_service_reused='false'/);
  assert.match(ensurePrereqs, /service_restarted='false'/);
  assert.match(ensurePrereqs, /--repo-root \$RepoRoot --apply --report/);
  assert.match(ensurePrereqs, /status = 'ok'/);
  assert.match(ensurePrereqs, /report = \$report/);
  assert.doesNotMatch(ensurePrereqs, /systemctl restart docker\.service/);
  assert.match(runner, /Invoke-EnsureWslDeliveryPrereqs/);
  assert.match(runner, /wsl-prereqs-failed/);
});

test('delivery-agent manager status synthesizes the active lane from the freshest heartbeat when delivery state is stale', async () => {
  const manager = await readText('tools/priority/Manage-UnattendedDeliveryAgent.ps1');

  assert.match(manager, /function Resolve-DeliveryStateForStatus/);
  assert.match(manager, /derivedFromHeartbeat/);
  assert.match(manager, /derivedFromRuntimeState/);
  assert.match(manager, /Read-JsonFile -Path \$Paths\.ObserverHeartbeatPath/);
  assert.match(manager, /Read-JsonFile -Path \$Paths\.RuntimeStatePath/);
  assert.match(manager, /Read-JsonFile -Path \$Paths\.TaskPacketPath/);
});

test('delivery-agent manager status ignores stale heartbeat state from before the current manager start', async (t) => {
  const runtimeDirPath = await mkdtemp(path.join(repoRoot, 'tests', 'results', '_agent', 'tmp-manager-status-stale-'));
  const relativeRuntimeDir = path.relative(repoRoot, runtimeDirPath);
  t.after(async () => {
    await rm(runtimeDirPath, { recursive: true, force: true });
  });

  const now = Date.now();
  const deliveryGeneratedAt = new Date(now - 120_000).toISOString();
  const heartbeatGeneratedAt = new Date(now - 60_000).toISOString();
  const managerStartedAt = new Date(now - 10_000).toISOString();
  const daemonStartedAt = new Date(now - 9_000).toISOString();

  await writeJson(path.join(runtimeDirPath, 'delivery-agent-state.json'), {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: deliveryGeneratedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: runtimeDirPath,
    status: 'blocked',
    laneLifecycle: 'blocked',
    activeCodingLanes: 0,
    activeLane: {
      schema: 'priority/delivery-agent-lane-state@v1',
      generatedAt: deliveryGeneratedAt,
      laneId: 'origin-1010',
      issue: 1010,
      branch: 'issue/origin-1010-example',
      forkRemote: 'origin',
      blockerClass: 'validation-failure',
      laneLifecycle: 'blocked'
    }
  });
  await writeJson(path.join(runtimeDirPath, 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: heartbeatGeneratedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    outcome: 'lease-blocked',
    activeLane: {
      laneId: 'origin-959',
      issue: 959,
      branch: 'issue/origin-959-example',
      forkRemote: 'origin',
      blockerClass: 'none'
    }
  });
  await writeJson(path.join(runtimeDirPath, 'delivery-agent-manager-pid.json'), {
    schema: 'priority/unattended-delivery-agent-manager-pid@v1',
    startedAt: managerStartedAt,
    pid: 0
  });
  await writeJson(path.join(runtimeDirPath, 'delivery-agent-wsl-daemon-pid.json'), {
    schema: 'priority/unattended-delivery-agent-wsl-daemon-pid@v1',
    startedAt: daemonStartedAt,
    pid: 0
  });

  const status = await invokeManagerStatus(relativeRuntimeDir);
  const traceText = await readFile(path.join(runtimeDirPath, 'delivery-agent-manager-trace.ndjson'), 'utf8');

  assert.equal(status.delivery.activeLane.issue, 1010);
  assert.equal(status.heartbeatDiagnostics.usedHeartbeat, false);
  assert.equal(status.heartbeatDiagnostics.reason, 'stale-before-current-manager');
  assert.deepEqual(status.logTail.daemon, []);
  assert.match(traceText, /"eventType":"status"/);
});

test('delivery-agent manager status derives from a fresh heartbeat when no delivery state exists', async (t) => {
  const runtimeDirPath = await mkdtemp(path.join(repoRoot, 'tests', 'results', '_agent', 'tmp-manager-status-fresh-'));
  const relativeRuntimeDir = path.relative(repoRoot, runtimeDirPath);
  t.after(async () => {
    await rm(runtimeDirPath, { recursive: true, force: true });
  });

  const now = Date.now();
  const managerStartedAt = new Date(now - 120_000).toISOString();
  const heartbeatGeneratedAt = new Date(now - 15_000).toISOString();

  await writeJson(path.join(runtimeDirPath, 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: heartbeatGeneratedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    outcome: 'lane-tracked',
    activeLane: {
      laneId: 'origin-959',
      issue: 959,
      branch: 'issue/origin-959-example',
      forkRemote: 'origin',
      blockerClass: 'none',
      taskPacket: {
        status: 'coding'
      }
    }
  });
  await writeJson(path.join(runtimeDirPath, 'delivery-agent-manager-pid.json'), {
    schema: 'priority/unattended-delivery-agent-manager-pid@v1',
    startedAt: managerStartedAt,
    pid: 0
  });

  const status = await invokeManagerStatus(relativeRuntimeDir);

  assert.equal(status.delivery.activeLane.issue, 959);
  assert.equal(status.delivery.derivedFromHeartbeat, true);
  assert.equal(status.heartbeatDiagnostics.usedHeartbeat, true);
  assert.equal(status.heartbeatDiagnostics.reason, 'fresh-heartbeat');
  assert.ok(Array.isArray(status.logTail.daemon));
});

test('delivery-agent manager status prefers a fresher runtime state and task packet over stale delivery and heartbeat artifacts', async (t) => {
  const runtimeDirPath = await mkdtemp(path.join(repoRoot, 'tests', 'results', '_agent', 'tmp-manager-status-runtime-'));
  const relativeRuntimeDir = path.relative(repoRoot, runtimeDirPath);
  t.after(async () => {
    await rm(runtimeDirPath, { recursive: true, force: true });
  });

  const now = Date.now();
  const deliveryGeneratedAt = new Date(now - 300_000).toISOString();
  const heartbeatGeneratedAt = new Date(now - 240_000).toISOString();
  const runtimeGeneratedAt = new Date(now - 30_000).toISOString();
  const taskPacketGeneratedAt = new Date(now - 15_000).toISOString();
  const managerStartedAt = new Date(now - 180_000).toISOString();
  const daemonStartedAt = new Date(now - 180_000).toISOString();

  await writeJson(path.join(runtimeDirPath, 'delivery-agent-state.json'), {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: deliveryGeneratedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: runtimeDirPath,
    status: 'blocked',
    laneLifecycle: 'blocked',
    activeCodingLanes: 0,
    activeLane: {
      schema: 'priority/delivery-agent-lane-state@v1',
      generatedAt: deliveryGeneratedAt,
      laneId: 'origin-959',
      issue: 959,
      branch: 'issue/origin-959-example',
      forkRemote: 'origin',
      blockerClass: 'validation-failure',
      laneLifecycle: 'blocked'
    }
  });
  await writeJson(path.join(runtimeDirPath, 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: heartbeatGeneratedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    outcome: 'lane-tracked',
    activeLane: {
      laneId: 'origin-959',
      issue: 959,
      branch: 'issue/origin-959-example',
      forkRemote: 'origin',
      blockerClass: 'none',
      taskPacket: {
        status: 'coding'
      }
    }
  });
  await writeJson(path.join(runtimeDirPath, 'runtime-state.json'), {
    schema: 'priority/runtime-supervisor-state@v1',
    generatedAt: runtimeGeneratedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    lifecycle: {
      status: 'blocked',
      lastAction: 'step'
    },
    activeLane: {
      laneId: 'origin-962',
      issue: 962,
      branch: 'issue/origin-962-example',
      forkRemote: 'origin',
      blockerClass: 'none',
      taskPacket: {
        generatedAt: runtimeGeneratedAt,
        status: 'coding',
        branch: {
          name: 'issue/origin-962-example',
          forkRemote: 'origin'
        },
        pullRequest: {
          url: null
        },
        evidence: {
          delivery: {
            selectedActionType: 'advance-standing-issue',
            laneLifecycle: 'coding'
          }
        }
      }
    }
  });
  await writeJson(path.join(runtimeDirPath, 'task-packet.json'), {
    schema: 'priority/runtime-worker-task-packet@v1',
    generatedAt: taskPacketGeneratedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    laneId: 'origin-962',
    status: 'coding',
    branch: {
      name: 'issue/origin-962-example',
      forkRemote: 'origin'
    },
    pullRequest: {
      url: null
    },
    checks: {
      blockerClass: 'none'
    },
    evidence: {
      delivery: {
        selectedActionType: 'advance-standing-issue',
        laneLifecycle: 'coding'
      }
    }
  });
  await writeJson(path.join(runtimeDirPath, 'delivery-agent-manager-pid.json'), {
    schema: 'priority/unattended-delivery-agent-manager-pid@v1',
    startedAt: managerStartedAt,
    pid: 0
  });
  await writeJson(path.join(runtimeDirPath, 'delivery-agent-wsl-daemon-pid.json'), {
    schema: 'priority/unattended-delivery-agent-wsl-daemon-pid@v1',
    startedAt: daemonStartedAt,
    pid: 0
  });

  const status = await invokeManagerStatus(relativeRuntimeDir);

  assert.equal(status.delivery.activeLane.issue, 962);
  assert.equal(status.delivery.activeLane.branch, 'issue/origin-962-example');
  assert.equal(status.delivery.laneLifecycle, 'coding');
  assert.equal(status.delivery.activeCodingLanes, 1);
  assert.equal(status.delivery.derivedFromRuntimeState, true);
  assert.equal(status.heartbeatDiagnostics.usedHeartbeat, false);
  assert.equal(status.heartbeatDiagnostics.usedRuntimeState, true);
  assert.equal(status.heartbeatDiagnostics.reason, 'runtime-state-current');
  assert.equal(path.basename(status.delivery.artifacts.statePath), 'runtime-state.json');
  assert.equal(path.basename(status.delivery.artifacts.lanePath), 'task-packet.json');
});

test('delivery-agent manager status emits bounded log-tail trace events for daemon and manager logs', async (t) => {
  const runtimeDirPath = await mkdtemp(path.join(repoRoot, 'tests', 'results', '_agent', 'tmp-manager-status-log-tail-'));
  const relativeRuntimeDir = path.relative(repoRoot, runtimeDirPath);
  t.after(async () => {
    await rm(runtimeDirPath, { recursive: true, force: true });
  });

  await writeFile(path.join(runtimeDirPath, 'runtime-daemon-wsl.log'), 'daemon line 1\ndaemon line 2\n', 'utf8');
  await writeFile(path.join(runtimeDirPath, 'delivery-agent-manager.log'), 'manager out 1\n', 'utf8');
  await writeFile(path.join(runtimeDirPath, 'delivery-agent-manager.stderr.log'), 'manager err 1\n', 'utf8');

  const status = await invokeManagerStatus(relativeRuntimeDir);
  const traceText = await readFile(path.join(runtimeDirPath, 'delivery-agent-manager-trace.ndjson'), 'utf8');

  assert.deepEqual(status.logTail.daemon, ['daemon line 1', 'daemon line 2']);
  assert.deepEqual(status.logTail.managerStdout, ['manager out 1']);
  assert.deepEqual(status.logTail.managerStderr, ['manager err 1']);
  assert.match(traceText, /"eventType":"log-tail"/);
  assert.match(traceText, /"source":"daemon"/);
  assert.match(traceText, /"source":"manager-stdout"/);
  assert.match(traceText, /"source":"manager-stderr"/);
  assert.match(traceText, /"reason":"status:status"/);
});

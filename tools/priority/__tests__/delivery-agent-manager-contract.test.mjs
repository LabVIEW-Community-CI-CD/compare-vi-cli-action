#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile as execFileCb } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
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

async function copyRepoFile(relativePath, tempRoot) {
  const destinationPath = path.join(tempRoot, relativePath);
  await mkdir(path.dirname(destinationPath), { recursive: true });
  await copyFile(path.join(repoRoot, relativePath), destinationPath);
  return destinationPath;
}

async function writeFakeDeliveryAgentBuildScript(tempRoot) {
  const scriptPath = path.join(tempRoot, 'tools', 'npm', 'run-script.mjs');
  await mkdir(path.dirname(scriptPath), { recursive: true });
  await writeFile(
    scriptPath,
    `#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
process.stdout.write('added 66 packages in 2s\\n');
process.stdout.write('> compare-vi-cli-action@0.6.3 build\\n');
const distDir = path.join(repoRoot, 'dist', 'tools', 'priority');
mkdirSync(distDir, { recursive: true });
writeFileSync(
  path.join(distDir, 'delivery-agent.js'),
  "#!/usr/bin/env node\\n" +
    "const command = process.argv[2] || '';\\n" +
    "const reportPathIndex = process.argv.indexOf('--report-path');\\n" +
    "const reportPath = reportPathIndex >= 0 ? process.argv[reportPathIndex + 1] : null;\\n" +
    "process.stdout.write(JSON.stringify({ schema: 'test/delivery-agent@v1', command, reportPath }, null, 2) + '\\\\n');\\n",
  'utf8',
);
`,
    'utf8',
  );
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
  assert.equal(
    packageJson.scripts['priority:delivery:memory'],
    'node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/delivery-memory.ts --fallback-dist dist/tools/priority/delivery-memory.js'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:host:signal'],
    'node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/delivery-host-signal.ts --fallback-dist dist/tools/priority/delivery-host-signal.js'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:ensure'],
    'node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/delivery-agent.ts --fallback-dist dist/tools/priority/delivery-agent.js -- ensure --sleep-mode'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:status'],
    'node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/delivery-agent.ts --fallback-dist dist/tools/priority/delivery-agent.js -- status'
  );
  assert.equal(
    packageJson.scripts['priority:delivery:agent:stop'],
    'node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/delivery-agent.ts --fallback-dist dist/tools/priority/delivery-agent.js -- stop'
  );
  assert.equal(
    packageJson.scripts['priority:unattended:sleep:ensure'],
    'node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/delivery-agent.ts --fallback-dist dist/tools/priority/delivery-agent.js -- ensure --sleep-mode'
  );
  assert.equal(
    packageJson.scripts['priority:unattended:project-board:ensure'],
    'node tools/npm/run-local-typescript.mjs --project tsconfig.json --entry tools/priority/delivery-agent.ts --fallback-dist dist/tools/priority/delivery-agent.js -- ensure --sleep-mode'
  );
});

test('delivery-agent policy wires coding turns to the Codex runner', async () => {
  const policy = JSON.parse(await readText('tools/priority/delivery-agent.policy.json'));
  assert.deepEqual(policy.codingTurnCommand, ['node', 'dist/tools/priority/run-delivery-turn-with-codex.js']);
  assert.equal(policy.maxActiveCodingLanes, 4);
  assert.equal(policy.workerPool.targetSlotCount, 4);
  assert.deepEqual(
    policy.workerPool.providers.map((provider) => provider.id),
    ['local-codex', 'hosted-github-workflow', 'remote-copilot-lane', 'local-shadow-native']
  );
  assert.deepEqual(policy.workerPool.providers[0].capabilities, {
    executionPlane: 'local',
    assignmentMode: 'interactive-coding',
    dispatchSurface: 'runtime-harness',
    completionMode: 'sync',
    requiresLocalCheckout: true
  });
});

test('delivery-agent wrappers delegate to the compiled node CLI', async () => {
  const manager = await readText('tools/priority/Manage-UnattendedDeliveryAgent.ps1');
  const runner = await readText('tools/priority/Run-UnattendedDeliveryAgent.ps1');
  const ensurePrereqs = await readText('tools/priority/Ensure-WSLDeliveryPrereqs.ps1');
  const cli = await readText('tools/priority/delivery-agent.ts');

  assert.match(manager, /delivery-agent\.js/);
  assert.match(manager, /'ensure'|\"ensure\"/);
  assert.match(manager, /'status'|\"status\"/);
  assert.match(manager, /'stop'|\"stop\"/);
  assert.match(manager, /DeliveryAgentWrapper\.Build\.psm1/);
  assert.match(manager, /Initialize-DeliveryAgentDistScript/);
  assert.match(runner, /delivery-agent\.js/);
  assert.match(runner, /'run'|\"run\"/);
  assert.match(runner, /DeliveryAgentWrapper\.Build\.psm1/);
  assert.match(runner, /Initialize-DeliveryAgentDistScript/);
  assert.match(ensurePrereqs, /delivery-agent\.js/);
  assert.match(ensurePrereqs, /prereqs/);
  assert.match(ensurePrereqs, /DeliveryAgentWrapper\.Build\.psm1/);
  assert.match(ensurePrereqs, /Initialize-DeliveryAgentDistScript/);
  assert.doesNotMatch(manager, /run-script\.mjs'\) build/);
  assert.doesNotMatch(runner, /run-script\.mjs'\) build/);
  assert.doesNotMatch(ensurePrereqs, /run-script\.mjs'\) build/);
  assert.doesNotMatch(manager, /Start-Process -FilePath 'pwsh'/);
  assert.doesNotMatch(runner, /Start-Process -FilePath 'pwsh'/);
  assert.match(cli, /ensureManagerCommand/);
  assert.match(cli, /stopManagerCommand/);
  assert.match(cli, /runManagerLoop/);
  assert.match(cli, /runPrereqsCommand/);
});

test('delivery-agent manager status synthesizes the active lane from the freshest heartbeat when delivery state is stale', async () => {
  const common = await readText('tools/priority/lib/delivery-agent-common.ts');
  const manager = await readText('tools/priority/lib/delivery-agent-manager.ts');

  assert.match(common, /export function resolveDeliveryStateForStatus/);
  assert.match(common, /derivedFromHeartbeat/);
  assert.match(common, /derivedFromRuntimeState/);
  assert.match(manager, /readJsonFile\(paths\.observerHeartbeatPath\)/);
  assert.match(manager, /readJsonFile\(paths\.runtimeStatePath\)/);
  assert.match(manager, /readJsonFile\(paths\.taskPacketPath\)/);
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

test('Manage-UnattendedDeliveryAgent suppresses fallback build chatter before JSON status output', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-wrapper-status-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  await copyRepoFile('tools/priority/Manage-UnattendedDeliveryAgent.ps1', tempRoot);
  await copyRepoFile('tools/priority/DeliveryAgentWrapper.Build.psm1', tempRoot);
  await writeFakeDeliveryAgentBuildScript(tempRoot);

  const { stdout, stderr } = await execFile(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(tempRoot, 'tools', 'priority', 'Manage-UnattendedDeliveryAgent.ps1'),
      '-Status',
      '-RuntimeDir',
      'tests/results/_agent/runtime'
    ],
    {
      cwd: tempRoot,
      windowsHide: true
    }
  );

  assert.equal(stderr, '');
  assert.doesNotMatch(stdout, /added 66 packages|compare-vi-cli-action@0\.6\.3 build/i);
  assert.deepEqual(JSON.parse(stdout), {
    schema: 'test/delivery-agent@v1',
    command: 'status',
    reportPath: null
  });
});

test('Ensure-WSLDeliveryPrereqs suppresses fallback build chatter before JSON prereq output', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-wrapper-prereqs-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  await copyRepoFile('tools/priority/Ensure-WSLDeliveryPrereqs.ps1', tempRoot);
  await copyRepoFile('tools/priority/DeliveryAgentWrapper.Build.psm1', tempRoot);
  await writeFakeDeliveryAgentBuildScript(tempRoot);

  const { stdout, stderr } = await execFile(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(tempRoot, 'tools', 'priority', 'Ensure-WSLDeliveryPrereqs.ps1'),
      '-Distro',
      'Ubuntu',
      '-NodeVersion',
      'v24.13.1',
      '-ReportPath',
      'tests/results/_agent/runtime/wsl-delivery-prereqs.json'
    ],
    {
      cwd: tempRoot,
      windowsHide: true
    }
  );

  assert.equal(stderr, '');
  assert.doesNotMatch(stdout, /added 66 packages|compare-vi-cli-action@0\.6\.3 build/i);
  assert.deepEqual(JSON.parse(stdout), {
    schema: 'test/delivery-agent@v1',
    command: 'prereqs',
    reportPath: 'tests/results/_agent/runtime/wsl-delivery-prereqs.json'
  });
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

test('delivery-agent manager status exposes observer telemetry as non-blocking state', async (t) => {
  const runtimeDirPath = await mkdtemp(path.join(repoRoot, 'tests', 'results', '_agent', 'tmp-manager-status-observer-'));
  const relativeRuntimeDir = path.relative(repoRoot, runtimeDirPath);
  t.after(async () => {
    await rm(runtimeDirPath, { recursive: true, force: true });
  });

  await writeJson(path.join(runtimeDirPath, 'codex-state-hygiene.json'), {
    schema: 'priority/codex-state-hygiene-report@v1',
    generatedAt: new Date('2026-03-11T20:00:00.000Z').toISOString(),
    observer: {
      plane: 'observer',
      source: 'codex-state-hygiene',
      status: 'degraded',
      deliveryCritical: false,
      hotPathEligible: false,
      deliveryImpact: 'none',
      reasons: ['thread-stream-state-changed'],
      counts: {
        gitOriginAndRoots: 0,
        localEnvironmentsUnsupported: 0,
        openInTargetUnsupported: 0,
        unhandledBroadcastNoHandler: 1,
        threadStreamStateChanged: 1,
        threadQueuedFollowupsChanged: 0,
        databaseLocked: 0,
        slowStatement: 0
      }
    }
  });

  const status = await invokeManagerStatus(relativeRuntimeDir);

  assert.equal(status.observer.plane, 'observer');
  assert.equal(status.observer.status, 'degraded');
  assert.equal(status.observer.deliveryCritical, false);
  assert.equal(status.observer.hotPathEligible, false);
  assert.equal(status.observer.deliveryImpact, 'none');
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

test('Manage-UnattendedDeliveryAgent.ps1 remains a thin wrapper around the JS delivery-agent implementation', async () => {
  const manager = await readText('tools/priority/Manage-UnattendedDeliveryAgent.ps1');

  assert.doesNotMatch(manager, /function Resolve-DeliveryStateForStatus/);
  assert.doesNotMatch(manager, /function Get-SanitizedSegment/);
  assert.match(manager, /delivery-agent\.js/i);
});

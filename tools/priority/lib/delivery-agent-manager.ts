// @ts-nocheck

import { closeSync, mkdirSync, openSync, rmSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { refreshDeliveryMemory } from '../delivery-memory.js';
import {
  DAEMON_PID_SCHEMA,
  DEFAULTS,
  MANAGER_CYCLE_SCHEMA,
  MANAGER_PID_SCHEMA,
  MANAGER_REPORT_SCHEMA,
  MANAGER_STATE_SCHEMA,
  STOP_REQUEST_SCHEMA,
  convertToWslPath,
  getArtifactPaths,
  getOptionalDateTimeProperty,
  getOptionalIntProperty,
  getOptionalProperty,
  getOptionalStringProperty,
  getStableLeaseOwner,
  getWslRuntimeDaemonUnitName,
  normalizeText,
  readJsonFile,
  readLogTail,
  resolveHostSignalForStatus,
  resolveDeliveryStateForStatus,
  resolveGitDirPath,
  resolveObserverTelemetry,
  resolveRepoRoot,
  resolveWorkspaceQuarantine,
  runCommand,
  shellQuote,
  sleep,
  testProcessAlive,
  testWslProcessAlive,
  toIso,
  writeJsonFile,
  writeLogTailTrace,
  writeManagerTrace,
} from './delivery-agent-common.js';
import {
  invokeDeliveryHostSignal,
  runRepoHygiene,
  runPrereqsCommand,
  updateHostIsolationState,
} from './delivery-agent-prereqs.js';

async function invokeDeliveryMemory({ repoRoot, repo, runtimeDir, outPath }) {
  try {
    const { report } = await refreshDeliveryMemory({
      repoRoot,
      repository: repo,
      runtimeDir,
      outPath,
    });
    return report;
  } catch (error) {
    return {
      status: 'error',
      reason: 'tool-failed',
      reportPath: outPath,
      message: error?.message || String(error),
    };
  }
}

function buildManagerChildCommand({ repoRoot, options }) {
  const localTypescriptRunnerPath = path.join(repoRoot, 'tools', 'npm', 'run-local-typescript.mjs');
  return [
    localTypescriptRunnerPath,
    '--project',
    'tsconfig.json',
    '--entry',
    'tools/priority/delivery-agent.ts',
    '--fallback-dist',
    'dist/tools/priority/delivery-agent.js',
    '--',
    'run',
    '--repo',
    options.repo,
    '--runtime-dir',
    options.runtimeDir,
    '--daemon-poll-interval-seconds',
    String(options.daemonPollIntervalSeconds),
    '--cycle-interval-seconds',
    String(options.cycleIntervalSeconds),
    '--max-cycles',
    String(options.maxCycles),
    '--wsl-distro',
    options.wslDistro,
  ];
}

async function invokeMonitoringWorkInjection({
  cycle,
  repoRoot,
  repo,
  runtimeDir,
  distro,
  tracePath,
}) {
  try {
    const monitoringWorkInjectionModulePath = path.join(repoRoot, 'tools', 'priority', 'monitoring-work-injection.mjs');
    const {
      DEFAULT_OUTPUT_PATH: defaultMonitoringWorkInjectionOutputPath,
      runMonitoringWorkInjection,
    } = await import(pathToFileURL(monitoringWorkInjectionModulePath).href);
    const injection = await runMonitoringWorkInjection({
      repoRoot,
      repository: repo,
      outputPath: defaultMonitoringWorkInjectionOutputPath,
    });
    const summary = injection?.report?.summary ?? {};
    writeManagerTrace({
      repo,
      runtimeDir,
      distro,
      tracePath,
      eventType: 'monitoring-work-injection',
      detail: {
        cycle,
        status: summary.status || 'unknown',
        triggerId: summary.triggerId || null,
        issueNumber: Number.isInteger(summary.issueNumber) ? summary.issueNumber : null,
        issueUrl: summary.issueUrl || null,
        outputPath: injection?.outputPath || null,
      },
    });
    return {
      status: summary.status || 'unknown',
      triggerId: summary.triggerId || null,
      issueNumber: Number.isInteger(summary.issueNumber) ? summary.issueNumber : null,
      issueUrl: summary.issueUrl || null,
      outputPath: injection?.outputPath || null,
      error: null,
    };
  } catch (error) {
    const message = error?.message || String(error);
    writeManagerTrace({
      repo,
      runtimeDir,
      distro,
      tracePath,
      eventType: 'monitoring-work-injection-failed',
      detail: { cycle, message },
    });
    return {
      status: 'error',
      triggerId: null,
      issueNumber: null,
      issueUrl: null,
      outputPath: null,
      error: message,
    };
  }
}

export function resolvePostRepairHostConflict({
  repairedHostSignal,
  collectedHostSignal,
}) {
  const repairedStatus = getOptionalStringProperty(repairedHostSignal, 'status');
  const repairedProvider = getOptionalStringProperty(repairedHostSignal, 'provider');
  const repairedFingerprint = getOptionalStringProperty(repairedHostSignal, 'daemonFingerprint');
  const collectedStatus = getOptionalStringProperty(collectedHostSignal, 'status');
  const collectedProvider = getOptionalStringProperty(collectedHostSignal, 'provider');
  const collectedFingerprint = getOptionalStringProperty(collectedHostSignal, 'daemonFingerprint');

  const routedRunnerConflict =
    repairedStatus === 'native-wsl' &&
    repairedProvider === 'native-wsl' &&
    collectedStatus === 'runner-conflict' &&
    collectedProvider === 'native-wsl' &&
    Boolean(repairedFingerprint) &&
    repairedFingerprint === collectedFingerprint;

  if (routedRunnerConflict) {
    return {
      status: 'routed-runner-conflict',
      blockedByHostConflict: false,
      effectiveHostSignal: repairedHostSignal,
      reason: 'native-daemon-repair-succeeded-runner-services-remain-observed',
      repairedStatus,
      collectedStatus,
      repairedFingerprint,
      collectedFingerprint,
    };
  }

  const effectiveHostSignal = collectedHostSignal || repairedHostSignal || null;
  const effectiveStatus = getOptionalStringProperty(effectiveHostSignal, 'status');
  return {
    status: effectiveStatus === 'native-wsl' ? 'clear' : 'blocked',
    blockedByHostConflict: effectiveStatus !== 'native-wsl',
    effectiveHostSignal,
    reason: effectiveStatus === 'native-wsl' ? 'host-runtime-native-wsl' : 'post-repair-conflict-persisted',
    repairedStatus,
    collectedStatus,
    repairedFingerprint,
    collectedFingerprint,
  };
}

export function resolveDaemonStartFailure({
  error,
  stopOnIdle,
  heartbeat,
  report,
  notBefore,
}) {
  const message = error?.message || String(error);
  const isPidMissing = message.includes('WSL runtime daemon did not return a valid PID');
  const heartbeatOutcome = getOptionalStringProperty(heartbeat, 'outcome');
  const reportOutcome = getOptionalStringProperty(report, 'outcome');
  const heartbeatGeneratedAt = getOptionalDateTimeProperty(heartbeat, 'generatedAt');
  const reportGeneratedAt = getOptionalDateTimeProperty(report, 'generatedAt');
  const notBeforeAt =
    notBefore instanceof Date
      ? notBefore
      : typeof notBefore === 'string'
        ? getOptionalDateTimeProperty({ notBefore }, 'notBefore')
        : null;
  const heartbeatFresh = !notBeforeAt || Boolean(heartbeatGeneratedAt && heartbeatGeneratedAt >= notBeforeAt);
  const reportFresh = !notBeforeAt || Boolean(reportGeneratedAt && reportGeneratedAt >= notBeforeAt);

  let observerOutcome = null;
  let observerOutcomeSource = null;
  if (reportOutcome && reportFresh) {
    observerOutcome = reportOutcome;
    observerOutcomeSource = 'report';
  } else if (heartbeatOutcome && heartbeatFresh) {
    observerOutcome = heartbeatOutcome;
    observerOutcomeSource = 'heartbeat';
  }

  if (isPidMissing && observerOutcomeSource) {
    return {
      status: 'routed-observer-outcome',
      reason: observerOutcome === 'idle-stop'
        ? 'daemon-exited-cleanly-before-pid-observed'
        : 'daemon-emitted-structured-outcome-before-pid-observed',
      message,
      stopOnIdle: Boolean(stopOnIdle),
      observerOutcome,
      observerOutcomeSource,
      heartbeatOutcome,
      reportOutcome,
      heartbeatFresh,
      reportFresh,
    };
  }

  return {
    status: 'unhandled',
    reason: isPidMissing ? 'daemon-pid-missing-without-fresh-idle-stop-proof' : 'daemon-start-failed',
    message,
    stopOnIdle: Boolean(stopOnIdle),
    observerOutcome: null,
    observerOutcomeSource: null,
    heartbeatOutcome,
    reportOutcome,
    heartbeatFresh,
    reportFresh,
  };
}

export function buildWslRuntimeDaemonEnvironment({
  repoRoot,
  runtimeDir,
  daemonPollIntervalSeconds,
  leaseOwner,
  leaseRootWsl,
  daemonLogPath,
  repo,
  stopOnIdle,
  gitDirPath = resolveGitDirPath(repoRoot),
}) {
  const repoRootWsl = convertToWslPath(repoRoot);
  const daemonLogPathWsl = convertToWslPath(daemonLogPath);
  const gitDirWsl = convertToWslPath(gitDirPath);
  return {
    GIT_DIR: gitDirWsl,
    GIT_WORK_TREE: repoRootWsl,
    COMPAREVI_RUNTIME_DAEMON_LOG: daemonLogPathWsl,
    COMPAREVI_RUNTIME_DAEMON_CWD: repoRootWsl,
    COMPAREVI_RUNTIME_DAEMON_REPO: repo,
    COMPAREVI_RUNTIME_DAEMON_RUNTIME_DIR: runtimeDir,
    COMPAREVI_RUNTIME_DAEMON_LEASE_ROOT: leaseRootWsl,
    COMPAREVI_RUNTIME_DAEMON_POLL_INTERVAL: String(daemonPollIntervalSeconds),
    AGENT_WRITER_LEASE_OWNER: leaseOwner,
    DOCKER_HOST: DEFAULTS.dockerHost,
    COMPAREVI_DOCKER_RUNTIME_PROVIDER: 'native-wsl',
    COMPAREVI_DOCKER_EXPECTED_CONTEXT: '',
    COMPAREVI_RUNTIME_DAEMON_STOP_ON_IDLE: stopOnIdle ? 'true' : 'false',
  };
}

export function buildWslRuntimeDaemonSetenvArgs(environment) {
  return Object.entries(environment).map(([key, value]) => `--setenv=${key}=${value}`);
}

export function startWslRuntimeDaemon({
  repoRoot,
  runtimeDir,
  distro,
  daemonPollIntervalSeconds,
  leaseOwner,
  leaseRootWsl,
  daemonLogPath,
  repo,
  unitName,
  stopOnIdle,
}) {
  const launchScriptPath = path.join(repoRoot, 'tools', 'priority', 'bash', 'start-runtime-daemon.sh');
  const launchScriptPathWsl = convertToWslPath(launchScriptPath);
  const environment = buildWslRuntimeDaemonEnvironment({
    repoRoot,
    runtimeDir,
    daemonPollIntervalSeconds,
    leaseOwner,
    leaseRootWsl,
    daemonLogPath,
    repo,
    stopOnIdle,
  });
  const systemdArgs = [
    '--user',
    '--unit',
    unitName,
    '--collect',
    '--quiet',
    ...buildWslRuntimeDaemonSetenvArgs(environment),
    'bash',
    launchScriptPathWsl,
  ].map((value) => shellQuote(value)).join(' ');

  runCommand('wsl.exe', ['-d', distro, '--', 'bash', '-lc', `systemctl --user reset-failed ${shellQuote(`${unitName}.service`)} >/dev/null 2>&1 || true`]);
  const startCommand = `systemd-run ${systemdArgs} >/dev/null && systemctl --user show ${shellQuote(`${unitName}.service`)} -p MainPID --value`;
  const result = runCommand('wsl.exe', ['-d', distro, '--', 'bash', '-lc', startCommand]);
  if (result.status !== 0) {
    throw new Error(`Failed to start WSL runtime daemon in distro '${distro}': ${normalizeText(result.stderr || result.stdout)}`);
  }
  const pid = Number(normalizeText(result.stdout.split(/\r?\n/).pop() || result.stdout));
  if (!Number.isInteger(pid) || pid <= 0) {
    throw new Error(`WSL runtime daemon did not return a valid PID for distro '${distro}'.`);
  }
  return pid;
}

export function stopWslRuntimeDaemon({ distro, unitName, processId }) {
  if (unitName) {
    runCommand('wsl.exe', ['-d', distro, '--', 'bash', '-lc', `systemctl --user stop ${shellQuote(`${unitName}.service`)} >/dev/null 2>&1 || true`]);
  }
  if (!Number.isInteger(processId) || processId <= 0) {
    return;
  }
  runCommand('wsl.exe', ['-d', distro, '--', 'bash', '-lc', `kill ${processId} >/dev/null 2>&1 || true`]);
  if (testWslProcessAlive(distro, processId)) {
    runCommand('wsl.exe', ['-d', distro, '--', 'bash', '-lc', `kill -9 ${processId} >/dev/null 2>&1 || true`]);
  }
}

export function emitStatus(options) {
  const repoRoot = options.repoRoot || resolveRepoRoot();
  const paths = getArtifactPaths(repoRoot, options.runtimeDir);
  const pidState = readJsonFile(paths.managerPidPath);
  const managerAlive = testProcessAlive(getOptionalIntProperty(pidState, 'pid'));
  const managerStartedAt = getOptionalDateTimeProperty(pidState, 'startedAt');
  const daemonState = readJsonFile(paths.wslDaemonPidPath);
  const daemonAlive = testWslProcessAlive(options.wslDistro, getOptionalIntProperty(daemonState, 'pid'));
  const daemonStartedAt = getOptionalDateTimeProperty(daemonState, 'startedAt');
  const heartbeat = readJsonFile(paths.observerHeartbeatPath);
  const taskPacket = readJsonFile(paths.taskPacketPath);
  const deliveryState = readJsonFile(paths.deliveryStatePath);
  const runtimeState = deliveryState ? null : readJsonFile(paths.runtimeStatePath);
  const resolvedDelivery = resolveDeliveryStateForStatus({
    repo: options.repo,
    runtimeDir: options.runtimeDir,
    deliveryState,
    heartbeat,
    runtimeState,
    taskPacket,
    paths,
    managerStartedAt,
    daemonStartedAt,
    daemonAlive,
  });
  const resolvedDeliveryState = resolvedDelivery.state;
  const deliveryMemory = readJsonFile(paths.deliveryMemoryPath);
  const codexStateHygiene = readJsonFile(paths.codexStateHygienePath);
  const observer = resolveObserverTelemetry(codexStateHygiene, paths.codexStateHygienePath);
  const workspaceQuarantine = getOptionalProperty(options, 'workspaceQuarantine') || resolveWorkspaceQuarantine(repoRoot);
  const hostSignalResolution = resolveHostSignalForStatus({
    hostSignal: readJsonFile(paths.hostSignalPath),
    managerStartedAt,
  });
  const hostSignal = hostSignalResolution.hostSignal;
  const hostIsolation = readJsonFile(paths.hostIsolationPath);
  const wslNativeDocker = readJsonFile(paths.wslNativeDockerPath);
  const daemonLogTail = readLogTail(paths.daemonLogPath);
  const managerLogTail = readLogTail(paths.runnerLogPath);
  const managerErrorLogTail = readLogTail(paths.runnerErrorPath);
  const status = managerAlive || daemonAlive ? 'running' : 'stopped';

  writeLogTailTrace({ repo: options.repo, runtimeDir: options.runtimeDir, distro: options.wslDistro, tracePath: paths.managerTracePath, source: 'daemon', reason: `status:${options.outcome}`, logPath: paths.daemonLogPath, lines: daemonLogTail });
  writeLogTailTrace({ repo: options.repo, runtimeDir: options.runtimeDir, distro: options.wslDistro, tracePath: paths.managerTracePath, source: 'manager-stdout', reason: `status:${options.outcome}`, logPath: paths.runnerLogPath, lines: managerLogTail });
  writeLogTailTrace({ repo: options.repo, runtimeDir: options.runtimeDir, distro: options.wslDistro, tracePath: paths.managerTracePath, source: 'manager-stderr', reason: `status:${options.outcome}`, logPath: paths.runnerErrorPath, lines: managerErrorLogTail });

  const report = {
    schema: MANAGER_REPORT_SCHEMA,
    generatedAt: toIso(),
    repo: options.repo,
    runtimeDir: options.runtimeDir,
    distro: options.wslDistro,
    status,
    outcome: options.outcome,
    manager: {
      pid: getOptionalIntProperty(pidState, 'pid'),
      alive: managerAlive,
      startedAt: getOptionalProperty(pidState, 'startedAt'),
      command: getOptionalProperty(pidState, 'command'),
    },
    daemon: {
      pid: getOptionalIntProperty(daemonState, 'pid'),
      alive: daemonAlive,
      startedAt: getOptionalProperty(daemonState, 'startedAt'),
      command: getOptionalProperty(daemonState, 'command'),
    },
    heartbeat,
    delivery: resolvedDeliveryState,
    heartbeatDiagnostics: resolvedDelivery.diagnostics,
    deliveryMemory,
    observer,
    workspaceQuarantine,
    codexStateHygiene,
    hostSignal,
    hostSignalDiagnostics: hostSignalResolution.diagnostics,
    hostIsolation,
    wslNativeDocker,
    logTail: {
      daemon: daemonLogTail,
      managerStdout: managerLogTail,
      managerStderr: managerErrorLogTail,
    },
    paths: {
      managerStatePath: paths.managerStatePath,
      managerPidPath: paths.managerPidPath,
      stopRequestPath: paths.stopRequestPath,
      observerHeartbeatPath: paths.observerHeartbeatPath,
      deliveryStatePath: paths.deliveryStatePath,
      runtimeStatePath: paths.runtimeStatePath,
      taskPacketPath: paths.taskPacketPath,
      deliveryMemoryPath: paths.deliveryMemoryPath,
      wslDaemonPidPath: paths.wslDaemonPidPath,
      codexStateHygienePath: paths.codexStateHygienePath,
      hostSignalPath: paths.hostSignalPath,
      hostIsolationPath: paths.hostIsolationPath,
      hostTracePath: paths.hostTracePath,
      managerTracePath: paths.managerTracePath,
      wslNativeDockerPath: paths.wslNativeDockerPath,
      daemonLogPath: paths.daemonLogPath,
      runnerLogPath: paths.runnerLogPath,
      runnerErrorPath: paths.runnerErrorPath,
    },
  };

  writeJsonFile(paths.managerStatePath, report);
  writeManagerTrace({
    repo: options.repo,
    runtimeDir: options.runtimeDir,
    distro: options.wslDistro,
    tracePath: paths.managerTracePath,
    eventType: 'status',
    detail: {
      outcome: options.outcome,
      managerAlive,
      daemonAlive,
      heartbeatReason: resolvedDelivery.diagnostics.reason,
      heartbeatUsed: Boolean(resolvedDelivery.diagnostics.usedHeartbeat),
      heartbeatGeneratedAt: resolvedDelivery.diagnostics.heartbeatGeneratedAt,
      observerStatus: getOptionalStringProperty(observer, 'status'),
      workspaceQuarantineStatus: getOptionalStringProperty(workspaceQuarantine, 'status'),
      daemonLogLineCount: daemonLogTail.length,
      managerStdoutLineCount: managerLogTail.length,
      managerStderrLineCount: managerErrorLogTail.length,
      hostSignalReason: hostSignalResolution.diagnostics.reason,
      hostSignalUsed: Boolean(hostSignalResolution.diagnostics.usedHostSignal),
    },
  });
  return report;
}

export async function ensureManagerCommand(options, dependencies = {}) {
  const repoRoot = options.repoRoot || resolveRepoRoot();
  const paths = getArtifactPaths(repoRoot, options.runtimeDir);
  const runPrereqs = dependencies.runPrereqsCommandFn ?? runPrereqsCommand;
  const runHygiene = dependencies.runRepoHygieneFn ?? runRepoHygiene;
  const invokeHostSignal = dependencies.invokeDeliveryHostSignalFn ?? invokeDeliveryHostSignal;
  const spawnProcess = dependencies.spawnFn ?? spawn;
  const sleepFn = dependencies.sleepFn ?? sleep;
  await runHygiene({ ...options, repoRoot });
  const workspaceQuarantine = resolveWorkspaceQuarantine(repoRoot);
  if (workspaceQuarantine.status === 'blocked') {
    writeManagerTrace({
      repo: options.repo,
      runtimeDir: options.runtimeDir,
      distro: options.wslDistro,
      tracePath: paths.managerTracePath,
      eventType: 'workspace-quarantine-blocked',
      detail: {
        reason: workspaceQuarantine.reason,
        trackedEntryCount: workspaceQuarantine.trackedEntryCount,
        untrackedEntryCount: workspaceQuarantine.untrackedEntryCount,
      },
    });
    return emitStatus({ ...options, repoRoot, outcome: 'workspace-quarantined', workspaceQuarantine });
  }

  await runPrereqs({ ...options, repoRoot });

  const existingPidState = readJsonFile(paths.managerPidPath);
  const existingPid = getOptionalIntProperty(existingPidState, 'pid');
  if (testProcessAlive(existingPid)) {
    return emitStatus({ ...options, repoRoot, outcome: 'already-running', workspaceQuarantine });
  }

  rmSync(paths.stopRequestPath, { force: true });
  invokeHostSignal({ mode: 'isolate', repoRoot, distro: options.wslDistro, paths, previousFingerprint: null, allowRunnerServices: false });

  mkdirSync(path.dirname(paths.runnerLogPath), { recursive: true });
  const stdoutFd = openSync(paths.runnerLogPath, 'a');
  const stderrFd = openSync(paths.runnerErrorPath, 'a');
  const childArgs = buildManagerChildCommand({ repoRoot, options });
  if (options.stopWhenNoOpenIssues || options.sleepMode) {
    childArgs.push('--stop-when-no-open-issues');
  }
  if (options.sleepMode) {
    childArgs.push('--sleep-mode');
  }
  const child = spawnProcess(process.execPath, childArgs, {
    cwd: repoRoot,
    detached: true,
    windowsHide: true,
    stdio: ['ignore', stdoutFd, stderrFd],
    env: process.env,
  });
  child.unref();
  closeSync(stdoutFd);
  closeSync(stderrFd);

  writeJsonFile(paths.managerPidPath, {
    schema: MANAGER_PID_SCHEMA,
    startedAt: toIso(),
    pid: child.pid,
    repo: options.repo,
    runtimeDir: options.runtimeDir,
    distro: options.wslDistro,
    command: [process.execPath, ...childArgs],
  });

  await sleepFn(2000);
  return emitStatus({ ...options, repoRoot, outcome: 'started', workspaceQuarantine });
}

export async function stopManagerCommand(options) {
  const repoRoot = options.repoRoot || resolveRepoRoot();
  const paths = getArtifactPaths(repoRoot, options.runtimeDir);
  writeJsonFile(paths.stopRequestPath, {
    schema: STOP_REQUEST_SCHEMA,
    requestedAt: toIso(),
    repo: options.repo,
    distro: options.wslDistro,
  });

  const managerPidState = readJsonFile(paths.managerPidPath);
  const managerPid = getOptionalIntProperty(managerPidState, 'pid');
  const deadline = Date.now() + options.stopWaitSeconds * 1000;
  while (Date.now() < deadline) {
    if (!testProcessAlive(managerPid)) {
      break;
    }
    await sleep(1000);
  }
  if (testProcessAlive(managerPid)) {
    try {
      process.kill(managerPid, 'SIGTERM');
    } catch {
      // ignore
    }
  }

  const daemonPidState = readJsonFile(paths.wslDaemonPidPath);
  const daemonPid = getOptionalIntProperty(daemonPidState, 'pid');
  if (testWslProcessAlive(options.wslDistro, daemonPid)) {
    runCommand('wsl.exe', ['-d', options.wslDistro, '--', 'bash', '-lc', `kill ${daemonPid} >/dev/null 2>&1 || true`]);
    await sleep(2000);
    if (testWslProcessAlive(options.wslDistro, daemonPid)) {
      runCommand('wsl.exe', ['-d', options.wslDistro, '--', 'bash', '-lc', `kill -9 ${daemonPid} >/dev/null 2>&1 || true`]);
    }
  }

  try {
    invokeDeliveryHostSignal({ mode: 'restore', repoRoot, distro: options.wslDistro, paths, previousFingerprint: null, allowRunnerServices: false });
  } catch (error) {
    process.stderr.write(`Warning: failed to restore runner services: ${error?.message || String(error)}\n`);
  }

  rmSync(paths.managerPidPath, { force: true });
  rmSync(paths.wslDaemonPidPath, { force: true });
  return emitStatus({ ...options, repoRoot, outcome: 'stopped' });
}

export async function runManagerLoop(options) {
  const repoRoot = options.repoRoot || resolveRepoRoot();
  const paths = getArtifactPaths(repoRoot, options.runtimeDir);
  mkdirSync(paths.runtimeDirPath, { recursive: true });

  const gitDirPath = resolveGitDirPath(repoRoot);
  const leaseRootWsl = convertToWslPath(path.join(gitDirPath, 'agent-writer-leases'));
  const leaseOwner = getStableLeaseOwner(repoRoot);
  const daemonUnitName = getWslRuntimeDaemonUnitName(options.repo);

  let cycle = 0;
  let activeDaemonPid = 0;
  let codexStateHygiene = readJsonFile(paths.codexStateHygienePath);
  let observerTelemetry = resolveObserverTelemetry(codexStateHygiene, paths.codexStateHygienePath);
  let deliveryMemory = null;
  let hostSignal = readJsonFile(paths.hostSignalPath);
  let hostIsolation = updateHostIsolationState({
    path: paths.hostIsolationPath,
    repo: options.repo,
    runtimeDir: options.runtimeDir,
    distro: options.wslDistro,
    hostSignalPath: paths.hostSignalPath,
    hostSignal,
  });
  let wslNativeDocker = readJsonFile(paths.wslNativeDockerPath);
  let monitoringWorkInjection = null;
  let hostConflictResolution = null;
  let blockedByHostConflict = false;

  try {
    await runPrereqsCommand({ ...options, repoRoot });
    writeManagerTrace({
      repo: options.repo,
      runtimeDir: options.runtimeDir,
      distro: options.wslDistro,
      tracePath: paths.managerTracePath,
      eventType: 'manager-started',
      detail: {
        ensureStatus: hostSignal?.status || 'ok',
        repoRootWsl: convertToWslPath(repoRoot),
        leaseOwner,
      },
    });
  } catch (error) {
    writeManagerTrace({
      repo: options.repo,
      runtimeDir: options.runtimeDir,
      distro: options.wslDistro,
      tracePath: paths.managerTracePath,
      eventType: 'wsl-prereqs-failed',
      detail: {
        repoRootWsl: convertToWslPath(repoRoot),
        leaseOwner,
        message: error?.message || String(error),
      },
    });
    throw error;
  }

  try {
    while (true) {
      if (options.maxCycles > 0 && cycle >= options.maxCycles) {
        break;
      }
      if (path.isAbsolute(paths.stopRequestPath) && readJsonFile(paths.stopRequestPath)) {
        break;
      }

      cycle += 1;
      const cycleStartedAt = new Date();
      const pidState = readJsonFile(paths.wslDaemonPidPath);
      activeDaemonPid = getOptionalIntProperty(pidState, 'pid');
      let daemonAlive = testWslProcessAlive(options.wslDistro, activeDaemonPid);
      writeManagerTrace({
        repo: options.repo,
        runtimeDir: options.runtimeDir,
        distro: options.wslDistro,
        tracePath: paths.managerTracePath,
        eventType: 'cycle-start',
        detail: { cycle, daemonPid: activeDaemonPid, daemonAlive },
      });

      const previousFingerprint = hostSignal?.daemonFingerprint ? String(hostSignal.daemonFingerprint) : null;
      const hostSignalResult = invokeDeliveryHostSignal({
        mode: 'collect',
        repoRoot,
        distro: options.wslDistro,
        paths,
        previousFingerprint,
        allowRunnerServices: false,
      });
      hostSignal = hostSignalResult.report;
      hostIsolation = hostSignalResult.isolation;
      wslNativeDocker = readJsonFile(paths.wslNativeDockerPath);
      writeManagerTrace({
        repo: options.repo,
        runtimeDir: options.runtimeDir,
        distro: options.wslDistro,
        tracePath: paths.managerTracePath,
        eventType: 'host-signal',
        detail: {
          cycle,
          status: hostSignal.status,
          provider: hostSignal.provider,
          daemonFingerprint: hostSignal.daemonFingerprint,
          fingerprintChanged: Boolean(hostSignal.fingerprintChanged),
        },
      });

      if (hostSignal.status === 'runner-conflict') {
        if (daemonAlive) {
          stopWslRuntimeDaemon({ distro: options.wslDistro, unitName: daemonUnitName, processId: activeDaemonPid });
          daemonAlive = false;
        }
        const isolated = invokeDeliveryHostSignal({
          mode: 'isolate',
          repoRoot,
          distro: options.wslDistro,
          paths,
          previousFingerprint: hostSignal.daemonFingerprint,
          allowRunnerServices: false,
        });
        hostSignal = isolated.report;
        hostIsolation = isolated.isolation;
        writeManagerTrace({
          repo: options.repo,
          runtimeDir: options.runtimeDir,
          distro: options.wslDistro,
          tracePath: paths.managerTracePath,
          eventType: 'runner-conflict-isolated',
          detail: { cycle, status: hostSignal.status, daemonPid: activeDaemonPid },
        });
      }

      blockedByHostConflict = false;
      monitoringWorkInjection = null;
      hostConflictResolution = null;
      if (hostSignal.status !== 'native-wsl') {
        if (daemonAlive) {
          stopWslRuntimeDaemon({ distro: options.wslDistro, unitName: daemonUnitName, processId: activeDaemonPid });
          daemonAlive = false;
        }
        rmSync(paths.wslDaemonPidPath, { force: true });
        hostIsolation = updateHostIsolationState({
          path: paths.hostIsolationPath,
          repo: options.repo,
          runtimeDir: options.runtimeDir,
          distro: options.wslDistro,
          hostSignalPath: paths.hostSignalPath,
          counterName: 'cyclesBlockedByHostRuntimeConflict',
          increment: 1,
          lastEventType: 'host-runtime-conflict',
          lastEventDetail: `status=${hostSignal.status}`,
          hostSignal,
        });
        writeManagerTrace({
          repo: options.repo,
          runtimeDir: options.runtimeDir,
          distro: options.wslDistro,
          tracePath: paths.managerTracePath,
          eventType: 'host-runtime-conflict',
          detail: { cycle, status: hostSignal.status },
        });

        let repairError = null;
        try {
          await runPrereqsCommand(options);
          hostSignal = readJsonFile(paths.hostSignalPath);
          hostIsolation = updateHostIsolationState({
            path: paths.hostIsolationPath,
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            hostSignalPath: paths.hostSignalPath,
            counterName: 'nativeDaemonRepairCount',
            increment: 1,
            lastEventType: 'native-daemon-repaired',
            lastEventDetail: `status=${hostSignal?.status || 'unknown'}`,
            hostSignal,
          });
          wslNativeDocker = readJsonFile(paths.wslNativeDockerPath);
          writeManagerTrace({
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            tracePath: paths.managerTracePath,
            eventType: 'native-daemon-repaired',
            detail: { cycle, status: hostSignal?.status || 'unknown' },
          });
        } catch (error) {
          repairError = error?.message || String(error);
          hostIsolation = updateHostIsolationState({
            path: paths.hostIsolationPath,
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            hostSignalPath: paths.hostSignalPath,
            lastEventType: 'native-daemon-repair-failed',
            lastEventDetail: repairError,
            hostSignal,
          });
          writeManagerTrace({
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            tracePath: paths.managerTracePath,
            eventType: 'native-daemon-repair-failed',
            detail: { cycle, message: repairError },
          });
        }

        if (!repairError) {
          const repairedHostSignal = hostSignal;
          const postRepairFingerprint = hostSignal?.daemonFingerprint ? String(hostSignal.daemonFingerprint) : null;
          const collected = invokeDeliveryHostSignal({
            mode: 'collect',
            repoRoot,
            distro: options.wslDistro,
            paths,
            previousFingerprint: postRepairFingerprint,
            allowRunnerServices: false,
          });
          hostIsolation = collected.isolation;
          hostConflictResolution = resolvePostRepairHostConflict({
            repairedHostSignal,
            collectedHostSignal: collected.report,
          });
          hostSignal = hostConflictResolution.effectiveHostSignal;
          writeJsonFile(paths.hostSignalPath, hostSignal);
          if (hostConflictResolution.status === 'routed-runner-conflict') {
            hostIsolation = updateHostIsolationState({
              path: paths.hostIsolationPath,
              repo: options.repo,
              runtimeDir: options.runtimeDir,
              distro: options.wslDistro,
              hostSignalPath: paths.hostSignalPath,
              lastEventType: 'runner-conflict-routed',
              lastEventDetail: hostConflictResolution.reason,
              hostSignal,
            });
            writeManagerTrace({
              repo: options.repo,
              runtimeDir: options.runtimeDir,
              distro: options.wslDistro,
              tracePath: paths.managerTracePath,
              eventType: 'runner-conflict-routed',
              detail: {
                cycle,
                reason: hostConflictResolution.reason,
                repairedStatus: hostConflictResolution.repairedStatus,
                collectedStatus: hostConflictResolution.collectedStatus,
                repairedFingerprint: hostConflictResolution.repairedFingerprint,
                collectedFingerprint: hostConflictResolution.collectedFingerprint,
              },
            });
          }
        }
        blockedByHostConflict = hostSignal.status !== 'native-wsl';
        if (blockedByHostConflict) {
          monitoringWorkInjection = await invokeMonitoringWorkInjection({
            cycle,
            repoRoot,
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            tracePath: paths.managerTracePath,
          });
        }
      }

      if (!blockedByHostConflict && !daemonAlive) {
        try {
          activeDaemonPid = startWslRuntimeDaemon({
            repoRoot,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            daemonPollIntervalSeconds: options.daemonPollIntervalSeconds,
            leaseOwner,
            leaseRootWsl,
            daemonLogPath: paths.daemonLogPath,
            repo: options.repo,
            unitName: daemonUnitName,
            stopOnIdle: options.stopWhenNoOpenIssues || options.sleepMode,
          });
          writeJsonFile(paths.wslDaemonPidPath, {
            schema: DAEMON_PID_SCHEMA,
            startedAt: toIso(),
            pid: activeDaemonPid,
            unit: `${daemonUnitName}.service`,
            repo: options.repo,
            distro: options.wslDistro,
            command: [
              'node',
              'tools/npm/run-local-typescript.mjs',
              '--project',
              'tsconfig.json',
              '--entry',
              'tools/priority/runtime-daemon.ts',
              '--fallback-dist',
              'dist/tools/priority/runtime-daemon.js',
              '--',
              '--repo',
              options.repo,
              '--runtime-dir',
              options.runtimeDir,
              '--lease-root',
              leaseRootWsl,
              '--poll-interval-seconds',
              String(options.daemonPollIntervalSeconds),
              '--execute-turn',
            ],
          });
          await sleep(3000);
          daemonAlive = testWslProcessAlive(options.wslDistro, activeDaemonPid);
          writeManagerTrace({
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            tracePath: paths.managerTracePath,
            eventType: 'daemon-started',
            detail: { cycle, daemonPid: activeDaemonPid, daemonAlive },
          });
        } catch (error) {
          // Stop-on-idle turns may exit cleanly before systemd exposes a stable MainPID.
          await sleep(1000);
          const daemonStartHeartbeat = readJsonFile(paths.observerHeartbeatPath);
          const daemonStartReport = readJsonFile(paths.observerReportPath);
          const daemonStartResolution = resolveDaemonStartFailure({
            error,
            stopOnIdle: options.stopWhenNoOpenIssues || options.sleepMode,
            heartbeat: daemonStartHeartbeat,
            report: daemonStartReport,
            notBefore: cycleStartedAt,
          });
          if (daemonStartResolution.status !== 'routed-observer-outcome') {
            throw error;
          }
          hostIsolation = updateHostIsolationState({
            path: paths.hostIsolationPath,
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            hostSignalPath: paths.hostSignalPath,
            lastEventType: 'daemon-observer-outcome-routed',
            lastEventDetail: `source=${daemonStartResolution.observerOutcomeSource}; outcome=${daemonStartResolution.observerOutcome}`,
            hostSignal,
          });
          activeDaemonPid = 0;
          daemonAlive = false;
          writeManagerTrace({
            repo: options.repo,
            runtimeDir: options.runtimeDir,
            distro: options.wslDistro,
            tracePath: paths.managerTracePath,
            eventType: 'daemon-observer-outcome-routed',
            detail: {
              cycle,
              reason: daemonStartResolution.reason,
              observerOutcome: daemonStartResolution.observerOutcome,
              observerOutcomeSource: daemonStartResolution.observerOutcomeSource,
              heartbeatOutcome: daemonStartResolution.heartbeatOutcome,
              reportOutcome: daemonStartResolution.reportOutcome,
              heartbeatFresh: daemonStartResolution.heartbeatFresh,
              reportFresh: daemonStartResolution.reportFresh,
            },
          });
        }
      }

      deliveryMemory = await invokeDeliveryMemory({
        repoRoot,
        repo: options.repo,
        runtimeDir: options.runtimeDir,
        outPath: paths.deliveryMemoryPath,
      });
      codexStateHygiene = readJsonFile(paths.codexStateHygienePath);
      observerTelemetry = resolveObserverTelemetry(codexStateHygiene, paths.codexStateHygienePath);

      const heartbeat = readJsonFile(paths.observerHeartbeatPath);
      const report = readJsonFile(paths.observerReportPath);
      if (!daemonAlive) {
        const daemonLogTail = readLogTail(paths.daemonLogPath);
        writeLogTailTrace({
          repo: options.repo,
          runtimeDir: options.runtimeDir,
          distro: options.wslDistro,
          tracePath: paths.managerTracePath,
          source: 'daemon',
          reason: 'daemon-not-running',
          logPath: paths.daemonLogPath,
          lines: daemonLogTail,
          detail: { cycle, daemonPid: activeDaemonPid },
        });
        writeManagerTrace({
          repo: options.repo,
          runtimeDir: options.runtimeDir,
          distro: options.wslDistro,
          tracePath: paths.managerTracePath,
          eventType: 'daemon-not-running',
          detail: {
            cycle,
            daemonPid: activeDaemonPid,
            heartbeatGeneratedAt: heartbeat?.generatedAt || null,
            heartbeatOutcome: heartbeat?.outcome || null,
            reportOutcome: report?.outcome || null,
            daemonLogLineCount: daemonLogTail.length,
          },
        });
      }

      const state = {
        schema: MANAGER_STATE_SCHEMA,
        generatedAt: toIso(),
        repo: options.repo,
        runtimeDir: options.runtimeDir,
        distro: options.wslDistro,
        cycle,
        daemon: { pid: activeDaemonPid, alive: daemonAlive },
        heartbeat,
        report,
        hostSignal,
        hostIsolation,
        wslNativeDocker,
        monitoringWorkInjection,
        hostConflictResolution,
        observer: observerTelemetry,
        codexStateHygiene,
        deliveryMemory,
        deliveryMemoryPath: paths.deliveryMemoryPath,
        hostSignalPath: paths.hostSignalPath,
        hostIsolationPath: paths.hostIsolationPath,
        hostTracePath: paths.hostTracePath,
        managerTracePath: paths.managerTracePath,
        wslNativeDockerPath: paths.wslNativeDockerPath,
        blockedByHostRuntimeConflict: blockedByHostConflict,
        stopWhenNoOpenIssues: options.stopWhenNoOpenIssues || options.sleepMode,
      };
      writeJsonFile(paths.managerStatePath, state);
      writeJsonFile(paths.cyclePath, {
        schema: MANAGER_CYCLE_SCHEMA,
        generatedAt: toIso(),
        cycle,
        daemon: state.daemon,
        report,
        hostSignal,
        hostIsolation,
        wslNativeDocker,
        monitoringWorkInjection,
        hostConflictResolution,
        observer: observerTelemetry,
        codexStateHygiene,
        deliveryMemory,
        managerTracePath: paths.managerTracePath,
      });

      if (blockedByHostConflict) {
        await sleep(options.cycleIntervalSeconds * 1000);
        continue;
      }
      if (!daemonAlive && (options.stopWhenNoOpenIssues || options.sleepMode) && report?.outcome === 'idle-stop') {
        break;
      }
      await sleep(options.cycleIntervalSeconds * 1000);
    }
  } finally {
    stopWslRuntimeDaemon({ distro: options.wslDistro, unitName: daemonUnitName, processId: activeDaemonPid });
    rmSync(paths.stopRequestPath, { force: true });
    rmSync(paths.wslDaemonPidPath, { force: true });
    try {
      const restorePreviousFingerprint = hostSignal?.daemonFingerprint ? String(hostSignal.daemonFingerprint) : null;
      const restoreResult = invokeDeliveryHostSignal({
        mode: 'restore',
        repoRoot,
        distro: options.wslDistro,
        paths,
        previousFingerprint: restorePreviousFingerprint,
        allowRunnerServices: false,
      });
      hostSignal = restoreResult.report;
      hostIsolation = restoreResult.isolation;
      writeManagerTrace({
        repo: options.repo,
        runtimeDir: options.runtimeDir,
        distro: options.wslDistro,
        tracePath: paths.managerTracePath,
        eventType: 'manager-stopped',
        detail: { cycle, restored: true, daemonPid: activeDaemonPid },
      });
    } catch (error) {
      hostIsolation = updateHostIsolationState({
        path: paths.hostIsolationPath,
        repo: options.repo,
        runtimeDir: options.runtimeDir,
        distro: options.wslDistro,
        hostSignalPath: paths.hostSignalPath,
        lastEventType: 'runner-service-restore-failed',
        lastEventDetail: error?.message || String(error),
        hostSignal,
      });
      writeManagerTrace({
        repo: options.repo,
        runtimeDir: options.runtimeDir,
        distro: options.wslDistro,
        tracePath: paths.managerTracePath,
        eventType: 'manager-stop-restore-failed',
        detail: { cycle, message: error?.message || String(error) },
      });
    }
    wslNativeDocker = readJsonFile(paths.wslNativeDockerPath);
      writeJsonFile(paths.managerStatePath, {
        schema: MANAGER_STATE_SCHEMA,
        generatedAt: toIso(),
      repo: options.repo,
      runtimeDir: options.runtimeDir,
      distro: options.wslDistro,
      cycle,
      daemon: { pid: activeDaemonPid, alive: testWslProcessAlive(options.wslDistro, activeDaemonPid) },
        hostSignal,
        hostIsolation,
        wslNativeDocker,
        monitoringWorkInjection,
        hostConflictResolution,
        codexStateHygiene,
        deliveryMemory,
        deliveryMemoryPath: paths.deliveryMemoryPath,
      hostSignalPath: paths.hostSignalPath,
        hostIsolationPath: paths.hostIsolationPath,
        hostTracePath: paths.hostTracePath,
        managerTracePath: paths.managerTracePath,
        wslNativeDockerPath: paths.wslNativeDockerPath,
        blockedByHostRuntimeConflict: blockedByHostConflict,
        outcome: 'stopped',
      });
  }
}

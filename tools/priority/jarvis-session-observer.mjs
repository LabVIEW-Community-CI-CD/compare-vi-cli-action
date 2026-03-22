#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const JARVIS_SESSION_OBSERVER_SCHEMA = 'priority/jarvis-session-observer@v1';
export const DEFAULT_RUNTIME_DIR = path.join('tests', 'results', '_agent', 'runtime');
export const DEFAULT_OUTPUT_PATH = path.join(DEFAULT_RUNTIME_DIR, 'jarvis-session-observer.json');
export const DEFAULT_POLICY_PATH = path.join('tools', 'priority', 'delivery-agent.policy.json');
export const DEFAULT_TAIL_LINES = 10;

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toOptionalText(value) {
  const normalized = normalizeText(value);
  return normalized || null;
}

function normalizeLower(value) {
  return normalizeText(value).toLowerCase();
}

function coercePositiveInteger(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    return null;
  }
  return parsed;
}

function resolvePath(repoRoot, targetPath) {
  if (!targetPath) {
    return repoRoot;
  }
  return path.isAbsolute(targetPath) ? targetPath : path.join(repoRoot, targetPath);
}

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, 'utf8'));
  } catch {
    return null;
  }
}

async function readTailIfPresent(filePath, tailLines) {
  try {
    const text = await fs.readFile(filePath, 'utf8');
    const lines = text.split(/\r?\n/).filter((line) => line.length > 0);
    return lines.slice(Math.max(0, lines.length - tailLines));
  } catch {
    return [];
  }
}

async function writeReceipt(outputPath, payload) {
  const resolved = path.resolve(outputPath);
  await fs.mkdir(path.dirname(resolved), { recursive: true });
  await fs.writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function printUsage() {
  console.log('Usage: node tools/priority/jarvis-session-observer.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --repo-root <path>   Repository root (default: current working directory).`);
  console.log(`  --runtime-dir <path> Runtime receipt directory (default: ${DEFAULT_RUNTIME_DIR}).`);
  console.log(`  --policy <path>      Delivery-agent policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --output <path>      Observer receipt path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log(`  --tail-lines <n>     Log tail line count (default: ${DEFAULT_TAIL_LINES}).`);
  console.log('  -h, --help           Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: process.cwd(),
    runtimeDir: DEFAULT_RUNTIME_DIR,
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    tailLines: DEFAULT_TAIL_LINES,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (['--repo-root', '--runtime-dir', '--policy', '--output', '--tail-lines'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--runtime-dir') options.runtimeDir = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--tail-lines') options.tailLines = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  const tailLines = coercePositiveInteger(options.tailLines);
  if (!options.help && tailLines == null) {
    throw new Error('Tail line count must be a positive integer.');
  }
  options.tailLines = tailLines ?? DEFAULT_TAIL_LINES;
  return options;
}

function normalizeJarvisPolicy(policy = {}, runtimeState = {}) {
  const capitalFabric = policy?.capitalFabric ?? {};
  const specialtyLane = Array.isArray(capitalFabric?.specialtyLanes)
    ? capitalFabric.specialtyLanes.find((entry) => normalizeLower(entry?.id) === 'jarvis') ?? null
    : null;
  const dockerRuntime = policy?.dockerRuntime ?? {};
  const logicalLaneActivation = runtimeState?.logicalLaneActivation ?? {};
  const effectiveLogicalLaneCount =
    coercePositiveInteger(logicalLaneActivation?.effectiveLogicalLaneCount) ??
    coercePositiveInteger(runtimeState?.effectiveLogicalLaneCount) ??
    coercePositiveInteger(capitalFabric?.maxLogicalLaneCount) ??
    1;
  const configuredSessionCapacity = coercePositiveInteger(specialtyLane?.maxInstanceCount) ?? 1;
  const effectiveSessionCapacity = Math.max(1, Math.min(configuredSessionCapacity, effectiveLogicalLaneCount));

  return {
    specialtyLaneId: toOptionalText(specialtyLane?.id) ?? 'jarvis',
    enabled: specialtyLane?.enabled !== false,
    primaryRecordedResponsibility: toOptionalText(specialtyLane?.primaryRecordedResponsibility),
    purpose: toOptionalText(specialtyLane?.purpose),
    allocationMode: toOptionalText(specialtyLane?.allocationMode),
    preferredExecutionPlane: toOptionalText(specialtyLane?.preferredExecutionPlane),
    preferredContainerImage: toOptionalText(specialtyLane?.preferredContainerImage),
    configuredSessionCapacity,
    effectiveSessionCapacity,
    effectiveLogicalLaneCount,
    dockerRuntimePolicy: {
      provider: toOptionalText(dockerRuntime?.provider),
      expectedDockerHost: toOptionalText(dockerRuntime?.dockerHost),
      expectedOsType: toOptionalText(dockerRuntime?.expectedOsType),
      expectedContext: toOptionalText(dockerRuntime?.expectedContext),
      manageDockerEngine: dockerRuntime?.manageDockerEngine === true,
      allowHostEngineMutation: dockerRuntime?.allowHostEngineMutation === true
    }
  };
}

function normalizeHostSignal(hostSignal = null, hostIsolation = null) {
  const reasons = Array.isArray(hostSignal?.reasons)
    ? hostSignal.reasons.map((entry) => normalizeText(entry)).filter(Boolean)
    : [];
  return {
    status: toOptionalText(hostSignal?.status) ?? 'unknown',
    provider: toOptionalText(hostSignal?.provider),
    reasons,
    daemonFingerprint: toOptionalText(hostSignal?.daemonFingerprint),
    previousFingerprint: toOptionalText(hostSignal?.previousFingerprint),
    fingerprintChanged: hostSignal?.fingerprintChanged === true,
    windowsDocker: {
      available: hostSignal?.windowsDocker?.available === true,
      context: toOptionalText(hostSignal?.windowsDocker?.context),
      osType: toOptionalText(hostSignal?.windowsDocker?.osType),
      operatingSystem: toOptionalText(hostSignal?.windowsDocker?.operatingSystem),
      serverName: toOptionalText(hostSignal?.windowsDocker?.serverName),
      platformName: toOptionalText(hostSignal?.windowsDocker?.platformName),
      serverVersion: toOptionalText(hostSignal?.windowsDocker?.serverVersion),
      labels: Array.isArray(hostSignal?.windowsDocker?.labels) ? hostSignal.windowsDocker.labels : [],
      error: toOptionalText(hostSignal?.windowsDocker?.error)
    },
    wslDocker: {
      distro: toOptionalText(hostSignal?.wslDocker?.distro),
      dockerHost: toOptionalText(hostSignal?.wslDocker?.dockerHost),
      available: hostSignal?.wslDocker?.available === true,
      socketPath: toOptionalText(hostSignal?.wslDocker?.socketPath),
      socketPresent: hostSignal?.wslDocker?.socketPresent === true,
      socketOwner: toOptionalText(hostSignal?.wslDocker?.socketOwner),
      socketMode: toOptionalText(hostSignal?.wslDocker?.socketMode),
      systemdState: toOptionalText(hostSignal?.wslDocker?.systemdState),
      serviceState: toOptionalText(hostSignal?.wslDocker?.serviceState),
      context: toOptionalText(hostSignal?.wslDocker?.context),
      osType: toOptionalText(hostSignal?.wslDocker?.osType),
      operatingSystem: toOptionalText(hostSignal?.wslDocker?.operatingSystem),
      serverName: toOptionalText(hostSignal?.wslDocker?.serverName),
      platformName: toOptionalText(hostSignal?.wslDocker?.platformName),
      serverVersion: toOptionalText(hostSignal?.wslDocker?.serverVersion),
      labels: Array.isArray(hostSignal?.wslDocker?.labels) ? hostSignal.wslDocker.labels : [],
      isDockerDesktop: hostSignal?.wslDocker?.isDockerDesktop === true,
      error: toOptionalText(hostSignal?.wslDocker?.error)
    },
    runnerServices: {
      running: Array.isArray(hostSignal?.runnerServices?.running) ? hostSignal.runnerServices.running : [],
      stopped: Array.isArray(hostSignal?.runnerServices?.stopped) ? hostSignal.runnerServices.stopped : []
    },
    isolation: {
      lastStatus: toOptionalText(hostIsolation?.lastStatus),
      lastAction: toOptionalText(hostIsolation?.lastAction),
      preemptedServices: Array.isArray(hostIsolation?.preemptedServices) ? hostIsolation.preemptedServices : [],
      counters: hostIsolation?.counters ?? {}
    }
  };
}

function buildDaemonCutoverAssessment(jarvisPolicy, hostRuntime) {
  const runtimeProvider = normalizeLower(jarvisPolicy?.dockerRuntimePolicy?.provider);
  const expectedDockerHost = toOptionalText(jarvisPolicy?.dockerRuntimePolicy?.expectedDockerHost);
  const expectedOsType = toOptionalText(jarvisPolicy?.dockerRuntimePolicy?.expectedOsType);
  const expectedContext = toOptionalText(jarvisPolicy?.dockerRuntimePolicy?.expectedContext);
  const observedDockerHost = toOptionalText(hostRuntime?.wslDocker?.dockerHost);
  const observedContext = toOptionalText(hostRuntime?.wslDocker?.context) ?? toOptionalText(hostRuntime?.windowsDocker?.context);
  const observedOsType = toOptionalText(hostRuntime?.wslDocker?.osType) ?? toOptionalText(hostRuntime?.windowsDocker?.osType);
  const hostStatus = normalizeLower(hostRuntime?.status);
  const runningRunnerServices = Array.isArray(hostRuntime?.runnerServices?.running) ? hostRuntime.runnerServices.running : [];
  const runnerServiceCount = runningRunnerServices.length;

  const buildRequiredActions = (...actions) => actions.filter((action) => normalizeText(action).length > 0);

  if (runtimeProvider !== 'native-wsl') {
    return {
      schema: 'priority/jarvis-daemon-cutover-assessment@v1',
      status: 'not-required',
      runtimeProvider: jarvisPolicy?.dockerRuntimePolicy?.provider ?? null,
      expectedDockerHost,
      observedDockerHost,
      expectedContext,
      observedContext,
      expectedOsType,
      observedOsType,
      canReuseLinuxDaemon: false,
      readyForLinuxDaemon: false,
      requiresOperatorCutover: false,
      requiredActions: [],
      reason: 'Delivery policy does not require native-wsl daemon reuse.'
    };
  }

  if (hostStatus === 'native-wsl') {
    return {
      schema: 'priority/jarvis-daemon-cutover-assessment@v1',
      status: 'ready',
      runtimeProvider: jarvisPolicy?.dockerRuntimePolicy?.provider ?? null,
      expectedDockerHost,
      observedDockerHost,
      expectedContext,
      observedContext,
      expectedOsType,
      observedOsType,
      canReuseLinuxDaemon: true,
      readyForLinuxDaemon: true,
      requiresOperatorCutover: false,
      requiredActions: [],
      reason: 'Pinned WSL Docker host resolves to a distro-owned Linux daemon.'
    };
  }

  if (hostStatus === 'desktop-backed') {
    return {
      schema: 'priority/jarvis-daemon-cutover-assessment@v1',
      status: 'cutover-required',
      runtimeProvider: jarvisPolicy?.dockerRuntimePolicy?.provider ?? null,
      expectedDockerHost,
      observedDockerHost,
      expectedContext,
      observedContext,
      expectedOsType,
      observedOsType,
      canReuseLinuxDaemon: false,
      readyForLinuxDaemon: false,
      requiresOperatorCutover: true,
      requiredActions: buildRequiredActions(
        runnerServiceCount > 0
          ? `Stop or explicitly govern the ${runnerServiceCount} running actions.runner.* service${runnerServiceCount === 1 ? '' : 's'} on this host.`
          : 'Verify the host has no unmanaged actions.runner.* services running.',
        'Switch WSL Docker to a distro-owned Linux daemon before reusing the daemon-first Linux plane.',
        'Rerun priority:delivery:host:signal.',
        'Rerun priority:jarvis:status.'
      ),
      reason: 'WSL Docker still resolves to Docker Desktop; cut over to a distro-owned Linux daemon before reusing the daemon-first Linux plane.'
    };
  }

  if (hostStatus === 'drifted') {
    return {
      schema: 'priority/jarvis-daemon-cutover-assessment@v1',
      status: 'drifted',
      runtimeProvider: jarvisPolicy?.dockerRuntimePolicy?.provider ?? null,
      expectedDockerHost,
      observedDockerHost,
      expectedContext,
      observedContext,
      expectedOsType,
      observedOsType,
      canReuseLinuxDaemon: false,
      readyForLinuxDaemon: false,
      requiresOperatorCutover: false,
      requiredActions: buildRequiredActions(
        'Reconcile the WSL Docker daemon fingerprint.',
        'Rerun priority:delivery:host:signal.',
        'Rerun priority:jarvis:status.'
      ),
      reason: 'WSL Docker daemon fingerprint drifted and must be reconciled before Linux daemon reuse.'
    };
  }

  if (hostStatus === 'runner-conflict') {
    return {
      schema: 'priority/jarvis-daemon-cutover-assessment@v1',
      status: 'runner-conflict',
      runtimeProvider: jarvisPolicy?.dockerRuntimePolicy?.provider ?? null,
      expectedDockerHost,
      observedDockerHost,
      expectedContext,
      observedContext,
      expectedOsType,
      observedOsType,
      canReuseLinuxDaemon: false,
      readyForLinuxDaemon: false,
      requiresOperatorCutover: false,
      requiredActions: buildRequiredActions(
        runnerServiceCount > 0
          ? `Stop or explicitly govern the ${runnerServiceCount} running actions.runner.* service${runnerServiceCount === 1 ? '' : 's'} on this host.`
          : 'Verify the host has no unmanaged actions.runner.* services running.',
        'Rerun priority:delivery:host:signal.',
        'Rerun priority:jarvis:status.'
      ),
      reason: 'Runner-service isolation is still required before Linux daemon reuse.'
    };
  }

  return {
    schema: 'priority/jarvis-daemon-cutover-assessment@v1',
    status: 'unknown',
    runtimeProvider: jarvisPolicy?.dockerRuntimePolicy?.provider ?? null,
    expectedDockerHost,
    observedDockerHost,
    expectedContext,
    observedContext,
    expectedOsType,
    observedOsType,
    canReuseLinuxDaemon: false,
    readyForLinuxDaemon: false,
    requiresOperatorCutover: false,
    requiredActions: buildRequiredActions(
      'Re-run priority:delivery:host:signal to capture the current host state.',
      'Re-run priority:jarvis:status to re-evaluate daemon cutover readiness.'
    ),
    reason: 'Jarvis could not determine whether the Linux daemon plane is reusable.'
  };
}

function mapConcurrentLanePhase(entry = {}) {
  const runtimeStatus = normalizeLower(entry?.runtimeStatus);
  if (runtimeStatus === 'active' || runtimeStatus === 'completed') {
    return 'active';
  }
  if (runtimeStatus === 'planned' || runtimeStatus === 'unknown') {
    return 'queued';
  }
  if (runtimeStatus === 'blocked' || runtimeStatus === 'failed') {
    return 'blocked';
  }
  if (runtimeStatus === 'deferred') {
    return 'deferred';
  }
  if (runtimeStatus === 'idle') {
    return 'idle';
  }
  return 'unknown';
}

function isWindowsDockerLane(entry = {}) {
  const reasons = Array.isArray(entry?.reasons) ? entry.reasons.map((reason) => normalizeLower(reason)) : [];
  const metadata = entry?.metadata ?? {};
  const dockerServerOs = normalizeLower(metadata?.dockerServerOs ?? entry?.dockerServerOs);
  return (
    normalizeLower(entry?.id) === 'manual-windows-docker' ||
    normalizeLower(entry?.resourceGroup) === 'docker-desktop-windows' ||
    reasons.some((reason) => reason.includes('docker-engine-windows')) ||
    dockerServerOs === 'windows'
  );
}

function collectConcurrentLaneSessions(concurrentLaneStatus = {}, jarvisPolicy = {}) {
  const laneStatuses = Array.isArray(concurrentLaneStatus?.laneStatuses) ? concurrentLaneStatus.laneStatuses : [];
  return laneStatuses
    .filter((entry) => isWindowsDockerLane(entry))
    .map((entry, index) => {
      const metadata = entry?.metadata ?? {};
      return {
        source: 'concurrent-lane-status',
        sessionId: toOptionalText(entry?.id) ?? `jarvis-session-${index + 1}`,
        logicalLaneId: toOptionalText(entry?.logicalLaneId),
        issue: coercePositiveInteger(entry?.issue),
        phase: mapConcurrentLanePhase(entry),
        laneId: toOptionalText(entry?.id),
        laneClass: toOptionalText(entry?.laneClass),
        executionPlane: toOptionalText(entry?.executionPlane),
        resourceGroup: toOptionalText(entry?.resourceGroup),
        branchRef: toOptionalText(entry?.branchRef ?? metadata?.branchRef),
        dockerContext: toOptionalText(metadata?.dockerContext ?? entry?.dockerContext),
        dockerServerOs: toOptionalText(metadata?.dockerServerOs ?? entry?.dockerServerOs),
        preferredContainerImage: jarvisPolicy?.preferredContainerImage ?? null,
        primaryRecordedResponsibility: jarvisPolicy?.primaryRecordedResponsibility ?? null,
        reason: Array.isArray(entry?.reasons) ? entry.reasons.map((reason) => normalizeText(reason)).filter(Boolean).join('; ') : null
      };
    });
}

function buildRuntimeFallbackSession(runtimeState = {}, hostRuntime = {}, jarvisPolicy = {}) {
  const activeLane = runtimeState?.activeLane ?? null;
  const providerDispatch = activeLane?.providerDispatch ?? runtimeState?.providerDispatch ?? null;
  const executionPlane = normalizeLower(providerDispatch?.executionPlane);
  const windowsDockerOsType = normalizeLower(hostRuntime?.windowsDocker?.osType);
  if (!activeLane || executionPlane !== 'local' || windowsDockerOsType !== 'windows') {
    return null;
  }
  return {
    source: 'runtime-state-active-lane',
    sessionId: toOptionalText(activeLane?.laneId) ?? 'jarvis-runtime-active-lane',
    logicalLaneId: toOptionalText(activeLane?.workerSlotId ?? providerDispatch?.workerSlotId),
    issue: coercePositiveInteger(activeLane?.issue),
    phase: normalizeLower(runtimeState?.laneLifecycle) === 'blocked' ? 'blocked' : 'active',
    laneId: toOptionalText(activeLane?.laneId),
    laneClass: toOptionalText(activeLane?.laneClass),
    executionPlane: toOptionalText(providerDispatch?.executionPlane),
    resourceGroup: toOptionalText(providerDispatch?.providerId),
    branchRef: toOptionalText(activeLane?.branch),
    dockerContext: toOptionalText(hostRuntime?.windowsDocker?.context),
    dockerServerOs: toOptionalText(hostRuntime?.windowsDocker?.osType),
    preferredContainerImage: jarvisPolicy?.preferredContainerImage ?? null,
    primaryRecordedResponsibility: jarvisPolicy?.primaryRecordedResponsibility ?? null,
    reason: 'Fallback local active lane projected from delivery-agent-state.'
  };
}

function buildObserverHeartbeat(heartbeat = null) {
  return {
    exists: Boolean(heartbeat),
    generatedAt: toOptionalText(heartbeat?.generatedAt),
    outcome: toOptionalText(heartbeat?.outcome),
    cyclesCompleted: coercePositiveInteger(heartbeat?.cyclesCompleted) ?? 0,
    activeLaneId: toOptionalText(heartbeat?.activeLane?.laneId),
    activeIssue: coercePositiveInteger(heartbeat?.activeLane?.issue),
    stopRequested: heartbeat?.stopRequested === true
  };
}

function buildWslDaemonState(daemonPid = null) {
  return {
    exists: Boolean(daemonPid),
    pid: coercePositiveInteger(daemonPid?.pid),
    generatedAt: toOptionalText(daemonPid?.generatedAt),
    running: daemonPid?.running === true,
    unitName: toOptionalText(daemonPid?.unitName),
    distro: toOptionalText(daemonPid?.distro)
  };
}

function buildDockerDaemonEngine(dockerDaemonEngine = null) {
  return {
    exists: Boolean(dockerDaemonEngine),
    generatedAt: toOptionalText(dockerDaemonEngine?.generatedAt),
    requiredOs: toOptionalText(dockerDaemonEngine?.requiredOs),
    lockPath: toOptionalText(dockerDaemonEngine?.lockPath),
    lockAcquired: dockerDaemonEngine?.lockAcquired === true,
    dockerCommand: toOptionalText(dockerDaemonEngine?.docker?.command),
    observedOs: toOptionalText(dockerDaemonEngine?.docker?.os),
    previousContext: toOptionalText(dockerDaemonEngine?.docker?.context?.previous),
    activeContext: toOptionalText(dockerDaemonEngine?.docker?.context?.active),
    contextMode: toOptionalText(dockerDaemonEngine?.docker?.context?.mode),
    contextSwitched: dockerDaemonEngine?.docker?.context?.switched === true
  };
}

function determineReportStatus({ activeSessionCount, daemonCutoverStatus, warnings }) {
  if (activeSessionCount > 0) {
    return 'active';
  }
  if (['cutover-required', 'drifted', 'runner-conflict'].includes(daemonCutoverStatus)) {
    return 'blocked';
  }
  if (warnings.length > 0) {
    return 'unknown';
  }
  return 'idle';
}

function createWatchPaths(paths) {
  return [
    paths.policyPath,
    paths.deliveryStatePath,
    paths.concurrentLaneStatusPath,
    paths.deliveryMemoryPath,
    paths.hostSignalPath,
    paths.hostIsolationPath,
    paths.observerHeartbeatPath,
    paths.wslDaemonPidPath,
    paths.dockerDaemonEnginePath,
    paths.runtimeDaemonLogPath,
    paths.dockerDaemonLogPath
  ];
}

function printHumanSummary(report) {
  const lines = [];
  lines.push(
    `[jarvis-session-observer] wrote ${report.artifacts.receiptPath} ` +
      `(status=${report.status}, sessions=${report.summary.activeSessionCount}/${report.summary.totalSessionCount}, daemonCutover=${report.summary.daemonCutoverStatus})`
  );
  lines.push(
    `Jarvis owner=${report.jarvisPolicy.primaryRecordedResponsibility ?? 'unassigned'} ` +
      `capacity=${report.jarvisPolicy.effectiveSessionCapacity}/${report.jarvisPolicy.configuredSessionCapacity} ` +
      `plane=${report.jarvisPolicy.preferredExecutionPlane ?? 'unknown'}`
  );
  lines.push(
    `Host runtime=${report.hostRuntime.status} provider=${report.hostRuntime.provider ?? 'unknown'} ` +
      `windowsContext=${report.hostRuntime.windowsDocker.context ?? '<none>'} ` +
      `windowsOs=${report.hostRuntime.windowsDocker.osType ?? '<none>'}`
  );
  lines.push(
    `Linux daemon reuse=${report.daemon.daemonCutover.status} ` +
      `expectedDockerHost=${report.daemon.daemonCutover.expectedDockerHost ?? '<none>'} ` +
      `observedDockerHost=${report.daemon.daemonCutover.observedDockerHost ?? '<none>'}`
  );
  if (Array.isArray(report.daemon.daemonCutover.requiredActions) && report.daemon.daemonCutover.requiredActions.length > 0) {
    lines.push('Required actions:');
    for (const action of report.daemon.daemonCutover.requiredActions) {
      lines.push(`- ${action}`);
    }
  }
  if (report.sessions.length > 0) {
    lines.push('Sessions:');
    for (const session of report.sessions) {
      lines.push(
        `- ${session.sessionId}: phase=${session.phase} source=${session.source} context=${session.dockerContext ?? '<none>'} os=${session.dockerServerOs ?? '<none>'} issue=${session.issue ?? '<none>'}`
      );
    }
  } else {
    lines.push('Sessions: none observed');
  }
  if (report.warnings.length > 0) {
    lines.push('Warnings:');
    for (const warning of report.warnings) {
      lines.push(`- ${warning}`);
    }
  }
  const runtimeDaemonLines = report.daemon.logs.runtimeDaemonWsl.lines;
  const dockerDaemonLines = report.daemon.logs.dockerDaemon.lines;
  if (runtimeDaemonLines.length > 0) {
    lines.push('runtime-daemon-wsl.log tail:');
    for (const line of runtimeDaemonLines) {
      lines.push(`  ${line}`);
    }
  }
  if (dockerDaemonLines.length > 0) {
    lines.push('docker-daemon-logs.txt tail:');
    for (const line of dockerDaemonLines) {
      lines.push(`  ${line}`);
    }
  }
  console.log(lines.join('\n'));
}

export async function buildJarvisSessionObserverReport({
  repoRoot,
  runtimeDir = DEFAULT_RUNTIME_DIR,
  policyPath = DEFAULT_POLICY_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  tailLines = DEFAULT_TAIL_LINES
}) {
  const resolvedRepoRoot = path.resolve(repoRoot);
  const resolvedRuntimeDir = resolvePath(resolvedRepoRoot, runtimeDir);
  const paths = {
    policyPath: resolvePath(resolvedRepoRoot, policyPath),
    outputPath: resolvePath(resolvedRepoRoot, outputPath),
    deliveryStatePath: path.join(resolvedRuntimeDir, 'delivery-agent-state.json'),
    concurrentLaneStatusPath: path.join(resolvedRuntimeDir, 'concurrent-lane-status-receipt.json'),
    deliveryMemoryPath: path.join(resolvedRuntimeDir, 'delivery-memory.json'),
    hostSignalPath: path.join(resolvedRuntimeDir, 'daemon-host-signal.json'),
    hostIsolationPath: path.join(resolvedRuntimeDir, 'delivery-agent-host-isolation.json'),
    observerHeartbeatPath: path.join(resolvedRuntimeDir, 'observer-heartbeat.json'),
    wslDaemonPidPath: path.join(resolvedRuntimeDir, 'delivery-agent-wsl-daemon-pid.json'),
    dockerDaemonEnginePath: path.join(resolvedRuntimeDir, 'docker-daemon-engine.json'),
    runtimeDaemonLogPath: path.join(resolvedRuntimeDir, 'runtime-daemon-wsl.log'),
    dockerDaemonLogPath: path.join(resolvedRuntimeDir, 'docker-daemon-logs.txt')
  };

  const [
    policy,
    runtimeState,
    concurrentLaneStatus,
    deliveryMemory,
    hostSignal,
    hostIsolation,
    observerHeartbeat,
    daemonPid,
    dockerDaemonEngine,
    runtimeDaemonLogTail,
    dockerDaemonLogTail
  ] = await Promise.all([
    readJsonIfPresent(paths.policyPath),
    readJsonIfPresent(paths.deliveryStatePath),
    readJsonIfPresent(paths.concurrentLaneStatusPath),
    readJsonIfPresent(paths.deliveryMemoryPath),
    readJsonIfPresent(paths.hostSignalPath),
    readJsonIfPresent(paths.hostIsolationPath),
    readJsonIfPresent(paths.observerHeartbeatPath),
    readJsonIfPresent(paths.wslDaemonPidPath),
    readJsonIfPresent(paths.dockerDaemonEnginePath),
    readTailIfPresent(paths.runtimeDaemonLogPath, tailLines),
    readTailIfPresent(paths.dockerDaemonLogPath, tailLines)
  ]);

  const warnings = [];
  if (!policy) warnings.push('delivery-agent policy receipt is missing.');
  if (!hostSignal) warnings.push('daemon-host-signal.json is missing.');
  if (!runtimeState) warnings.push('delivery-agent-state.json is missing.');

  const jarvisPolicy = normalizeJarvisPolicy(policy ?? {}, runtimeState ?? {});
  const hostRuntime = normalizeHostSignal(hostSignal, hostIsolation);
  const daemonCutover = buildDaemonCutoverAssessment(jarvisPolicy, hostRuntime);
  const concurrentSessions = collectConcurrentLaneSessions(concurrentLaneStatus ?? {}, jarvisPolicy);
  const runtimeFallbackSession = buildRuntimeFallbackSession(runtimeState ?? {}, hostRuntime, jarvisPolicy);
  const sessions = runtimeFallbackSession && concurrentSessions.length === 0
    ? [runtimeFallbackSession]
    : concurrentSessions;

  const activeSessionCount = sessions.filter((entry) => entry.phase === 'active').length;
  const queuedSessionCount = sessions.filter((entry) => entry.phase === 'queued').length;
  const blockedSessionCount = sessions.filter((entry) => entry.phase === 'blocked').length;
  const deferredSessionCount = sessions.filter((entry) => entry.phase === 'deferred').length;
  const totalSessionCount = sessions.length;
  const status = determineReportStatus({ activeSessionCount, daemonCutoverStatus: daemonCutover.status, warnings });

  const report = {
    schema: JARVIS_SESSION_OBSERVER_SCHEMA,
    generatedAt: new Date().toISOString(),
    repository: toOptionalText(runtimeState?.repository) ?? toOptionalText(policy?.repo) ?? null,
    status,
    summary: {
      specialtyLaneId: jarvisPolicy.specialtyLaneId,
      primaryRecordedResponsibility: jarvisPolicy.primaryRecordedResponsibility,
      configuredSessionCapacity: jarvisPolicy.configuredSessionCapacity,
      effectiveSessionCapacity: jarvisPolicy.effectiveSessionCapacity,
      activeSessionCount,
      queuedSessionCount,
      blockedSessionCount,
      deferredSessionCount,
      totalSessionCount,
      daemonCutoverStatus: daemonCutover.status,
      readyForLinuxDaemon: daemonCutover.readyForLinuxDaemon,
      requiresOperatorCutover: daemonCutover.requiresOperatorCutover
    },
    jarvisPolicy,
    hostRuntime,
    daemon: {
      observerHeartbeat: buildObserverHeartbeat(observerHeartbeat),
      wslDaemon: buildWslDaemonState(daemonPid),
      dockerDaemonEngine: buildDockerDaemonEngine(dockerDaemonEngine),
      daemonCutover,
      deliveryMemory: {
        exists: Boolean(deliveryMemory),
        generatedAt: toOptionalText(deliveryMemory?.generatedAt),
        workerPoolTarget: coercePositiveInteger(deliveryMemory?.summary?.targetSlotCount ?? deliveryMemory?.workerPool?.targetSlotCount)
      },
      logs: {
        runtimeDaemonWsl: {
          path: paths.runtimeDaemonLogPath,
          lineCount: runtimeDaemonLogTail.length,
          lines: runtimeDaemonLogTail
        },
        dockerDaemon: {
          path: paths.dockerDaemonLogPath,
          lineCount: dockerDaemonLogTail.length,
          lines: dockerDaemonLogTail
        }
      }
    },
    sessions,
    warnings,
    artifacts: {
      receiptPath: paths.outputPath,
      watchPaths: createWatchPaths(paths),
      policyPath: paths.policyPath,
      runtimeDir: resolvedRuntimeDir,
      deliveryStatePath: paths.deliveryStatePath,
      concurrentLaneStatusPath: paths.concurrentLaneStatusPath,
      hostSignalPath: paths.hostSignalPath,
      hostIsolationPath: paths.hostIsolationPath,
      observerHeartbeatPath: paths.observerHeartbeatPath,
      wslDaemonPidPath: paths.wslDaemonPidPath,
      dockerDaemonEnginePath: paths.dockerDaemonEnginePath
    }
  };

  return report;
}

export async function observeJarvisSessionObserver(options) {
  const report = await buildJarvisSessionObserverReport({
    repoRoot: options.repoRoot,
    runtimeDir: options.runtimeDir,
    policyPath: options.policyPath,
    outputPath: options.outputPath,
    tailLines: options.tailLines
  });
  const outputPath = await writeReceipt(resolvePath(options.repoRoot, options.outputPath), report);
  const reportWithPath = {
    ...report,
    artifacts: {
      ...report.artifacts,
      receiptPath: outputPath
    }
  };
  await writeReceipt(outputPath, reportWithPath);
  return { report: reportWithPath, outputPath };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const { report } = await observeJarvisSessionObserver(options);
  printHumanSummary(report);
  return report.status === 'blocked' ? 1 : 0;
}

const modulePath = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === modulePath) {
  main().then(
    (code) => {
      process.exit(code);
    },
    (error) => {
      console.error(`[jarvis-session-observer] ${error.message}`);
      process.exit(1);
    }
  );
}

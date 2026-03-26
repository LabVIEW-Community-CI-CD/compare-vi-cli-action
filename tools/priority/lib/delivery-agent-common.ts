// @ts-nocheck

import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const DEFAULTS = {
  repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  runtimeDir: path.join('tests', 'results', '_agent', 'runtime'),
  daemonPollIntervalSeconds: 60,
  cycleIntervalSeconds: 90,
  maxCycles: 0,
  stopWaitSeconds: 30,
  wslDistro: 'Ubuntu',
  sleepMode: false,
  stopWhenNoOpenIssues: false,
  reportPath: path.join('tests', 'results', '_agent', 'runtime', 'wsl-delivery-prereqs.json'),
  nodeVersion: 'v24.13.1',
  pwshVersion: '7.5.4',
  dockerHost: 'unix:///var/run/docker.sock',
};

export const MANAGER_STATE_SCHEMA = 'priority/unattended-delivery-agent-state@v1';
export const MANAGER_CYCLE_SCHEMA = 'priority/unattended-delivery-agent-cycle@v1';
export const MANAGER_REPORT_SCHEMA = 'priority/unattended-delivery-agent-report@v1';
export const MANAGER_PID_SCHEMA = 'priority/unattended-delivery-agent-manager-pid@v1';
export const DAEMON_PID_SCHEMA = 'priority/unattended-delivery-agent-wsl-daemon-pid@v1';
export const STOP_REQUEST_SCHEMA = 'priority/unattended-delivery-agent-stop@v1';
export const TRACE_SCHEMA = 'priority/unattended-delivery-agent-trace@v1';
export const RUNTIME_EPOCH_SCHEMA = 'priority/unattended-delivery-agent-runtime-epoch@v1';
export const MAX_BUFFER = 32 * 1024 * 1024;

export function resolveRepoRoot() {
  const moduleDir = path.dirname(fileURLToPath(import.meta.url));
  let currentDir = moduleDir;
  while (true) {
    if (existsSync(path.join(currentDir, 'package.json'))) {
      return currentDir;
    }
    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) {
      break;
    }
    currentDir = parentDir;
  }
  throw new Error(`Unable to resolve repository root from module location: ${moduleDir}`);
}

export function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

export function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function shellQuote(value) {
  const text = normalizeText(value);
  return `'${text.replace(/'/g, `'\"'\"'`)}'`;
}

export function resolvePath(repoRoot, targetPath) {
  if (!targetPath) {
    return repoRoot;
  }
  return path.isAbsolute(targetPath) ? targetPath : path.join(repoRoot, targetPath);
}

export function convertToWslPath(targetPath) {
  const resolved = path.resolve(targetPath);
  const normalized = resolved.replace(/\\/g, '/');
  const match = normalized.match(/^([A-Za-z]):\/(.*)$/);
  if (!match) {
    throw new Error(`Unable to convert to WSL path: ${targetPath}`);
  }
  return `/mnt/${match[1].toLowerCase()}/${match[2]}`;
}

export function readJsonFile(filePath) {
  if (!existsSync(filePath)) {
    return null;
  }
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

export function writeJsonFile(filePath, payload) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

export function addJsonLine(filePath, payload) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  appendFileSync(filePath, `${JSON.stringify(payload)}\n`, 'utf8');
  return filePath;
}

export function readLogTail(filePath, tailLines = 40) {
  if (!existsSync(filePath)) {
    return [];
  }
  try {
    const text = readFileSync(filePath, 'utf8');
    const lines = text.split(/\r?\n/).filter((line) => line.length > 0);
    return lines.slice(Math.max(0, lines.length - tailLines));
  } catch {
    return [];
  }
}

export function runCommand(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    input: options.input,
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
    windowsHide: true,
    stdio: options.stdio ?? ['pipe', 'pipe', 'pipe'],
  });
  return {
    status: result.status ?? 0,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error,
  };
}

export function resolveCommandPath(name) {
  if (name === 'node') {
    return process.execPath;
  }
  const locator = process.platform === 'win32' ? 'where.exe' : 'which';
  const result = runCommand(locator, [name]);
  if (result.error || result.status !== 0) {
    throw new Error(`Required command not found on the host: ${name}`);
  }
  const line = result.stdout.split(/\r?\n/).map(normalizeText).find(Boolean);
  if (!line) {
    throw new Error(`Required command not found on the host: ${name}`);
  }
  return line;
}

export function getNpmCommand() {
  return process.platform === 'win32' ? 'npm.cmd' : 'npm';
}

export function getOptionalProperty(inputObject, name) {
  if (!inputObject || typeof inputObject !== 'object') {
    return null;
  }
  return Object.prototype.hasOwnProperty.call(inputObject, name) ? inputObject[name] : null;
}

export function getOptionalStringProperty(inputObject, name) {
  const value = getOptionalProperty(inputObject, name);
  const text = normalizeText(value);
  return text || null;
}

export function getOptionalIntProperty(inputObject, name) {
  const value = getOptionalProperty(inputObject, name);
  const parsed = Number(value);
  return Number.isInteger(parsed) ? parsed : 0;
}

export function getOptionalDateTimeProperty(inputObject, name) {
  const text = getOptionalStringProperty(inputObject, name);
  if (!text) {
    return null;
  }
  const parsed = Date.parse(text);
  return Number.isFinite(parsed) ? new Date(parsed) : null;
}

export function getRuntimeEpochId(inputObject) {
  return (
    getOptionalStringProperty(inputObject, 'runtimeEpochId') ||
    getOptionalStringProperty(getOptionalProperty(inputObject, 'activeLane'), 'runtimeEpochId')
  );
}

export function describeRuntimeEpochAlignment(currentRuntimeEpochId, observedRuntimeEpochId) {
  const current = normalizeText(currentRuntimeEpochId);
  const observed = normalizeText(observedRuntimeEpochId);
  if (!current) {
    return 'not-required';
  }
  if (!observed) {
    return 'missing';
  }
  return observed === current ? 'aligned' : 'mismatch';
}

function resolveRuntimeEpochMismatchReason(prefix, alignment) {
  if (alignment === 'missing') {
    return `${prefix}-runtime-epoch-missing`;
  }
  if (alignment === 'mismatch') {
    return `${prefix}-runtime-epoch-mismatch`;
  }
  return `${prefix}-runtime-epoch-not-required`;
}

export function resolveObserverTelemetry(codexStateHygiene, reportPath) {
  const fallback = {
    plane: 'observer',
    source: 'codex-state-hygiene',
    status: 'unknown',
    deliveryCritical: false,
    hotPathEligible: false,
    deliveryImpact: 'none',
    reasons: ['report-missing'],
    counts: {
      gitOriginAndRoots: 0,
      localEnvironmentsUnsupported: 0,
      openInTargetUnsupported: 0,
      unhandledBroadcastNoHandler: 0,
      threadStreamStateChanged: 0,
      threadQueuedFollowupsChanged: 0,
      databaseLocked: 0,
      slowStatement: 0,
    },
    reportPath,
  };

  if (!codexStateHygiene) {
    return fallback;
  }
  if (codexStateHygiene.observer && typeof codexStateHygiene.observer === 'object') {
    return {
      ...codexStateHygiene.observer,
      reportPath: codexStateHygiene.observer.reportPath || reportPath,
    };
  }

  const legacyStatus = normalizeText(codexStateHygiene.status) || 'unknown';
  fallback.reasons = ['legacy-report-shape'];
  const counts = codexStateHygiene.extensionLog?.counts || {};
  for (const name of Object.keys(fallback.counts)) {
    const parsed = Number(counts?.[name]);
    if (Number.isFinite(parsed) && parsed > 0) {
      fallback.counts[name] = parsed;
    }
  }
  const pressureReasons = Object.entries(fallback.counts)
    .filter(([, value]) => Number(value) > 0)
    .map(([name]) => name);
  if (pressureReasons.length > 0 || legacyStatus === 'action-needed') {
    fallback.status = 'degraded';
    fallback.reasons = [...fallback.reasons, ...pressureReasons];
  } else if (legacyStatus === 'unknown') {
    fallback.status = 'unknown';
  } else {
    fallback.status = 'healthy';
  }
  return fallback;
}

export function resolveHostSignalForStatus({ hostSignal, managerStartedAt = null }) {
  const hostSignalGeneratedAt = getOptionalDateTimeProperty(hostSignal, 'generatedAt');
  const diagnostics = {
    usedHostSignal: false,
    reason: 'host-signal-missing',
    hostSignalGeneratedAt: hostSignalGeneratedAt ? hostSignalGeneratedAt.toISOString() : null,
    managerStartedAt: managerStartedAt ? managerStartedAt.toISOString() : null,
    hostSignalRepository: getOptionalStringProperty(hostSignal, 'repository'),
  };

  if (!hostSignal) {
    return { hostSignal: null, diagnostics };
  }

  if (managerStartedAt && hostSignalGeneratedAt && hostSignalGeneratedAt < managerStartedAt) {
    diagnostics.reason = 'stale-before-current-manager';
    return { hostSignal: null, diagnostics };
  }

  diagnostics.usedHostSignal = true;
  diagnostics.reason = 'host-signal-current';
  return { hostSignal, diagnostics };
}

export function getArtifactPaths(repoRoot, runtimeDir) {
  const runtimeDirPath = resolvePath(repoRoot, runtimeDir);
  return {
    runtimeDirPath,
    managerStatePath: path.join(runtimeDirPath, 'delivery-agent-manager-state.json'),
    managerPidPath: path.join(runtimeDirPath, 'delivery-agent-manager-pid.json'),
    stopRequestPath: path.join(runtimeDirPath, 'delivery-agent-manager-stop.json'),
    observerHeartbeatPath: path.join(runtimeDirPath, 'observer-heartbeat.json'),
    deliveryStatePath: path.join(runtimeDirPath, 'delivery-agent-state.json'),
    runtimeStatePath: path.join(runtimeDirPath, 'runtime-state.json'),
    taskPacketPath: path.join(runtimeDirPath, 'task-packet.json'),
    deliveryMemoryPath: path.join(runtimeDirPath, 'delivery-memory.json'),
    wslDaemonPidPath: path.join(runtimeDirPath, 'delivery-agent-wsl-daemon-pid.json'),
    codexStateHygienePath: path.join(runtimeDirPath, 'codex-state-hygiene.json'),
    hostSignalPath: path.join(runtimeDirPath, 'daemon-host-signal.json'),
    hostIsolationPath: path.join(runtimeDirPath, 'delivery-agent-host-isolation.json'),
    hostTracePath: path.join(runtimeDirPath, 'delivery-agent-host-trace.ndjson'),
    managerTracePath: path.join(runtimeDirPath, 'delivery-agent-manager-trace.ndjson'),
    wslNativeDockerPath: path.join(runtimeDirPath, 'wsl-native-docker.json'),
    daemonLogPath: path.join(runtimeDirPath, 'runtime-daemon-wsl.log'),
    runnerLogPath: path.join(runtimeDirPath, 'delivery-agent-manager.log'),
    runnerErrorPath: path.join(runtimeDirPath, 'delivery-agent-manager.stderr.log'),
    cyclePath: path.join(runtimeDirPath, 'delivery-agent-manager-cycle.json'),
    observerReportPath: path.join(runtimeDirPath, 'runtime-daemon-report.json'),
    runtimeEpochPath: path.join(runtimeDirPath, 'delivery-agent-runtime-epoch.json'),
    runtimeQuarantineRootPath: path.join(runtimeDirPath, 'quarantine'),
  };
}

export function getIssueArtifactPaths(repoRoot) {
  const issueDirPath = path.join(repoRoot, 'tests', 'results', '_agent', 'issue');
  const handoffDirPath = path.join(repoRoot, 'tests', 'results', '_agent', 'handoff');
  return {
    issueDirPath,
    handoffDirPath,
    queueEmptyReportPath: path.join(issueDirPath, 'no-standing-priority.json'),
    routerPath: path.join(issueDirPath, 'router.json'),
    monitoringModePath: path.join(handoffDirPath, 'monitoring-mode.json'),
  };
}

export function isQueueEmptyMonitoringReady({ queueEmptyReport, router }) {
  const queueEmptyReason = getOptionalStringProperty(queueEmptyReport, 'reason');
  const routerIssue = getOptionalIntProperty(router, 'issue');
  return queueEmptyReason === 'queue-empty' && routerIssue <= 0;
}

export function buildQueueEmptyMonitoringDeliveryState({
  repo,
  runtimeDir,
  generatedAt = null,
  paths,
  queueEmptyReportPath = null,
  monitoringMode = null,
  runtimeEpochId = null,
}) {
  const monitoringAction = getOptionalStringProperty(monitoringMode, 'futureAgentAction') || 'future-agent-may-pivot';
  const iso = generatedAt ? toIso(generatedAt) : toIso();
  return {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: iso,
    repository: repo,
    runtimeDir,
    runtimeEpochId,
    status: 'idle',
    laneLifecycle: 'idle',
    activeCodingLanes: 0,
    derivedFromQueueEmptyState: true,
    queueState: {
      status: 'queue-empty',
      reason: 'queue-empty',
      reportPath: queueEmptyReportPath,
    },
    activeLane: {
      schema: 'priority/delivery-agent-lane-state@v1',
      generatedAt: iso,
      runtimeEpochId,
      laneId: 'queue-empty-monitoring',
      issue: null,
      epic: null,
      branch: null,
      forkRemote: null,
      prUrl: null,
      blockerClass: 'none',
      laneLifecycle: 'idle',
      actionType: 'monitoring-idle',
      outcome: 'queue-empty',
      reason: 'queue-empty',
      retryable: false,
      nextWakeCondition: monitoringAction,
      syntheticIdle: true,
    },
    artifacts: {
      statePath: paths.deliveryStatePath,
      lanePath: null,
      concurrentLaneApplyReceiptPath: null,
    },
  };
}

export function testProcessAlive(processId) {
  if (!Number.isInteger(processId) || processId <= 0) {
    return false;
  }
  try {
    process.kill(processId, 0);
    return true;
  } catch {
    return false;
  }
}

export function testWslProcessAlive(distro, processId) {
  if (!Number.isInteger(processId) || processId <= 0) {
    return false;
  }
  const result = runCommand('wsl.exe', ['-d', distro, '--', 'bash', '-lc', `kill -0 ${processId} >/dev/null 2>&1`]);
  return result.status === 0;
}

export function writeManagerTrace({ repo, runtimeDir, distro, tracePath, eventType, detail = {} }) {
  addJsonLine(tracePath, {
    schema: TRACE_SCHEMA,
    generatedAt: toIso(),
    repo,
    runtimeDir,
    distro,
    eventType,
    ...detail,
  });
}

export function buildRuntimeEpochId({ repo = '', startedAt = new Date() } = {}) {
  const startedAtIso = toIso(startedAt).replace(/[:.]/g, '-');
  const repoSlug = normalizeText(repo)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'repo';
  return `${startedAtIso}-${repoSlug}`;
}

export function resolveRuntimeEpochTimestamp(payload) {
  if (!payload || typeof payload !== 'object') {
    return null;
  }
  for (const propertyName of ['generatedAt', 'startedAt', 'requestedAt', 'updatedAt']) {
    const value = getOptionalDateTimeProperty(payload, propertyName);
    if (value) {
      return value;
    }
  }
  return null;
}

export function quarantineStaleRuntimeReceipts({
  repo,
  runtimeDir,
  paths,
  runtimeEpochId,
  managerStartedAt,
}) {
  const quarantineEntries = [];
  const managerStartedAtIso = toIso(managerStartedAt);
  const quarantineDirPath = path.join(paths.runtimeQuarantineRootPath, runtimeEpochId);
  const candidates = [
    ['runtime-epoch', paths.runtimeEpochPath],
    ['manager-state', paths.managerStatePath],
    ['manager-cycle', paths.cyclePath],
    ['observer-heartbeat', paths.observerHeartbeatPath],
    ['delivery-state', paths.deliveryStatePath],
    ['runtime-state', paths.runtimeStatePath],
    ['task-packet', paths.taskPacketPath],
    ['delivery-memory', paths.deliveryMemoryPath],
    ['wsl-daemon-pid', paths.wslDaemonPidPath],
    ['host-signal', paths.hostSignalPath],
    ['host-isolation', paths.hostIsolationPath],
    ['wsl-native-docker', paths.wslNativeDockerPath],
    ['observer-report', paths.observerReportPath],
  ];

  for (const [artifactId, artifactPath] of candidates) {
    if (!existsSync(artifactPath)) {
      continue;
    }
    const payload = readJsonFile(artifactPath);
    const generatedAt = resolveRuntimeEpochTimestamp(payload);
    const shouldQuarantine =
      payload == null ||
      generatedAt == null ||
      generatedAt < managerStartedAt;
    if (!shouldQuarantine) {
      continue;
    }

    mkdirSync(quarantineDirPath, { recursive: true });
    const quarantinePath = path.join(quarantineDirPath, path.basename(artifactPath));
    rmSync(quarantinePath, { force: true, recursive: true });
    renameSync(artifactPath, quarantinePath);
    quarantineEntries.push({
      artifactId,
      sourcePath: artifactPath,
      quarantinePath,
      reason: payload == null ? 'invalid-json' : generatedAt == null ? 'missing-timestamp' : 'predates-current-manager-epoch',
      generatedAt: generatedAt ? generatedAt.toISOString() : null,
    });
  }

  return {
    schema: 'priority/unattended-delivery-agent-startup-quarantine@v1',
    generatedAt: toIso(),
    repo,
    runtimeDir,
    runtimeEpochId,
    managerStartedAt: managerStartedAtIso,
    quarantineDirPath: quarantineEntries.length > 0 ? quarantineDirPath : null,
    entryCount: quarantineEntries.length,
    entries: quarantineEntries,
  };
}

export function writeLogTailTrace({ repo, runtimeDir, distro, tracePath, source, reason, logPath, lines = null, detail = {} }) {
  const tailLines = lines ?? readLogTail(logPath);
  if (!Array.isArray(tailLines) || tailLines.length === 0) {
    return;
  }
  writeManagerTrace({
    repo,
    runtimeDir,
    distro,
    tracePath,
    eventType: 'log-tail',
    detail: {
      source,
      reason,
      logPath,
      lineCount: tailLines.length,
      lines: tailLines,
      ...detail,
    },
  });
}

export function resolveGitDirPath(repoRoot) {
  const result = runCommand('git', ['-C', repoRoot, 'rev-parse', '--git-dir']);
  if (result.status !== 0) {
    throw new Error(`Unable to resolve git dir for ${repoRoot}.`);
  }
  const gitDirRaw = normalizeText(result.stdout);
  const gitDirPath = path.isAbsolute(gitDirRaw) ? gitDirRaw : path.join(repoRoot, gitDirRaw);
  return path.resolve(gitDirPath);
}

export function resolveControlRootBranch(repoRoot) {
  const result = runCommand('git', ['-C', repoRoot, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/upstream/HEAD']);
  if (result.status === 0) {
    const shortRef = normalizeText(result.stdout);
    const branchName = normalizeText(shortRef.split('/').pop());
    if (branchName) {
      return branchName;
    }
  }
  const branchClassPolicy = readJsonFile(path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'));
  const upstreamPlane = Array.isArray(branchClassPolicy?.repositoryPlanes)
    ? branchClassPolicy.repositoryPlanes.find((plane) => normalizeText(plane?.id) === 'upstream')
    : null;
  const fallbackBranchName = normalizeText(upstreamPlane?.developBranch);
  if (fallbackBranchName) {
    return fallbackBranchName;
  }
  return null;
}

export function resolveWorkspaceQuarantine(repoRoot) {
  const result = runCommand('git', ['-C', repoRoot, 'status', '--porcelain=v1', '--branch', '--untracked-files=normal']);
  if (result.status !== 0) {
    return {
      status: 'blocked',
      reason: 'git-status-failed',
      repoRoot,
      branchName: null,
      isControlRoot: null,
      trackedEntryCount: 0,
      untrackedEntryCount: 0,
      trackedEntries: [],
      untrackedEntries: [],
      errorMessage: normalizeText(result.stderr || result.stdout) || `git status exited with ${result.status}`,
    };
  }

  const trackedEntries = [];
  const untrackedEntries = [];
  const lines = result.stdout.split(/\r?\n/).map((line) => line.trimEnd()).filter(Boolean);
  let branchName = null;
  for (const line of lines) {
    if (line.startsWith('## ')) {
      const parsedBranchName = normalizeText(line.slice(3).split('...')[0]);
      branchName = parsedBranchName.startsWith('HEAD ') ? null : parsedBranchName;
      continue;
    }
    const entry = {
      raw: line,
      code: line.slice(0, 2),
      path: normalizeText(line.slice(3)),
    };
    if (line.startsWith('?? ')) {
      untrackedEntries.push(entry);
      continue;
    }
    trackedEntries.push(entry);
  }
  const controlRootBranch = resolveControlRootBranch(repoRoot);
  const identityKnown = Boolean(branchName) && Boolean(controlRootBranch);
  const isControlRoot = identityKnown ? branchName === controlRootBranch : null;
  const hasTrackedControlRootDirt = isControlRoot === true && trackedEntries.length > 0;
  const hasTrackedUnknownIdentityDirt = trackedEntries.length > 0 && isControlRoot == null;

  return {
    status: hasTrackedControlRootDirt || hasTrackedUnknownIdentityDirt ? 'blocked' : 'clear',
    reason: hasTrackedControlRootDirt
      ? 'tracked-dirt'
      : isControlRoot === false
        ? 'non-control-root'
        : isControlRoot === true
          ? 'clean'
          : 'control-root-identity-unknown',
    repoRoot,
    branchName,
    controlRootBranch,
    isControlRoot,
    trackedEntryCount: trackedEntries.length,
    untrackedEntryCount: untrackedEntries.length,
    trackedEntries,
    untrackedEntries,
    errorMessage: null,
  };
}

export function getStableLeaseOwner(repoRoot) {
  const leasePath = path.join(resolveGitDirPath(repoRoot), 'agent-writer-leases', 'workspace.json');
  const lease = readJsonFile(leasePath);
  if (lease?.owner) {
    return normalizeText(lease.owner);
  }
  const actor =
    normalizeText(process.env.AGENT_WRITER_LEASE_ACTOR) ||
    normalizeText(process.env.GITHUB_ACTOR) ||
    normalizeText(process.env.USERNAME) ||
    normalizeText(process.env.USER) ||
    'unknown';
  const hostName = normalizeText(process.env.COMPUTERNAME) || normalizeText(process.env.HOSTNAME) || 'unknown';
  return `${actor}@${hostName}:default`;
}

export function getWslRuntimeDaemonUnitName(repo) {
  let sanitized = normalizeText(repo).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (sanitized.length > 48) {
    sanitized = sanitized.slice(sanitized.length - 48);
  }
  return `comparevi-${sanitized}-daemon`;
}

export function convertToDeliveryLifecycle(value, fallback = 'planning', blocked = false) {
  const normalized = normalizeText(value).toLowerCase();
  const allowed = new Set([
    'planning',
    'reshaping-backlog',
    'coding',
    'waiting-ci',
    'waiting-review',
    'ready-merge',
    'blocked',
    'complete',
    'idle',
  ]);
  if (allowed.has(normalized)) {
    return normalized;
  }
  return blocked ? 'blocked' : fallback;
}

function projectConcurrentLaneApply(concurrentLaneApply) {
  if (!concurrentLaneApply || typeof concurrentLaneApply !== 'object') {
    return null;
  }
  const validateDispatch = getOptionalProperty(concurrentLaneApply, 'validateDispatch');
  return {
    receiptPath: getOptionalStringProperty(concurrentLaneApply, 'receiptPath'),
    status: getOptionalStringProperty(concurrentLaneApply, 'status'),
    selectedBundleId: getOptionalStringProperty(concurrentLaneApply, 'selectedBundleId'),
    validateDispatch:
      validateDispatch && typeof validateDispatch === 'object'
        ? {
            status: getOptionalStringProperty(validateDispatch, 'status'),
            repository: getOptionalStringProperty(validateDispatch, 'repository'),
            remote: getOptionalStringProperty(validateDispatch, 'remote'),
            ref: getOptionalStringProperty(validateDispatch, 'ref'),
            sampleIdStrategy: getOptionalStringProperty(validateDispatch, 'sampleIdStrategy'),
            sampleId: getOptionalStringProperty(validateDispatch, 'sampleId'),
            historyScenarioSet: getOptionalStringProperty(validateDispatch, 'historyScenarioSet'),
            allowFork: getOptionalProperty(validateDispatch, 'allowFork') === true,
            pushMissing: getOptionalProperty(validateDispatch, 'pushMissing') === true,
            forcePushOk: getOptionalProperty(validateDispatch, 'forcePushOk') === true,
            allowNonCanonicalViHistory: getOptionalProperty(validateDispatch, 'allowNonCanonicalViHistory') === true,
            allowNonCanonicalHistoryCore: getOptionalProperty(validateDispatch, 'allowNonCanonicalHistoryCore') === true,
            reportPath: getOptionalStringProperty(validateDispatch, 'reportPath'),
            runDatabaseId: getOptionalIntProperty(validateDispatch, 'runDatabaseId') || null,
            error: getOptionalStringProperty(validateDispatch, 'error'),
          }
        : null,
  };
}

function projectWorkerCheckoutIdentity(taskPacket, activeLane) {
  const laneEvidence = getOptionalProperty(getOptionalProperty(taskPacket, 'evidence'), 'lane');
  const providerDispatch = getOptionalProperty(activeLane, 'providerDispatch');
  const worker = getOptionalProperty(activeLane, 'worker');
  const workerReady = getOptionalProperty(activeLane, 'workerReady');
  const workerBranch = getOptionalProperty(activeLane, 'workerBranch');
  const taskBranch = getOptionalProperty(taskPacket, 'branch');
  return {
    workerSlotId:
      getOptionalStringProperty(laneEvidence, 'workerSlotId') ||
      getOptionalStringProperty(providerDispatch, 'workerSlotId'),
    workerCheckoutRoot:
      getOptionalStringProperty(laneEvidence, 'workerCheckoutRoot') ||
      getOptionalStringProperty(worker, 'checkoutRoot'),
    workerCheckoutRootPolicy: getOptionalProperty(laneEvidence, 'workerCheckoutRootPolicy'),
    workerCheckoutPath:
      getOptionalStringProperty(laneEvidence, 'workerCheckoutPath') ||
      getOptionalStringProperty(worker, 'checkoutPath') ||
      getOptionalStringProperty(workerReady, 'checkoutPath') ||
      getOptionalStringProperty(workerBranch, 'checkoutPath') ||
      getOptionalStringProperty(taskBranch, 'checkoutPath'),
  };
}

export function convertRuntimeArtifactsToDeliveryState({ repo, runtimeDir, runtimeState, taskPacket, paths }) {
  if (!runtimeState?.activeLane) {
    return null;
  }
  const activeLane = runtimeState.activeLane;
  const issue = getOptionalIntProperty(activeLane, 'issue');
  if (issue <= 0) {
    return null;
  }

  const runtimeGeneratedAt = getOptionalDateTimeProperty(runtimeState, 'generatedAt');
  const embeddedTaskPacket = getOptionalProperty(activeLane, 'taskPacket');
  const embeddedTaskPacketGeneratedAt = getOptionalDateTimeProperty(embeddedTaskPacket, 'generatedAt');
  const taskPacketGeneratedAt = getOptionalDateTimeProperty(taskPacket, 'generatedAt');
  let effectiveTaskPacket = embeddedTaskPacket;
  if (
    taskPacket &&
    (!embeddedTaskPacket ||
      (taskPacketGeneratedAt && (!embeddedTaskPacketGeneratedAt || taskPacketGeneratedAt > embeddedTaskPacketGeneratedAt)))
  ) {
    effectiveTaskPacket = taskPacket;
  }

  const runtimeLifecycle = getOptionalStringProperty(getOptionalProperty(runtimeState, 'lifecycle'), 'status');
  const runtimeDelivery = getOptionalProperty(getOptionalProperty(effectiveTaskPacket, 'evidence'), 'delivery');
  const concurrentLaneApply =
    projectConcurrentLaneApply(getOptionalProperty(activeLane, 'concurrentLaneApply')) ??
    projectConcurrentLaneApply(getOptionalProperty(runtimeDelivery, 'concurrentLaneApply'));
  const workerCheckoutIdentity = projectWorkerCheckoutIdentity(effectiveTaskPacket, activeLane);
  let taskLifecycle = getOptionalStringProperty(effectiveTaskPacket, 'status');
  if (!taskLifecycle) {
    taskLifecycle = getOptionalStringProperty(runtimeDelivery, 'laneLifecycle');
  }
  const laneLifecycleFallback = runtimeLifecycle === 'idle' ? 'idle' : runtimeLifecycle === 'blocked' ? 'blocked' : 'planning';
  const blockerClass =
    getOptionalStringProperty(activeLane, 'blockerClass') ||
    getOptionalStringProperty(getOptionalProperty(effectiveTaskPacket, 'checks'), 'blockerClass') ||
    'none';
  const laneLifecycle = convertToDeliveryLifecycle(taskLifecycle, laneLifecycleFallback, blockerClass !== 'none');
  const status = laneLifecycle === 'idle' ? 'idle' : laneLifecycle === 'blocked' ? 'blocked' : 'running';
  const generatedAt =
    taskPacketGeneratedAt && (!runtimeGeneratedAt || taskPacketGeneratedAt > runtimeGeneratedAt)
      ? taskPacketGeneratedAt
      : runtimeGeneratedAt;
  const iso = generatedAt ? generatedAt.toISOString() : toIso();
  const runtimeEpochId = getRuntimeEpochId(taskPacket) || getRuntimeEpochId(runtimeState) || null;

  return {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: iso,
    repository: repo,
    runtimeDir,
    runtimeEpochId,
    status,
    laneLifecycle,
    activeCodingLanes: laneLifecycle === 'coding' ? 1 : 0,
    derivedFromRuntimeState: true,
    concurrentLaneApply,
    activeLane: {
      schema: 'priority/delivery-agent-lane-state@v1',
      generatedAt: iso,
      runtimeEpochId,
      laneId: getOptionalStringProperty(activeLane, 'laneId'),
      issue,
      epic: getOptionalIntProperty(activeLane, 'epic'),
      branch:
        getOptionalStringProperty(activeLane, 'branch') ||
        getOptionalStringProperty(getOptionalProperty(effectiveTaskPacket, 'branch'), 'name'),
      forkRemote:
        getOptionalStringProperty(activeLane, 'forkRemote') ||
        getOptionalStringProperty(getOptionalProperty(effectiveTaskPacket, 'branch'), 'forkRemote'),
      prUrl:
        getOptionalStringProperty(activeLane, 'prUrl') ||
        getOptionalStringProperty(getOptionalProperty(effectiveTaskPacket, 'pullRequest'), 'url'),
      blockerClass,
      laneLifecycle,
      actionType:
        getOptionalStringProperty(runtimeDelivery, 'selectedActionType') ||
        getOptionalStringProperty(getOptionalProperty(runtimeState, 'lifecycle'), 'lastAction'),
      outcome: getOptionalStringProperty(getOptionalProperty(runtimeState, 'lifecycle'), 'status'),
      reason: getOptionalStringProperty(getOptionalProperty(runtimeState, 'lifecycle'), 'status'),
      retryable: false,
      nextWakeCondition: null,
      concurrentLaneApply,
      workerSlotId: workerCheckoutIdentity.workerSlotId,
      workerCheckoutRoot: workerCheckoutIdentity.workerCheckoutRoot,
      workerCheckoutRootPolicy: workerCheckoutIdentity.workerCheckoutRootPolicy,
      workerCheckoutPath: workerCheckoutIdentity.workerCheckoutPath,
    },
    artifacts: {
      statePath: paths.deliveryStatePath,
      lanePath: paths.taskPacketPath,
      concurrentLaneApplyReceiptPath: concurrentLaneApply?.receiptPath || null,
    },
  };
}

export function resolveDeliveryStateForStatus({
  repo,
  runtimeDir,
  deliveryState,
  heartbeat,
  runtimeState,
  taskPacket,
  paths,
  managerStartedAt = null,
  daemonStartedAt = null,
  daemonAlive = false,
  heartbeatFreshnessSeconds = 300,
  currentRuntimeEpochId = null,
}) {
  const runtimeEpochId = normalizeText(currentRuntimeEpochId) || null;
  const deliveryGeneratedAt = getOptionalDateTimeProperty(deliveryState, 'generatedAt');
  const heartbeatGeneratedAt = getOptionalDateTimeProperty(heartbeat, 'generatedAt');
  const runtimeGeneratedAt = getOptionalDateTimeProperty(runtimeState, 'generatedAt');
  const taskPacketGeneratedAt = getOptionalDateTimeProperty(taskPacket, 'generatedAt');
  const deliveryRuntimeEpochId = getRuntimeEpochId(deliveryState);
  const heartbeatRuntimeEpochId = getRuntimeEpochId(heartbeat);
  const runtimeStateRuntimeEpochId = getRuntimeEpochId(runtimeState);
  const taskPacketRuntimeEpochId = getRuntimeEpochId(taskPacket);
  const deliveryRuntimeEpochAlignment = describeRuntimeEpochAlignment(runtimeEpochId, deliveryRuntimeEpochId);
  const heartbeatRuntimeEpochAlignment = describeRuntimeEpochAlignment(runtimeEpochId, heartbeatRuntimeEpochId);
  const runtimeStateRuntimeEpochAlignment = describeRuntimeEpochAlignment(runtimeEpochId, runtimeStateRuntimeEpochId);
  const taskPacketRuntimeEpochAlignment = describeRuntimeEpochAlignment(runtimeEpochId, taskPacketRuntimeEpochId);
  const diagnostics = {
    usedHeartbeat: false,
    usedRuntimeState: false,
    reason: 'delivery-state-missing',
    currentRuntimeEpochId: runtimeEpochId,
    deliveryRuntimeEpochId,
    heartbeatRuntimeEpochId,
    runtimeStateRuntimeEpochId,
    taskPacketRuntimeEpochId,
    deliveryRuntimeEpochAlignment,
    heartbeatRuntimeEpochAlignment,
    runtimeStateRuntimeEpochAlignment,
    taskPacketRuntimeEpochAlignment,
    heartbeatGeneratedAt: heartbeatGeneratedAt ? heartbeatGeneratedAt.toISOString() : null,
    deliveryGeneratedAt: deliveryGeneratedAt ? deliveryGeneratedAt.toISOString() : null,
    runtimeGeneratedAt: runtimeGeneratedAt ? runtimeGeneratedAt.toISOString() : null,
    taskPacketGeneratedAt: taskPacketGeneratedAt ? taskPacketGeneratedAt.toISOString() : null,
    managerStartedAt: managerStartedAt ? managerStartedAt.toISOString() : null,
    daemonStartedAt: daemonStartedAt ? daemonStartedAt.toISOString() : null,
    daemonAlive: Boolean(daemonAlive),
    heartbeatFreshnessSeconds: Number(heartbeatFreshnessSeconds),
    heartbeatRepository: getOptionalStringProperty(heartbeat, 'repository'),
    runtimeRepository: getOptionalStringProperty(runtimeState, 'repository'),
  };

  let effectiveDeliveryState = deliveryState;
  let effectiveDeliveryGeneratedAt = deliveryGeneratedAt;
  if (runtimeEpochId && deliveryState && deliveryRuntimeEpochAlignment !== 'aligned') {
    effectiveDeliveryState = null;
    effectiveDeliveryGeneratedAt = null;
    diagnostics.reason = resolveRuntimeEpochMismatchReason('delivery-state', deliveryRuntimeEpochAlignment);
  }

  const effectiveTaskPacket =
    runtimeEpochId && taskPacket && taskPacketRuntimeEpochAlignment !== 'aligned'
      ? null
      : taskPacket;

  let runtimeDeliveryState = null;
  let runtimeIssue = 0;
  const runtimeRepo = getOptionalStringProperty(runtimeState, 'repository');
  if (runtimeState) {
    if (runtimeRepo && runtimeRepo !== repo) {
      diagnostics.reason = 'runtime-state-repository-mismatch';
    } else if (runtimeEpochId && runtimeStateRuntimeEpochAlignment !== 'aligned') {
      diagnostics.reason = resolveRuntimeEpochMismatchReason('runtime-state', runtimeStateRuntimeEpochAlignment);
    } else {
      runtimeDeliveryState = convertRuntimeArtifactsToDeliveryState({
        repo,
        runtimeDir,
        runtimeState,
        taskPacket: effectiveTaskPacket,
        paths,
      });
      if (runtimeDeliveryState?.activeLane) {
        runtimeIssue = getOptionalIntProperty(runtimeDeliveryState.activeLane, 'issue');
      }
    }
  }

  const useRuntimeIfCurrent = () => {
    diagnostics.reason = 'runtime-state-current';
    diagnostics.usedRuntimeState = true;
    return { state: runtimeDeliveryState, diagnostics };
  };

  if (!heartbeat?.activeLane) {
    if (
      runtimeDeliveryState &&
      (!effectiveDeliveryGeneratedAt ||
        runtimeGeneratedAt > effectiveDeliveryGeneratedAt ||
        (effectiveDeliveryState?.activeLane &&
          getOptionalIntProperty(effectiveDeliveryState.activeLane, 'issue') !== runtimeIssue))
    ) {
      return useRuntimeIfCurrent();
    }
    if (effectiveDeliveryState) {
      diagnostics.reason = 'delivery-state-current';
    }
    return { state: effectiveDeliveryState, diagnostics };
  }

  const heartbeatLane = heartbeat.activeLane;
  const deliveryIssue = effectiveDeliveryState?.activeLane ? getOptionalIntProperty(effectiveDeliveryState.activeLane, 'issue') : 0;
  const heartbeatIssue = getOptionalIntProperty(heartbeatLane, 'issue');
  if (heartbeatIssue <= 0) {
    if (
      runtimeDeliveryState &&
      (!effectiveDeliveryGeneratedAt || runtimeGeneratedAt > effectiveDeliveryGeneratedAt || deliveryIssue !== runtimeIssue)
    ) {
      return useRuntimeIfCurrent();
    }
    diagnostics.reason = 'heartbeat-missing-issue';
    return { state: effectiveDeliveryState, diagnostics };
  }

  const heartbeatRepo = getOptionalStringProperty(heartbeat, 'repository');
  if (heartbeatRepo && heartbeatRepo !== repo) {
    if (
      runtimeDeliveryState &&
      (!effectiveDeliveryGeneratedAt || runtimeGeneratedAt > effectiveDeliveryGeneratedAt || deliveryIssue !== runtimeIssue)
    ) {
      return useRuntimeIfCurrent();
    }
    diagnostics.reason = 'heartbeat-repository-mismatch';
    return { state: effectiveDeliveryState, diagnostics };
  }

  const nowUtc = new Date();
  const heartbeatTooOld =
    heartbeatGeneratedAt && heartbeatFreshnessSeconds > 0
      ? (nowUtc.getTime() - heartbeatGeneratedAt.getTime()) / 1000 > heartbeatFreshnessSeconds
      : false;
  const beforeCurrentManager = Boolean(managerStartedAt && heartbeatGeneratedAt && heartbeatGeneratedAt < managerStartedAt);
  const beforeCurrentDaemon = Boolean(daemonStartedAt && heartbeatGeneratedAt && heartbeatGeneratedAt < daemonStartedAt);
  const heartbeatPredatesCurrentEpoch = beforeCurrentManager || beforeCurrentDaemon;
  if (heartbeatPredatesCurrentEpoch) {
    if (
      runtimeDeliveryState &&
      (!effectiveDeliveryGeneratedAt || runtimeGeneratedAt > effectiveDeliveryGeneratedAt || deliveryIssue !== runtimeIssue)
    ) {
      return useRuntimeIfCurrent();
    }
    diagnostics.reason = 'stale-before-current-manager';
    return { state: effectiveDeliveryState, diagnostics };
  }
  if (!daemonAlive && heartbeatTooOld) {
    if (
      runtimeDeliveryState &&
      (!effectiveDeliveryGeneratedAt || runtimeGeneratedAt > effectiveDeliveryGeneratedAt || deliveryIssue !== runtimeIssue)
    ) {
      return useRuntimeIfCurrent();
    }
    diagnostics.reason = 'stale-heartbeat-daemon-dead';
    return { state: effectiveDeliveryState, diagnostics };
  }
  if (runtimeEpochId && heartbeatRuntimeEpochAlignment !== 'aligned') {
    if (
      runtimeDeliveryState &&
      (!effectiveDeliveryGeneratedAt || runtimeGeneratedAt > effectiveDeliveryGeneratedAt || deliveryIssue !== runtimeIssue)
    ) {
      return useRuntimeIfCurrent();
    }
    diagnostics.reason = resolveRuntimeEpochMismatchReason('heartbeat', heartbeatRuntimeEpochAlignment);
    return { state: effectiveDeliveryState, diagnostics };
  }

  if (
    effectiveDeliveryState &&
    effectiveDeliveryGeneratedAt &&
    (!heartbeatGeneratedAt || effectiveDeliveryGeneratedAt >= heartbeatGeneratedAt)
  ) {
    diagnostics.reason = 'delivery-state-current';
    return { state: effectiveDeliveryState, diagnostics };
  }

  let freshestBaseGeneratedAt = effectiveDeliveryGeneratedAt;
  if (runtimeDeliveryState && runtimeGeneratedAt && (!freshestBaseGeneratedAt || runtimeGeneratedAt > freshestBaseGeneratedAt)) {
    freshestBaseGeneratedAt = runtimeGeneratedAt;
  }
  const currentBaseIssue = runtimeIssue > 0 ? runtimeIssue : deliveryIssue;
  const heartbeatNewer = Boolean(heartbeatGeneratedAt && (!freshestBaseGeneratedAt || heartbeatGeneratedAt > freshestBaseGeneratedAt));
  const issueDrift = currentBaseIssue !== heartbeatIssue;
  if (!heartbeatNewer && !issueDrift) {
    if (
      runtimeDeliveryState &&
      (!effectiveDeliveryGeneratedAt || runtimeGeneratedAt > effectiveDeliveryGeneratedAt || deliveryIssue !== runtimeIssue)
    ) {
      return useRuntimeIfCurrent();
    }
    diagnostics.reason = 'delivery-state-current';
    return { state: effectiveDeliveryState, diagnostics };
  }

  const laneId = getOptionalStringProperty(heartbeatLane, 'laneId');
  const heartbeatTaskPacket = getOptionalProperty(heartbeatLane, 'taskPacket');
  const heartbeatDelivery = getOptionalProperty(getOptionalProperty(heartbeatTaskPacket, 'evidence'), 'delivery');
  const concurrentLaneApply =
    projectConcurrentLaneApply(getOptionalProperty(heartbeatLane, 'concurrentLaneApply')) ??
    projectConcurrentLaneApply(getOptionalProperty(getOptionalProperty(getOptionalProperty(heartbeatLane, 'execution'), 'details'), 'concurrentLaneApply')) ??
    projectConcurrentLaneApply(getOptionalProperty(heartbeatDelivery, 'concurrentLaneApply'));
  const workerCheckoutIdentity = projectWorkerCheckoutIdentity(heartbeatTaskPacket, heartbeatLane);
  const taskStatus = getOptionalStringProperty(heartbeatTaskPacket, 'status');
  const runtimeOutcome = getOptionalStringProperty(heartbeat, 'outcome');
  const laneLifecycle = /blocked|failed/i.test(runtimeOutcome || '')
    ? 'blocked'
    : convertToDeliveryLifecycle(taskStatus, 'planning', false);
  const status = laneLifecycle === 'idle' ? 'idle' : laneLifecycle === 'blocked' ? 'blocked' : 'running';
  const lanePath = laneId ? path.join(paths.runtimeDirPath, 'delivery-agent-lanes', `${laneId}.json`) : null;

  diagnostics.usedHeartbeat = true;
  diagnostics.reason = 'fresh-heartbeat';
  return {
    state: {
      schema: 'priority/delivery-agent-runtime-state@v1',
      generatedAt: heartbeatGeneratedAt ? heartbeatGeneratedAt.toISOString() : toIso(),
      repository: repo,
      runtimeDir,
      runtimeEpochId: runtimeEpochId || heartbeatRuntimeEpochId || null,
      status,
      laneLifecycle,
      activeCodingLanes: laneLifecycle === 'coding' ? 1 : 0,
      derivedFromHeartbeat: true,
      concurrentLaneApply,
      activeLane: {
        schema: 'priority/delivery-agent-lane-state@v1',
        generatedAt: heartbeatGeneratedAt ? heartbeatGeneratedAt.toISOString() : toIso(),
        runtimeEpochId: runtimeEpochId || heartbeatRuntimeEpochId || null,
        laneId,
        issue: heartbeatIssue,
        epic: getOptionalIntProperty(heartbeatLane, 'epic'),
        branch: getOptionalStringProperty(heartbeatLane, 'branch'),
        forkRemote: getOptionalStringProperty(heartbeatLane, 'forkRemote'),
        prUrl: getOptionalStringProperty(heartbeatLane, 'prUrl'),
        blockerClass: getOptionalStringProperty(heartbeatLane, 'blockerClass'),
        laneLifecycle,
        actionType: runtimeOutcome,
        outcome: runtimeOutcome,
        reason: runtimeOutcome,
        retryable: false,
        nextWakeCondition: null,
        concurrentLaneApply,
        workerSlotId: workerCheckoutIdentity.workerSlotId,
        workerCheckoutRoot: workerCheckoutIdentity.workerCheckoutRoot,
        workerCheckoutRootPolicy: workerCheckoutIdentity.workerCheckoutRootPolicy,
        workerCheckoutPath: workerCheckoutIdentity.workerCheckoutPath,
      },
      artifacts: {
        statePath: paths.deliveryStatePath,
        lanePath,
        concurrentLaneApplyReceiptPath: concurrentLaneApply?.receiptPath || null,
      },
    },
    diagnostics,
  };
}

// @ts-nocheck

import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { runDeliveryHostSignal } from '../delivery-host-signal.js';
import {
  DEFAULTS,
  convertToWslPath,
  getArtifactPaths,
  getNpmCommand,
  normalizeText,
  readJsonFile,
  resolveCommandPath,
  resolveGitDirPath,
  resolveRepoRoot,
  runCommand,
  toIso,
  writeJsonFile,
} from './delivery-agent-common.js';

export function invokeDeliveryHostSignal({ mode, repoRoot, distro, paths, previousFingerprint = null, allowRunnerServices = false, resetFingerprintBaseline = false }) {
  return runDeliveryHostSignal({
    mode,
    repoRoot,
    distro,
    dockerHost: DEFAULTS.dockerHost,
    reportPath: paths.hostSignalPath,
    isolationPath: paths.hostIsolationPath,
    tracePath: paths.hostTracePath,
    previousFingerprint,
    requireRunnerStopped: !allowRunnerServices,
    resetFingerprintBaseline,
  });
}

export function repairRepoGitWorktreeConfig(repoRoot) {
  if (!repoRoot) {
    return { repaired: false, previousWorktree: null, reason: 'gitdir-not-directory' };
  }
  const currentWorktree = normalizeText(runCommand('git', ['-C', repoRoot, 'config', '--local', '--get', 'core.worktree']).stdout);
  if (!currentWorktree) {
    return { repaired: false, previousWorktree: null, reason: 'already-unset' };
  }
  const normalizedRepoRoot = path.resolve(repoRoot);
  const gitDirPath = resolveGitDirPath(repoRoot);
  const candidatePaths = new Set();
  if (path.isAbsolute(currentWorktree)) {
    candidatePaths.add(path.resolve(currentWorktree));
  } else {
    candidatePaths.add(path.resolve(repoRoot, currentWorktree));
    candidatePaths.add(path.resolve(gitDirPath, currentWorktree));
  }
  for (const candidatePath of candidatePaths) {
    if (candidatePath === normalizedRepoRoot && existsSync(candidatePath)) {
      return { repaired: false, previousWorktree: currentWorktree, reason: 'already-valid' };
    }
  }
  const unsetResult = runCommand('git', ['-C', repoRoot, 'config', '--local', '--unset-all', 'core.worktree']);
  if (unsetResult.status !== 0) {
    throw new Error(`Failed to unset core.worktree for ${repoRoot}`);
  }
  return { repaired: true, previousWorktree: currentWorktree, reason: 'unset-invalid-worktree' };
}

export function runNodeJsonScript(scriptPath, args, fallbackPayload) {
  if (!scriptPath) {
    return fallbackPayload;
  }
  const result = runCommand(process.execPath, [scriptPath, ...args]);
  if (result.status !== 0) {
    return {
      ...fallbackPayload,
      status: 'error',
      reason: 'tool-failed',
      exitCode: result.status,
      message: normalizeText(result.stderr || result.stdout),
    };
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    return { ...fallbackPayload, status: 'error', reason: 'report-parse-failed' };
  }
}

export function getWslDefaultUser(distro) {
  const result = runCommand('wsl.exe', ['-d', distro, '--', 'bash', '-lc', 'id -un']);
  if (result.status !== 0) {
    throw new Error(`Unable to resolve the default WSL user for distro '${distro}'.`);
  }
  const user = normalizeText(result.stdout.split(/\r?\n/).pop() || result.stdout);
  if (!user) {
    throw new Error(`Unable to resolve the default WSL user for distro '${distro}'.`);
  }
  return user;
}

export function ensureNativeWslDocker({ repoRoot, distro, targetUser, paths }) {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'bash', 'ensure-native-wsl-docker.sh');
  const scriptPathWsl = convertToWslPath(scriptPath);
  const output = runCommand('wsl.exe', ['-d', distro, '-u', 'root', '--', 'env', `COMPAREVI_WSL_TARGET_USER=${targetUser}`, 'bash', scriptPathWsl]);
  if (output.status !== 0) {
    throw new Error(`Native WSL Docker bootstrap failed for distro '${distro}': ${normalizeText(output.stderr || output.stdout)}`);
  }
  const report = JSON.parse(output.stdout);
  const dockerInfoText = normalizeText(report.dockerInfoBase64)
    ? Buffer.from(String(report.dockerInfoBase64), 'base64').toString('utf8')
    : '';
  const dockerInfo = dockerInfoText ? JSON.parse(dockerInfoText) : null;
  const platformName = normalizeText(dockerInfo?.Platform?.Name);
  const operatingSystem = normalizeText(dockerInfo?.OperatingSystem);
  const serverName = normalizeText(dockerInfo?.Name);
  const isDockerDesktop = /docker desktop|docker-desktop/i.test([platformName, operatingSystem, serverName].join(' '));
  const nativeOwned =
    !isDockerDesktop &&
    report.socketPresent === true &&
    report.serviceState === 'active' &&
    dockerInfo &&
    normalizeText(report.serverVersion) &&
    normalizeText(dockerInfo?.OSType) === 'linux';
  const hydrated = {
    ...report,
    ensuredAt: toIso(),
    distro,
    dockerInfo,
    isDockerDesktop,
    nativeOwned,
  };
  delete hydrated.dockerInfoBase64;
  writeJsonFile(paths.wslNativeDockerPath, hydrated);
  if (!nativeOwned) {
    throw new Error(`WSL Docker bootstrap did not produce a native distro-owned daemon for '${distro}'. See ${paths.wslNativeDockerPath}`);
  }
  return hydrated;
}

export function getGlobalGitConfig(key) {
  const result = runCommand('git', ['config', '--global', key]);
  return normalizeText(result.stdout);
}

export function getCodexRequestedVersion() {
  const npmCommand = getNpmCommand();
  const result = runCommand(npmCommand, ['view', '@openai/codex', 'version']);
  return normalizeText(result.stdout) || 'latest';
}

export function runWslDeliveryPrereqs({ repoRoot, distro, nodeVersion, pwshVersion, codexVersion, ghPath, gitUserName, gitUserEmail }) {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'bash', 'ensure-wsl-delivery-prereqs.sh');
  const scriptPathWsl = convertToWslPath(scriptPath);
  const codexHomePath = convertToWslPath(path.join(process.env.USERPROFILE || process.env.HOME || repoRoot, '.codex'));
  const envArgs = [
    `COMPAREVI_WSL_NODE_VERSION=${nodeVersion}`,
    `COMPAREVI_WSL_GH_EXE=${convertToWslPath(ghPath)}`,
    `COMPAREVI_WSL_PWSH_VERSION=${pwshVersion}`,
    `COMPAREVI_WSL_CODEX_VERSION=${codexVersion}`,
    `COMPAREVI_WSL_CODEX_HOME=${codexHomePath}`,
    `COMPAREVI_WSL_GIT_USER_NAME=${gitUserName}`,
    `COMPAREVI_WSL_GIT_USER_EMAIL=${gitUserEmail}`,
  ];
  const result = runCommand('wsl.exe', ['-d', distro, '--', 'env', ...envArgs, 'bash', scriptPathWsl]);
  if (result.status !== 0) {
    throw new Error(`WSL delivery prerequisite bootstrap failed for distro '${distro}': ${normalizeText(result.stderr || result.stdout)}`);
  }
  return JSON.parse(result.stdout);
}

export function resolveDefaultHostIsolationState({ repo, runtimeDir, distro, hostSignalPath }) {
  return {
    schema: 'priority/delivery-agent-host-isolation@v1',
    generatedAt: toIso(),
    repo,
    runtimeDir,
    distro,
    dockerHost: DEFAULTS.dockerHost,
    runnerServicePolicy: 'stop-all-actions-runner-services',
    restoreRunnerServicesOnExit: true,
    preemptedServices: [],
    restoredServices: [],
    lastAction: 'status',
    lastEvent: null,
    lastDrift: null,
    daemonFingerprint: null,
    lastStatus: null,
    hostSignalPath,
    counters: {
      runnerPreemptionCount: 0,
      runnerRestoreCount: 0,
      dockerDriftIncidentCount: 0,
      nativeDaemonRepairCount: 0,
      cyclesBlockedByHostRuntimeConflict: 0,
    },
  };
}

export function updateHostIsolationState({ path: isolationPath, repo, runtimeDir, distro, hostSignalPath, counterName = '', increment = 0, lastEventType = '', lastEventDetail = '', hostSignal = null }) {
  const state = readJsonFile(isolationPath) || resolveDefaultHostIsolationState({ repo, runtimeDir, distro, hostSignalPath });
  state.counters ||= {};
  for (const name of ['runnerPreemptionCount', 'runnerRestoreCount', 'dockerDriftIncidentCount', 'nativeDaemonRepairCount', 'cyclesBlockedByHostRuntimeConflict']) {
    if (!Number.isInteger(state.counters[name])) {
      state.counters[name] = 0;
    }
  }
  if (counterName) {
    state.counters[counterName] += increment;
  }
  if (lastEventType) {
    state.lastEvent = {
      type: lastEventType,
      at: toIso(),
      detail: normalizeText(lastEventDetail) || null,
    };
  }
  if (hostSignal) {
    state.generatedAt = toIso();
    state.daemonFingerprint = hostSignal.daemonFingerprint;
    state.lastStatus = hostSignal.status;
    state.hostSignalPath = hostSignalPath;
  }
  writeJsonFile(isolationPath, state);
  return state;
}

export function runRepoHygiene(options) {
  const repoRoot = options.repoRoot || resolveRepoRoot();
  const paths = getArtifactPaths(repoRoot, options.runtimeDir || DEFAULTS.runtimeDir);
  const repoGitWorktreeRepair = repairRepoGitWorktreeConfig(repoRoot);
  const crossPlaneWorktreeRepair = runNodeJsonScript(
    path.join(repoRoot, 'tools', 'priority', 'repair-runtime-worktrees.mjs'),
    ['--repo-root', repoRoot, '--report', path.join(paths.runtimeDirPath, 'cross-plane-worktree-repair.json')],
    { status: 'skipped', reason: 'script-missing', reportPath: null },
  );
  const codexStateHygiene = runNodeJsonScript(
    path.join(repoRoot, 'tools', 'priority', 'codex-state-hygiene.mjs'),
    ['--repo-root', repoRoot, '--apply', '--report', paths.codexStateHygienePath],
    { status: 'skipped', reason: 'script-missing', reportPath: paths.codexStateHygienePath },
  );
  return {
    repoGitWorktreeRepair,
    crossPlaneWorktreeRepair,
    codexStateHygiene,
  };
}

export async function runPrereqsCommand(options) {
  const repoRoot = options.repoRoot || resolveRepoRoot();
  const reportPath = path.isAbsolute(options.reportPath) ? options.reportPath : path.join(repoRoot, options.reportPath || DEFAULTS.reportPath);
  const paths = getArtifactPaths(repoRoot, options.runtimeDir || DEFAULTS.runtimeDir);
  const ghPath = resolveCommandPath('gh');
  const gitUserName = getGlobalGitConfig('user.name');
  const gitUserEmail = getGlobalGitConfig('user.email');
  const codexVersion = getCodexRequestedVersion();
  const repoHygiene = runRepoHygiene({ ...options, repoRoot });
  const wslDefaultUser = getWslDefaultUser(options.wslDistro);
  const wslNativeDocker = ensureNativeWslDocker({ repoRoot, distro: options.wslDistro, targetUser: wslDefaultUser, paths });
  const hostSignal = invokeDeliveryHostSignal({
    mode: 'collect',
    repoRoot,
    distro: options.wslDistro,
    paths,
    previousFingerprint: null,
    allowRunnerServices: true,
    resetFingerprintBaseline: true,
  });
  const prereqReport = runWslDeliveryPrereqs({
    repoRoot,
    distro: options.wslDistro,
    nodeVersion: options.nodeVersion,
    pwshVersion: options.pwshVersion,
    codexVersion,
    ghPath,
    gitUserName,
    gitUserEmail,
  });
  const report = {
    ...prereqReport,
    ensuredAt: toIso(),
    distro: options.wslDistro,
    nodeRequested: options.nodeVersion,
    pwshRequested: options.pwshVersion,
    codexRequested: codexVersion,
    ...repoHygiene,
    wslDefaultUser,
    wslNativeDocker,
    hostSignal: hostSignal.report,
  };
  writeJsonFile(reportPath, report);
  return report;
}

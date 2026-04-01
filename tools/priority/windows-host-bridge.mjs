import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

export const DEFAULT_WINDOWS_PWSH_CANDIDATES = Object.freeze([
  '/mnt/c/Program Files/PowerShell/7/pwsh.exe',
  '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
]);

const DEFAULT_MAX_BUFFER_BYTES = 64 * 1024 * 1024;

function runProcess(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? process.cwd(),
    encoding: 'utf8',
    env: options.env ?? process.env,
    maxBuffer: options.maxBuffer ?? DEFAULT_MAX_BUFFER_BYTES,
  });
  return {
    status: typeof result.status === 'number' ? result.status : null,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function trimText(value) {
  return String(value ?? '').trim();
}

function quotePowerShellLiteral(value) {
  return `'${String(value ?? '').replace(/'/g, "''")}'`;
}

function splitRelativeWindowsPath(value) {
  return String(value ?? '')
    .split(/[\\/]+/)
    .filter(Boolean);
}

export function resolveRepoWindowsPath(repoRoot, runProcessFn = runProcess) {
  const result = runProcessFn('wslpath', ['-w', repoRoot], { cwd: repoRoot });
  if (result.status !== 0) {
    throw new Error(
      trimText(result.stderr) ||
      trimText(result.stdout) ||
      'wslpath failed to translate the repository root to a Windows path.',
    );
  }
  const translated = trimText(result.stdout);
  if (!translated) {
    throw new Error('wslpath did not return a Windows path for the repository root.');
  }
  return translated;
}

export function resolveWindowsPwshPath(
  runProcessFn = runProcess,
  pathExists = existsSync,
  candidates = DEFAULT_WINDOWS_PWSH_CANDIDATES,
) {
  for (const candidate of candidates) {
    if (!pathExists(candidate)) continue;
    const probe = runProcessFn(candidate, ['-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']);
    if (probe.status === 0) {
      return candidate;
    }
  }

  const fallback = runProcessFn('pwsh.exe', ['-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']);
  if (fallback.status === 0) {
    return 'pwsh.exe';
  }

  return null;
}

export function resolveWindowsNodePath(windowsPwshPath, runProcessFn = runProcess) {
  const result = runProcessFn(windowsPwshPath, [
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    '(Get-Command node.exe -ErrorAction Stop).Source',
  ]);
  if (result.status !== 0) {
    throw new Error(
      trimText(result.stderr) ||
      trimText(result.stdout) ||
      'Unable to resolve node.exe on the reachable Windows host.',
    );
  }
  const nodePath = trimText(result.stdout);
  if (!nodePath) {
    throw new Error('The reachable Windows host did not return a node.exe path.');
  }
  return nodePath;
}

export function detectWindowsHostBridge(
  repoRoot,
  {
    platform = process.platform,
    runProcessFn = runProcess,
    pathExists = existsSync,
  } = {},
) {
  const coordinatorHostPlatform = platform === 'win32' ? 'Windows' : 'Unix';
  if (platform === 'win32') {
    return {
      status: 'native',
      bridge_mode: 'native-windows',
      coordinator_host_platform: coordinatorHostPlatform,
      current_host_platform: 'Windows',
      repo_root_windows: repoRoot,
      windows_pwsh_path: 'pwsh',
      windows_node_path: process.execPath,
      reason: 'Current coordinator is already running on Windows.',
    };
  }

  let repoRootWindows;
  try {
    repoRootWindows = resolveRepoWindowsPath(repoRoot, runProcessFn);
  } catch (error) {
    return {
      status: 'unavailable',
      bridge_mode: 'wsl-windows',
      coordinator_host_platform: coordinatorHostPlatform,
      current_host_platform: coordinatorHostPlatform,
      reason: error instanceof Error ? error.message : String(error),
    };
  }

  const windowsPwshPath = resolveWindowsPwshPath(runProcessFn, pathExists);
  if (!windowsPwshPath) {
    return {
      status: 'unavailable',
      bridge_mode: 'wsl-windows',
      coordinator_host_platform: coordinatorHostPlatform,
      current_host_platform: coordinatorHostPlatform,
      repo_root_windows: repoRootWindows,
      reason: 'No reachable Windows PowerShell executable is available from the current coordinator.',
    };
  }

  let windowsNodePath = null;
  try {
    windowsNodePath = resolveWindowsNodePath(windowsPwshPath, runProcessFn);
  } catch {
    windowsNodePath = null;
  }

  return {
    status: 'reachable',
    bridge_mode: 'wsl-windows',
    coordinator_host_platform: coordinatorHostPlatform,
    current_host_platform: 'Windows',
    repo_root_windows: repoRootWindows,
    windows_pwsh_path: windowsPwshPath,
    windows_node_path: windowsNodePath,
    reason: 'A reachable Windows host is available through a local bridge from the current coordinator.',
  };
}

export function buildWindowsPath(rootPathWindows, relativePath) {
  return path.win32.join(rootPathWindows, ...splitRelativeWindowsPath(relativePath));
}

function serializePowerShellArgs(args) {
  return args.map((value) => quotePowerShellLiteral(value)).join(' ');
}

function isPowerShellParameterToken(value) {
  return /^-[A-Za-z][A-Za-z0-9-]*$/.test(String(value ?? ''));
}

function serializePowerShellFileArgs(args) {
  return args
    .map((value) => (isPowerShellParameterToken(value) ? String(value) : quotePowerShellLiteral(value)))
    .join(' ');
}

export function buildWindowsPowerShellFileBridgeSpec({
  bridge,
  scriptRelativePath,
  scriptArgs = [],
}) {
  const scriptPathWindows = buildWindowsPath(bridge.repo_root_windows, scriptRelativePath);
  const commandText = [
    `Set-Location -LiteralPath ${quotePowerShellLiteral(bridge.repo_root_windows)}`,
    `& ${quotePowerShellLiteral(scriptPathWindows)}${scriptArgs.length > 0 ? ` ${serializePowerShellFileArgs(scriptArgs)}` : ''}`,
  ].join('; ');
  return {
    command: bridge.windows_pwsh_path,
    args: [
      '-NoLogo',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      commandText,
    ],
    script_path_windows: scriptPathWindows,
  };
}

export function buildWindowsNodeBridgeSpec({
  bridge,
  scriptRelativePath,
  scriptArgs = [],
}) {
  if (!bridge.windows_node_path) {
    throw new Error('A reachable Windows node.exe path is required before building a Windows Node bridge spec.');
  }
  const scriptPathWindows = buildWindowsPath(bridge.repo_root_windows, scriptRelativePath);
  const commandText = [
    `Set-Location -LiteralPath ${quotePowerShellLiteral(bridge.repo_root_windows)}`,
    `& ${quotePowerShellLiteral(bridge.windows_node_path)} ${quotePowerShellLiteral(scriptPathWindows)}${scriptArgs.length > 0 ? ` ${serializePowerShellArgs(scriptArgs)}` : ''}`,
  ].join('; ');
  return {
    command: bridge.windows_pwsh_path,
    args: [
      '-NoLogo',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      commandText,
    ],
    script_path_windows: scriptPathWindows,
    node_path_windows: bridge.windows_node_path,
  };
}

export function runBridgeSpec(spec, options = {}) {
  return runProcess(spec.command, spec.args, options);
}

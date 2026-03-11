#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'os';
import { dirname, join, resolve } from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

export const DELIVERY_HOST_SIGNAL_SCHEMA = 'priority/delivery-agent-host-signal@v1';
export const DELIVERY_HOST_ISOLATION_SCHEMA = 'priority/delivery-agent-host-isolation@v1';
export const DELIVERY_HOST_SIGNAL_RUN_SCHEMA = 'priority/delivery-agent-host-signal-run@v1';
export const DEFAULT_REPORT_PATH = join('tests', 'results', '_agent', 'runtime', 'daemon-host-signal.json');
export const DEFAULT_ISOLATION_PATH = join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'delivery-agent-host-isolation.json',
);
export const DEFAULT_TRACE_PATH = join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'delivery-agent-host-trace.ndjson',
);
export const DEFAULT_DOCKER_HOST = 'unix:///var/run/docker.sock';
export const DEFAULT_WSL_DISTRO = 'Ubuntu';
export const DEFAULT_RUNNER_SERVICE_PREFIX = 'actions.runner.';
const MAX_BUFFER = 32 * 1024 * 1024;

export type HostSignalMode = 'collect' | 'isolate' | 'restore';
export type HostSignalStatus = 'native-wsl' | 'desktop-backed' | 'runner-conflict' | 'drifted';

interface CliOptions {
  help: boolean;
  mode: HostSignalMode;
  repoRoot: string;
  distro: string;
  dockerHost: string;
  reportPath: string;
  isolationPath: string;
  tracePath: string;
  previousFingerprint: string | null;
  resetFingerprintBaseline: boolean;
  requireRunnerStopped: boolean;
}

interface CommandResult {
  status: number | null;
  stdout: string;
  stderr: string;
  error?: Error;
}

interface CommandRunner {
  (filePath: string, args: string[], options?: { cwd?: string; env?: Record<string, string | undefined> }): CommandResult;
}

interface WindowsDockerSignal {
  available: boolean;
  context: string | null;
  osType: string | null;
  operatingSystem: string | null;
  serverName: string | null;
  platformName: string | null;
  serverVersion: string | null;
  labels: string[];
  error: string | null;
}

interface WslDockerSignal {
  distro: string;
  dockerHost: string;
  available: boolean;
  socketPath: string;
  socketPresent: boolean;
  socketOwner: string | null;
  socketMode: string | null;
  systemdState: string | null;
  serviceState: string | null;
  context: string | null;
  osType: string | null;
  operatingSystem: string | null;
  serverName: string | null;
  platformName: string | null;
  serverVersion: string | null;
  labels: string[];
  isDockerDesktop: boolean;
  error: string | null;
}

interface RunnerServiceRecord {
  name: string;
  displayName: string | null;
  status: string | null;
  startType: string | null;
}

interface RunnerServicesSignal {
  servicePrefix: string;
  discovered: RunnerServiceRecord[];
  running: string[];
  stopped: string[];
}

interface HostSignalReport {
  schema: typeof DELIVERY_HOST_SIGNAL_SCHEMA;
  generatedAt: string;
  repoRoot: string;
  distro: string;
  dockerHost: string;
  status: HostSignalStatus;
  provider: 'native-wsl' | 'desktop';
  daemonFingerprint: string;
  previousFingerprint: string | null;
  fingerprintChanged: boolean;
  windowsDocker: WindowsDockerSignal;
  wslDocker: WslDockerSignal;
  runnerServices: RunnerServicesSignal;
  reasons: string[];
}

interface HostIsolationCounters {
  runnerPreemptionCount: number;
  runnerRestoreCount: number;
  dockerDriftIncidentCount: number;
  nativeDaemonRepairCount: number;
  cyclesBlockedByHostRuntimeConflict: number;
}

interface HostIsolationState {
  schema: typeof DELIVERY_HOST_ISOLATION_SCHEMA;
  generatedAt: string;
  repoRoot: string;
  distro: string;
  dockerHost: string;
  runnerServicePolicy: 'stop-all-actions-runner-services';
  restoreRunnerServicesOnExit: true;
  preemptedServices: string[];
  restoredServices: string[];
  lastAction: HostSignalMode | 'status';
  lastEvent: {
    type: string;
    at: string;
    detail: string | null;
  } | null;
  lastDrift: {
    at: string;
    previousFingerprint: string | null;
    currentFingerprint: string;
    status: HostSignalStatus;
  } | null;
  daemonFingerprint: string | null;
  lastStatus: HostSignalStatus | null;
  hostSignalPath: string;
  counters: HostIsolationCounters;
}

interface HostSignalRunResult {
  schema: typeof DELIVERY_HOST_SIGNAL_RUN_SCHEMA;
  generatedAt: string;
  mode: HostSignalMode;
  reportPath: string;
  isolationPath: string;
  tracePath: string;
  report: HostSignalReport;
  isolation: HostIsolationState;
  actions: {
    preemptedServices: string[];
    restoredServices: string[];
  };
}

interface RunDeliveryHostSignalOptions {
  mode?: HostSignalMode;
  repoRoot?: string;
  distro?: string;
  dockerHost?: string;
  reportPath?: string;
  isolationPath?: string;
  tracePath?: string;
  previousFingerprint?: string | null;
  requireRunnerStopped?: boolean;
  now?: Date;
  runner?: CommandRunner;
}

function resolvePath(repoRoot: string, filePath: string): string {
  return /^(?:[A-Za-z]:[\\/]|\/|\\\\)/.test(filePath) ? filePath : join(repoRoot, filePath);
}

function toIso(now: Date = new Date()): string {
  return now.toISOString();
}

function normalizeText(value: unknown): string {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function getRecordValue(record: Record<string, unknown>, names: string[]): unknown {
  for (const name of names) {
    if (Object.prototype.hasOwnProperty.call(record, name)) {
      return record[name];
    }
  }
  return undefined;
}

function getRecordText(record: Record<string, unknown>, names: string[]): string | null {
  const value = getRecordValue(record, names);
  const text = normalizeText(value);
  return text || null;
}

function normalizeServiceStatus(value: string | null): string | null {
  const text = normalizeText(value);
  switch (text) {
    case '1':
      return 'Stopped';
    case '2':
      return 'StartPending';
    case '3':
      return 'StopPending';
    case '4':
      return 'Running';
    case '5':
      return 'ContinuePending';
    case '6':
      return 'PausePending';
    case '7':
      return 'Paused';
    default:
      return text || null;
  }
}

function normalizeServiceStartType(value: string | null): string | null {
  const text = normalizeText(value);
  switch (text) {
    case '2':
      return 'Automatic';
    case '3':
      return 'Manual';
    case '4':
      return 'Disabled';
    default:
      return text || null;
  }
}

function normalizeStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((entry) => normalizeText(entry)).filter(Boolean);
}

function parseJson<T>(value: string, fallback: T): T {
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

function defaultRunner(filePath: string, args: string[], options: { cwd?: string; env?: Record<string, string | undefined> } = {}): CommandResult {
  const result = spawnSync(filePath, args, {
    cwd: options.cwd,
    env: options.env,
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
    windowsHide: true,
  } as Parameters<typeof spawnSync>[2] & { maxBuffer: number });
  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error as Error | undefined,
  };
}

function escapePowerShellSingleQuoted(text: string): string {
  return `'${text.replace(/'/g, "''")}'`;
}

function readJsonIfPresent<T>(filePath: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8')) as T;
  } catch {
    return fallback;
  }
}

function writeJsonFile(filePath: string, payload: unknown): string {
  mkdirSync(dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

function appendTraceEvent(filePath: string, payload: unknown): string {
  mkdirSync(dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(payload)}\n`, { encoding: 'utf8', flag: 'a' });
  return filePath;
}

function buildDaemonFingerprint(wslDocker: WslDockerSignal): string {
  const fingerprintSource = {
    dockerHost: wslDocker.dockerHost,
    socketPath: wslDocker.socketPath,
    socketOwner: wslDocker.socketOwner,
    serviceState: wslDocker.serviceState,
    osType: wslDocker.osType,
    operatingSystem: wslDocker.operatingSystem,
    serverName: wslDocker.serverName,
    platformName: wslDocker.platformName,
    serverVersion: wslDocker.serverVersion,
    labels: [...wslDocker.labels].sort(),
  };
  const text = JSON.stringify(fingerprintSource);
  let hash = 2166136261;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

function isDockerDesktopSignal(signal: {
  operatingSystem?: string | null;
  serverName?: string | null;
  platformName?: string | null;
  labels?: string[];
}): boolean {
  const haystack = [
    normalizeText(signal.operatingSystem),
    normalizeText(signal.serverName),
    normalizeText(signal.platformName),
    ...normalizeStringArray(signal.labels),
  ]
    .join(' ')
    .toLowerCase();
  return haystack.includes('docker desktop') || haystack.includes('docker-desktop') || haystack.includes('com.docker.desktop');
}

function classifyHostSignal({
  wslDocker,
  runnerServices,
  previousFingerprint,
  currentFingerprint,
  requireRunnerStopped,
}: {
  wslDocker: WslDockerSignal;
  runnerServices: RunnerServicesSignal;
  previousFingerprint: string | null;
  currentFingerprint: string;
  requireRunnerStopped: boolean;
}): { status: HostSignalStatus; provider: 'native-wsl' | 'desktop'; reasons: string[]; fingerprintChanged: boolean } {
  const reasons: string[] = [];
  const provider = wslDocker.isDockerDesktop ? 'desktop' : 'native-wsl';
  const fingerprintChanged = Boolean(previousFingerprint && previousFingerprint !== currentFingerprint);

  if (provider !== 'native-wsl') {
    reasons.push('WSL Docker server resolves to Docker Desktop instead of a native distro-owned daemon.');
  }
  if (!wslDocker.available) {
    reasons.push('WSL Docker daemon is unavailable on the pinned socket.');
  }
  if (requireRunnerStopped && runnerServices.running.length > 0) {
    reasons.push(`Runner services are still active: ${runnerServices.running.join(', ')}.`);
  }
  if (fingerprintChanged) {
    reasons.push('WSL Docker daemon fingerprint changed since the previous cycle.');
  }

  let status: HostSignalStatus = 'native-wsl';
  if (provider !== 'native-wsl' || !wslDocker.available) {
    status = 'desktop-backed';
  } else if (requireRunnerStopped && runnerServices.running.length > 0) {
    status = 'runner-conflict';
  }
  if (fingerprintChanged) {
    status = 'drifted';
  }

  return {
    status,
    provider,
    reasons,
    fingerprintChanged,
  };
}

function runPowerShellJson<T>(script: string, runner: CommandRunner): T {
  const result = runner('pwsh', ['-NoLogo', '-NoProfile', '-Command', script]);
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || 'PowerShell command failed.');
  }
  return parseJson<T>(result.stdout, [] as T);
}

function collectRunnerServices(runner: CommandRunner): RunnerServicesSignal {
  const script = [
    "$ErrorActionPreference='Stop'",
    "$services = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object Name,DisplayName,Status,StartType)",
    '$services | ConvertTo-Json -Depth 6',
  ].join('; ');
  const discovered = runPowerShellJson<Array<Record<string, unknown>> | Record<string, unknown>>(script, runner);
  const rawRecords = Array.isArray(discovered) ? discovered : discovered ? [discovered] : [];
  const normalized = rawRecords.map((entry) => ({
    name: getRecordText(entry, ['name', 'Name']),
    displayName: getRecordText(entry, ['displayName', 'DisplayName']),
    status: normalizeServiceStatus(getRecordText(entry, ['status', 'Status', 'state', 'State'])),
    startType: normalizeServiceStartType(getRecordText(entry, ['startType', 'StartType', 'startMode', 'StartMode'])),
  }));
  const running = normalized
    .filter((entry) => normalizeText(entry.status).toLowerCase() === 'running')
    .map((entry) => normalizeText(entry.name))
    .filter(Boolean);
  const stopped = normalized
    .filter((entry) => normalizeText(entry.status).toLowerCase() !== 'running')
    .map((entry) => normalizeText(entry.name))
    .filter(Boolean);
  return {
    servicePrefix: DEFAULT_RUNNER_SERVICE_PREFIX,
    discovered: normalized.map((entry) => ({
      name: normalizeText(entry.name),
      displayName: normalizeText(entry.displayName) || null,
      status: normalizeText(entry.status) || null,
      startType: normalizeText(entry.startType) || null,
    })),
    running,
    stopped,
  };
}

function mutateRunnerServices(
  action: 'stop' | 'start',
  serviceNames: string[],
  runner: CommandRunner,
): string[] {
  if (serviceNames.length === 0) {
    return [];
  }
  const namesLiteral = `@(${serviceNames.map((entry) => escapePowerShellSingleQuoted(entry)).join(',')})`;
  const verb = action === 'stop' ? 'Stop-Service' : 'Start-Service';
  const script = [
    "$ErrorActionPreference='Stop'",
    `$names = ${namesLiteral}`,
    '$results = @()',
    'foreach ($name in $names) {',
    '  try {',
    `    ${verb} -Name $name -ErrorAction Stop`,
    "    $results += [pscustomobject]@{ name = $name; status = 'ok' }",
    '  } catch {',
    "    $results += [pscustomobject]@{ name = $name; status = 'failed'; error = $_.Exception.Message }",
    '  }',
    '}',
    '$results | ConvertTo-Json -Depth 6',
  ].join('; ');
  const result = runPowerShellJson<Array<{ name?: string; status?: string }>>(script, runner);
  const normalized = Array.isArray(result) ? result : result ? [result] : [];
  return normalized
    .filter((entry) => normalizeText(entry.status).toLowerCase() === 'ok')
    .map((entry) => normalizeText(entry.name))
    .filter(Boolean);
}

function collectWindowsDocker(runner: CommandRunner): WindowsDockerSignal {
  const contextResult = runner('docker', ['context', 'show']);
  const infoResult = runner('docker', ['info', '--format', '{{json .}}']);
  const info = infoResult.status === 0 ? parseJson<Record<string, unknown>>(infoResult.stdout, {}) : {};
  const clientInfo = (info.ClientInfo ?? {}) as Record<string, unknown>;
  const labels = normalizeStringArray(info.Labels);
  return {
    available: infoResult.status === 0,
    context: contextResult.status === 0 ? normalizeText(contextResult.stdout) || null : null,
    osType: normalizeText(info.OSType) || null,
    operatingSystem: normalizeText(info.OperatingSystem) || null,
    serverName: normalizeText(info.Name) || null,
    platformName: normalizeText((info.Platform as Record<string, unknown> | undefined)?.Name) || null,
    serverVersion: normalizeText(info.ServerVersion) || normalizeText(clientInfo.Version) || null,
    labels,
    error: infoResult.status === 0 ? null : normalizeText(infoResult.stderr || infoResult.stdout) || 'docker info failed',
  };
}

function collectWslDocker(distro: string, dockerHost: string, runner: CommandRunner): WslDockerSignal {
  const tempScriptPath = join(tmpdir(), `comparevi-delivery-host-signal-${Date.now()}.sh`);
  const bashScript = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    `export DOCKER_HOST=${JSON.stringify(dockerHost)}`,
    "systemd_state=\"$(systemctl is-system-running 2>/dev/null || true)\"",
    "service_state=\"$(systemctl is-active docker 2>/dev/null || true)\"",
    "context_value=\"$(docker context show 2>/dev/null || true)\"",
    "info_b64=\"$(docker info --format '{{json .}}' 2>/dev/null | base64 -w0 || true)\"",
    "socket_present='false'",
    "socket_owner=''",
    "socket_mode=''",
    'if [ -S /var/run/docker.sock ]; then',
    "  socket_present='true'",
    "  socket_owner=\"$(stat -c '%U:%G' /var/run/docker.sock 2>/dev/null || true)\"",
    "  socket_mode=\"$(stat -c '%a' /var/run/docker.sock 2>/dev/null || true)\"",
    'fi',
    "printf '%s\\n' \"$systemd_state\"",
    "printf '%s\\n' \"$service_state\"",
    "printf '%s\\n' \"$context_value\"",
    "printf '%s\\n' \"$socket_present\"",
    "printf '%s\\n' \"$socket_owner\"",
    "printf '%s\\n' \"$socket_mode\"",
    "printf '%s\\n' \"$info_b64\"",
  ].join('\n');
  writeFileSync(tempScriptPath, `${bashScript}\n`, 'utf8');
  const tempScriptPathWsl = tempScriptPath.replace(/\\/g, '/').replace(/^([A-Za-z]):/, (_, drive: string) => `/mnt/${drive.toLowerCase()}`);
  const result = runner('wsl.exe', ['-d', distro, '--', 'bash', tempScriptPathWsl]);
  try {
    if (existsSync(tempScriptPath)) {
      unlinkSync(tempScriptPath);
    }
  } catch {
    // ignore cleanup failures
  }
  const lines = (result.stdout || '').split(/\r?\n/);
  const [systemdState, serviceState, context, socketPresentRaw, socketOwner, socketMode, infoB64] = lines;
  const infoText = infoB64 ? atob(infoB64) : '';
  const info = infoText ? parseJson<Record<string, unknown>>(infoText, {}) : {};
  const labels = normalizeStringArray(info.Labels);
  const serverVersion = normalizeText(info.ServerVersion) || null;
  const osType = normalizeText(info.OSType) || null;
  const operatingSystem = normalizeText(info.OperatingSystem) || null;
  const serverName = normalizeText(info.Name) || null;
  const platformName = normalizeText((info.Platform as Record<string, unknown> | undefined)?.Name) || null;
  const hasServerIdentity = Boolean(serverVersion || osType || operatingSystem || serverName);
  const signal: WslDockerSignal = {
    distro,
    dockerHost,
    available: result.status === 0 && hasServerIdentity,
    socketPath: '/var/run/docker.sock',
    socketPresent: normalizeText(socketPresentRaw).toLowerCase() === 'true',
    socketOwner: normalizeText(socketOwner) || null,
    socketMode: normalizeText(socketMode) || null,
    systemdState: normalizeText(systemdState) || null,
    serviceState: normalizeText(serviceState) || null,
    context: normalizeText(context) || null,
    osType,
    operatingSystem,
    serverName,
    platformName,
    serverVersion,
    labels,
    isDockerDesktop: false,
    error:
      result.status === 0
        ? (hasServerIdentity ? null : 'WSL docker client returned no server identity on the pinned socket.')
        : normalizeText(result.stderr || result.stdout) || 'WSL docker info failed',
  };
  signal.isDockerDesktop = isDockerDesktopSignal(signal);
  return signal;
}

function collectHostSignal(
  options: {
    repoRoot: string;
    distro: string;
    dockerHost: string;
    previousFingerprint: string | null;
    requireRunnerStopped: boolean;
    now: Date;
  },
  runner: CommandRunner,
): HostSignalReport {
  const windowsDocker = collectWindowsDocker(runner);
  const wslDocker = collectWslDocker(options.distro, options.dockerHost, runner);
  const runnerServices = collectRunnerServices(runner);
  const daemonFingerprint = buildDaemonFingerprint(wslDocker);
  const classification = classifyHostSignal({
    wslDocker,
    runnerServices,
    previousFingerprint: options.previousFingerprint,
    currentFingerprint: daemonFingerprint,
    requireRunnerStopped: options.requireRunnerStopped,
  });

  return {
    schema: DELIVERY_HOST_SIGNAL_SCHEMA,
    generatedAt: toIso(options.now),
    repoRoot: options.repoRoot,
    distro: options.distro,
    dockerHost: options.dockerHost,
    status: classification.status,
    provider: classification.provider,
    daemonFingerprint,
    previousFingerprint: options.previousFingerprint,
    fingerprintChanged: classification.fingerprintChanged,
    windowsDocker,
    wslDocker,
    runnerServices,
    reasons: classification.reasons,
  };
}

function createDefaultIsolationState({
  repoRoot,
  distro,
  dockerHost,
  reportPath,
  now,
}: {
  repoRoot: string;
  distro: string;
  dockerHost: string;
  reportPath: string;
  now: Date;
}): HostIsolationState {
  return {
    schema: DELIVERY_HOST_ISOLATION_SCHEMA,
    generatedAt: toIso(now),
    repoRoot,
    distro,
    dockerHost,
    runnerServicePolicy: 'stop-all-actions-runner-services',
    restoreRunnerServicesOnExit: true,
    preemptedServices: [],
    restoredServices: [],
    lastAction: 'collect',
    lastEvent: null,
    lastDrift: null,
    daemonFingerprint: null,
    lastStatus: null,
    hostSignalPath: reportPath,
    counters: {
      runnerPreemptionCount: 0,
      runnerRestoreCount: 0,
      dockerDriftIncidentCount: 0,
      nativeDaemonRepairCount: 0,
      cyclesBlockedByHostRuntimeConflict: 0,
    },
  };
}

function normalizeIsolationState(
  existing: Partial<HostIsolationState> | null,
  defaults: HostIsolationState,
): HostIsolationState {
  return {
    ...defaults,
    ...(existing ?? {}),
    counters: {
      ...defaults.counters,
      ...(existing?.counters ?? {}),
    },
    preemptedServices: normalizeStringArray(existing?.preemptedServices),
    restoredServices: normalizeStringArray(existing?.restoredServices),
  };
}

export function parseArgs(argv: string[] = process.argv): CliOptions {
  const options: CliOptions = {
    help: false,
    mode: 'collect',
    repoRoot: process.cwd(),
    distro: DEFAULT_WSL_DISTRO,
    dockerHost: DEFAULT_DOCKER_HOST,
    reportPath: DEFAULT_REPORT_PATH,
    isolationPath: DEFAULT_ISOLATION_PATH,
    tracePath: DEFAULT_TRACE_PATH,
    previousFingerprint: null,
    resetFingerprintBaseline: false,
    requireRunnerStopped: true,
  };
  const args = argv.slice(2);
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--require-runner-stopped') {
      options.requireRunnerStopped = true;
      continue;
    }
    if (token === '--reset-fingerprint-baseline') {
      options.resetFingerprintBaseline = true;
      options.previousFingerprint = '';
      continue;
    }
    if (token === '--allow-runner-services') {
      options.requireRunnerStopped = false;
      continue;
    }
    if (
      token === '--mode' ||
      token === '--repo-root' ||
      token === '--distro' ||
      token === '--docker-host' ||
      token === '--report' ||
      token === '--isolation' ||
      token === '--trace' ||
      token === '--previous-fingerprint'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--mode') {
        if (next !== 'collect' && next !== 'isolate' && next !== 'restore') {
          throw new Error(`Unsupported mode: ${next}.`);
        }
        options.mode = next;
      } else if (token === '--repo-root') {
        options.repoRoot = next;
      } else if (token === '--distro') {
        options.distro = next;
      } else if (token === '--docker-host') {
        options.dockerHost = next;
      } else if (token === '--report') {
        options.reportPath = next;
      } else if (token === '--isolation') {
        options.isolationPath = next;
      } else if (token === '--trace') {
        options.tracePath = next;
      } else if (token === '--previous-fingerprint') {
        options.previousFingerprint = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }
  return options;
}

function printUsage(): void {
  console.log('Usage: node dist/tools/priority/delivery-host-signal.js [options]');
  console.log('');
  console.log('Options:');
  console.log('  --mode <collect|isolate|restore>   Action to run (default: collect).');
  console.log(`  --repo-root <path>                 Repository root (default: ${process.cwd()}).`);
  console.log(`  --distro <name>                    WSL distro (default: ${DEFAULT_WSL_DISTRO}).`);
  console.log(`  --docker-host <uri>                Pinned Docker host (default: ${DEFAULT_DOCKER_HOST}).`);
  console.log(`  --report <path>                    Host signal report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(`  --isolation <path>                 Host isolation state path (default: ${DEFAULT_ISOLATION_PATH}).`);
  console.log(`  --trace <path>                     Deterministic host trace path (default: ${DEFAULT_TRACE_PATH}).`);
  console.log('  --previous-fingerprint <sha256>    Previous daemon fingerprint for drift detection.');
  console.log('  --reset-fingerprint-baseline       Ignore any persisted previous fingerprint and establish a new baseline.');
  console.log('  --allow-runner-services            Do not classify active runner services as a conflict.');
  console.log('  -h, --help                         Show help.');
}

export function runDeliveryHostSignal(options: RunDeliveryHostSignalOptions = {}): HostSignalRunResult {
  const runner = options.runner ?? defaultRunner;
  const now = options.now ?? new Date();
  const repoRoot = resolve(options.repoRoot ?? process.cwd());
  const reportPath = resolvePath(repoRoot, options.reportPath ?? DEFAULT_REPORT_PATH);
  const isolationPath = resolvePath(repoRoot, options.isolationPath ?? DEFAULT_ISOLATION_PATH);
  const tracePath = resolvePath(repoRoot, options.tracePath ?? DEFAULT_TRACE_PATH);
  const distro = normalizeText(options.distro) || DEFAULT_WSL_DISTRO;
  const dockerHost = normalizeText(options.dockerHost) || DEFAULT_DOCKER_HOST;
  const mode = options.mode ?? 'collect';

  const defaults = createDefaultIsolationState({
    repoRoot,
    distro,
    dockerHost,
    reportPath,
    now,
  });
  const existingIsolation = existsSync(isolationPath)
    ? readJsonIfPresent<Partial<HostIsolationState> | null>(isolationPath, null)
    : null;
  const isolation = normalizeIsolationState(existingIsolation, defaults);
  const previousFingerprint = options.previousFingerprint ?? isolation.daemonFingerprint ?? null;

  let preemptedServices: string[] = [];
  let restoredServices: string[] = [];
  if (mode === 'isolate') {
    const services = collectRunnerServices(runner);
    preemptedServices = mutateRunnerServices('stop', services.running, runner);
    if (preemptedServices.length > 0) {
      isolation.preemptedServices = [...new Set([...isolation.preemptedServices, ...preemptedServices])];
      isolation.counters.runnerPreemptionCount += preemptedServices.length;
      isolation.lastEvent = {
        type: 'runner-services-preempted',
        at: toIso(now),
        detail: preemptedServices.join(', '),
      };
    }
  } else if (mode === 'restore') {
    restoredServices = mutateRunnerServices('start', isolation.preemptedServices, runner);
    if (restoredServices.length > 0) {
      isolation.restoredServices = [...new Set([...isolation.restoredServices, ...restoredServices])];
      isolation.preemptedServices = isolation.preemptedServices.filter((entry) => !restoredServices.includes(entry));
      isolation.counters.runnerRestoreCount += restoredServices.length;
      isolation.lastEvent = {
        type: 'runner-services-restored',
        at: toIso(now),
        detail: restoredServices.join(', '),
      };
    }
  }

  const report = collectHostSignal(
    {
      repoRoot,
      distro,
      dockerHost,
      previousFingerprint,
      requireRunnerStopped: options.requireRunnerStopped ?? true,
      now,
    },
    runner,
  );

  isolation.generatedAt = toIso(now);
  isolation.lastAction = mode;
  isolation.hostSignalPath = reportPath;
  isolation.daemonFingerprint = report.daemonFingerprint;
  isolation.lastStatus = report.status;
  if (report.fingerprintChanged) {
    isolation.counters.dockerDriftIncidentCount += 1;
    isolation.lastDrift = {
      at: toIso(now),
      previousFingerprint,
      currentFingerprint: report.daemonFingerprint,
      status: report.status,
    };
    isolation.lastEvent = {
      type: 'docker-daemon-drifted',
      at: toIso(now),
      detail: `${previousFingerprint ?? '<none>'} -> ${report.daemonFingerprint}`,
    };
  }

  writeJsonFile(reportPath, report);
  writeJsonFile(isolationPath, isolation);
  appendTraceEvent(tracePath, {
    schema: 'priority/delivery-agent-host-trace@v1',
    generatedAt: toIso(now),
    mode,
    repoRoot,
    distro,
    dockerHost,
    status: report.status,
    provider: report.provider,
    daemonFingerprint: report.daemonFingerprint,
    previousFingerprint,
    reasons: report.reasons,
    preemptedServices,
    restoredServices,
    trackedPreemptedServices: isolation.preemptedServices,
    lastEvent: isolation.lastEvent,
  });

  return {
    schema: DELIVERY_HOST_SIGNAL_RUN_SCHEMA,
    generatedAt: toIso(now),
    mode,
    reportPath,
    isolationPath,
    tracePath,
    report,
    isolation,
    actions: {
      preemptedServices,
      restoredServices,
    },
  };
}

export async function main(argv: string[] = process.argv): Promise<number> {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const result = runDeliveryHostSignal(options);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  return 0;
}

const invokedHref = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : null;
if (invokedHref && invokedHref === import.meta.url) {
  main(process.argv).then(
    (exitCode) => process.exit(exitCode),
    (error: unknown) => {
      process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
      process.exit(1);
    },
  );
}

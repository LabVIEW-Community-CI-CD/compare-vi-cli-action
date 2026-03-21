#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { resolveGitAdminPaths } from './lib/git-admin-paths.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
const DEFAULT_SCOPE = 'workspace';
const DEFAULT_STALE_SECONDS = 900;
const DEFAULT_WAIT_MS = 250;
const DEFAULT_MAX_ATTEMPTS = 0;
const DEFAULT_RENAME_RETRY_ATTEMPTS = 5;
const DEFAULT_RENAME_RETRY_WAIT_MS = 50;

const STATUS = Object.freeze({
  acquired: 'acquired',
  renewed: 'renewed',
  takeover: 'takeover',
  busy: 'busy',
  stale: 'stale',
  released: 'released',
  notFound: 'not-found',
  mismatch: 'mismatch',
  active: 'active'
});

function envInt(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function envBool(name, fallback = false) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  return raw === '1' || raw.toLowerCase() === 'true';
}

function resolveDefaultGitCommonDir(options = {}) {
  try {
    return resolveGitAdminPaths({
      cwd: options.repoRoot || REPO_ROOT,
      env: options.env || process.env,
      spawnSyncFn: options.spawnSyncFn || spawnSync
    }).gitCommonDir;
  } catch {
    return path.join(options.repoRoot || REPO_ROOT, '.git');
  }
}

export function defaultLeaseRoot(options = {}) {
  return process.env.AGENT_WRITER_LEASE_ROOT || path.join(resolveDefaultGitCommonDir(options), 'agent-writer-leases');
}

export function defaultOwner() {
  const explicitOwner = typeof process.env.AGENT_WRITER_LEASE_OWNER === 'string'
    ? process.env.AGENT_WRITER_LEASE_OWNER.trim()
    : '';
  if (explicitOwner) {
    return explicitOwner;
  }
  const actor =
    process.env.AGENT_WRITER_LEASE_ACTOR ||
    process.env.GITHUB_ACTOR ||
    process.env.USERNAME ||
    process.env.USER ||
    'unknown';
  const session = process.env.AGENT_SESSION_NAME || process.env.PS_SESSION_NAME || 'default';
  return `${actor}@${os.hostname()}:${session}`;
}

export function leasePathForScope(scope, leaseRoot = defaultLeaseRoot()) {
  return path.join(leaseRoot, `${scope}.json`);
}

function nowIso() {
  return new Date().toISOString();
}

function leaseAgeSeconds(lease, nowMs = Date.now()) {
  const heartbeat = lease?.heartbeatAt || lease?.acquiredAt;
  if (!heartbeat) return Number.POSITIVE_INFINITY;
  const parsed = Date.parse(heartbeat);
  if (!Number.isFinite(parsed)) return Number.POSITIVE_INFINITY;
  return Math.max(0, (nowMs - parsed) / 1000);
}

async function ensureParentDir(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
}

async function readLease(filePath) {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    if (!raw.trim()) return null;
    return JSON.parse(raw);
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

function isRetryableLeaseReplaceError(error) {
  return ['EPERM', 'EACCES', 'EBUSY', 'EEXIST'].includes(error?.code);
}

async function replaceFileWithRetry(tempPath, filePath, {
  retryAttempts = DEFAULT_RENAME_RETRY_ATTEMPTS,
  retryWaitMs = DEFAULT_RENAME_RETRY_WAIT_MS,
  fsModule = fs
} = {}) {
  let attempt = 0;
  while (true) {
    try {
      await fsModule.rename(tempPath, filePath);
      return;
    } catch (error) {
      if (!isRetryableLeaseReplaceError(error)) {
        throw error;
      }
      if (attempt >= retryAttempts) {
        throw error;
      }
      await fsModule.rm(filePath, { force: true });
      attempt += 1;
      if (retryWaitMs > 0) {
        await sleep(retryWaitMs);
      }
    }
  }
}

async function writeJsonAtomic(filePath, payload, { createOnly = false } = {}) {
  await ensureParentDir(filePath);
  const body = `${JSON.stringify(payload, null, 2)}\n`;
  if (createOnly) {
    await fs.writeFile(filePath, body, { encoding: 'utf8', flag: 'wx' });
    return;
  }
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  await fs.writeFile(tempPath, body, { encoding: 'utf8' });
  try {
    await replaceFileWithRetry(tempPath, filePath);
  } finally {
    await fs.rm(tempPath, { force: true });
  }
}

function buildBaseResult(action, scope, leasePath, owner) {
  return {
    schema: 'agent/writer-lease-result@v1',
    action,
    scope,
    leasePath,
    owner,
    checkedAt: nowIso()
  };
}

function createLeaseRecord({ scope, owner, leaseId, takeoverFrom = null, takeoverReason = null }) {
  const timestamp = nowIso();
  const record = {
    schema: 'agent/writer-lease@v1',
    scope,
    leaseId,
    owner,
    acquiredAt: timestamp,
    heartbeatAt: timestamp
  };
  if (takeoverFrom) {
    record.takeover = {
      fromOwner: takeoverFrom,
      reason: takeoverReason || 'stale-lease'
    };
  }
  return record;
}

function normalizeAcquireOptions(options = {}) {
  return {
    scope: options.scope || DEFAULT_SCOPE,
    owner: options.owner || defaultOwner(),
    leaseRoot: options.leaseRoot || defaultLeaseRoot(),
    staleSeconds: Number.isFinite(options.staleSeconds)
      ? options.staleSeconds
      : envInt('AGENT_WRITER_LEASE_STALE_SECONDS', DEFAULT_STALE_SECONDS),
    waitMs: Number.isFinite(options.waitMs) ? options.waitMs : envInt('AGENT_WRITER_LEASE_WAIT_MS', DEFAULT_WAIT_MS),
    maxAttempts: Number.isFinite(options.maxAttempts)
      ? options.maxAttempts
      : envInt('AGENT_WRITER_LEASE_MAX_ATTEMPTS', DEFAULT_MAX_ATTEMPTS),
    forceTakeover: options.forceTakeover ?? envBool('AGENT_WRITER_LEASE_FORCE_TAKEOVER', false)
  };
}

function normalizeReleaseOptions(options = {}) {
  return {
    scope: options.scope || DEFAULT_SCOPE,
    owner: options.owner || defaultOwner(),
    leaseRoot: options.leaseRoot || defaultLeaseRoot(),
    leaseId: options.leaseId || process.env.AGENT_WRITER_LEASE_ID || ''
  };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
}

export async function inspectWriterLease(options = {}) {
  const { scope, owner, leaseRoot, staleSeconds } = normalizeAcquireOptions(options);
  const leasePath = leasePathForScope(scope, leaseRoot);
  const base = buildBaseResult('inspect', scope, leasePath, owner);
  const lease = await readLease(leasePath);
  if (!lease) {
    return { ...base, status: STATUS.notFound, lease: null };
  }
  const ageSeconds = leaseAgeSeconds(lease);
  return {
    ...base,
    status: STATUS.active,
    ageSeconds,
    stale: ageSeconds > staleSeconds,
    lease
  };
}

export async function acquireWriterLease(options = {}) {
  const normalized = normalizeAcquireOptions(options);
  const { scope, owner, leaseRoot, staleSeconds, waitMs, maxAttempts, forceTakeover } = normalized;
  const leasePath = leasePathForScope(scope, leaseRoot);
  const base = buildBaseResult('acquire', scope, leasePath, owner);

  let attempt = 0;
  while (true) {
    const leaseId = options.leaseId || `${Date.now()}-${process.pid}-${Math.random().toString(16).slice(2, 10)}`;
    const freshLease = createLeaseRecord({ scope, owner, leaseId });
    try {
      await writeJsonAtomic(leasePath, freshLease, { createOnly: true });
      return { ...base, status: STATUS.acquired, attempt, lease: freshLease };
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
    }

    const current = await readLease(leasePath);
    if (!current) {
      if (attempt >= maxAttempts) {
        return { ...base, status: STATUS.busy, attempt, reason: 'lease-file-race', lease: null };
      }
      attempt += 1;
      await sleep(waitMs);
      continue;
    }

    const ageSeconds = leaseAgeSeconds(current);
    const isStale = ageSeconds > staleSeconds;

    if (current.owner === owner) {
      const renewed = {
        ...current,
        heartbeatAt: nowIso()
      };
      await writeJsonAtomic(leasePath, renewed);
      return { ...base, status: STATUS.renewed, attempt, ageSeconds, lease: renewed };
    }

    if (isStale) {
      if (!forceTakeover) {
        return {
          ...base,
          status: STATUS.stale,
          attempt,
          ageSeconds,
          staleSeconds,
          holder: current.owner,
          lease: current
        };
      }
      const takeover = createLeaseRecord({
        scope,
        owner,
        leaseId,
        takeoverFrom: current.owner,
        takeoverReason: `stale>${staleSeconds}s`
      });
      await writeJsonAtomic(leasePath, takeover);
      return {
        ...base,
        status: STATUS.takeover,
        attempt,
        ageSeconds,
        staleSeconds,
        previousLease: current,
        lease: takeover
      };
    }

    if (attempt >= maxAttempts) {
      return {
        ...base,
        status: STATUS.busy,
        attempt,
        ageSeconds,
        staleSeconds,
        holder: current.owner,
        lease: current
      };
    }

    attempt += 1;
    await sleep(waitMs);
  }
}

export async function releaseWriterLease(options = {}) {
  const { scope, owner, leaseRoot, leaseId } = normalizeReleaseOptions(options);
  const leasePath = leasePathForScope(scope, leaseRoot);
  const base = buildBaseResult('release', scope, leasePath, owner);
  const current = await readLease(leasePath);
  if (!current) {
    return { ...base, status: STATUS.notFound, lease: null };
  }

  const ownerMatches = current.owner === owner;
  const leaseIdMatches = leaseId && current.leaseId === leaseId;
  if (!ownerMatches && !leaseIdMatches) {
    return {
      ...base,
      status: STATUS.mismatch,
      lease: current,
      reason: 'owner-or-lease-id-mismatch'
    };
  }

  await fs.rm(leasePath, { force: true });
  return { ...base, status: STATUS.released, lease: current };
}

export async function heartbeatWriterLease(options = {}) {
  const { scope, owner, leaseRoot, leaseId } = normalizeReleaseOptions(options);
  const leasePath = leasePathForScope(scope, leaseRoot);
  const base = buildBaseResult('heartbeat', scope, leasePath, owner);
  const current = await readLease(leasePath);
  if (!current) {
    return { ...base, status: STATUS.notFound, lease: null };
  }

  const ownerMatches = current.owner === owner;
  const leaseIdMatches = leaseId && current.leaseId === leaseId;
  if (!ownerMatches && !leaseIdMatches) {
    return {
      ...base,
      status: STATUS.mismatch,
      lease: current,
      reason: 'owner-or-lease-id-mismatch'
    };
  }

  const next = { ...current, heartbeatAt: nowIso() };
  await writeJsonAtomic(leasePath, next);
  return { ...base, status: STATUS.renewed, lease: next };
}

async function maybeWriteReport(reportPath, payload) {
  if (!reportPath) return;
  await ensureParentDir(reportPath);
  await fs.writeFile(reportPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

export function parseArgs(argv = process.argv.slice(2)) {
  const parsed = {
    action: '',
    scope: DEFAULT_SCOPE,
    owner: '',
    leaseRoot: '',
    leaseId: '',
    staleSeconds: undefined,
    waitMs: undefined,
    maxAttempts: undefined,
    forceTakeover: false,
    report: '',
    quiet: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    switch (token) {
      case '--action':
        parsed.action = argv[++index] || '';
        break;
      case '--scope':
        parsed.scope = argv[++index] || DEFAULT_SCOPE;
        break;
      case '--owner':
        parsed.owner = argv[++index] || '';
        break;
      case '--lease-root':
        parsed.leaseRoot = argv[++index] || '';
        break;
      case '--lease-id':
        parsed.leaseId = argv[++index] || '';
        break;
      case '--stale-seconds':
        parsed.staleSeconds = Number.parseInt(argv[++index] || '', 10);
        break;
      case '--wait-ms':
        parsed.waitMs = Number.parseInt(argv[++index] || '', 10);
        break;
      case '--max-attempts':
        parsed.maxAttempts = Number.parseInt(argv[++index] || '', 10);
        break;
      case '--force-takeover':
        parsed.forceTakeover = true;
        break;
      case '--report':
        parsed.report = argv[++index] || '';
        break;
      case '--quiet':
        parsed.quiet = true;
        break;
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${token}`);
    }
  }
  return parsed;
}

function printUsage() {
  console.log(`Usage:
  node tools/priority/agent-writer-lease.mjs --action <acquire|release|heartbeat|inspect> [options]

Options:
  --scope <name>            Lease scope (default: workspace)
  --owner <value>           Lease owner identity
  --lease-root <path>       Lease root directory (default: .git/agent-writer-leases)
  --lease-id <id>           Optional lease id matcher for release/heartbeat
  --stale-seconds <n>       Stale threshold for acquire/inspect
  --wait-ms <n>             Wait interval between retries (acquire)
  --max-attempts <n>        Retry attempts before reporting busy (acquire)
  --force-takeover          Allow stale lease takeover (acquire)
  --report <path>           Write deterministic report JSON
  --quiet                   Suppress stdout JSON output
`);
}

function exitCodeForResult(result) {
  if (!result) return 1;
  switch (result.action) {
    case 'acquire':
      if ([STATUS.acquired, STATUS.renewed, STATUS.takeover].includes(result.status)) return 0;
      if (result.status === STATUS.busy) return 10;
      if (result.status === STATUS.stale) return 11;
      return 1;
    case 'release':
      if ([STATUS.released, STATUS.notFound].includes(result.status)) return 0;
      if (result.status === STATUS.mismatch) return 12;
      return 1;
    case 'heartbeat':
      if (result.status === STATUS.renewed) return 0;
      if (result.status === STATUS.notFound) return 13;
      if (result.status === STATUS.mismatch) return 12;
      return 1;
    case 'inspect':
      return result.status === STATUS.active ? 0 : 1;
    default:
      return 1;
  }
}

export async function runCli(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help || !options.action) {
    printUsage();
    return 0;
  }

  let result;
  if (options.action === 'acquire') {
    result = await acquireWriterLease(options);
  } else if (options.action === 'release') {
    result = await releaseWriterLease(options);
  } else if (options.action === 'heartbeat') {
    result = await heartbeatWriterLease(options);
  } else if (options.action === 'inspect') {
    result = await inspectWriterLease(options);
  } else {
    throw new Error(`Unsupported action '${options.action}'.`);
  }

  if (options.report) {
    await maybeWriteReport(options.report, result);
  }
  if (!options.quiet) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  }
  return exitCodeForResult(result);
}

export const __test = {
  leaseAgeSeconds,
  parseArgs,
  isRetryableLeaseReplaceError,
  replaceFileWithRetry
};

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const code = await runCli();
    process.exit(code);
  } catch (error) {
    const failure = {
      schema: 'agent/writer-lease-result@v1',
      action: 'error',
      status: 'error',
      message: error?.message || String(error)
    };
    process.stderr.write(`${JSON.stringify(failure, null, 2)}\n`);
    process.exit(1);
  }
}

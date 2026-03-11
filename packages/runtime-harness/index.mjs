#!/usr/bin/env node

import { existsSync } from 'node:fs';
import { appendFile, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

export const STATE_SCHEMA = 'priority/runtime-supervisor-state@v1';
export const REPORT_SCHEMA = 'priority/runtime-supervisor-report@v1';
export const EVENT_SCHEMA = 'priority/runtime-event@v1';
export const TURN_SCHEMA = 'priority/runtime-turn@v1';
export const LANE_SCHEMA = 'priority/runtime-lane@v1';
export const STOP_REQUEST_SCHEMA = 'priority/runtime-stop-request@v1';
export const BLOCKER_SCHEMA = 'priority/runtime-blocker@v1';
export const SCHEDULER_DECISION_SCHEMA = 'priority/runtime-scheduler-decision@v1';
export const WORKER_CHECKOUT_SCHEMA = 'priority/runtime-worker-checkout@v1';
export const WORKER_READY_SCHEMA = 'priority/runtime-worker-ready@v1';
export const WORKER_BRANCH_SCHEMA = 'priority/runtime-worker-branch@v1';
export const TASK_PACKET_SCHEMA = 'priority/runtime-worker-task-packet@v1';
export const EXECUTION_RECEIPT_SCHEMA = 'priority/runtime-execution-receipt@v1';
export const DEFAULT_RUNTIME_DIR = path.join('tests', 'results', '_agent', 'runtime');
export const DEFAULT_LEASE_SCOPE = 'workspace';
export const ACTIONS = new Set(['status', 'step', 'stop', 'resume']);
export const BLOCKER_CLASSES = new Set(['none', 'merge', 'review', 'ci', 'scope', 'helper', 'auth']);

function printUsage() {
  console.log('Usage: node runtime-harness --action <status|step|stop|resume> [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>         Repository slug to record in state.');
  console.log(`  --runtime-dir <path>        Runtime artifact root (default: ${DEFAULT_RUNTIME_DIR}).`);
  console.log('  --state-path <path>         Override runtime-state.json path.');
  console.log('  --events-path <path>        Override runtime-events.ndjson path.');
  console.log('  --lanes-dir <path>          Override lane artifact directory.');
  console.log('  --turns-dir <path>          Override turn artifact directory.');
  console.log('  --stop-request-path <path>  Override stop-request.json path.');
  console.log('  --last-blocker-path <path>  Override last-blocker.json path.');
  console.log('  --lane <id>                 Lane identifier for step actions.');
  console.log('  --issue <number>            Upstream child issue number for the active lane.');
  console.log('  --epic <number>             Parent epic issue number for the active lane.');
  console.log('  --fork-remote <name>        Lane fork remote (origin|personal|upstream).');
  console.log('  --branch <name>             Lane branch name.');
  console.log('  --pr-url <url>              Active pull request URL for the lane.');
  console.log('  --blocker-class <name>      Blocker class (none|merge|review|ci|scope|helper|auth).');
  console.log('  --reason <text>             Stop reason or blocker note.');
  console.log(`  --lease-scope <name>        Lease scope for step actions (default: ${DEFAULT_LEASE_SCOPE}).`);
  console.log('  --lease-root <path>         Optional lease root override.');
  console.log('  --owner <value>             Runtime owner identity.');
  console.log('  --quiet                     Suppress stdout JSON output.');
  console.log('  -h, --help                  Show this help text and exit.');
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function toPositiveInteger(value, { label }) {
  if (value == null) return null;
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) {
    throw new Error(`Invalid ${label} value '${value}'.`);
  }
  return number;
}

function resolvePath(repoRoot, value) {
  return path.isAbsolute(value) ? value : path.join(repoRoot, value);
}

function toIso(now = new Date()) {
  return now.toISOString();
}

function sanitizeSegment(value) {
  return String(value || '')
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'runtime';
}

function makeTurnFileName(now, cycle) {
  const stamp = toIso(now).replace(/[:.]/g, '-');
  const normalizedCycle = String(cycle).padStart(4, '0');
  return `${stamp}-${normalizedCycle}.json`;
}

function summarizeLease(result) {
  if (!result) return null;
  return {
    action: result.action ?? null,
    status: result.status ?? null,
    scope: result.scope ?? null,
    owner: result.owner ?? null,
    leaseId: result.lease?.leaseId ?? result.leaseId ?? null,
    checkedAt: result.checkedAt ?? null
  };
}

async function ensureDir(dirPath) {
  await mkdir(dirPath, { recursive: true });
  return dirPath;
}

async function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

async function readJson(filePath) {
  try {
    const raw = await readFile(path.resolve(filePath), 'utf8');
    return JSON.parse(raw);
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

async function appendNdjson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await appendFile(resolved, `${JSON.stringify(payload)}\n`, 'utf8');
  return resolved;
}

async function countJsonFiles(dirPath) {
  try {
    const entries = await readdir(dirPath, { withFileTypes: true });
    return entries.filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.json')).length;
  } catch (error) {
    if (error?.code === 'ENOENT') return 0;
    throw error;
  }
}

function resolveRuntimePaths(repoRoot, options) {
  const runtimeDir = resolvePath(repoRoot, options.runtimeDir || DEFAULT_RUNTIME_DIR);
  return {
    runtimeDir,
    statePath: options.statePath ? resolvePath(repoRoot, options.statePath) : path.join(runtimeDir, 'runtime-state.json'),
    eventsPath: options.eventsPath ? resolvePath(repoRoot, options.eventsPath) : path.join(runtimeDir, 'runtime-events.ndjson'),
    lanesDir: options.lanesDir ? resolvePath(repoRoot, options.lanesDir) : path.join(runtimeDir, 'lanes'),
    turnsDir: options.turnsDir ? resolvePath(repoRoot, options.turnsDir) : path.join(runtimeDir, 'turns'),
    stopRequestPath: options.stopRequestPath
      ? resolvePath(repoRoot, options.stopRequestPath)
      : path.join(runtimeDir, 'stop-request.json'),
    lastBlockerPath: options.lastBlockerPath
      ? resolvePath(repoRoot, options.lastBlockerPath)
      : path.join(runtimeDir, 'last-blocker.json')
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    action: '',
    repo: '',
    runtimeDir: DEFAULT_RUNTIME_DIR,
    statePath: '',
    eventsPath: '',
    lanesDir: '',
    turnsDir: '',
    stopRequestPath: '',
    lastBlockerPath: '',
    lane: '',
    issue: null,
    epic: null,
    forkRemote: '',
    branch: '',
    prUrl: '',
    blockerClass: 'none',
    reason: '',
    leaseScope: DEFAULT_LEASE_SCOPE,
    leaseRoot: '',
    owner: '',
    quiet: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--quiet') {
      options.quiet = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--action' ||
      token === '--repo' ||
      token === '--runtime-dir' ||
      token === '--state-path' ||
      token === '--events-path' ||
      token === '--lanes-dir' ||
      token === '--turns-dir' ||
      token === '--stop-request-path' ||
      token === '--last-blocker-path' ||
      token === '--lane' ||
      token === '--issue' ||
      token === '--epic' ||
      token === '--fork-remote' ||
      token === '--branch' ||
      token === '--pr-url' ||
      token === '--blocker-class' ||
      token === '--reason' ||
      token === '--lease-scope' ||
      token === '--lease-root' ||
      token === '--owner'
    ) {
      if (next === undefined || (next.startsWith('-') && token !== '--reason')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--action') {
        options.action = normalizeText(next).toLowerCase();
      } else if (token === '--repo') {
        options.repo = normalizeText(next);
      } else if (token === '--runtime-dir') {
        options.runtimeDir = normalizeText(next);
      } else if (token === '--state-path') {
        options.statePath = normalizeText(next);
      } else if (token === '--events-path') {
        options.eventsPath = normalizeText(next);
      } else if (token === '--lanes-dir') {
        options.lanesDir = normalizeText(next);
      } else if (token === '--turns-dir') {
        options.turnsDir = normalizeText(next);
      } else if (token === '--stop-request-path') {
        options.stopRequestPath = normalizeText(next);
      } else if (token === '--last-blocker-path') {
        options.lastBlockerPath = normalizeText(next);
      } else if (token === '--lane') {
        options.lane = normalizeText(next);
      } else if (token === '--issue') {
        options.issue = toPositiveInteger(next, { label: '--issue' });
      } else if (token === '--epic') {
        options.epic = toPositiveInteger(next, { label: '--epic' });
      } else if (token === '--fork-remote') {
        options.forkRemote = normalizeText(next);
      } else if (token === '--branch') {
        options.branch = normalizeText(next);
      } else if (token === '--pr-url') {
        options.prUrl = normalizeText(next);
      } else if (token === '--blocker-class') {
        options.blockerClass = normalizeText(next).toLowerCase();
      } else if (token === '--reason') {
        options.reason = String(next);
      } else if (token === '--lease-scope') {
        options.leaseScope = normalizeText(next) || DEFAULT_LEASE_SCOPE;
      } else if (token === '--lease-root') {
        options.leaseRoot = normalizeText(next);
      } else if (token === '--owner') {
        options.owner = normalizeText(next);
      }
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.action && !ACTIONS.has(options.action)) {
    throw new Error(`Unsupported --action '${options.action}'.`);
  }
  if (options.blockerClass && !BLOCKER_CLASSES.has(options.blockerClass)) {
    throw new Error(`Unsupported --blocker-class '${options.blockerClass}'.`);
  }

  return options;
}

export function createRuntimeAdapter(adapter = {}) {
  const normalized = {
    name: normalizeText(adapter.name) || 'runtime-adapter',
    resolveRepoRoot: adapter.resolveRepoRoot,
    resolveOwner: adapter.resolveOwner,
    acquireLease: adapter.acquireLease,
    releaseLease: adapter.releaseLease,
    planStep: typeof adapter.planStep === 'function' ? adapter.planStep : null,
    prepareWorker: typeof adapter.prepareWorker === 'function' ? adapter.prepareWorker : null,
    bootstrapWorker: typeof adapter.bootstrapWorker === 'function' ? adapter.bootstrapWorker : null,
    activateWorker: typeof adapter.activateWorker === 'function' ? adapter.activateWorker : null,
    buildTaskPacket: typeof adapter.buildTaskPacket === 'function' ? adapter.buildTaskPacket : null,
    executeTurn: typeof adapter.executeTurn === 'function' ? adapter.executeTurn : null,
    resolveRepository:
      typeof adapter.resolveRepository === 'function'
        ? adapter.resolveRepository
        : ({ options, env }) => normalizeText(options.repo) || env.GITHUB_REPOSITORY || 'unknown/unknown'
  };

  for (const field of ['resolveRepoRoot', 'resolveOwner', 'acquireLease', 'releaseLease']) {
    if (typeof normalized[field] !== 'function') {
      throw new Error(`Runtime adapter '${normalized.name}' is missing required hook '${field}'.`);
    }
  }

  return normalized;
}

function summarizeWorker(workerRecord) {
  if (!workerRecord) return null;
  return {
    laneId: workerRecord.laneId,
    checkoutPath: workerRecord.checkoutPath,
    checkoutRoot: workerRecord.checkoutRoot,
    status: workerRecord.status,
    ref: workerRecord.ref,
    requestedBranch: workerRecord.requestedBranch,
    preparedAt: workerRecord.preparedAt,
    reused: Boolean(workerRecord.reused)
  };
}

function summarizeWorkerReady(workerReadyRecord) {
  if (!workerReadyRecord) return null;
  return {
    laneId: workerReadyRecord.laneId,
    checkoutPath: workerReadyRecord.checkoutPath,
    status: workerReadyRecord.status,
    bootstrapCommand: workerReadyRecord.bootstrapCommand,
    preparedAt: workerReadyRecord.preparedAt,
    readyAt: workerReadyRecord.readyAt,
    refreshed: Boolean(workerReadyRecord.refreshed)
  };
}

function summarizeWorkerBranch(workerBranchRecord) {
  if (!workerBranchRecord) return null;
  return {
    laneId: workerBranchRecord.laneId,
    checkoutPath: workerBranchRecord.checkoutPath,
    branch: workerBranchRecord.branch,
    status: workerBranchRecord.status,
    trackingRef: workerBranchRecord.trackingRef,
    activatedAt: workerBranchRecord.activatedAt,
    reused: Boolean(workerBranchRecord.reused)
  };
}

function summarizeTaskPacket(taskPacketRecord) {
  if (!taskPacketRecord) return null;
  return {
    laneId: taskPacketRecord.laneId,
    cycle: taskPacketRecord.cycle,
    status: taskPacketRecord.status,
    objective: {
      summary: taskPacketRecord.objective?.summary ?? null,
      source: taskPacketRecord.objective?.source ?? null
    },
    branch: {
      name: taskPacketRecord.branch?.name ?? null,
      status: taskPacketRecord.branch?.status ?? null
    },
    pullRequest: {
      url: taskPacketRecord.pullRequest?.url ?? null,
      status: taskPacketRecord.pullRequest?.status ?? null
    },
    checks: {
      status: taskPacketRecord.checks?.status ?? null,
      blockerClass: taskPacketRecord.checks?.blockerClass ?? null
    },
    helperSurface: {
      preferredCount: Array.isArray(taskPacketRecord.helperSurface?.preferred)
        ? taskPacketRecord.helperSurface.preferred.length
        : 0,
      fallbackCount: Array.isArray(taskPacketRecord.helperSurface?.fallbacks)
        ? taskPacketRecord.helperSurface.fallbacks.length
        : 0
    },
    generatedAt: taskPacketRecord.generatedAt ?? null,
    artifacts: taskPacketRecord.artifacts ?? {}
  };
}

function normalizeWorkerRecord(worker, now) {
  if (!worker || typeof worker !== 'object') return null;
  const checkoutPath = normalizeText(worker.checkoutPath) || null;
  const checkoutRoot = normalizeText(worker.checkoutRoot) || (checkoutPath ? path.dirname(checkoutPath) : null);
  const status = normalizeText(worker.status).toLowerCase() || 'prepared';
  const laneId = normalizeText(worker.laneId) || null;
  const ref = normalizeText(worker.ref) || null;
  const requestedBranch = normalizeText(worker.requestedBranch) || null;
  const source = normalizeText(worker.source) || null;
  const reason = normalizeText(worker.reason) || null;
  const preparedAt = normalizeText(worker.preparedAt) || toIso(now);
  const artifacts = worker.artifacts && typeof worker.artifacts === 'object' ? worker.artifacts : {};
  return {
    schema: WORKER_CHECKOUT_SCHEMA,
    laneId,
    checkoutPath,
    checkoutRoot,
    status,
    ref,
    requestedBranch,
    source,
    reason,
    preparedAt,
    reused: worker.reused === true || status === 'reused',
    artifacts
  };
}

function normalizeWorkerReadyRecord(workerReady, now) {
  if (!workerReady || typeof workerReady !== 'object') return null;
  const laneId = normalizeText(workerReady.laneId) || null;
  const checkoutPath = normalizeText(workerReady.checkoutPath) || null;
  const status = normalizeText(workerReady.status).toLowerCase() || 'ready';
  const source = normalizeText(workerReady.source) || null;
  const reason = normalizeText(workerReady.reason) || null;
  const bootstrapCommand = Array.isArray(workerReady.bootstrapCommand)
    ? workerReady.bootstrapCommand.map((entry) => String(entry))
    : [];
  const bootstrapExitCode = Number.isInteger(workerReady.bootstrapExitCode) ? workerReady.bootstrapExitCode : 0;
  const preparedAt = normalizeText(workerReady.preparedAt) || toIso(now);
  const readyAt = normalizeText(workerReady.readyAt) || toIso(now);
  const artifacts = workerReady.artifacts && typeof workerReady.artifacts === 'object' ? workerReady.artifacts : {};
  return {
    schema: WORKER_READY_SCHEMA,
    laneId,
    checkoutPath,
    status,
    source,
    reason,
    bootstrapCommand,
    bootstrapExitCode,
    preparedAt,
    readyAt,
    refreshed: workerReady.refreshed === true || status === 'reused',
    artifacts
  };
}

function normalizeWorkerBranchRecord(workerBranch, now) {
  if (!workerBranch || typeof workerBranch !== 'object') return null;
  const laneId = normalizeText(workerBranch.laneId) || null;
  const checkoutPath = normalizeText(workerBranch.checkoutPath) || null;
  const branch = normalizeText(workerBranch.branch) || null;
  const forkRemote = normalizeText(workerBranch.forkRemote) || null;
  const status = normalizeText(workerBranch.status).toLowerCase() || 'attached';
  const source = normalizeText(workerBranch.source) || null;
  const reason = normalizeText(workerBranch.reason) || null;
  const baseRef = normalizeText(workerBranch.baseRef) || null;
  const trackingRef = normalizeText(workerBranch.trackingRef) || null;
  const fetchedRemotes = Array.isArray(workerBranch.fetchedRemotes)
    ? workerBranch.fetchedRemotes.map((entry) => normalizeText(entry)).filter(Boolean)
    : [];
  const readyAt = normalizeText(workerBranch.readyAt) || null;
  const activatedAt = normalizeText(workerBranch.activatedAt) || toIso(now);
  const artifacts = workerBranch.artifacts && typeof workerBranch.artifacts === 'object' ? workerBranch.artifacts : {};
  return {
    schema: WORKER_BRANCH_SCHEMA,
    laneId,
    checkoutPath,
    branch,
    forkRemote,
    status,
    source,
    reason,
    baseRef,
    trackingRef,
    fetchedRemotes,
    readyAt,
    activatedAt,
    reused: workerBranch.reused === true || status === 'reused',
    artifacts
  };
}

function normalizeTaskPacketRecord(taskPacket, now) {
  if (!taskPacket || typeof taskPacket !== 'object') return null;
  const objective = taskPacket.objective && typeof taskPacket.objective === 'object' ? taskPacket.objective : {};
  const branch = taskPacket.branch && typeof taskPacket.branch === 'object' ? taskPacket.branch : {};
  const pullRequest = taskPacket.pullRequest && typeof taskPacket.pullRequest === 'object' ? taskPacket.pullRequest : {};
  const checks = taskPacket.checks && typeof taskPacket.checks === 'object' ? taskPacket.checks : {};
  const helperSurface = taskPacket.helperSurface && typeof taskPacket.helperSurface === 'object' ? taskPacket.helperSurface : {};
  const recentEvents = Array.isArray(taskPacket.recentEvents) ? taskPacket.recentEvents : [];
  const evidence = taskPacket.evidence && typeof taskPacket.evidence === 'object' ? taskPacket.evidence : {};
  const artifacts = taskPacket.artifacts && typeof taskPacket.artifacts === 'object' ? taskPacket.artifacts : {};
  return {
    schema: TASK_PACKET_SCHEMA,
    generatedAt: normalizeText(taskPacket.generatedAt) || toIso(now),
    cycle: Number.isInteger(taskPacket.cycle) ? taskPacket.cycle : null,
    laneId: normalizeText(taskPacket.laneId) || null,
    status: normalizeText(taskPacket.status).toLowerCase() || 'ready',
    source: normalizeText(taskPacket.source) || null,
    objective: {
      summary: normalizeText(objective.summary) || null,
      source: normalizeText(objective.source) || null
    },
    branch: {
      name: normalizeText(branch.name) || null,
      forkRemote: normalizeText(branch.forkRemote) || null,
      status: normalizeText(branch.status) || null,
      trackingRef: normalizeText(branch.trackingRef) || null,
      checkoutPath: normalizeText(branch.checkoutPath) || null
    },
    pullRequest: {
      url: normalizeText(pullRequest.url) || null,
      status: normalizeText(pullRequest.status) || null
    },
    checks: {
      status: normalizeText(checks.status) || null,
      blockerClass: normalizeText(checks.blockerClass) || null
    },
    helperSurface: {
      preferred: Array.isArray(helperSurface.preferred)
        ? helperSurface.preferred.map((entry) => String(entry))
        : [],
      fallbacks: Array.isArray(helperSurface.fallbacks)
        ? helperSurface.fallbacks.map((entry) => String(entry))
        : []
    },
    recentEvents,
    evidence,
    artifacts
  };
}

function buildActiveLaneSummary(laneRecord) {
  if (!laneRecord) return null;
  return {
    laneId: laneRecord.laneId,
    issue: laneRecord.issue,
    epic: laneRecord.epic,
    forkRemote: laneRecord.forkRemote,
    branch: laneRecord.branch,
    prUrl: laneRecord.prUrl,
    blockerClass: laneRecord.blocker?.blockerClass ?? 'none',
    worker: summarizeWorker(laneRecord.worker),
    workerReady: summarizeWorkerReady(laneRecord.workerReady),
    workerBranch: summarizeWorkerBranch(laneRecord.workerBranch),
    taskPacket: summarizeTaskPacket(laneRecord.taskPacket),
    updatedAt: laneRecord.updatedAt
  };
}

function buildEmptyState({ repository, repoRoot, runtimePaths, now, owner, adapter }) {
  const timestamp = toIso(now);
  return {
    schema: STATE_SCHEMA,
    generatedAt: timestamp,
    repository,
    repoRoot,
    runtimeDir: runtimePaths.runtimeDir,
    runtimeAdapter: adapter.name,
    lifecycle: {
      status: 'idle',
      cycle: 0,
      startedAt: timestamp,
      updatedAt: timestamp,
      lastAction: null,
      stopRequested: false
    },
    owner,
    activeLane: null,
    summary: {
      trackedLaneCount: 0,
      blockerPresent: false
    },
    artifacts: {
      statePath: runtimePaths.statePath,
      eventsPath: runtimePaths.eventsPath,
      lanesDir: runtimePaths.lanesDir,
      turnsDir: runtimePaths.turnsDir,
      stopRequestPath: runtimePaths.stopRequestPath,
      lastBlockerPath: runtimePaths.lastBlockerPath
    }
  };
}

async function ensureRuntimeLayout(runtimePaths) {
  await ensureDir(runtimePaths.runtimeDir);
  await ensureDir(runtimePaths.lanesDir);
  await ensureDir(runtimePaths.turnsDir);
}

async function loadState({ repository, repoRoot, runtimePaths, now, owner, adapter }) {
  const existing = await readJson(runtimePaths.statePath);
  if (existing) {
    return {
      ...existing,
      repository: existing.repository || repository,
      repoRoot: existing.repoRoot || repoRoot,
      runtimeDir: existing.runtimeDir || runtimePaths.runtimeDir,
      runtimeAdapter: existing.runtimeAdapter || adapter.name,
      owner: existing.owner || owner,
      artifacts: {
        ...(existing.artifacts || {}),
        statePath: runtimePaths.statePath,
        eventsPath: runtimePaths.eventsPath,
        lanesDir: runtimePaths.lanesDir,
        turnsDir: runtimePaths.turnsDir,
        stopRequestPath: runtimePaths.stopRequestPath,
        lastBlockerPath: runtimePaths.lastBlockerPath
      }
    };
  }
  return buildEmptyState({ repository, repoRoot, runtimePaths, now, owner, adapter });
}

function buildLaneRecord(options, now) {
  const hasLaneContext =
    Boolean(options.lane) ||
    Number.isInteger(options.issue) ||
    Number.isInteger(options.epic) ||
    Boolean(options.forkRemote) ||
    Boolean(options.branch) ||
    Boolean(options.prUrl);
  if (!hasLaneContext) {
    return null;
  }

  const laneId =
    options.lane ||
    [options.forkRemote, options.issue].filter(Boolean).join('-') ||
    `lane-${sanitizeSegment(options.branch || 'active')}`;
  const blockerClass = options.blockerClass || 'none';
  const worker = normalizeWorkerRecord(options.worker, now);
  const workerReady = normalizeWorkerReadyRecord(options.workerReady, now);
  const workerBranch = normalizeWorkerBranchRecord(options.workerBranch, now);
  const taskPacket = normalizeTaskPacketRecord(options.taskPacket, now);
  return {
    schema: LANE_SCHEMA,
    laneId,
    issue: Number.isInteger(options.issue) ? options.issue : null,
    epic: Number.isInteger(options.epic) ? options.epic : null,
    forkRemote: normalizeText(options.forkRemote) || null,
    branch: normalizeText(options.branch) || null,
    prUrl: normalizeText(options.prUrl) || null,
    blocker:
      blockerClass === 'none'
        ? null
        : {
            schema: BLOCKER_SCHEMA,
            blockerClass,
            reason: normalizeText(options.reason) || null,
            observedAt: toIso(now)
          },
    worker,
    workerReady,
    workerBranch,
    taskPacket,
    createdAt: toIso(now),
    updatedAt: toIso(now)
  };
}

async function writeLaneArtifact(runtimePaths, laneRecord) {
  if (!laneRecord) return null;
  const lanePath = path.join(runtimePaths.lanesDir, `${sanitizeSegment(laneRecord.laneId)}.json`);
  await writeJson(lanePath, laneRecord);
  return lanePath;
}

async function writeLastBlocker(runtimePaths, laneRecord, now) {
  if (!laneRecord?.blocker) {
    if (existsSync(runtimePaths.lastBlockerPath)) {
      await rm(runtimePaths.lastBlockerPath, { force: true });
    }
    return null;
  }

  const blockerPayload = {
    schema: BLOCKER_SCHEMA,
    generatedAt: toIso(now),
    laneId: laneRecord.laneId,
    issue: laneRecord.issue,
    epic: laneRecord.epic,
    forkRemote: laneRecord.forkRemote,
    branch: laneRecord.branch,
    blockerClass: laneRecord.blocker.blockerClass,
    reason: laneRecord.blocker.reason
  };
  await writeJson(runtimePaths.lastBlockerPath, blockerPayload);
  return runtimePaths.lastBlockerPath;
}

async function recordEvent(runtimePaths, payload) {
  return appendNdjson(runtimePaths.eventsPath, payload);
}

async function writeTurn(runtimePaths, turn) {
  const turnPath = path.join(runtimePaths.turnsDir, makeTurnFileName(new Date(turn.generatedAt), turn.cycle));
  await writeJson(turnPath, turn);
  return turnPath;
}

async function finalizeState(state, runtimePaths, now) {
  state.generatedAt = toIso(now);
  state.summary = {
    trackedLaneCount: await countJsonFiles(runtimePaths.lanesDir),
    blockerPresent: existsSync(runtimePaths.lastBlockerPath)
  };
  await writeJson(runtimePaths.statePath, state);
  return state;
}

function buildBaseReport({ action, repository, runtimePaths, now, adapter }) {
  return {
    schema: REPORT_SCHEMA,
    generatedAt: toIso(now),
    action,
    repository,
    runtimeAdapter: adapter.name,
    status: 'pass',
    runtime: {
      runtimeDir: runtimePaths.runtimeDir,
      statePath: runtimePaths.statePath,
      eventsPath: runtimePaths.eventsPath,
      lanesDir: runtimePaths.lanesDir,
      turnsDir: runtimePaths.turnsDir,
      stopRequestPath: runtimePaths.stopRequestPath,
      lastBlockerPath: runtimePaths.lastBlockerPath
    }
  };
}

async function runStatusAction(context) {
  const { state, runtimePaths, now, report } = context;
  const stopRequest = await readJson(runtimePaths.stopRequestPath);
  state.lifecycle.stopRequested = Boolean(stopRequest);
  state.lifecycle.updatedAt = toIso(now);
  state.lifecycle.lastAction = 'status';
  await finalizeState(state, runtimePaths, now);
  report.outcome = 'status';
  report.state = state;
  return { exitCode: 0, report };
}

async function runStopAction(context) {
  const { options, owner, state, runtimePaths, now, report } = context;
  const stopRequest = {
    schema: STOP_REQUEST_SCHEMA,
    requestedAt: toIso(now),
    requestedBy: owner,
    reason: normalizeText(options.reason) || 'operator-request'
  };
  await writeJson(runtimePaths.stopRequestPath, stopRequest);
  state.lifecycle.stopRequested = true;
  state.lifecycle.status = 'paused';
  state.lifecycle.updatedAt = toIso(now);
  state.lifecycle.lastAction = 'stop';
  await finalizeState(state, runtimePaths, now);
  await recordEvent(runtimePaths, {
    schema: EVENT_SCHEMA,
    timestamp: toIso(now),
    action: 'stop',
    owner,
    reason: stopRequest.reason
  });
  report.outcome = 'stop-requested';
  report.stopRequest = stopRequest;
  report.state = state;
  return { exitCode: 0, report };
}

async function runResumeAction(context) {
  const { state, runtimePaths, now, report, owner } = context;
  await rm(runtimePaths.stopRequestPath, { force: true });
  state.lifecycle.stopRequested = false;
  state.lifecycle.status = 'idle';
  state.lifecycle.updatedAt = toIso(now);
  state.lifecycle.lastAction = 'resume';
  await finalizeState(state, runtimePaths, now);
  await recordEvent(runtimePaths, {
    schema: EVENT_SCHEMA,
    timestamp: toIso(now),
    action: 'resume',
    owner
  });
  report.outcome = 'resumed';
  report.state = state;
  return { exitCode: 0, report };
}

function isLeaseSuccess(result) {
  return ['acquired', 'renewed', 'takeover'].includes(result?.status);
}

async function runStepAction(context) {
  const {
    options,
    state,
    runtimePaths,
    now,
    report,
    owner,
    acquireWriterLeaseFn,
    releaseWriterLeaseFn
  } = context;

  const leaseOptions = {
    scope: options.leaseScope || DEFAULT_LEASE_SCOPE,
    owner
  };
  if (options.leaseRoot) {
    leaseOptions.leaseRoot = path.isAbsolute(options.leaseRoot)
      ? options.leaseRoot
      : path.join(context.repoRoot, options.leaseRoot);
  }

  const acquireResult = await acquireWriterLeaseFn(leaseOptions);
  report.lease = {
    acquire: summarizeLease(acquireResult),
    release: null
  };

  if (!isLeaseSuccess(acquireResult)) {
    state.lifecycle.status = 'blocked';
    state.lifecycle.updatedAt = toIso(now);
    state.lifecycle.lastAction = 'step';
    state.lifecycle.stopRequested = Boolean(await readJson(runtimePaths.stopRequestPath));
    await finalizeState(state, runtimePaths, now);
    await recordEvent(runtimePaths, {
      schema: EVENT_SCHEMA,
      timestamp: toIso(now),
      action: 'step',
      outcome: 'lease-blocked',
      leaseStatus: acquireResult?.status ?? null
    });
    report.status = 'blocked';
    report.outcome = 'lease-blocked';
    report.state = state;
    return { exitCode: 10, report };
  }

  try {
    const stopRequest = await readJson(runtimePaths.stopRequestPath);
    const laneRecord = buildLaneRecord(options, now);
    let lanePath = null;
    let blockerPath = null;
    let outcome = 'idle';

    state.lifecycle.cycle = Number(state.lifecycle.cycle || 0) + 1;
    state.lifecycle.updatedAt = toIso(now);
    state.lifecycle.lastAction = 'step';
    state.lifecycle.stopRequested = Boolean(stopRequest);

    if (stopRequest) {
      state.lifecycle.status = 'paused';
      outcome = 'stop-requested';
    } else if (laneRecord) {
      state.lifecycle.status = 'running';
      state.activeLane = buildActiveLaneSummary(laneRecord);
      lanePath = await writeLaneArtifact(runtimePaths, laneRecord);
      blockerPath = await writeLastBlocker(runtimePaths, laneRecord, now);
      outcome = 'lane-tracked';
    } else {
      state.lifecycle.status = 'idle';
      state.activeLane = null;
      await writeLastBlocker(runtimePaths, null, now);
    }

    const turn = {
      schema: TURN_SCHEMA,
      generatedAt: toIso(now),
      action: 'step',
      cycle: state.lifecycle.cycle,
      repository: state.repository,
      runtimeAdapter: state.runtimeAdapter,
      outcome,
      stopRequested: Boolean(stopRequest),
      lease: {
        acquire: summarizeLease(acquireResult),
        release: null
      },
      activeLane: laneRecord ? buildActiveLaneSummary(laneRecord) : null,
      artifacts: {
        lanePath,
        blockerPath,
        workerPath: laneRecord?.worker?.checkoutPath ?? null,
        workerArtifactPath: laneRecord?.worker?.artifacts?.lanePath ?? null,
        workerReadyPath: laneRecord?.workerReady?.artifacts?.latestPath ?? null,
        workerReadyArtifactPath: laneRecord?.workerReady?.artifacts?.lanePath ?? null,
        workerBranchPath: laneRecord?.workerBranch?.artifacts?.latestPath ?? null,
        workerBranchArtifactPath: laneRecord?.workerBranch?.artifacts?.lanePath ?? null,
        taskPacketPath: laneRecord?.taskPacket?.artifacts?.latestPath ?? null,
        taskPacketHistoryPath: laneRecord?.taskPacket?.artifacts?.historyPath ?? null,
        statePath: runtimePaths.statePath,
        eventsPath: runtimePaths.eventsPath
      }
    };

    await finalizeState(state, runtimePaths, now);
    const turnPath = await writeTurn(runtimePaths, turn);
    await recordEvent(runtimePaths, {
      schema: EVENT_SCHEMA,
      timestamp: toIso(now),
      action: 'step',
      outcome,
      cycle: state.lifecycle.cycle,
      laneId: laneRecord?.laneId ?? null,
      issue: laneRecord?.issue ?? null,
      epic: laneRecord?.epic ?? null,
      blockerClass: laneRecord?.blocker?.blockerClass ?? 'none',
      stopRequested: Boolean(stopRequest)
    });

    report.outcome = outcome;
    report.turnPath = turnPath;
    report.worker = summarizeWorker(laneRecord?.worker);
    report.workerReady = summarizeWorkerReady(laneRecord?.workerReady);
    report.workerBranch = summarizeWorkerBranch(laneRecord?.workerBranch);
    report.taskPacket = summarizeTaskPacket(laneRecord?.taskPacket);
    report.state = state;
  } finally {
    const leaseId = report.lease?.acquire?.leaseId ?? null;
    const releaseResult = await releaseWriterLeaseFn({
      ...leaseOptions,
      leaseId
    });
    report.lease.release = summarizeLease(releaseResult);
  }

  return { exitCode: 0, report };
}

function resolveAdapter(deps = {}) {
  return createRuntimeAdapter(deps.adapter ?? {});
}

export async function runRuntimeSupervisor(options = {}, deps = {}) {
  const now = deps.now ?? new Date();
  const adapter = resolveAdapter(deps);
  const resolveRepoRootFn = deps.resolveRepoRootFn ?? ((context) => adapter.resolveRepoRoot(context));
  const repoRoot = deps.repoRoot ?? resolveRepoRootFn({ options, env: process.env, deps, adapter });
  const resolveRepositoryFn = deps.resolveRepositoryFn ?? ((context) => adapter.resolveRepository(context));
  const repository = resolveRepositoryFn({ options, env: process.env, repoRoot, deps, adapter });
  const resolveOwnerFn = deps.resolveOwnerFn ?? ((context) => adapter.resolveOwner(context));
  const owner = normalizeText(options.owner) || resolveOwnerFn({ options, env: process.env, repoRoot, deps, adapter });
  const runtimePaths = resolveRuntimePaths(repoRoot, options);
  await ensureRuntimeLayout(runtimePaths);

  const state = await loadState({
    repository,
    repoRoot,
    runtimePaths,
    now,
    owner,
    adapter
  });
  const report = buildBaseReport({
    action: options.action,
    repository,
    runtimePaths,
    now,
    adapter
  });

  const context = {
    options,
    owner,
    state,
    runtimePaths,
    now,
    repoRoot,
    report,
    acquireWriterLeaseFn:
      deps.acquireWriterLeaseFn ?? ((leaseOptions) => adapter.acquireLease(leaseOptions, { options, env: process.env, repoRoot, deps })),
    releaseWriterLeaseFn:
      deps.releaseWriterLeaseFn ?? ((leaseOptions) => adapter.releaseLease(leaseOptions, { options, env: process.env, repoRoot, deps }))
  };

  if (options.action === 'status') {
    return runStatusAction(context);
  }
  if (options.action === 'stop') {
    return runStopAction(context);
  }
  if (options.action === 'resume') {
    return runResumeAction(context);
  }
  if (options.action === 'step') {
    return runStepAction(context);
  }
  throw new Error(`Unsupported action '${options.action}'.`);
}

export async function runCli(argv = process.argv, deps = {}) {
  const options = parseArgs(argv);
  if (options.help || !options.action) {
    printUsage();
    return 0;
  }

  const result = await runRuntimeSupervisor(options, deps);
  if (!options.quiet) {
    process.stdout.write(`${JSON.stringify(result.report, null, 2)}\n`);
  }
  return result.exitCode;
}

export const __test = {
  buildLaneRecord,
  buildEmptyState,
  makeTurnFileName,
  resolveRuntimePaths
};

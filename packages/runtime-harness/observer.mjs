#!/usr/bin/env node

import { mkdir, open, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  BLOCKER_CLASSES,
  createRuntimeAdapter,
  DEFAULT_RUNTIME_DIR,
  EXECUTION_RECEIPT_SCHEMA,
  SCHEDULER_DECISION_SCHEMA,
  TASK_PACKET_SCHEMA,
  WORKER_BRANCH_SCHEMA,
  WORKER_CHECKOUT_SCHEMA,
  WORKER_READY_SCHEMA
} from './index.mjs';
import { runRuntimeWorkerStep } from './worker.mjs';

export const OBSERVER_REPORT_SCHEMA = 'priority/runtime-observer-report@v1';
export const OBSERVER_HEARTBEAT_SCHEMA = 'priority/runtime-observer-heartbeat@v1';
export const DEFAULT_POLL_INTERVAL_SECONDS = 60;
export const SCHEDULER_DECISION_OUTCOMES = new Set(['selected', 'idle', 'blocked']);
const SCHEDULER_STEP_OPTION_KEYS = ['lane', 'issue', 'epic', 'forkRemote', 'branch', 'prUrl', 'blockerClass', 'reason'];
const DEFAULT_RECENT_EVENTS_LIMIT = 5;
const MAX_RECENT_EVENTS_BYTES = 64 * 1024;

function printUsage() {
  console.log('Usage: node runtime-daemon [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>               Repository slug to record in observer state.');
  console.log(`  --runtime-dir <path>              Runtime artifact root (default: ${DEFAULT_RUNTIME_DIR}).`);
  console.log('  --heartbeat-path <path>           Override observer-heartbeat.json path.');
  console.log('  --scheduler-decision-path <path>  Override scheduler-decision.json path.');
  console.log('  --scheduler-decisions-dir <path>  Override scheduler decision history directory.');
  console.log('  --lane <id>                       Lane identifier for worker steps.');
  console.log('  --issue <number>                  Upstream child issue number for the active lane.');
  console.log('  --epic <number>                   Parent epic issue number for the active lane.');
  console.log('  --fork-remote <name>              Lane fork remote (origin|personal|upstream).');
  console.log('  --branch <name>                   Lane branch name.');
  console.log('  --pr-url <url>                    Active pull request URL for the lane.');
  console.log('  --blocker-class <name>            Blocker class for the active lane.');
  console.log('  --reason <text>                   Blocker reason or operator note.');
  console.log('  --lease-scope <name>              Lease scope for worker steps.');
  console.log('  --lease-root <path>               Optional lease root override.');
  console.log('  --owner <value>                   Runtime owner identity.');
  console.log(`  --poll-interval-seconds <number>  Delay between worker cycles (default: ${DEFAULT_POLL_INTERVAL_SECONDS}).`);
  console.log('  --max-cycles <number>             Stop after N cycles (0 = run until stop request).');
  console.log('  --stop-on-idle                    Exit cleanly when the planner reports idle/no actionable work.');
  console.log('  --execute-turn                    Invoke the adapter execution hook after each successful worker step.');
  console.log('  --quiet                           Suppress stdout JSON output.');
  console.log('  -h, --help                        Show this help text and exit.');
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function toPositiveInteger(value, { label, allowZero = false }) {
  if (value == null) return null;
  const number = Number(value);
  const minimum = allowZero ? 0 : 1;
  if (!Number.isInteger(number) || number < minimum) {
    throw new Error(`Invalid ${label} value '${value}'.`);
  }
  return number;
}

function coercePositiveInteger(value) {
  if (value == null || value === '') return null;
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
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

function makeDecisionFileName(now, cycle) {
  const stamp = toIso(now).replace(/[:.]/g, '-');
  const normalizedCycle = String(cycle).padStart(4, '0');
  return `${stamp}-${normalizedCycle}.json`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
}

function resolveRepoRoot(options, deps, adapter) {
  if (deps.repoRoot) return deps.repoRoot;
  if (typeof deps.resolveRepoRootFn === 'function') {
    return deps.resolveRepoRootFn({ options, env: process.env, deps, adapter });
  }
  return adapter.resolveRepoRoot({ options, env: process.env, deps, adapter });
}

function resolveHeartbeatPath(options, repoRoot) {
  if (options.heartbeatPath) {
    return resolvePath(repoRoot, options.heartbeatPath);
  }
  const runtimeDir = resolvePath(repoRoot, options.runtimeDir || DEFAULT_RUNTIME_DIR);
  return path.join(runtimeDir, 'observer-heartbeat.json');
}

function resolveSchedulerPaths(options, repoRoot) {
  const runtimeDir = resolvePath(repoRoot, options.runtimeDir || DEFAULT_RUNTIME_DIR);
  return {
    latestPath: options.schedulerDecisionPath
      ? resolvePath(repoRoot, options.schedulerDecisionPath)
      : path.join(runtimeDir, 'scheduler-decision.json'),
    historyDir: options.schedulerDecisionsDir
      ? resolvePath(repoRoot, options.schedulerDecisionsDir)
      : path.join(runtimeDir, 'scheduler-decisions')
  };
}

function resolveRuntimeArtifactPaths(options, repoRoot) {
  const runtimeDir = resolvePath(repoRoot, options.runtimeDir || DEFAULT_RUNTIME_DIR);
  return {
    runtimeDir,
    statePath: path.join(runtimeDir, 'runtime-state.json'),
    eventsPath: path.join(runtimeDir, 'runtime-events.ndjson'),
    stopRequestPath: path.join(runtimeDir, 'stop-request.json')
  };
}

function resolveWorkerPaths(options, repoRoot) {
  const runtimeDir = resolvePath(repoRoot, options.runtimeDir || DEFAULT_RUNTIME_DIR);
  return {
    latestPath: path.join(runtimeDir, 'worker-checkout.json'),
    workersDir: path.join(runtimeDir, 'workers'),
    readyLatestPath: path.join(runtimeDir, 'worker-ready.json'),
    readyDir: path.join(runtimeDir, 'workers-ready'),
    branchLatestPath: path.join(runtimeDir, 'worker-branch.json'),
    branchDir: path.join(runtimeDir, 'workers-branch')
  };
}

function resolveTaskPacketPaths(options, repoRoot) {
  const runtimeDir = resolvePath(repoRoot, options.runtimeDir || DEFAULT_RUNTIME_DIR);
  return {
    latestPath: path.join(runtimeDir, 'task-packet.json'),
    historyDir: path.join(runtimeDir, 'task-packets')
  };
}

function resolveExecutionPaths(options, repoRoot) {
  const runtimeDir = resolvePath(repoRoot, options.runtimeDir || DEFAULT_RUNTIME_DIR);
  return {
    latestPath: path.join(runtimeDir, 'execution-receipt.json'),
    historyDir: path.join(runtimeDir, 'execution-receipts')
  };
}

async function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

async function readRecentEvents(eventsPath, limit = DEFAULT_RECENT_EVENTS_LIMIT) {
  let handle;
  try {
    handle = await open(path.resolve(eventsPath), 'r');
    const stats = await handle.stat();
    if (!Number.isFinite(stats.size) || stats.size <= 0) {
      return [];
    }

    const bytesToRead = Math.min(stats.size, MAX_RECENT_EVENTS_BYTES);
    const startOffset = Math.max(0, stats.size - bytesToRead);
    const buffer = Buffer.alloc(bytesToRead);
    const { bytesRead } = await handle.read(buffer, 0, bytesToRead, startOffset);
    const raw = buffer.toString('utf8', 0, bytesRead);
    const lines = raw.split(/\r?\n/);
    if (startOffset > 0) {
      lines.shift();
    }

    const events = [];
    for (let index = lines.length - 1; index >= 0 && events.length < limit; index -= 1) {
      const line = lines[index]?.trim();
      if (!line) continue;
      try {
        events.push(JSON.parse(line));
      } catch {
        continue;
      }
    }

    return events.reverse();
  } catch (error) {
    if (error?.code === 'ENOENT') return [];
    throw error;
  } finally {
    await handle?.close();
  }
}

function normalizeStepOptions(stepOptions = {}) {
  const normalized = {};
  if (normalizeText(stepOptions.lane)) normalized.lane = normalizeText(stepOptions.lane);
  const issue = coercePositiveInteger(stepOptions.issue);
  if (issue != null) normalized.issue = issue;
  const epic = coercePositiveInteger(stepOptions.epic);
  if (epic != null) normalized.epic = epic;
  if (normalizeText(stepOptions.forkRemote)) normalized.forkRemote = normalizeText(stepOptions.forkRemote);
  if (normalizeText(stepOptions.branch)) normalized.branch = normalizeText(stepOptions.branch);
  if (normalizeText(stepOptions.prUrl)) normalized.prUrl = normalizeText(stepOptions.prUrl);
  const blockerClass = normalizeText(stepOptions.blockerClass).toLowerCase();
  if (blockerClass && BLOCKER_CLASSES.has(blockerClass)) {
    normalized.blockerClass = blockerClass;
  }
  if (stepOptions.reason != null) {
    normalized.reason = String(stepOptions.reason);
  }
  return normalized;
}

function hasStepContext(stepOptions = {}) {
  return (
    Boolean(normalizeText(stepOptions.lane)) ||
    coercePositiveInteger(stepOptions.issue) != null ||
    coercePositiveInteger(stepOptions.epic) != null ||
    Boolean(normalizeText(stepOptions.forkRemote)) ||
    Boolean(normalizeText(stepOptions.branch)) ||
    Boolean(normalizeText(stepOptions.prUrl))
  );
}

function summarizeStepOptions(stepOptions = {}) {
  if (!hasStepContext(stepOptions)) return null;
  const issue = coercePositiveInteger(stepOptions.issue);
  const forkRemote = normalizeText(stepOptions.forkRemote) || null;
  const laneId =
    normalizeText(stepOptions.lane) ||
    [forkRemote, issue].filter(Boolean).join('-') ||
    `lane-${sanitizeSegment(stepOptions.branch || 'active')}`;
  return {
    laneId,
    issue,
    epic: coercePositiveInteger(stepOptions.epic),
    forkRemote,
    branch: normalizeText(stepOptions.branch) || null,
    prUrl: normalizeText(stepOptions.prUrl) || null,
    blockerClass: normalizeText(stepOptions.blockerClass).toLowerCase() || 'none'
  };
}

function normalizeWorkerCheckout(rawWorker, decision, now, adapter, repository) {
  if (!rawWorker || typeof rawWorker !== 'object') return null;
  const checkoutPath = normalizeText(rawWorker.checkoutPath) || null;
  const checkoutRoot = normalizeText(rawWorker.checkoutRoot) || (checkoutPath ? path.dirname(checkoutPath) : null);
  const status = normalizeText(rawWorker.status).toLowerCase() || 'prepared';
  const laneId = normalizeText(rawWorker.laneId) || decision?.activeLane?.laneId || null;
  return {
    schema: WORKER_CHECKOUT_SCHEMA,
    generatedAt: toIso(now),
    runtimeAdapter: adapter.name,
    repository,
    laneId,
    slotId: normalizeText(rawWorker.slotId) || null,
    issue: decision?.activeLane?.issue ?? null,
    epic: decision?.activeLane?.epic ?? null,
    forkRemote: decision?.activeLane?.forkRemote ?? null,
    branch: decision?.activeLane?.branch ?? null,
    checkoutPath,
    checkoutRoot,
    status,
    ref: normalizeText(rawWorker.ref) || null,
    requestedBranch: normalizeText(rawWorker.requestedBranch) || decision?.activeLane?.branch || null,
    reason: normalizeText(rawWorker.reason) || null,
    source: normalizeText(rawWorker.source) || adapter.name,
    reused: rawWorker.reused === true || status === 'reused'
  };
}

async function writeWorkerCheckout(workerPaths, workerCheckout) {
  await mkdir(workerPaths.workersDir, { recursive: true });
  await writeJson(workerPaths.latestPath, workerCheckout);
  const lanePath = path.join(workerPaths.workersDir, `${sanitizeSegment(workerCheckout.laneId || 'runtime')}.json`);
  await writeJson(lanePath, workerCheckout);
  return {
    latestPath: workerPaths.latestPath,
    lanePath
  };
}

function normalizeWorkerReady(rawWorkerReady, decision, workerCheckout, now, adapter, repository) {
  if (!rawWorkerReady || typeof rawWorkerReady !== 'object') return null;
  const laneId =
    normalizeText(rawWorkerReady.laneId) || workerCheckout?.laneId || decision?.activeLane?.laneId || null;
  const checkoutPath = normalizeText(rawWorkerReady.checkoutPath) || workerCheckout?.checkoutPath || null;
  const status = normalizeText(rawWorkerReady.status).toLowerCase() || 'ready';
  const bootstrapCommand = Array.isArray(rawWorkerReady.bootstrapCommand)
    ? rawWorkerReady.bootstrapCommand.map((entry) => String(entry))
    : [];
  return {
    schema: WORKER_READY_SCHEMA,
    generatedAt: toIso(now),
    runtimeAdapter: adapter.name,
    repository,
    laneId,
    slotId: normalizeText(rawWorkerReady.slotId) || workerCheckout?.slotId || null,
    issue: decision?.activeLane?.issue ?? null,
    epic: decision?.activeLane?.epic ?? null,
    forkRemote: decision?.activeLane?.forkRemote ?? null,
    branch: decision?.activeLane?.branch ?? null,
    checkoutPath,
    status,
    source: normalizeText(rawWorkerReady.source) || adapter.name,
    reason: normalizeText(rawWorkerReady.reason) || null,
    bootstrapCommand,
    bootstrapExitCode: Number.isInteger(rawWorkerReady.bootstrapExitCode) ? rawWorkerReady.bootstrapExitCode : 0,
    preparedAt: normalizeText(rawWorkerReady.preparedAt) || workerCheckout?.generatedAt || toIso(now),
    readyAt: normalizeText(rawWorkerReady.readyAt) || toIso(now),
    refreshed: rawWorkerReady.refreshed === true || status === 'reused'
  };
}

async function writeWorkerReady(workerPaths, workerReady) {
  await mkdir(workerPaths.readyDir, { recursive: true });
  await writeJson(workerPaths.readyLatestPath, workerReady);
  const lanePath = path.join(workerPaths.readyDir, `${sanitizeSegment(workerReady.laneId || 'runtime')}.json`);
  await writeJson(lanePath, workerReady);
  return {
    latestPath: workerPaths.readyLatestPath,
    lanePath
  };
}

function normalizeWorkerBranch(rawWorkerBranch, decision, workerReady, now, adapter, repository) {
  if (!rawWorkerBranch || typeof rawWorkerBranch !== 'object') return null;
  const laneId =
    normalizeText(rawWorkerBranch.laneId) || workerReady?.laneId || decision?.activeLane?.laneId || null;
  const checkoutPath = normalizeText(rawWorkerBranch.checkoutPath) || workerReady?.checkoutPath || null;
  const branch = normalizeText(rawWorkerBranch.branch) || decision?.activeLane?.branch || null;
  const status = normalizeText(rawWorkerBranch.status).toLowerCase() || 'attached';
  const fetchedRemotes = Array.isArray(rawWorkerBranch.fetchedRemotes)
    ? rawWorkerBranch.fetchedRemotes.map((entry) => String(entry))
    : [];
  return {
    schema: WORKER_BRANCH_SCHEMA,
    generatedAt: toIso(now),
    runtimeAdapter: adapter.name,
    repository,
    laneId,
    slotId: normalizeText(rawWorkerBranch.slotId) || workerReady?.slotId || null,
    issue: decision?.activeLane?.issue ?? null,
    epic: decision?.activeLane?.epic ?? null,
    forkRemote: normalizeText(rawWorkerBranch.forkRemote) || decision?.activeLane?.forkRemote || null,
    branch,
    checkoutPath,
    status,
    source: normalizeText(rawWorkerBranch.source) || adapter.name,
    reason: normalizeText(rawWorkerBranch.reason) || null,
    baseRef: normalizeText(rawWorkerBranch.baseRef) || null,
    trackingRef: normalizeText(rawWorkerBranch.trackingRef) || null,
    fetchedRemotes,
    readyAt: normalizeText(rawWorkerBranch.readyAt) || workerReady?.readyAt || null,
    activatedAt: normalizeText(rawWorkerBranch.activatedAt) || toIso(now),
    reused: rawWorkerBranch.reused === true || status === 'reused'
  };
}

async function writeWorkerBranch(workerPaths, workerBranch) {
  await mkdir(workerPaths.branchDir, { recursive: true });
  await writeJson(workerPaths.branchLatestPath, workerBranch);
  const lanePath = path.join(workerPaths.branchDir, `${sanitizeSegment(workerBranch.laneId || 'runtime')}.json`);
  await writeJson(lanePath, workerBranch);
  return {
    latestPath: workerPaths.branchLatestPath,
    lanePath
  };
}

function extractExplicitStepOptions(options = {}) {
  return normalizeStepOptions({
    lane: options.lane,
    issue: options.issue,
    epic: options.epic,
    forkRemote: options.forkRemote,
    branch: options.branch,
    prUrl: options.prUrl,
    blockerClass: options.blockerClass,
    reason: options.reason
  });
}

function buildSchedulerDecision({ rawDecision, now, cycle, adapter, repository }) {
  const stepOptions = normalizeStepOptions(rawDecision?.stepOptions || {});
  let outcome = normalizeText(rawDecision?.outcome).toLowerCase();
  if (!SCHEDULER_DECISION_OUTCOMES.has(outcome)) {
    outcome = hasStepContext(stepOptions) ? 'selected' : 'idle';
  }
  if (outcome === 'selected' && !hasStepContext(stepOptions)) {
    outcome = 'idle';
  }

  return {
    schema: SCHEDULER_DECISION_SCHEMA,
    generatedAt: toIso(now),
    cycle,
    runtimeAdapter: adapter.name,
    repository,
    source: normalizeText(rawDecision?.source) || 'runtime-harness',
    outcome,
    reason: normalizeText(rawDecision?.reason) || null,
    stepOptions: hasStepContext(stepOptions) ? stepOptions : null,
    activeLane: summarizeStepOptions(stepOptions),
    artifacts: rawDecision?.artifacts && typeof rawDecision.artifacts === 'object' ? rawDecision.artifacts : {}
  };
}

async function resolveSchedulerDecision({
  options,
  deps,
  adapter,
  repoRoot,
  repository,
  now,
  cycle,
  heartbeatPath,
  schedulerPaths,
  previousDecision,
  previousStep
}) {
  const explicitStepOptions = extractExplicitStepOptions(options);
  const planner =
    typeof deps.resolveScheduledStepFn === 'function'
      ? deps.resolveScheduledStepFn
      : (typeof adapter.planStep === 'function' ? (context) => adapter.planStep(context) : null);

  if (!planner) {
    return buildSchedulerDecision({
      rawDecision: {
        source: 'manual',
        outcome: hasStepContext(explicitStepOptions) ? 'selected' : 'idle',
        reason: hasStepContext(explicitStepOptions)
          ? 'using explicit observer lane input'
          : 'no scheduler hook and no explicit observer lane input',
        stepOptions: explicitStepOptions
      },
      now,
      cycle,
      adapter,
      repository
    });
  }

  const rawDecision = await planner({
    options,
    env: process.env,
    repoRoot,
    deps,
    adapter,
    repository,
    cycle,
    heartbeatPath,
    schedulerPaths,
    previousDecision,
    previousStep,
    explicitStepOptions
  });
  return buildSchedulerDecision({
    rawDecision,
    now,
    cycle,
    adapter,
    repository
  });
}

async function writeSchedulerDecision(schedulerPaths, decision) {
  await writeJson(schedulerPaths.latestPath, decision);
  const historyPath = path.join(
    schedulerPaths.historyDir,
    makeDecisionFileName(new Date(decision.generatedAt), decision.cycle)
  );
  await writeJson(historyPath, decision);
  return {
    latestPath: schedulerPaths.latestPath,
    historyPath
  };
}

function buildWorkerStepOptions(options, decision) {
  const workerOptions = { ...options };
  for (const key of SCHEDULER_STEP_OPTION_KEYS) {
    delete workerOptions[key];
  }
  if (decision?.stepOptions) {
    Object.assign(workerOptions, decision.stepOptions);
  }
  return workerOptions;
}

function buildDecisionSummary(decision, artifacts) {
  return {
    source: decision.source,
    outcome: decision.outcome,
    reason: decision.reason,
    activeLane: decision.activeLane,
    latestPath: artifacts.latestPath,
    historyPath: artifacts.historyPath
  };
}

function normalizeHelperCommands(list) {
  return Array.isArray(list)
    ? list.map((entry) => normalizeText(entry)).filter(Boolean)
    : [];
}

function determineTaskPacketStatus({ schedulerDecision, preparedWorker, workerReady, workerBranch }) {
  if (
    preparedWorker?.status === 'blocked' ||
    workerReady?.status === 'blocked' ||
    workerBranch?.status === 'blocked' ||
    schedulerDecision?.outcome === 'blocked'
  ) {
    return 'blocked';
  }
  if (schedulerDecision?.outcome === 'idle') {
    return 'idle';
  }
  if (workerBranch?.status) {
    return 'ready';
  }
  if (workerReady?.status) {
    return 'prepared';
  }
  if (preparedWorker?.status) {
    return 'selected';
  }
  return normalizeText(schedulerDecision?.outcome) || 'idle';
}

function buildDefaultTaskObjective(schedulerDecision) {
  const activeLane = schedulerDecision?.activeLane ?? null;
  if (Number.isInteger(activeLane?.issue)) {
    const branch = normalizeText(activeLane.branch);
    const laneTarget = branch || normalizeText(activeLane.laneId) || `issue-${activeLane.issue}`;
    return {
      summary: `Advance issue #${activeLane.issue} on ${laneTarget}`,
      source: normalizeText(schedulerDecision?.source) || 'runtime-harness'
    };
  }
  return {
    summary: normalizeText(schedulerDecision?.reason) || 'No active lane selected for this worker cycle.',
    source: normalizeText(schedulerDecision?.source) || 'runtime-harness'
  };
}

function summarizeExecutionReceipt(executionReceipt) {
  if (!executionReceipt) return null;
  return {
    cycle: executionReceipt.cycle ?? null,
    status: executionReceipt.status ?? null,
    outcome: executionReceipt.outcome ?? null,
    generatedAt: executionReceipt.generatedAt ?? null,
    stopLoop: executionReceipt.stopLoop === true,
    details: executionReceipt.details ?? {},
    artifacts: executionReceipt.artifacts ?? {}
  };
}

function normalizeExecutionReceipt(executionReceipt, { now, adapter, repository, cycle, schedulerDecision }) {
  if (!executionReceipt || typeof executionReceipt !== 'object') {
    return null;
  }
  const details =
    executionReceipt.details && typeof executionReceipt.details === 'object' ? executionReceipt.details : {};
  return {
    schema: EXECUTION_RECEIPT_SCHEMA,
    generatedAt: normalizeText(executionReceipt.generatedAt) || toIso(now),
    cycle: Number.isInteger(executionReceipt.cycle) ? executionReceipt.cycle : cycle,
    runtimeAdapter: adapter.name,
    repository,
    laneId: normalizeText(executionReceipt.laneId) || schedulerDecision?.activeLane?.laneId || null,
    issue:
      coercePositiveInteger(executionReceipt.issue) ??
      coercePositiveInteger(schedulerDecision?.activeLane?.issue) ??
      null,
    status: normalizeText(executionReceipt.status).toLowerCase() || 'completed',
    outcome: normalizeText(executionReceipt.outcome) || 'completed',
    reason: normalizeText(executionReceipt.reason) || null,
    source: normalizeText(executionReceipt.source) || adapter.name,
    stopLoop: executionReceipt.stopLoop === true,
    details,
    artifacts: executionReceipt.artifacts && typeof executionReceipt.artifacts === 'object' ? executionReceipt.artifacts : {}
  };
}

function resolvePollIntervalSeconds(options, executionReceipt) {
  const configuredSeconds = Number.isInteger(options?.pollIntervalSeconds) ? options.pollIntervalSeconds : undefined;
  let defaultSeconds =
    typeof configuredSeconds === 'number' && configuredSeconds > 0
      ? configuredSeconds
      : DEFAULT_POLL_INTERVAL_SECONDS;
  if (!Number.isFinite(defaultSeconds) || defaultSeconds <= 0) {
    defaultSeconds = 1;
  }
  const hintedSeconds = Number(executionReceipt?.details?.pollIntervalSecondsHint);
  if (!Number.isFinite(hintedSeconds) || hintedSeconds <= 0) {
    return defaultSeconds;
  }
  return Math.min(defaultSeconds, Math.max(1, Math.floor(hintedSeconds)));
}

async function writeExecutionReceipt(executionPaths, executionReceipt) {
  await mkdir(executionPaths.historyDir, { recursive: true });
  const historyPath = path.join(
    executionPaths.historyDir,
    makeDecisionFileName(new Date(executionReceipt.generatedAt), executionReceipt.cycle ?? 0)
  );
  const persistedExecutionReceipt = {
    ...executionReceipt,
    artifacts: {
      ...(executionReceipt.artifacts ?? {}),
      latestPath: executionPaths.latestPath,
      historyPath
    }
  };
  await writeJson(executionPaths.latestPath, persistedExecutionReceipt);
  await writeJson(historyPath, persistedExecutionReceipt);
  return {
    latestPath: executionPaths.latestPath,
    historyPath,
    executionReceipt: persistedExecutionReceipt
  };
}

function buildObservedActiveLane(schedulerDecision, preparedWorker, workerReady, workerBranch, taskPacket, executionReceipt) {
  if (!schedulerDecision?.activeLane) return null;
  const activeLane = {
    ...schedulerDecision.activeLane
  };
  if (preparedWorker) {
    activeLane.worker = preparedWorker;
  }
  if (workerReady) {
    activeLane.workerReady = workerReady;
  }
  if (workerBranch) {
    activeLane.workerBranch = workerBranch;
  }
  if (taskPacket) {
    activeLane.taskPacket = {
      cycle: taskPacket.cycle,
      status: taskPacket.status,
      objective: taskPacket.objective,
      generatedAt: taskPacket.generatedAt,
      artifacts: taskPacket.artifacts ?? {}
    };
  }
  if (executionReceipt) {
    activeLane.execution = summarizeExecutionReceipt(executionReceipt);
  }
  return activeLane;
}

function buildObserverArtifacts({
  runtimeArtifactPaths,
  workerArtifacts,
  workerReadyArtifacts,
  workerBranchArtifacts,
  schedulerArtifacts,
  taskPacketArtifacts,
  executionArtifacts,
  includeRuntimeState = false
}) {
  return {
    statePath: includeRuntimeState ? runtimeArtifactPaths.statePath : null,
    eventsPath: includeRuntimeState ? runtimeArtifactPaths.eventsPath : null,
    stopRequestPath: includeRuntimeState ? runtimeArtifactPaths.stopRequestPath : null,
    workerCheckoutPath: workerArtifacts.latestPath,
    workerLanePath: workerArtifacts.lanePath,
    workerReadyPath: workerReadyArtifacts.latestPath,
    workerReadyLanePath: workerReadyArtifacts.lanePath,
    workerBranchPath: workerBranchArtifacts.latestPath,
    workerBranchLanePath: workerBranchArtifacts.lanePath,
    schedulerDecisionPath: schedulerArtifacts.latestPath,
    schedulerDecisionHistoryPath: schedulerArtifacts.historyPath,
    taskPacketPath: taskPacketArtifacts.latestPath,
    taskPacketHistoryPath: taskPacketArtifacts.historyPath,
    executionReceiptPath: executionArtifacts.latestPath,
    executionReceiptHistoryPath: executionArtifacts.historyPath
  };
}

async function buildTaskPacket({
  options,
  deps,
  adapter,
  repoRoot,
  repository,
  cycle,
  heartbeatPath,
  runtimeArtifactPaths,
  schedulerArtifacts,
  taskPacketPaths,
  schedulerDecision,
  preparedWorker,
  workerReady,
  workerBranch,
  workerArtifacts,
  workerReadyArtifacts,
  workerBranchArtifacts,
  previousDecision,
  previousStep,
  now
}) {
  const activeLane = schedulerDecision?.activeLane ?? null;
  const taskPacketHook =
    typeof deps.buildTaskPacketFn === 'function'
      ? deps.buildTaskPacketFn
      : (typeof adapter.buildTaskPacket === 'function' ? (context) => adapter.buildTaskPacket(context) : null);
  const recentEvents = await readRecentEvents(runtimeArtifactPaths.eventsPath, 5);
  const packet = {
    schema: TASK_PACKET_SCHEMA,
    generatedAt: toIso(now),
    cycle,
    runtimeAdapter: adapter.name,
    repository,
    laneId: activeLane?.laneId ?? null,
    status: determineTaskPacketStatus({
      schedulerDecision,
      preparedWorker,
      workerReady,
      workerBranch
    }),
    source: normalizeText(schedulerDecision?.source) || adapter.name,
    objective: buildDefaultTaskObjective(schedulerDecision),
    branch: {
      name: normalizeText(workerBranch?.branch) || normalizeText(activeLane?.branch) || null,
      forkRemote: normalizeText(workerBranch?.forkRemote) || normalizeText(activeLane?.forkRemote) || null,
      status:
        normalizeText(workerBranch?.status) ||
        normalizeText(workerReady?.status) ||
        normalizeText(preparedWorker?.status) ||
        (activeLane ? 'selected' : 'idle'),
      trackingRef: normalizeText(workerBranch?.trackingRef) || null,
      checkoutPath:
        normalizeText(workerBranch?.checkoutPath) ||
        normalizeText(workerReady?.checkoutPath) ||
        normalizeText(preparedWorker?.checkoutPath) ||
        null
    },
    pullRequest: {
      url: normalizeText(activeLane?.prUrl) || null,
      status: normalizeText(activeLane?.prUrl) ? 'linked' : 'none'
    },
    checks: {
      status: activeLane?.blockerClass === 'ci' ? 'blocked' : normalizeText(activeLane?.prUrl) ? 'pending-or-unknown' : 'not-linked',
      blockerClass: normalizeText(activeLane?.blockerClass) || 'none'
    },
    helperSurface: {
      preferred: [],
      fallbacks: []
    },
    recentEvents,
    evidence: {
      runtime: {
        runtimeDir: runtimeArtifactPaths.runtimeDir,
        heartbeatPath,
        statePath: runtimeArtifactPaths.statePath,
        eventsPath: runtimeArtifactPaths.eventsPath,
        stopRequestPath: runtimeArtifactPaths.stopRequestPath
      },
      scheduler: {
        latestPath: schedulerArtifacts.latestPath,
        historyPath: schedulerArtifacts.historyPath,
        sourceArtifacts: schedulerDecision?.artifacts ?? {}
      },
      worker: {
        checkoutPath: workerArtifacts.latestPath,
        checkoutLanePath: workerArtifacts.lanePath,
        readyPath: workerReadyArtifacts.latestPath,
        readyLanePath: workerReadyArtifacts.lanePath,
        branchPath: workerBranchArtifacts.latestPath,
        branchLanePath: workerBranchArtifacts.lanePath
      }
    },
    artifacts: {}
  };

  if (taskPacketHook) {
    const adapterPacket = await taskPacketHook({
      options,
      env: process.env,
      repoRoot,
      deps,
      adapter,
      repository,
      cycle,
      heartbeatPath,
      runtimeArtifactPaths,
      schedulerArtifacts,
      taskPacketPaths,
      schedulerDecision,
      preparedWorker,
      workerReady,
      workerBranch,
      workerArtifacts,
      workerReadyArtifacts,
      workerBranchArtifacts,
      previousDecision,
      previousStep,
      now,
      recentEvents
    });
    if (adapterPacket && typeof adapterPacket === 'object') {
      const objective = adapterPacket.objective && typeof adapterPacket.objective === 'object' ? adapterPacket.objective : {};
      const branch = adapterPacket.branch && typeof adapterPacket.branch === 'object' ? adapterPacket.branch : {};
      const pullRequest =
        adapterPacket.pullRequest && typeof adapterPacket.pullRequest === 'object' ? adapterPacket.pullRequest : {};
      const checks = adapterPacket.checks && typeof adapterPacket.checks === 'object' ? adapterPacket.checks : {};
      const evidence = adapterPacket.evidence && typeof adapterPacket.evidence === 'object' ? adapterPacket.evidence : {};
      packet.source = normalizeText(adapterPacket.source) || packet.source;
      packet.status = normalizeText(adapterPacket.status).toLowerCase() || packet.status;
      packet.objective = {
        summary: normalizeText(objective.summary) || packet.objective.summary,
        source: normalizeText(objective.source) || packet.objective.source
      };
      packet.branch = {
        ...packet.branch,
        name: normalizeText(branch.name) || packet.branch.name,
        forkRemote: normalizeText(branch.forkRemote) || packet.branch.forkRemote,
        status: normalizeText(branch.status) || packet.branch.status,
        trackingRef: normalizeText(branch.trackingRef) || packet.branch.trackingRef,
        checkoutPath: normalizeText(branch.checkoutPath) || packet.branch.checkoutPath
      };
      packet.pullRequest = {
        url: normalizeText(pullRequest.url) || packet.pullRequest.url,
        status: normalizeText(pullRequest.status) || packet.pullRequest.status
      };
      packet.checks = {
        status: normalizeText(checks.status) || packet.checks.status,
        blockerClass: normalizeText(checks.blockerClass) || packet.checks.blockerClass
      };
      packet.helperSurface = {
        preferred: normalizeHelperCommands(adapterPacket.helperSurface?.preferred),
        fallbacks: normalizeHelperCommands(adapterPacket.helperSurface?.fallbacks)
      };
      packet.recentEvents = Array.isArray(adapterPacket.recentEvents) ? adapterPacket.recentEvents : packet.recentEvents;
      packet.evidence = {
        ...packet.evidence,
        ...evidence
      };
    }
  }

  return packet;
}

async function writeTaskPacket(taskPacketPaths, taskPacket) {
  await mkdir(taskPacketPaths.historyDir, { recursive: true });
  const historyPath = path.join(
    taskPacketPaths.historyDir,
    makeDecisionFileName(new Date(taskPacket.generatedAt), taskPacket.cycle ?? 0)
  );
  const persistedTaskPacket = {
    ...taskPacket,
    artifacts: {
      ...(taskPacket.artifacts ?? {}),
      latestPath: taskPacketPaths.latestPath,
      historyPath
    }
  };
  await writeJson(taskPacketPaths.latestPath, persistedTaskPacket);
  await writeJson(historyPath, persistedTaskPacket);
  return {
    latestPath: taskPacketPaths.latestPath,
    historyPath,
    taskPacket: persistedTaskPacket
  };
}

export function parseObserverArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: '',
    runtimeDir: DEFAULT_RUNTIME_DIR,
    heartbeatPath: '',
    schedulerDecisionPath: '',
    schedulerDecisionsDir: '',
    lane: '',
    issue: null,
    epic: null,
    forkRemote: '',
    branch: '',
    prUrl: '',
    blockerClass: 'none',
    reason: '',
    leaseScope: 'workspace',
    leaseRoot: '',
    owner: '',
    pollIntervalSeconds: DEFAULT_POLL_INTERVAL_SECONDS,
    maxCycles: 0,
    stopOnIdle: false,
    executeTurn: false,
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
    if (token === '--stop-on-idle') {
      options.stopOnIdle = true;
      continue;
    }
    if (token === '--execute-turn') {
      options.executeTurn = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--runtime-dir' ||
      token === '--heartbeat-path' ||
      token === '--scheduler-decision-path' ||
      token === '--scheduler-decisions-dir' ||
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
      token === '--owner' ||
      token === '--poll-interval-seconds' ||
      token === '--max-cycles'
    ) {
      if (next === undefined || (next.startsWith('-') && token !== '--reason')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') {
        options.repo = normalizeText(next);
      } else if (token === '--runtime-dir') {
        options.runtimeDir = normalizeText(next);
      } else if (token === '--heartbeat-path') {
        options.heartbeatPath = normalizeText(next);
      } else if (token === '--scheduler-decision-path') {
        options.schedulerDecisionPath = normalizeText(next);
      } else if (token === '--scheduler-decisions-dir') {
        options.schedulerDecisionsDir = normalizeText(next);
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
        options.leaseScope = normalizeText(next) || 'workspace';
      } else if (token === '--lease-root') {
        options.leaseRoot = normalizeText(next);
      } else if (token === '--owner') {
        options.owner = normalizeText(next);
      } else if (token === '--poll-interval-seconds') {
        options.pollIntervalSeconds = toPositiveInteger(next, { label: '--poll-interval-seconds', allowZero: true });
      } else if (token === '--max-cycles') {
        options.maxCycles = toPositiveInteger(next, { label: '--max-cycles', allowZero: true });
      }
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.blockerClass && !BLOCKER_CLASSES.has(options.blockerClass)) {
    throw new Error(`Unsupported --blocker-class '${options.blockerClass}'.`);
  }

  return options;
}

export async function runRuntimeObserverLoop(options = {}, deps = {}) {
  const platform = deps.platform ?? process.platform;
  const adapter = createRuntimeAdapter(deps.adapter ?? {});
  const repoRoot = resolveRepoRoot(options, deps, adapter);
  const heartbeatPath = resolveHeartbeatPath(options, repoRoot);
  const runtimeArtifactPaths = resolveRuntimeArtifactPaths(options, repoRoot);
  const schedulerPaths = resolveSchedulerPaths(options, repoRoot);
  const workerPaths = resolveWorkerPaths(options, repoRoot);
  const taskPacketPaths = resolveTaskPacketPaths(options, repoRoot);
  const executionPaths = resolveExecutionPaths(options, repoRoot);
  const nowFactory = deps.nowFactory ?? (() => deps.now ?? new Date());
  const sleepFn = deps.sleepFn ?? sleep;

  const report = {
    schema: OBSERVER_REPORT_SCHEMA,
    generatedAt: toIso(nowFactory()),
    runtimeAdapter: adapter.name,
    repository:
      typeof adapter.resolveRepository === 'function'
        ? adapter.resolveRepository({ options, env: process.env, repoRoot, deps, adapter })
        : normalizeText(options.repo) || process.env.GITHUB_REPOSITORY || 'unknown/unknown',
    heartbeatPath,
    scheduler: {
      latestPath: schedulerPaths.latestPath,
      historyDir: schedulerPaths.historyDir
    },
    worker: {
      latestPath: workerPaths.latestPath,
      workersDir: workerPaths.workersDir,
      readyLatestPath: workerPaths.readyLatestPath,
      readyDir: workerPaths.readyDir,
      branchLatestPath: workerPaths.branchLatestPath,
      branchDir: workerPaths.branchDir
    },
    taskPackets: {
      latestPath: taskPacketPaths.latestPath,
      historyDir: taskPacketPaths.historyDir
    },
    execution: {
      latestPath: executionPaths.latestPath,
      historyDir: executionPaths.historyDir
    },
    status: 'pass',
    outcome: 'idle',
    cyclesCompleted: 0,
    lastDecision: null,
    lastStep: null
  };

  if (platform !== 'linux') {
    report.status = 'blocked';
    report.outcome = 'linux-only';
    report.message = 'Observer daemon mode is supported only on Linux.';
    return { exitCode: 2, report };
  }

  let previousDecision = null;
  let previousStep = null;
  while (true) {
    const cycle = report.cyclesCompleted + 1;
    const stepNow = nowFactory();
    let schedulerDecision;
    try {
      schedulerDecision = await resolveSchedulerDecision({
        options,
        deps,
        adapter,
        repoRoot,
        repository: report.repository,
        now: stepNow,
        cycle,
        heartbeatPath,
        schedulerPaths,
        previousDecision,
        previousStep
      });
    } catch (error) {
      report.status = 'blocked';
      report.outcome = 'scheduler-failed';
      report.message = error?.message || String(error);
      return { exitCode: 11, report };
    }

    const schedulerArtifacts = await writeSchedulerDecision(schedulerPaths, schedulerDecision);
    report.lastDecision = buildDecisionSummary(schedulerDecision, schedulerArtifacts);
    let taskPacket = null;
    let taskPacketArtifacts = {
      latestPath: null,
      historyPath: null
    };
    let executionReceipt = null;
    let executionArtifacts = {
      latestPath: null,
      historyPath: null
    };

    if (schedulerDecision.outcome !== 'selected') {
      const taskPacketRecord = await buildTaskPacket({
        options,
        deps,
        adapter,
        repoRoot,
        repository: report.repository,
        cycle,
        heartbeatPath,
        runtimeArtifactPaths,
        schedulerArtifacts,
        taskPacketPaths,
        schedulerDecision,
        preparedWorker: null,
        workerReady: null,
        workerBranch: null,
        workerArtifacts: {
          latestPath: null,
          lanePath: null
        },
        workerReadyArtifacts: {
          latestPath: null,
          lanePath: null
        },
        workerBranchArtifacts: {
          latestPath: null,
          lanePath: null
        },
        previousDecision,
        previousStep,
        now: stepNow
      });
      const persistedTaskPacket = await writeTaskPacket(taskPacketPaths, taskPacketRecord);
      taskPacket = persistedTaskPacket.taskPacket;
      taskPacketArtifacts = {
        latestPath: persistedTaskPacket.latestPath,
        historyPath: persistedTaskPacket.historyPath
      };

      if (options.stopOnIdle && schedulerDecision.outcome === 'idle') {
        const heartbeatNow = nowFactory();
        report.lastStep = {
          exitCode: 0,
          outcome: 'idle',
          statePath: null,
          turnPath: null,
          taskPacket
        };
        await writeJson(heartbeatPath, {
          schema: OBSERVER_HEARTBEAT_SCHEMA,
          generatedAt: toIso(heartbeatNow),
          runtimeAdapter: adapter.name,
          repository: report.repository,
          platform,
          cyclesCompleted: report.cyclesCompleted,
          outcome: 'idle-stop',
          stopRequested: false,
          activeLane: buildObservedActiveLane(schedulerDecision, null, null, null, taskPacket, null),
          schedulerDecision: report.lastDecision,
          artifacts: buildObserverArtifacts({
            runtimeArtifactPaths,
            workerArtifacts: { latestPath: null, lanePath: null },
            workerReadyArtifacts: { latestPath: null, lanePath: null },
            workerBranchArtifacts: { latestPath: null, lanePath: null },
            schedulerArtifacts,
            taskPacketArtifacts,
            executionArtifacts
          })
        });
        report.outcome = 'idle-stop';
        return { exitCode: 0, report };
      }
    }

    if (schedulerDecision.outcome === 'blocked') {
      const heartbeatNow = nowFactory();
      await writeJson(heartbeatPath, {
        schema: OBSERVER_HEARTBEAT_SCHEMA,
        generatedAt: toIso(heartbeatNow),
        runtimeAdapter: adapter.name,
        repository: report.repository,
        platform,
        cyclesCompleted: report.cyclesCompleted,
        outcome: 'scheduler-blocked',
        stopRequested: false,
        activeLane: buildObservedActiveLane(schedulerDecision, null, null, null, taskPacket, null),
        schedulerDecision: report.lastDecision,
        artifacts: buildObserverArtifacts({
          runtimeArtifactPaths,
          workerArtifacts: { latestPath: null, lanePath: null },
          workerReadyArtifacts: { latestPath: null, lanePath: null },
          workerBranchArtifacts: { latestPath: null, lanePath: null },
          schedulerArtifacts,
          taskPacketArtifacts,
          executionArtifacts
        })
      });
      report.status = 'blocked';
      report.outcome = 'scheduler-blocked';
      report.lastStep = {
        exitCode: 12,
        outcome: 'scheduler-blocked',
        statePath: null,
        turnPath: null,
        taskPacket
      };
      return { exitCode: 12, report };
    }

    let preparedWorker = null;
    let workerArtifacts = {
      latestPath: null,
      lanePath: null
    };
    let workerReady = null;
    let workerReadyArtifacts = {
      latestPath: null,
      lanePath: null
    };
    let workerBranch = null;
    let workerBranchArtifacts = {
      latestPath: null,
      lanePath: null
    };
    const prepareWorkerFn =
      typeof deps.prepareWorkerFn === 'function'
        ? deps.prepareWorkerFn
        : (typeof adapter.prepareWorker === 'function' ? (context) => adapter.prepareWorker(context) : null);
    if (prepareWorkerFn && schedulerDecision.outcome === 'selected') {
      try {
        preparedWorker = normalizeWorkerCheckout(
          await prepareWorkerFn({
            options,
            env: process.env,
            repoRoot,
            deps,
            adapter,
            repository: report.repository,
            cycle,
            heartbeatPath,
            schedulerPaths,
            workerPaths,
            schedulerDecision,
            previousDecision,
            previousStep
          }),
          schedulerDecision,
          stepNow,
          adapter,
          report.repository
        );
      } catch (error) {
        report.status = 'blocked';
        report.outcome = 'worker-prepare-failed';
        report.message = error?.message || String(error);
        return { exitCode: 13, report };
      }
      if (preparedWorker) {
        workerArtifacts = await writeWorkerCheckout(workerPaths, preparedWorker);
        preparedWorker.artifacts = {
          latestPath: workerArtifacts.latestPath,
          lanePath: workerArtifacts.lanePath
        };
      }
      if (preparedWorker?.status === 'blocked') {
        const heartbeatNow = nowFactory();
        await writeJson(heartbeatPath, {
          schema: OBSERVER_HEARTBEAT_SCHEMA,
          generatedAt: toIso(heartbeatNow),
          runtimeAdapter: adapter.name,
          repository: report.repository,
          platform,
          cyclesCompleted: report.cyclesCompleted,
          outcome: 'worker-blocked',
          stopRequested: false,
          activeLane: {
            ...(schedulerDecision.activeLane ?? {}),
            worker: preparedWorker
          },
          schedulerDecision: report.lastDecision,
          artifacts: {
            statePath: null,
            eventsPath: null,
            stopRequestPath: null,
            workerCheckoutPath: workerArtifacts.latestPath,
            workerLanePath: workerArtifacts.lanePath,
            workerReadyPath: null,
            workerReadyLanePath: null,
            workerBranchPath: null,
            workerBranchLanePath: null,
            schedulerDecisionPath: schedulerArtifacts.latestPath,
            schedulerDecisionHistoryPath: schedulerArtifacts.historyPath
          }
        });
        report.status = 'blocked';
        report.outcome = 'worker-blocked';
        report.lastStep = {
          exitCode: 13,
          outcome: 'worker-blocked',
          statePath: null,
          turnPath: null,
          worker: preparedWorker
        };
        return { exitCode: 13, report };
      }
    }

    const bootstrapWorkerFn =
      typeof deps.bootstrapWorkerFn === 'function'
        ? deps.bootstrapWorkerFn
        : (typeof adapter.bootstrapWorker === 'function' ? (context) => adapter.bootstrapWorker(context) : null);
    if (bootstrapWorkerFn && preparedWorker?.status && preparedWorker.status !== 'blocked') {
      try {
        workerReady = normalizeWorkerReady(
          await bootstrapWorkerFn({
            options,
            env: process.env,
            repoRoot,
            deps,
            adapter,
            repository: report.repository,
            cycle,
            heartbeatPath,
            schedulerPaths,
            workerPaths,
            schedulerDecision,
            preparedWorker,
            previousDecision,
            previousStep
          }),
          schedulerDecision,
          preparedWorker,
          stepNow,
          adapter,
          report.repository
        );
      } catch (error) {
        const heartbeatNow = nowFactory();
        await writeJson(heartbeatPath, {
          schema: OBSERVER_HEARTBEAT_SCHEMA,
          generatedAt: toIso(heartbeatNow),
          runtimeAdapter: adapter.name,
          repository: report.repository,
          platform,
          cyclesCompleted: report.cyclesCompleted,
          outcome: 'worker-bootstrap-failed',
          stopRequested: false,
          activeLane: {
            ...(schedulerDecision.activeLane ?? {}),
            worker: preparedWorker
          },
          schedulerDecision: report.lastDecision,
          artifacts: {
            statePath: null,
            eventsPath: null,
            stopRequestPath: null,
            workerCheckoutPath: workerArtifacts.latestPath,
            workerLanePath: workerArtifacts.lanePath,
            workerReadyPath: null,
            workerReadyLanePath: null,
            schedulerDecisionPath: schedulerArtifacts.latestPath,
            schedulerDecisionHistoryPath: schedulerArtifacts.historyPath
          }
        });
        report.status = 'blocked';
        report.outcome = 'worker-bootstrap-failed';
        report.message = error?.message || String(error);
        report.lastStep = {
          exitCode: 14,
          outcome: 'worker-bootstrap-failed',
          statePath: null,
          turnPath: null,
          worker: preparedWorker,
          workerReady: null
        };
        return { exitCode: 14, report };
      }
      if (workerReady) {
        workerReadyArtifacts = await writeWorkerReady(workerPaths, workerReady);
        workerReady.artifacts = {
          latestPath: workerReadyArtifacts.latestPath,
          lanePath: workerReadyArtifacts.lanePath
        };
      }
      if (workerReady?.status === 'blocked') {
        const heartbeatNow = nowFactory();
        await writeJson(heartbeatPath, {
          schema: OBSERVER_HEARTBEAT_SCHEMA,
          generatedAt: toIso(heartbeatNow),
          runtimeAdapter: adapter.name,
          repository: report.repository,
          platform,
          cyclesCompleted: report.cyclesCompleted,
          outcome: 'worker-ready-blocked',
          stopRequested: false,
          activeLane: {
            ...(schedulerDecision.activeLane ?? {}),
            worker: preparedWorker,
            workerReady
          },
          schedulerDecision: report.lastDecision,
          artifacts: {
            statePath: null,
            eventsPath: null,
            stopRequestPath: null,
            workerCheckoutPath: workerArtifacts.latestPath,
            workerLanePath: workerArtifacts.lanePath,
            workerReadyPath: workerReadyArtifacts.latestPath,
            workerReadyLanePath: workerReadyArtifacts.lanePath,
            workerBranchPath: null,
            workerBranchLanePath: null,
            schedulerDecisionPath: schedulerArtifacts.latestPath,
            schedulerDecisionHistoryPath: schedulerArtifacts.historyPath
          }
        });
        report.status = 'blocked';
        report.outcome = 'worker-ready-blocked';
        report.lastStep = {
          exitCode: 14,
          outcome: 'worker-ready-blocked',
          statePath: null,
          turnPath: null,
          worker: preparedWorker,
          workerReady
        };
        return { exitCode: 14, report };
      }
    }

    const activateWorkerFn =
      typeof deps.activateWorkerFn === 'function'
        ? deps.activateWorkerFn
        : (typeof adapter.activateWorker === 'function' ? (context) => adapter.activateWorker(context) : null);
    if (activateWorkerFn && workerReady?.status && workerReady.status !== 'blocked') {
      try {
        workerBranch = normalizeWorkerBranch(
          await activateWorkerFn({
            options,
            env: process.env,
            repoRoot,
            deps,
            adapter,
            repository: report.repository,
            cycle,
            heartbeatPath,
            schedulerPaths,
            workerPaths,
            schedulerDecision,
            preparedWorker,
            workerReady,
            previousDecision,
            previousStep
          }),
          schedulerDecision,
          workerReady,
          stepNow,
          adapter,
          report.repository
        );
      } catch (error) {
        report.status = 'blocked';
        report.outcome = 'worker-activate-failed';
        report.message = error?.message || String(error);
        return { exitCode: 15, report };
      }
      if (workerBranch) {
        workerBranchArtifacts = await writeWorkerBranch(workerPaths, workerBranch);
        workerBranch.artifacts = {
          latestPath: workerBranchArtifacts.latestPath,
          lanePath: workerBranchArtifacts.lanePath
        };
      }
    }

    if (schedulerDecision.outcome === 'selected') {
      const taskPacketRecord = await buildTaskPacket({
        options,
        deps,
        adapter,
        repoRoot,
        repository: report.repository,
        cycle,
        heartbeatPath,
        runtimeArtifactPaths,
        schedulerArtifacts,
        taskPacketPaths,
        schedulerDecision,
        preparedWorker,
        workerReady,
        workerBranch,
        workerArtifacts,
        workerReadyArtifacts,
        workerBranchArtifacts,
        previousDecision,
        previousStep,
        now: stepNow
      });
      const persistedTaskPacket = await writeTaskPacket(taskPacketPaths, taskPacketRecord);
      taskPacket = persistedTaskPacket.taskPacket;
      taskPacketArtifacts = {
        latestPath: persistedTaskPacket.latestPath,
        historyPath: persistedTaskPacket.historyPath
      };
    }

    if (workerBranch?.status === 'blocked') {
      const heartbeatNow = nowFactory();
      await writeJson(heartbeatPath, {
        schema: OBSERVER_HEARTBEAT_SCHEMA,
        generatedAt: toIso(heartbeatNow),
        runtimeAdapter: adapter.name,
        repository: report.repository,
        platform,
        cyclesCompleted: report.cyclesCompleted,
        outcome: 'worker-branch-blocked',
        stopRequested: false,
        activeLane: buildObservedActiveLane(schedulerDecision, preparedWorker, workerReady, workerBranch, taskPacket, null),
        schedulerDecision: report.lastDecision,
        artifacts: buildObserverArtifacts({
          runtimeArtifactPaths,
          workerArtifacts,
          workerReadyArtifacts,
          workerBranchArtifacts,
          schedulerArtifacts,
          taskPacketArtifacts,
          executionArtifacts
        })
      });
      report.status = 'blocked';
      report.outcome = 'worker-branch-blocked';
      report.lastStep = {
        exitCode: 15,
        outcome: 'worker-branch-blocked',
        statePath: null,
        turnPath: null,
        worker: preparedWorker,
        workerReady,
        workerBranch,
        taskPacket
      };
      return { exitCode: 15, report };
    }

    const stepResult = await runRuntimeWorkerStep(
      {
        ...buildWorkerStepOptions(options, schedulerDecision),
        worker: preparedWorker,
        workerReady,
        workerBranch,
        taskPacket
      },
      {
        ...deps,
        now: stepNow,
        repoRoot,
        adapter
      }
    );

    report.cyclesCompleted += 1;
    report.lastStep = {
      exitCode: stepResult.exitCode,
      outcome: stepResult.report.outcome,
      statePath: stepResult.report.runtime?.statePath ?? null,
      turnPath: stepResult.report.turnPath ?? null,
      worker: stepResult.report.worker ?? preparedWorker,
      workerReady: stepResult.report.workerReady ?? workerReady,
      workerBranch: stepResult.report.workerBranch ?? workerBranch,
      taskPacket: stepResult.report.taskPacket ?? taskPacket
    };

    const executeTurnFn =
      options.executeTurn
        ? typeof deps.executeTurnFn === 'function'
          ? deps.executeTurnFn
          : (typeof adapter.executeTurn === 'function' ? (context) => adapter.executeTurn(context) : null)
        : null;
    if (stepResult.exitCode === 0 && executeTurnFn) {
      try {
        const rawExecutionReceipt = await executeTurnFn({
          options,
          env: process.env,
          repoRoot,
          deps,
          adapter,
          repository: report.repository,
          cycle,
          heartbeatPath,
          runtimeArtifactPaths,
          schedulerPaths,
          workerPaths,
          taskPacketPaths,
          executionPaths,
          schedulerDecision,
          schedulerArtifacts,
          preparedWorker,
          workerReady,
          workerBranch,
          taskPacket,
          taskPacketArtifacts,
          stepResult,
          previousDecision,
          previousStep,
          now: stepNow
        });
        executionReceipt = normalizeExecutionReceipt(rawExecutionReceipt, {
          now: stepNow,
          adapter,
          repository: report.repository,
          cycle,
          schedulerDecision
        });
      } catch (error) {
        const executionErrorMessage = error?.message || String(error);
        report.status = 'blocked';
        report.outcome = 'execution-failed';
        report.message = executionErrorMessage;

        try {
          executionReceipt = normalizeExecutionReceipt(
            {
              status: 'blocked',
              outcome: 'execution-failed',
              reason: executionErrorMessage
            },
            {
              now: stepNow,
              adapter,
              repository: report.repository,
              cycle,
              schedulerDecision
            }
          );
          const persistedExecutionReceipt = await writeExecutionReceipt(executionPaths, executionReceipt);
          executionReceipt = persistedExecutionReceipt.executionReceipt;
          executionArtifacts = {
            latestPath: persistedExecutionReceipt.latestPath,
            historyPath: persistedExecutionReceipt.historyPath
          };
          report.lastStep.execution = summarizeExecutionReceipt(executionReceipt);
        } catch {
          // Ignore receipt persistence failures and preserve the execution error as the primary failure.
        }

        try {
          const heartbeatNow = nowFactory();
          await writeJson(heartbeatPath, {
            schema: OBSERVER_HEARTBEAT_SCHEMA,
            generatedAt: toIso(heartbeatNow),
            runtimeAdapter: adapter.name,
            repository: report.repository,
            platform,
            cyclesCompleted: report.cyclesCompleted,
            outcome: executionReceipt?.outcome || report.outcome,
            stopRequested: Boolean(stepResult.report.state?.lifecycle?.stopRequested),
            activeLane:
              buildObservedActiveLane(
                schedulerDecision,
                stepResult.report.worker ?? preparedWorker,
                stepResult.report.workerReady ?? workerReady,
                stepResult.report.workerBranch ?? workerBranch,
                stepResult.report.taskPacket ?? taskPacket,
                executionReceipt
              ) ?? stepResult.report.state?.activeLane ?? null,
            schedulerDecision: report.lastDecision,
            artifacts: buildObserverArtifacts({
              runtimeArtifactPaths,
              workerArtifacts,
              workerReadyArtifacts,
              workerBranchArtifacts,
              schedulerArtifacts,
              taskPacketArtifacts,
              executionArtifacts,
              includeRuntimeState: true
            })
          });
        } catch {
          // Ignore heartbeat persistence failures and preserve the execution error as the primary failure.
        }

        return { exitCode: 16, report };
      }

      if (executionReceipt) {
        const persistedExecutionReceipt = await writeExecutionReceipt(executionPaths, executionReceipt);
        executionReceipt = persistedExecutionReceipt.executionReceipt;
        executionArtifacts = {
          latestPath: persistedExecutionReceipt.latestPath,
          historyPath: persistedExecutionReceipt.historyPath
        };
        report.lastStep.execution = summarizeExecutionReceipt(executionReceipt);
      }
    }
    previousDecision = schedulerDecision;
    previousStep = report.lastStep;

    const heartbeatNow = nowFactory();
    await writeJson(heartbeatPath, {
      schema: OBSERVER_HEARTBEAT_SCHEMA,
      generatedAt: toIso(heartbeatNow),
      runtimeAdapter: adapter.name,
      repository: report.repository,
      platform,
      cyclesCompleted: report.cyclesCompleted,
      outcome: executionReceipt?.outcome || stepResult.report.outcome,
      stopRequested: Boolean(stepResult.report.state?.lifecycle?.stopRequested),
      activeLane:
        buildObservedActiveLane(
          schedulerDecision,
          stepResult.report.worker ?? preparedWorker,
          stepResult.report.workerReady ?? workerReady,
          stepResult.report.workerBranch ?? workerBranch,
          stepResult.report.taskPacket ?? taskPacket,
          executionReceipt
        ) ?? stepResult.report.state?.activeLane ?? null,
      schedulerDecision: report.lastDecision,
      artifacts: buildObserverArtifacts({
        runtimeArtifactPaths,
        workerArtifacts,
        workerReadyArtifacts,
        workerBranchArtifacts,
        schedulerArtifacts,
        taskPacketArtifacts,
        executionArtifacts,
        includeRuntimeState: true
      })
    });

    if (stepResult.exitCode !== 0) {
      report.status = 'blocked';
      report.outcome = 'worker-failed';
      return { exitCode: stepResult.exitCode, report };
    }

    if (stepResult.report.state?.lifecycle?.stopRequested) {
      report.outcome = 'stop-requested';
      return { exitCode: 0, report };
    }

    if (executionReceipt?.status === 'blocked') {
      report.status = 'blocked';
      report.outcome = executionReceipt.outcome || 'execution-blocked';
      return { exitCode: 16, report };
    }

    if (executionReceipt?.stopLoop) {
      report.outcome = executionReceipt.outcome || 'execution-stop';
      return { exitCode: 0, report };
    }

    if (options.maxCycles > 0 && report.cyclesCompleted >= options.maxCycles) {
      report.outcome = 'max-cycles-reached';
      return { exitCode: 0, report };
    }

    await sleepFn(resolvePollIntervalSeconds(options, executionReceipt) * 1000);
  }
}

export async function runObserverCli(argv = process.argv, deps = {}) {
  const options = parseObserverArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const result = await runRuntimeObserverLoop(options, deps);
  if (!options.quiet) {
    process.stdout.write(`${JSON.stringify(result.report, null, 2)}\n`);
  }
  return result.exitCode;
}

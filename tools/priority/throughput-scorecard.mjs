#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/throughput-scorecard@v1';
export const DEFAULT_RUNTIME_STATE_PATH = path.join('tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json');
export const DEFAULT_DELIVERY_MEMORY_PATH = path.join('tests', 'results', '_agent', 'runtime', 'delivery-memory.json');
export const DEFAULT_QUEUE_REPORT_PATH = path.join('tests', 'results', '_agent', 'queue', 'queue-supervisor-report.json');
export const DEFAULT_CONCURRENT_LANE_STATUS_PATH = path.join('tests', 'results', '_agent', 'runtime', 'concurrent-lane-status-receipt.json');
export const DEFAULT_UTILIZATION_POLICY_PATH = path.join('tools', 'policy', 'merge-queue-utilization-target.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'throughput', 'throughput-scorecard.json');

const HELP = [
  'Usage: node tools/priority/throughput-scorecard.mjs [options]',
  '',
  'Options:',
  `  --runtime-state <path>   Runtime state JSON path (default: ${DEFAULT_RUNTIME_STATE_PATH}).`,
  `  --delivery-memory <path> Delivery memory JSON path (default: ${DEFAULT_DELIVERY_MEMORY_PATH}).`,
  `  --queue-report <path>    Queue supervisor report path (default: ${DEFAULT_QUEUE_REPORT_PATH}).`,
  `  --concurrent-lane-status <path> Concurrent lane status receipt path (default: ${DEFAULT_CONCURRENT_LANE_STATUS_PATH}).`,
  `  --utilization-policy <path> Merge-queue utilization policy path (default: ${DEFAULT_UTILIZATION_POLICY_PATH}).`,
  `  --output <path>          Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --repo <owner/repo>      Repository slug override.',
  '  --help                   Show help.'
];

function printHelp(log = console.log) {
  for (const line of HELP) log(line);
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) return null;
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo) {
  if (normalizeText(explicitRepo).includes('/')) return normalizeText(explicitRepo);
  if (normalizeText(process.env.GITHUB_REPOSITORY).includes('/')) return normalizeText(process.env.GITHUB_REPOSITORY);
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) return slug;
    } catch {
      // ignore
    }
  }
  return null;
}

function loadJsonInput(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    return { path: resolved, exists: false, payload: null, error: null };
  }
  try {
    return { path: resolved, exists: true, payload: JSON.parse(fs.readFileSync(resolved, 'utf8')), error: null };
  } catch (error) {
    return { path: resolved, exists: true, payload: null, error: error.message || String(error) };
  }
}

function coerceNonNegativeNumber(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function clampRatio(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.min(parsed, 1) : null;
}

function evaluateMergeQueueUtilization(queueSummary, policy = null) {
  const mergeQueuePolicy = policy?.mergeQueue && typeof policy.mergeQueue === 'object' ? policy.mergeQueue : {};
  const readyInventoryFloor = Number(mergeQueuePolicy.readyInventoryFloor ?? 2) || 2;
  const occupancyFloorRatio = clampRatio(mergeQueuePolicy.occupancyFloorRatio ?? 0.5) ?? 0.5;
  const occupancyTargetRatio = clampRatio(mergeQueuePolicy.occupancyTargetRatio ?? 1) ?? 1;
  const treatPausedQueueAsExempt = mergeQueuePolicy.treatPausedQueueAsExempt !== false;
  const effectiveMaxInflight = Number(queueSummary.effectiveMaxInflight ?? 0) || 0;
  const inflight = Number(queueSummary.inflight ?? 0) || 0;
  const readyPrInventory = Number(queueSummary.readyPrInventory ?? 0) || 0;
  const occupancyRatio = effectiveMaxInflight > 0 ? Math.min(inflight / effectiveMaxInflight, 1) : null;
  const reasons = [];

  if (!(queueSummary.paused && treatPausedQueueAsExempt) && effectiveMaxInflight > 0) {
    if (readyPrInventory < readyInventoryFloor) {
      reasons.push('merge-queue-ready-inventory-below-floor');
    }
    if ((occupancyRatio ?? 0) < occupancyFloorRatio) {
      reasons.push('merge-queue-occupancy-below-floor');
    }
  }

  return {
    target: {
      readyInventoryFloor,
      occupancyFloorRatio,
      occupancyTargetRatio,
      treatPausedQueueAsExempt
    },
    observed: {
      readyPrInventory,
      inflight,
      effectiveMaxInflight,
      occupancyRatio,
      paused: queueSummary.paused
    },
    status: reasons.length > 0 ? 'warn' : 'pass',
    reasons
  };
}

function summarizeConcurrentLaneStatus(input = null) {
  const payload = input?.payload && typeof input.payload === 'object' ? input.payload : null;
  const summary = payload?.summary && typeof payload.summary === 'object' ? payload.summary : {};
  const orchestratorDisposition = normalizeText(summary.orchestratorDisposition) || null;
  let workerDisposition = 'unknown';
  if (orchestratorDisposition === 'wait-hosted-run') {
    workerDisposition = 'retain';
  } else if (orchestratorDisposition === 'hold-investigate') {
    workerDisposition = 'investigate';
  } else if (orchestratorDisposition && orchestratorDisposition.startsWith('release-')) {
    workerDisposition = 'release';
  }

  return {
    path: input?.path ?? null,
    exists: input?.exists === true,
    error: input?.error ?? null,
    status: normalizeText(payload?.status) || (input?.exists === true ? 'unknown' : 'not-observed'),
    hostedObservationStatus: normalizeText(payload?.hostedRun?.observationStatus) || null,
    pullRequestObservationStatus: normalizeText(payload?.pullRequest?.observationStatus) || null,
    orchestratorDisposition,
    workerDisposition,
    selectedBundleId:
      normalizeText(summary.selectedBundleId) ||
      normalizeText(payload?.applyReceipt?.selectedBundleId) ||
      null,
    laneCount: Number(summary.laneCount ?? 0) || 0,
    activeLaneCount: Number(summary.activeLaneCount ?? 0) || 0,
    completedLaneCount: Number(summary.completedLaneCount ?? 0) || 0,
    failedLaneCount: Number(summary.failedLaneCount ?? 0) || 0,
    blockedLaneCount: Number(summary.blockedLaneCount ?? 0) || 0,
    plannedLaneCount: Number(summary.plannedLaneCount ?? 0) || 0,
    deferredLaneCount: Number(summary.deferredLaneCount ?? 0) || 0,
    manualLaneCount: Number(summary.manualLaneCount ?? 0) || 0,
    shadowLaneCount: Number(summary.shadowLaneCount ?? 0) || 0
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    runtimeStatePath: DEFAULT_RUNTIME_STATE_PATH,
    deliveryMemoryPath: DEFAULT_DELIVERY_MEMORY_PATH,
    queueReportPath: DEFAULT_QUEUE_REPORT_PATH,
    concurrentLaneStatusPath: DEFAULT_CONCURRENT_LANE_STATUS_PATH,
    utilizationPolicyPath: DEFAULT_UTILIZATION_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (['--runtime-state', '--delivery-memory', '--queue-report', '--concurrent-lane-status', '--utilization-policy', '--output', '--repo'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--runtime-state') options.runtimeStatePath = next;
      if (token === '--delivery-memory') options.deliveryMemoryPath = next;
      if (token === '--queue-report') options.queueReportPath = next;
      if (token === '--concurrent-lane-status') options.concurrentLaneStatusPath = next;
      if (token === '--utilization-policy') options.utilizationPolicyPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export function buildThroughputScorecard({
  repository = null,
  runtimeState = null,
  deliveryMemory = null,
  queueReport = null,
  concurrentLaneStatus = null,
  concurrentLaneStatusInput = null,
  utilizationPolicy = null,
  inputPaths = {},
  now = new Date()
}) {
  const workerPool = runtimeState?.workerPool && typeof runtimeState.workerPool === 'object' ? runtimeState.workerPool : {};
  const readySet = Array.isArray(queueReport?.readiness?.readySet) ? queueReport.readiness.readySet : [];
  const workerPoolSummary = {
    targetSlotCount: Number(workerPool.targetSlotCount ?? 0) || 0,
    occupiedSlotCount: Number(workerPool.occupiedSlotCount ?? 0) || 0,
    availableSlotCount: Number(workerPool.availableSlotCount ?? 0) || 0,
    releasedLaneCount: Number(workerPool.releasedLaneCount ?? 0) || 0,
    utilizationRatio: coerceNonNegativeNumber(workerPool.utilizationRatio) ?? 0,
    activeCodingLanes: Number(runtimeState?.activeCodingLanes ?? 0) || 0
  };
  const queueSummary = {
    readyPrInventory: readySet.length,
    inflight: Number(queueReport?.inflight ?? 0) || 0,
    capacity: Number(queueReport?.capacity ?? 0) || 0,
    effectiveMaxInflight: Number(queueReport?.effectiveMaxInflight ?? 0) || 0,
    paused: queueReport?.paused === true,
    throughputMode: normalizeText(queueReport?.throughputController?.mode) || null,
    governorMode: normalizeText(queueReport?.governor?.mode) || null,
    readySetTop: readySet.slice(0, 5).map((entry) => entry.number)
  };
  const deliverySummary = {
    totalTerminalPullRequestCount: Number(deliveryMemory?.summary?.totalTerminalPullRequestCount ?? 0) || 0,
    mergedPullRequestCount: Number(deliveryMemory?.summary?.mergedPullRequestCount ?? 0) || 0,
    closedPullRequestCount: Number(deliveryMemory?.summary?.closedPullRequestCount ?? 0) || 0,
    hostedWaitEscapeCount: Number(deliveryMemory?.summary?.hostedWaitEscapeCount ?? 0) || 0,
    meanTerminalDurationMinutes: coerceNonNegativeNumber(deliveryMemory?.summary?.meanTerminalDurationMinutes),
    viHistorySuitePullRequestCount: Number(deliveryMemory?.summary?.viHistorySuitePullRequestCount ?? 0) || 0
  };
  const mergeQueueUtilization = evaluateMergeQueueUtilization(queueSummary, utilizationPolicy);
  const concurrentLanes = summarizeConcurrentLaneStatus(
    concurrentLaneStatusInput ?? {
      path: inputPaths.concurrentLaneStatusPath ?? null,
      exists: concurrentLaneStatus !== null && concurrentLaneStatus !== undefined,
      error: null,
      payload: concurrentLaneStatus
    }
  );

  const reasons = [];
  if (queueSummary.readyPrInventory > 0 && workerPoolSummary.occupiedSlotCount === 0 && queueSummary.capacity > 0) {
    reasons.push('actionable-work-with-idle-worker-pool');
  }
  const actionableLaneDemand = Math.max(
    queueSummary.readyPrInventory,
    concurrentLanes.activeLaneCount + concurrentLanes.plannedLaneCount
  );
  if (
    workerPoolSummary.occupiedSlotCount > 0
    && workerPoolSummary.availableSlotCount > 0
    && workerPoolSummary.targetSlotCount > workerPoolSummary.occupiedSlotCount
    && actionableLaneDemand > workerPoolSummary.occupiedSlotCount
  ) {
    reasons.push('actionable-work-below-worker-slot-target');
  }
  if (queueSummary.readyPrInventory > 0 && queueSummary.paused) {
    reasons.push('queue-paused-with-ready-inventory');
  }
  reasons.push(...mergeQueueUtilization.reasons);

  const status = reasons.length > 0 ? 'warn' : 'pass';

  return {
    schema: REPORT_SCHEMA,
    generatedAt: toIso(now),
    repository: normalizeText(repository) || null,
    inputs: {
      runtimeStatePath: inputPaths.runtimeStatePath ?? null,
      deliveryMemoryPath: inputPaths.deliveryMemoryPath ?? null,
      queueReportPath: inputPaths.queueReportPath ?? null,
      concurrentLaneStatusPath: inputPaths.concurrentLaneStatusPath ?? null,
      utilizationPolicyPath: inputPaths.utilizationPolicyPath ?? null
    },
    workerPool: workerPoolSummary,
    queue: queueSummary,
    mergeQueueUtilization,
    concurrentLanes,
    delivery: deliverySummary,
    summary: {
      status,
      reasons,
      metrics: {
        currentWorkerUtilizationRatio: workerPoolSummary.utilizationRatio,
        readyPrInventory: queueSummary.readyPrInventory,
        mergeQueueInflight: queueSummary.inflight,
        mergeQueueCapacity: queueSummary.capacity,
        mergeQueueOccupancyRatio: mergeQueueUtilization.observed.occupancyRatio,
        mergeQueueReadyInventoryFloor: mergeQueueUtilization.target.readyInventoryFloor,
        concurrentLaneActiveCount: concurrentLanes.activeLaneCount,
        concurrentLaneDeferredCount: concurrentLanes.deferredLaneCount,
        hostedWaitEscapeCount: deliverySummary.hostedWaitEscapeCount,
        meanTerminalDurationMinutes: deliverySummary.meanTerminalDurationMinutes
      }
    }
  };
}

export function runThroughputScorecard({
  repo = null,
  runtimeStatePath = DEFAULT_RUNTIME_STATE_PATH,
  deliveryMemoryPath = DEFAULT_DELIVERY_MEMORY_PATH,
  queueReportPath = DEFAULT_QUEUE_REPORT_PATH,
  concurrentLaneStatusPath = DEFAULT_CONCURRENT_LANE_STATUS_PATH,
  utilizationPolicyPath = DEFAULT_UTILIZATION_POLICY_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  now = new Date()
} = {}) {
  let runtimeStateInput = loadJsonInput(runtimeStatePath);
  if (!runtimeStateInput.exists && path.basename(runtimeStatePath) === path.basename(DEFAULT_RUNTIME_STATE_PATH)) {
    const legacyRuntimeStatePath = path.join(path.dirname(runtimeStatePath), 'runtime-state.json');
    const legacyRuntimeStateInput = loadJsonInput(legacyRuntimeStatePath);
    if (legacyRuntimeStateInput.exists) {
      runtimeStateInput = legacyRuntimeStateInput;
    }
  }
  const deliveryMemoryInput = loadJsonInput(deliveryMemoryPath);
  const queueReportInput = loadJsonInput(queueReportPath);
  const concurrentLaneStatusInput = loadJsonInput(concurrentLaneStatusPath);
  const utilizationPolicyInput = loadJsonInput(utilizationPolicyPath);
  const repository =
    normalizeText(repo) ||
    normalizeText(runtimeStateInput.payload?.repository) ||
    normalizeText(deliveryMemoryInput.payload?.repository) ||
    normalizeText(queueReportInput.payload?.repository) ||
    normalizeText(concurrentLaneStatusInput.payload?.repository) ||
    resolveRepoSlug(repo) ||
    null;
  const report = buildThroughputScorecard({
    repository,
    runtimeState: runtimeStateInput.payload,
    deliveryMemory: deliveryMemoryInput.payload,
    queueReport: queueReportInput.payload,
    concurrentLaneStatus: concurrentLaneStatusInput.payload,
    concurrentLaneStatusInput,
    utilizationPolicy: utilizationPolicyInput.payload,
    inputPaths: {
      runtimeStatePath: runtimeStateInput.path,
      deliveryMemoryPath: deliveryMemoryInput.path,
      queueReportPath: queueReportInput.path,
      concurrentLaneStatusPath: concurrentLaneStatusInput.path,
      utilizationPolicyPath: utilizationPolicyInput.path
    },
    now
  });

  const resolvedOutputPath = path.resolve(outputPath);
  fs.mkdirSync(path.dirname(resolvedOutputPath), { recursive: true });
  fs.writeFileSync(resolvedOutputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return {
    report,
    outputPath: resolvedOutputPath,
    inputs: {
      runtimeState: runtimeStateInput,
      deliveryMemory: deliveryMemoryInput,
      queueReport: queueReportInput,
      concurrentLaneStatus: concurrentLaneStatusInput,
      utilizationPolicy: utilizationPolicyInput
    }
  };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return 0;
  }
  const result = runThroughputScorecard(options);
  console.log(
    `[throughput-scorecard] report: ${result.outputPath} status=${result.report.summary.status} ready=${result.report.queue.readyPrInventory} utilization=${result.report.workerPool.utilizationRatio}`
  );
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv);
  } catch (error) {
    console.error(`[throughput-scorecard] ${error.message || error}`);
    process.exitCode = 1;
  }
}

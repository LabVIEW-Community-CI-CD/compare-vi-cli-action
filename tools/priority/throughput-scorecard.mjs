#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/throughput-scorecard@v1';
export const DEFAULT_RUNTIME_STATE_PATH = path.join('tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json');
export const DEFAULT_DELIVERY_MEMORY_PATH = path.join('tests', 'results', '_agent', 'runtime', 'delivery-memory.json');
export const DEFAULT_QUEUE_REPORT_PATH = path.join('tests', 'results', '_agent', 'queue', 'queue-supervisor-report.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'throughput', 'throughput-scorecard.json');

const HELP = [
  'Usage: node tools/priority/throughput-scorecard.mjs [options]',
  '',
  'Options:',
  `  --runtime-state <path>   Runtime state JSON path (default: ${DEFAULT_RUNTIME_STATE_PATH}).`,
  `  --delivery-memory <path> Delivery memory JSON path (default: ${DEFAULT_DELIVERY_MEMORY_PATH}).`,
  `  --queue-report <path>    Queue supervisor report path (default: ${DEFAULT_QUEUE_REPORT_PATH}).`,
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

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    runtimeStatePath: DEFAULT_RUNTIME_STATE_PATH,
    deliveryMemoryPath: DEFAULT_DELIVERY_MEMORY_PATH,
    queueReportPath: DEFAULT_QUEUE_REPORT_PATH,
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
    if (['--runtime-state', '--delivery-memory', '--queue-report', '--output', '--repo'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--runtime-state') options.runtimeStatePath = next;
      if (token === '--delivery-memory') options.deliveryMemoryPath = next;
      if (token === '--queue-report') options.queueReportPath = next;
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

  const reasons = [];
  if (queueSummary.readyPrInventory > 0 && workerPoolSummary.occupiedSlotCount === 0 && queueSummary.capacity > 0) {
    reasons.push('actionable-work-with-idle-worker-pool');
  }
  if (queueSummary.readyPrInventory > 0 && queueSummary.paused) {
    reasons.push('queue-paused-with-ready-inventory');
  }

  const status = reasons.length > 0 ? 'warn' : 'pass';

  return {
    schema: REPORT_SCHEMA,
    generatedAt: toIso(now),
    repository: normalizeText(repository) || null,
    inputs: {
      runtimeStatePath: inputPaths.runtimeStatePath ?? null,
      deliveryMemoryPath: inputPaths.deliveryMemoryPath ?? null,
      queueReportPath: inputPaths.queueReportPath ?? null
    },
    workerPool: workerPoolSummary,
    queue: queueSummary,
    delivery: deliverySummary,
    summary: {
      status,
      reasons,
      metrics: {
        currentWorkerUtilizationRatio: workerPoolSummary.utilizationRatio,
        readyPrInventory: queueSummary.readyPrInventory,
        mergeQueueInflight: queueSummary.inflight,
        mergeQueueCapacity: queueSummary.capacity,
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
  outputPath = DEFAULT_OUTPUT_PATH,
  now = new Date()
} = {}) {
  const runtimeStateInput = loadJsonInput(runtimeStatePath);
  const deliveryMemoryInput = loadJsonInput(deliveryMemoryPath);
  const queueReportInput = loadJsonInput(queueReportPath);
  const repository =
    normalizeText(repo) ||
    normalizeText(runtimeStateInput.payload?.repository) ||
    normalizeText(deliveryMemoryInput.payload?.repository) ||
    normalizeText(queueReportInput.payload?.repository) ||
    resolveRepoSlug(repo) ||
    null;
  const report = buildThroughputScorecard({
    repository,
    runtimeState: runtimeStateInput.payload,
    deliveryMemory: deliveryMemoryInput.payload,
    queueReport: queueReportInput.payload,
    inputPaths: {
      runtimeStatePath: runtimeStateInput.path,
      deliveryMemoryPath: deliveryMemoryInput.path,
      queueReportPath: queueReportInput.path
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
      queueReport: queueReportInput
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

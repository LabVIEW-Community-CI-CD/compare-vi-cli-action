#!/usr/bin/env node
// @ts-nocheck

import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const DELIVERY_MEMORY_REPORT_SCHEMA = 'priority/delivery-memory-report@v1';
export const DEFAULT_RUNTIME_DIR = path.join('tests', 'results', '_agent', 'runtime');
export const DEFAULT_REPORT_FILENAME = 'delivery-memory.json';

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function resolvePath(repoRoot, candidate) {
  return path.isAbsolute(candidate) ? candidate : path.join(repoRoot, candidate);
}

function coercePositiveInteger(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function parseTimeMs(value) {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function parsePullRequestNumberFromUrl(url) {
  const match = normalizeText(url).match(/\/pull\/(\d+)$/i);
  return coercePositiveInteger(match?.[1]);
}

function normalizeArray(value) {
  return Array.isArray(value) ? value : [];
}

function classifyCloseReason({ actionType, outcome, reason, branch }) {
  const haystack = [actionType, outcome, reason, branch]
    .map((entry) => normalizeText(entry).toLowerCase())
    .filter(Boolean)
    .join(' ');
  if (!haystack) return null;
  if (/poison/.test(haystack)) return 'poisoned-branch';
  if (/supersed|replac|duplicate/.test(haystack)) return 'superseded';
  if (/abandon|stale|orphan|queue/.test(haystack)) return 'queue-hygiene';
  return 'unknown';
}

function deriveTerminalDisposition(receipt, context) {
  const actionType = normalizeText(receipt?.details?.actionType).toLowerCase();
  const outcome = normalizeText(receipt?.outcome).toLowerCase();
  const reason = normalizeText(receipt?.reason);
  const branch = normalizeText(receipt?.details?.branch) || normalizeText(context?.branch);

  if (actionType === 'merge-pr' && outcome === 'merged') {
    return {
      terminalDisposition: 'merged',
      closeReasonClass: null,
      poisonedBranch: false
    };
  }

  const closeReasonClass = classifyCloseReason({ actionType, outcome, reason, branch });
  const explicitClose =
    actionType === 'close-pr' ||
    outcome.includes('closed-pr') ||
    outcome.includes('poisoned-branch') ||
    /close(?:d|)\s+pr/i.test(reason);

  if (explicitClose) {
    return {
      terminalDisposition: 'closed',
      closeReasonClass,
      poisonedBranch: closeReasonClass === 'poisoned-branch'
    };
  }

  return null;
}

function summarizeEffort(metrics) {
  const filesTouchedCount = metrics.filesTouched.size;
  const score =
    metrics.codingTurnCount * 5 +
    metrics.blockedTurnCount * 3 +
    metrics.waitingReviewTurnCount * 2 +
    metrics.waitingCiTurnCount +
    metrics.mergeAttemptCount * 2 +
    metrics.closeAttemptCount * 2 +
    Math.ceil(metrics.helperCallCount / 5) +
    Math.min(filesTouchedCount, 10);
  const level = score >= 12 ? 'high' : score >= 5 ? 'medium' : 'low';
  return {
    level,
    score,
    turnCount: metrics.turnCount,
    codingTurnCount: metrics.codingTurnCount,
    blockedTurnCount: metrics.blockedTurnCount,
    waitingReviewTurnCount: metrics.waitingReviewTurnCount,
    waitingCiTurnCount: metrics.waitingCiTurnCount,
    mergeAttemptCount: metrics.mergeAttemptCount,
    closeAttemptCount: metrics.closeAttemptCount,
    helperCallCount: metrics.helperCallCount,
    filesTouchedCount
  };
}

function classifyDeliveryTrack({ objective, branch, filesTouched = [], terminalReason }) {
  const haystack = [objective, branch, terminalReason, ...normalizeArray(filesTouched)]
    .map((entry) => normalizeText(entry).toLowerCase())
    .filter(Boolean)
    .join(' ');
  if (
    haystack.includes('vi-history') ||
    haystack.includes('history suite') ||
    haystack.includes('history-report') ||
    haystack.includes('comparevi-history') ||
    haystack.includes('comparevihistory') ||
    haystack.includes('tools/test-prvihistorysmoke.ps1') ||
    haystack.includes('tests/comparevi.history.tests.ps1') ||
    haystack.includes('tests/comparevihistory.tests.ps1')
  ) {
    return 'vi-history-suite';
  }
  return 'general';
}

function normalizeTaskPacketContext(taskPacket) {
  if (!taskPacket || typeof taskPacket !== 'object') return null;
  const laneId = normalizeText(taskPacket.laneId);
  if (!laneId) return null;
  const delivery = taskPacket?.evidence?.delivery ?? {};
  const prUrl = normalizeText(taskPacket?.pullRequest?.url) || normalizeText(delivery?.pullRequest?.url) || null;
  return {
    laneId,
    generatedAt: normalizeText(taskPacket.generatedAt) || null,
    repository: normalizeText(taskPacket.repository) || null,
    issue:
      coercePositiveInteger(taskPacket.issue) ??
      coercePositiveInteger(delivery?.selectedIssue?.number) ??
      coercePositiveInteger(delivery?.standingIssue?.number) ??
      null,
    branch: normalizeText(taskPacket?.branch?.name) || null,
    objective: normalizeText(taskPacket?.objective?.summary) || null,
    prUrl,
    prNumber: parsePullRequestNumberFromUrl(prUrl),
    selectedActionType: normalizeText(delivery?.selectedActionType) || null
  };
}

function findBestContext(contexts, generatedAt) {
  if (!Array.isArray(contexts) || contexts.length === 0) return null;
  const targetMs = parseTimeMs(generatedAt);
  if (!Number.isFinite(targetMs)) {
    return contexts[contexts.length - 1] ?? null;
  }
  let best = null;
  let bestMs = Number.NEGATIVE_INFINITY;
  for (const context of contexts) {
    const contextMs = parseTimeMs(context.generatedAt);
    if (!Number.isFinite(contextMs)) continue;
    if (contextMs <= targetMs && contextMs >= bestMs) {
      best = context;
      bestMs = contextMs;
    }
  }
  return best ?? contexts[contexts.length - 1] ?? null;
}

function ensureEntry(records, key, seed = {}) {
  let existing = records.get(key);
  if (!existing) {
    existing = {
      key,
      laneId: normalizeText(seed.laneId) || null,
      issue: coercePositiveInteger(seed.issue),
      branch: normalizeText(seed.branch) || null,
      objective: normalizeText(seed.objective) || null,
      repository: normalizeText(seed.repository) || null,
      pullRequestUrl: normalizeText(seed.pullRequestUrl) || null,
      pullRequestNumber: coercePositiveInteger(seed.pullRequestNumber),
      firstObservedAt: null,
      lastObservedAt: null,
      terminalAt: null,
      terminalDisposition: null,
      closeReasonClass: null,
      poisonedBranch: false,
      terminalOutcome: null,
      terminalReason: null,
      metrics: {
        turnCount: 0,
        codingTurnCount: 0,
        blockedTurnCount: 0,
        waitingReviewTurnCount: 0,
        waitingCiTurnCount: 0,
        mergeAttemptCount: 0,
        closeAttemptCount: 0,
        helperCallCount: 0,
        filesTouched: new Set()
      }
    };
    records.set(key, existing);
  }
  return existing;
}

function updateObservedTimes(entry, generatedAt) {
  const observedAt = normalizeText(generatedAt) || null;
  if (!observedAt) return;
  if (!entry.firstObservedAt || observedAt < entry.firstObservedAt) {
    entry.firstObservedAt = observedAt;
  }
  if (!entry.lastObservedAt || observedAt > entry.lastObservedAt) {
    entry.lastObservedAt = observedAt;
  }
}

function recordReceipt(entry, receipt, context) {
  const metrics = entry.metrics;
  metrics.turnCount += 1;
  const actionType = normalizeText(receipt?.details?.actionType).toLowerCase();
  const laneLifecycle = normalizeText(receipt?.details?.laneLifecycle).toLowerCase();
  if (actionType === 'execute-coding-turn') {
    metrics.codingTurnCount += 1;
  }
  if (actionType === 'merge-pr') {
    metrics.mergeAttemptCount += 1;
  }
  if (actionType === 'close-pr') {
    metrics.closeAttemptCount += 1;
  }
  if (laneLifecycle === 'blocked' || normalizeText(receipt?.status).toLowerCase() === 'blocked') {
    metrics.blockedTurnCount += 1;
  }
  if (laneLifecycle === 'waiting-review') {
    metrics.waitingReviewTurnCount += 1;
  }
  if (laneLifecycle === 'waiting-ci') {
    metrics.waitingCiTurnCount += 1;
  }
  metrics.helperCallCount += normalizeArray(receipt?.details?.helperCallsExecuted).length;
  for (const filePath of normalizeArray(receipt?.details?.filesTouched)) {
    const normalized = normalizeText(filePath);
    if (normalized) metrics.filesTouched.add(normalized);
  }

  if (!entry.issue) {
    entry.issue = coercePositiveInteger(receipt?.issue) ?? coercePositiveInteger(context?.issue);
  }
  if (!entry.branch) {
    entry.branch = normalizeText(receipt?.details?.branch) || normalizeText(context?.branch) || null;
  }
  if (!entry.objective) {
    entry.objective = normalizeText(context?.objective) || null;
  }
  if (!entry.repository) {
    entry.repository = normalizeText(receipt?.repository) || normalizeText(context?.repository) || null;
  }
  if (!entry.pullRequestUrl) {
    entry.pullRequestUrl = normalizeText(receipt?.details?.pullRequestUrl) || normalizeText(context?.prUrl) || null;
  }
  if (!entry.pullRequestNumber) {
    entry.pullRequestNumber =
      parsePullRequestNumberFromUrl(receipt?.details?.pullRequestUrl) ??
      coercePositiveInteger(context?.prNumber) ??
      null;
  }

  updateObservedTimes(entry, receipt?.generatedAt);

  const terminal = deriveTerminalDisposition(receipt, context);
  if (terminal) {
    entry.terminalAt = normalizeText(receipt?.generatedAt) || entry.terminalAt;
    entry.terminalDisposition = terminal.terminalDisposition;
    entry.closeReasonClass = terminal.closeReasonClass;
    entry.poisonedBranch = terminal.poisonedBranch;
    entry.terminalOutcome = normalizeText(receipt?.outcome) || null;
    entry.terminalReason = normalizeText(receipt?.reason) || null;
  }
}

function finalizeEntry(entry) {
  const durationStart = parseTimeMs(entry.firstObservedAt);
  const durationEnd = parseTimeMs(entry.terminalAt || entry.lastObservedAt);
  const durationMinutes =
    Number.isFinite(durationStart) && Number.isFinite(durationEnd) && durationEnd >= durationStart
      ? Math.round(((durationEnd - durationStart) / 60000) * 10) / 10
      : null;
  const effort = summarizeEffort(entry.metrics);
  const filesTouchedSample = Array.from(entry.metrics.filesTouched).sort().slice(0, 10);
  const deliveryTrack = classifyDeliveryTrack({
    objective: entry.objective,
    branch: entry.branch,
    filesTouched: filesTouchedSample,
    terminalReason: entry.terminalReason
  });
  return {
    laneId: entry.laneId,
    issue: entry.issue,
    branch: entry.branch,
    objective: entry.objective,
    repository: entry.repository,
    pullRequestUrl: entry.pullRequestUrl,
    pullRequestNumber: entry.pullRequestNumber,
    firstObservedAt: entry.firstObservedAt,
    lastObservedAt: entry.lastObservedAt,
    terminalAt: entry.terminalAt,
    terminalDisposition: entry.terminalDisposition,
    closeReasonClass: entry.closeReasonClass,
    poisonedBranch: entry.poisonedBranch,
    terminalOutcome: entry.terminalOutcome,
    terminalReason: entry.terminalReason,
    deliveryTrack,
    effort: {
      ...effort,
      durationMinutes
    },
    filesTouchedSample
  };
}

function compareEntries(left, right) {
  const leftTime = normalizeText(left.terminalAt || left.lastObservedAt);
  const rightTime = normalizeText(right.terminalAt || right.lastObservedAt);
  return rightTime.localeCompare(leftTime);
}

export function buildDeliveryMemoryReport({
  repository = null,
  runtimeDir = DEFAULT_RUNTIME_DIR,
  taskPackets = [],
  executionReceipts = [],
  hostIsolation = null,
  now = new Date()
}) {
  const taskContextsByLane = new Map();
  for (const taskPacket of taskPackets) {
    const context = normalizeTaskPacketContext(taskPacket);
    if (!context) continue;
    const contexts = taskContextsByLane.get(context.laneId) ?? [];
    contexts.push(context);
    contexts.sort((left, right) => normalizeText(left.generatedAt).localeCompare(normalizeText(right.generatedAt)));
    taskContextsByLane.set(context.laneId, contexts);
  }

  const records = new Map();
  const normalizedReceipts = normalizeArray(executionReceipts)
    .filter((receipt) => receipt && typeof receipt === 'object')
    .slice()
    .sort((left, right) => normalizeText(left.generatedAt).localeCompare(normalizeText(right.generatedAt)));

  for (const receipt of normalizedReceipts) {
    const laneId = normalizeText(receipt?.laneId);
    const contexts = laneId ? taskContextsByLane.get(laneId) ?? [] : [];
    const context = findBestContext(contexts, receipt?.generatedAt);
    const pullRequestUrl = normalizeText(receipt?.details?.pullRequestUrl) || normalizeText(context?.prUrl) || null;
    const key = pullRequestUrl || (laneId ? `lane:${laneId}` : `receipt:${normalizeText(receipt?.generatedAt) || records.size}`);
    const entry = ensureEntry(records, key, {
      laneId,
      issue: coercePositiveInteger(receipt?.issue) ?? coercePositiveInteger(context?.issue),
      branch: normalizeText(receipt?.details?.branch) || normalizeText(context?.branch),
      objective: normalizeText(context?.objective),
      repository: normalizeText(receipt?.repository) || normalizeText(context?.repository) || normalizeText(repository),
      pullRequestUrl,
      pullRequestNumber: parsePullRequestNumberFromUrl(pullRequestUrl) ?? coercePositiveInteger(context?.prNumber)
    });
    recordReceipt(entry, receipt, context);
  }

  const pullRequests = [...records.values()]
    .filter((entry) => entry.terminalDisposition === 'merged' || entry.terminalDisposition === 'closed')
    .map(finalizeEntry)
    .sort(compareEntries);

  const summary = {
    totalTerminalPullRequestCount: pullRequests.length,
    mergedPullRequestCount: pullRequests.filter((entry) => entry.terminalDisposition === 'merged').length,
    closedPullRequestCount: pullRequests.filter((entry) => entry.terminalDisposition === 'closed').length,
    poisonedBranchClosureCount: pullRequests.filter((entry) => entry.poisonedBranch === true).length,
    lowEffortCount: pullRequests.filter((entry) => entry.effort.level === 'low').length,
    mediumEffortCount: pullRequests.filter((entry) => entry.effort.level === 'medium').length,
    highEffortCount: pullRequests.filter((entry) => entry.effort.level === 'high').length,
    viHistorySuitePullRequestCount: pullRequests.filter((entry) => entry.deliveryTrack === 'vi-history-suite').length,
    viHistorySuiteMergedPullRequestCount: pullRequests.filter(
      (entry) => entry.deliveryTrack === 'vi-history-suite' && entry.terminalDisposition === 'merged'
    ).length,
    viHistorySuiteClosedPullRequestCount: pullRequests.filter(
      (entry) => entry.deliveryTrack === 'vi-history-suite' && entry.terminalDisposition === 'closed'
    ).length,
    runnerPreemptionCount: Number(hostIsolation?.counters?.runnerPreemptionCount ?? 0),
    runnerRestoreCount: Number(hostIsolation?.counters?.runnerRestoreCount ?? 0),
    dockerDriftIncidentCount: Number(hostIsolation?.counters?.dockerDriftIncidentCount ?? 0),
    nativeDaemonRepairCount: Number(hostIsolation?.counters?.nativeDaemonRepairCount ?? 0),
    cyclesBlockedByHostRuntimeConflict: Number(hostIsolation?.counters?.cyclesBlockedByHostRuntimeConflict ?? 0),
    recentTerminalPullRequests: pullRequests.slice(0, 5).map((entry) => ({
      laneId: entry.laneId,
      issue: entry.issue,
      pullRequestNumber: entry.pullRequestNumber,
      pullRequestUrl: entry.pullRequestUrl,
      deliveryTrack: entry.deliveryTrack,
      terminalDisposition: entry.terminalDisposition,
      closeReasonClass: entry.closeReasonClass,
      poisonedBranch: entry.poisonedBranch,
      terminalAt: entry.terminalAt,
      effortLevel: entry.effort.level,
      effortScore: entry.effort.score
    }))
  };

  return {
    schema: DELIVERY_MEMORY_REPORT_SCHEMA,
    generatedAt: toIso(now),
    repository: normalizeText(repository) || pullRequests[0]?.repository || null,
    runtimeDir,
    summary,
    hostIsolation,
    pullRequests
  };
}

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

async function readJsonDirectory(dirPath) {
  try {
    const entries = await readdir(dirPath, { withFileTypes: true });
    const files = entries
      .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.json'))
      .map((entry) => path.join(dirPath, entry.name))
      .sort();
    const payloads = [];
    for (const filePath of files) {
      const payload = await readJsonIfPresent(filePath);
      if (payload) payloads.push(payload);
    }
    return payloads;
  } catch (error) {
    if (error?.code === 'ENOENT') return [];
    throw error;
  }
}

export async function refreshDeliveryMemory({
  repoRoot = process.cwd(),
  repository = null,
  runtimeDir = DEFAULT_RUNTIME_DIR,
  outPath = null,
  now = new Date()
} = {}) {
  const runtimeRoot = resolvePath(repoRoot, runtimeDir);
  const reportPath = outPath ? resolvePath(repoRoot, outPath) : path.join(runtimeRoot, DEFAULT_REPORT_FILENAME);
  const executionReceipts = await readJsonDirectory(path.join(runtimeRoot, 'execution-receipts'));
  const taskPackets = await readJsonDirectory(path.join(runtimeRoot, 'task-packets'));
  const hostIsolation = await readJsonIfPresent(path.join(runtimeRoot, 'delivery-agent-host-isolation.json'));
  const report = buildDeliveryMemoryReport({
    repository,
    runtimeDir,
    taskPackets,
    executionReceipts,
    hostIsolation,
    now
  });
  await mkdir(path.dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return {
    report,
    reportPath
  };
}

export function parseArgs(argv = process.argv) {
  const options = {
    repoRoot: process.cwd(),
    repository: null,
    runtimeDir: DEFAULT_RUNTIME_DIR,
    outPath: null,
    help: false
  };
  const args = argv.slice(2);
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    const next = args[index + 1];
    if (token === '--repo-root' || token === '--repo' || token === '--runtime-dir' || token === '--out') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--repo') options.repository = next;
      if (token === '--runtime-dir') options.runtimeDir = next;
      if (token === '--out') options.outPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }
  return options;
}

function printUsage() {
  console.log('Usage: node tools/priority/delivery-memory.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>   Repository root (default: current working directory).');
  console.log('  --repo <owner/repo>  Repository slug to stamp into the report.');
  console.log(`  --runtime-dir <path> Runtime artifact directory (default: ${DEFAULT_RUNTIME_DIR}).`);
  console.log('  --out <path>         Output path (default: <runtime-dir>/delivery-memory.json).');
  console.log('  -h, --help           Show help.');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const { report } = await refreshDeliveryMemory({
    repoRoot: options.repoRoot,
    repository: options.repository,
    runtimeDir: options.runtimeDir,
    outPath: options.outPath
  });
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  return 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).then(
    (exitCode) => process.exit(exitCode),
    (error) => {
      process.stderr.write(`${error?.message || String(error)}\n`);
      process.exit(1);
    }
  );
}

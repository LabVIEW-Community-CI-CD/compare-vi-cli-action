#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { parseRemoteUrl, runGhGraphql } from './lib/remote-utils.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { deriveCurrentCycleIdleAuthority } from './lib/current-cycle-idle-authority.mjs';
import { buildQueueReadinessReport, DEFAULT_READINESS_REPORT_PATH } from './queue-readiness.mjs';
import { hasDeferredPostMergeBranchCleanup, reconcileDeferredBranchCleanup } from './merge-sync-pr.mjs';

const REPORT_SCHEMA = 'priority/queue-supervisor-report@v1';
const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'queue', 'queue-supervisor-report.json');
const THROUGHPUT_CONTROLLER_SCHEMA = 'ops-throughput-controller-state@v1';
const DEFAULT_CONTROLLER_STATE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'queue',
  'throughput-controller-state.json'
);
const DEFAULT_RUNTIME_STATE_PATH = path.join('tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json');
const DEFAULT_GOVERNOR_STATE_PATH = path.join('tests', 'results', '_agent', 'slo', 'ops-governor-state.json');
const DEFAULT_SECURITY_INTAKE_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'security',
  'security-intake-report.json'
);
const DEFAULT_MAX_INFLIGHT = 5;
const DEFAULT_MIN_INFLIGHT = 2;
const DEFAULT_HEALTH_SAMPLE = 10;
const DEFAULT_HEALTH_MIN_SUCCESS_RATE = 0.8;
const DEFAULT_HEALTH_MAX_RED_MINUTES = 30;
const DEFAULT_HEALTH_LOOKBACK_DAYS = 30;
const DEFAULT_MAX_QUEUED_RUNS = 6;
const DEFAULT_MAX_IN_PROGRESS_RUNS = 8;
const DEFAULT_STALL_THRESHOLD_MINUTES = 45;
const DEFAULT_BURST_MODE = 'auto';
const DEFAULT_BURST_REFILL_CYCLES = 3;
const BURST_BACKOFF_MINUTES = 30;
const RELEASE_WINDOW_DAY_UTC = 3;
const RELEASE_WINDOW_MAX_DAY_OF_MONTH = 7;
const RELEASE_WINDOW_HOUR_UTC = 18;
const RETRY_WINDOW_HOURS = 24;
const CONTROLLER_REQUIRED_UPGRADE_STREAK = 2;
const CONTROLLER_THRESHOLDS = Object.freeze({
  severeSuccessRate: 0.8,
  warningSuccessRate: 0.9,
  warningSaturation: 0.75,
  severeSaturation: 1.0,
  warningRetryRatio: 0.2,
  severeRetryRatio: 0.35,
  warningQuarantineRatio: 0.1,
  severeQuarantineRatio: 0.2
});
const EXCLUDED_LABELS = new Set(['queue-blocked', 'do-not-queue']);
const DEFAULT_BASE_BRANCHES = ['develop', 'main'];
const COUPLING_VALUES = new Set(['independent', 'soft', 'hard']);
const BURST_MODES = new Set(['auto', 'on', 'off']);
const SECURITY_INTAKE_STATUSES = new Set(['pass', 'breach', 'overridden', 'platform-stale', 'skip', 'error']);
const COUPLING_PRIORITY = Object.freeze({
  independent: 0,
  soft: 1,
  hard: 2
});

function printUsage() {
  console.log('Usage: node tools/priority/queue-supervisor.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --apply                Enqueue PRs (default is dry-run planning mode).');
  console.log(`  --report <path>        Write report JSON (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(
    `  --controller-state <path> Write throughput-controller JSON (default: ${DEFAULT_CONTROLLER_STATE_PATH}).`
  );
  console.log(`  --readiness-report <path> Write queue readiness JSON (default: ${DEFAULT_READINESS_REPORT_PATH}).`);
  console.log(`  --governor-state <path>   Read governor-state JSON (default: ${DEFAULT_GOVERNOR_STATE_PATH}).`);
  console.log(
    `  --security-intake-report <path> Read security-intake JSON (default: ${DEFAULT_SECURITY_INTAKE_REPORT_PATH}).`
  );
  console.log(`  --max-inflight <n>     Queue target cap (default: ${DEFAULT_MAX_INFLIGHT}, env QUEUE_AUTOPILOT_MAX_INFLIGHT).`);
  console.log(`  --min-inflight <n>     Adaptive-cap floor (default: ${DEFAULT_MIN_INFLIGHT}, env QUEUE_AUTOPILOT_MIN_INFLIGHT).`);
  console.log('  --adaptive-cap         Enable adaptive inflight tuning (default, env QUEUE_AUTOPILOT_ADAPTIVE_CAP).');
  console.log('  --no-adaptive-cap      Disable adaptive inflight tuning and use fixed max-inflight.');
  console.log(`  --max-queued-runs <n>  Pause when queued workflow runs exceed this threshold (default: ${DEFAULT_MAX_QUEUED_RUNS}).`);
  console.log(`  --max-in-progress-runs <n> Pause when in-progress workflow runs exceed this threshold (default: ${DEFAULT_MAX_IN_PROGRESS_RUNS}).`);
  console.log(`  --stall-threshold-minutes <n> Pause when active runs exceed age threshold (default: ${DEFAULT_STALL_THRESHOLD_MINUTES}).`);
  console.log(`  --burst-mode <auto|on|off> Burst controller mode (default: ${DEFAULT_BURST_MODE}, env QUEUE_BURST_MODE).`);
  console.log(`  --burst-refill-cycles <n> Keep burst active for N follow-up cycles after trigger (default: ${DEFAULT_BURST_REFILL_CYCLES}, env QUEUE_BURST_REFILL_CYCLES).`);
  console.log('  --repo <owner/repo>    Target repository (default: GITHUB_REPOSITORY/upstream remote).');
  console.log(`  --base-branches <csv>  Queue-managed branch allowlist (default: ${DEFAULT_BASE_BRANCHES.join(',')}).`);
  console.log('  --health-branch <name> Branch to evaluate trunk health (default: develop).');
  console.log('  --dry-run              Force dry-run mode.');
  console.log('  -h, --help             Show this help text and exit.');
}

function parseIntStrict(value, { label }) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Invalid ${label} value '${value}'.`);
  }
  return parsed;
}

function parseBooleanStrict(value, { label }) {
  const normalized = String(value ?? '').trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  throw new Error(`Invalid ${label} value '${value}'. Expected one of: 1,true,yes,on,0,false,no,off.`);
}

function parseCsv(value) {
  return String(value)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function parseBurstMode(value, { label }) {
  const normalized = String(value ?? '')
    .trim()
    .toLowerCase();
  if (!BURST_MODES.has(normalized)) {
    throw new Error(`Invalid ${label} value '${value}'. Expected one of: auto,on,off.`);
  }
  return normalized;
}

function isMaterializedMergeSyncSummary(summary) {
  return Boolean(summary?.promotion?.materialized);
}

function summarizeMergeSyncSummary(summary, summaryPath) {
  return {
    path: summaryPath,
    finalMode: summary?.finalMode ?? null,
    finalReason: summary?.finalReason ?? null,
    promotionStatus: summary?.promotion?.status ?? null,
    materialized: isMaterializedMergeSyncSummary(summary),
    branchCleanupRequested: Boolean(summary?.branchCleanup?.requested),
    branchCleanupStatus: summary?.branchCleanup?.status ?? null,
    branchCleanupReason: summary?.branchCleanup?.reason ?? null
  };
}

async function listMergeSyncSummaryPaths({ repoRoot, readdirFn = readdir } = {}) {
  const queueResultsRoot = path.join(repoRoot, 'tests', 'results', '_agent', 'queue');
  let entries = [];
  try {
    entries = await readdirFn(queueResultsRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return [];
    }
    throw error;
  }

  return entries
    .filter((entry) => {
      if (typeof entry === 'string') {
        return /^merge-sync-\d+\.json$/u.test(entry);
      }
      return Boolean(entry?.isFile?.()) && /^merge-sync-\d+\.json$/u.test(entry.name);
    })
    .map((entry) => path.join(queueResultsRoot, typeof entry === 'string' ? entry : entry.name))
    .sort();
}

async function reconcileDeferredBranchCleanupReceipts({
  repoRoot,
  applyMutations = false,
  readdirFn = readdir,
  readOptionalJsonFn = readOptionalJson,
  writeReportFn = writeReport,
  reconcileDeferredBranchCleanupFn = reconcileDeferredBranchCleanup
} = {}) {
  const summaryPaths = await listMergeSyncSummaryPaths({ repoRoot, readdirFn });
  const actions = [];

  for (const summaryPath of summaryPaths) {
    const summary = await readOptionalJsonFn(summaryPath);
    if (!hasDeferredPostMergeBranchCleanup(summary)) {
      continue;
    }

    if (!applyMutations) {
      actions.push({
        path: summaryPath,
        pr: summary?.pr ?? null,
        repo: summary?.repo ?? null,
        status: 'pending',
        changed: false,
        promotionStatus: summary?.promotion?.status ?? null,
        branchCleanupStatus: summary?.branchCleanup?.status ?? null,
        branchCleanupReason: summary?.branchCleanup?.reason ?? null
      });
      continue;
    }

    try {
      const result = await reconcileDeferredBranchCleanupFn({
        repoRoot,
        summary
      });
      if (result?.changed) {
        await writeReportFn(summaryPath, result.summary);
      }
      actions.push({
        path: summaryPath,
        pr: summary?.pr ?? null,
        repo: summary?.repo ?? null,
        status: result?.status ?? 'pending',
        changed: Boolean(result?.changed),
        promotionStatus: result?.promotion?.status ?? summary?.promotion?.status ?? null,
        branchCleanupStatus: result?.summary?.branchCleanup?.status ?? summary?.branchCleanup?.status ?? null,
        branchCleanupReason: result?.summary?.branchCleanup?.reason ?? summary?.branchCleanup?.reason ?? null
      });
    } catch (error) {
      actions.push({
        path: summaryPath,
        pr: summary?.pr ?? null,
        repo: summary?.repo ?? null,
        status: 'failed',
        changed: false,
        promotionStatus: summary?.promotion?.status ?? null,
        branchCleanupStatus: summary?.branchCleanup?.status ?? null,
        branchCleanupReason: summary?.branchCleanup?.reason ?? null,
        error: error?.message ?? String(error)
      });
    }
  }

  return {
    summary: {
      totalCount: actions.length,
      pendingCount: actions.filter((action) => action.status === 'pending' || action.status === 'deferred').length,
      completedCount: actions.filter((action) => action.status === 'completed').length,
      dryRunCount: actions.filter((action) => action.status === 'dry-run').length,
      failedCount: actions.filter((action) => action.status === 'failed').length
    },
    actions
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    apply: false,
    dryRun: true,
    reportPath: DEFAULT_REPORT_PATH,
    controllerStatePath: DEFAULT_CONTROLLER_STATE_PATH,
    readinessReportPath: DEFAULT_READINESS_REPORT_PATH,
    governorStatePath: DEFAULT_GOVERNOR_STATE_PATH,
    securityIntakeReportPath: DEFAULT_SECURITY_INTAKE_REPORT_PATH,
    maxInflight: null,
    minInflight: null,
    adaptiveCap: null,
    repo: null,
    baseBranches: [...DEFAULT_BASE_BRANCHES],
    healthBranch: 'develop',
    maxQueuedRuns: null,
    maxInProgressRuns: null,
    stallThresholdMinutes: null,
    burstMode: null,
    burstRefillCycles: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--apply') {
      options.apply = true;
      options.dryRun = false;
      continue;
    }
    if (arg === '--dry-run') {
      options.apply = false;
      options.dryRun = true;
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    if (
      arg === '--report' ||
      arg === '--controller-state' ||
      arg === '--readiness-report' ||
      arg === '--governor-state' ||
      arg === '--security-intake-report' ||
      arg === '--max-inflight' ||
      arg === '--min-inflight' ||
      arg === '--repo' ||
      arg === '--base-branches' ||
      arg === '--health-branch' ||
      arg === '--max-queued-runs' ||
      arg === '--max-in-progress-runs' ||
      arg === '--stall-threshold-minutes' ||
      arg === '--burst-mode' ||
      arg === '--burst-refill-cycles'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--report') {
        options.reportPath = next;
      } else if (arg === '--controller-state') {
        options.controllerStatePath = next;
      } else if (arg === '--readiness-report') {
        options.readinessReportPath = next;
      } else if (arg === '--governor-state') {
        options.governorStatePath = next;
      } else if (arg === '--security-intake-report') {
        options.securityIntakeReportPath = next;
      } else if (arg === '--max-inflight') {
        options.maxInflight = parseIntStrict(next, { label: '--max-inflight' });
      } else if (arg === '--min-inflight') {
        options.minInflight = parseIntStrict(next, { label: '--min-inflight' });
      } else if (arg === '--repo') {
        if (!next.includes('/')) {
          throw new Error(`Invalid --repo '${next}', expected owner/repo.`);
        }
        options.repo = next;
      } else if (arg === '--base-branches') {
        const parsed = parseCsv(next);
        if (parsed.length === 0) {
          throw new Error('Expected at least one branch in --base-branches.');
        }
        options.baseBranches = parsed.map((branch) => branch.toLowerCase());
      } else if (arg === '--health-branch') {
        options.healthBranch = next.trim().toLowerCase();
      } else if (arg === '--max-queued-runs') {
        options.maxQueuedRuns = parseIntStrict(next, { label: '--max-queued-runs' });
      } else if (arg === '--max-in-progress-runs') {
        options.maxInProgressRuns = parseIntStrict(next, { label: '--max-in-progress-runs' });
      } else if (arg === '--stall-threshold-minutes') {
        options.stallThresholdMinutes = parseIntStrict(next, { label: '--stall-threshold-minutes' });
      } else if (arg === '--burst-mode') {
        options.burstMode = parseBurstMode(next, { label: '--burst-mode' });
      } else if (arg === '--burst-refill-cycles') {
        options.burstRefillCycles = parseIntStrict(next, { label: '--burst-refill-cycles' });
      }
      continue;
    }
    if (arg === '--adaptive-cap') {
      options.adaptiveCap = true;
      continue;
    }
    if (arg === '--no-adaptive-cap') {
      options.adaptiveCap = false;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  const envInflight = process.env.QUEUE_AUTOPILOT_MAX_INFLIGHT;
  if (options.maxInflight == null && envInflight && String(envInflight).trim()) {
    options.maxInflight = parseIntStrict(envInflight, { label: 'QUEUE_AUTOPILOT_MAX_INFLIGHT' });
  }
  if (options.maxInflight == null) {
    options.maxInflight = DEFAULT_MAX_INFLIGHT;
  }
  const envAdaptiveCap = process.env.QUEUE_AUTOPILOT_ADAPTIVE_CAP;
  if (options.adaptiveCap == null && envAdaptiveCap && String(envAdaptiveCap).trim()) {
    options.adaptiveCap = parseBooleanStrict(envAdaptiveCap, { label: 'QUEUE_AUTOPILOT_ADAPTIVE_CAP' });
  }
  if (options.adaptiveCap == null) {
    options.adaptiveCap = true;
  }

  const envMinInflight = process.env.QUEUE_AUTOPILOT_MIN_INFLIGHT;
  if (options.minInflight == null && envMinInflight && String(envMinInflight).trim()) {
    options.minInflight = parseIntStrict(envMinInflight, { label: 'QUEUE_AUTOPILOT_MIN_INFLIGHT' });
  }
  if (options.minInflight == null) {
    options.minInflight = DEFAULT_MIN_INFLIGHT;
  }
  if (options.minInflight > options.maxInflight) {
    throw new Error(
      `Invalid inflight bounds: min-inflight (${options.minInflight}) cannot exceed max-inflight (${options.maxInflight}).`
    );
  }

  const envMaxQueuedRuns = process.env.QUEUE_AUTOPILOT_MAX_QUEUED_RUNS;
  if (options.maxQueuedRuns == null && envMaxQueuedRuns && String(envMaxQueuedRuns).trim()) {
    options.maxQueuedRuns = parseIntStrict(envMaxQueuedRuns, { label: 'QUEUE_AUTOPILOT_MAX_QUEUED_RUNS' });
  }
  if (options.maxQueuedRuns == null) {
    options.maxQueuedRuns = DEFAULT_MAX_QUEUED_RUNS;
  }

  const envMaxInProgressRuns = process.env.QUEUE_AUTOPILOT_MAX_IN_PROGRESS_RUNS;
  if (options.maxInProgressRuns == null && envMaxInProgressRuns && String(envMaxInProgressRuns).trim()) {
    options.maxInProgressRuns = parseIntStrict(envMaxInProgressRuns, { label: 'QUEUE_AUTOPILOT_MAX_IN_PROGRESS_RUNS' });
  }
  if (options.maxInProgressRuns == null) {
    options.maxInProgressRuns = DEFAULT_MAX_IN_PROGRESS_RUNS;
  }

  const envStallThreshold = process.env.QUEUE_AUTOPILOT_STALL_THRESHOLD_MINUTES;
  if (options.stallThresholdMinutes == null && envStallThreshold && String(envStallThreshold).trim()) {
    options.stallThresholdMinutes = parseIntStrict(envStallThreshold, { label: 'QUEUE_AUTOPILOT_STALL_THRESHOLD_MINUTES' });
  }
  if (options.stallThresholdMinutes == null) {
    options.stallThresholdMinutes = DEFAULT_STALL_THRESHOLD_MINUTES;
  }

  const envBurstMode = process.env.QUEUE_BURST_MODE;
  if (options.burstMode == null && envBurstMode && String(envBurstMode).trim()) {
    options.burstMode = parseBurstMode(envBurstMode, { label: 'QUEUE_BURST_MODE' });
  }
  if (options.burstMode == null) {
    options.burstMode = DEFAULT_BURST_MODE;
  }

  const envBurstRefillCycles = process.env.QUEUE_BURST_REFILL_CYCLES;
  if (options.burstRefillCycles == null && envBurstRefillCycles && String(envBurstRefillCycles).trim()) {
    options.burstRefillCycles = parseIntStrict(envBurstRefillCycles, { label: 'QUEUE_BURST_REFILL_CYCLES' });
  }
  if (options.burstRefillCycles == null) {
    options.burstRefillCycles = DEFAULT_BURST_REFILL_CYCLES;
  }

  return options;
}

function normalizeLabelName(label) {
  if (!label) return '';
  if (typeof label === 'string') return label.trim().toLowerCase();
  if (typeof label === 'object' && typeof label.name === 'string') return label.name.trim().toLowerCase();
  return '';
}

function normalizeOwner(value) {
  if (!value) return '';
  if (typeof value === 'string') return value.trim().toLowerCase();
  if (typeof value === 'object' && typeof value.login === 'string') return value.login.trim().toLowerCase();
  return '';
}

function parseRepositorySlug(value) {
  const parts = String(value ?? '')
    .split('/')
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length !== 2) {
    throw new Error(`Invalid repository slug '${value}'. Expected owner/repo.`);
  }
  return { owner: parts[0], repo: parts[1] };
}

function normalizeIso(value) {
  if (!value) return null;
  const iso = new Date(value);
  return Number.isNaN(iso.valueOf()) ? null : iso.toISOString();
}

export function normalizeBaseBranch(value) {
  if (!value) return '';
  const normalized = String(value).trim().toLowerCase();
  if (normalized.startsWith('refs/heads/')) {
    return normalized.slice('refs/heads/'.length);
  }
  return normalized;
}

function normalizeGovernorMode(value) {
  const normalized = String(value ?? '')
    .trim()
    .toLowerCase();
  if (normalized === 'normal' || normalized === 'stabilize' || normalized === 'pause') {
    return normalized;
  }
  return 'normal';
}

function projectOptionalStateEnvelope(envelope, { path: statePath, allowedStatuses = null } = {}) {
  const payload = envelope && typeof envelope === 'object' && 'payload' in envelope ? envelope.payload : envelope;
  const rawStatus = typeof payload?.status === 'string' ? payload.status : null;
  return {
    path: statePath,
    exists:
      envelope && typeof envelope === 'object' && 'exists' in envelope ? Boolean(envelope.exists) : Boolean(payload),
    error: envelope && typeof envelope === 'object' && 'error' in envelope ? envelope.error : null,
    status: allowedStatuses && !allowedStatuses.has(rawStatus) ? null : rawStatus,
    generatedAt: normalizeIso(payload?.generatedAt),
    sourceSchema: typeof payload?.schema === 'string' ? payload.schema : null
  };
}

function priorityFromTitle(title = '') {
  const match = String(title).match(/\[P(?<priority>\d+)\]/i);
  if (!match?.groups?.priority) {
    return 9;
  }
  const parsed = Number(match.groups.priority);
  if (!Number.isInteger(parsed) || parsed < 0) {
    return 9;
  }
  return parsed;
}

function parseCoupling(body = '') {
  const match = String(body).match(/^\s*Coupling\s*:\s*(?<coupling>independent|soft|hard)\s*$/im);
  const value = match?.groups?.coupling?.toLowerCase() ?? 'independent';
  return COUPLING_VALUES.has(value) ? value : 'independent';
}

function parseDependsOn(body = '') {
  const match = String(body).match(/^\s*Depends-On\s*:\s*(?<deps>[^\n\r]+)\s*$/im);
  if (!match?.groups?.deps) {
    return [];
  }
  const deps = new Set();
  for (const token of match.groups.deps.split(',')) {
    const depMatch = token.match(/#(?<number>\d+)/);
    if (!depMatch?.groups?.number) continue;
    const number = Number(depMatch.groups.number);
    if (Number.isInteger(number) && number > 0) {
      deps.add(number);
    }
  }
  return [...deps].sort((a, b) => a - b);
}

function checkRollupToMap(rollup = []) {
  const states = new Map();
  for (const entry of rollup) {
    if (!entry) continue;
    const typename = entry.__typename ?? '';
    if (typename === 'CheckRun') {
      const context = entry.name?.trim();
      if (!context) continue;
      const status = String(entry.status ?? '').toUpperCase();
      const conclusion = String(entry.conclusion ?? '').toUpperCase();
      const isSuccess = status === 'COMPLETED' && conclusion === 'SUCCESS';
      const isFailure = status !== 'COMPLETED' || (conclusion && conclusion !== 'SUCCESS' && conclusion !== 'NEUTRAL' && conclusion !== 'SKIPPED');
      const previous = states.get(context) ?? { success: false, failure: false, raw: [] };
      previous.success = previous.success || isSuccess;
      previous.failure = previous.failure || isFailure;
      previous.raw.push({ typename, status, conclusion });
      states.set(context, previous);
      continue;
    }
    if (typename === 'StatusContext') {
      const context = entry.context?.trim();
      if (!context) continue;
      const state = String(entry.state ?? '').toUpperCase();
      const isSuccess = state === 'SUCCESS';
      const isFailure = state !== 'SUCCESS';
      const previous = states.get(context) ?? { success: false, failure: false, raw: [] };
      previous.success = previous.success || isSuccess;
      previous.failure = previous.failure || isFailure;
      previous.raw.push({ typename, state });
      states.set(context, previous);
    }
  }
  return states;
}

export function evaluateRequiredChecks(requiredChecks, statusCheckRollup) {
  const required = Array.isArray(requiredChecks) ? requiredChecks : [];
  if (required.length === 0) {
    return { ok: true, missing: [], failing: [] };
  }
  const states = checkRollupToMap(statusCheckRollup);
  const missing = [];
  const failing = [];
  for (const context of required) {
    const entry = states.get(context);
    if (!entry) {
      missing.push(context);
      continue;
    }
    if (!entry.success || entry.failure) {
      failing.push(context);
    }
  }
  return {
    ok: missing.length === 0 && failing.length === 0,
    missing,
    failing
  };
}

function compareCandidates(a, b) {
  if (a.priority !== b.priority) {
    return a.priority - b.priority;
  }
  if (a.couplingOrder !== b.couplingOrder) {
    return a.couplingOrder - b.couplingOrder;
  }
  const aTime = Date.parse(a.updatedAt) || 0;
  const bTime = Date.parse(b.updatedAt) || 0;
  if (aTime !== bTime) {
    return aTime - bTime;
  }
  return a.number - b.number;
}

function toTopoOrder(candidates) {
  const nodes = new Map(candidates.map((candidate) => [candidate.number, candidate]));
  const indegree = new Map();
  const edges = new Map();
  for (const candidate of candidates) {
    indegree.set(candidate.number, 0);
    edges.set(candidate.number, []);
  }

  for (const candidate of candidates) {
    for (const dep of candidate.dependsOn) {
      if (!nodes.has(dep)) continue;
      indegree.set(candidate.number, (indegree.get(candidate.number) ?? 0) + 1);
      edges.get(dep).push(candidate.number);
    }
  }

  const ready = [...candidates.filter((candidate) => (indegree.get(candidate.number) ?? 0) === 0)].sort(compareCandidates);
  const order = [];
  while (ready.length > 0) {
    const next = ready.shift();
    order.push(next);
    for (const target of edges.get(next.number) ?? []) {
      indegree.set(target, (indegree.get(target) ?? 0) - 1);
      if ((indegree.get(target) ?? 0) === 0) {
        ready.push(nodes.get(target));
        ready.sort(compareCandidates);
      }
    }
  }

  if (order.length === candidates.length) {
    return { ordered: order, cycleDetected: false };
  }

  const unresolved = candidates
    .filter((candidate) => !order.some((selected) => selected.number === candidate.number))
    .sort(compareCandidates);
  return { ordered: [...order, ...unresolved], cycleDetected: true };
}

export function classifyOpenPullRequests({
  pullRequests,
  requiredChecksByBranch,
  queueManagedBranches,
  excludedLabels = EXCLUDED_LABELS
}) {
  const allOpen = new Map();
  const normalized = [];
  for (const pr of pullRequests ?? []) {
    const labels = (pr.labels ?? []).map(normalizeLabelName).filter(Boolean);
    const baseRefName = normalizeBaseBranch(pr.baseRefName);
    const parsed = {
      number: Number(pr.number),
      title: pr.title ?? '',
      url: pr.url ?? null,
      updatedAt: normalizeIso(pr.updatedAt) ?? new Date(0).toISOString(),
      baseRefName,
      headRefName: pr.headRefName ?? null,
      headRepositoryOwner: normalizeOwner(pr.headRepositoryOwner),
      isCrossRepository: Boolean(pr.isCrossRepository),
      isDraft: Boolean(pr.isDraft),
      mergeStateStatus: String(pr.mergeStateStatus ?? '').toUpperCase(),
      mergeable: String(pr.mergeable ?? '').toUpperCase(),
      isInMergeQueue: pr.isInMergeQueue === true,
      labels,
      autoMergeEnabled: Boolean(pr.autoMergeRequest),
      coupling: parseCoupling(pr.body ?? ''),
      dependsOn: parseDependsOn(pr.body ?? ''),
      priority: priorityFromTitle(pr.title ?? ''),
      couplingOrder: COUPLING_PRIORITY[parseCoupling(pr.body ?? '')] ?? COUPLING_PRIORITY.independent,
      statusCheckRollup: Array.isArray(pr.statusCheckRollup) ? pr.statusCheckRollup : []
    };
    allOpen.set(parsed.number, parsed);
    normalized.push(parsed);
  }

  const candidates = [];
  for (const pr of normalized) {
    const reasons = [];
    if (!queueManagedBranches.has(pr.baseRefName)) {
      reasons.push('base-branch-not-queue-managed');
    }
    if (pr.isDraft) {
      reasons.push('draft');
    }
    if (pr.mergeStateStatus === 'DIRTY' || pr.mergeable === 'CONFLICTING') {
      reasons.push('merge-conflict');
    }
    if (pr.labels.some((label) => excludedLabels.has(label))) {
      reasons.push('queue-label-blocked');
    }

    const requiredChecks = requiredChecksByBranch[pr.baseRefName] ?? [];
    const checks = evaluateRequiredChecks(requiredChecks, pr.statusCheckRollup);
    if (!checks.ok) {
      if (checks.missing.length > 0) reasons.push('required-checks-missing');
      if (checks.failing.length > 0) reasons.push('required-checks-failing');
    }

    candidates.push({
      ...pr,
      requiredChecks,
      checks,
      eligible: reasons.length === 0,
      reasons
    });
  }

  const initiallyEligible = candidates.filter((candidate) => candidate.eligible);
  const eligibleSet = new Set(initiallyEligible.map((candidate) => candidate.number));

  for (const candidate of initiallyEligible) {
    const unresolvedOpenDependencies = candidate.dependsOn.filter((dep) => allOpen.has(dep) && !eligibleSet.has(dep));
    if (unresolvedOpenDependencies.length > 0) {
      candidate.eligible = false;
      candidate.reasons.push('dependency-open-not-eligible');
      candidate.unresolvedOpenDependencies = unresolvedOpenDependencies;
    } else {
      candidate.unresolvedOpenDependencies = [];
    }
  }

  const finalEligible = candidates.filter((candidate) => candidate.eligible);
  const topo = toTopoOrder(finalEligible);
  return {
    allOpen: normalized,
    candidates,
    orderedEligible: topo.ordered,
    cycleDetected: topo.cycleDetected
  };
}

function parseRemoteRepository(repoRoot, remoteName) {
  const result = spawnSync('git', ['config', '--get', `remote.${remoteName}.url`], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore']
  });
  if (result.status !== 0) {
    return null;
  }
  return parseRemoteUrl(result.stdout.trim());
}

function resolveRepositorySlug(repoRoot, explicit) {
  if (explicit) return explicit;
  if (process.env.GITHUB_REPOSITORY && process.env.GITHUB_REPOSITORY.includes('/')) {
    return process.env.GITHUB_REPOSITORY.trim();
  }
  const upstream = parseRemoteRepository(repoRoot, 'upstream');
  if (upstream) {
    return `${upstream.owner}/${upstream.repo}`;
  }
  const origin = parseRemoteRepository(repoRoot, 'origin');
  if (origin) {
    return `${origin.owner}/${origin.repo}`;
  }
  throw new Error('Unable to resolve target repository. Use --repo owner/repo.');
}

async function readJsonFile(filePath) {
  const raw = await readFile(filePath, 'utf8');
  return JSON.parse(raw);
}

async function readOptionalJson(filePath) {
  if (!existsSync(filePath)) {
    return null;
  }
  try {
    return await readJsonFile(filePath);
  } catch {
    return null;
  }
}

function runGhJson(args, { cwd, allowFailure = false } = {}) {
  const result = spawnSync('gh', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    if (allowFailure) {
      return { ok: false, status: result.status ?? 1, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
    }
    throw new Error(`gh ${args.join(' ')} failed: ${(result.stderr || result.stdout || '').trim()}`);
  }
  const payload = (result.stdout || '').trim();
  if (!payload) {
    return null;
  }
  return JSON.parse(payload);
}

function runCommand(command, args, { cwd, allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0 && !allowFailure) {
    throw new Error(`${command} ${args.join(' ')} failed: ${(result.stderr || result.stdout || '').trim()}`);
  }
  return {
    status: result.status ?? 1,
    stdout: (result.stdout || '').trim(),
    stderr: (result.stderr || '').trim()
  };
}

export function evaluateHealthGate({
  workflowRunsByName,
  now = new Date(),
  minSuccessRate = DEFAULT_HEALTH_MIN_SUCCESS_RATE,
  maxRedMinutes = DEFAULT_HEALTH_MAX_RED_MINUTES,
  lookbackDays = DEFAULT_HEALTH_LOOKBACK_DAYS
}) {
  const runs = [];
  for (const [workflow, workflowRuns] of Object.entries(workflowRunsByName ?? {})) {
    for (const run of workflowRuns ?? []) {
      runs.push({
        workflow,
        conclusion: String(run.conclusion ?? '').toLowerCase(),
        status: String(run.status ?? '').toLowerCase(),
        createdAt: normalizeIso(run.created_at ?? run.createdAt),
        updatedAt: normalizeIso(run.updated_at ?? run.updatedAt),
        url: run.html_url ?? run.url ?? null
      });
    }
  }

  runs.sort((a, b) => runTimestampMs(b) - runTimestampMs(a));
  const lookbackMs =
    Number.isFinite(lookbackDays) && lookbackDays > 0
      ? lookbackDays * 24 * 60 * 60 * 1000
      : null;
  const filteredRuns =
    lookbackMs == null
      ? runs
      : runs.filter((run) => {
          const stamp = runTimestampMs(run);
          return Number.isFinite(stamp) && now.valueOf() - stamp <= lookbackMs;
        });

  const sampleSize = filteredRuns.length;
  const successful = filteredRuns.filter((run) => run.conclusion === 'success').length;
  const successRate = sampleSize === 0 ? 0 : successful / sampleSize;
  const latest = filteredRuns[0] ?? null;
  const lastSuccess = filteredRuns.find((run) => run.conclusion === 'success') ?? null;

  let redMinutes = 0;
  if (latest && latest.conclusion !== 'success') {
    if (!lastSuccess?.updatedAt) {
      redMinutes = Number.POSITIVE_INFINITY;
    } else {
      redMinutes = (now.valueOf() - Date.parse(lastSuccess.updatedAt)) / 60000;
    }
  }

  const reasons = [];
  if (sampleSize === 0) {
    reasons.push('insufficient-health-data');
  }
  if (successRate < minSuccessRate) {
    reasons.push('success-rate-below-threshold');
  }
  if (redMinutes > maxRedMinutes) {
    reasons.push('trunk-red-window-exceeded');
  }

  return {
    paused: reasons.length > 0,
    reasons,
    sampleSize,
    successful,
    successRate,
    redMinutes: Number.isFinite(redMinutes) ? Number(redMinutes.toFixed(2)) : redMinutes,
    minSuccessRate,
    maxRedMinutes,
    latest
  };
}

function normalizeRunStatus(value) {
  return String(value ?? '').trim().toLowerCase();
}

function normalizeRunConclusion(value) {
  return String(value ?? '').trim().toLowerCase();
}

function runTimestampMs(run) {
  const updated = Date.parse(run.updatedAt ?? '');
  if (Number.isFinite(updated)) {
    return updated;
  }
  const created = Date.parse(run.createdAt ?? '');
  if (Number.isFinite(created)) {
    return created;
  }
  return Number.NaN;
}

function runAgeMinutes(run, nowMs) {
  const stamp = runTimestampMs(run);
  if (!Number.isFinite(stamp)) {
    return Number.POSITIVE_INFINITY;
  }
  return Math.max(0, (nowMs - stamp) / 60000);
}

function toRuntimeFleetRuns(workflowRunsByName = {}) {
  const runs = [];
  for (const [workflow, workflowRuns] of Object.entries(workflowRunsByName)) {
    for (const run of workflowRuns ?? []) {
      runs.push({
        workflow,
        id: run.id ?? run.run_id ?? null,
        status: normalizeRunStatus(run.status),
        conclusion: normalizeRunConclusion(run.conclusion),
        createdAt: normalizeIso(run.created_at ?? run.createdAt),
        updatedAt: normalizeIso(run.updated_at ?? run.updatedAt),
        branch: normalizeBaseBranch(run.head_branch ?? run.headBranch ?? ''),
        url: run.html_url ?? run.url ?? null
      });
    }
  }
  return runs;
}

export function evaluateRuntimeFleetHealth({
  workflowRunsByName,
  now = new Date(),
  maxQueuedRuns = DEFAULT_MAX_QUEUED_RUNS,
  maxInProgressRuns = DEFAULT_MAX_IN_PROGRESS_RUNS,
  stallThresholdMinutes = DEFAULT_STALL_THRESHOLD_MINUTES
}) {
  const nowMs = now.valueOf();
  const runs = toRuntimeFleetRuns(workflowRunsByName);
  const queuedStatuses = new Set(['queued', 'requested', 'waiting', 'pending']);
  const inProgressStatuses = new Set(['in_progress']);

  const queuedRuns = [];
  const inProgressRuns = [];
  const stalledRuns = [];

  for (const run of runs) {
    if (queuedStatuses.has(run.status)) {
      const ageMinutes = runAgeMinutes(run, nowMs);
      queuedRuns.push({ ...run, ageMinutes: Number.isFinite(ageMinutes) ? Number(ageMinutes.toFixed(2)) : ageMinutes });
      if (ageMinutes > stallThresholdMinutes) {
        stalledRuns.push({ ...run, ageMinutes: Number.isFinite(ageMinutes) ? Number(ageMinutes.toFixed(2)) : ageMinutes });
      }
      continue;
    }
    if (inProgressStatuses.has(run.status)) {
      const ageMinutes = runAgeMinutes(run, nowMs);
      inProgressRuns.push({ ...run, ageMinutes: Number.isFinite(ageMinutes) ? Number(ageMinutes.toFixed(2)) : ageMinutes });
      if (ageMinutes > stallThresholdMinutes) {
        stalledRuns.push({ ...run, ageMinutes: Number.isFinite(ageMinutes) ? Number(ageMinutes.toFixed(2)) : ageMinutes });
      }
    }
  }

  stalledRuns.sort((left, right) => (right.ageMinutes || 0) - (left.ageMinutes || 0));
  const reasons = [];
  if (queuedRuns.length > maxQueuedRuns) {
    reasons.push('queued-runs-threshold-exceeded');
  }
  if (inProgressRuns.length > maxInProgressRuns) {
    reasons.push('in-progress-runs-threshold-exceeded');
  }
  if (stalledRuns.length > 0) {
    reasons.push('stalled-runs-detected');
  }

  return {
    paused: reasons.length > 0,
    reasons,
    totals: {
      queued: queuedRuns.length,
      inProgress: inProgressRuns.length,
      active: queuedRuns.length + inProgressRuns.length,
      stalled: stalledRuns.length
    },
    thresholds: {
      maxQueuedRuns,
      maxInProgressRuns,
      stallThresholdMinutes
    },
    stalledRuns
  };
}

function normalizeControllerMode(value) {
  const normalized = String(value ?? '')
    .trim()
    .toLowerCase();
  if (normalized === 'healthy' || normalized === 'guarded' || normalized === 'stabilize' || normalized === 'fixed') {
    return normalized;
  }
  return null;
}

function modeRank(mode) {
  if (mode === 'stabilize') return 0;
  if (mode === 'guarded') return 1;
  if (mode === 'healthy') return 2;
  return -1;
}

function modeFromRank(rank) {
  if (rank <= 0) return 'stabilize';
  if (rank === 1) return 'guarded';
  return 'healthy';
}

function deriveModeCaps(configuredMax, configuredMin) {
  const healthy = configuredMax;
  const stabilize = configuredMin;
  const guarded = Math.max(stabilize, Math.min(healthy, healthy - 2));
  return { healthy, guarded, stabilize };
}

function toFiniteNumber(value, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : fallback;
}

function normalizeRatio(value) {
  const numeric = toFiniteNumber(value, 0);
  if (numeric < 0) return 0;
  return Number(numeric.toFixed(3));
}

function normalizeCount(value) {
  return Math.max(0, Math.trunc(toFiniteNumber(value, 0)));
}

function buildWorkerOccupancySummary({
  runtimeState,
  runtimeStatePath = DEFAULT_RUNTIME_STATE_PATH,
  currentCycleIdleAuthority = null
} = {}) {
  const workerPool =
    runtimeState?.workerPool && typeof runtimeState.workerPool === 'object' && !Array.isArray(runtimeState.workerPool)
      ? runtimeState.workerPool
      : null;
  const idleAuthorityObserved = currentCycleIdleAuthority?.status === 'observed';
  const targetSlotCount = normalizeCount(workerPool?.targetSlotCount);
  const staleRuntimeSuppressed =
    idleAuthorityObserved
    && (normalizeCount(workerPool?.occupiedSlotCount) > 0 || normalizeCount(runtimeState?.activeCodingLanes) > 0);

  return {
    runtimeStatePath,
    available: Boolean(workerPool),
    authoritySource: idleAuthorityObserved ? 'current-cycle-idle' : 'delivery-runtime',
    targetSlotCount,
    occupiedSlotCount: idleAuthorityObserved ? 0 : normalizeCount(workerPool?.occupiedSlotCount),
    availableSlotCount: idleAuthorityObserved ? targetSlotCount : normalizeCount(workerPool?.availableSlotCount),
    releasedLaneCount: idleAuthorityObserved ? 0 : normalizeCount(workerPool?.releasedLaneCount),
    utilizationRatio: idleAuthorityObserved ? 0 : normalizeRatio(workerPool?.utilizationRatio),
    activeCodingLanes: idleAuthorityObserved ? 0 : normalizeCount(runtimeState?.activeCodingLanes),
    staleRuntimeSuppressed,
    currentCycleIdleAuthority: {
      status: currentCycleIdleAuthority?.status ?? 'missing',
      source: currentCycleIdleAuthority?.source ?? null,
      observedAt: currentCycleIdleAuthority?.observedAt ?? null,
      nextWakeCondition: currentCycleIdleAuthority?.nextWakeCondition ?? null
    }
  };
}

export function computeRetryPressure(retryHistory = {}, candidateCount = 0) {
  let failureEvents = 0;
  let activeFailurePrs = 0;
  let quarantinedPrs = 0;

  for (const entry of Object.values(retryHistory)) {
    const failures = Array.isArray(entry?.failures) ? entry.failures : [];
    if (failures.length === 0) {
      continue;
    }
    activeFailurePrs += 1;
    failureEvents += failures.length;
    if (failures.length >= 2) {
      quarantinedPrs += 1;
    }
  }

  const denominator = Math.max(1, Number(candidateCount) || 0);
  const retryRatio = failureEvents / denominator;
  const quarantineRatio = quarantinedPrs / Math.max(1, activeFailurePrs);
  return {
    failureEvents,
    activeFailurePrs,
    quarantinedPrs,
    retryRatio: normalizeRatio(retryRatio),
    quarantineRatio: normalizeRatio(quarantineRatio)
  };
}

export function pruneRetryHistory(retryHistory = {}, nowIso, windowHours = RETRY_WINDOW_HOURS) {
  const normalized = {};
  const nowMs = Date.parse(nowIso);
  const cutoff = nowMs - windowHours * 60 * 60 * 1000;

  for (const [key, entry] of Object.entries(retryHistory)) {
    const failures = Array.isArray(entry?.failures) ? entry.failures : [];
    const retained = failures.filter((value) => {
      const timestamp = Date.parse(value);
      return Number.isFinite(timestamp) && timestamp >= cutoff;
    });
    if (retained.length > 0) {
      normalized[key] = { failures: retained };
    }
  }
  return normalized;
}

function evaluateDesiredControllerMode({
  successRate,
  saturation,
  stalled,
  retryRatio,
  quarantineRatio,
  thresholds = CONTROLLER_THRESHOLDS
}) {
  const severeReasons = [];
  const warningReasons = [];

  if (successRate < thresholds.severeSuccessRate) severeReasons.push('success-rate-severe');
  if (saturation >= thresholds.severeSaturation) severeReasons.push('runtime-saturation-severe');
  if (stalled > 0) severeReasons.push('stalled-runs-detected');
  if (retryRatio >= thresholds.severeRetryRatio) severeReasons.push('retry-ratio-severe');
  if (quarantineRatio >= thresholds.severeQuarantineRatio) severeReasons.push('quarantine-ratio-severe');

  if (severeReasons.length > 0) {
    return {
      desiredMode: 'stabilize',
      reasons: severeReasons
    };
  }

  if (successRate < thresholds.warningSuccessRate) warningReasons.push('success-rate-warning');
  if (saturation >= thresholds.warningSaturation) warningReasons.push('runtime-saturation-warning');
  if (retryRatio >= thresholds.warningRetryRatio) warningReasons.push('retry-ratio-warning');
  if (quarantineRatio >= thresholds.warningQuarantineRatio) warningReasons.push('quarantine-ratio-warning');

  return {
    desiredMode: warningReasons.length > 0 ? 'guarded' : 'healthy',
    reasons: warningReasons
  };
}

function applyControllerHysteresis({
  desiredMode,
  previousMode,
  previousUpgradeStreak,
  requiredUpgradeStreak = CONTROLLER_REQUIRED_UPGRADE_STREAK
}) {
  const normalizedPreviousMode = normalizeControllerMode(previousMode);
  if (!normalizedPreviousMode || normalizedPreviousMode === 'fixed') {
    return {
      mode: desiredMode,
      desiredMode,
      transition: 'initialized',
      upgradeStreak: 0
    };
  }

  const previousRank = modeRank(normalizedPreviousMode);
  let desiredRank = modeRank(desiredMode);
  if (desiredRank > previousRank + 1) {
    desiredRank = previousRank + 1;
  }
  const cappedDesiredMode = modeFromRank(desiredRank);

  if (desiredRank < previousRank) {
    return {
      mode: cappedDesiredMode,
      desiredMode: cappedDesiredMode,
      transition: 'downgrade-applied',
      upgradeStreak: 0
    };
  }

  if (desiredRank === previousRank) {
    return {
      mode: cappedDesiredMode,
      desiredMode: cappedDesiredMode,
      transition: 'unchanged',
      upgradeStreak: 0
    };
  }

  const streak = Math.max(0, Number(previousUpgradeStreak) || 0) + 1;
  if (streak >= requiredUpgradeStreak) {
    return {
      mode: cappedDesiredMode,
      desiredMode: cappedDesiredMode,
      transition: 'upgrade-applied',
      upgradeStreak: 0
    };
  }

  return {
    mode: normalizedPreviousMode,
    desiredMode: cappedDesiredMode,
    transition: 'upgrade-pending',
    upgradeStreak: streak
  };
}

function readPreviousControllerUpgradeStreak(previousControllerState) {
  const direct = Number(previousControllerState?.upgradeStreak);
  if (Number.isFinite(direct) && direct >= 0) {
    return Math.trunc(direct);
  }

  const nested = Number(previousControllerState?.hysteresis?.upgradeStreak);
  if (Number.isFinite(nested) && nested >= 0) {
    return Math.trunc(nested);
  }

  return 0;
}

export function evaluateAdaptiveInflight({
  maxInflight,
  minInflight = DEFAULT_MIN_INFLIGHT,
  adaptiveCap = true,
  health,
  runtimeFleet,
  retryPressure = null,
  previousControllerState = null
}) {
  const configuredMax = parseIntStrict(maxInflight, { label: 'maxInflight' });
  const configuredMin = parseIntStrict(minInflight, { label: 'minInflight' });
  if (configuredMin > configuredMax) {
    throw new Error(`Adaptive inflight floor (${configuredMin}) cannot exceed max inflight (${configuredMax}).`);
  }

  const caps = deriveModeCaps(configuredMax, configuredMin);
  const successRate = toFiniteNumber(health?.successRate, 0);
  const queued = toFiniteNumber(runtimeFleet?.totals?.queued, 0);
  const inProgress = toFiniteNumber(runtimeFleet?.totals?.inProgress, 0);
  const stalled = toFiniteNumber(runtimeFleet?.totals?.stalled, 0);
  const maxQueued = Math.max(1, toFiniteNumber(runtimeFleet?.thresholds?.maxQueuedRuns, DEFAULT_MAX_QUEUED_RUNS));
  const maxInProgress = Math.max(
    1,
    toFiniteNumber(runtimeFleet?.thresholds?.maxInProgressRuns, DEFAULT_MAX_IN_PROGRESS_RUNS)
  );
  const saturation = Math.max(queued / maxQueued, inProgress / maxInProgress);
  const retryRatio = normalizeRatio(retryPressure?.retryRatio);
  const quarantineRatio = normalizeRatio(retryPressure?.quarantineRatio);

  if (!adaptiveCap) {
    return {
      enabled: false,
      configuredMaxInflight: configuredMax,
      minInflight: configuredMin,
      effectiveMaxInflight: configuredMax,
      tier: 'fixed',
      mode: 'fixed',
      desiredMode: 'fixed',
      capByMode: caps,
      reasons: [],
      metrics: {
        successRate: normalizeRatio(successRate),
        saturation: normalizeRatio(saturation),
        queued,
        inProgress,
        stalled,
        retryRatio,
        quarantineRatio
      },
      thresholds: CONTROLLER_THRESHOLDS,
      hysteresis: {
        previousMode: normalizeControllerMode(previousControllerState?.mode),
        transition: 'fixed-cap-disabled',
        upgradeStreak: 0,
        requiredUpgradeStreak: CONTROLLER_REQUIRED_UPGRADE_STREAK
      }
    };
  }

  const desired = evaluateDesiredControllerMode({
    successRate,
    saturation,
    stalled,
    retryRatio,
    quarantineRatio
  });
  const hysteresis = applyControllerHysteresis({
    desiredMode: desired.desiredMode,
    previousMode: previousControllerState?.mode,
    previousUpgradeStreak: readPreviousControllerUpgradeStreak(previousControllerState),
    requiredUpgradeStreak: CONTROLLER_REQUIRED_UPGRADE_STREAK
  });
  const effectiveMaxInflight = caps[hysteresis.mode] ?? configuredMin;

  return {
    enabled: true,
    configuredMaxInflight: configuredMax,
    minInflight: configuredMin,
    effectiveMaxInflight,
    tier: hysteresis.mode,
    mode: hysteresis.mode,
    desiredMode: hysteresis.desiredMode,
    capByMode: caps,
    reasons: [...new Set(desired.reasons)],
    metrics: {
      successRate: normalizeRatio(successRate),
      saturation: normalizeRatio(saturation),
      queued,
      inProgress,
      stalled,
      retryRatio,
      quarantineRatio
    },
    thresholds: CONTROLLER_THRESHOLDS,
    hysteresis: {
      previousMode: normalizeControllerMode(previousControllerState?.mode),
      transition: hysteresis.transition,
      upgradeStreak: hysteresis.upgradeStreak,
      requiredUpgradeStreak: CONTROLLER_REQUIRED_UPGRADE_STREAK
    }
  };
}

function hasReleaseBranchPullRequest(pullRequests = []) {
  return (pullRequests ?? []).some((pr) => {
    const headRefName = String(pr?.headRefName ?? '')
      .trim()
      .toLowerCase();
    const baseRefName = normalizeBaseBranch(pr?.baseRefName);
    return headRefName.startsWith('release/') || baseRefName.startsWith('release/');
  });
}

function hasReleaseBurstLabel(pullRequests = []) {
  return (pullRequests ?? []).some((pr) =>
    (pr?.labels ?? []).some((label) => normalizeLabelName(label) === 'release-burst')
  );
}

function isReleaseWindow(now = new Date()) {
  const utcDay = now.getUTCDay();
  const utcDate = now.getUTCDate();
  const utcHour = now.getUTCHours();
  return utcDay === RELEASE_WINDOW_DAY_UTC && utcDate <= RELEASE_WINDOW_MAX_DAY_OF_MONTH && utcHour === RELEASE_WINDOW_HOUR_UTC;
}

export function evaluateBurstWindow({
  burstMode = DEFAULT_BURST_MODE,
  burstRefillCycles = DEFAULT_BURST_REFILL_CYCLES,
  pullRequests = [],
  previousBurst = null,
  controllerMode = null,
  now = new Date()
} = {}) {
  const mode = parseBurstMode(burstMode, { label: 'burstMode' });
  const configuredRefillCycles = parseIntStrict(burstRefillCycles, { label: 'burstRefillCycles' });
  const nowMs = now.valueOf();
  const previousBackoffUntil = normalizeIso(previousBurst?.backoffUntil);
  let backoffUntil = previousBackoffUntil;
  let backoffActive = false;
  if (previousBackoffUntil) {
    const backoffUntilMs = Date.parse(previousBackoffUntil);
    backoffActive = Number.isFinite(backoffUntilMs) && backoffUntilMs > nowMs;
  }

  const stabilized = normalizeControllerMode(controllerMode) === 'stabilize';
  if (stabilized) {
    backoffUntil = new Date(nowMs + BURST_BACKOFF_MINUTES * 60 * 1000).toISOString();
    backoffActive = true;
  }

  const triggerSignals = Object.freeze({
    releaseWindow: isReleaseWindow(now),
    releaseBranchPullRequest: hasReleaseBranchPullRequest(pullRequests),
    releaseBurstLabel: hasReleaseBurstLabel(pullRequests)
  });
  const triggerReasons = [];
  if (triggerSignals.releaseWindow) triggerReasons.push('release-window');
  if (triggerSignals.releaseBranchPullRequest) triggerReasons.push('open-release-branch-pr');
  if (triggerSignals.releaseBurstLabel) triggerReasons.push('release-burst-label');
  const triggerActive = triggerReasons.length > 0;

  let refillCyclesRemaining = 0;
  const previousRefillCycles = Math.max(0, Number(previousBurst?.refillCyclesRemaining) || 0);
  if (mode === 'auto') {
    if (triggerActive) {
      refillCyclesRemaining = configuredRefillCycles;
    } else if (previousRefillCycles > 0) {
      refillCyclesRemaining = previousRefillCycles - 1;
    }
  } else if (mode === 'on') {
    refillCyclesRemaining = configuredRefillCycles;
  }

  const reasons = [];
  let active = false;
  if (mode === 'off') {
    reasons.push('burst-mode-off');
  } else if (backoffActive) {
    reasons.push('stabilize-backoff');
  } else if (mode === 'on') {
    active = true;
    reasons.push('burst-mode-on');
  } else if (triggerActive) {
    active = true;
    reasons.push(...triggerReasons);
  } else if (refillCyclesRemaining > 0) {
    active = true;
    reasons.push('refill-cycles');
  } else {
    reasons.push('no-burst-trigger');
  }

  return {
    mode,
    active,
    configuredRefillCycles,
    refillCyclesRemaining,
    backoffMinutes: BURST_BACKOFF_MINUTES,
    backoffUntil,
    backoffActive,
    triggerSignals,
    triggerReasons,
    reasons: [...new Set(reasons)],
    stabilized
  };
}

function parseQueueManagedBranches(policy, fallbackBranches) {
  const queueManaged = new Set();
  const rulesets = policy?.rulesets ?? {};
  for (const ruleset of Object.values(rulesets)) {
    if (!ruleset?.merge_queue) {
      continue;
    }
    for (const include of ruleset.includes ?? []) {
      const match = String(include).match(/^refs\/heads\/(.+)$/i);
      if (!match?.[1]) continue;
      const branch = normalizeBaseBranch(match[1]);
      if (!branch.includes('*')) {
        queueManaged.add(branch);
      }
    }
  }

  if (queueManaged.size === 0) {
    for (const branch of fallbackBranches ?? []) {
      queueManaged.add(normalizeBaseBranch(branch));
    }
  }
  return queueManaged;
}

function countInflight(candidates) {
  return candidates.filter((candidate) => isQueuedCandidate(candidate)).length;
}

function isQueuedCandidate(candidate) {
  return candidate?.isInMergeQueue === true || candidate?.autoMergeEnabled === true;
}

function buildPullRequestQueueStateQuery(numbers) {
  const selections = numbers
    .map((number) => {
      const alias = `pr_${number}`;
      return [
        `      ${alias}: pullRequest(number:${number}) {`,
        '        number',
        '        state',
        '        mergeStateStatus',
        '        isInMergeQueue',
        '        autoMergeRequest {',
        '          enabledAt',
        '        }',
        '      }'
      ].join('\n');
    })
    .join('\n');

  return [
    'query($owner:String!, $repo:String!) {',
    '  repository(owner:$owner, name:$repo) {',
    selections,
    '  }',
    '}'
  ].join('\n');
}

async function readPullRequestQueueStates({
  repoRoot,
  repository,
  pullRequestNumbers,
  runGhGraphqlFn = null
} = {}) {
  const numbers = [...new Set((pullRequestNumbers ?? []).map((value) => Number(value)).filter((value) => Number.isInteger(value) && value > 0))]
    .sort((left, right) => left - right);
  if (numbers.length === 0) {
    return {
      states: new Map(),
      attempted: false,
      error: null
    };
  }
  if (typeof runGhGraphqlFn !== 'function') {
    return {
      states: new Map(),
      attempted: false,
      error: null
    };
  }

  const { owner, repo } = parseRepositorySlug(repository);
  try {
    const payload = runGhGraphqlFn(repoRoot, buildPullRequestQueueStateQuery(numbers), { owner, repo }) ?? {};
    const repositoryNode = payload?.data?.repository ?? {};
    const states = new Map();
    for (const number of numbers) {
      const node = repositoryNode[`pr_${number}`];
      if (node?.number) {
        states.set(Number(node.number), node);
      }
    }
    return {
      states,
      attempted: true,
      error: null
    };
  } catch (error) {
    return {
      states: new Map(),
      attempted: true,
      error: error?.message ?? String(error)
    };
  }
}

function reportRetryState(history, number) {
  const key = String(number);
  const failures = Array.isArray(history?.[key]?.failures) ? history[key].failures : [];
  return failures;
}

function appendFailure(history, number, atIso, windowHours = RETRY_WINDOW_HOURS) {
  const key = String(number);
  const nowMs = Date.parse(atIso);
  const cutoff = nowMs - windowHours * 60 * 60 * 1000;
  const existing = reportRetryState(history, number);
  const retained = existing.filter((value) => Date.parse(value) >= cutoff);
  retained.push(atIso);
  history[key] = { failures: retained };
  return retained.length;
}

function clearFailure(history, number) {
  const key = String(number);
  if (history[key]) {
    delete history[key];
  }
}

async function writeReport(reportPath, report) {
  const resolved = path.resolve(reportPath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

const HEALTH_WORKFLOW_SPECS = Object.freeze([
  { name: 'Validate', file: 'validate.yml' },
  { name: 'Policy Guard (Upstream)', file: 'policy-guard-upstream.yml' },
  { name: 'Fixture Drift Validation', file: 'fixture-drift.yml' },
  { name: 'commit-integrity', file: 'commit-integrity.yml' }
]);

function fetchWorkflowRunsByName({
  runGhJsonFn,
  repository,
  healthBranch,
  sampleSize,
  cwd
}) {
  const workflowRunsByName = {};
  const fetchErrors = [];
  for (const spec of HEALTH_WORKFLOW_SPECS) {
    const endpoint = `repos/${repository}/actions/workflows/${spec.file}/runs?branch=${encodeURIComponent(healthBranch)}&per_page=${sampleSize}`;
    try {
      const response = runGhJsonFn(['api', endpoint], { cwd }) ?? {};
      workflowRunsByName[spec.name] = Array.isArray(response.workflow_runs) ? response.workflow_runs : [];
    } catch (error) {
      workflowRunsByName[spec.name] = [];
      fetchErrors.push({
        workflow: spec.name,
        file: spec.file,
        message: error?.message ?? String(error)
      });
    }
  }
  return { workflowRunsByName, fetchErrors };
}

export async function runQueueSupervisor(options = {}) {
  const repoRoot = options.repoRoot ?? getRepoRoot();
  const args = options.args ?? parseArgs();
  const controllerStatePath = args.controllerStatePath ?? DEFAULT_CONTROLLER_STATE_PATH;
  const readinessReportPath = args.readinessReportPath ?? DEFAULT_READINESS_REPORT_PATH;
  const runtimeStatePath = DEFAULT_RUNTIME_STATE_PATH;
  const governorStatePath = args.governorStatePath ?? DEFAULT_GOVERNOR_STATE_PATH;
  const securityIntakeReportPath = args.securityIntakeReportPath ?? DEFAULT_SECURITY_INTAKE_REPORT_PATH;
  const now = options.now ?? new Date();
  const runGhJsonFn = options.runGhJsonFn ?? runGhJson;
  const runCommandFn = options.runCommandFn ?? runCommand;
  const readdirFn = options.readdirFn ?? readdir;
  const readJsonFileFn = options.readJsonFileFn ?? readJsonFile;
  const readOptionalJsonFn = options.readOptionalJsonFn ?? readOptionalJson;
  const writeReportFn = options.writeReportFn ?? writeReport;
  const reconcileDeferredBranchCleanupFn = options.reconcileDeferredBranchCleanupFn ?? reconcileDeferredBranchCleanup;
  const runGhGraphqlFn = options.runGhGraphqlFn ?? (options.runGhJsonFn ? null : runGhGraphql);
  const repository = resolveRepositorySlug(repoRoot, args.repo);
  const repositoryOwner = String(repository).split('/')[0]?.trim().toLowerCase() ?? '';

  const branchRequiredChecks = await readJsonFileFn(path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'));
  const policyManifest = await readJsonFileFn(path.join(repoRoot, 'tools', 'priority', 'policy.json'));
  const requiredChecksByBranch = branchRequiredChecks?.branches ?? {};
  const queueManagedBranches = parseQueueManagedBranches(policyManifest, args.baseBranches);

  const allOpenPrs = runGhJsonFn([
    'pr',
    'list',
    '--repo',
    repository,
    '--state',
    'open',
    '--limit',
    '200',
    '--json',
    'number,title,body,baseRefName,headRefName,headRepositoryOwner,isCrossRepository,isDraft,updatedAt,url,labels,statusCheckRollup,mergeStateStatus,mergeable,autoMergeRequest'
  ], { cwd: repoRoot }) ?? [];

  const queueManagedPrNumbers = allOpenPrs
    .filter((pr) => queueManagedBranches.has(normalizeBaseBranch(pr.baseRefName)))
    .map((pr) => Number(pr.number));
  const queueStateEnrichment = await readPullRequestQueueStates({
    repoRoot,
    repository,
    pullRequestNumbers: queueManagedPrNumbers,
    runGhGraphqlFn
  });
  const enrichedOpenPrs = allOpenPrs.map((pr) => {
    const queueState = queueStateEnrichment.states.get(Number(pr.number));
    if (!queueState) {
      return pr;
    }
    return {
      ...pr,
      state: queueState.state ?? pr.state,
      mergeStateStatus: queueState.mergeStateStatus ?? pr.mergeStateStatus,
      isInMergeQueue: queueState.isInMergeQueue === true,
      autoMergeRequest: queueState.autoMergeRequest ?? pr.autoMergeRequest
    };
  });

  const classified = classifyOpenPullRequests({
    pullRequests: enrichedOpenPrs,
    requiredChecksByBranch,
    queueManagedBranches
  });

  const { workflowRunsByName, fetchErrors: workflowFetchErrors } = fetchWorkflowRunsByName({
    runGhJsonFn,
    repository,
    healthBranch: args.healthBranch,
    sampleSize: DEFAULT_HEALTH_SAMPLE,
    cwd: repoRoot
  });

  const health = evaluateHealthGate({ workflowRunsByName, now });
  const runtimeFleet = evaluateRuntimeFleetHealth({
    workflowRunsByName,
    now,
    maxQueuedRuns: args.maxQueuedRuns,
    maxInProgressRuns: args.maxInProgressRuns,
    stallThresholdMinutes: args.stallThresholdMinutes
  });
  const nowIso = now.toISOString();
  const previousReport = await readOptionalJsonFn(path.resolve(repoRoot, args.reportPath));
  const previousControllerState = await readOptionalJsonFn(path.resolve(repoRoot, controllerStatePath));
  let runtimeState = await readOptionalJsonFn(path.resolve(repoRoot, runtimeStatePath));
  let resolvedRuntimeStatePath = runtimeStatePath;
  if (runtimeState == null) {
    const legacyRuntimeStatePath = path.join(path.dirname(runtimeStatePath), 'runtime-state.json');
    const legacyRuntimeState = await readOptionalJsonFn(path.resolve(repoRoot, legacyRuntimeStatePath));
    if (legacyRuntimeState != null) {
      runtimeState = legacyRuntimeState;
      resolvedRuntimeStatePath = legacyRuntimeStatePath;
    }
  }
  const currentCycleIdleAuthority = deriveCurrentCycleIdleAuthority({
    deliveryRuntimeState: runtimeState,
    now
  });
  const governorStateEnvelope = await readOptionalJsonFn(path.resolve(repoRoot, governorStatePath));
  const governorStatePayload =
    governorStateEnvelope && typeof governorStateEnvelope === 'object' && 'payload' in governorStateEnvelope
      ? governorStateEnvelope.payload
      : governorStateEnvelope;
  const governorState = {
    path: governorStatePath,
    exists:
      governorStateEnvelope && typeof governorStateEnvelope === 'object' && 'exists' in governorStateEnvelope
        ? Boolean(governorStateEnvelope.exists)
        : Boolean(governorStatePayload),
    error:
      governorStateEnvelope && typeof governorStateEnvelope === 'object' && 'error' in governorStateEnvelope
        ? governorStateEnvelope.error
        : null,
    mode: normalizeGovernorMode(governorStatePayload?.mode ?? governorStatePayload?.intent),
    desiredMode: normalizeGovernorMode(governorStatePayload?.desiredMode ?? governorStatePayload?.mode),
    reasons: Array.isArray(governorStatePayload?.reasons) ? [...governorStatePayload.reasons] : [],
    generatedAt: normalizeIso(governorStatePayload?.generatedAt),
    sourceSchema: typeof governorStatePayload?.schema === 'string' ? governorStatePayload.schema : null
  };
  const securityIntakeStateEnvelope = await readOptionalJsonFn(path.resolve(repoRoot, securityIntakeReportPath));
  const securityIntake = projectOptionalStateEnvelope(securityIntakeStateEnvelope, {
    path: securityIntakeReportPath,
    allowedStatuses: SECURITY_INTAKE_STATUSES
  });
  const retryHistory = pruneRetryHistory(
    previousReport?.retryHistory && typeof previousReport.retryHistory === 'object'
      ? structuredClone(previousReport.retryHistory)
      : {},
    nowIso
  );
  const retryPressure = computeRetryPressure(retryHistory, classified.candidates.length);
  const pausedByVariable = String(process.env.QUEUE_AUTOPILOT_PAUSED ?? '').trim() === '1';
  const pausedReasons = [];
  if (pausedByVariable) pausedReasons.push('paused-by-variable');
  if (governorState.mode === 'pause') pausedReasons.push('governor-pause');
  if (health.paused) pausedReasons.push(...health.reasons);
  if (runtimeFleet.paused) pausedReasons.push(...runtimeFleet.reasons);
  if (workflowFetchErrors.length > 0) pausedReasons.push('health-workflow-fetch-errors');
  const uniquePausedReasons = [...new Set(pausedReasons)];

  const adaptiveInflight = evaluateAdaptiveInflight({
    maxInflight: args.maxInflight,
    minInflight: args.minInflight,
    adaptiveCap: args.adaptiveCap,
    health,
    runtimeFleet,
    retryPressure,
    previousControllerState
  });
  const burst = evaluateBurstWindow({
    burstMode: args.burstMode,
    burstRefillCycles: args.burstRefillCycles,
    pullRequests: enrichedOpenPrs,
    previousBurst: previousReport?.burst,
    controllerMode: adaptiveInflight.mode,
    now
  });
  const burstCapApplied = burst.active && args.maxInflight > adaptiveInflight.effectiveMaxInflight;
  let effectiveMaxInflight = burstCapApplied ? args.maxInflight : adaptiveInflight.effectiveMaxInflight;
  let governorCapApplied = false;
  let governorCapLimit = null;
  if (governorState.mode === 'stabilize') {
    const stabilizeCap = Math.max(0, Math.min(args.minInflight, effectiveMaxInflight));
    if (stabilizeCap < effectiveMaxInflight) {
      governorCapApplied = true;
      governorCapLimit = stabilizeCap;
      effectiveMaxInflight = stabilizeCap;
    }
  }
  if (governorState.mode === 'pause') {
    governorCapApplied = true;
    governorCapLimit = 0;
    effectiveMaxInflight = 0;
  }
  const inflight = countInflight(classified.candidates.filter((candidate) => queueManagedBranches.has(candidate.baseRefName)));
  const capacity = Math.max(0, effectiveMaxInflight - inflight);

  const throughputControllerState = {
    schema: THROUGHPUT_CONTROLLER_SCHEMA,
    generatedAt: nowIso,
    repository,
    mode: adaptiveInflight.mode,
    desiredMode: adaptiveInflight.desiredMode,
    targetCap: effectiveMaxInflight,
    capByMode: adaptiveInflight.capByMode,
    adaptiveEnabled: adaptiveInflight.enabled,
    burstMode: burst.mode,
    burstActive: burst.active,
    burstCapApplied,
    governorMode: governorState.mode,
    governorDesiredMode: governorState.desiredMode,
    governorCapApplied,
    governorCapLimit,
    reasons: adaptiveInflight.reasons,
    metrics: adaptiveInflight.metrics,
    thresholds: adaptiveInflight.thresholds,
    upgradeStreak: adaptiveInflight.hysteresis?.upgradeStreak ?? 0,
    hysteresis: adaptiveInflight.hysteresis,
    retryPressure,
    paused: uniquePausedReasons.length > 0,
    pausedReasons: uniquePausedReasons
  };

  const queueReadiness = buildQueueReadinessReport({
    repository,
    candidates: classified.candidates,
    orderedEligible: classified.orderedEligible.map((candidate) => candidate.number),
    now
  });
  const workerOccupancy = buildWorkerOccupancySummary({
    runtimeState,
    runtimeStatePath: resolvedRuntimeStatePath,
    currentCycleIdleAuthority
  });
  const queueManagedCandidates = classified.candidates.filter((candidate) => queueManagedBranches.has(candidate.baseRefName));
  const candidateByNumber = new Map(classified.candidates.map((candidate) => [candidate.number, candidate]));
  const readyCandidates = queueReadiness.readySet.map((entry) => candidateByNumber.get(entry.number)).filter(Boolean);
  const readyQueuedCount = readyCandidates.filter((candidate) => isQueuedCandidate(candidate)).length;
  const readyUnqueuedCount = Math.max(0, readyCandidates.length - readyQueuedCount);
  const queueInventory = {
    queueManagedOpenCount: queueManagedCandidates.length,
    readyPrInventory: readyCandidates.length,
    blockedPrInventory: Math.max(0, queueManagedCandidates.length - readyCandidates.length),
    readyQueuedCount,
    readyUnqueuedCount,
    mergeQueueOccupancy: inflight,
    mergeQueueTargetCapacity: effectiveMaxInflight,
    mergeQueueAvailableCapacity: capacity
  };
  const planned = queueReadiness.readySet
    .map((entry) => candidateByNumber.get(entry.number))
    .filter(Boolean)
    .filter((candidate) => !isQueuedCandidate(candidate));
  const toProcess = planned.slice(0, capacity);

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    mode: {
      apply: Boolean(args.apply),
      dryRun: Boolean(args.dryRun)
    },
    controls: {
      pausedByVariable,
      queueAutopilotPaused: process.env.QUEUE_AUTOPILOT_PAUSED ?? null,
      queueAutopilotMaxInflight: process.env.QUEUE_AUTOPILOT_MAX_INFLIGHT ?? null,
      queueAutopilotMinInflight: process.env.QUEUE_AUTOPILOT_MIN_INFLIGHT ?? null,
      queueAutopilotAdaptiveCap: process.env.QUEUE_AUTOPILOT_ADAPTIVE_CAP ?? null,
      queueAutopilotMaxQueuedRuns: process.env.QUEUE_AUTOPILOT_MAX_QUEUED_RUNS ?? null,
      queueAutopilotMaxInProgressRuns: process.env.QUEUE_AUTOPILOT_MAX_IN_PROGRESS_RUNS ?? null,
      queueAutopilotStallThresholdMinutes: process.env.QUEUE_AUTOPILOT_STALL_THRESHOLD_MINUTES ?? null,
      queueBurstMode: process.env.QUEUE_BURST_MODE ?? null,
      queueBurstRefillCycles: process.env.QUEUE_BURST_REFILL_CYCLES ?? null,
      queueGovernorStatePath: process.env.QUEUE_GOVERNOR_STATE_PATH ?? null,
      repositoryOwner
    },
    queueManagedBranches: [...queueManagedBranches].sort(),
    queueStateEnrichment: {
      attempted: queueStateEnrichment.attempted,
      queuedStateCount: queueStateEnrichment.states.size,
      error: queueStateEnrichment.error
    },
    maxInflight: args.maxInflight,
    minInflight: args.minInflight,
    effectiveMaxInflight,
    adaptiveInflight,
    burst,
    burstCapApplied,
    governor: {
      ...governorState,
      capApplied: governorCapApplied,
      capLimit: governorCapLimit
    },
    securityIntake,
    inflight,
    capacity,
    health,
    runtimeFleet,
    workerOccupancy,
    workflowFetchErrors,
    paused: uniquePausedReasons.length > 0,
    pausedReasons: uniquePausedReasons,
    throughputController: throughputControllerState,
    queueInventory,
    readiness: {
      reportPath: readinessReportPath,
      summary: queueReadiness.summary,
      readySet: queueReadiness.readySet.map((entry) => ({
        number: entry.number,
        score: entry.score,
        dependencyRank: entry.dependencyRank
      }))
    },
    summary: {
      openCount: classified.allOpen.length,
      candidateCount: classified.candidates.length,
      eligibleCount: classified.orderedEligible.length,
      cycleDetected: classified.cycleDetected,
      queueManagedOpenCount: queueInventory.queueManagedOpenCount,
      readyPrInventory: queueInventory.readyPrInventory,
      blockedPrInventory: queueInventory.blockedPrInventory,
      readyQueuedCount: queueInventory.readyQueuedCount,
      readyUnqueuedCount: queueInventory.readyUnqueuedCount,
      mergeQueueOccupancy: queueInventory.mergeQueueOccupancy,
      mergeQueueTargetCapacity: queueInventory.mergeQueueTargetCapacity,
      mergeQueueAvailableCapacity: queueInventory.mergeQueueAvailableCapacity,
      plannedCount: toProcess.length,
      enqueuedCount: 0,
      quarantinedCount: 0,
      securityIntakeStatus: securityIntake.status
    },
    candidates: classified.candidates
      .map((candidate) => ({
        number: candidate.number,
        title: candidate.title,
        url: candidate.url,
        baseRefName: candidate.baseRefName,
        headRefName: candidate.headRefName,
        headRepositoryOwner: candidate.headRepositoryOwner || null,
        isCrossRepository: candidate.isCrossRepository,
        updatedAt: candidate.updatedAt,
        priority: candidate.priority,
        coupling: candidate.coupling,
        dependsOn: candidate.dependsOn,
        unresolvedOpenDependencies: candidate.unresolvedOpenDependencies ?? [],
        mergeStateStatus: candidate.mergeStateStatus,
        mergeable: candidate.mergeable,
        isInMergeQueue: candidate.isInMergeQueue,
        autoMergeEnabled: candidate.autoMergeEnabled,
        eligible: candidate.eligible,
        reasons: [...candidate.reasons].sort(),
        checks: candidate.checks
      }))
      .sort((a, b) => a.number - b.number),
    orderedEligible: classified.orderedEligible.map((candidate) => candidate.number),
    actions: [],
    retryHistory: {}
  };

  report.deferredBranchCleanup = await reconcileDeferredBranchCleanupReceipts({
    repoRoot,
    applyMutations: Boolean(args.apply) && !args.dryRun,
    readdirFn,
    readOptionalJsonFn,
    writeReportFn,
    reconcileDeferredBranchCleanupFn
  });

  if (report.paused || args.dryRun || !args.apply) {
    report.retryHistory = retryHistory;
    const resolvedPath = await writeReportFn(args.reportPath, report);
    const resolvedControllerStatePath = await writeReportFn(controllerStatePath, throughputControllerState);
    const resolvedReadinessPath = await writeReportFn(readinessReportPath, queueReadiness);
    return {
      report,
      reportPath: resolvedPath,
      controllerState: throughputControllerState,
      controllerStatePath: resolvedControllerStatePath,
      readiness: queueReadiness,
      readinessPath: resolvedReadinessPath
    };
  }

  for (const candidate of toProcess) {
    const action = {
      number: candidate.number,
      url: candidate.url,
      baseRefName: candidate.baseRefName,
      status: 'pending',
      attempts: [],
      quarantined: false,
      retriedUpdateBranch: false
    };

    const mergeSummaryPath = path.join('tests', 'results', '_agent', 'queue', `merge-sync-${candidate.number}.json`);
    const mergeArgs = [
      'tools/priority/merge-sync-pr.mjs',
      '--pr',
      String(candidate.number),
      '--repo',
      repository,
      '--summary-path',
      mergeSummaryPath
    ];
    const mergeResult = runCommandFn('node', mergeArgs, { cwd: repoRoot, allowFailure: true });
    action.attempts.push({
      type: 'merge-sync',
      status: mergeResult.status,
      stderr: mergeResult.stderr
    });
    const mergeSummary = await readOptionalJsonFn(path.resolve(repoRoot, mergeSummaryPath));
    action.mergeSummary = summarizeMergeSyncSummary(mergeSummary, mergeSummaryPath);

    let merged = mergeResult.status === 0 && isMaterializedMergeSyncSummary(mergeSummary);
    if (!merged && candidate.mergeStateStatus === 'BEHIND') {
      action.retriedUpdateBranch = true;
      const updateResult = runCommandFn(
        'gh',
        ['pr', 'update-branch', String(candidate.number), '--repo', repository],
        { cwd: repoRoot, allowFailure: true }
      );
      action.attempts.push({
        type: 'update-branch',
        status: updateResult.status,
        stderr: updateResult.stderr
      });

      if (updateResult.status === 0) {
        const retryMerge = runCommandFn('node', mergeArgs, { cwd: repoRoot, allowFailure: true });
        action.attempts.push({
          type: 'merge-sync-retry',
          status: retryMerge.status,
          stderr: retryMerge.stderr
        });
        const retrySummary = await readOptionalJsonFn(path.resolve(repoRoot, mergeSummaryPath));
        action.mergeSummary = summarizeMergeSyncSummary(retrySummary, mergeSummaryPath);
        merged = retryMerge.status === 0 && isMaterializedMergeSyncSummary(retrySummary);
      }
    }

    if (merged) {
      action.status = 'enqueued';
      clearFailure(retryHistory, candidate.number);
      const clearBlocked = runCommandFn(
        'gh',
        ['pr', 'edit', String(candidate.number), '--repo', repository, '--remove-label', 'queue-blocked'],
        { cwd: repoRoot, allowFailure: true }
      );
      action.queueBlockedCleared = clearBlocked.status === 0;
      report.summary.enqueuedCount += 1;
      report.actions.push(action);
      continue;
    }

    const failureCountWindow = appendFailure(retryHistory, candidate.number, nowIso);
    action.status = 'failed';
    action.failureCount24h = failureCountWindow;
    if (failureCountWindow >= 2) {
      const quarantineResult = runCommandFn(
        'gh',
        ['pr', 'edit', String(candidate.number), '--repo', repository, '--add-label', 'queue-quarantine'],
        { cwd: repoRoot, allowFailure: true }
      );
      action.quarantined = quarantineResult.status === 0;
      action.quarantineStatus = quarantineResult.status;
      action.quarantineError = quarantineResult.stderr || null;
      if (action.quarantined) {
        report.summary.quarantinedCount += 1;
      }
    } else {
      const blockedResult = runCommandFn(
        'gh',
        ['pr', 'edit', String(candidate.number), '--repo', repository, '--add-label', 'queue-blocked'],
        { cwd: repoRoot, allowFailure: true }
      );
      action.queueBlockedApplied = blockedResult.status === 0;
      action.queueBlockedError = blockedResult.stderr || null;
    }

    report.actions.push(action);
  }

  report.retryHistory = retryHistory;
  const resolvedPath = await writeReportFn(args.reportPath, report);
  const resolvedControllerStatePath = await writeReportFn(controllerStatePath, throughputControllerState);
  const resolvedReadinessPath = await writeReportFn(readinessReportPath, queueReadiness);
  return {
    report,
    reportPath: resolvedPath,
    controllerState: throughputControllerState,
    controllerStatePath: resolvedControllerStatePath,
    readiness: queueReadiness,
    readinessPath: resolvedReadinessPath
  };
}

export async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const { report, reportPath, controllerState, controllerStatePath, readinessPath } = await runQueueSupervisor({ args });
  console.log(`[queue-supervisor] report written: ${reportPath}`);
  if (controllerStatePath) {
    console.log(
      `[queue-supervisor] throughput controller: ${controllerStatePath} (mode=${controllerState?.mode ?? 'unknown'}, cap=${controllerState?.targetCap ?? 'n/a'})`
    );
  }
  if (readinessPath) {
    console.log(`[queue-supervisor] readiness report: ${readinessPath}`);
  }
  console.log(
    `[queue-supervisor] paused=${report.paused} ready=${report.summary.readyPrInventory} blocked=${report.summary.blockedPrInventory} occupancy=${report.summary.mergeQueueOccupancy}/${report.summary.mergeQueueTargetCapacity} planned=${report.summary.plannedCount} enqueued=${report.summary.enqueuedCount}`
  );
  if (report.paused) {
    console.log(`[queue-supervisor] pause reasons: ${report.pausedReasons.join(', ')}`);
  }
  return 0;
}

export const __test = Object.freeze({
  parseArgs,
  normalizeBaseBranch,
  evaluateRequiredChecks,
  classifyOpenPullRequests,
  evaluateHealthGate,
  evaluateRuntimeFleetHealth,
  evaluateBurstWindow,
  computeRetryPressure,
  pruneRetryHistory,
  runQueueSupervisor
});

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).catch((error) => {
    console.error(error?.stack ?? error?.message ?? String(error));
    process.exitCode = 1;
  });
}

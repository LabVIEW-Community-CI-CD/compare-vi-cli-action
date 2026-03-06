#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { parseRemoteUrl } from './lib/remote-utils.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';

const REPORT_SCHEMA = 'priority/queue-supervisor-report@v1';
const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'queue', 'queue-supervisor-report.json');
const DEFAULT_MAX_INFLIGHT = 4;
const DEFAULT_HEALTH_SAMPLE = 10;
const DEFAULT_HEALTH_MIN_SUCCESS_RATE = 0.8;
const DEFAULT_HEALTH_MAX_RED_MINUTES = 30;
const DEFAULT_MAX_QUEUED_RUNS = 6;
const DEFAULT_MAX_IN_PROGRESS_RUNS = 8;
const DEFAULT_STALL_THRESHOLD_MINUTES = 45;
const RETRY_WINDOW_HOURS = 24;
const EXCLUDED_LABELS = new Set(['queue-blocked', 'do-not-queue']);
const DEFAULT_BASE_BRANCHES = ['develop', 'main'];
const COUPLING_VALUES = new Set(['independent', 'soft', 'hard']);
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
  console.log(`  --max-inflight <n>     Queue target cap (default: ${DEFAULT_MAX_INFLIGHT}, env QUEUE_AUTOPILOT_MAX_INFLIGHT).`);
  console.log(`  --max-queued-runs <n>  Pause when queued workflow runs exceed this threshold (default: ${DEFAULT_MAX_QUEUED_RUNS}).`);
  console.log(`  --max-in-progress-runs <n> Pause when in-progress workflow runs exceed this threshold (default: ${DEFAULT_MAX_IN_PROGRESS_RUNS}).`);
  console.log(`  --stall-threshold-minutes <n> Pause when active runs exceed age threshold (default: ${DEFAULT_STALL_THRESHOLD_MINUTES}).`);
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

function parseCsv(value) {
  return String(value)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    apply: false,
    dryRun: true,
    reportPath: DEFAULT_REPORT_PATH,
    maxInflight: null,
    repo: null,
    baseBranches: [...DEFAULT_BASE_BRANCHES],
    healthBranch: 'develop',
    maxQueuedRuns: null,
    maxInProgressRuns: null,
    stallThresholdMinutes: null,
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
      arg === '--max-inflight' ||
      arg === '--repo' ||
      arg === '--base-branches' ||
      arg === '--health-branch' ||
      arg === '--max-queued-runs' ||
      arg === '--max-in-progress-runs' ||
      arg === '--stall-threshold-minutes'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--report') {
        options.reportPath = next;
      } else if (arg === '--max-inflight') {
        options.maxInflight = parseIntStrict(next, { label: '--max-inflight' });
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
      }
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
  excludedLabels = EXCLUDED_LABELS,
  expectedHeadOwner = ''
}) {
  const normalizedExpectedHeadOwner = normalizeOwner(expectedHeadOwner);
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
    if (normalizedExpectedHeadOwner && pr.headRepositoryOwner !== normalizedExpectedHeadOwner) {
      reasons.push('head-not-upstream-owned');
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
  maxRedMinutes = DEFAULT_HEALTH_MAX_RED_MINUTES
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

  runs.sort((a, b) => Date.parse(b.createdAt || 0) - Date.parse(a.createdAt || 0));
  const sampleSize = runs.length;
  const successful = runs.filter((run) => run.conclusion === 'success').length;
  const successRate = sampleSize === 0 ? 0 : successful / sampleSize;
  const latest = runs[0] ?? null;
  const lastSuccess = runs.find((run) => run.conclusion === 'success') ?? null;

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
  return candidates.filter((candidate) => candidate.autoMergeEnabled).length;
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
  const now = options.now ?? new Date();
  const runGhJsonFn = options.runGhJsonFn ?? runGhJson;
  const runCommandFn = options.runCommandFn ?? runCommand;
  const readJsonFileFn = options.readJsonFileFn ?? readJsonFile;
  const readOptionalJsonFn = options.readOptionalJsonFn ?? readOptionalJson;
  const writeReportFn = options.writeReportFn ?? writeReport;
  const repository = resolveRepositorySlug(repoRoot, args.repo);
  const expectedHeadOwner = String(repository).split('/')[0]?.trim().toLowerCase() ?? '';

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

  const classified = classifyOpenPullRequests({
    pullRequests: allOpenPrs,
    requiredChecksByBranch,
    queueManagedBranches,
    expectedHeadOwner
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
  const pausedByVariable = String(process.env.QUEUE_AUTOPILOT_PAUSED ?? '').trim() === '1';
  const pausedReasons = [];
  if (pausedByVariable) pausedReasons.push('paused-by-variable');
  if (health.paused) pausedReasons.push(...health.reasons);
  if (runtimeFleet.paused) pausedReasons.push(...runtimeFleet.reasons);
  if (workflowFetchErrors.length > 0) pausedReasons.push('health-workflow-fetch-errors');
  const uniquePausedReasons = [...new Set(pausedReasons)];

  const inflight = countInflight(classified.candidates.filter((candidate) => queueManagedBranches.has(candidate.baseRefName)));
  const capacity = Math.max(0, args.maxInflight - inflight);
  const planned = classified.orderedEligible.filter((candidate) => !candidate.autoMergeEnabled);
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
      queueAutopilotMaxQueuedRuns: process.env.QUEUE_AUTOPILOT_MAX_QUEUED_RUNS ?? null,
      queueAutopilotMaxInProgressRuns: process.env.QUEUE_AUTOPILOT_MAX_IN_PROGRESS_RUNS ?? null,
      queueAutopilotStallThresholdMinutes: process.env.QUEUE_AUTOPILOT_STALL_THRESHOLD_MINUTES ?? null,
      expectedHeadOwner
    },
    queueManagedBranches: [...queueManagedBranches].sort(),
    maxInflight: args.maxInflight,
    inflight,
    capacity,
    health,
    runtimeFleet,
    workflowFetchErrors,
    paused: uniquePausedReasons.length > 0,
    pausedReasons: uniquePausedReasons,
    summary: {
      openCount: classified.allOpen.length,
      candidateCount: classified.candidates.length,
      eligibleCount: classified.orderedEligible.length,
      cycleDetected: classified.cycleDetected,
      plannedCount: toProcess.length,
      enqueuedCount: 0,
      quarantinedCount: 0
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

  const previousReport = await readOptionalJsonFn(path.resolve(repoRoot, args.reportPath));
  const retryHistory = previousReport?.retryHistory && typeof previousReport.retryHistory === 'object'
    ? structuredClone(previousReport.retryHistory)
    : {};

  if (report.paused || args.dryRun || !args.apply) {
    report.retryHistory = retryHistory;
    const resolvedPath = await writeReportFn(args.reportPath, report);
    return { report, reportPath: resolvedPath };
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

    let merged = mergeResult.status === 0;
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
        merged = retryMerge.status === 0;
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

    const nowIso = now.toISOString();
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
  return { report, reportPath: resolvedPath };
}

export async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const { report, reportPath } = await runQueueSupervisor({ args });
  console.log(`[queue-supervisor] report written: ${reportPath}`);
  console.log(`[queue-supervisor] paused=${report.paused} eligible=${report.summary.eligibleCount} planned=${report.summary.plannedCount} enqueued=${report.summary.enqueuedCount}`);
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

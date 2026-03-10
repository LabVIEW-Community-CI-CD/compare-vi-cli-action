#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  BLOCKER_CLASSES,
  createRuntimeAdapter,
  DEFAULT_RUNTIME_DIR,
  SCHEDULER_DECISION_SCHEMA
} from './index.mjs';
import { runRuntimeWorkerStep } from './worker.mjs';

export const OBSERVER_REPORT_SCHEMA = 'priority/runtime-observer-report@v1';
export const OBSERVER_HEARTBEAT_SCHEMA = 'priority/runtime-observer-heartbeat@v1';
export const DEFAULT_POLL_INTERVAL_SECONDS = 60;
export const SCHEDULER_DECISION_OUTCOMES = new Set(['selected', 'idle', 'blocked']);
const SCHEDULER_STEP_OPTION_KEYS = ['lane', 'issue', 'epic', 'forkRemote', 'branch', 'prUrl', 'blockerClass', 'reason'];

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

async function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
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
  const schedulerPaths = resolveSchedulerPaths(options, repoRoot);
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
        activeLane: schedulerDecision.activeLane,
        schedulerDecision: report.lastDecision,
        artifacts: {
          statePath: null,
          eventsPath: null,
          stopRequestPath: null,
          schedulerDecisionPath: schedulerArtifacts.latestPath,
          schedulerDecisionHistoryPath: schedulerArtifacts.historyPath
        }
      });
      report.status = 'blocked';
      report.outcome = 'scheduler-blocked';
      return { exitCode: 12, report };
    }

    const stepResult = await runRuntimeWorkerStep(buildWorkerStepOptions(options, schedulerDecision), {
      ...deps,
      now: stepNow,
      repoRoot,
      adapter
    });

    report.cyclesCompleted += 1;
    report.lastStep = {
      exitCode: stepResult.exitCode,
      outcome: stepResult.report.outcome,
      statePath: stepResult.report.runtime?.statePath ?? null,
      turnPath: stepResult.report.turnPath ?? null
    };
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
      outcome: stepResult.report.outcome,
      stopRequested: Boolean(stepResult.report.state?.lifecycle?.stopRequested),
      activeLane: stepResult.report.state?.activeLane ?? null,
      schedulerDecision: report.lastDecision,
      artifacts: {
        statePath: stepResult.report.runtime?.statePath ?? null,
        eventsPath: stepResult.report.runtime?.eventsPath ?? null,
        stopRequestPath: stepResult.report.runtime?.stopRequestPath ?? null,
        schedulerDecisionPath: schedulerArtifacts.latestPath,
        schedulerDecisionHistoryPath: schedulerArtifacts.historyPath
      }
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

    if (options.maxCycles > 0 && report.cyclesCompleted >= options.maxCycles) {
      report.outcome = 'max-cycles-reached';
      return { exitCode: 0, report };
    }

    await sleepFn(options.pollIntervalSeconds * 1000);
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

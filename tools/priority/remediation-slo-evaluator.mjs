#!/usr/bin/env node

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/remediation-slo-report@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'slo', 'remediation-slo-report.json');
export const GOVERNOR_STATE_SCHEMA = 'ops-governor-state@v1';
export const DEFAULT_GOVERNOR_STATE_PATH = path.join('tests', 'results', '_agent', 'slo', 'ops-governor-state.json');
export const DEFAULT_INCIDENT_EVENTS_PATH = path.join('tests', 'results', '_agent', 'ops', 'incident-events.json');
export const DEFAULT_QUEUE_REPORT_PATH = path.join('tests', 'results', '_agent', 'queue', 'queue-supervisor-report.json');
export const DEFAULT_SLO_METRICS_PATH = path.join('tests', 'results', '_agent', 'slo', 'slo-metrics.json');
export const DEFAULT_RELEASE_SCORECARD_PATH = path.join('tests', 'results', '_agent', 'release', 'release-scorecard.json');
export const DEFAULT_LOOKBACK_DAYS = 30;
export const GOVERNOR_RECOVERY_THRESHOLDS = Object.freeze({
  pauseToStabilizeHealthyCycles: 2,
  stabilizeToNormalHealthyCycles: 2
});

export const DEFAULT_THRESHOLDS = Object.freeze({
  mttdHours: Object.freeze({ warn: 2, fail: 8 }),
  routeLatencyHours: Object.freeze({ warn: 4, fail: 24 }),
  mttrByPriorityHours: Object.freeze({
    P0: Object.freeze({ warn: 24, fail: 72 }),
    P1: Object.freeze({ warn: 48, fail: 120 }),
    P2: Object.freeze({ warn: 96, fail: 240 })
  }),
  reopenRate: Object.freeze({ warn: 0.2, fail: 0.35 }),
  queueRetryRatio: Object.freeze({ warn: 0.2, fail: 0.35 }),
  trunkRedMinutes: Object.freeze({ warn: 30, fail: 60 }),
  releaseBlockerCount: Object.freeze({ warn: 1, fail: 3 })
});

function printUsage() {
  console.log('Usage: node tools/priority/remediation-slo-evaluator.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --output <path>            Output report path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log(`  --governor-state <path>    Governor state output path (default: ${DEFAULT_GOVERNOR_STATE_PATH}).`);
  console.log(`  --issue-events <path>      Incident event input path (default: ${DEFAULT_INCIDENT_EVENTS_PATH}).`);
  console.log(`  --queue-report <path>      Queue supervisor report path (default: ${DEFAULT_QUEUE_REPORT_PATH}).`);
  console.log(`  --slo-metrics <path>       SLO metrics input path (default: ${DEFAULT_SLO_METRICS_PATH}).`);
  console.log(`  --release-scorecard <path> Release scorecard input path (default: ${DEFAULT_RELEASE_SCORECARD_PATH}).`);
  console.log(`  --lookback-days <n>        Incident lookback window in days (default: ${DEFAULT_LOOKBACK_DAYS}).`);
  console.log('  --repo <owner/repo>        Repository slug (default: GITHUB_REPOSITORY/upstream/origin remote).');
  console.log('  -h, --help                 Show this help text and exit.');
}

function parseIntStrict(value, { label }) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Invalid ${label} value '${value}'.`);
  }
  return parsed;
}

function asOptional(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized || null;
}

export function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) return null;
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return `${owner}/${repo}`;
}

export function resolveRepositorySlug(repoRoot, explicitRepo, environment = process.env) {
  const explicit = asOptional(explicitRepo);
  if (explicit && explicit.includes('/')) return explicit;
  const envRepo = asOptional(environment.GITHUB_REPOSITORY);
  if (envRepo && envRepo.includes('/')) return envRepo;

  for (const remoteName of ['upstream', 'origin']) {
    const result = spawnSync('git', ['config', '--get', `remote.${remoteName}.url`], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    if (result.status !== 0) continue;
    const parsed = parseRemoteUrl(result.stdout.trim());
    if (parsed) return parsed;
  }

  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    outputPath: DEFAULT_OUTPUT_PATH,
    governorStatePath: DEFAULT_GOVERNOR_STATE_PATH,
    issueEventsPath: DEFAULT_INCIDENT_EVENTS_PATH,
    queueReportPath: DEFAULT_QUEUE_REPORT_PATH,
    sloMetricsPath: DEFAULT_SLO_METRICS_PATH,
    releaseScorecardPath: DEFAULT_RELEASE_SCORECARD_PATH,
    lookbackDays: DEFAULT_LOOKBACK_DAYS,
    repo: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    if (
      token === '--output' ||
      token === '--governor-state' ||
      token === '--issue-events' ||
      token === '--queue-report' ||
      token === '--slo-metrics' ||
      token === '--release-scorecard' ||
      token === '--repo' ||
      token === '--lookback-days'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--output') options.outputPath = next;
      if (token === '--governor-state') options.governorStatePath = next;
      if (token === '--issue-events') options.issueEventsPath = next;
      if (token === '--queue-report') options.queueReportPath = next;
      if (token === '--slo-metrics') options.sloMetricsPath = next;
      if (token === '--release-scorecard') options.releaseScorecardPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--lookback-days') options.lookbackDays = parseIntStrict(next, { label: '--lookback-days' });
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

async function readJsonOptional(filePath) {
  const resolved = path.resolve(filePath);
  if (!existsSync(resolved)) {
    return {
      exists: false,
      path: resolved,
      error: null,
      payload: null
    };
  }

  try {
    const raw = await readFile(resolved, 'utf8');
    return {
      exists: true,
      path: resolved,
      error: null,
      payload: JSON.parse(raw)
    };
  } catch (error) {
    return {
      exists: true,
      path: resolved,
      error: error?.message ?? String(error),
      payload: null
    };
  }
}

function toTimestamp(value) {
  const timestamp = Date.parse(value ?? '');
  return Number.isFinite(timestamp) ? timestamp : null;
}

function average(values) {
  if (!Array.isArray(values) || values.length === 0) return null;
  const sum = values.reduce((total, value) => total + value, 0);
  return sum / values.length;
}

function normalizePriority(value) {
  const normalized = String(value ?? '')
    .trim()
    .toUpperCase();
  if (normalized === 'P0' || normalized === 'P1' || normalized === 'P2') {
    return normalized;
  }
  return 'P2';
}

function normalizeIncidentEvents(payload) {
  if (!Array.isArray(payload)) return [];
  return payload
    .map((entry, index) => {
      const occurredAtMs = toTimestamp(entry?.occurredAt ?? entry?.occurred_at);
      const detectedAtMs = toTimestamp(entry?.detectedAt ?? entry?.detected_at);
      const routedAtMs = toTimestamp(entry?.routedAt ?? entry?.routed_at);
      const resolvedAtMs = toTimestamp(entry?.resolvedAt ?? entry?.resolved_at);
      const referenceMs = detectedAtMs ?? occurredAtMs;
      if (!Number.isFinite(referenceMs)) return null;
      return {
        id: asOptional(entry?.id) ?? `event-${index + 1}`,
        priority: normalizePriority(entry?.priority),
        occurredAtMs,
        detectedAtMs,
        routedAtMs,
        resolvedAtMs,
        reopenedCount: Math.max(0, Number(entry?.reopenedCount ?? entry?.reopened_count ?? 0) || 0),
        source: asOptional(entry?.source) ?? null
      };
    })
    .filter(Boolean);
}

export function summarizeIncidentMetrics({
  events = [],
  now = new Date(),
  lookbackDays = DEFAULT_LOOKBACK_DAYS
} = {}) {
  const cutoffMs = now.valueOf() - lookbackDays * 24 * 60 * 60 * 1000;
  const inWindow = events.filter((event) => {
    const referenceMs = event.detectedAtMs ?? event.occurredAtMs;
    return Number.isFinite(referenceMs) && referenceMs >= cutoffMs;
  });

  const mttdHours = inWindow
    .map((event) => {
      if (!Number.isFinite(event.occurredAtMs) || !Number.isFinite(event.detectedAtMs)) return null;
      if (event.detectedAtMs < event.occurredAtMs) return null;
      return (event.detectedAtMs - event.occurredAtMs) / 3_600_000;
    })
    .filter((value) => Number.isFinite(value));

  const routeLatencyHours = inWindow
    .map((event) => {
      if (!Number.isFinite(event.detectedAtMs) || !Number.isFinite(event.routedAtMs)) return null;
      if (event.routedAtMs < event.detectedAtMs) return null;
      return (event.routedAtMs - event.detectedAtMs) / 3_600_000;
    })
    .filter((value) => Number.isFinite(value));

  const mttrByPriority = {
    P0: [],
    P1: [],
    P2: []
  };
  for (const event of inWindow) {
    if (!Number.isFinite(event.detectedAtMs) || !Number.isFinite(event.resolvedAtMs)) {
      continue;
    }
    if (event.resolvedAtMs < event.detectedAtMs) {
      continue;
    }
    mttrByPriority[event.priority].push((event.resolvedAtMs - event.detectedAtMs) / 3_600_000);
  }

  const totalIncidents = inWindow.length;
  const reopenedIncidents = inWindow.filter((event) => event.reopenedCount > 0).length;

  return {
    lookbackDays,
    totalIncidents,
    reopenedIncidents,
    reopenRate: totalIncidents > 0 ? reopenedIncidents / totalIncidents : 0,
    mttdHours: average(mttdHours),
    routeLatencyHours: average(routeLatencyHours),
    mttrByPriorityHours: {
      P0: average(mttrByPriority.P0),
      P1: average(mttrByPriority.P1),
      P2: average(mttrByPriority.P2)
    },
    sampleCounts: {
      mttd: mttdHours.length,
      routeLatency: routeLatencyHours.length,
      mttrP0: mttrByPriority.P0.length,
      mttrP1: mttrByPriority.P1.length,
      mttrP2: mttrByPriority.P2.length
    }
  };
}

export function summarizeOperationalMetrics({
  queueReport = null,
  sloMetrics = null,
  releaseScorecard = null
} = {}) {
  return {
    queueRetryRatio: Number.isFinite(Number(queueReport?.throughputController?.retryPressure?.retryRatio))
      ? Number(queueReport.throughputController.retryPressure.retryRatio)
      : null,
    queueQuarantineRatio: Number.isFinite(Number(queueReport?.throughputController?.retryPressure?.quarantineRatio))
      ? Number(queueReport.throughputController.retryPressure.quarantineRatio)
      : null,
    trunkRedMinutes: Number.isFinite(Number(queueReport?.health?.redMinutes))
      ? Number(queueReport.health.redMinutes)
      : null,
    trunkFailureRate: Number.isFinite(Number(sloMetrics?.summary?.metrics?.failureRate))
      ? Number(sloMetrics.summary.metrics.failureRate)
      : null,
    releaseBlockerCount: Number.isFinite(Number(releaseScorecard?.summary?.blockerCount))
      ? Number(releaseScorecard.summary.blockerCount)
      : null,
    releaseStatus: asOptional(releaseScorecard?.summary?.status) ?? null
  };
}

function classifySeverity(value, threshold) {
  if (!Number.isFinite(value)) {
    return 'n/a';
  }
  if (value >= threshold.fail) {
    return 'fail';
  }
  if (value >= threshold.warn) {
    return 'warn';
  }
  return 'pass';
}

export function evaluateRemediationSlo({
  incidentMetrics,
  operationalMetrics,
  thresholds = DEFAULT_THRESHOLDS
}) {
  const checks = [];

  const addCheck = (key, value, threshold, context = {}) => {
    const status = classifySeverity(value, threshold);
    checks.push({
      key,
      value: Number.isFinite(value) ? value : null,
      thresholds: threshold,
      status,
      ...context
    });
  };

  addCheck('mttd-hours', incidentMetrics.mttdHours, thresholds.mttdHours);
  addCheck('route-latency-hours', incidentMetrics.routeLatencyHours, thresholds.routeLatencyHours);
  addCheck('reopen-rate', incidentMetrics.reopenRate, thresholds.reopenRate);
  addCheck('queue-retry-ratio', operationalMetrics.queueRetryRatio, thresholds.queueRetryRatio);
  addCheck('trunk-red-minutes', operationalMetrics.trunkRedMinutes, thresholds.trunkRedMinutes);
  addCheck('release-blocker-count', operationalMetrics.releaseBlockerCount, thresholds.releaseBlockerCount);

  for (const priority of ['P0', 'P1', 'P2']) {
    addCheck(
      `mttr-${priority.toLowerCase()}-hours`,
      incidentMetrics.mttrByPriorityHours[priority],
      thresholds.mttrByPriorityHours[priority],
      { priority }
    );
  }

  const severityRank = (status) => {
    if (status === 'fail') return 2;
    if (status === 'warn') return 1;
    return 0;
  };

  let overall = 'pass';
  for (const check of checks) {
    if (severityRank(check.status) > severityRank(overall)) {
      overall = check.status;
    }
  }

  const breaches = checks
    .filter((check) => check.status === 'warn' || check.status === 'fail')
    .map((check) => ({
      key: check.key,
      status: check.status,
      value: check.value,
      thresholds: check.thresholds,
      priority: check.priority ?? null
    }));

  return {
    status: overall,
    checks,
    breaches
  };
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

export function deriveGovernorDesiredMode({
  evaluated,
  operationalMetrics,
  thresholds = DEFAULT_THRESHOLDS
}) {
  const reasons = [];
  const trunkRedMinutes = Number(operationalMetrics?.trunkRedMinutes);
  const queueRetryRatio = Number(operationalMetrics?.queueRetryRatio);
  const queueQuarantineRatio = Number(operationalMetrics?.queueQuarantineRatio);

  if (Number.isFinite(trunkRedMinutes) && trunkRedMinutes >= thresholds.trunkRedMinutes.fail) {
    reasons.push('trunk-red-fail-threshold');
  }
  if (Number.isFinite(queueRetryRatio) && queueRetryRatio >= thresholds.queueRetryRatio.fail) {
    reasons.push('queue-retry-fail-threshold');
  }
  if (Number.isFinite(queueQuarantineRatio) && queueQuarantineRatio >= thresholds.queueRetryRatio.fail) {
    reasons.push('queue-quarantine-fail-threshold');
  }

  if (reasons.length > 0) {
    return {
      mode: 'pause',
      reasons
    };
  }

  if (evaluated?.status === 'pass') {
    return {
      mode: 'normal',
      reasons: ['slo-pass']
    };
  }

  return {
    mode: 'stabilize',
    reasons: ['slo-breach']
  };
}

export function applyGovernorModeTransition({
  desiredMode,
  previousMode,
  previousHealthyStreak = 0,
  recoveryThresholds = GOVERNOR_RECOVERY_THRESHOLDS
}) {
  const normalizedDesiredMode = normalizeGovernorMode(desiredMode);
  const normalizedPreviousMode = normalizeGovernorMode(previousMode);
  const healthyStreakCandidate = normalizedDesiredMode === 'normal' ? Math.max(0, previousHealthyStreak) + 1 : 0;

  let mode = normalizedDesiredMode;
  let reason = 'desired-mode';

  if (normalizedDesiredMode === 'pause') {
    mode = 'pause';
    reason = 'pause-threshold-breach';
  } else if (normalizedPreviousMode === 'pause') {
    if (
      normalizedDesiredMode === 'normal' &&
      healthyStreakCandidate >= recoveryThresholds.pauseToStabilizeHealthyCycles
    ) {
      mode = 'stabilize';
      reason = 'pause-recovery-threshold-met';
    } else {
      mode = 'pause';
      reason = normalizedDesiredMode === 'normal' ? 'pause-recovery-threshold-pending' : 'pause-hold-unhealthy';
    }
  } else if (normalizedDesiredMode === 'stabilize') {
    mode = 'stabilize';
    reason = 'slo-breach';
  } else if (
    normalizedPreviousMode === 'stabilize' &&
    healthyStreakCandidate < recoveryThresholds.stabilizeToNormalHealthyCycles
  ) {
    mode = 'stabilize';
    reason = 'stabilize-recovery-threshold-pending';
  }

  return {
    mode,
    desiredMode: normalizedDesiredMode,
    previousMode: normalizedPreviousMode,
    healthyStreak: healthyStreakCandidate,
    transitionReason: reason
  };
}

async function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runRemediationSloEvaluator(options = {}) {
  const repoRoot = options.repoRoot ?? process.cwd();
  const args = options.args ?? parseArgs();
  const now = options.now ?? new Date();
  const environment = options.environment ?? process.env;
  const readJsonOptionalFn = options.readJsonOptionalFn ?? readJsonOptional;
  const writeJsonFn = options.writeJsonFn ?? writeJson;

  const repository = resolveRepositorySlug(repoRoot, args.repo, environment);

  const previousReportEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.outputPath));
  const previousGovernorStateEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.governorStatePath));
  const incidentEventsEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.issueEventsPath));
  const queueReportEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.queueReportPath));
  const sloMetricsEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.sloMetricsPath));
  const releaseScorecardEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.releaseScorecardPath));

  const events = normalizeIncidentEvents(incidentEventsEnvelope.payload);
  const incidentMetrics = summarizeIncidentMetrics({
    events,
    now,
    lookbackDays: args.lookbackDays
  });
  const operationalMetrics = summarizeOperationalMetrics({
    queueReport: queueReportEnvelope.payload,
    sloMetrics: sloMetricsEnvelope.payload,
    releaseScorecard: releaseScorecardEnvelope.payload
  });
  const evaluated = evaluateRemediationSlo({
    incidentMetrics,
    operationalMetrics,
    thresholds: DEFAULT_THRESHOLDS
  });

  const previousStatus = asOptional(previousReportEnvelope.payload?.summary?.status) ?? 'pass';
  const firstBreach = previousStatus === 'pass' && evaluated.status !== 'pass';
  const previousGovernorMode = normalizeGovernorMode(
    previousGovernorStateEnvelope.payload?.mode ?? previousReportEnvelope.payload?.governor?.intent
  );
  const previousGovernorHealthyStreak = Number.isInteger(Number(previousGovernorStateEnvelope.payload?.healthyStreak))
    ? Number(previousGovernorStateEnvelope.payload.healthyStreak)
    : 0;
  const desiredGovernor = deriveGovernorDesiredMode({
    evaluated,
    operationalMetrics,
    thresholds: DEFAULT_THRESHOLDS
  });
  const governorTransition = applyGovernorModeTransition({
    desiredMode: desiredGovernor.mode,
    previousMode: previousGovernorMode,
    previousHealthyStreak: previousGovernorHealthyStreak
  });
  const governorIntent = governorTransition.mode;
  const transitionSummary = `${previousGovernorMode}->${governorIntent}`;

  const operatorWhy = desiredGovernor.reasons.length > 0 ? desiredGovernor.reasons.join(', ') : 'slo-pass';
  const operatorRecovery = [];
  if (governorIntent === 'pause') {
    operatorRecovery.push('Restore trunk-red minutes below fail threshold.');
    operatorRecovery.push('Restore queue retry ratio below fail threshold.');
    operatorRecovery.push(
      `Sustain healthy cycles for at least ${GOVERNOR_RECOVERY_THRESHOLDS.pauseToStabilizeHealthyCycles} evaluations.`
    );
  } else if (governorIntent === 'stabilize') {
    operatorRecovery.push(
      `Sustain healthy cycles for at least ${GOVERNOR_RECOVERY_THRESHOLDS.stabilizeToNormalHealthyCycles} evaluations.`
    );
  } else {
    operatorRecovery.push('Continue monitoring queue and trunk SLO signals.');
  }

  const governorState = {
    schema: GOVERNOR_STATE_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    mode: governorIntent,
    desiredMode: governorTransition.desiredMode,
    previousMode: governorTransition.previousMode,
    healthyStreak: governorTransition.healthyStreak,
    recoveryThresholds: GOVERNOR_RECOVERY_THRESHOLDS,
    reasons: desiredGovernor.reasons,
    transition: {
      from: governorTransition.previousMode,
      to: governorIntent,
      reason: governorTransition.transitionReason,
      summary: transitionSummary
    },
    metrics: {
      summaryStatus: evaluated.status,
      trunkRedMinutes: operationalMetrics.trunkRedMinutes,
      queueRetryRatio: operationalMetrics.queueRetryRatio,
      queueQuarantineRatio: operationalMetrics.queueQuarantineRatio,
      releaseStatus: operationalMetrics.releaseStatus
    },
    operatorSummary: {
      why: operatorWhy,
      recovery: operatorRecovery
    }
  };

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    windows: {
      lookbackDays: args.lookbackDays
    },
    inputs: {
      governorStatePath: args.governorStatePath,
      issueEventsPath: args.issueEventsPath,
      queueReportPath: args.queueReportPath,
      sloMetricsPath: args.sloMetricsPath,
      releaseScorecardPath: args.releaseScorecardPath
    },
    sourceState: {
      issueEvents: {
        exists: incidentEventsEnvelope.exists,
        error: incidentEventsEnvelope.error
      },
      governorState: {
        exists: previousGovernorStateEnvelope.exists,
        error: previousGovernorStateEnvelope.error
      },
      queueReport: {
        exists: queueReportEnvelope.exists,
        error: queueReportEnvelope.error
      },
      sloMetrics: {
        exists: sloMetricsEnvelope.exists,
        error: sloMetricsEnvelope.error
      },
      releaseScorecard: {
        exists: releaseScorecardEnvelope.exists,
        error: releaseScorecardEnvelope.error
      }
    },
    thresholds: DEFAULT_THRESHOLDS,
    metrics: {
      incident: incidentMetrics,
      operations: operationalMetrics
    },
    summary: {
      status: evaluated.status,
      checkCount: evaluated.checks.length,
      breachCount: evaluated.breaches.length
    },
    checks: evaluated.checks,
    breaches: evaluated.breaches,
    governor: {
      intent: governorIntent,
      desiredIntent: governorTransition.desiredMode,
      firstBreach,
      previousStatus,
      previousMode: governorTransition.previousMode,
      transition: `${previousStatus}->${evaluated.status}`,
      modeTransition: transitionSummary,
      transitionReason: governorTransition.transitionReason,
      recoveryThresholds: GOVERNOR_RECOVERY_THRESHOLDS,
      healthyStreak: governorTransition.healthyStreak,
      reasons: desiredGovernor.reasons
    }
  };

  const outputPath = await writeJsonFn(args.outputPath, report);
  const governorStatePath = await writeJsonFn(args.governorStatePath, governorState);
  return {
    report,
    outputPath,
    governorState,
    governorStatePath,
    exitCode: 0
  };
}

export async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const { report, outputPath, governorStatePath } = await runRemediationSloEvaluator({ args });
  console.log(
    `[remediation-slo] report: ${outputPath} status=${report.summary.status} breaches=${report.summary.breachCount} governor=${report.governor.intent}`
  );
  console.log(`[remediation-slo] governor-state: ${governorStatePath}`);
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) {
        process.exitCode = code;
      }
    })
    .catch((error) => {
      console.error(error?.stack ?? error?.message ?? String(error));
      process.exitCode = 1;
    });
}

#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { defaultLeaseRoot } from './agent-writer-lease.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
const DEFAULT_RUNTIME_OUTPUT_PATH = path.join(DEFAULT_REPO_ROOT, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json');
const DEFAULT_HANDOFF_OUTPUT_PATH = path.join(DEFAULT_REPO_ROOT, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json');

const DEFAULT_THRESHOLDS = Object.freeze({
  writerLeaseFreshSeconds: 30 * 60,
  issueContextFreshSeconds: 6 * 60 * 60,
  handoffFreshSeconds: 24 * 60 * 60,
  sessionFreshSeconds: 7 * 24 * 60 * 60,
  deliveryStateFreshSeconds: 6 * 60 * 60,
  observerFreshSeconds: 6 * 60 * 60
});

function nowIso(now = new Date()) {
  return now.toISOString();
}

function safeParseJson(filePath) {
  try {
    if (!fs.existsSync(filePath)) {
      return { exists: false, payload: null, error: null, stat: null };
    }
    const raw = fs.readFileSync(filePath, 'utf8');
    const stat = fs.statSync(filePath);
    return {
      exists: true,
      payload: JSON.parse(raw),
      error: null,
      stat
    };
  } catch (error) {
    return {
      exists: true,
      payload: null,
      error: error instanceof Error ? error.message : String(error),
      stat: null
    };
  }
}

function ensureParentDir(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function writeJson(filePath, payload) {
  ensureParentDir(filePath);
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function parseDate(value) {
  if (!value || typeof value !== 'string') {
    return null;
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return new Date(parsed);
}

function toIso(value) {
  if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
    return null;
  }
  return value.toISOString();
}

function ageSeconds(referenceDate, now) {
  if (!(referenceDate instanceof Date) || Number.isNaN(referenceDate.getTime())) {
    return null;
  }
  return Math.max(0, Math.round((now.getTime() - referenceDate.getTime()) / 1000));
}

function newestDate(...values) {
  const dates = values
    .filter((value) => value instanceof Date && !Number.isNaN(value.getTime()))
    .sort((left, right) => right.getTime() - left.getTime());
  return dates[0] || null;
}

function describeSource({
  path: filePath,
  exists,
  error,
  observedAt,
  now,
  freshSeconds,
  extra = {}
}) {
  const age = ageSeconds(observedAt, now);
  return {
    path: filePath,
    exists,
    observedAt: toIso(observedAt),
    ageSeconds: age,
    freshnessThresholdSeconds: freshSeconds,
    fresh: age !== null ? age <= freshSeconds : false,
    error,
    ...extra
  };
}

function inspectWriterLease(repoRoot, now, thresholds, options = {}) {
  const leasePath = path.join(defaultLeaseRoot({
    repoRoot,
    env: options.env,
    spawnSyncFn: options.spawnSyncFn
  }), 'workspace.json');
  const { exists, payload, error, stat } = safeParseJson(leasePath);
  const observedAt = newestDate(
    parseDate(payload?.heartbeatAt),
    parseDate(payload?.acquiredAt),
    stat ? new Date(stat.mtimeMs) : null
  );
  return describeSource({
    path: leasePath,
    exists,
    error,
    observedAt,
    now,
    freshSeconds: thresholds.writerLeaseFreshSeconds,
    extra: {
      schema: payload?.schema || null,
      owner: payload?.owner || null,
      leaseId: payload?.leaseId || null,
      scope: payload?.scope || null
    }
  });
}

function inspectRouter(repoRoot, now, thresholds) {
  const routerPath = path.join(repoRoot, 'tests', 'results', '_agent', 'issue', 'router.json');
  const { exists, payload, error, stat } = safeParseJson(routerPath);
  const observedAt = stat ? new Date(stat.mtimeMs) : null;
  return describeSource({
    path: routerPath,
    exists,
    error,
    observedAt,
    now,
    freshSeconds: thresholds.issueContextFreshSeconds,
    extra: {
      schema: payload?.schema || null,
      issue: payload?.issue ?? null,
      actionCount: Array.isArray(payload?.actions) ? payload.actions.length : 0
    }
  });
}

function inspectNoStanding(repoRoot, now, thresholds) {
  const noStandingPath = path.join(repoRoot, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json');
  const { exists, payload, error, stat } = safeParseJson(noStandingPath);
  const observedAt = stat ? new Date(stat.mtimeMs) : null;
  return describeSource({
    path: noStandingPath,
    exists,
    error,
    observedAt,
    now,
    freshSeconds: thresholds.issueContextFreshSeconds,
    extra: {
      schema: payload?.schema || null,
      reason: payload?.reason || null,
      openIssueCount: payload?.openIssueCount ?? null
    }
  });
}

function inspectHandoffEntrypoint(repoRoot, now, thresholds) {
  const entrypointPath = path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'entrypoint-status.json');
  const { exists, payload, error, stat } = safeParseJson(entrypointPath);
  const observedAt = newestDate(
    parseDate(payload?.generatedAt),
    stat ? new Date(stat.mtimeMs) : null
  );
  return describeSource({
    path: entrypointPath,
    exists,
    error,
    observedAt,
    now,
    freshSeconds: thresholds.handoffFreshSeconds,
    extra: {
      schema: payload?.schema || null,
      status: payload?.status || null
    }
  });
}

function inspectSessions(repoRoot, now, thresholds) {
  const sessionsDir = path.join(repoRoot, 'tests', 'results', '_agent', 'sessions');
  let files = [];
  try {
    if (fs.existsSync(sessionsDir)) {
      files = fs.readdirSync(sessionsDir)
        .filter((entry) => entry.toLowerCase().endsWith('.json'))
        .map((entry) => {
          const fullPath = path.join(sessionsDir, entry);
          const stat = fs.statSync(fullPath);
          return {
            path: fullPath,
            mtime: new Date(stat.mtimeMs)
          };
        })
        .sort((left, right) => right.mtime.getTime() - left.mtime.getTime());
    }
  } catch {
    files = [];
  }

  const latest = files[0] || null;
  const age = latest ? ageSeconds(latest.mtime, now) : null;
  return {
    path: sessionsDir,
    exists: fs.existsSync(sessionsDir),
    observedAt: latest ? toIso(latest.mtime) : null,
    ageSeconds: age,
    freshnessThresholdSeconds: thresholds.sessionFreshSeconds,
    fresh: age !== null ? age <= thresholds.sessionFreshSeconds : false,
    count: files.length,
    latestPath: latest ? latest.path : null
  };
}

function inspectDeliveryState(repoRoot, now, thresholds) {
  const deliveryPath = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json');
  const runtimePath = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'runtime-state.json');
  const preferred = safeParseJson(deliveryPath);
  const fallback = preferred.exists ? null : safeParseJson(runtimePath);
  const selectedPath = preferred.exists ? deliveryPath : runtimePath;
  const selected = preferred.exists ? preferred : (fallback || { exists: false, payload: null, error: null, stat: null });
  const payload = selected.payload;
  const observedAt = newestDate(
    parseDate(payload?.generatedAt),
    parseDate(payload?.lifecycle?.updatedAt),
    selected.stat ? new Date(selected.stat.mtimeMs) : null
  );
  return describeSource({
    path: selectedPath,
    exists: selected.exists,
    error: selected.error,
    observedAt,
    now,
    freshSeconds: thresholds.deliveryStateFreshSeconds,
    extra: {
      schema: payload?.schema || null,
      source: preferred.exists ? 'delivery-agent-state' : (selected.exists ? 'runtime-state-compat' : 'missing'),
      status: payload?.status || payload?.lifecycle?.status || null,
      laneLifecycle: payload?.laneLifecycle || payload?.activeLane?.laneLifecycle || payload?.activeLane?.execution?.details?.laneLifecycle || null,
      blockerClass: payload?.activeLane?.blockerClass || payload?.activeLane?.execution?.details?.blockerClass || null,
      nextWakeCondition: payload?.activeLane?.nextWakeCondition || payload?.activeLane?.execution?.details?.nextWakeCondition || null,
      prUrl: payload?.activeLane?.prUrl || null,
      activeLaneIssue: payload?.activeLane?.issue ?? null,
      repoContextPivot: normalizeRepoContextPivot(payload?.activeLane?.repoContextPivot)
    }
  });
}

function inspectObserverHeartbeat(repoRoot, now, thresholds) {
  const observerPath = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'observer-heartbeat.json');
  const { exists, payload, error, stat } = safeParseJson(observerPath);
  const observedAt = newestDate(
    parseDate(payload?.generatedAt),
    stat ? new Date(stat.mtimeMs) : null
  );
  return describeSource({
    path: observerPath,
    exists,
    error,
    observedAt,
    now,
    freshSeconds: thresholds.observerFreshSeconds,
    extra: {
      schema: payload?.schema || null,
      outcome: payload?.outcome || null,
      laneLifecycle: payload?.activeLane?.execution?.details?.laneLifecycle || null,
      blockerClass: payload?.activeLane?.blockerClass || payload?.activeLane?.execution?.details?.blockerClass || null,
      nextWakeCondition: payload?.activeLane?.nextWakeCondition || payload?.activeLane?.execution?.details?.nextWakeCondition || null,
      prUrl: payload?.activeLane?.prUrl || null,
      activeLaneIssue: payload?.activeLane?.issue ?? null,
      repoContextPivot: normalizeRepoContextPivot(payload?.activeLane?.repoContextPivot)
    }
  });
}

function normalizeRepoContextPivot(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }

  const normalized = {
    currentRepository: typeof value.currentRepository === 'string' && value.currentRepository.trim() ? value.currentRepository.trim() : null,
    currentOwnerRepository:
      typeof value.currentOwnerRepository === 'string' && value.currentOwnerRepository.trim()
        ? value.currentOwnerRepository.trim()
        : null,
    nextOwnerRepository:
      typeof value.nextOwnerRepository === 'string' && value.nextOwnerRepository.trim()
        ? value.nextOwnerRepository.trim()
        : null,
    nextAction: typeof value.nextAction === 'string' && value.nextAction.trim() ? value.nextAction.trim() : null,
    ownerDecisionSource:
      typeof value.ownerDecisionSource === 'string' && value.ownerDecisionSource.trim()
        ? value.ownerDecisionSource.trim()
        : null,
    pivotStatus: typeof value.pivotStatus === 'string' && value.pivotStatus.trim() ? value.pivotStatus.trim() : null,
    brokerSelectionSource:
      typeof value.brokerSelectionSource === 'string' && value.brokerSelectionSource.trim()
        ? value.brokerSelectionSource.trim()
        : null
  };

  return Object.values(normalized).some((entry) => entry !== null) ? normalized : null;
}

function evaluateTurnBoundary({
  issueContext,
  deliveryState,
  observerHeartbeat
}) {
  if (issueContext.mode === 'queue-empty') {
    return {
      status: 'safe-idle',
      supervisionState: 'safe-idle',
      operatorTurnEndWouldCreateIdleGap: false,
      operatorPromptRequiredToResume: false,
      activeLaneIssue: null,
      wakeCondition: null,
      source: 'queue-empty',
      reason: 'standing-priority queue is explicitly empty',
      pendingActions: []
    };
  }

  if (issueContext.mode !== 'issue' || issueContext.issue === null) {
    return {
      status: 'stale-context',
      supervisionState: 'stale-context',
      operatorTurnEndWouldCreateIdleGap: true,
      operatorPromptRequiredToResume: true,
      activeLaneIssue: null,
      wakeCondition: null,
      source: 'issue-context-missing',
      reason: 'standing lane context is missing, so end-of-turn continuity cannot be trusted',
      pendingActions: [
        'Run bootstrap to refresh standing-priority state.',
        'Refresh handoff surfaces before treating the lane as supervised.'
      ]
    };
  }

  const issue = issueContext.issue;
  const deliveryMatch = deliveryState.activeLaneIssue === issue;
  const observerMatch = observerHeartbeat.activeLaneIssue === issue;
  const source = deliveryMatch ? 'delivery-state'
    : observerMatch ? 'observer-heartbeat'
      : 'issue-context';
  const wakeCondition = deliveryMatch ? deliveryState.nextWakeCondition
    : observerMatch ? observerHeartbeat.nextWakeCondition
      : null;
  const blockerClass = deliveryMatch ? deliveryState.blockerClass
    : observerMatch ? observerHeartbeat.blockerClass
      : null;
  const prUrl = deliveryMatch ? deliveryState.prUrl
    : observerMatch ? observerHeartbeat.prUrl
      : null;
  const repoContextPivot = deliveryMatch ? deliveryState.repoContextPivot
    : observerMatch ? observerHeartbeat.repoContextPivot
      : null;
  const pivotSupervised = Boolean(repoContextPivot?.nextOwnerRepository && repoContextPivot?.nextAction);
  const effectiveSource = pivotSupervised ? 'repo-context-pivot' : source;
  const effectiveWakeCondition = pivotSupervised ? null : (wakeCondition || null);
  const supervisedInBackground = Boolean(wakeCondition || blockerClass || prUrl || pivotSupervised);
  const supervisionState = supervisedInBackground ? 'supervised-background' : 'live-follow-through-required';
  const reason = supervisedInBackground
    ? pivotSupervised
      ? `standing issue #${issue} is already supervised through repo-context pivot ownership toward '${repoContextPivot.nextOwnerRepository}' with next action '${repoContextPivot.nextAction}'`
      : `standing issue #${issue} still has active work pending but is already supervised${wakeCondition ? ` and waiting for '${wakeCondition}'` : blockerClass ? ` under blocker class '${blockerClass}'` : prUrl ? ' through an active PR lane' : ''}`
    : deliveryMatch || observerMatch
      ? `standing issue #${issue} still has active work pending and no wake condition is recorded`
      : `standing issue #${issue} remains active; ending the turn here risks an idle gap`;
  const pendingActions = supervisedInBackground
    ? pivotSupervised
      ? [
          `Keep the brokered pivot toward '${repoContextPivot.nextOwnerRepository}' supervised for standing issue #${issue}.`,
          `Resume when repo-context action '${repoContextPivot.nextAction}' changes state for standing issue #${issue}.`
        ]
      : [
          wakeCondition
            ? `Resume when wake condition '${wakeCondition}' is satisfied for standing issue #${issue}.`
            : blockerClass
              ? `Resume when blocker class '${blockerClass}' clears for standing issue #${issue}.`
              : prUrl
                ? `Resume when the active PR lane changes state for standing issue #${issue}.`
                : `Keep supervising standing issue #${issue} through the background control plane.`
        ]
    : [
        `Keep the live lane active on standing issue #${issue} before ending the turn.`,
        'Delegate or stage the next concrete follow-through step so the standing lane does not go dark.'
      ];

  return {
    status: 'active-work-pending',
    supervisionState,
    operatorTurnEndWouldCreateIdleGap: !supervisedInBackground,
    operatorPromptRequiredToResume: !supervisedInBackground,
    activeLaneIssue: issue,
    wakeCondition: effectiveWakeCondition,
    source: effectiveSource,
    reason,
    pendingActions
  };
}

function resolveIssueContext(router, noStanding) {
  if (router.exists && router.issue !== null && router.issue !== undefined) {
    return {
      mode: 'issue',
      issue: router.issue,
      present: true,
      fresh: router.fresh,
      observedAt: router.observedAt,
      reason: null
    };
  }

  if (noStanding.exists && noStanding.reason === 'queue-empty') {
    return {
      mode: 'queue-empty',
      issue: null,
      present: true,
      fresh: noStanding.fresh,
      observedAt: noStanding.observedAt,
      reason: noStanding.reason
    };
  }

  return {
    mode: 'missing',
    issue: null,
    present: false,
    fresh: false,
    observedAt: null,
    reason: null
  };
}

function evaluateContinuity({
  writerLease,
  issueContext,
  handoffEntrypoint,
  sessions,
  deliveryState,
  observerHeartbeat,
  now
}) {
  const supplementalFresh = [
    handoffEntrypoint.fresh,
    sessions.fresh,
    deliveryState.fresh,
    observerHeartbeat.fresh
  ].filter(Boolean).length;

  const continuityReferenceAt = newestDate(
    parseDate(writerLease.observedAt),
    parseDate(issueContext.observedAt),
    parseDate(handoffEntrypoint.observedAt),
    parseDate(sessions.observedAt),
    parseDate(deliveryState.observedAt),
    parseDate(observerHeartbeat.observedAt)
  );
  const silenceGapSeconds = ageSeconds(continuityReferenceAt, now);

  const preservedWithoutPrompt = writerLease.fresh && issueContext.present && supplementalFresh > 0;
  const contextPresent = issueContext.present && (
    writerLease.exists ||
    handoffEntrypoint.exists ||
    sessions.count > 0 ||
    deliveryState.exists ||
    observerHeartbeat.exists
  );

  let status = 'stale';
  let quietPeriodStatus = 'broken';
  let promptDependency = 'high';
  let recommendedAction = 'run bootstrap and refresh handoff surfaces';
  let operatorQuietPeriodTreatedAsPause = true;

  if (preservedWithoutPrompt) {
    status = 'maintained';
    quietPeriodStatus = 'covered';
    promptDependency = 'low';
    recommendedAction = 'none';
    operatorQuietPeriodTreatedAsPause = false;
  } else if (contextPresent) {
    status = 'at-risk';
    quietPeriodStatus = 'degrading';
    promptDependency = 'medium';
    recommendedAction = issueContext.mode === 'queue-empty'
      ? 'refresh bootstrap or handoff to keep queue-empty idle state current'
      : 'refresh bootstrap or handoff before assuming the standing lane is still current';
    operatorQuietPeriodTreatedAsPause = false;
  }

  const turnBoundary = evaluateTurnBoundary({
    issueContext,
    deliveryState,
    observerHeartbeat
  });

  if (turnBoundary.operatorTurnEndWouldCreateIdleGap) {
    if (status === 'maintained') {
      status = 'at-risk';
    }
    if (quietPeriodStatus === 'covered') {
      quietPeriodStatus = 'degrading';
    }
    if (promptDependency === 'low') {
      promptDependency = 'medium';
    }
    recommendedAction = issueContext.mode === 'issue'
      ? 'keep the live lane active or hand the standing lane to a background worker before ending the turn'
      : recommendedAction;
    operatorQuietPeriodTreatedAsPause = true;
  } else if (turnBoundary.status === 'active-work-pending' && turnBoundary.supervisionState === 'supervised-background') {
    recommendedAction = turnBoundary.pendingActions[0] || 'continue supervising the background lane until its wake condition changes';
    operatorQuietPeriodTreatedAsPause = false;
  }

  return {
    status,
    preservedWithoutPrompt,
    promptDependency,
    unattendedSignalCount: [
      writerLease.fresh,
      issueContext.present,
      handoffEntrypoint.fresh,
      sessions.fresh,
      deliveryState.fresh,
      observerHeartbeat.fresh
    ].filter(Boolean).length,
    quietPeriod: {
      status: quietPeriodStatus,
      continuityReferenceAt: toIso(continuityReferenceAt),
      silenceGapSeconds,
      operatorQuietPeriodTreatedAsPause
    },
    turnBoundary,
    recommendation: recommendedAction
  };
}

export function buildContinuityTelemetry({
  repoRoot = DEFAULT_REPO_ROOT,
  thresholds = DEFAULT_THRESHOLDS,
  runtimeOutputPath = DEFAULT_RUNTIME_OUTPUT_PATH,
  handoffOutputPath = DEFAULT_HANDOFF_OUTPUT_PATH,
  env = process.env,
  spawnSyncFn
} = {}, now = new Date()) {
  const writerLease = inspectWriterLease(repoRoot, now, thresholds, { env, spawnSyncFn });
  const router = inspectRouter(repoRoot, now, thresholds);
  const noStanding = inspectNoStanding(repoRoot, now, thresholds);
  const handoffEntrypoint = inspectHandoffEntrypoint(repoRoot, now, thresholds);
  const sessions = inspectSessions(repoRoot, now, thresholds);
  const deliveryState = inspectDeliveryState(repoRoot, now, thresholds);
  const observerHeartbeat = inspectObserverHeartbeat(repoRoot, now, thresholds);
  const issueContext = resolveIssueContext(router, noStanding);
  const continuity = evaluateContinuity({
    writerLease,
    issueContext,
    handoffEntrypoint,
    sessions,
    deliveryState,
    observerHeartbeat,
    now
  });

  const report = {
    schema: 'priority/continuity-telemetry-report@v1',
    generatedAt: nowIso(now),
    repoRoot,
    status: continuity.status,
    issueContext,
    continuity,
    sources: {
      writerLease,
      router,
      noStanding,
      handoffEntrypoint,
      sessions,
      deliveryState,
      observerHeartbeat
    },
    artifacts: {
      runtimePath: runtimeOutputPath,
      handoffPath: handoffOutputPath
    }
  };

  return {
    report,
    runtimeOutputPath,
    handoffOutputPath
  };
}

export function parseArgs(argv = process.argv.slice(2)) {
  const parsed = {
    repoRoot: DEFAULT_REPO_ROOT,
    runtimeOutputPath: DEFAULT_RUNTIME_OUTPUT_PATH,
    handoffOutputPath: DEFAULT_HANDOFF_OUTPUT_PATH,
    now: null
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    switch (token) {
      case '--repo-root':
        parsed.repoRoot = path.resolve(argv[++index] || DEFAULT_REPO_ROOT);
        break;
      case '--output':
        parsed.runtimeOutputPath = path.resolve(parsed.repoRoot, argv[++index] || DEFAULT_RUNTIME_OUTPUT_PATH);
        break;
      case '--handoff-output':
        parsed.handoffOutputPath = path.resolve(parsed.repoRoot, argv[++index] || DEFAULT_HANDOFF_OUTPUT_PATH);
        break;
      case '--now':
        parsed.now = argv[++index] || null;
        break;
      case '--help':
      case '-h':
        parsed.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${token}`);
    }
  }

  if (parsed.runtimeOutputPath === DEFAULT_RUNTIME_OUTPUT_PATH) {
    parsed.runtimeOutputPath = path.join(parsed.repoRoot, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json');
  }
  if (parsed.handoffOutputPath === DEFAULT_HANDOFF_OUTPUT_PATH) {
    parsed.handoffOutputPath = path.join(parsed.repoRoot, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json');
  }

  return parsed;
}

function printUsage() {
  console.log(`Usage:
  node tools/priority/continuity-telemetry.mjs [options]

Options:
  --repo-root <path>       Repository root to inspect
  --output <path>          Runtime continuity report path
  --handoff-output <path>  Handoff continuity summary path
  --now <iso>              Override current time (tests)
`);
}

export function runContinuityTelemetry(options = {}, now = null) {
  const effectiveNow = now || (options.now ? new Date(options.now) : new Date());
  const result = buildContinuityTelemetry(options, effectiveNow);
  writeJson(result.runtimeOutputPath, result.report);
  writeJson(result.handoffOutputPath, result.report);
  return result;
}

async function main() {
  const options = parseArgs();
  if (options.help) {
    printUsage();
    return 0;
  }

  const result = runContinuityTelemetry(options);
  process.stdout.write(
    `[continuity] status=${result.report.status} quiet=${result.report.continuity.quietPeriod.status} pause=${result.report.continuity.quietPeriod.operatorQuietPeriodTreatedAsPause} -> ${result.runtimeOutputPath}\n`
  );
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;

if (invokedPath && invokedPath === modulePath) {
  try {
    const code = await main();
    process.exit(code);
  } catch (error) {
    process.stderr.write(`[continuity] ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }
}

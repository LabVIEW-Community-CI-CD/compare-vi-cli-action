#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/agent-spend-gap-slo@v1';
export const DEFAULT_COST_ROLLUP_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_THROUGHPUT_SCORECARD_PATH = path.join('tests', 'results', '_agent', 'throughput', 'throughput-scorecard.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-spend-gap-slo.json');
export const DEFAULT_GAP_THRESHOLD_MINUTES = 30;

const ACTIONABLE_REASON_CODES = new Set([
  'actionable-work-with-idle-worker-pool',
  'actionable-work-below-worker-slot-target'
]);

const HELP = [
  'Usage: node tools/priority/agent-spend-gap-slo.mjs [options]',
  '',
  'Options:',
  `  --cost-rollup <path>           Agent cost rollup path (default: ${DEFAULT_COST_ROLLUP_PATH}).`,
  `  --throughput <path>            Throughput scorecard path (default: ${DEFAULT_THROUGHPUT_SCORECARD_PATH}).`,
  `  --gap-threshold-minutes <n>    Minimum gap duration to classify (default: ${DEFAULT_GAP_THRESHOLD_MINUTES}).`,
  `  --output <path>                Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --repo <owner/repo>            Repository slug override.',
  '  --help                         Show help.'
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

function coerceNonNegativeInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function roundMetric(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.round(parsed * 1000) / 1000;
}

function roundPerDollar(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  return Math.round(parsed * 1000000) / 1000000;
}

function normalizeInputRef(input = null) {
  return {
    path: input?.path ?? null,
    exists: input?.exists === true,
    error: input?.error ?? null
  };
}

function resolveTurnEvent(turn = {}) {
  const raw = normalizeText(turn?.provenance?.usageObservedAt) || normalizeText(turn?.generatedAt);
  if (!raw) return { iso: null, ms: null };
  const ms = Date.parse(raw);
  if (!Number.isFinite(ms)) return { iso: null, ms: null };
  return { iso: new Date(ms).toISOString(), ms };
}

function buildTurnEvidence(turn = {}) {
  return {
    issueNumber: coerceNonNegativeInteger(turn.issueNumber),
    turnId: normalizeText(turn.turnId) || null,
    laneId: normalizeText(turn.laneId) || null,
    agentRole: normalizeText(turn.agentRole) || null,
    providerId: normalizeText(turn.providerId) || null,
    effectiveModel: normalizeText(turn.effectiveModel) || null,
    effectiveReasoningEffort: normalizeText(turn.effectiveReasoningEffort) || null,
    amountUsd: coerceNonNegativeNumber(turn.amountUsd) ?? 0,
    exactness: normalizeText(turn.exactness) === 'exact' ? 'exact' : 'estimated'
  };
}

function extractThroughputEvidence(throughputScorecard = null) {
  const reasons = Array.isArray(throughputScorecard?.summary?.reasons)
    ? throughputScorecard.summary.reasons.map((entry) => normalizeText(entry)).filter(Boolean)
    : [];
  const metrics = throughputScorecard?.summary?.metrics && typeof throughputScorecard.summary.metrics === 'object'
    ? throughputScorecard.summary.metrics
    : {};

  const readyPrInventory =
    coerceNonNegativeInteger(metrics.readyPrInventory) ??
    coerceNonNegativeInteger(throughputScorecard?.queue?.readyPrInventory);
  const currentWorkerUtilizationRatio =
    coerceNonNegativeNumber(metrics.currentWorkerUtilizationRatio) ??
    coerceNonNegativeNumber(throughputScorecard?.workerPool?.utilizationRatio);
  const concurrentLaneActiveCount =
    coerceNonNegativeInteger(metrics.concurrentLaneActiveCount) ??
    coerceNonNegativeInteger(throughputScorecard?.concurrentLanes?.activeLaneCount);
  const concurrentLaneDeferredCount =
    coerceNonNegativeInteger(metrics.concurrentLaneDeferredCount) ??
    coerceNonNegativeInteger(throughputScorecard?.concurrentLanes?.deferredLaneCount);
  const hostedWaitEscapeCount =
    coerceNonNegativeInteger(metrics.hostedWaitEscapeCount) ??
    coerceNonNegativeInteger(throughputScorecard?.delivery?.hostedWaitEscapeCount);

  return {
    available:
      throughputScorecard != null
      && readyPrInventory != null
      && currentWorkerUtilizationRatio != null
      && concurrentLaneActiveCount != null
      && concurrentLaneDeferredCount != null,
    readyPrInventory,
    currentWorkerUtilizationRatio,
    concurrentLaneActiveCount,
    concurrentLaneDeferredCount,
    hostedWaitEscapeCount,
    throughputReasons: reasons
  };
}

function extractFundedThroughputEvidence({ costRollup = null, throughputScorecard = null, inputPaths = {}, observedMinutes = 0 } = {}) {
  const billingWindow = costRollup?.billingWindow && typeof costRollup.billingWindow === 'object' ? costRollup.billingWindow : {};
  const summaryMetrics = costRollup?.summary?.metrics && typeof costRollup.summary.metrics === 'object'
    ? costRollup.summary.metrics
    : {};
  const delivery = throughputScorecard?.delivery && typeof throughputScorecard.delivery === 'object'
    ? throughputScorecard.delivery
    : {};
  const fundedUsd = coerceNonNegativeNumber(billingWindow.prepaidUsd);
  const actualUsdConsumed = coerceNonNegativeNumber(summaryMetrics.actualUsdConsumed);
  const heuristicUsdDelta =
    actualUsdConsumed != null && coerceNonNegativeNumber(summaryMetrics.totalUsd) != null
      ? roundMetric(summaryMetrics.totalUsd - actualUsdConsumed)
      : null;
  const heuristicUsdDeltaRatio =
    actualUsdConsumed != null && actualUsdConsumed > 0 && heuristicUsdDelta != null
      ? roundPerDollar(heuristicUsdDelta / actualUsdConsumed)
      : null;

  const validatedPullRequestCount = coerceNonNegativeInteger(delivery.mergedPullRequestCount) ?? 0;
  const closedIssueCount = coerceNonNegativeInteger(delivery.closedPullRequestCount) ?? 0;
  const promotionEvidenceCount = coerceNonNegativeInteger(delivery.totalTerminalPullRequestCount) ?? (validatedPullRequestCount + closedIssueCount);
  const hostedWaitEscapeCount = coerceNonNegativeInteger(delivery.hostedWaitEscapeCount) ?? 0;
  const activeLaneCount =
    coerceNonNegativeInteger(throughputScorecard?.concurrentLanes?.activeLaneCount) ??
    coerceNonNegativeInteger(throughputScorecard?.summary?.metrics?.concurrentLaneActiveCount) ??
    0;
  const laneMinutesAllocated = roundMetric(activeLaneCount * Math.max(observedMinutes, 0));

  const perDollar = fundedUsd != null && fundedUsd > 0
    ? (count) => roundPerDollar(count / fundedUsd)
    : () => null;

  return {
    fundingWindow: {
      invoiceTurnId: normalizeText(billingWindow.invoiceTurnId) || null,
      mode: normalizeText(billingWindow.selection?.mode) || null,
      calibrationWindowId: normalizeText(billingWindow.selection?.calibrationWindowId) || null,
      activationState: normalizeText(billingWindow.activationState) || null,
      fundingPurpose: normalizeText(billingWindow.fundingPurpose) || null,
      kind: normalizeText(billingWindow.fundingPurpose) === 'calibration' ? 'calibration' : 'operational',
      prepaidUsd: fundedUsd,
      actualUsdConsumed,
      heuristicUsdDelta,
      heuristicUsdDeltaRatio
    },
    metrics: {
      validatedPullRequestCount,
      closedIssueCount,
      promotionEvidenceCount,
      laneMinutesAllocated,
      hostedWaitEscapeCount,
      validatedPullRequestsPerFundedDollar: perDollar(validatedPullRequestCount),
      closedIssuesPerFundedDollar: perDollar(closedIssueCount),
      promotionEvidencePerFundedDollar: perDollar(promotionEvidenceCount),
      laneMinutesAllocatedPerFundedDollar: perDollar(laneMinutesAllocated),
      hostedWaitEscapesPerFundedDollar: perDollar(hostedWaitEscapeCount)
    },
    provenance: {
      costRollup: normalizeInputRef(inputPaths.costRollupPath),
      throughputScorecard: normalizeInputRef(inputPaths.throughputScorecardPath),
      sourceKind: 'composed-scorecard',
      sourcePathEvidence: 'Derived from agent-cost-rollup billingWindow and throughput-scorecard delivery evidence.',
      operatorNote: 'Validated throughput per funded dollar is reported as a derived projection, not a replacement for invoice-turn reconciliation.'
    }
  };
}

function classifyGap(previousTurn, nextTurn, evidence) {
  if (!evidence.available) {
    return {
      classification: 'insufficient-evidence',
      trackingIssueNumber: null
    };
  }

  const actionableSignal =
    evidence.throughputReasons.some((reason) => ACTIONABLE_REASON_CODES.has(reason))
    || (evidence.readyPrInventory > 0 && evidence.currentWorkerUtilizationRatio === 0);

  if (actionableSignal) {
    return {
      classification: 'optimization-signal',
      trackingIssueNumber: null
    };
  }

  const laneTransition =
    normalizeText(previousTurn?.laneId)
    && normalizeText(nextTurn?.laneId)
    && normalizeText(previousTurn.laneId) !== normalizeText(nextTurn.laneId);
  const issueTransition =
    coerceNonNegativeInteger(previousTurn?.issueNumber) != null
    && coerceNonNegativeInteger(nextTurn?.issueNumber) != null
    && coerceNonNegativeInteger(previousTurn.issueNumber) !== coerceNonNegativeInteger(nextTurn.issueNumber);
  const trackedFollowup =
    laneTransition
    || issueTransition
    || evidence.concurrentLaneActiveCount > 0
    || evidence.concurrentLaneDeferredCount > 0;

  if (trackedFollowup) {
    return {
      classification: 'tracked-followup',
      trackingIssueNumber:
        coerceNonNegativeInteger(nextTurn?.issueNumber) ??
        coerceNonNegativeInteger(previousTurn?.issueNumber) ??
        null
    };
  }

  if (
    evidence.readyPrInventory === 0
    && evidence.concurrentLaneActiveCount === 0
    && evidence.concurrentLaneDeferredCount === 0
  ) {
    return {
      classification: 'accepted-quiet-window',
      trackingIssueNumber: null
    };
  }

  return {
    classification: 'insufficient-evidence',
    trackingIssueNumber: null
  };
}

function buildGap(previousTurn, nextTurn, evidence) {
  const startedAt = resolveTurnEvent(previousTurn);
  const endedAt = resolveTurnEvent(nextTurn);
  const durationMinutes = roundMetric((endedAt.ms - startedAt.ms) / 60000);
  const classification = classifyGap(previousTurn, nextTurn, evidence);

  return {
    startedAt: startedAt.iso,
    endedAt: endedAt.iso,
    durationMinutes,
    previousTurn: buildTurnEvidence(previousTurn),
    nextTurn: buildTurnEvidence(nextTurn),
    classification: classification.classification,
    trackingIssueNumber: classification.trackingIssueNumber,
    evidence: {
      readyPrInventory: evidence.readyPrInventory,
      currentWorkerUtilizationRatio: evidence.currentWorkerUtilizationRatio,
      concurrentLaneActiveCount: evidence.concurrentLaneActiveCount,
      concurrentLaneDeferredCount: evidence.concurrentLaneDeferredCount,
      hostedWaitEscapeCount: evidence.hostedWaitEscapeCount,
      throughputReasons: evidence.throughputReasons
    }
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    costRollupPath: DEFAULT_COST_ROLLUP_PATH,
    throughputScorecardPath: DEFAULT_THROUGHPUT_SCORECARD_PATH,
    gapThresholdMinutes: DEFAULT_GAP_THRESHOLD_MINUTES,
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
    if (['--cost-rollup', '--throughput', '--gap-threshold-minutes', '--output', '--repo'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--throughput') options.throughputScorecardPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--gap-threshold-minutes') {
        const threshold = Number(next);
        if (!Number.isFinite(threshold) || threshold < 0) {
          throw new Error('--gap-threshold-minutes must be a non-negative number.');
        }
        options.gapThresholdMinutes = threshold;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export function buildAgentSpendGapSlo({
  repository = null,
  costRollup = null,
  throughputScorecard = null,
  inputPaths = {},
  gapThresholdMinutes = DEFAULT_GAP_THRESHOLD_MINUTES,
  now = new Date()
} = {}) {
  const thresholdMinutes = coerceNonNegativeNumber(gapThresholdMinutes) ?? DEFAULT_GAP_THRESHOLD_MINUTES;
  const throughputEvidence = extractThroughputEvidence(throughputScorecard);
  const turns = Array.isArray(costRollup?.turns) ? costRollup.turns : [];
  const orderedTurns = turns
    .map((turn) => ({
      turn,
      event: resolveTurnEvent(turn)
    }))
    .filter((entry) => entry.event.ms != null)
    .sort((left, right) => left.event.ms - right.event.ms);

  const gaps = [];
  for (let index = 1; index < orderedTurns.length; index += 1) {
    const previousTurn = orderedTurns[index - 1];
    const nextTurn = orderedTurns[index];
    const durationMinutes = (nextTurn.event.ms - previousTurn.event.ms) / 60000;
    if (durationMinutes >= thresholdMinutes) {
      gaps.push(buildGap(previousTurn.turn, nextTurn.turn, throughputEvidence));
    }
  }

  const metrics = {
    totalSpendTurns: turns.length,
    totalGapCount: gaps.length,
    optimizationSignalGapCount: gaps.filter((gap) => gap.classification === 'optimization-signal').length,
    trackedGapCount: gaps.filter((gap) => gap.classification === 'tracked-followup').length,
    quietWindowGapCount: gaps.filter((gap) => gap.classification === 'accepted-quiet-window').length,
    unexplainedGapCount: gaps.filter((gap) => gap.classification === 'insufficient-evidence').length,
    largestGapMinutes: gaps.length > 0 ? Math.max(...gaps.map((gap) => gap.durationMinutes)) : 0,
    totalGapMinutes: roundMetric(gaps.reduce((total, gap) => total + gap.durationMinutes, 0))
  };

  const reasons = [];
  if (!Array.isArray(costRollup?.turns)) {
    reasons.push('cost-rollup-unavailable');
  }
  if (!throughputEvidence.available) {
    reasons.push('throughput-scorecard-unavailable');
  }
  if (metrics.totalGapCount === 0) {
    reasons.push('no-spend-gaps-observed');
  }
  if (metrics.optimizationSignalGapCount > 0) {
    reasons.push('optimization-signal-gaps-observed');
  }
  if (metrics.trackedGapCount > 0) {
    reasons.push('tracked-followup-gaps-observed');
  }
  if (metrics.quietWindowGapCount > 0) {
    reasons.push('quiet-window-gaps-observed');
  }
  if (metrics.unexplainedGapCount > 0) {
    reasons.push('spend-gap-evidence-incomplete');
  }

  const firstSpendAt = orderedTurns[0]?.event.iso ?? null;
  const lastSpendAt = orderedTurns[orderedTurns.length - 1]?.event.iso ?? null;
  const observedMinutes =
    orderedTurns.length > 1
      ? roundMetric((orderedTurns[orderedTurns.length - 1].event.ms - orderedTurns[0].event.ms) / 60000)
      : 0;
  const fundedThroughput = extractFundedThroughputEvidence({
    costRollup,
    throughputScorecard,
    inputPaths,
    observedMinutes
  });

  if (fundedThroughput.fundingWindow.prepaidUsd == null || fundedThroughput.fundingWindow.prepaidUsd === 0) {
    reasons.push('funded-throughput-window-unavailable');
  }

  return {
    schema: REPORT_SCHEMA,
    generatedAt: toIso(now),
    repository: normalizeText(repository) || null,
    inputs: {
      costRollupPath: normalizeInputRef(inputPaths.costRollupPath),
      throughputScorecardPath: normalizeInputRef(inputPaths.throughputScorecardPath),
      gapThresholdMinutes: thresholdMinutes
    },
    window: {
      firstSpendAt,
      lastSpendAt,
      observedMinutes
    },
    summary: {
      status:
        reasons.some((reason) =>
          ['cost-rollup-unavailable', 'throughput-scorecard-unavailable', 'optimization-signal-gaps-observed', 'spend-gap-evidence-incomplete', 'funded-throughput-window-unavailable'].includes(reason)
        )
          ? 'warn'
          : 'pass',
      reasons,
      metrics
    },
    fundedThroughput,
    gaps
  };
}

export function runAgentSpendGapSlo({
  repo = null,
  costRollupPath = DEFAULT_COST_ROLLUP_PATH,
  throughputScorecardPath = DEFAULT_THROUGHPUT_SCORECARD_PATH,
  gapThresholdMinutes = DEFAULT_GAP_THRESHOLD_MINUTES,
  outputPath = DEFAULT_OUTPUT_PATH,
  now = new Date()
} = {}) {
  const costRollupInput = loadJsonInput(costRollupPath);
  const throughputScorecardInput = loadJsonInput(throughputScorecardPath);
  const repository =
    normalizeText(repo) ||
    normalizeText(costRollupInput.payload?.repository) ||
    normalizeText(throughputScorecardInput.payload?.repository) ||
    resolveRepoSlug(repo) ||
    null;
  const report = buildAgentSpendGapSlo({
    repository,
    costRollup: costRollupInput.payload,
    throughputScorecard: throughputScorecardInput.payload,
    inputPaths: {
      costRollupPath: costRollupInput,
      throughputScorecardPath: throughputScorecardInput
    },
    gapThresholdMinutes,
    now
  });

  const resolvedOutputPath = path.resolve(outputPath);
  fs.mkdirSync(path.dirname(resolvedOutputPath), { recursive: true });
  fs.writeFileSync(resolvedOutputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return {
    report,
    outputPath: resolvedOutputPath,
    inputs: {
      costRollup: costRollupInput,
      throughputScorecard: throughputScorecardInput
    }
  };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return 0;
  }
  const result = runAgentSpendGapSlo(options);
  console.log(
    `[agent-spend-gap-slo] report: ${result.outputPath} status=${result.report.summary.status} gaps=${result.report.summary.metrics.totalGapCount}`
  );
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv);
  } catch (error) {
    console.error(`[agent-spend-gap-slo] ${error.message || error}`);
    process.exitCode = 1;
  }
}

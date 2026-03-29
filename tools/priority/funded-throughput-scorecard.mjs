#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const COST_ROLLUP_SCHEMA = 'priority/agent-cost-rollup@v1';
export const THROUGHPUT_SCORECARD_SCHEMA = 'priority/throughput-scorecard@v1';
export const REPORT_SCHEMA = 'priority/funded-throughput-scorecard@v1';
export const DEFAULT_COST_ROLLUP_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_THROUGHPUT_SCORECARD_PATH = path.join('tests', 'results', '_agent', 'throughput', 'throughput-scorecard.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'capital', 'funded-throughput-scorecard.json');

export const IMPLEMENTED_METRIC_CODES = [
  'validated-merged-prs-per-funded-dollar',
  'issues-closed-per-funded-dollar',
  'promotion-evidence-per-funded-dollar',
  'lane-minutes-allocated-per-funded-dollar',
  'hosted-wait-escapes-per-funded-dollar',
  'heuristic-spend-drift-relative-to-invoice-turn'
];

export const PROJECTED_METRIC_CODES = [
  'issues-closed-per-funded-dollar',
  'promotion-evidence-per-funded-dollar',
  'lane-minutes-allocated-per-funded-dollar'
];
export const DEFERRED_METRICS = [];

const HELP = [
  'Usage: node tools/priority/funded-throughput-scorecard.mjs [options]',
  '',
  'Options:',
  `  --cost-rollup <path>  Agent cost rollup path (default: ${DEFAULT_COST_ROLLUP_PATH}).`,
  `  --throughput <path>   Throughput scorecard path (default: ${DEFAULT_THROUGHPUT_SCORECARD_PATH}).`,
  `  --output <path>       Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --repo <owner/repo>   Repository slug override.',
  '  --help                Show help.'
];

function printHelp(log = console.log) {
  for (const line of HELP) {
    log(line);
  }
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

function createBlocker(code, message, inputPath = null) {
  return {
    code,
    message,
    inputPath
  };
}

function normalizeInputRef(input = null) {
  return {
    path: input?.path ?? null,
    exists: input?.exists === true,
    error: input?.error ?? null
  };
}

function coerceNonNegativeNumber(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function coerceNonNegativeInteger(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function coerceFiniteNumber(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function roundNumber(value, precision = 6) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  return Number(parsed.toFixed(precision));
}

function computeRatio(numerator, denominator) {
  const safeNumerator = coerceNonNegativeNumber(numerator);
  const safeDenominator = coerceNonNegativeNumber(denominator);
  if (safeNumerator == null || safeDenominator == null || safeDenominator === 0) {
    return null;
  }
  return roundNumber(safeNumerator / safeDenominator);
}

function classifyFundingWindow(billingWindow = null) {
  const fundingPurpose = normalizeText(billingWindow?.fundingPurpose).toLowerCase();
  const selectionMode = normalizeText(billingWindow?.selection?.mode).toLowerCase();
  if (fundingPurpose === 'calibration' || selectionMode === 'sticky-calibration') {
    return 'calibration';
  }
  if (fundingPurpose === 'operational') {
    return 'operational';
  }
  return 'unknown';
}

function extractCostEvidence(costRollup = null, costRollupInput = null) {
  const blockers = [];
  if (costRollupInput?.exists === false) {
    blockers.push(
      createBlocker(
        'cost-rollup-missing',
        'Agent cost rollup is missing, so funded-dollar attribution cannot be scored.',
        costRollupInput.path
      )
    );
  }
  if (costRollupInput?.error) {
    blockers.push(
      createBlocker(
        'cost-rollup-unreadable',
        `Agent cost rollup could not be parsed: ${costRollupInput.error}`,
        costRollupInput.path
      )
    );
  }

  if (costRollupInput?.exists === true && !costRollupInput?.error && normalizeText(costRollup?.schema) !== COST_ROLLUP_SCHEMA) {
    blockers.push(
      createBlocker(
        'cost-rollup-schema-mismatch',
        `Agent cost rollup schema must remain ${COST_ROLLUP_SCHEMA}.`,
        costRollupInput.path
      )
    );
  }

  const metrics = costRollup?.summary?.metrics && typeof costRollup.summary.metrics === 'object'
    ? costRollup.summary.metrics
    : {};
  const billingWindow = costRollup?.billingWindow && typeof costRollup.billingWindow === 'object'
    ? costRollup.billingWindow
    : null;

  const fundedUsd = coerceNonNegativeNumber(metrics.totalUsd);
  if (fundedUsd == null) {
    blockers.push(
      createBlocker(
        'funded-usd-missing',
        'Agent cost rollup summary.metrics.totalUsd is required to compute funded-dollar ratios.',
        costRollupInput?.path ?? null
      )
    );
  }
  if (!billingWindow) {
    blockers.push(
      createBlocker(
        'billing-window-missing',
        'Agent cost rollup billingWindow is required so funding-window attribution remains explicit.',
        costRollupInput?.path ?? null
      )
    );
  }

  return {
    blockers,
    fundedUsd,
    exactUsd: coerceNonNegativeNumber(metrics.exactUsd) ?? 0,
    estimatedUsd: coerceNonNegativeNumber(metrics.estimatedUsd) ?? 0,
    actualUsdConsumed: coerceNonNegativeNumber(metrics.actualUsdConsumed),
    heuristicUsdDelta: coerceFiniteNumber(metrics.heuristicUsdDelta),
    heuristicUsdDeltaRatio: coerceFiniteNumber(metrics.heuristicUsdDeltaRatio),
    fundingWindow: {
      invoiceTurnId: normalizeText(billingWindow?.invoiceTurnId) || null,
      invoiceId: normalizeText(billingWindow?.invoiceId) || null,
      openedAt: normalizeText(billingWindow?.openedAt) || null,
      closedAt: normalizeText(billingWindow?.closedAt) || null,
      fundingPurpose: normalizeText(billingWindow?.fundingPurpose) || null,
      activationState: normalizeText(billingWindow?.activationState) || null,
      windowClass: classifyFundingWindow(billingWindow),
      reconciliationStatus: normalizeText(billingWindow?.reconciliationStatus) || null,
      selectionMode: normalizeText(billingWindow?.selection?.mode) || null,
      calibrationWindowId: normalizeText(billingWindow?.selection?.calibrationWindowId) || null,
      reconciledAt: normalizeText(billingWindow?.reconciledAt) || null
    }
  };
}

function extractThroughputEvidence(throughputScorecard = null, throughputScorecardInput = null) {
  const blockers = [];
  if (throughputScorecardInput?.exists === false) {
    blockers.push(
      createBlocker(
        'throughput-scorecard-missing',
        'Throughput scorecard is missing, so validated output cannot be paired with funded spend.',
        throughputScorecardInput.path
      )
    );
  }
  if (throughputScorecardInput?.error) {
    blockers.push(
      createBlocker(
        'throughput-scorecard-unreadable',
        `Throughput scorecard could not be parsed: ${throughputScorecardInput.error}`,
        throughputScorecardInput.path
      )
    );
  }

  if (
    throughputScorecardInput?.exists === true
    && !throughputScorecardInput?.error
    && normalizeText(throughputScorecard?.schema) !== THROUGHPUT_SCORECARD_SCHEMA
  ) {
    blockers.push(
      createBlocker(
        'throughput-scorecard-schema-mismatch',
        `Throughput scorecard schema must remain ${THROUGHPUT_SCORECARD_SCHEMA}.`,
        throughputScorecardInput.path
      )
    );
  }

  const delivery = throughputScorecard?.delivery && typeof throughputScorecard.delivery === 'object'
    ? throughputScorecard.delivery
    : {};
  const summaryMetrics = throughputScorecard?.summary?.metrics && typeof throughputScorecard.summary.metrics === 'object'
    ? throughputScorecard.summary.metrics
    : {};

  const validatedMergedPullRequestCount = coerceNonNegativeInteger(delivery.mergedPullRequestCount);
  const closedIssueCount =
    coerceNonNegativeInteger(delivery.closedPullRequestCount) ??
    coerceNonNegativeInteger(summaryMetrics.closedPullRequestCount);
  const totalTerminalPullRequestCount = coerceNonNegativeInteger(delivery.totalTerminalPullRequestCount);
  const hostedWaitEscapeCount =
    coerceNonNegativeInteger(delivery.hostedWaitEscapeCount) ??
    coerceNonNegativeInteger(summaryMetrics.hostedWaitEscapeCount);
  const concurrentLaneActiveCount =
    coerceNonNegativeInteger(summaryMetrics.concurrentLaneActiveCount) ??
    coerceNonNegativeInteger(throughputScorecard?.concurrentLanes?.activeLaneCount);
  const meanTerminalDurationMinutes =
    coerceNonNegativeNumber(delivery.meanTerminalDurationMinutes) ??
    coerceNonNegativeNumber(summaryMetrics.meanTerminalDurationMinutes);
  const promotionEvidenceCount =
    totalTerminalPullRequestCount ??
    ((validatedMergedPullRequestCount ?? 0) + (closedIssueCount ?? 0));
  const laneMinutesAllocated =
    concurrentLaneActiveCount != null && meanTerminalDurationMinutes != null
      ? roundNumber(concurrentLaneActiveCount * meanTerminalDurationMinutes)
      : null;
  const currentCycleIdleAuthority =
    throughputScorecard?.workerPool?.currentCycleIdleAuthority
    && typeof throughputScorecard.workerPool.currentCycleIdleAuthority === 'object'
      ? throughputScorecard.workerPool.currentCycleIdleAuthority
      : null;

  if (validatedMergedPullRequestCount == null) {
    blockers.push(
      createBlocker(
        'validated-merged-throughput-missing',
        'Throughput scorecard delivery.mergedPullRequestCount is required for validated throughput scoring.',
        throughputScorecardInput?.path ?? null
      )
    );
  }
  if (totalTerminalPullRequestCount == null) {
    blockers.push(
      createBlocker(
        'terminal-throughput-missing',
        'Throughput scorecard delivery.totalTerminalPullRequestCount is required for scorecard context.',
        throughputScorecardInput?.path ?? null
      )
    );
  }
  if (hostedWaitEscapeCount == null) {
    blockers.push(
      createBlocker(
        'hosted-wait-escape-missing',
        'Throughput scorecard hosted wait escape evidence is required for the first funded-dollar slice.',
        throughputScorecardInput?.path ?? null
      )
    );
  }

  return {
    blockers,
    throughputWindow: {
      currentCycleIdleStatus: normalizeText(currentCycleIdleAuthority?.status) || 'missing',
      currentCycleIdleSource: normalizeText(currentCycleIdleAuthority?.source) || null,
      currentCycleIdleObservedAt: normalizeText(currentCycleIdleAuthority?.observedAt) || null,
      currentCycleIdleNextWakeCondition: normalizeText(currentCycleIdleAuthority?.nextWakeCondition) || null
    },
    validatedMergedPullRequestCount: validatedMergedPullRequestCount ?? 0,
    closedIssueCount: closedIssueCount ?? 0,
    promotionEvidenceCount: promotionEvidenceCount ?? 0,
    concurrentLaneActiveCount: concurrentLaneActiveCount ?? 0,
    meanTerminalDurationMinutes,
    laneMinutesAllocated,
    totalTerminalPullRequestCount: totalTerminalPullRequestCount ?? 0,
    hostedWaitEscapeCount: hostedWaitEscapeCount ?? 0
  };
}

function resolveRecommendation({ blockers, reasons }) {
  if (blockers.length > 0) {
    return 'repair-input-receipts';
  }
  if (reasons.includes('no-funded-spend-observed')) {
    return 'observe-funded-window';
  }
  if (reasons.includes('calibration-window')) {
    return 'continue-calibration-before-benchmarking';
  }
  if (reasons.includes('estimated-spend-present')) {
    return 'continue-estimated-telemetry';
  }
  if (reasons.includes('invoice-reconciliation-pending')) {
    return 'continue-invoice-reconciliation';
  }
  if (reasons.includes('current-cycle-idle-window')) {
    return 'observe-funded-window';
  }
  if (reasons.includes('zero-validated-throughput')) {
    return 'increase-validated-throughput';
  }
  return 'benchmark-operational-throughput';
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    costRollupPath: DEFAULT_COST_ROLLUP_PATH,
    throughputScorecardPath: DEFAULT_THROUGHPUT_SCORECARD_PATH,
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
    if (['--cost-rollup', '--throughput', '--output', '--repo'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--throughput') options.throughputScorecardPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export function buildFundedThroughputScorecard({
  repository = null,
  costRollup = null,
  throughputScorecard = null,
  inputPaths = {},
  now = new Date()
} = {}) {
  const costEvidence = extractCostEvidence(costRollup, inputPaths.costRollupPath);
  const throughputEvidence = extractThroughputEvidence(throughputScorecard, inputPaths.throughputScorecardPath);
  const blockers = [...costEvidence.blockers, ...throughputEvidence.blockers];

  const metrics = {
    fundedUsd: costEvidence.fundedUsd ?? 0,
    exactUsd: costEvidence.exactUsd,
    estimatedUsd: costEvidence.estimatedUsd,
    actualUsdConsumed: costEvidence.actualUsdConsumed,
    validatedMergedPullRequestCount: throughputEvidence.validatedMergedPullRequestCount,
    closedIssueCount: throughputEvidence.closedIssueCount,
    promotionEvidenceCount: throughputEvidence.promotionEvidenceCount,
    concurrentLaneActiveCount: throughputEvidence.concurrentLaneActiveCount,
    meanTerminalDurationMinutes: throughputEvidence.meanTerminalDurationMinutes,
    laneMinutesAllocated: throughputEvidence.laneMinutesAllocated,
    totalTerminalPullRequestCount: throughputEvidence.totalTerminalPullRequestCount,
    hostedWaitEscapeCount: throughputEvidence.hostedWaitEscapeCount,
    validatedMergedPullRequestsPerFundedUsd: computeRatio(
      throughputEvidence.validatedMergedPullRequestCount,
      costEvidence.fundedUsd
    ),
    closedIssuesPerFundedUsd: computeRatio(
      throughputEvidence.closedIssueCount,
      costEvidence.fundedUsd
    ),
    promotionEvidencePerFundedUsd: computeRatio(
      throughputEvidence.promotionEvidenceCount,
      costEvidence.fundedUsd
    ),
    laneMinutesAllocatedPerFundedUsd: computeRatio(
      throughputEvidence.laneMinutesAllocated,
      costEvidence.fundedUsd
    ),
    hostedWaitEscapesPerFundedUsd: computeRatio(
      throughputEvidence.hostedWaitEscapeCount,
      costEvidence.fundedUsd
    ),
    heuristicUsdDelta: costEvidence.heuristicUsdDelta,
    heuristicUsdDeltaRatio: costEvidence.heuristicUsdDeltaRatio
  };

  const reasons = [];
  if (blockers.length === 0) {
    if (metrics.fundedUsd === 0) {
      reasons.push('no-funded-spend-observed');
    }
    if (costEvidence.fundingWindow.windowClass === 'calibration') {
      reasons.push('calibration-window');
    }
    if (metrics.estimatedUsd > 0) {
      reasons.push('estimated-spend-present');
    }
    if (costEvidence.fundingWindow.reconciliationStatus !== 'actual-observed') {
      reasons.push('invoice-reconciliation-pending');
    }
    if (
      metrics.fundedUsd > 0
      && metrics.validatedMergedPullRequestCount === 0
      && throughputEvidence.throughputWindow.currentCycleIdleStatus === 'observed'
    ) {
      reasons.push('current-cycle-idle-window');
    } else if (metrics.fundedUsd > 0 && metrics.validatedMergedPullRequestCount === 0) {
      reasons.push('zero-validated-throughput');
    }
  }

  return {
    schema: REPORT_SCHEMA,
    generatedAt: toIso(now),
    repository: normalizeText(repository) || null,
    inputs: {
      costRollupPath: normalizeInputRef(inputPaths.costRollupPath),
      throughputScorecardPath: normalizeInputRef(inputPaths.throughputScorecardPath)
    },
    coverage: {
      implementedMetricCodes: [...IMPLEMENTED_METRIC_CODES],
      projectedMetricCodes: [...PROJECTED_METRIC_CODES],
      deferredMetrics: DEFERRED_METRICS.map((entry) => ({ ...entry }))
    },
    fundingWindow: costEvidence.fundingWindow,
    throughputWindow: throughputEvidence.throughputWindow,
    summary: {
      status: blockers.length > 0 ? 'fail' : reasons.length > 0 ? 'warn' : 'pass',
      recommendation: resolveRecommendation({ blockers, reasons }),
      reasons,
      blockerCount: blockers.length,
      blockers,
      metrics
    }
  };
}

export function runFundedThroughputScorecard({
  repo = null,
  costRollupPath = DEFAULT_COST_ROLLUP_PATH,
  throughputScorecardPath = DEFAULT_THROUGHPUT_SCORECARD_PATH,
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
  const report = buildFundedThroughputScorecard({
    repository,
    costRollup: costRollupInput.payload,
    throughputScorecard: throughputScorecardInput.payload,
    inputPaths: {
      costRollupPath: costRollupInput,
      throughputScorecardPath: throughputScorecardInput
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
  const result = runFundedThroughputScorecard(options);
  console.log(
    `[funded-throughput-scorecard] report: ${result.outputPath} status=${result.report.summary.status} mergedPerUsd=${result.report.summary.metrics.validatedMergedPullRequestsPerFundedUsd ?? 'n/a'}`
  );
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv);
  } catch (error) {
    console.error(`[funded-throughput-scorecard] ${error.message || error}`);
    process.exitCode = 1;
  }
}

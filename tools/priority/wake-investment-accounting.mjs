#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'wake-investment-accounting.json');
export const DEFAULT_WAKE_ADJUDICATION_PATH = path.join('tests', 'results', '_agent', 'issue', 'wake-adjudication.json');
export const DEFAULT_WAKE_WORK_SYNTHESIS_PATH = path.join('tests', 'results', '_agent', 'issue', 'wake-work-synthesis.json');
export const DEFAULT_AVERAGE_ISSUE_COST_SCORECARD_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'capital',
  'average-issue-cost-scorecard.json'
);
export const DEFAULT_COST_ROLLUP_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'capital', 'wake-investment-accounting.json');

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function asOptional(value) {
  const normalized = normalizeText(value);
  return normalized.length > 0 ? normalized : null;
}

function normalizeRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function roundNumber(value, precision = 6) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return Number(parsed.toFixed(precision));
}

function coerceNonNegativeNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function coercePositiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function ensurePolicy(payload, filePath) {
  if (payload?.schema !== 'priority/wake-investment-accounting-policy@v1') {
    throw new Error(`Expected wake investment accounting policy at ${filePath}.`);
  }
  return payload;
}

function ensureWakeAdjudicationReport(payload, filePath) {
  if (payload?.schema !== 'priority/wake-adjudication-report@v1') {
    throw new Error(`Expected wake adjudication report at ${filePath}.`);
  }
  return payload;
}

function ensureWakeWorkSynthesisReport(payload, filePath) {
  if (payload?.schema !== 'priority/wake-work-synthesis-report@v1') {
    throw new Error(`Expected wake work synthesis report at ${filePath}.`);
  }
  return payload;
}

function ensureAverageIssueCostScorecard(payload, filePath) {
  if (payload?.schema !== 'priority/average-issue-cost-scorecard@v1') {
    throw new Error(`Expected average issue cost scorecard at ${filePath}.`);
  }
  return payload;
}

function ensureCostRollup(payload, filePath) {
  if (payload?.schema !== 'priority/agent-cost-rollup@v1') {
    throw new Error(`Expected agent cost rollup at ${filePath}.`);
  }
  return payload;
}

function parseIntegerArg(token, value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${token} expects a positive integer.`);
  }
  return parsed;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    policyPath: DEFAULT_POLICY_PATH,
    wakeAdjudicationPath: DEFAULT_WAKE_ADJUDICATION_PATH,
    wakeWorkSynthesisPath: DEFAULT_WAKE_WORK_SYNTHESIS_PATH,
    averageIssueCostScorecardPath: DEFAULT_AVERAGE_ISSUE_COST_SCORECARD_PATH,
    costRollupPath: DEFAULT_COST_ROLLUP_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    issueNumber: null,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--policy', 'policyPath'],
    ['--wake-adjudication', 'wakeAdjudicationPath'],
    ['--wake-work-synthesis', 'wakeWorkSynthesisPath'],
    ['--average-issue-cost', 'averageIssueCostScorecardPath'],
    ['--cost-rollup', 'costRollupPath'],
    ['--output', 'outputPath']
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--issue-number') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error('Missing value for --issue-number.');
      }
      options.issueNumber = parseIntegerArg(token, next);
      index += 1;
      continue;
    }
    if (stringFlags.has(token)) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      options[stringFlags.get(token)] = next;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  [
    'Usage: node tools/priority/wake-investment-accounting.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>            Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --policy <path>               Accounting policy path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --wake-adjudication <path>    Wake adjudication report path (default: ${DEFAULT_WAKE_ADJUDICATION_PATH}).`,
    `  --wake-work-synthesis <path>  Wake work synthesis report path (default: ${DEFAULT_WAKE_WORK_SYNTHESIS_PATH}).`,
    `  --average-issue-cost <path>   Average issue cost scorecard path (default: ${DEFAULT_AVERAGE_ISSUE_COST_SCORECARD_PATH}).`,
    `  --cost-rollup <path>          Agent cost rollup path (default: ${DEFAULT_COST_ROLLUP_PATH}).`,
    '  --issue-number <number>       Issue number override for observed wake cost lookup.',
    `  --output <path>               Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  -h, --help                    Show help.'
  ].forEach((line) => console.log(line));
}

function safeUniqueNumbers(values) {
  return [...new Set((Array.isArray(values) ? values : []).map((entry) => Number(entry)).filter((entry) => Number.isInteger(entry) && entry > 0))].sort(
    (left, right) => left - right
  );
}

function safeUniqueStrings(values) {
  return [...new Set((Array.isArray(values) ? values : []).map((entry) => normalizeText(entry)).filter(Boolean))].sort((left, right) =>
    left.localeCompare(right)
  );
}

function createBlocker(code, message, inputPath = null) {
  return {
    code,
    message,
    inputPath
  };
}

function determineIssueNumber(issueNumberOverride, averageIssueCostScorecard, costRollup) {
  const explicit = coercePositiveInteger(issueNumberOverride);
  if (explicit != null) {
    return explicit;
  }
  const rollupIssueNumbers = safeUniqueNumbers(costRollup?.summary?.provenance?.issueNumbers);
  if (rollupIssueNumbers.length === 1) {
    return rollupIssueNumbers[0];
  }
  const scorecardIssueNumbers = safeUniqueNumbers((averageIssueCostScorecard?.issues || []).map((entry) => entry?.issueNumber));
  if (scorecardIssueNumbers.length === 1) {
    return scorecardIssueNumbers[0];
  }
  return null;
}

function determineObservedIssueCost(issueNumber, averageIssueCostScorecard) {
  if (issueNumber == null) {
    return {
      issueNumber: null,
      stateBucket: null,
      totalUsd: null,
      operatorLaborUsd: null,
      operatorLaborMissingTurnCount: null,
      blendedTotalUsd: null,
      exactUsd: null,
      estimatedUsd: null,
      turnCount: null,
      firstTurnAt: null,
      lastTurnAt: null,
      fundingWindowIds: [],
      exactnessState: 'unknown'
    };
  }

  const issueEntry = (averageIssueCostScorecard?.issues || []).find((entry) => Number(entry?.issueNumber) === issueNumber);
  if (!issueEntry) {
    return {
      issueNumber,
      stateBucket: null,
      totalUsd: null,
      operatorLaborUsd: null,
      operatorLaborMissingTurnCount: null,
      blendedTotalUsd: null,
      exactUsd: null,
      estimatedUsd: null,
      turnCount: null,
      firstTurnAt: null,
      lastTurnAt: null,
      fundingWindowIds: [],
      exactnessState: 'unknown'
    };
  }

  const exactUsd = coerceNonNegativeNumber(issueEntry.exactUsd);
  const estimatedUsd = coerceNonNegativeNumber(issueEntry.estimatedUsd);
  let exactnessState = 'unknown';
  if ((exactUsd ?? 0) > 0 && (estimatedUsd ?? 0) > 0) {
    exactnessState = 'mixed';
  } else if ((exactUsd ?? 0) > 0) {
    exactnessState = 'exact';
  } else if ((estimatedUsd ?? 0) > 0) {
    exactnessState = 'estimated';
  }

  return {
    issueNumber,
    stateBucket: asOptional(issueEntry.stateBucket),
    totalUsd: coerceNonNegativeNumber(issueEntry.totalUsd),
    operatorLaborUsd: coerceNonNegativeNumber(issueEntry.operatorLaborUsd),
    operatorLaborMissingTurnCount: Number.isInteger(issueEntry.operatorLaborMissingTurnCount) ? issueEntry.operatorLaborMissingTurnCount : null,
    blendedTotalUsd: coerceNonNegativeNumber(issueEntry.blendedTotalUsd),
    exactUsd,
    estimatedUsd,
    turnCount: Number.isInteger(issueEntry.turnCount) ? issueEntry.turnCount : null,
    firstTurnAt: asOptional(issueEntry.firstTurnAt),
    lastTurnAt: asOptional(issueEntry.lastTurnAt),
    fundingWindowIds: safeUniqueStrings(issueEntry.windowIds),
    exactnessState
  };
}

function selectBenchmark(policy, averageIssueCostScorecard, observedIssueCost) {
  const metrics = averageIssueCostScorecard?.summary?.metrics ?? {};
  for (const metricCode of policy.benchmarkMetricPreference || []) {
    const value = coerceNonNegativeNumber(metrics?.[metricCode]);
    if (value != null && value > 0) {
      return {
        selectedMetricCode: metricCode,
        benchmarkSourceKind: 'scorecard-metric',
        selectedBenchmarkUsd: value
      };
    }
  }
  if (policy.allowObservedIssueFallback === true) {
    const fallbackValue =
      coerceNonNegativeNumber(observedIssueCost?.blendedTotalUsd) ??
      coerceNonNegativeNumber(observedIssueCost?.totalUsd);
    if (fallbackValue != null && fallbackValue > 0) {
      return {
        selectedMetricCode: 'observedIssueUsdFallback',
        benchmarkSourceKind: 'observed-issue-fallback',
        selectedBenchmarkUsd: fallbackValue
      };
    }
  }
  return {
    selectedMetricCode: null,
    benchmarkSourceKind: 'missing',
    selectedBenchmarkUsd: null
  };
}

function determinePaybackEligibility(policy, wakeAdjudication, wakeWorkSynthesis) {
  const decisionPolicy = policy?.decisionAccounting?.[wakeWorkSynthesis?.summary?.decision];
  if (!decisionPolicy || decisionPolicy.avoidedCostProxy !== 'issue-benchmark') {
    return [];
  }

  const triggerCodes = [];
  const classification = normalizeText(wakeAdjudication?.summary?.classification);
  const eligibleClassifications = new Set(policy?.paybackTriggers?.classificationEligibility || []);
  if (eligibleClassifications.has(classification)) {
    triggerCodes.push('classification-eligible');
  }
  const suppressed =
    wakeAdjudication?.summary?.suppressIssueInjection === true ||
    wakeAdjudication?.summary?.suppressDownstreamIssueInjection === true ||
    wakeAdjudication?.summary?.suppressTemplateIssueInjection === true;
  if (policy?.paybackTriggers?.allowSuppressionTrigger === true && suppressed) {
    triggerCodes.push('suppression-trigger');
  }
  const governingRepository = normalizeText(wakeWorkSynthesis?.roles?.governingRole?.repository);
  const ownerRepository = normalizeText(wakeWorkSynthesis?.summary?.recommendedOwnerRepository);
  if (
    policy?.paybackTriggers?.allowOwnerRepositoryMismatchTrigger === true &&
    governingRepository &&
    ownerRepository &&
    governingRepository !== ownerRepository
  ) {
    triggerCodes.push('owner-repository-mismatch');
  }

  return triggerCodes.sort((left, right) => left.localeCompare(right));
}

function determineConfidence(benchmark, observedIssueCost) {
  const hasBenchmark = coerceNonNegativeNumber(benchmark?.selectedBenchmarkUsd) != null;
  const hasObserved =
    coerceNonNegativeNumber(observedIssueCost?.blendedTotalUsd) != null ||
    coerceNonNegativeNumber(observedIssueCost?.totalUsd) != null;
  if (!hasBenchmark && !hasObserved) {
    return 'insufficient';
  }
  if (hasBenchmark && hasObserved && observedIssueCost.exactnessState === 'exact') {
    return 'high';
  }
  if (hasBenchmark && hasObserved) {
    return 'medium';
  }
  return 'low';
}

function determinePaybackStatus(netPaybackUsd, avoidedIssueBenchmarkUsd) {
  if (avoidedIssueBenchmarkUsd == null) {
    return 'unresolved';
  }
  if (netPaybackUsd == null) {
    return 'unresolved';
  }
  if (netPaybackUsd > 0) {
    return 'positive';
  }
  if (netPaybackUsd < 0) {
    return 'negative';
  }
  return 'neutral';
}

function determineRecommendation(blockers, reasons, wakeWorkSynthesis, benchmark, observedIssueCost, paybackStatus) {
  if (blockers.length > 0) {
    return 'repair-input-receipts';
  }
  if (reasons.includes('benchmark-fallback-to-observed-issue')) {
    return 'stabilize-wake-benchmark';
  }
  if (reasons.includes('issue-cost-not-observed')) {
    return 'continue-observing-wake-cost';
  }
  if (reasons.includes('estimated-issue-cost-present')) {
    return 'continue-estimated-telemetry';
  }
  if (paybackStatus === 'positive') {
    return 'continue-governance-investment';
  }
  if (wakeWorkSynthesis?.summary?.decision === 'template-work') {
    return 'track-resolution-cost';
  }
  if (benchmark?.benchmarkSourceKind === 'missing' && observedIssueCost?.issueNumber == null) {
    return 'seed-wake-accounting-inputs';
  }
  return 'continue-wake-accounting';
}

export function buildWakeInvestmentAccounting({
  repository,
  policy,
  wakeAdjudication,
  wakeWorkSynthesis,
  averageIssueCostScorecard,
  costRollup,
  inputPaths,
  issueNumber = null,
  now = new Date()
}) {
  const blockers = [];
  const reasons = [];

  const observedIssueNumber = determineIssueNumber(issueNumber, averageIssueCostScorecard, costRollup);
  const observedIssueCost = determineObservedIssueCost(observedIssueNumber, averageIssueCostScorecard);
  if (observedIssueNumber == null) {
    reasons.push('issue-number-not-inferred');
  }
  if (observedIssueCost.totalUsd == null) {
    reasons.push('issue-cost-not-observed');
  }
  if (observedIssueCost.exactnessState === 'estimated' || observedIssueCost.exactnessState === 'mixed') {
    reasons.push('estimated-issue-cost-present');
  }

  const benchmarkSelection = selectBenchmark(policy, averageIssueCostScorecard, observedIssueCost);
  if (benchmarkSelection.benchmarkSourceKind === 'observed-issue-fallback') {
    reasons.push('benchmark-fallback-to-observed-issue');
  }
  if (benchmarkSelection.selectedBenchmarkUsd == null) {
    blockers.push(
      createBlocker(
        'benchmark-unavailable',
        'Wake investment accounting needs either a benchmark issue-cost metric or an observed issue-cost fallback.',
        inputPaths.averageIssueCostScorecardPath
      )
    );
  }

  const paybackTriggerCodes = determinePaybackEligibility(policy, wakeAdjudication, wakeWorkSynthesis);
  const observedWakeIssueUsd =
    coerceNonNegativeNumber(observedIssueCost.blendedTotalUsd) ??
    coerceNonNegativeNumber(observedIssueCost.totalUsd);
  const observedCostBasis =
    coerceNonNegativeNumber(observedIssueCost.blendedTotalUsd) != null ? 'blended' : 'token-only';
  const benchmarkIssueUsd = coerceNonNegativeNumber(benchmarkSelection.selectedBenchmarkUsd);
  const decisionPolicy = policy.decisionAccounting[wakeWorkSynthesis.summary.decision];
  const avoidedIssueBenchmarkUsd =
    decisionPolicy?.avoidedCostProxy === 'issue-benchmark' && paybackTriggerCodes.length > 0 ? benchmarkIssueUsd : null;
  const netPaybackUsd =
    avoidedIssueBenchmarkUsd != null && observedWakeIssueUsd != null
      ? roundNumber(avoidedIssueBenchmarkUsd - observedWakeIssueUsd)
      : null;
  const observedToBenchmarkRatio =
    observedWakeIssueUsd != null && benchmarkIssueUsd != null && benchmarkIssueUsd > 0
      ? roundNumber(observedWakeIssueUsd / benchmarkIssueUsd)
      : null;

  const uniqueReasons = safeUniqueStrings(reasons);
  const status = blockers.length > 0 ? 'fail' : uniqueReasons.length > 0 ? 'warn' : 'pass';
  const accountingConfidence = determineConfidence(benchmarkSelection, observedIssueCost);
  const paybackStatus = determinePaybackStatus(netPaybackUsd, avoidedIssueBenchmarkUsd);
  const recommendation = determineRecommendation(
    blockers,
    uniqueReasons,
    wakeWorkSynthesis,
    benchmarkSelection,
    observedIssueCost,
    paybackStatus
  );

  return {
    schema: 'priority/wake-investment-accounting-report@v1',
    generatedAt: new Date(now).toISOString(),
    repository,
    policy: {
      path: inputPaths.policyPath,
      compareRepository: policy.compareRepository,
      benchmarkMetricPreference: policy.benchmarkMetricPreference,
      allowObservedIssueFallback: policy.allowObservedIssueFallback === true
    },
    inputs: {
      wakeAdjudicationReportPath: inputPaths.wakeAdjudicationPath,
      wakeWorkSynthesisReportPath: inputPaths.wakeWorkSynthesisPath,
      averageIssueCostScorecardPath: inputPaths.averageIssueCostScorecardPath,
      costRollupPath: inputPaths.costRollupPath
    },
    wake: {
      classification: wakeAdjudication.summary.classification,
      decision: wakeWorkSynthesis.summary.decision,
      workKind: wakeWorkSynthesis.summary.workKind,
      status: wakeWorkSynthesis.summary.status,
      reason: wakeWorkSynthesis.summary.reason,
      recommendedOwnerRepository: wakeWorkSynthesis.summary.recommendedOwnerRepository,
      suppressIssueInjection: wakeAdjudication.summary.suppressIssueInjection === true,
      suppressDownstreamIssueInjection: wakeAdjudication.summary.suppressDownstreamIssueInjection === true,
      suppressTemplateIssueInjection: wakeAdjudication.summary.suppressTemplateIssueInjection === true
    },
    billingWindow: {
      invoiceTurnId: asOptional(costRollup?.billingWindow?.invoiceTurnId),
      fundingPurpose: asOptional(costRollup?.billingWindow?.fundingPurpose),
      activationState: asOptional(costRollup?.billingWindow?.activationState),
      reconciliationStatus: asOptional(costRollup?.billingWindow?.reconciliationStatus)
    },
    costBenchmark: {
      selectedMetricCode: benchmarkSelection.selectedMetricCode,
      benchmarkSourceKind: benchmarkSelection.benchmarkSourceKind,
      selectedBenchmarkUsd: benchmarkIssueUsd,
      rollingAverageUsdPerIssue: coerceNonNegativeNumber(averageIssueCostScorecard?.summary?.metrics?.rollingAverageUsdPerIssue),
      rollingAverageBlendedUsdPerIssue: coerceNonNegativeNumber(averageIssueCostScorecard?.summary?.metrics?.rollingAverageBlendedUsdPerIssue),
      currentActiveWindowAverageUsdPerIssue: coerceNonNegativeNumber(
        averageIssueCostScorecard?.summary?.metrics?.currentActiveWindowAverageUsdPerIssue
      ),
      currentActiveWindowAverageBlendedUsdPerIssue: coerceNonNegativeNumber(
        averageIssueCostScorecard?.summary?.metrics?.currentActiveWindowAverageBlendedUsdPerIssue
      ),
      latestTrailingOperationalWindowAverageUsdPerIssue: coerceNonNegativeNumber(
        averageIssueCostScorecard?.summary?.metrics?.latestTrailingOperationalWindowAverageUsdPerIssue
      ),
      latestTrailingOperationalWindowAverageBlendedUsdPerIssue: coerceNonNegativeNumber(
        averageIssueCostScorecard?.summary?.metrics?.latestTrailingOperationalWindowAverageBlendedUsdPerIssue
      )
    },
    observedIssueCost,
    summary: {
      accountingBucket: decisionPolicy.accountingBucket,
      status,
      recommendation,
      reasons: uniqueReasons,
      blockerCount: blockers.length,
      blockers,
      accountingConfidence,
      paybackStatus,
      paybackTriggerCodes,
      metrics: {
        benchmarkIssueUsd,
        observedWakeIssueUsd,
        observedCostBasis,
        observedToBenchmarkRatio,
        avoidedIssueBenchmarkUsd,
        netPaybackUsd,
        observedOperatorLaborUsd: coerceNonNegativeNumber(observedIssueCost.operatorLaborUsd),
        observedOperatorLaborMissingTurnCount:
          Number.isInteger(observedIssueCost.operatorLaborMissingTurnCount) ? observedIssueCost.operatorLaborMissingTurnCount : null,
        exactObservedUsd: coerceNonNegativeNumber(observedIssueCost.exactUsd),
        estimatedObservedUsd: coerceNonNegativeNumber(observedIssueCost.estimatedUsd),
        issueTurnCount: Number.isInteger(observedIssueCost.turnCount) ? observedIssueCost.turnCount : null
      }
    }
  };
}

export async function runWakeInvestmentAccounting(options = {}) {
  const repoRoot = path.resolve(options.repoRoot ?? DEFAULT_REPO_ROOT);
  const resolvedPolicyPath = path.resolve(repoRoot, options.policyPath ?? DEFAULT_POLICY_PATH);
  const resolvedWakeAdjudicationPath = path.resolve(repoRoot, options.wakeAdjudicationPath ?? DEFAULT_WAKE_ADJUDICATION_PATH);
  const resolvedWakeWorkSynthesisPath = path.resolve(repoRoot, options.wakeWorkSynthesisPath ?? DEFAULT_WAKE_WORK_SYNTHESIS_PATH);
  const resolvedAverageIssueCostScorecardPath = path.resolve(
    repoRoot,
    options.averageIssueCostScorecardPath ?? DEFAULT_AVERAGE_ISSUE_COST_SCORECARD_PATH
  );
  const resolvedCostRollupPath = path.resolve(repoRoot, options.costRollupPath ?? DEFAULT_COST_ROLLUP_PATH);

  const policy = ensurePolicy(readJson(resolvedPolicyPath), resolvedPolicyPath);
  const wakeAdjudication = ensureWakeAdjudicationReport(readJson(resolvedWakeAdjudicationPath), resolvedWakeAdjudicationPath);
  const wakeWorkSynthesis = ensureWakeWorkSynthesisReport(readJson(resolvedWakeWorkSynthesisPath), resolvedWakeWorkSynthesisPath);
  const averageIssueCostScorecard = ensureAverageIssueCostScorecard(
    readJson(resolvedAverageIssueCostScorecardPath),
    resolvedAverageIssueCostScorecardPath
  );
  const costRollup = ensureCostRollup(readJson(resolvedCostRollupPath), resolvedCostRollupPath);

  const repository =
    asOptional(options.repository) ??
    asOptional(costRollup.repository) ??
    asOptional(averageIssueCostScorecard.repository) ??
    asOptional(wakeWorkSynthesis.repository) ??
    policy.compareRepository;

  const report = buildWakeInvestmentAccounting({
    repository,
    policy,
    wakeAdjudication,
    wakeWorkSynthesis,
    averageIssueCostScorecard,
    costRollup,
    inputPaths: {
      policyPath: normalizeRelative(repoRoot, resolvedPolicyPath),
      wakeAdjudicationPath: normalizeRelative(repoRoot, resolvedWakeAdjudicationPath),
      wakeWorkSynthesisPath: normalizeRelative(repoRoot, resolvedWakeWorkSynthesisPath),
      averageIssueCostScorecardPath: normalizeRelative(repoRoot, resolvedAverageIssueCostScorecardPath),
      costRollupPath: normalizeRelative(repoRoot, resolvedCostRollupPath)
    },
    issueNumber: options.issueNumber,
    now: options.now ?? new Date()
  });

  const outputPath = path.resolve(repoRoot, options.outputPath ?? DEFAULT_OUTPUT_PATH);
  writeJson(outputPath, report);
  return { outputPath, report };
}

async function main() {
  const options = parseArgs(process.argv);
  if (options.help) {
    printHelp();
    return;
  }
  const result = await runWakeInvestmentAccounting(options);
  console.log(
    `[wake-investment-accounting] wrote ${result.outputPath} (${result.report.summary.accountingBucket}, status=${result.report.summary.status})`
  );
}

const isDirectRun = (() => {
  try {
    return import.meta.url === new URL(`file://${process.argv[1].replace(/\\/g, '/')}`).href;
  } catch {
    return false;
  }
})();

if (isDirectRun) {
  try {
    await main();
  } catch (error) {
    console.error(`[wake-investment-accounting] ${error.message}`);
    process.exitCode = 1;
  }
}

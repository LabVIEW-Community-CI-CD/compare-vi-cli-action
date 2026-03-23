#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'autonomous-governor-summary.json'
);
export const DEFAULT_QUEUE_EMPTY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'no-standing-priority.json'
);
export const DEFAULT_CONTINUITY_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'continuity-summary.json'
);
export const DEFAULT_MONITORING_MODE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'monitoring-mode.json'
);
export const DEFAULT_WAKE_LIFECYCLE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'wake-lifecycle.json'
);
export const DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'capital',
  'wake-investment-accounting.json'
);
export const DEFAULT_DELIVERY_RUNTIME_STATE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'delivery-agent-state.json'
);
export const DEFAULT_RELEASE_SIGNING_READINESS_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'release-signing-readiness.json'
);

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeOptionalObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function normalizeUpper(value) {
  return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

function sanitizeSegment(value) {
  return String(value || '')
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'runtime';
}

function parsePullRequestNumber(value) {
  const match = String(value || '').match(/\/pull\/(\d+)(?:\/|$)/i);
  if (!match) {
    return null;
  }
  const parsed = Number(match[1]);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function readOptionalJson(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function resolveMergeSyncSummaryCandidatePaths(repoRoot, repository, prNumber) {
  if (!Number.isInteger(prNumber) || prNumber <= 0) {
    return [];
  }

  const issueDir = path.join(repoRoot, 'tests', 'results', '_agent', 'issue');
  const directCandidates = [
    path.join(repoRoot, 'tests', 'results', '_agent', 'queue', `merge-sync-${prNumber}.json`),
    path.join(issueDir, `${sanitizeSegment(repository)}-pr-${prNumber}-queue-admission.json`)
  ];

  const discovered = [];
  if (fs.existsSync(issueDir)) {
    for (const entry of fs.readdirSync(issueDir, { withFileTypes: true })) {
      if (!entry.isFile()) {
        continue;
      }
      if (
        entry.name.includes(`pr-${prNumber}-queue-admission.json`) ||
        entry.name.includes(`merge-sync-${prNumber}`)
      ) {
        discovered.push(path.join(issueDir, entry.name));
      }
    }
  }

  return Array.from(new Set([...directCandidates, ...discovered]));
}

function resolveQueueRefreshReceiptCandidatePaths(repoRoot, prNumber) {
  if (!Number.isInteger(prNumber) || prNumber <= 0) {
    return [];
  }
  return [path.join(repoRoot, 'tests', 'results', '_agent', 'queue', `queue-refresh-${prNumber}.json`)];
}

function resolveLatestMergeSyncSummaryPath(repoRoot, repository, prNumber) {
  const candidates = resolveMergeSyncSummaryCandidatePaths(repoRoot, repository, prNumber)
    .filter((candidate) => fs.existsSync(candidate))
    .map((candidate) => ({
      path: candidate,
      mtimeMs: fs.statSync(candidate).mtimeMs
    }))
    .sort((left, right) => right.mtimeMs - left.mtimeMs);

  return candidates[0]?.path || null;
}

function resolveLatestQueueRefreshReceiptPath(repoRoot, prNumber) {
  const candidates = resolveQueueRefreshReceiptCandidatePaths(repoRoot, prNumber)
    .filter((candidate) => fs.existsSync(candidate))
    .map((candidate) => ({
      path: candidate,
      mtimeMs: fs.statSync(candidate).mtimeMs
    }))
    .sort((left, right) => right.mtimeMs - left.mtimeMs);

  return candidates[0]?.path || null;
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function toRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
}

function ensureSchema(payload, filePath, schema) {
  if (payload?.schema !== schema) {
    throw new Error(`Expected ${schema} at ${filePath}.`);
  }
  return payload;
}

function parseBoolean(value) {
  return value === true;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    queueEmptyReportPath: DEFAULT_QUEUE_EMPTY_REPORT_PATH,
    continuitySummaryPath: DEFAULT_CONTINUITY_SUMMARY_PATH,
    monitoringModePath: DEFAULT_MONITORING_MODE_PATH,
    wakeLifecyclePath: DEFAULT_WAKE_LIFECYCLE_PATH,
    wakeInvestmentAccountingPath: DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH,
    deliveryRuntimeStatePath: DEFAULT_DELIVERY_RUNTIME_STATE_PATH,
    releaseSigningReadinessPath: DEFAULT_RELEASE_SIGNING_READINESS_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--queue-empty-report', 'queueEmptyReportPath'],
    ['--continuity-summary', 'continuitySummaryPath'],
    ['--monitoring-mode', 'monitoringModePath'],
    ['--wake-lifecycle', 'wakeLifecyclePath'],
    ['--wake-investment-accounting', 'wakeInvestmentAccountingPath'],
    ['--delivery-runtime-state', 'deliveryRuntimeStatePath'],
    ['--release-signing-readiness', 'releaseSigningReadinessPath'],
    ['--output', 'outputPath']
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
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
    'Usage: node tools/priority/autonomous-governor-summary.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>                 Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --queue-empty-report <path>       Queue-empty report path (default: ${DEFAULT_QUEUE_EMPTY_REPORT_PATH}).`,
    `  --continuity-summary <path>       Continuity summary path (default: ${DEFAULT_CONTINUITY_SUMMARY_PATH}).`,
    `  --monitoring-mode <path>          Monitoring mode path (default: ${DEFAULT_MONITORING_MODE_PATH}).`,
    `  --wake-lifecycle <path>           Wake lifecycle path (default: ${DEFAULT_WAKE_LIFECYCLE_PATH}).`,
    `  --wake-investment-accounting <path> Wake investment accounting path (default: ${DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH}).`,
    `  --delivery-runtime-state <path>   Delivery runtime state path (default: ${DEFAULT_DELIVERY_RUNTIME_STATE_PATH}).`,
    `  --release-signing-readiness <path> Release signing readiness path (default: ${DEFAULT_RELEASE_SIGNING_READINESS_PATH}).`,
    `  --output <path>                   Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  -h, --help                        Show help.'
  ].forEach((line) => console.log(line));
}

function deriveQueueState(queueEmptyReport, monitoringMode) {
  if (queueEmptyReport?.schema === 'standing-priority/no-standing@v1') {
    return {
      status: asOptional(queueEmptyReport.reason) || 'queue-empty',
      reason: asOptional(queueEmptyReport.reason),
      openIssueCount: Number.isInteger(queueEmptyReport.openIssueCount) ? queueEmptyReport.openIssueCount : null,
      ready: queueEmptyReport.reason === 'queue-empty'
    };
  }
  return {
    status: asOptional(monitoringMode?.compare?.queueState?.status) || 'unknown',
    reason: asOptional(monitoringMode?.compare?.queueState?.detail),
    openIssueCount: null,
    ready: parseBoolean(monitoringMode?.compare?.queueState?.ready)
  };
}

function deriveContinuity(continuitySummary, monitoringMode) {
  return {
    status: asOptional(continuitySummary?.status) || asOptional(monitoringMode?.compare?.continuity?.status),
    turnBoundary: asOptional(continuitySummary?.continuity?.turnBoundary?.status),
    supervisionState: asOptional(continuitySummary?.continuity?.turnBoundary?.supervisionState),
    operatorPromptRequiredToResume: continuitySummary?.continuity?.turnBoundary?.operatorPromptRequiredToResume === true
  };
}

function deriveWake(wakeLifecycle) {
  if (wakeLifecycle?.schema !== 'priority/wake-lifecycle-report@v1') {
    return {
      terminalState: null,
      currentStage: null,
      classification: null,
      decision: null,
      monitoringStatus: null,
      authoritativeTier: null,
      blockedLowerTierEvidence: false,
      replayMatched: false,
      replayAuthorityCompatible: null,
      issueNumber: null,
      issueUrl: null,
      recommendedOwnerRepository: null
    };
  }
  return {
    terminalState: asOptional(wakeLifecycle?.summary?.terminalState),
    currentStage: asOptional(wakeLifecycle?.summary?.currentStage),
    classification: asOptional(wakeLifecycle?.summary?.wakeClassification),
    decision: asOptional(wakeLifecycle?.summary?.decision),
    monitoringStatus: asOptional(wakeLifecycle?.summary?.monitoringStatus),
    authoritativeTier: asOptional(wakeLifecycle?.summary?.authoritativeTier),
    blockedLowerTierEvidence: wakeLifecycle?.summary?.blockedLowerTierEvidence === true,
    replayMatched: wakeLifecycle?.summary?.replayMatched === true,
    replayAuthorityCompatible:
      typeof wakeLifecycle?.summary?.replayAuthorityCompatible === 'boolean'
        ? wakeLifecycle.summary.replayAuthorityCompatible
        : null,
    issueNumber: Number.isInteger(wakeLifecycle?.summary?.issueNumber) ? wakeLifecycle.summary.issueNumber : null,
    issueUrl: asOptional(wakeLifecycle?.summary?.issueUrl),
    recommendedOwnerRepository: asOptional(wakeLifecycle?.wake?.recommendedOwnerRepository)
  };
}

function deriveFunding(wakeInvestmentAccounting) {
  return {
    accountingBucket: asOptional(wakeInvestmentAccounting?.summary?.accountingBucket),
    status: asOptional(wakeInvestmentAccounting?.summary?.status),
    paybackStatus: asOptional(wakeInvestmentAccounting?.summary?.paybackStatus),
    recommendation: asOptional(wakeInvestmentAccounting?.summary?.recommendation),
    invoiceTurnId: asOptional(wakeInvestmentAccounting?.billingWindow?.invoiceTurnId),
    fundingPurpose: asOptional(wakeInvestmentAccounting?.billingWindow?.fundingPurpose),
    activationState: asOptional(wakeInvestmentAccounting?.billingWindow?.activationState),
    benchmarkIssueUsd:
      typeof wakeInvestmentAccounting?.summary?.metrics?.benchmarkIssueUsd === 'number'
        ? wakeInvestmentAccounting.summary.metrics.benchmarkIssueUsd
        : null,
    observedWakeIssueUsd:
      typeof wakeInvestmentAccounting?.summary?.metrics?.observedWakeIssueUsd === 'number'
        ? wakeInvestmentAccounting.summary.metrics.observedWakeIssueUsd
        : null,
    netPaybackUsd:
      typeof wakeInvestmentAccounting?.summary?.metrics?.netPaybackUsd === 'number'
        ? wakeInvestmentAccounting.summary.metrics.netPaybackUsd
        : null
  };
}

function deriveReleaseSigningReadiness(releaseSigningReadinessReport) {
  if (releaseSigningReadinessReport?.schema !== 'priority/release-signing-readiness-report@v1') {
    return {
      status: 'missing',
      codePathState: null,
      signingCapabilityState: null,
      signingAuthorityState: null,
      releaseConductorApplyState: null,
      publicationState: null,
      publishedBundleState: null,
      publishedBundleReleaseTag: null,
      publishedBundleAuthoritativeConsumerPin: null,
      externalBlocker: null,
      blockerCount: 0
    };
  }

  return {
    status: asOptional(releaseSigningReadinessReport?.summary?.status) || 'missing',
    codePathState: asOptional(releaseSigningReadinessReport?.summary?.codePathState),
    signingCapabilityState: asOptional(releaseSigningReadinessReport?.summary?.signingCapabilityState),
    signingAuthorityState: asOptional(releaseSigningReadinessReport?.summary?.signingAuthorityState),
    releaseConductorApplyState: asOptional(releaseSigningReadinessReport?.summary?.releaseConductorApplyState),
    publicationState: asOptional(releaseSigningReadinessReport?.summary?.publicationState),
    publishedBundleState: asOptional(releaseSigningReadinessReport?.summary?.publishedBundleState),
    publishedBundleReleaseTag: asOptional(releaseSigningReadinessReport?.summary?.publishedBundleReleaseTag),
    publishedBundleAuthoritativeConsumerPin: asOptional(
      releaseSigningReadinessReport?.summary?.publishedBundleAuthoritativeConsumerPin
    ),
    externalBlocker: asOptional(releaseSigningReadinessReport?.summary?.externalBlocker),
    blockerCount: Number.isInteger(releaseSigningReadinessReport?.summary?.blockerCount)
      ? releaseSigningReadinessReport.summary.blockerCount
      : 0
  };
}

function deriveDeliveryRuntime(deliveryRuntimeState) {
  const activeLane = deliveryRuntimeState?.activeLane || {};
  const prUrl = asOptional(activeLane?.prUrl);
  const laneLifecycle = asOptional(activeLane?.laneLifecycle) || asOptional(deliveryRuntimeState?.laneLifecycle);
  const blockerClass = asOptional(activeLane?.blockerClass);
  const outcome = asOptional(activeLane?.outcome);
  const queueAuthorityRefresh =
    normalizeOptionalObject(activeLane?.queueAuthorityRefresh) ??
    normalizeOptionalObject(deliveryRuntimeState?.queueAuthorityRefresh);

  let status = 'none';
  if (prUrl) {
    if (laneLifecycle === 'waiting-ci') {
      status = 'checks-pending';
    } else if (laneLifecycle === 'ready-merge') {
      status = 'merge-queue-progress';
    } else if (blockerClass === 'merge' || outcome === 'merge-blocked') {
      status = 'merge-blocked';
    } else {
      status = 'pr-active';
    }
  }

  return {
    status,
    runtimeStatus: asOptional(deliveryRuntimeState?.status),
    laneLifecycle,
    actionType: asOptional(activeLane?.actionType),
    outcome,
    blockerClass,
    nextWakeCondition: asOptional(activeLane?.nextWakeCondition),
    queueAuthorityRefresh: {
      attempted: queueAuthorityRefresh?.attempted === true,
      status: asOptional(queueAuthorityRefresh?.status),
      reason: asOptional(queueAuthorityRefresh?.reason),
      summaryPath: asOptional(queueAuthorityRefresh?.summaryPath),
      mergeSummaryPath: asOptional(queueAuthorityRefresh?.mergeSummaryPath),
      receiptGeneratedAt: asOptional(queueAuthorityRefresh?.receiptGeneratedAt),
      receiptStatus: asOptional(queueAuthorityRefresh?.receiptStatus),
      receiptReason: asOptional(queueAuthorityRefresh?.receiptReason),
      evidenceFreshness: asOptional(queueAuthorityRefresh?.evidenceFreshness),
      nextWakeCondition: asOptional(queueAuthorityRefresh?.nextWakeCondition),
      mergeStateStatus: asOptional(queueAuthorityRefresh?.mergeStateStatus),
      isInMergeQueue:
        typeof queueAuthorityRefresh?.isInMergeQueue === 'boolean' ? queueAuthorityRefresh.isInMergeQueue : null,
      autoMergeEnabled:
        typeof queueAuthorityRefresh?.autoMergeEnabled === 'boolean' ? queueAuthorityRefresh.autoMergeEnabled : null,
      mergedAt: asOptional(queueAuthorityRefresh?.mergedAt)
    },
    prUrl,
    issueNumber: Number.isInteger(activeLane?.issue) ? activeLane.issue : null,
    reason: asOptional(activeLane?.reason)
  };
}

function deriveQueueAuthority({ repoRoot, repository, deliveryRuntime, readOptionalJsonFn }) {
  const prNumber = parsePullRequestNumber(deliveryRuntime.prUrl);
  const queueRefreshReceiptPath = resolveLatestQueueRefreshReceiptPath(repoRoot, prNumber);
  const queueRefreshReceipt = queueRefreshReceiptPath ? readOptionalJsonFn(queueRefreshReceiptPath) : null;
  if (queueRefreshReceipt?.schema && queueRefreshReceipt.schema !== 'priority/queue-refresh-receipt@v1') {
    throw new Error(`Expected priority/queue-refresh-receipt@v1 at ${queueRefreshReceiptPath}.`);
  }
  const mergeSyncSummaryPath = resolveLatestMergeSyncSummaryPath(repoRoot, repository, prNumber);
  const mergeSyncSummary = mergeSyncSummaryPath ? readOptionalJsonFn(mergeSyncSummaryPath) : null;
  if (mergeSyncSummary?.schema && mergeSyncSummary.schema !== 'priority/sync-merge@v1') {
    throw new Error(`Expected priority/sync-merge@v1 at ${mergeSyncSummaryPath}.`);
  }

  let status = deliveryRuntime.status;
  let source = deliveryRuntime.status === 'none' ? 'none' : 'delivery-runtime';
  let nextWakeCondition = deliveryRuntime.nextWakeCondition;
  let promotionStatus = null;
  let mergeStateStatus = null;
  let isInMergeQueue = false;
  let autoMergeEnabled = false;
  let summaryPath = null;

  if (queueRefreshReceipt) {
    promotionStatus = asOptional(queueRefreshReceipt?.requeue?.promotionStatus);
    mergeStateStatus = asOptional(queueRefreshReceipt?.initial?.mergeStateStatus);
    isInMergeQueue = queueRefreshReceipt?.initial?.isInMergeQueue === true;
    autoMergeEnabled = queueRefreshReceipt?.initial?.autoMergeEnabled === true;
    summaryPath = queueRefreshReceiptPath;

    if (asOptional(queueRefreshReceipt?.initial?.mergedAt)) {
      status = 'queue-settled';
      nextWakeCondition = 'queue-settled';
      source = 'queue-refresh-summary';
    } else if (isInMergeQueue) {
      status = 'merge-queue-progress';
      nextWakeCondition = 'merge-queue-progress';
      source = 'queue-refresh-summary';
    } else if (autoMergeEnabled) {
      status = 'checks-pending';
      nextWakeCondition = 'checks-green';
      source = 'queue-refresh-summary';
    } else if (asOptional(queueRefreshReceipt?.summary?.reason) === 'not-in-merge-queue') {
      status = 'checks-pending';
      nextWakeCondition = 'checks-green';
      source = 'queue-refresh-summary';
    }
  }

  if (mergeSyncSummary) {
    const mergeSyncPromotionStatus = asOptional(mergeSyncSummary?.promotion?.status);
    const mergeSyncMergeStateStatus =
      asOptional(mergeSyncSummary?.promotion?.final?.mergeStateStatus) ||
      asOptional(mergeSyncSummary?.prState?.mergeStateStatus);
    const mergeSyncIsInQueue = mergeSyncSummary?.promotion?.final?.isInMergeQueue === true;
    const mergeSyncAutoMergeEnabled = mergeSyncSummary?.promotion?.final?.autoMergeEnabled === true;

    if (source !== 'queue-refresh-summary') {
      promotionStatus = mergeSyncPromotionStatus;
      mergeStateStatus = mergeSyncMergeStateStatus;
      isInMergeQueue = mergeSyncIsInQueue;
      autoMergeEnabled = mergeSyncAutoMergeEnabled;
      summaryPath = mergeSyncSummaryPath;

      if (
        ['merged', 'already-merged'].includes(mergeSyncPromotionStatus) ||
        normalizeUpper(mergeSyncSummary?.promotion?.final?.state) === 'MERGED'
      ) {
        status = 'queue-settled';
        nextWakeCondition = 'queue-settled';
        source = 'merge-sync-summary';
      } else if (mergeSyncIsInQueue || ['queued', 'already-queued'].includes(mergeSyncPromotionStatus)) {
        status = 'merge-queue-progress';
        nextWakeCondition = 'merge-queue-progress';
        source = 'merge-sync-summary';
      } else if (
        mergeSyncAutoMergeEnabled ||
        ['auto-merge-enabled', 'already-auto-merge-enabled'].includes(mergeSyncPromotionStatus)
      ) {
        status = 'checks-pending';
        nextWakeCondition = 'checks-green';
        source = 'merge-sync-summary';
      }
    }
  }

  return {
    status,
    source,
    nextWakeCondition,
    summaryPath: summaryPath ? toRelative(repoRoot, summaryPath) : null,
    promotionStatus,
    mergeStateStatus,
    isInMergeQueue,
    autoMergeEnabled,
    prUrl: deliveryRuntime.prUrl
  };
}

function deriveGovernorMode({ queueState, continuity, monitoringMode, wake }) {
  switch (wake.terminalState) {
    case 'compare-work':
      return 'compare-governance-work';
    case 'template-work':
      return 'template-work';
    case 'external-route':
      return 'external-route';
    case 'suppressed':
      return 'suppressed';
    case 'monitoring':
      return 'monitoring';
    case 'retired':
      return 'retired';
    default:
      break;
  }

  if (
    queueState.status === 'queue-empty' &&
    continuity.status === 'maintained' &&
    continuity.turnBoundary === 'safe-idle' &&
    asOptional(monitoringMode?.summary?.status) === 'active'
  ) {
    return 'monitoring-active';
  }

  return 'attention-required';
}

function deriveSignalQuality({ governorMode, wake }) {
  if ((wake.terminalState === 'suppressed' || wake.terminalState === 'monitoring') && wake.blockedLowerTierEvidence) {
    return 'noise-contained';
  }
  if (wake.terminalState === 'compare-work' && wake.blockedLowerTierEvidence) {
    return 'validated-governance-work';
  }
  if (wake.terminalState === 'compare-work') {
    return 'actionable-governance-work';
  }
  if (wake.terminalState === 'template-work') {
    return 'validated-template-work';
  }
  if (wake.terminalState === 'external-route') {
    return 'routed-external-signal';
  }
  if (governorMode === 'monitoring-active') {
    return 'idle-monitoring';
  }
  return 'unknown';
}

function deriveOwners({ governorMode, monitoringMode, wake, repository }) {
  const compareRepository =
    asOptional(monitoringMode?.policy?.compareRepository) ||
    asOptional(monitoringMode?.repository) ||
    asOptional(repository);
  const pivotTargetRepository = asOptional(monitoringMode?.policy?.pivotTargetRepository);

  switch (governorMode) {
    case 'compare-governance-work':
      return {
        currentOwnerRepository: wake.recommendedOwnerRepository || compareRepository,
        nextOwnerRepository: wake.recommendedOwnerRepository || compareRepository
      };
    case 'template-work':
      return {
        currentOwnerRepository: wake.recommendedOwnerRepository || pivotTargetRepository,
        nextOwnerRepository: wake.recommendedOwnerRepository || pivotTargetRepository
      };
    case 'monitoring-active':
      return {
        currentOwnerRepository: compareRepository,
        nextOwnerRepository:
          asOptional(monitoringMode?.summary?.futureAgentAction) === 'future-agent-may-pivot'
            ? pivotTargetRepository
            : compareRepository
      };
    case 'external-route':
      return {
        currentOwnerRepository: compareRepository,
        nextOwnerRepository: wake.recommendedOwnerRepository || compareRepository
      };
    default:
      return {
        currentOwnerRepository: compareRepository,
        nextOwnerRepository: compareRepository
      };
  }
}

function deriveNextAction({ governorMode, monitoringMode, wake }) {
  switch (governorMode) {
    case 'compare-governance-work':
      return wake.issueNumber ? 'continue-standing-work' : 'continue-compare-governance-work';
    case 'template-work':
      return 'route-to-template-work';
    case 'external-route':
      return 'follow-external-route';
    case 'suppressed':
      return 'stay-suppressed';
    case 'monitoring':
      return 'remain-in-monitoring';
    case 'retired':
      return 'no-further-action';
    case 'monitoring-active':
      return asOptional(monitoringMode?.summary?.futureAgentAction) || 'remain-in-monitoring';
    default:
      return 'refresh-governor-inputs';
  }
}

function buildReport({
  repoRoot,
  queueEmptyReportPath,
  queueEmptyReport,
  continuitySummaryPath,
  continuitySummary,
  monitoringModePath,
  monitoringMode,
  wakeLifecyclePath,
  wakeLifecycle,
  wakeInvestmentAccountingPath,
  wakeInvestmentAccounting,
  deliveryRuntimeStatePath,
  deliveryRuntimeState,
  releaseSigningReadinessPath,
  releaseSigningReadinessReport,
  readOptionalJsonFn,
  now
}) {
  const repository =
    asOptional(monitoringMode?.repository) ||
    asOptional(wakeLifecycle?.repository) ||
    asOptional(wakeInvestmentAccounting?.repository) ||
    null;

  const queueState = deriveQueueState(queueEmptyReport, monitoringMode);
  const continuity = deriveContinuity(continuitySummary, monitoringMode);
  const wake = deriveWake(wakeLifecycle);
  const funding = deriveFunding(wakeInvestmentAccounting);
  const releaseSigningReadiness = deriveReleaseSigningReadiness(releaseSigningReadinessReport);
  const deliveryRuntime = deriveDeliveryRuntime(deliveryRuntimeState);
  const queueAuthority = deriveQueueAuthority({
    repoRoot,
    repository,
    deliveryRuntime,
    readOptionalJsonFn
  });
  const governorMode = deriveGovernorMode({ queueState, continuity, monitoringMode, wake });
  const signalQuality = deriveSignalQuality({ governorMode, wake });
  const owners = deriveOwners({ governorMode, monitoringMode, wake, repository });
  const nextAction = deriveNextAction({ governorMode, monitoringMode, wake });

  return {
    schema: 'priority/autonomous-governor-summary-report@v1',
    generatedAt: now.toISOString(),
    repository,
    inputs: {
      queueEmptyReportPath: toRelative(repoRoot, queueEmptyReportPath),
      continuitySummaryPath: toRelative(repoRoot, continuitySummaryPath),
      monitoringModePath: toRelative(repoRoot, monitoringModePath),
      wakeLifecyclePath: toRelative(repoRoot, wakeLifecyclePath),
      wakeInvestmentAccountingPath: toRelative(repoRoot, wakeInvestmentAccountingPath),
      deliveryRuntimeStatePath: toRelative(repoRoot, deliveryRuntimeStatePath),
      releaseSigningReadinessPath: toRelative(repoRoot, releaseSigningReadinessPath)
    },
    compare: {
      queueState,
      continuity,
      monitoringMode: {
        status: asOptional(monitoringMode?.summary?.status),
        futureAgentAction: asOptional(monitoringMode?.summary?.futureAgentAction),
        wakeConditionCount: Number.isInteger(monitoringMode?.summary?.wakeConditionCount)
          ? monitoringMode.summary.wakeConditionCount
          : null
      },
      releaseSigningReadiness,
      deliveryRuntime,
      queueAuthority
    },
    wake,
    funding,
    summary: {
      governorMode,
      currentOwnerRepository: owners.currentOwnerRepository,
      nextOwnerRepository: owners.nextOwnerRepository,
      nextAction,
      signalQuality,
      queueState: queueState.status,
      continuityStatus: continuity.status,
      wakeTerminalState: wake.terminalState,
      monitoringStatus: asOptional(monitoringMode?.summary?.status),
      futureAgentAction: asOptional(monitoringMode?.summary?.futureAgentAction),
      releaseSigningStatus: releaseSigningReadiness.status,
      releaseSigningAuthorityState: releaseSigningReadiness.signingAuthorityState,
      releaseConductorApplyState: releaseSigningReadiness.releaseConductorApplyState,
      releaseSigningExternalBlocker: releaseSigningReadiness.externalBlocker,
      releasePublicationState: releaseSigningReadiness.publicationState,
      releasePublishedBundleState: releaseSigningReadiness.publishedBundleState,
      releasePublishedBundleReleaseTag: releaseSigningReadiness.publishedBundleReleaseTag,
      releasePublishedBundleAuthoritativeConsumerPin: releaseSigningReadiness.publishedBundleAuthoritativeConsumerPin,
      queueHandoffStatus: queueAuthority.status,
      queueHandoffNextWakeCondition: queueAuthority.nextWakeCondition,
      queueHandoffPrUrl: queueAuthority.prUrl,
      queueAuthoritySource: queueAuthority.source
    }
  };
}

export async function runAutonomousGovernorSummary(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const queueEmptyReportPath = path.resolve(repoRoot, options.queueEmptyReportPath || DEFAULT_QUEUE_EMPTY_REPORT_PATH);
  const continuitySummaryPath = path.resolve(repoRoot, options.continuitySummaryPath || DEFAULT_CONTINUITY_SUMMARY_PATH);
  const monitoringModePath = path.resolve(repoRoot, options.monitoringModePath || DEFAULT_MONITORING_MODE_PATH);
  const wakeLifecyclePath = path.resolve(repoRoot, options.wakeLifecyclePath || DEFAULT_WAKE_LIFECYCLE_PATH);
  const wakeInvestmentAccountingPath = path.resolve(
    repoRoot,
    options.wakeInvestmentAccountingPath || DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH
  );
  const deliveryRuntimeStatePath = path.resolve(
    repoRoot,
    options.deliveryRuntimeStatePath || DEFAULT_DELIVERY_RUNTIME_STATE_PATH
  );
  const releaseSigningReadinessPath = path.resolve(
    repoRoot,
    options.releaseSigningReadinessPath || DEFAULT_RELEASE_SIGNING_READINESS_PATH
  );
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);

  const readOptionalJsonFn = deps.readOptionalJsonFn || readOptionalJson;
  const writeJsonFn = deps.writeJsonFn || writeJson;
  const now = deps.now || new Date();

  const queueEmptyReport = readOptionalJsonFn(queueEmptyReportPath);
  const continuitySummary = readOptionalJsonFn(continuitySummaryPath);
  const monitoringMode = readOptionalJsonFn(monitoringModePath);
  const wakeLifecycle = readOptionalJsonFn(wakeLifecyclePath);
  const wakeInvestmentAccounting = readOptionalJsonFn(wakeInvestmentAccountingPath);
  const deliveryRuntimeState = readOptionalJsonFn(deliveryRuntimeStatePath);
  const releaseSigningReadinessReport = readOptionalJsonFn(releaseSigningReadinessPath);

  if (queueEmptyReport) {
    ensureSchema(queueEmptyReport, queueEmptyReportPath, 'standing-priority/no-standing@v1');
  }
  if (continuitySummary) {
    ensureSchema(continuitySummary, continuitySummaryPath, 'priority/continuity-telemetry-report@v1');
  }
  if (monitoringMode) {
    ensureSchema(monitoringMode, monitoringModePath, 'agent-handoff/monitoring-mode-v1');
  }
  if (wakeLifecycle) {
    ensureSchema(wakeLifecycle, wakeLifecyclePath, 'priority/wake-lifecycle-report@v1');
  }
  if (wakeInvestmentAccounting) {
    ensureSchema(wakeInvestmentAccounting, wakeInvestmentAccountingPath, 'priority/wake-investment-accounting-report@v1');
  }
  if (deliveryRuntimeState) {
    ensureSchema(deliveryRuntimeState, deliveryRuntimeStatePath, 'priority/delivery-agent-runtime-state@v1');
  }
  if (releaseSigningReadinessReport) {
    ensureSchema(
      releaseSigningReadinessReport,
      releaseSigningReadinessPath,
      'priority/release-signing-readiness-report@v1'
    );
  }

  const report = buildReport({
    repoRoot,
    queueEmptyReportPath,
    queueEmptyReport,
    continuitySummaryPath,
    continuitySummary,
    monitoringModePath,
    monitoringMode,
    wakeLifecyclePath,
    wakeLifecycle,
    wakeInvestmentAccountingPath,
    wakeInvestmentAccounting,
    deliveryRuntimeStatePath,
    deliveryRuntimeState,
    releaseSigningReadinessPath,
    releaseSigningReadinessReport,
    readOptionalJsonFn,
    now
  });

  const writtenPath = writeJsonFn(outputPath, report);
  return { report, outputPath: writtenPath };
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[autonomous-governor-summary] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runAutonomousGovernorSummary(options);
    console.log(
      `[autonomous-governor-summary] wrote ${outputPath} (${report.summary.governorMode}, next=${report.summary.nextAction})`
    );
    return 0;
  } catch (error) {
    console.error(`[autonomous-governor-summary] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && modulePath === invokedPath) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

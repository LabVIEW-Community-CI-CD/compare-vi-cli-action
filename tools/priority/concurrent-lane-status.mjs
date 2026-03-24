#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  CONCURRENT_LANE_APPLY_RECEIPT_SCHEMA,
  DEFAULT_OUTPUT_PATH as DEFAULT_APPLY_RECEIPT_PATH
} from './concurrent-lane-apply.mjs';
import {
  DEFAULT_OUTPUT_PATH as DEFAULT_EXECUTION_BUNDLE_RECEIPT_PATH,
  EXECUTION_CELL_BUNDLE_REPORT_SCHEMA
} from './execution-cell-bundle.mjs';
import { ensureGhCli, resolveUpstream, runGhGraphql, runGhJson } from './lib/remote-utils.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';

export const CONCURRENT_LANE_STATUS_RECEIPT_SCHEMA = 'priority/concurrent-lane-status-receipt@v1';
export const DEFAULT_STATUS_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'concurrent-lane-status-receipt.json'
);

const ACTIVE_RUN_STATUSES = new Set(['queued', 'in_progress', 'pending', 'requested', 'waiting']);
const SUCCESSFUL_CONCLUSIONS = new Set(['success', 'neutral', 'skipped']);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toOptionalText(value) {
  const normalized = normalizeText(value);
  return normalized || null;
}

function normalizeLower(value) {
  return normalizeText(value).toLowerCase();
}

function coercePositiveInteger(value) {
  if (value == null) {
    return null;
  }
  const numeric = Number(value);
  if (!Number.isInteger(numeric) || numeric <= 0) {
    return null;
  }
  return numeric;
}

async function readJsonRequired(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

async function writeReceipt(outputPath, receipt) {
  const resolved = path.resolve(process.cwd(), outputPath);
  await fs.mkdir(path.dirname(resolved), { recursive: true });
  await fs.writeFile(resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
  return resolved;
}

function summarizePrChecks(statusCheckRollup = []) {
  const checks = Array.isArray(statusCheckRollup) ? statusCheckRollup : [];
  const summary = {
    total: checks.length,
    completed: 0,
    pending: 0,
    failed: 0,
    successful: 0
  };

  for (const entry of checks) {
    const typeName = normalizeText(entry?.__typename);
    if (typeName === 'CheckRun') {
      const status = normalizeLower(entry?.status);
      const conclusion = normalizeLower(entry?.conclusion);
      if (status === 'completed') {
        summary.completed += 1;
        if (SUCCESSFUL_CONCLUSIONS.has(conclusion)) {
          summary.successful += 1;
        } else {
          summary.failed += 1;
        }
      } else {
        summary.pending += 1;
      }
      continue;
    }

    const state = normalizeLower(entry?.state);
    if (state === 'success') {
      summary.completed += 1;
      summary.successful += 1;
    } else if (state === 'pending' || state === 'expected') {
      summary.pending += 1;
    } else if (state) {
      summary.completed += 1;
      summary.failed += 1;
    }
  }

  return summary;
}

function classifyHostedRunObservation(run = null, observationError = null, applyReceipt = null) {
  const dispatchStatus = normalizeLower(applyReceipt?.validateDispatch?.status);
  if (dispatchStatus === 'dry-run') {
    return 'planned';
  }
  if (dispatchStatus === 'failed') {
    return 'failed';
  }
  if (dispatchStatus === 'not-required') {
    return 'not-required';
  }
  if (observationError) {
    return 'failed';
  }
  if (!run) {
    return dispatchStatus === 'dispatched' ? 'unknown' : 'not-required';
  }

  const status = normalizeLower(run.status);
  const conclusion = normalizeLower(run.conclusion);
  if (ACTIVE_RUN_STATUSES.has(status)) {
    return 'active';
  }
  if (status === 'completed') {
    return SUCCESSFUL_CONCLUSIONS.has(conclusion) ? 'completed' : 'failed';
  }
  return 'unknown';
}

function projectHostedLaneStatus(lane, hostedObservationStatus) {
  if (lane.executionPlane !== 'hosted') {
    if (lane.decision === 'deferred') {
      return 'deferred';
    }
    if (lane.decision === 'blocked') {
      return 'blocked';
    }
    return 'unknown';
  }

  if (lane.decision === 'blocked') {
    return 'blocked';
  }
  if (lane.decision === 'planned-dispatch') {
    return 'planned';
  }
  if (lane.decision !== 'dispatched') {
    return 'unknown';
  }
  if (hostedObservationStatus === 'active') {
    return 'active';
  }
  if (hostedObservationStatus === 'completed') {
    return 'completed';
  }
  if (hostedObservationStatus === 'failed') {
    return 'failed';
  }
  if (hostedObservationStatus === 'planned') {
    return 'planned';
  }
  return 'unknown';
}

function determineReceiptStatus({ applyReceipt, hostedObservationStatus, pullRequestObservationStatus, observationErrors }) {
  if (normalizeLower(applyReceipt?.status) === 'failed') {
    return 'failed';
  }
  if (hostedObservationStatus === 'failed') {
    return 'failed';
  }
  if (pullRequestObservationStatus === 'error') {
    return 'failed';
  }
  if (observationErrors.length > 0) {
    return 'failed';
  }
  if (hostedObservationStatus === 'active') {
    return 'active';
  }
  return 'settled';
}

function projectExecutionBundleReceipt(receiptPath, receipt) {
  if (!receipt || receipt.schema !== EXECUTION_CELL_BUNDLE_REPORT_SCHEMA) {
    return null;
  }

  const summary = receipt.summary && typeof receipt.summary === 'object' ? receipt.summary : {};
  return {
    path: toOptionalText(receiptPath),
    schema: toOptionalText(receipt.schema),
    status: toOptionalText(receipt.status),
    cellId: toOptionalText(receipt.cellId),
    laneId: toOptionalText(receipt.laneId),
    executionCellLeaseId: toOptionalText(summary.executionCellLeaseId),
    dockerLaneLeaseId: toOptionalText(summary.dockerLaneLeaseId),
    harnessInstanceId: toOptionalText(summary.harnessInstanceId),
    planeBinding: toOptionalText(summary.planeBinding),
    premiumSaganMode: summary.premiumSaganMode === true,
    reciprocalLinkReady: summary.reciprocalLinkReady === true,
    effectiveBillableRateUsdPerHour: Number.isFinite(summary.effectiveBillableRateUsdPerHour)
      ? summary.effectiveBillableRateUsdPerHour
      : null,
    isolatedLaneGroupId: toOptionalText(summary.isolatedLaneGroupId),
    fingerprintSha256: toOptionalText(summary.fingerprintSha256)
  };
}

const IDLE_CLASSIFICATION_STATES = Object.freeze([
  'waiting-hosted',
  'waiting-merge',
  'policy-paused',
  'blocked',
  'prewarm',
  'operator-steering',
  'queue-empty'
]);

function normalizeReasonList(reasons = []) {
  return Array.isArray(reasons)
    ? reasons.map((reason) => normalizeLower(reason)).filter(Boolean)
    : [];
}

function normalizeIdleClassification(classification) {
  const state = normalizeLower(classification?.state);
  if (!IDLE_CLASSIFICATION_STATES.includes(state)) {
    return null;
  }
  return {
    state,
    source: toOptionalText(classification?.source) || 'derived',
    signals: Array.isArray(classification?.signals)
      ? classification.signals.map((signal) => toOptionalText(signal)).filter(Boolean)
      : []
  };
}

export function classifyIdleLaneState(lane = {}) {
  const runtimeStatus = normalizeLower(lane.runtimeStatus);
  if (!runtimeStatus || runtimeStatus === 'active' || runtimeStatus === 'completed') {
    return null;
  }

  const decision = normalizeLower(lane.decision);
  const executionPlane = normalizeLower(lane.executionPlane);
  const availability = normalizeLower(lane.availability);
  const reasons = normalizeReasonList(lane.reasons);
  const metadata = lane?.metadata && typeof lane.metadata === 'object' ? lane.metadata : {};
  const signals = [...new Set([runtimeStatus, decision, executionPlane, availability, ...reasons])].filter(Boolean);

  if (
    runtimeStatus === 'blocked' ||
    decision === 'blocked' ||
    metadata.blocked === true ||
    reasons.some((reason) => reason.includes('blocked'))
  ) {
    return {
      state: 'blocked',
      source: runtimeStatus === 'blocked' || decision === 'blocked' ? 'decision' : 'reason',
      signals
    };
  }

  if (
    metadata.operatorSteering === true ||
    metadata.operatorSteered === true ||
    reasons.some((reason) => reason.includes('operator-steering') || reason.includes('operator steering') || reason.includes('steering'))
  ) {
    return {
      state: 'operator-steering',
      source: metadata.operatorSteering === true || metadata.operatorSteered === true ? 'metadata' : 'reason',
      signals
    };
  }

  if (
    metadata.policyPaused === true ||
    availability === 'disabled' ||
    reasons.some((reason) => reason.includes('policy-paused') || (reason.includes('policy') && reason.includes('paused')))
  ) {
    return {
      state: 'policy-paused',
      source: metadata.policyPaused === true || availability === 'disabled' ? 'metadata' : 'reason',
      signals
    };
  }

  if (
    metadata.prewarm === true ||
    lane.laneClass === 'shadow-validation' ||
    reasons.some((reason) => reason.includes('prewarm') || reason.includes('warm-up') || reason.includes('warmup'))
  ) {
    return {
      state: 'prewarm',
      source: metadata.prewarm === true || lane.laneClass === 'shadow-validation' ? 'metadata' : 'reason',
      signals
    };
  }

  if (
    metadata.queueEmpty === true ||
    reasons.some((reason) => reason.includes('queue-empty') || reason.includes('no-open-issues') || reason.includes('no-eligible'))
  ) {
    return {
      state: 'queue-empty',
      source: metadata.queueEmpty === true ? 'metadata' : 'reason',
      signals
    };
  }

  if (executionPlane === 'hosted' || lane.laneClass === 'hosted-proof') {
    return {
      state: 'waiting-hosted',
      source: 'execution-plane',
      signals
    };
  }

  return {
    state: 'waiting-merge',
    source: 'execution-plane',
    signals
  };
}

export function summarizeIdleClassificationCoverage(laneStatuses = []) {
  const nonWorkingLaneStatuses = Array.isArray(laneStatuses)
    ? laneStatuses.filter((entry) => {
        const runtimeStatus = normalizeLower(entry?.runtimeStatus);
        return runtimeStatus && runtimeStatus !== 'active' && runtimeStatus !== 'completed';
      })
    : [];
  const classifiedLaneStatuses = nonWorkingLaneStatuses.filter(
    (entry) => normalizeIdleClassification(entry?.idleClassification) !== null
  );
  const stateCounts = Object.fromEntries(IDLE_CLASSIFICATION_STATES.map((state) => [state, 0]));
  for (const entry of classifiedLaneStatuses) {
    const state = normalizeLower(entry?.idleClassification?.state);
    if (state in stateCounts) {
      stateCounts[state] += 1;
    }
  }
  const nonWorkingLaneCount = nonWorkingLaneStatuses.length;
  const classifiedLaneCount = classifiedLaneStatuses.length;
  const unclassifiedLaneCount = Math.max(nonWorkingLaneCount - classifiedLaneCount, 0);
  return {
    managedLaneCount: Array.isArray(laneStatuses) ? laneStatuses.length : 0,
    nonWorkingLaneCount,
    classifiedLaneCount,
    unclassifiedLaneCount,
    coverageRatio: nonWorkingLaneCount > 0 ? classifiedLaneCount / nonWorkingLaneCount : 1,
    stateCounts
  };
}

function determineOrchestratorDisposition({ receiptStatus, hostedObservationStatus, pullRequestObservationStatus, deferredLaneCount }) {
  if (receiptStatus === 'failed') {
    return 'hold-investigate';
  }
  if (hostedObservationStatus === 'active') {
    return 'wait-hosted-run';
  }
  if (pullRequestObservationStatus === 'queued') {
    return 'release-merge-queue';
  }
  if (deferredLaneCount > 0) {
    return 'release-with-deferred-local';
  }
  return 'release-complete';
}

function buildRunUrl(repository, runId, fallbackUrl = null) {
  const repoSlug = normalizeText(repository);
  const normalizedRunId = coercePositiveInteger(runId);
  if (normalizeText(fallbackUrl)) {
    return fallbackUrl;
  }
  if (!repoSlug || normalizedRunId === null) {
    return null;
  }
  return `https://github.com/${repoSlug}/actions/runs/${normalizedRunId}`;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    applyReceiptPath: DEFAULT_APPLY_RECEIPT_PATH,
    executionBundleReceiptPath: DEFAULT_EXECUTION_BUNDLE_RECEIPT_PATH,
    outputPath: DEFAULT_STATUS_OUTPUT_PATH,
    repo: null,
    pr: null,
    ref: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (
      token === '--apply-receipt' ||
      token === '--execution-bundle-receipt' ||
      token === '--output' ||
      token === '--repo' ||
      token === '--pr' ||
      token === '--ref'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--apply-receipt') options.applyReceiptPath = next;
      if (token === '--execution-bundle-receipt') options.executionBundleReceiptPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--pr') options.pr = next;
      if (token === '--ref') options.ref = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function buildPullRequestSelector(options, applyReceipt) {
  const explicitPr = coercePositiveInteger(options.pr);
  if (explicitPr !== null) {
    return { number: explicitPr, ref: null, source: 'cli-pr' };
  }

  const explicitRef = toOptionalText(options.ref);
  if (explicitRef) {
    return { number: null, ref: explicitRef, source: 'cli-ref' };
  }

  const receiptRef = toOptionalText(applyReceipt?.validateDispatch?.ref);
  if (receiptRef) {
    return { number: null, ref: receiptRef, source: 'apply-receipt' };
  }

  return { number: null, ref: null, source: 'none' };
}

function isNotFoundError(error) {
  const message = normalizeLower(error?.message);
  return message.includes('not found') || message.includes('could not resolve to a pull request');
}

function observeHostedRun({
  repoRoot,
  repository,
  runId,
  runGhJsonFn = runGhJson
}) {
  const normalizedRunId = coercePositiveInteger(runId);
  if (normalizedRunId === null || !normalizeText(repository)) {
    return {
      observationStatus: 'not-observed',
      runId: normalizedRunId,
      status: null,
      conclusion: null,
      url: null,
      workflowName: null,
      displayTitle: null,
      headBranch: null,
      headSha: null,
      createdAt: null,
      updatedAt: null,
      error: null
    };
  }

  try {
    const payload = runGhJsonFn(repoRoot, ['api', `repos/${repository}/actions/runs/${normalizedRunId}`]);
    const runStatus = normalizeLower(payload?.status);
    const runConclusion = normalizeLower(payload?.conclusion);
    return {
      observationStatus: classifyHostedRunObservation(
        {
          status: runStatus,
          conclusion: runConclusion
        },
        null,
        {
          validateDispatch: {
            status: 'dispatched'
          }
        }
      ),
      runId: normalizedRunId,
      status: toOptionalText(payload?.status),
      conclusion: toOptionalText(payload?.conclusion),
      url: buildRunUrl(repository, normalizedRunId, payload?.html_url),
      workflowName: toOptionalText(payload?.name),
      displayTitle: toOptionalText(payload?.display_title),
      headBranch: toOptionalText(payload?.head_branch),
      headSha: toOptionalText(payload?.head_sha),
      createdAt: toOptionalText(payload?.created_at),
      updatedAt: toOptionalText(payload?.updated_at),
      error: null
    };
  } catch (error) {
    return {
      observationStatus: 'failed',
      runId: normalizedRunId,
      status: null,
      conclusion: null,
      url: buildRunUrl(repository, normalizedRunId, null),
      workflowName: null,
      displayTitle: null,
      headBranch: null,
      headSha: null,
      createdAt: null,
      updatedAt: null,
      error: error?.message || String(error)
    };
  }
}

function lookupPullRequestByRef({
  repoRoot,
  repository,
  ref,
  runGhJsonFn = runGhJson
}) {
  const normalizedRef = normalizeText(ref);
  if (!normalizedRef || !normalizeText(repository)) {
    return null;
  }
  try {
    return runGhJsonFn(repoRoot, ['pr', 'view', normalizedRef, '--repo', repository, '--json', 'number,url,state,isDraft,headRefName,mergeStateStatus,statusCheckRollup']);
  } catch (error) {
    if (isNotFoundError(error)) {
      return null;
    }
    throw error;
  }
}

function observePullRequest({
  repoRoot,
  repository,
  selector,
  runGhJsonFn = runGhJson,
  runGhGraphqlFn = runGhGraphql
}) {
  if ((!selector?.number || selector.number === null) && !normalizeText(selector?.ref)) {
    return {
      observationStatus: 'not-requested',
      selector: {
        source: selector?.source ?? 'none',
        pr: null,
        ref: null
      },
      number: null,
      url: null,
      state: null,
      isDraft: null,
      headRefName: null,
      mergeStateStatus: null,
      mergeQueue: {
        status: 'not-requested',
        position: null,
        estimatedTimeToMerge: null,
        enqueuedAt: null
      },
      checksSummary: {
        total: 0,
        completed: 0,
        pending: 0,
        failed: 0,
        successful: 0
      },
      error: null
    };
  }

  try {
    let prPayload;
    let prNumber = coercePositiveInteger(selector?.number);
    if (prNumber !== null) {
      prPayload = runGhJsonFn(repoRoot, [
        'pr',
        'view',
        String(prNumber),
        '--repo',
        repository,
        '--json',
        'number,url,state,isDraft,headRefName,mergeStateStatus,statusCheckRollup'
      ]);
    } else {
      prPayload = lookupPullRequestByRef({
        repoRoot,
        repository,
        ref: selector?.ref,
        runGhJsonFn
      });
      prNumber = coercePositiveInteger(prPayload?.number);
    }

    if (!prPayload || prNumber === null) {
      return {
        observationStatus: 'not-found',
        selector: {
          source: selector?.source ?? 'unknown',
          pr: selector?.number ?? null,
          ref: toOptionalText(selector?.ref)
        },
        number: null,
        url: null,
        state: null,
        isDraft: null,
        headRefName: toOptionalText(selector?.ref),
        mergeStateStatus: null,
        mergeQueue: {
          status: 'not-found',
          position: null,
          estimatedTimeToMerge: null,
          enqueuedAt: null
        },
        checksSummary: {
          total: 0,
          completed: 0,
          pending: 0,
          failed: 0,
          successful: 0
        },
        error: null
      };
    }

    const query = `
      query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $number) {
            mergeQueueEntry {
              position
              estimatedTimeToMerge
              enqueuedAt
            }
          }
        }
      }
    `;
    const [owner, repo] = repository.split('/', 2);
    const queuePayload = runGhGraphqlFn(repoRoot, query, { owner, repo, number: prNumber });
    const mergeQueueEntry = queuePayload?.data?.repository?.pullRequest?.mergeQueueEntry ?? null;
    const mergeQueueStatus = mergeQueueEntry ? 'queued' : 'not-queued';
    const state = toOptionalText(prPayload?.state);
    let observationStatus = 'open';
    if (mergeQueueStatus === 'queued') {
      observationStatus = 'queued';
    } else if (normalizeLower(state) === 'merged') {
      observationStatus = 'merged';
    } else if (normalizeLower(state) === 'closed') {
      observationStatus = 'closed';
    }

    return {
      observationStatus,
      selector: {
        source: selector?.source ?? 'unknown',
        pr: prNumber,
        ref: toOptionalText(selector?.ref) ?? toOptionalText(prPayload?.headRefName)
      },
      number: prNumber,
      url: toOptionalText(prPayload?.url),
      state,
      isDraft: prPayload?.isDraft === true,
      headRefName: toOptionalText(prPayload?.headRefName),
      mergeStateStatus: toOptionalText(prPayload?.mergeStateStatus),
      mergeQueue: {
        status: mergeQueueStatus,
        position: coercePositiveInteger(mergeQueueEntry?.position),
        estimatedTimeToMerge: coercePositiveInteger(mergeQueueEntry?.estimatedTimeToMerge),
        enqueuedAt: toOptionalText(mergeQueueEntry?.enqueuedAt)
      },
      checksSummary: summarizePrChecks(prPayload?.statusCheckRollup),
      error: null
    };
  } catch (error) {
    return {
      observationStatus: 'error',
      selector: {
        source: selector?.source ?? 'unknown',
        pr: selector?.number ?? null,
        ref: toOptionalText(selector?.ref)
      },
      number: selector?.number ?? null,
      url: null,
      state: null,
      isDraft: null,
      headRefName: toOptionalText(selector?.ref),
      mergeStateStatus: null,
      mergeQueue: {
        status: 'unknown',
        position: null,
        estimatedTimeToMerge: null,
        enqueuedAt: null
      },
      checksSummary: {
        total: 0,
        completed: 0,
        pending: 0,
        failed: 0,
        successful: 0
      },
      error: error?.message || String(error)
    };
  }
}

export function buildConcurrentLaneStatusReceipt({
  applyReceiptPath,
  applyReceipt,
  executionBundle,
  hostedRun,
  pullRequest,
  laneStatuses,
  now = new Date(),
  status = 'settled',
  observationErrors = []
}) {
  const deferredLaneCount = laneStatuses.filter((entry) => entry.runtimeStatus === 'deferred').length;
  const activeLaneCount = laneStatuses.filter((entry) => entry.runtimeStatus === 'active').length;
  const completedLaneCount = laneStatuses.filter((entry) => entry.runtimeStatus === 'completed').length;
  const failedLaneCount = laneStatuses.filter((entry) => entry.runtimeStatus === 'failed').length;
  const blockedLaneCount = laneStatuses.filter((entry) => entry.runtimeStatus === 'blocked').length;
  const plannedLaneCount = laneStatuses.filter((entry) => entry.runtimeStatus === 'planned').length;
  const enrichedLaneStatuses = laneStatuses.map((entry) => ({
    ...entry,
    idleClassification: classifyIdleLaneState(entry)
  }));
  const idleClassificationCoverage = summarizeIdleClassificationCoverage(enrichedLaneStatuses);

  return {
    schema: CONCURRENT_LANE_STATUS_RECEIPT_SCHEMA,
    generatedAt: now.toISOString(),
    repository: toOptionalText(applyReceipt?.repository) ?? toOptionalText(applyReceipt?.validateDispatch?.repository) ?? null,
    status,
    applyReceipt: {
      path: toOptionalText(applyReceiptPath),
      schema: toOptionalText(applyReceipt?.schema),
      status: toOptionalText(applyReceipt?.status),
      selectedBundleId: toOptionalText(applyReceipt?.summary?.selectedBundleId)
    },
    plan: {
      path: toOptionalText(applyReceipt?.plan?.path),
      schema: toOptionalText(applyReceipt?.plan?.schema),
      source: toOptionalText(applyReceipt?.plan?.source),
      recommendedBundleId: toOptionalText(applyReceipt?.plan?.recommendedBundleId),
      selectedBundleId: toOptionalText(applyReceipt?.plan?.selectedBundle?.id)
    },
    executionBundle: executionBundle ?? null,
    hostedRun,
    pullRequest,
    laneStatuses: enrichedLaneStatuses,
    observationErrors,
    summary: {
      selectedBundleId: toOptionalText(applyReceipt?.summary?.selectedBundleId),
      laneCount: laneStatuses.length,
      activeLaneCount,
      completedLaneCount,
      failedLaneCount,
      blockedLaneCount,
      plannedLaneCount,
      deferredLaneCount,
      manualLaneCount: laneStatuses.filter((entry) => entry.executionPlane === 'local').length,
      shadowLaneCount: laneStatuses.filter((entry) => entry.executionPlane === 'local-shadow').length,
      executionBundleStatus: toOptionalText(executionBundle?.status),
      executionBundleReciprocalLinkReady: executionBundle?.reciprocalLinkReady === true,
      executionBundlePremiumSaganMode: executionBundle?.premiumSaganMode === true,
      pullRequestStatus: pullRequest?.observationStatus ?? 'not-requested',
      idleClassificationCoverage,
      orchestratorDisposition: determineOrchestratorDisposition({
        receiptStatus: status,
        hostedObservationStatus: hostedRun?.observationStatus ?? 'not-required',
        pullRequestObservationStatus: pullRequest?.observationStatus ?? 'not-requested',
        deferredLaneCount
      })
    }
  };
}

export async function observeConcurrentLaneStatus(
  options,
  {
    ensureGhCliFn = ensureGhCli,
    getRepoRootFn = getRepoRoot,
    resolveUpstreamFn = resolveUpstream,
    runGhJsonFn = runGhJson,
    runGhGraphqlFn = runGhGraphql
  } = {}
) {
  const repoRoot = getRepoRootFn();
  const applyReceiptPath = path.resolve(repoRoot, options.applyReceiptPath);
  const executionBundleReceiptPath = path.resolve(repoRoot, options.executionBundleReceiptPath);
  const applyReceipt = await readJsonRequired(applyReceiptPath);
  if (applyReceipt?.schema !== CONCURRENT_LANE_APPLY_RECEIPT_SCHEMA) {
    throw new Error(
      `Concurrent lane apply receipt at '${applyReceiptPath}' has schema '${applyReceipt?.schema ?? 'unknown'}'; expected '${CONCURRENT_LANE_APPLY_RECEIPT_SCHEMA}'.`
    );
  }

  const executionBundle = projectExecutionBundleReceipt(
    executionBundleReceiptPath,
    await readJsonIfPresent(executionBundleReceiptPath)
  );

  const repository =
    toOptionalText(options.repo) ??
    toOptionalText(applyReceipt?.repository) ??
    toOptionalText(applyReceipt?.validateDispatch?.repository) ??
    (() => {
      const upstream = resolveUpstreamFn(repoRoot);
      return upstream?.owner && upstream?.repo ? `${upstream.owner}/${upstream.repo}` : null;
    })();

  const selector = buildPullRequestSelector(options, applyReceipt);
  const shouldUseGitHub =
    coercePositiveInteger(applyReceipt?.validateDispatch?.runDatabaseId) !== null ||
    selector.number !== null ||
    Boolean(selector.ref);
  if (shouldUseGitHub) {
    ensureGhCliFn();
  }

  const rawHostedRun = observeHostedRun({
    repoRoot,
    repository,
    runId: applyReceipt?.validateDispatch?.runDatabaseId,
    runGhJsonFn
  });
  const hostedRun = {
    ...rawHostedRun,
    observationStatus: classifyHostedRunObservation(rawHostedRun, rawHostedRun.error, applyReceipt),
    reportPath: toOptionalText(applyReceipt?.validateDispatch?.reportPath),
    helperCommand: Array.isArray(applyReceipt?.validateDispatch?.command)
      ? [...applyReceipt.validateDispatch.command]
      : []
  };

  const pullRequest = observePullRequest({
    repoRoot,
    repository,
    selector,
    runGhJsonFn,
    runGhGraphqlFn
  });

  const laneStatuses = (Array.isArray(applyReceipt?.selectedLanes) ? applyReceipt.selectedLanes : []).map((lane) => ({
    id: lane.id,
    laneClass: lane.laneClass,
    executionPlane: lane.executionPlane,
    decision: lane.decision,
    availability: lane.availability,
    runtimeStatus: projectHostedLaneStatus(lane, hostedRun.observationStatus),
    reasons: Array.isArray(lane.reasons) ? [...lane.reasons] : [],
    metadata: lane.metadata && typeof lane.metadata === 'object' ? { ...lane.metadata } : {}
  }));

  const observationErrors = [hostedRun.error, pullRequest.error].filter(Boolean);
  const status = determineReceiptStatus({
    applyReceipt,
    hostedObservationStatus: hostedRun.observationStatus,
    pullRequestObservationStatus: pullRequest.observationStatus,
    observationErrors
  });
  const receipt = buildConcurrentLaneStatusReceipt({
    applyReceiptPath,
    applyReceipt,
    executionBundle,
    hostedRun,
    pullRequest,
    laneStatuses,
    observationErrors,
    status
  });
  const outputPath = await writeReceipt(options.outputPath, receipt);
  return { receipt, outputPath };
}

function printUsage() {
  console.log('Usage: node tools/priority/concurrent-lane-status.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --apply-receipt <path>  Concurrent lane apply receipt path (default: ${DEFAULT_APPLY_RECEIPT_PATH})`);
  console.log(
    `  --execution-bundle-receipt <path>  Execution bundle receipt path (default: ${DEFAULT_EXECUTION_BUNDLE_RECEIPT_PATH})`
  );
  console.log(`  --output <path>         Status receipt path (default: ${DEFAULT_STATUS_OUTPUT_PATH})`);
  console.log('  --repo <owner/repo>     Repository override for hosted run and PR observation.');
  console.log('  --pr <number>           Pull request number override for merge-queue observation.');
  console.log('  --ref <branch>          Head ref override for PR lookup when --pr is omitted.');
  console.log('  -h, --help              Show help.');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const { receipt, outputPath } = await observeConcurrentLaneStatus(options);
  console.log(
    `[concurrent-lane-status] receipt=${outputPath} status=${receipt.status} disposition=${receipt.summary.orchestratorDisposition}`
  );
  if (receipt.pullRequest?.observationStatus === 'queued') {
    console.log(
      `[concurrent-lane-status] merge-queue position=${receipt.pullRequest.mergeQueue.position ?? 'unknown'} eta=${receipt.pullRequest.mergeQueue.estimatedTimeToMerge ?? 'unknown'}`
    );
  }
  return receipt.status === 'failed' ? 1 : 0;
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

#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { fetchIssue } from './sync-standing-priority.mjs';

export const COST_ROLLUP_SCHEMA = 'priority/agent-cost-rollup@v1';
export const INVOICE_TURN_SCHEMA = 'priority/agent-cost-invoice-turn@v1';
export const REPORT_SCHEMA = 'priority/average-issue-cost-scorecard@v1';
export const DEFAULT_COST_ROLLUP_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_INVOICE_TURN_DIR = path.join('tests', 'results', '_agent', 'cost', 'invoice-turns');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'capital', 'average-issue-cost-scorecard.json');

export const IMPLEMENTED_METRIC_CODES = [
  'average-usd-per-issue-by-funding-window',
  'rolling-average-usd-per-issue',
  'average-usd-per-issue-by-current-issue-state',
  'issue-spend-channel-split'
];

export const DEFERRED_METRICS = [
  {
    code: 'historical-issue-state-timeline',
    reason: 'current issue hydration only proves present issue state, not state transitions at each funding-window boundary'
  },
  {
    code: 'issue-age-weighted-average-usd',
    reason: 'requires deterministic issue age and state-age snapshots beyond the cost rollup and invoice-turn receipts'
  },
  {
    code: 'validated-outcome-average-usd',
    reason: 'requires promotion or acceptance evidence in addition to spend and funding-window telemetry'
  }
];

const HELP = [
  'Usage: node tools/priority/average-issue-cost-scorecard.mjs [options]',
  '',
  'Options:',
  `  --cost-rollup <path>   Agent cost rollup path (default: ${DEFAULT_COST_ROLLUP_PATH}).`,
  '  --invoice-turn <path>  Invoice-turn receipt path. Repeat to override auto-discovery.',
  `  --output <path>        Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --repo <owner/repo>    Repository slug override.',
  '  --help                 Show help.'
];

const MODULE_FILE_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = path.resolve(path.dirname(MODULE_FILE_PATH), '..', '..');

function printHelp(log = console.log) {
  for (const line of HELP) {
    log(line);
  }
}

function ensureArray(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function toTimestamp(value) {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function roundNumber(value, precision = 6) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  return Number(parsed.toFixed(precision));
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

function computeAverage(totalUsd, count) {
  const safeTotal = coerceNonNegativeNumber(totalUsd);
  const safeCount = coerceNonNegativeInteger(count);
  if (safeTotal == null || safeCount == null || safeCount === 0) {
    return null;
  }
  return roundNumber(safeTotal / safeCount);
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

function resolveRepoSlug(explicitRepo, fallbackRepo = null) {
  if (normalizeText(explicitRepo).includes('/')) return normalizeText(explicitRepo);
  if (normalizeText(fallbackRepo).includes('/')) return normalizeText(fallbackRepo);
  if (normalizeText(process.env.GITHUB_REPOSITORY).includes('/')) return normalizeText(process.env.GITHUB_REPOSITORY);
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remote}.url`, {
        cwd: REPO_ROOT,
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

function resolvePathCandidate(candidatePath, repoRoot = REPO_ROOT) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) return null;
  return path.isAbsolute(normalized) ? normalized : path.resolve(repoRoot, normalized);
}

function discoverJsonPaths(directoryPath) {
  const resolvedDirectory = resolvePathCandidate(directoryPath) ?? path.resolve(directoryPath);
  if (!fs.existsSync(resolvedDirectory)) {
    return [];
  }
  return fs
    .readdirSync(resolvedDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.json'))
    .map((entry) => path.join(resolvedDirectory, entry.name))
    .sort((left, right) => left.localeCompare(right));
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

function createWarning(code, message, issueNumber = null) {
  return {
    code,
    message,
    issueNumber: Number.isInteger(issueNumber) && issueNumber > 0 ? issueNumber : null
  };
}

function normalizeInputRef(input = null) {
  return {
    path: input?.path ?? null,
    exists: input?.exists === true,
    error: input?.error ?? null
  };
}

function normalizeIterable(values) {
  if (Array.isArray(values)) {
    return values;
  }
  if (values && typeof values[Symbol.iterator] === 'function') {
    return [...values];
  }
  return [];
}

function safeUniqueStrings(values) {
  return [...new Set(normalizeIterable(values).map((entry) => normalizeText(entry)).filter(Boolean))].sort((left, right) =>
    left.localeCompare(right)
  );
}

function safeUniqueNumbers(values) {
  return [...new Set(normalizeIterable(values).map((entry) => Number(entry)).filter((entry) => Number.isInteger(entry) && entry > 0))].sort(
    (left, right) => left - right
  );
}

function normalizeIssueLabels(labels) {
  return safeUniqueStrings(
    ensureArray(labels).map((entry) => {
      if (typeof entry === 'string') {
        return entry;
      }
      if (typeof entry?.name === 'string') {
        return entry.name;
      }
      return '';
    })
  );
}

function normalizeCommentBodies(comments) {
  return ensureArray(comments)
    .map((entry) => {
      if (typeof entry === 'string') {
        return entry.trim();
      }
      return typeof entry?.body === 'string' ? entry.body.trim() : '';
    })
    .filter(Boolean);
}

function splitStandingClauses(value) {
  return String(value || '')
    .split(/[\n.;]+/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function hasAffirmativeExternalBlockClause(value) {
  return splitStandingClauses(value).some((clause) => {
    const hasAffirmativeBlockSignal =
      /\bexternally blocked on\b/i.test(clause) ||
      /\bblocked by\b/i.test(clause) ||
      /\bprimary downstream blocker\b/i.test(clause);
    if (!hasAffirmativeBlockSignal) {
      return false;
    }
    const hasNegatedOrHistoricalSignal =
      /\b(?:no longer|not|never|previously|formerly)\s+(?:externally blocked on|blocked by)\b/i.test(clause) ||
      /\b(?:was|were)\s+(?:externally blocked on|blocked by)\b/i.test(clause) ||
      /\b(?:no longer|not|never|previously|formerly)\b[^]{0,40}\bprimary downstream blocker\b/i.test(clause) ||
      /\b(?:was|were)\b[^]{0,40}\bprimary downstream blocker\b/i.test(clause);
    return !hasNegatedOrHistoricalSignal;
  });
}

function hasExplicitExternalOnlyTrackingSignal(value) {
  const lines = String(value || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  const getPreviousLines = (index, count = 2) => lines.slice(Math.max(0, index - count), index);
  const getNextLine = (index) => lines[index + 1] || '';

  return lines.some((line, index) => {
    const previousLines = getPreviousLines(index);
    const nextLine = getNextLine(index);
    const previousText = previousLines.join('\n');
    const hasCurrentStateSignal =
      /\bremains open only as local blocked tracking\b/i.test(line) ||
      /\bis blocked tracking,\s*not an active local standing lane\b/i.test(line) ||
      (/\bnot an active local standing lane\b/i.test(line) &&
        /\bdo not open a new in-repo coding lane here unless\b/i.test(nextLine)) ||
      (/\bdo not open a new in-repo coding lane here unless\b/i.test(line) &&
        /\bnot an active local standing lane\b/i.test(previousText));
    if (!hasCurrentStateSignal) {
      return false;
    }

    const hasHistoricalOrNegatedSignal =
      /\bhistorical note\b/i.test(line) ||
      /\bhistorical note\b/i.test(previousText) ||
      /\b(?:no longer|never|previously|formerly)\s+remains open only as local blocked tracking\b/i.test(line) ||
      /\b(?:was|were)\b[^]{0,60}\bopen only as local blocked tracking\b/i.test(line) ||
      /\b(?:was|were)\s+blocked tracking\b/i.test(line) ||
      /\b(?:no longer|never|previously|formerly)\s+blocked tracking\b/i.test(line) ||
      /\bnot blocked tracking\b/i.test(line) ||
      /\b(?:was|were)\b[^]{0,60}\bnot an active local standing lane\b/i.test(line) ||
      /\b(?:no longer|never|previously|formerly)\b[^]{0,60}\bnot an active local standing lane\b/i.test(line);

    return !hasHistoricalOrNegatedSignal;
  });
}

function hasExplicitExternalOnlyTrackingReactivationSignal(value) {
  const lines = String(value || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  return lines.some(
    (line) =>
      /\b(?:no longer|never|previously|formerly)\s+remains open only as local blocked tracking\b/i.test(line) ||
      /\brollout lane is active again\b/i.test(line) ||
      /\bactive local standing lane again\b/i.test(line) ||
      /\breactivat(?:ed|ion)\b/i.test(line)
  );
}

function classifyWindowClass(windowSummary = null) {
  const fundingPurpose = normalizeText(windowSummary?.fundingPurpose).toLowerCase();
  const selectionMode = normalizeText(windowSummary?.selectionMode ?? windowSummary?.selection?.mode).toLowerCase();
  if (fundingPurpose === 'calibration' || selectionMode === 'sticky-calibration') {
    return 'calibration';
  }
  if (fundingPurpose === 'operational') {
    return 'operational';
  }
  return 'unknown';
}

function classifySpendChannel(turn = null) {
  const executionPlane = normalizeText(turn?.executionPlane).toLowerCase();
  const agentRole = normalizeText(turn?.agentRole).toLowerCase();
  if (executionPlane === 'hosted') {
    return 'hosted-validation';
  }
  if (agentRole === 'live') {
    return 'live-agent';
  }
  if (agentRole === 'background') {
    return 'background-agent';
  }
  return 'unknown';
}

function normalizeIssueRecord(rawIssue = null) {
  const labels = normalizeIssueLabels(rawIssue?.labels);
  const commentBodies = normalizeCommentBodies(rawIssue?.commentBodies ?? rawIssue?.comments);
  const normalized = {
    number: coerceNonNegativeInteger(rawIssue?.number),
    title: normalizeText(rawIssue?.title) || null,
    state: normalizeText(rawIssue?.state).toLowerCase() || null,
    updatedAt: normalizeText(rawIssue?.updatedAt) || null,
    url: normalizeText(rawIssue?.url ?? rawIssue?.html_url) || null,
    labels,
    body: normalizeText(rawIssue?.body) || null,
    commentBodies
  };

  const labelSignal = labels.some((label) => /\b(blocked|external|dependency|upstream|waiting)\b/i.test(label));
  const textualSignal = [normalized.body, ...commentBodies]
    .filter(Boolean)
    .some((entry) => hasAffirmativeExternalBlockClause(entry) || hasExplicitExternalOnlyTrackingSignal(entry));
  const reactivated = [normalized.body, ...commentBodies].filter(Boolean).some(hasExplicitExternalOnlyTrackingReactivationSignal);

  let stateBucket = 'unknown';
  if (normalized.state === 'closed') {
    stateBucket = 'closed-completed';
  } else if (normalized.state === 'open' && (labelSignal || textualSignal) && !reactivated) {
    stateBucket = 'blocked-external';
  } else if (normalized.state === 'open') {
    stateBucket = 'open';
  }

  return {
    ...normalized,
    stateBucket
  };
}

function normalizeTurnTimestamp(turn = null) {
  return normalizeText(turn?.provenance?.usageObservedAt) || normalizeText(turn?.generatedAt) || null;
}

function normalizeInvoiceTurnReceipt(input = null) {
  const blockers = [];
  if (!input?.exists) {
    blockers.push(createBlocker('invoice-turn-missing', 'Invoice-turn receipt is missing.', input?.path ?? null));
    return { status: 'invalid', blockers, invoiceTurn: null };
  }
  if (input?.error) {
    blockers.push(createBlocker('invoice-turn-unreadable', `Invoice-turn receipt could not be parsed: ${input.error}`, input.path));
    return { status: 'invalid', blockers, invoiceTurn: null };
  }
  if (normalizeText(input?.payload?.schema) !== INVOICE_TURN_SCHEMA) {
    blockers.push(
      createBlocker(
        'invoice-turn-schema-mismatch',
        `Invoice-turn receipt schema must remain ${INVOICE_TURN_SCHEMA}.`,
        input.path
      )
    );
    return { status: 'invalid', blockers, invoiceTurn: null };
  }

  const payload = input.payload;
  const invoiceTurn = {
    sourcePath: input.path,
    synthetic: false,
    invoiceTurnId: normalizeText(payload.invoiceTurnId) || null,
    invoiceId: normalizeText(payload.invoiceId) || null,
    openedAt: normalizeText(payload.billingPeriod?.openedAt) || null,
    closedAt: normalizeText(payload.billingPeriod?.closedAt) || null,
    fundingPurpose: normalizeText(payload.policy?.fundingPurpose) || null,
    activationState: normalizeText(payload.policy?.activationState) || null,
    reconciliationStatus: normalizeText(payload.reconciliation?.status) || null,
    selectionMode: normalizeText(payload.selection?.mode) || 'hold',
    calibrationWindowId: normalizeText(payload.selection?.calibrationWindowId) || null,
    reconciledAt: normalizeText(payload.reconciliation?.reconciledAt) || null
  };
  invoiceTurn.windowClass = classifyWindowClass(invoiceTurn);
  return { status: 'valid', blockers, invoiceTurn };
}

function buildSyntheticBillingWindow(costRollup = null, costRollupInput = null) {
  const billingWindow = costRollup?.billingWindow && typeof costRollup.billingWindow === 'object' ? costRollup.billingWindow : null;
  if (!billingWindow) {
    return null;
  }
  const windowSummary = {
    sourcePath: costRollupInput?.path ?? null,
    synthetic: true,
    invoiceTurnId: normalizeText(billingWindow.invoiceTurnId) || 'current-billing-window',
    invoiceId: normalizeText(billingWindow.invoiceId) || null,
    openedAt: normalizeText(billingWindow.openedAt) || null,
    closedAt: normalizeText(billingWindow.closedAt) || null,
    fundingPurpose: normalizeText(billingWindow.fundingPurpose) || null,
    activationState: normalizeText(billingWindow.activationState) || null,
    reconciliationStatus: normalizeText(billingWindow.reconciliationStatus) || null,
    selectionMode: normalizeText(billingWindow.selection?.mode) || 'hold',
    calibrationWindowId: normalizeText(billingWindow.selection?.calibrationWindowId) || null,
    reconciledAt: normalizeText(billingWindow.reconciledAt) || null
  };
  windowSummary.windowClass = classifyWindowClass(windowSummary);
  return windowSummary;
}

function createWindowAccumulator(windowSummary, currentInvoiceTurnId) {
  const role =
    normalizeText(windowSummary.invoiceTurnId) && normalizeText(windowSummary.invoiceTurnId) === normalizeText(currentInvoiceTurnId)
      ? 'current-active'
      : windowSummary.windowClass === 'calibration'
        ? 'calibration'
        : windowSummary.windowClass === 'operational'
          ? 'trailing-operational'
          : 'historical';

  return {
    ...windowSummary,
    windowRole: role,
    allTurnUsd: 0,
    operatorLaborUsd: 0,
    operatorLaborMissingTurnCount: 0,
    issueAttributedUsd: 0,
    unattributedUsd: 0,
    exactUsd: 0,
    estimatedUsd: 0,
    turnCount: 0,
    attributedTurnCount: 0,
    unattributedTurnCount: 0,
    liveAgentUsd: 0,
    backgroundAgentUsd: 0,
    hostedValidationUsd: 0,
    issueNumbers: new Set(),
    issueMetrics: new Map(),
    firstTurnAt: null,
    lastTurnAt: null,
    rollingDistinctIssueCount: 0,
    rollingAverageUsdPerIssue: null
  };
}

function updateFirstLast(target, observedAt) {
  const observedTimestamp = toTimestamp(observedAt);
  if (observedTimestamp == null) {
    return;
  }
  if (!target.firstTurnAt || observedTimestamp < toTimestamp(target.firstTurnAt)) {
    target.firstTurnAt = new Date(observedTimestamp).toISOString();
  }
  if (!target.lastTurnAt || observedTimestamp > toTimestamp(target.lastTurnAt)) {
    target.lastTurnAt = new Date(observedTimestamp).toISOString();
  }
}

function createIssueAccumulator(issueNumber) {
  return {
    issueNumber,
    totalUsd: 0,
    operatorLaborUsd: 0,
    operatorLaborMissingTurnCount: 0,
    exactUsd: 0,
    estimatedUsd: 0,
    turnCount: 0,
    liveAgentUsd: 0,
    backgroundAgentUsd: 0,
    hostedValidationUsd: 0,
    firstTurnAt: null,
    lastTurnAt: null,
    windowIds: new Set(),
    turnIds: new Set(),
    turnSourcePaths: new Set(),
    sourceReceiptPaths: new Set(),
    sourceReportPaths: new Set(),
    invoiceTurnIds: new Set(),
    assignmentStrategies: new Set()
  };
}

function createWindowIssueAccumulator(issueNumber) {
  return {
    issueNumber,
    totalUsd: 0
  };
}

function updateSpendChannels(target, channel, amountUsd) {
  if (channel === 'live-agent') {
    target.liveAgentUsd += amountUsd;
  } else if (channel === 'background-agent') {
    target.backgroundAgentUsd += amountUsd;
  } else if (channel === 'hosted-validation') {
    target.hostedValidationUsd += amountUsd;
  }
}

function withinBillingWindow(turnTimestamp, window) {
  const observedTimestamp = toTimestamp(turnTimestamp);
  const openedTimestamp = toTimestamp(window?.openedAt);
  const closedTimestamp = toTimestamp(window?.closedAt);
  if (observedTimestamp == null || openedTimestamp == null) {
    return false;
  }
  if (observedTimestamp < openedTimestamp) {
    return false;
  }
  if (closedTimestamp != null && observedTimestamp > closedTimestamp) {
    return false;
  }
  return true;
}

function compareWindowPriority(left, right) {
  const leftOpened = toTimestamp(left?.openedAt) ?? 0;
  const rightOpened = toTimestamp(right?.openedAt) ?? 0;
  if (rightOpened !== leftOpened) {
    return rightOpened - leftOpened;
  }
  return normalizeText(right?.invoiceTurnId).localeCompare(normalizeText(left?.invoiceTurnId));
}

function assignTurnToWindow(turn, windows, currentInvoiceTurnId) {
  const steeringInvoiceTurnId = normalizeText(turn?.steeringInvoiceTurnId);
  if (steeringInvoiceTurnId) {
    const explicitWindow = windows.find((entry) => normalizeText(entry.invoiceTurnId) === steeringInvoiceTurnId);
    if (explicitWindow) {
      return { window: explicitWindow, assignmentStrategy: 'steering-invoice-turn' };
    }
  }

  const turnTimestamp = normalizeTurnTimestamp(turn);
  const matchingWindows = windows.filter((entry) => withinBillingWindow(turnTimestamp, entry)).sort(compareWindowPriority);
  if (matchingWindows.length === 1) {
    return { window: matchingWindows[0], assignmentStrategy: 'timestamp-match' };
  }
  if (matchingWindows.length > 1) {
    const selectedCurrent = matchingWindows.find((entry) => normalizeText(entry.invoiceTurnId) === normalizeText(currentInvoiceTurnId));
    if (selectedCurrent) {
      return { window: selectedCurrent, assignmentStrategy: 'billing-window-selected' };
    }
    return { window: matchingWindows[0], assignmentStrategy: 'latest-opened-window' };
  }
  if (windows.length === 1) {
    return { window: windows[0], assignmentStrategy: 'single-window-fallback' };
  }
  const selectedCurrent = windows.find((entry) => normalizeText(entry.invoiceTurnId) === normalizeText(currentInvoiceTurnId));
  if (selectedCurrent) {
    return { window: selectedCurrent, assignmentStrategy: 'billing-window-fallback' };
  }
  return { window: null, assignmentStrategy: 'unattributed' };
}

function summarizeIssueStateAverages(issueEntries) {
  const buckets = new Map();
  for (const entry of issueEntries) {
    const bucketKey = entry.stateBucket || 'unknown';
    if (!buckets.has(bucketKey)) {
      buckets.set(bucketKey, { stateBucket: bucketKey, issueCount: 0, totalUsd: 0 });
    }
    const bucket = buckets.get(bucketKey);
    bucket.issueCount += 1;
    bucket.totalUsd += entry.totalUsd;
  }
  return [...buckets.values()]
    .sort((left, right) => left.stateBucket.localeCompare(right.stateBucket))
    .map((entry) => ({
      stateBucket: entry.stateBucket,
      issueCount: entry.issueCount,
      totalUsd: roundNumber(entry.totalUsd) ?? 0,
      averageUsdPerIssue: computeAverage(entry.totalUsd, entry.issueCount)
    }));
}

async function hydrateIssues({ issueNumbers, repoRoot, repository, fetchIssueFn }) {
  if (!issueNumbers.length) {
    return {
      status: 'skipped',
      attempted: false,
      stateAttributionBasis: 'unavailable',
      hydratedIssueCount: 0,
      failedIssueNumbers: [],
      warnings: [],
      records: new Map()
    };
  }

  const records = new Map();
  const failedIssueNumbers = [];
  const warnings = [];

  await Promise.all(
    issueNumbers.map(async (issueNumber) => {
      try {
        const rawIssue = await fetchIssueFn(issueNumber, repoRoot, repository);
        records.set(issueNumber, normalizeIssueRecord(rawIssue));
      } catch (error) {
        failedIssueNumbers.push(issueNumber);
        warnings.push(
          createWarning(
            'issue-hydration-failed',
            `Issue #${issueNumber} could not be hydrated for state bucketing: ${error.message || error}`,
            issueNumber
          )
        );
      }
    })
  );

  failedIssueNumbers.sort((left, right) => left - right);
  warnings.sort((left, right) => (left.issueNumber ?? 0) - (right.issueNumber ?? 0));

  return {
    status: failedIssueNumbers.length > 0 ? 'warn' : 'pass',
    attempted: true,
    stateAttributionBasis: records.size > 0 ? 'current-issue-snapshot' : 'unavailable',
    hydratedIssueCount: records.size,
    failedIssueNumbers,
    warnings,
    records
  };
}

function buildIssueEntry(issueAccumulator, issueRecord, windowIds) {
  return {
    issueNumber: issueAccumulator.issueNumber,
    title: issueRecord?.title ?? null,
    url: issueRecord?.url ?? null,
    state: issueRecord?.state ?? null,
    stateBucket: issueRecord?.stateBucket ?? 'unknown',
    stateSnapshotUpdatedAt: issueRecord?.updatedAt ?? null,
    totalUsd: roundNumber(issueAccumulator.totalUsd) ?? 0,
    operatorLaborUsd: roundNumber(issueAccumulator.operatorLaborUsd) ?? 0,
    operatorLaborMissingTurnCount: issueAccumulator.operatorLaborMissingTurnCount,
    blendedTotalUsd:
      issueAccumulator.operatorLaborMissingTurnCount === 0
        ? roundNumber(issueAccumulator.totalUsd + issueAccumulator.operatorLaborUsd)
        : null,
    exactUsd: roundNumber(issueAccumulator.exactUsd) ?? 0,
    estimatedUsd: roundNumber(issueAccumulator.estimatedUsd) ?? 0,
    turnCount: issueAccumulator.turnCount,
    liveAgentUsd: roundNumber(issueAccumulator.liveAgentUsd) ?? 0,
    backgroundAgentUsd: roundNumber(issueAccumulator.backgroundAgentUsd) ?? 0,
    hostedValidationUsd: roundNumber(issueAccumulator.hostedValidationUsd) ?? 0,
    firstTurnAt: issueAccumulator.firstTurnAt,
    lastTurnAt: issueAccumulator.lastTurnAt,
    windowIds,
    provenance: {
      turnIds: safeUniqueStrings(issueAccumulator.turnIds),
      turnSourcePaths: safeUniqueStrings(issueAccumulator.turnSourcePaths),
      sourceReceiptPaths: safeUniqueStrings(issueAccumulator.sourceReceiptPaths),
      sourceReportPaths: safeUniqueStrings(issueAccumulator.sourceReportPaths),
      invoiceTurnIds: safeUniqueStrings(issueAccumulator.invoiceTurnIds),
      assignmentStrategies: safeUniqueStrings(issueAccumulator.assignmentStrategies)
    }
  };
}

function sortWindowsByTime(left, right) {
  const leftOpened = toTimestamp(left?.openedAt) ?? 0;
  const rightOpened = toTimestamp(right?.openedAt) ?? 0;
  if (leftOpened !== rightOpened) {
    return leftOpened - rightOpened;
  }
  return normalizeText(left?.invoiceTurnId).localeCompare(normalizeText(right?.invoiceTurnId));
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    costRollupPath: DEFAULT_COST_ROLLUP_PATH,
    invoiceTurnPaths: [],
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--cost-rollup' || token === '--invoice-turn' || token === '--output' || token === '--repo') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--invoice-turn') options.invoiceTurnPaths.push(next);
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function resolveInvoiceTurnPaths({ explicitInvoiceTurnPaths, costRollup, repoRoot = REPO_ROOT }) {
  const explicitPaths = safeUniqueStrings(explicitInvoiceTurnPaths.map((entry) => resolvePathCandidate(entry, repoRoot)));
  if (explicitPaths.length > 0) {
    return explicitPaths;
  }
  const inputPaths = safeUniqueStrings(
    ensureArray(costRollup?.inputs?.invoiceTurnPaths)
      .map((entry) => resolvePathCandidate(entry?.path, repoRoot))
      .filter(Boolean)
  );
  if (inputPaths.length > 0) {
    return inputPaths;
  }
  return discoverJsonPaths(resolvePathCandidate(DEFAULT_INVOICE_TURN_DIR, repoRoot));
}

export async function buildAverageIssueCostScorecard({
  repository = null,
  costRollup = null,
  costRollupInput = null,
  invoiceTurnInputs = [],
  now = new Date(),
  fetchIssueFn = async (issueNumber, repoRoot, repoSlug) => fetchIssue(issueNumber, repoRoot, repoSlug),
  repoRoot = REPO_ROOT
} = {}) {
  const blockers = [];

  if (costRollupInput?.exists === false) {
    blockers.push(
      createBlocker(
        'cost-rollup-missing',
        'Agent cost rollup is missing, so average issue cost cannot be derived from funding windows.',
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

  const turns = ensureArray(costRollup?.turns).filter((entry) => entry && typeof entry === 'object');
  const currentBillingWindowId = normalizeText(costRollup?.billingWindow?.invoiceTurnId) || null;
  if (costRollup?.billingWindow == null) {
    blockers.push(
      createBlocker(
        'billing-window-missing',
        'Agent cost rollup billingWindow is required so average issue cost stays tied to a funding window.',
        costRollupInput?.path ?? null
      )
    );
  }

  const normalizedInvoiceTurnResults = invoiceTurnInputs.map((input) => normalizeInvoiceTurnReceipt(input));
  for (const normalized of normalizedInvoiceTurnResults) {
    blockers.push(...ensureArray(normalized.blockers));
  }

  const validInvoiceTurns = normalizedInvoiceTurnResults
    .filter((entry) => entry.status === 'valid' && entry.invoiceTurn)
    .map((entry) => entry.invoiceTurn)
    .sort(sortWindowsByTime);

  const reasons = [];
  const effectiveInvoiceTurns =
    validInvoiceTurns.length > 0 ? validInvoiceTurns : [buildSyntheticBillingWindow(costRollup, costRollupInput)].filter(Boolean);

  if (validInvoiceTurns.length === 0 && effectiveInvoiceTurns.length > 0) {
    reasons.push('invoice-turn-receipts-missing');
  }
  if (effectiveInvoiceTurns.length <= 1 && turns.length > 0) {
    reasons.push('single-window-coverage');
  }

  const windowAccumulators = effectiveInvoiceTurns.map((entry) => createWindowAccumulator(entry, currentBillingWindowId));
  const issueAccumulators = new Map();
  const unattributedTurns = [];
  const issuelessTurns = [];

  for (const turn of turns) {
    const amountUsd = coerceNonNegativeNumber(turn.amountUsd) ?? 0;
    const exactness = normalizeText(turn.exactness).toLowerCase();
    const observedAt = normalizeTurnTimestamp(turn);
    const spendChannel = classifySpendChannel(turn);
    const issueNumber = coerceNonNegativeInteger(turn.issueNumber);
    const assignment = assignTurnToWindow(turn, windowAccumulators, currentBillingWindowId);
    const windowAccumulator = assignment.window;

    if (!windowAccumulator) {
      unattributedTurns.push(turn);
      continue;
    }

    windowAccumulator.allTurnUsd += amountUsd;
    if (coerceNonNegativeNumber(turn.operatorLaborUsd) != null) {
      windowAccumulator.operatorLaborUsd += coerceNonNegativeNumber(turn.operatorLaborUsd);
    } else {
      windowAccumulator.operatorLaborMissingTurnCount += 1;
    }
    windowAccumulator.turnCount += 1;
    if (exactness === 'exact') {
      windowAccumulator.exactUsd += amountUsd;
    } else {
      windowAccumulator.estimatedUsd += amountUsd;
    }
    updateSpendChannels(windowAccumulator, spendChannel, amountUsd);
    updateFirstLast(windowAccumulator, observedAt);

    if (issueNumber == null) {
      issuelessTurns.push(turn);
      windowAccumulator.unattributedUsd += amountUsd;
      windowAccumulator.unattributedTurnCount += 1;
      continue;
    }

    windowAccumulator.issueAttributedUsd += amountUsd;
    windowAccumulator.attributedTurnCount += 1;
    windowAccumulator.issueNumbers.add(issueNumber);

    if (!windowAccumulator.issueMetrics.has(issueNumber)) {
      windowAccumulator.issueMetrics.set(issueNumber, createWindowIssueAccumulator(issueNumber));
    }
    windowAccumulator.issueMetrics.get(issueNumber).totalUsd += amountUsd;

    if (!issueAccumulators.has(issueNumber)) {
      issueAccumulators.set(issueNumber, createIssueAccumulator(issueNumber));
    }
    const issueAccumulator = issueAccumulators.get(issueNumber);
    issueAccumulator.totalUsd += amountUsd;
    if (coerceNonNegativeNumber(turn.operatorLaborUsd) != null) {
      issueAccumulator.operatorLaborUsd += coerceNonNegativeNumber(turn.operatorLaborUsd);
    } else {
      issueAccumulator.operatorLaborMissingTurnCount += 1;
    }
    issueAccumulator.turnCount += 1;
    if (exactness === 'exact') {
      issueAccumulator.exactUsd += amountUsd;
    } else {
      issueAccumulator.estimatedUsd += amountUsd;
    }
    updateSpendChannels(issueAccumulator, spendChannel, amountUsd);
    updateFirstLast(issueAccumulator, observedAt);
    if (normalizeText(windowAccumulator.invoiceTurnId)) {
      issueAccumulator.windowIds.add(windowAccumulator.invoiceTurnId);
      issueAccumulator.invoiceTurnIds.add(windowAccumulator.invoiceTurnId);
    }
    if (normalizeText(turn.turnId)) {
      issueAccumulator.turnIds.add(turn.turnId);
    }
    if (normalizeText(turn.sourcePath)) {
      issueAccumulator.turnSourcePaths.add(turn.sourcePath);
    }
    if (normalizeText(turn?.provenance?.sourceReceiptPath)) {
      issueAccumulator.sourceReceiptPaths.add(turn.provenance.sourceReceiptPath);
    }
    if (normalizeText(turn?.provenance?.sourceReportPath)) {
      issueAccumulator.sourceReportPaths.add(turn.provenance.sourceReportPath);
    }
    issueAccumulator.assignmentStrategies.add(assignment.assignmentStrategy);
  }

  if (unattributedTurns.length > 0 || issuelessTurns.length > 0) {
    reasons.push('unattributed-turns-present');
  }
  if (turns.length === 0) {
    reasons.push('no-cost-turns-observed');
  }

  const issueNumbers = safeUniqueNumbers([...issueAccumulators.keys()]);
  const issueHydration = await hydrateIssues({
    issueNumbers,
    repoRoot,
    repository,
    fetchIssueFn
  });

  if (issueHydration.status === 'warn') {
    reasons.push('issue-state-hydration-incomplete');
  }

  const issueEntries = issueNumbers.map((issueNumber) => {
    const issueAccumulator = issueAccumulators.get(issueNumber);
    const issueRecord = issueHydration.records.get(issueNumber) ?? null;
    return buildIssueEntry(issueAccumulator, issueRecord, safeUniqueStrings(issueAccumulator.windowIds));
  });

  const issueEntryByNumber = new Map(issueEntries.map((entry) => [entry.issueNumber, entry]));

  const sortedWindowAccumulators = [...windowAccumulators].sort(sortWindowsByTime);
  const rollingIssueNumbers = new Set();
  let rollingIssueAttributedUsd = 0;

  const windowEntries = sortedWindowAccumulators.map((windowAccumulator) => {
    for (const issueNumber of windowAccumulator.issueNumbers) {
      rollingIssueNumbers.add(issueNumber);
    }
    rollingIssueAttributedUsd += windowAccumulator.issueAttributedUsd;
    windowAccumulator.rollingDistinctIssueCount = rollingIssueNumbers.size;
    windowAccumulator.rollingAverageUsdPerIssue = computeAverage(rollingIssueAttributedUsd, rollingIssueNumbers.size);

    const stateIssueEntries = [...windowAccumulator.issueMetrics.values()]
      .map((entry) => {
        const issueRecord = issueEntryByNumber.get(entry.issueNumber);
        return {
          issueNumber: entry.issueNumber,
          stateBucket: issueRecord?.stateBucket ?? 'unknown',
          totalUsd: entry.totalUsd
        };
      })
      .sort((left, right) => left.issueNumber - right.issueNumber);

    return {
      sourcePath: windowAccumulator.sourcePath,
      synthetic: windowAccumulator.synthetic === true,
      invoiceTurnId: windowAccumulator.invoiceTurnId,
      invoiceId: windowAccumulator.invoiceId,
      openedAt: windowAccumulator.openedAt,
      closedAt: windowAccumulator.closedAt,
      fundingPurpose: windowAccumulator.fundingPurpose,
      activationState: windowAccumulator.activationState,
      windowClass: windowAccumulator.windowClass,
      windowRole: windowAccumulator.windowRole,
      reconciliationStatus: windowAccumulator.reconciliationStatus,
      selectionMode: windowAccumulator.selectionMode,
      calibrationWindowId: windowAccumulator.calibrationWindowId,
      reconciledAt: windowAccumulator.reconciledAt,
      issueNumbers: safeUniqueNumbers(windowAccumulator.issueNumbers),
      issueStateAverages: summarizeIssueStateAverages(stateIssueEntries),
      metrics: {
        totalUsd: roundNumber(windowAccumulator.allTurnUsd) ?? 0,
        operatorLaborUsd: roundNumber(windowAccumulator.operatorLaborUsd) ?? 0,
        operatorLaborMissingTurnCount: windowAccumulator.operatorLaborMissingTurnCount,
        blendedTotalUsd:
          windowAccumulator.operatorLaborMissingTurnCount === 0
            ? roundNumber(windowAccumulator.allTurnUsd + windowAccumulator.operatorLaborUsd)
            : null,
        issueAttributedUsd: roundNumber(windowAccumulator.issueAttributedUsd) ?? 0,
        unattributedUsd: roundNumber(windowAccumulator.unattributedUsd) ?? 0,
        exactUsd: roundNumber(windowAccumulator.exactUsd) ?? 0,
        estimatedUsd: roundNumber(windowAccumulator.estimatedUsd) ?? 0,
        turnCount: windowAccumulator.turnCount,
        attributedTurnCount: windowAccumulator.attributedTurnCount,
        unattributedTurnCount: windowAccumulator.unattributedTurnCount,
        distinctIssueCount: windowAccumulator.issueNumbers.size,
        averageUsdPerIssue: computeAverage(windowAccumulator.issueAttributedUsd, windowAccumulator.issueNumbers.size),
        liveAgentUsd: roundNumber(windowAccumulator.liveAgentUsd) ?? 0,
        backgroundAgentUsd: roundNumber(windowAccumulator.backgroundAgentUsd) ?? 0,
        hostedValidationUsd: roundNumber(windowAccumulator.hostedValidationUsd) ?? 0,
        firstTurnAt: windowAccumulator.firstTurnAt,
        lastTurnAt: windowAccumulator.lastTurnAt,
        rollingDistinctIssueCount: windowAccumulator.rollingDistinctIssueCount,
        rollingAverageUsdPerIssue: windowAccumulator.rollingAverageUsdPerIssue
      }
    };
  });

  const stateAverages = summarizeIssueStateAverages(issueEntries);

  const totalUsd = roundNumber(turns.reduce((sumValue, turn) => sumValue + (coerceNonNegativeNumber(turn.amountUsd) ?? 0), 0)) ?? 0;
  const operatorLaborUsd = roundNumber(
    turns.reduce((sumValue, turn) => sumValue + (coerceNonNegativeNumber(turn.operatorLaborUsd) ?? 0), 0)
  ) ?? 0;
  const operatorLaborMissingTurnCount = turns.filter((turn) => coerceNonNegativeNumber(turn.operatorLaborUsd) == null).length;
  const issueAttributedUsd = roundNumber(issueEntries.reduce((sumValue, entry) => sumValue + entry.totalUsd, 0)) ?? 0;
  const exactUsd = roundNumber(issueEntries.reduce((sumValue, entry) => sumValue + entry.exactUsd, 0)) ?? 0;
  const estimatedUsd = roundNumber(issueEntries.reduce((sumValue, entry) => sumValue + entry.estimatedUsd, 0)) ?? 0;
  const unattributedUsd = roundNumber(Math.max(totalUsd - issueAttributedUsd, 0)) ?? 0;
  const liveAgentUsd = roundNumber(sortedWindowAccumulators.reduce((sumValue, entry) => sumValue + entry.liveAgentUsd, 0)) ?? 0;
  const backgroundAgentUsd = roundNumber(sortedWindowAccumulators.reduce((sumValue, entry) => sumValue + entry.backgroundAgentUsd, 0)) ?? 0;
  const hostedValidationUsd = roundNumber(sortedWindowAccumulators.reduce((sumValue, entry) => sumValue + entry.hostedValidationUsd, 0)) ?? 0;

  const currentActiveWindow = windowEntries.find((entry) => entry.windowRole === 'current-active') ?? null;
  const activeCalibrationWindow =
    windowEntries.find((entry) => entry.windowClass === 'calibration' && normalizeText(entry.activationState).toLowerCase() === 'active') ?? null;
  const latestTrailingOperationalWindow =
    [...windowEntries]
      .filter((entry) => entry.windowRole === 'trailing-operational')
      .sort((left, right) => sortWindowsByTime(right, left))[0] ?? null;

  if (estimatedUsd > 0) {
    reasons.push('estimated-spend-present');
  }

  const uniqueReasons = safeUniqueStrings(reasons);
  const status = blockers.length > 0 ? 'fail' : uniqueReasons.length > 0 ? 'warn' : 'pass';
  let recommendation = 'benchmark-average-issue-cost';
  if (blockers.length > 0) {
    recommendation = 'repair-input-receipts';
  } else if (uniqueReasons.includes('no-cost-turns-observed')) {
    recommendation = 'continue-observing-funding-windows';
  } else if (uniqueReasons.includes('issue-state-hydration-incomplete')) {
    recommendation = 'refresh-issue-state-hydration';
  } else if (uniqueReasons.includes('unattributed-turns-present')) {
    recommendation = 'tighten-issue-attribution';
  } else if (uniqueReasons.includes('estimated-spend-present')) {
    recommendation = 'continue-estimated-telemetry';
  }

  return {
    schema: REPORT_SCHEMA,
    generatedAt: toIso(now),
    repository,
    inputs: {
      costRollupPath: normalizeInputRef(costRollupInput),
      invoiceTurnPaths: invoiceTurnInputs.map((entry) => normalizeInputRef(entry))
    },
    coverage: {
      implementedMetricCodes: IMPLEMENTED_METRIC_CODES,
      deferredMetrics: DEFERRED_METRICS
    },
    issueHydration: {
      status: issueHydration.status,
      attempted: issueHydration.attempted,
      stateAttributionBasis: issueHydration.stateAttributionBasis,
      hydratedIssueCount: issueHydration.hydratedIssueCount,
      failedIssueNumbers: issueHydration.failedIssueNumbers,
      warnings: issueHydration.warnings
    },
    summary: {
      status,
      recommendation,
      reasons: uniqueReasons,
      blockerCount: blockers.length,
      blockers,
      metrics: {
        observedFundingWindowCount: windowEntries.length,
        distinctIssueCount: issueEntries.length,
        totalUsd,
        operatorLaborUsd,
        operatorLaborMissingTurnCount,
        blendedTotalUsd:
          operatorLaborMissingTurnCount === 0
            ? roundNumber(totalUsd + operatorLaborUsd)
            : null,
        issueAttributedUsd,
        unattributedUsd,
        exactUsd,
        estimatedUsd,
        liveAgentUsd,
        backgroundAgentUsd,
        hostedValidationUsd,
        rollingAverageUsdPerIssue: computeAverage(issueAttributedUsd, issueEntries.length),
        rollingAverageBlendedUsdPerIssue:
          operatorLaborMissingTurnCount === 0
            ? computeAverage(totalUsd + operatorLaborUsd, issueEntries.length)
            : null,
        currentActiveWindowAverageUsdPerIssue: currentActiveWindow?.metrics?.averageUsdPerIssue ?? null,
        currentActiveWindowAverageBlendedUsdPerIssue: currentActiveWindow?.metrics?.blendedTotalUsd != null
          ? computeAverage(currentActiveWindow.metrics.blendedTotalUsd, currentActiveWindow.metrics.distinctIssueCount)
          : null,
        activeCalibrationWindowAverageUsdPerIssue: activeCalibrationWindow?.metrics?.averageUsdPerIssue ?? null,
        activeCalibrationWindowAverageBlendedUsdPerIssue: activeCalibrationWindow?.metrics?.blendedTotalUsd != null
          ? computeAverage(activeCalibrationWindow.metrics.blendedTotalUsd, activeCalibrationWindow.metrics.distinctIssueCount)
          : null,
        latestTrailingOperationalWindowAverageUsdPerIssue: latestTrailingOperationalWindow?.metrics?.averageUsdPerIssue ?? null,
        latestTrailingOperationalWindowAverageBlendedUsdPerIssue: latestTrailingOperationalWindow?.metrics?.blendedTotalUsd != null
          ? computeAverage(latestTrailingOperationalWindow.metrics.blendedTotalUsd, latestTrailingOperationalWindow.metrics.distinctIssueCount)
          : null,
        unattributedTurnCount: issuelessTurns.length + unattributedTurns.length
      }
    },
    stateAverages,
    windows: windowEntries,
    issues: issueEntries
  };
}

export async function runAverageIssueCostScorecard(options = {}) {
  const repoRoot = path.resolve(options.repoRoot ?? REPO_ROOT);
  const costRollupInput = loadJsonInput(resolvePathCandidate(options.costRollupPath ?? DEFAULT_COST_ROLLUP_PATH, repoRoot));
  const invoiceTurnPaths = resolveInvoiceTurnPaths({
    explicitInvoiceTurnPaths: ensureArray(options.invoiceTurnPaths),
    costRollup: costRollupInput.payload,
    repoRoot
  });
  const invoiceTurnInputs = invoiceTurnPaths.map((filePath) => loadJsonInput(filePath));
  const repository = resolveRepoSlug(options.repo, costRollupInput.payload?.repository);
  const report = await buildAverageIssueCostScorecard({
    repository,
    costRollup: costRollupInput.payload,
    costRollupInput,
    invoiceTurnInputs,
    now: options.now ?? new Date(),
    fetchIssueFn: options.fetchIssueFn,
    repoRoot
  });
  const outputPath = path.resolve(repoRoot, options.outputPath ?? DEFAULT_OUTPUT_PATH);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return { outputPath, report };
}

async function main() {
  const options = parseArgs(process.argv);
  if (options.help) {
    printHelp();
    return;
  }
  const result = await runAverageIssueCostScorecard(options);
  console.log(
    `[average-issue-cost-scorecard] report: ${result.outputPath} status=${result.report.summary.status} rollingAverage=${result.report.summary.metrics.rollingAverageUsdPerIssue ?? 'n/a'}`
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
    console.error(`[average-issue-cost-scorecard] ${error.message || error}`);
    process.exitCode = 1;
  }
}

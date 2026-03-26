#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { runAgentCostInvoiceNormalize } from './agent-cost-invoice-normalize.mjs';
import { runAgentCostUsageExportNormalize } from './agent-cost-usage-export-normalize.mjs';

export const REPORT_SCHEMA = 'priority/treasury-ledger@v1';
export const DEFAULT_RUNTIME_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'capital', 'treasury-ledger.json');
export const DEFAULT_HANDOFF_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'handoff', 'treasury-ledger.json');
export const DEFAULT_COST_ROLLUP_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_OPERATOR_STEERING_EVENT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'operator-steering-event.json');
export const DEFAULT_INVOICE_OUTPUT_DIR = path.join('tests', 'results', '_agent', 'cost', 'invoice-turns');
export const DEFAULT_USAGE_OUTPUT_DIR = path.join('tests', 'results', '_agent', 'cost', 'usage-exports');

const MONTH_INDEX = new Map([
  ['jan', 1],
  ['january', 1],
  ['feb', 2],
  ['february', 2],
  ['mar', 3],
  ['march', 3],
  ['apr', 4],
  ['april', 4],
  ['may', 5],
  ['jun', 6],
  ['june', 6],
  ['jul', 7],
  ['july', 7],
  ['aug', 8],
  ['august', 8],
  ['sep', 9],
  ['sept', 9],
  ['september', 9],
  ['oct', 10],
  ['october', 10],
  ['nov', 11],
  ['november', 11],
  ['dec', 12],
  ['december', 12]
]);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toNonNegativeNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Number(parsed.toFixed(6)) : null;
}

function resolvePathOrNull(filePath) {
  const normalized = normalizeText(filePath);
  return normalized ? path.resolve(normalized) : null;
}

function resolveRepoPath(repoRoot, filePath) {
  const normalized = normalizeText(filePath);
  return normalized ? path.resolve(repoRoot, normalized) : null;
}

function ensureDirectoryForFile(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function loadJsonFile(filePath) {
  const resolvedPath = resolvePathOrNull(filePath);
  if (!resolvedPath) {
    return { exists: false, path: null, payload: null, error: null };
  }
  if (!fs.existsSync(resolvedPath)) {
    return { exists: false, path: resolvedPath, payload: null, error: null };
  }
  try {
    return {
      exists: true,
      path: resolvedPath,
      payload: readJson(resolvedPath),
      error: null
    };
  } catch (error) {
    return {
      exists: true,
      path: resolvedPath,
      payload: null,
      error: error?.message || String(error)
    };
  }
}

function writeJson(filePath, payload) {
  ensureDirectoryForFile(filePath);
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function sanitizeStem(value) {
  return normalizeText(value)
    .replace(/\.[^.]+$/, '')
    .replace(/[^A-Za-z0-9._-]+/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_+|_+$/g, '')
    .toLowerCase();
}

function inferInvoiceId(payload) {
  const explicit = normalizeText(payload?.invoiceId);
  if (explicit) {
    return explicit;
  }
  const sourcePath = normalizeText(payload?.sourcePath);
  if (!sourcePath) {
    return null;
  }
  const basename = path.basename(sourcePath);
  const match = basename.match(/Invoice-([^.]+)\.pdf$/i);
  return match?.[1] || null;
}

function deriveDefaultInvoiceOutputPath(repoRoot, metadataPayload) {
  const invoiceId = inferInvoiceId(metadataPayload) || 'local-invoice';
  return path.resolve(repoRoot, DEFAULT_INVOICE_OUTPUT_DIR, `${invoiceId}.local.json`);
}

function deriveDefaultUsageOutputPath(repoRoot, csvPath) {
  const stem = sanitizeStem(path.basename(normalizeText(csvPath))) || 'usage-export-local';
  return path.resolve(repoRoot, DEFAULT_USAGE_OUTPUT_DIR, `${stem}.json`);
}

function createMessage(code, message, pathValue = null) {
  return { code, message, path: pathValue };
}

function parseIsoDateParts(isoDate) {
  const normalized = normalizeText(isoDate);
  const match = normalized.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) {
    return null;
  }
  return {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3])
  };
}

function monthFromLabel(label) {
  return MONTH_INDEX.get(normalizeText(label).toLowerCase()) || null;
}

function parseDeclaredFileRange(filePath) {
  const basename = path.basename(normalizeText(filePath));
  if (!basename) {
    return null;
  }
  const match = basename.match(/\((?<startMonth>[A-Za-z]+)\s+(?<startDay>\d{1,2})\s*-\s*(?<endMonth>[A-Za-z]+)\s+(?<endDay>\d{1,2})\)(?:\s+\(\d+\))?\.csv$/i);
  if (!match?.groups) {
    return null;
  }
  const startMonth = monthFromLabel(match.groups.startMonth);
  const endMonth = monthFromLabel(match.groups.endMonth);
  const startDay = Number(match.groups.startDay);
  const endDay = Number(match.groups.endDay);
  if (!startMonth || !endMonth || !Number.isInteger(startDay) || !Number.isInteger(endDay)) {
    return null;
  }
  return {
    startLabel: `${match.groups.startMonth} ${startDay}`,
    endLabel: `${match.groups.endMonth} ${endDay}`,
    startMonth,
    startDay,
    endMonth,
    endDay
  };
}

function extractInvoiceTurn(receipt) {
  if (!receipt || normalizeText(receipt.schema) !== 'priority/agent-cost-invoice-turn@v1') {
    return null;
  }
  return {
    invoiceTurnId: normalizeText(receipt.invoiceTurnId) || null,
    invoiceId: normalizeText(receipt.invoiceId) || null,
    openedAt: normalizeText(receipt?.billingPeriod?.openedAt) || null,
    closedAt: normalizeText(receipt?.billingPeriod?.closedAt) || null,
    creditsPurchased: toNonNegativeNumber(receipt?.credits?.purchased),
    unitPriceUsd: toNonNegativeNumber(receipt?.credits?.unitPriceUsd),
    prepaidUsd: toNonNegativeNumber(receipt?.billing?.prepaidUsd),
    pricingBasis: normalizeText(receipt?.billing?.pricingBasis) || null,
    activationState: normalizeText(receipt?.policy?.activationState) || null,
    fundingPurpose: normalizeText(receipt?.policy?.fundingPurpose) || null,
    sourceKind: normalizeText(receipt?.provenance?.sourceKind) || null,
    sourcePathEvidence: normalizeText(receipt?.provenance?.sourcePath) || null,
    operatorNote: normalizeText(receipt?.provenance?.operatorNote) || null,
    generatedAt: normalizeText(receipt.generatedAt) || null
  };
}

function extractUsageExport(receipt) {
  if (!receipt || normalizeText(receipt.schema) !== 'priority/agent-cost-usage-export@v1') {
    return null;
  }
  return {
    normalizedUsageExportPath: null,
    sourcePathEvidence: normalizeText(receipt.sourcePathEvidence) || normalizeText(receipt?.provenance?.sourcePathEvidence) || null,
    startDate: normalizeText(receipt?.reportWindow?.startDate) || null,
    endDate: normalizeText(receipt?.reportWindow?.endDate) || null,
    usageCredits: toNonNegativeNumber(receipt?.totals?.usageCredits),
    usageQuantity: toNonNegativeNumber(receipt?.totals?.usageQuantity)
  };
}

function selectFundingWindow(normalizedInvoiceTurn, costRollup) {
  if (normalizedInvoiceTurn) {
    return {
      status: 'selected',
      source: 'normalized-invoice-turn',
      invoiceTurnId: normalizedInvoiceTurn.invoiceTurnId,
      invoiceId: normalizedInvoiceTurn.invoiceId,
      openedAt: normalizedInvoiceTurn.openedAt,
      activationState: normalizedInvoiceTurn.activationState,
      fundingPurpose: normalizedInvoiceTurn.fundingPurpose
    };
  }
  const billingWindow = costRollup?.billingWindow;
  if (billingWindow) {
    return {
      status: 'selected',
      source: 'agent-cost-rollup',
      invoiceTurnId: normalizeText(billingWindow.invoiceTurnId) || null,
      invoiceId: normalizeText(billingWindow.invoiceId) || null,
      openedAt: normalizeText(billingWindow.openedAt) || null,
      activationState: normalizeText(billingWindow.activationState) || null,
      fundingPurpose: normalizeText(billingWindow.fundingPurpose) || null
    };
  }
  return {
    status: 'missing',
    source: null,
    invoiceTurnId: null,
    invoiceId: null,
    openedAt: null,
    activationState: null,
    fundingPurpose: null
  };
}

function buildReplenishmentEvent(invoiceTurn, invoicePath) {
  if (!invoiceTurn) {
    return {
      status: 'missing',
      observedAt: null,
      sourceKind: null,
      reason: 'normalized invoice turn unavailable',
      invoiceTurnId: null,
      invoiceId: null,
      openedAt: null,
      creditsPurchased: null,
      prepaidUsd: null,
      activationState: null,
      fundingPurpose: null,
      sourcePathEvidence: null
    };
  }
  return {
    status: 'observed',
    observedAt: invoiceTurn.generatedAt || invoiceTurn.openedAt,
    sourceKind: invoiceTurn.sourceKind || 'normalized-invoice-turn',
    reason: 'normalized local invoice metadata established the replenishment window',
    invoiceTurnId: invoiceTurn.invoiceTurnId,
    invoiceId: invoiceTurn.invoiceId,
    openedAt: invoiceTurn.openedAt,
    creditsPurchased: invoiceTurn.creditsPurchased,
    prepaidUsd: invoiceTurn.prepaidUsd,
    activationState: invoiceTurn.activationState,
    fundingPurpose: invoiceTurn.fundingPurpose,
    sourcePathEvidence: invoiceTurn.sourcePathEvidence || invoicePath || null
  };
}

function buildHardStopEvent(invoiceMetadata) {
  const exhaustionObservedAt = normalizeText(invoiceMetadata?.exhaustionObservedAt) || null;
  const replenishmentReason = normalizeText(invoiceMetadata?.replenishmentReason) || null;
  if (exhaustionObservedAt) {
    return {
      status: 'observed',
      observedAt: exhaustionObservedAt,
      sourceKind: 'invoice-metadata',
      reason: 'invoice metadata recorded a hard-stop credit exhaustion event'
    };
  }
  if (replenishmentReason === 'post-exhaustion') {
    return {
      status: 'inferred',
      observedAt: null,
      sourceKind: 'invoice-metadata',
      reason: 'replenishmentReason=post-exhaustion implies a prior hard-stop event'
    };
  }
  return {
    status: 'missing',
    observedAt: null,
    sourceKind: null,
    reason: 'no hard-stop evidence supplied'
  };
}

function buildResumeEvent(invoiceMetadata, operatorSteeringEvent) {
  const resumeObservedAt = normalizeText(invoiceMetadata?.resumeObservedAt) || null;
  if (resumeObservedAt) {
    return {
      status: 'observed',
      observedAt: resumeObservedAt,
      sourceKind: 'invoice-metadata',
      reason: 'invoice metadata recorded the post-replenishment resume event'
    };
  }
  const steeringObservedAt = normalizeText(operatorSteeringEvent?.generatedAt) || null;
  if (steeringObservedAt) {
    return {
      status: 'observed',
      observedAt: steeringObservedAt,
      sourceKind: 'operator-steering-event',
      reason: 'operator steering event confirms autonomous work resumed after replenishment handling'
    };
  }
  if (normalizeText(invoiceMetadata?.replenishmentReason) === 'post-exhaustion') {
    return {
      status: 'inferred',
      observedAt: null,
      sourceKind: 'invoice-metadata',
      reason: 'post-exhaustion replenishment implies a resume path even without an explicit resume timestamp'
    };
  }
  return {
    status: 'missing',
    observedAt: null,
    sourceKind: null,
    reason: 'no resume evidence supplied'
  };
}

function buildObservedBurn(usageExportReceipt, normalizedUsageExportPath) {
  if (!usageExportReceipt) {
    return {
      status: 'missing',
      normalizedUsageExportPath: normalizedUsageExportPath || null,
      sourcePathEvidence: null,
      startDate: null,
      endDate: null,
      usageCredits: null,
      usageQuantity: null,
      filenameRangeStatus: 'missing',
      declaredFileRange: null,
      reason: 'normalized usage export receipt unavailable'
    };
  }

  const declaredFileRange = parseDeclaredFileRange(usageExportReceipt.sourcePathEvidence);
  const startDate = usageExportReceipt.startDate;
  const endDate = usageExportReceipt.endDate;
  const startParts = parseIsoDateParts(startDate);
  const endParts = parseIsoDateParts(endDate);

  let filenameRangeStatus = 'absent';
  let status = 'observed';
  let reason = null;

  if (!usageExportReceipt.sourcePathEvidence) {
    filenameRangeStatus = 'missing';
    status = 'fail-closed';
    reason = 'normalized usage export receipt is missing sourcePathEvidence';
  } else if (declaredFileRange) {
    if (!startParts || !endParts) {
      filenameRangeStatus = 'missing';
      status = 'fail-closed';
      reason = 'normalized usage export receipt is missing a valid reportWindow';
    } else {
      const matches =
        declaredFileRange.startMonth === startParts.month &&
        declaredFileRange.startDay === startParts.day &&
        declaredFileRange.endMonth === endParts.month &&
        declaredFileRange.endDay === endParts.day;
      filenameRangeStatus = matches ? 'match' : 'mismatch';
      if (!matches) {
        status = 'fail-closed';
        reason = `usage export filename declares ${declaredFileRange.startLabel} - ${declaredFileRange.endLabel}, but rows cover ${startDate}..${endDate}`;
      }
    }
  }

  return {
    status,
    normalizedUsageExportPath: normalizedUsageExportPath || null,
    sourcePathEvidence: usageExportReceipt.sourcePathEvidence,
    startDate,
    endDate,
    usageCredits: usageExportReceipt.usageCredits,
    usageQuantity: usageExportReceipt.usageQuantity,
    filenameRangeStatus,
    declaredFileRange,
    reason
  };
}

function buildRemainingCapitalPosture(fundingWindow, observedBurn, costRollup) {
  const rollupInvoiceTurnId = normalizeText(costRollup?.billingWindow?.invoiceTurnId) || normalizeText(costRollup?.inputs?.selectedInvoiceTurnId) || null;
  if (fundingWindow.status !== 'selected' || !fundingWindow.invoiceTurnId) {
    return {
      status: 'fail-closed',
      source: 'treasury-ledger',
      remainingCredits: null,
      remainingUsd: null,
      rollupInvoiceTurnId,
      reason: 'funding-window-missing'
    };
  }
  if (!costRollup) {
    return {
      status: 'fail-closed',
      source: 'treasury-ledger',
      remainingCredits: null,
      remainingUsd: null,
      rollupInvoiceTurnId,
      reason: 'cost-rollup-missing'
    };
  }
  if (rollupInvoiceTurnId && normalizeText(fundingWindow.invoiceTurnId) !== normalizeText(rollupInvoiceTurnId)) {
    return {
      status: 'fail-closed',
      source: 'agent-cost-rollup',
      remainingCredits: null,
      remainingUsd: null,
      rollupInvoiceTurnId,
      reason: 'funding-window-rollup-mismatch'
    };
  }
  if (observedBurn.status === 'fail-closed') {
    return {
      status: 'fail-closed',
      source: 'agent-cost-rollup',
      remainingCredits: null,
      remainingUsd: null,
      rollupInvoiceTurnId,
      reason: 'usage-export-window-mismatch'
    };
  }

  const remainingCredits = toNonNegativeNumber(costRollup?.summary?.metrics?.creditsRemaining);
  const remainingUsd = toNonNegativeNumber(costRollup?.summary?.metrics?.estimatedPrepaidUsdRemaining);
  if (remainingCredits == null || remainingUsd == null) {
    return {
      status: 'fail-closed',
      source: 'agent-cost-rollup',
      remainingCredits: null,
      remainingUsd: null,
      rollupInvoiceTurnId,
      reason: 'remaining-capital-unavailable'
    };
  }

  return {
    status: 'resolved',
    source: 'agent-cost-rollup',
    remainingCredits,
    remainingUsd,
    rollupInvoiceTurnId,
    reason: null
  };
}

function buildSchedulerState(fundingWindow, hardStopEvent, resumeEvent, replenishmentEvent, remainingCapitalPosture, observedBurn) {
  const blockingReasonCodes = [];
  if (fundingWindow.status !== 'selected') {
    blockingReasonCodes.push('funding-window-missing');
  }
  if (observedBurn.status === 'fail-closed') {
    blockingReasonCodes.push('usage-export-window-mismatch');
  }
  if (remainingCapitalPosture.status === 'fail-closed' && normalizeText(remainingCapitalPosture.reason)) {
    blockingReasonCodes.push(normalizeText(remainingCapitalPosture.reason));
  }

  return {
    status: blockingReasonCodes.length === 0 ? 'pass' : 'fail-closed',
    failClosed: blockingReasonCodes.length > 0,
    capitalModeRecommended: blockingReasonCodes.length === 0 ? 'balanced' : 'conserve',
    blockingReasonCodes,
    currentFundingWindowId: fundingWindow.invoiceTurnId,
    latestHardStopStatus: hardStopEvent.status,
    latestResumeStatus: resumeEvent.status,
    latestReplenishmentInvoiceTurnId: replenishmentEvent.invoiceTurnId
  };
}

function buildSummary(fundingWindow, replenishmentEvent, hardStopEvent, resumeEvent, remainingCapitalPosture, schedulerState, observedBurn, inputs) {
  const blockers = [];
  const warnings = [];

  if (observedBurn.status === 'fail-closed') {
    blockers.push(createMessage('usage-export-window-mismatch', observedBurn.reason, inputs.normalizedUsageExportPath));
  }
  if (remainingCapitalPosture.status === 'fail-closed') {
    blockers.push(
      createMessage(
        normalizeText(remainingCapitalPosture.reason) || 'remaining-capital-fail-closed',
        `Remaining capital posture is fail-closed: ${remainingCapitalPosture.reason || 'unknown reason'}`,
        inputs.costRollupPath
      )
    );
  }
  if (fundingWindow.status !== 'selected') {
    blockers.push(createMessage('funding-window-missing', 'No active funding window could be selected.', inputs.normalizedInvoiceTurnPath));
  }
  if (hardStopEvent.status === 'missing') {
    warnings.push(createMessage('hard-stop-evidence-missing', 'No hard-stop evidence was supplied for the current funding window.', inputs.invoiceMetadataPath));
  }
  if (resumeEvent.status === 'missing') {
    warnings.push(createMessage('resume-evidence-missing', 'No explicit resume evidence was supplied for the current funding window.', inputs.operatorSteeringEventPath));
  }
  if (replenishmentEvent.status === 'missing') {
    warnings.push(createMessage('replenishment-evidence-missing', 'No replenishment evidence was supplied.', inputs.normalizedInvoiceTurnPath));
  }

  return {
    status: blockers.length === 0 && schedulerState.status === 'pass' ? 'pass' : 'fail-closed',
    blockerCount: blockers.length,
    blockers,
    warningCount: warnings.length,
    warnings,
    currentFundingWindowId: fundingWindow.invoiceTurnId,
    latestReplenishmentInvoiceId: replenishmentEvent.invoiceId,
    latestHardStopStatus: hardStopEvent.status,
    latestResumeStatus: resumeEvent.status,
    remainingCapitalStatus: remainingCapitalPosture.status
  };
}

function resolveRepository(costRollup) {
  const explicit = normalizeText(costRollup?.repository);
  if (explicit) {
    return explicit;
  }
  const envValue = normalizeText(process.env.GITHUB_REPOSITORY);
  return envValue || null;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: process.cwd(),
    invoiceMetadataPath: null,
    invoiceOutputPath: null,
    usageExportCsvPath: null,
    usageOutputPath: null,
    costRollupPath: DEFAULT_COST_ROLLUP_PATH,
    operatorSteeringEventPath: DEFAULT_OPERATOR_STEERING_EVENT_PATH,
    outputPath: DEFAULT_RUNTIME_OUTPUT_PATH,
    handoffOutputPath: DEFAULT_HANDOFF_OUTPUT_PATH,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (
      ['--repo-root', '--invoice-metadata', '--invoice-output', '--usage-export-csv', '--usage-output', '--cost-rollup', '--operator-steering-event', '--output', '--handoff-output'].includes(token)
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--invoice-metadata') options.invoiceMetadataPath = next;
      if (token === '--invoice-output') options.invoiceOutputPath = next;
      if (token === '--usage-export-csv') options.usageExportCsvPath = next;
      if (token === '--usage-output') options.usageOutputPath = next;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--operator-steering-event') options.operatorSteeringEventPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--handoff-output') options.handoffOutputPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export function runTreasuryLedger(options = {}, now = new Date()) {
  const repoRoot = resolvePathOrNull(options.repoRoot) || process.cwd();
  const invoiceMetadataPath = resolveRepoPath(repoRoot, options.invoiceMetadataPath);
  const usageExportCsvPath = resolveRepoPath(repoRoot, options.usageExportCsvPath);
  const costRollupPath = options.costRollupPath === null ? null : resolveRepoPath(repoRoot, options.costRollupPath || DEFAULT_COST_ROLLUP_PATH);
  const operatorSteeringEventPath =
    options.operatorSteeringEventPath === null
      ? null
      : resolveRepoPath(repoRoot, options.operatorSteeringEventPath || DEFAULT_OPERATOR_STEERING_EVENT_PATH);
  const outputPath = resolveRepoPath(repoRoot, options.outputPath || DEFAULT_RUNTIME_OUTPUT_PATH);
  const handoffOutputPath = resolveRepoPath(repoRoot, options.handoffOutputPath || DEFAULT_HANDOFF_OUTPUT_PATH);

  const invoiceMetadata = invoiceMetadataPath ? readJson(invoiceMetadataPath) : null;
  const invoiceOutputPath =
    resolveRepoPath(repoRoot, options.invoiceOutputPath) || (invoiceMetadata ? deriveDefaultInvoiceOutputPath(repoRoot, invoiceMetadata) : null);
  const usageOutputPath =
    resolveRepoPath(repoRoot, options.usageOutputPath) || (usageExportCsvPath ? deriveDefaultUsageOutputPath(repoRoot, usageExportCsvPath) : null);

  let normalizedInvoiceTurnPath = invoiceOutputPath;
  let normalizedUsageExportPath = usageOutputPath;

  let normalizedInvoiceTurnPayload = null;
  if (invoiceMetadataPath) {
    const result = runAgentCostInvoiceNormalize({
      metadataPath: invoiceMetadataPath,
      outputPath: invoiceOutputPath
    });
    normalizedInvoiceTurnPath = result.outputPath;
    normalizedInvoiceTurnPayload = result.report;
  } else if (invoiceOutputPath && fs.existsSync(invoiceOutputPath)) {
    normalizedInvoiceTurnPayload = readJson(invoiceOutputPath);
  }

  let normalizedUsageExportPayload = null;
  if (usageExportCsvPath) {
    const result = runAgentCostUsageExportNormalize({
      inputPaths: [usageExportCsvPath],
      outputPath: usageOutputPath
    }, now);
    normalizedUsageExportPath = usageOutputPath;
    normalizedUsageExportPayload = result.reports[0] || null;
  } else if (usageOutputPath && fs.existsSync(usageOutputPath)) {
    normalizedUsageExportPayload = readJson(usageOutputPath);
  }

  const costRollupState = loadJsonFile(costRollupPath);
  const operatorSteeringState = loadJsonFile(operatorSteeringEventPath);
  const costRollup = costRollupState.payload;
  const operatorSteeringEvent = operatorSteeringState.payload;

  const normalizedInvoiceTurn = extractInvoiceTurn(normalizedInvoiceTurnPayload);
  const usageExportReceipt = extractUsageExport(normalizedUsageExportPayload);
  const fundingWindow = selectFundingWindow(normalizedInvoiceTurn, costRollup);
  const replenishmentEvent = buildReplenishmentEvent(normalizedInvoiceTurn, normalizedInvoiceTurnPath);
  const hardStopEvent = buildHardStopEvent(invoiceMetadata);
  const resumeEvent = buildResumeEvent(invoiceMetadata, operatorSteeringEvent);
  const observedBurn = buildObservedBurn(usageExportReceipt, normalizedUsageExportPath);
  const remainingCapitalPosture = buildRemainingCapitalPosture(fundingWindow, observedBurn, costRollup);
  const schedulerState = buildSchedulerState(fundingWindow, hardStopEvent, resumeEvent, replenishmentEvent, remainingCapitalPosture, observedBurn);

  const inputs = {
    invoiceMetadataPath,
    normalizedInvoiceTurnPath,
    usageExportCsvPath,
    normalizedUsageExportPath,
    costRollupPath: costRollupState.path,
    operatorSteeringEventPath: operatorSteeringState.path
  };

  const summary = buildSummary(
    fundingWindow,
    replenishmentEvent,
    hardStopEvent,
    resumeEvent,
    remainingCapitalPosture,
    schedulerState,
    observedBurn,
    inputs
  );

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository: resolveRepository(costRollup),
    inputs,
    events: {
      hardStop: hardStopEvent,
      replenishment: replenishmentEvent,
      resume: resumeEvent
    },
    fundingWindow,
    observedBurn,
    remainingCapitalPosture,
    schedulerState,
    summary
  };

  writeJson(outputPath, report);
  writeJson(handoffOutputPath, report);

  return {
    report,
    outputPath,
    handoffOutputPath,
    normalizedInvoiceTurnPath,
    normalizedUsageExportPath
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/treasury-ledger.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>             Repository root used for default output paths.');
  console.log('  --invoice-metadata <path>      Local private invoice metadata JSON to normalize.');
  console.log('  --invoice-output <path>        Explicit normalized invoice-turn receipt path.');
  console.log('  --usage-export-csv <path>      Local private usage export CSV to normalize.');
  console.log('  --usage-output <path>          Explicit normalized usage export receipt path.');
  console.log(`  --cost-rollup <path>           Cost rollup receipt path (default: ${DEFAULT_COST_ROLLUP_PATH}).`);
  console.log(`  --operator-steering-event <path> Operator steering event path (default: ${DEFAULT_OPERATOR_STEERING_EVENT_PATH}).`);
  console.log(`  --output <path>                Treasury runtime receipt output (default: ${DEFAULT_RUNTIME_OUTPUT_PATH}).`);
  console.log(`  --handoff-output <path>        Treasury handoff receipt output (default: ${DEFAULT_HANDOFF_OUTPUT_PATH}).`);
  console.log('  -h, --help                     Show help and exit.');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return 0;
    }
    const result = runTreasuryLedger(options);
    console.log(`[treasury-ledger] wrote ${result.outputPath}`);
    console.log(`[treasury-ledger] wrote ${result.handoffOutputPath}`);
    return 0;
  } catch (error) {
    console.error(error?.message || String(error));
    return 1;
  }
}

const entrypointPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (entrypointPath && modulePath === entrypointPath) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

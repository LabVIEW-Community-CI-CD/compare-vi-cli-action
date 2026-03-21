#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

export const TURN_SCHEMA = 'priority/agent-cost-turn@v1';
export const INVOICE_TURN_SCHEMA = 'priority/agent-cost-invoice-turn@v1';
export const USAGE_EXPORT_SCHEMA = 'priority/agent-cost-usage-export@v1';
export const ACCOUNT_BALANCE_SCHEMA = 'priority/agent-cost-account-balance@v1';
export const OPERATOR_STEERING_EVENT_SCHEMA = 'priority/operator-steering-event@v1';
export const REPORT_SCHEMA = 'priority/agent-cost-rollup@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_INVOICE_TURN_DIR = path.join('tests', 'results', '_agent', 'cost', 'invoice-turns');
export const DEFAULT_USAGE_EXPORT_DIR = path.join('tests', 'results', '_agent', 'cost', 'usage-exports');
export const DEFAULT_ACCOUNT_BALANCE_DIR = path.join('tests', 'results', '_agent', 'cost', 'account-balances');
export const DEFAULT_OPERATOR_STEERING_EVENT_DIR = path.join('tests', 'results', '_agent', 'runtime', 'operator-steering-events');

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function normalizeReasoningEffort(value) {
  const normalized = normalizeText(value).toLowerCase();
  return ['low', 'medium', 'high', 'xhigh'].includes(normalized) ? normalized : null;
}

function normalizeSelectionMode(value) {
  const normalized = normalizeText(value).toLowerCase();
  return ['hold', 'sticky-calibration', 'ended'].includes(normalized) ? normalized : null;
}

function toNonNegativeNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function toNonNegativeInteger(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function roundUsd(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return Number(parsed.toFixed(6));
}

function normalizeDateTime(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? normalized : null;
}

function safeRelative(filePath) {
  return path.relative(process.cwd(), path.resolve(filePath)).replace(/\\/g, '/');
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) {
    return null;
  }
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo) {
  if (normalizeText(explicitRepo).includes('/')) {
    return normalizeText(explicitRepo);
  }
  if (normalizeText(process.env.GITHUB_REPOSITORY).includes('/')) {
    return normalizeText(process.env.GITHUB_REPOSITORY);
  }
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) {
        return slug;
      }
    } catch {
      // ignore missing remotes
    }
  }
  return null;
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function loadInputFile(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    return { exists: false, path: resolvedPath, payload: null, error: null };
  }
  try {
    return {
      exists: true,
      path: resolvedPath,
      payload: readJsonFile(resolvedPath),
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

function ensureArray(value) {
  return Array.isArray(value) ? value : [];
}

function sum(values) {
  return roundUsd(values.reduce((accumulator, value) => accumulator + (Number.isFinite(value) ? value : 0), 0)) ?? 0;
}

function createBlocker(code, message, inputPath = null) {
  return { code, message, inputPath: inputPath ? safeRelative(inputPath) : null };
}

function pricingBasisFromTurn(payload) {
  return normalizeText(payload?.billing?.rateCard?.pricingBasis) || null;
}

function computeUsdFromRateCard(payload) {
  const rateCard = payload?.billing?.rateCard;
  if (!rateCard || typeof rateCard !== 'object') {
    return null;
  }

  const inputTokens = toNonNegativeInteger(payload?.usage?.inputTokens) ?? 0;
  const cachedInputTokens = toNonNegativeInteger(payload?.usage?.cachedInputTokens) ?? 0;
  const outputTokens = toNonNegativeInteger(payload?.usage?.outputTokens) ?? 0;
  const usageUnitCount = toNonNegativeNumber(payload?.usage?.usageUnitCount) ?? 0;

  const inputUsdPer1k = toNonNegativeNumber(rateCard.inputUsdPer1kTokens) ?? 0;
  const cachedInputUsdPer1k = toNonNegativeNumber(rateCard.cachedInputUsdPer1kTokens) ?? 0;
  const outputUsdPer1k = toNonNegativeNumber(rateCard.outputUsdPer1kTokens) ?? 0;
  const usageUnitUsd = toNonNegativeNumber(rateCard.usageUnitUsd) ?? 0;

  const tokenUsd =
    (inputTokens / 1000) * inputUsdPer1k +
    (cachedInputTokens / 1000) * cachedInputUsdPer1k +
    (outputTokens / 1000) * outputUsdPer1k;
  const unitUsd = usageUnitCount * usageUnitUsd;
  const total = tokenUsd + unitUsd;
  return total > 0 ? roundUsd(total) : null;
}

function normalizeTurnReceipt(input) {
  const payload = input?.payload;
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'invalid',
      blockers: [createBlocker('turn-report-unreadable', 'Turn report could not be read as JSON.', input.path)]
    };
  }

  if (normalizeText(payload.schema) !== TURN_SCHEMA) {
    return {
      status: 'invalid',
      blockers: [
        createBlocker(
          'turn-schema-mismatch',
          `Turn report schema must remain ${TURN_SCHEMA}.`,
          input.path
        )
      ]
    };
  }

  const exactness = normalizeText(payload?.billing?.exactness).toLowerCase();
  const normalizedExactness = exactness === 'exact' ? 'exact' : exactness === 'estimated' ? 'estimated' : null;
  const declaredAmountUsd = toNonNegativeNumber(payload?.billing?.amountUsd);
  const computedAmountUsd = computeUsdFromRateCard(payload);
  const preferRateCardEstimate = normalizedExactness === 'estimated' && declaredAmountUsd === 0 && computedAmountUsd != null;
  const amountUsd = preferRateCardEstimate ? computedAmountUsd : declaredAmountUsd ?? computedAmountUsd;

  const blockers = [];
  if (!normalizedExactness) {
    blockers.push(
      createBlocker('billing-exactness-missing', 'Turn report billing.exactness must be exact or estimated.', input.path)
    );
  }
  if (!normalizeText(payload?.provider?.id)) {
    blockers.push(createBlocker('provider-id-missing', 'Turn report provider.id is required.', input.path));
  }
  if (!normalizeText(payload?.model?.effective)) {
    blockers.push(createBlocker('model-effective-missing', 'Turn report model.effective is required.', input.path));
  }
  if (amountUsd == null) {
    blockers.push(
      createBlocker(
        'billing-amount-unresolved',
        'Turn report must provide billing.amountUsd or enough rate-card data to estimate cost.',
        input.path
      )
    );
  }

  if (blockers.length > 0) {
    return {
      status: 'invalid',
      blockers
    };
  }

  const usageUnitKind = normalizeText(payload?.usage?.usageUnitKind) || null;
  const usageUnitCount = toNonNegativeNumber(payload?.usage?.usageUnitCount);
  const inputTokens = toNonNegativeInteger(payload?.usage?.inputTokens) ?? 0;
  const cachedInputTokens = toNonNegativeInteger(payload?.usage?.cachedInputTokens) ?? 0;
  const outputTokens = toNonNegativeInteger(payload?.usage?.outputTokens) ?? 0;
  const totalTokens = toNonNegativeInteger(payload?.usage?.totalTokens) ?? inputTokens + cachedInputTokens + outputTokens;

  return {
    status: 'valid',
    blockers: [],
    turn: {
      sourcePath: safeRelative(input.path),
      generatedAt: normalizeText(payload.generatedAt) || null,
      repository: normalizeText(payload?.context?.repository) || null,
      issueNumber: toNonNegativeInteger(payload?.context?.issueNumber),
      laneId: normalizeText(payload?.context?.laneId) || null,
      laneBranch: normalizeText(payload?.context?.laneBranch) || null,
      sessionId: normalizeText(payload?.context?.sessionId) || null,
      turnId: normalizeText(payload?.context?.turnId) || null,
      workerSlotId: normalizeText(payload?.context?.workerSlotId) || null,
      agentRole: normalizeText(payload?.context?.agentRole) || null,
      providerId: normalizeText(payload?.provider?.id) || null,
      providerKind: normalizeText(payload?.provider?.kind) || null,
      providerRuntime: normalizeText(payload?.provider?.runtime) || null,
      executionPlane: normalizeText(payload?.provider?.executionPlane) || null,
      requestedModel: normalizeText(payload?.model?.requested) || null,
      effectiveModel: normalizeText(payload?.model?.effective) || null,
      requestedReasoningEffort: normalizeReasoningEffort(payload?.model?.requestedReasoningEffort),
      effectiveReasoningEffort: normalizeReasoningEffort(payload?.model?.effectiveReasoningEffort),
      operatorIntervened: payload?.steering?.operatorIntervened === true,
      steeringKind: normalizeText(payload?.steering?.kind) || null,
      steeringSource: normalizeText(payload?.steering?.source) || null,
      steeringObservedAt: normalizeDateTime(payload?.steering?.observedAt),
      steeringNote: normalizeText(payload?.steering?.note) || null,
      steeringInvoiceTurnId: normalizeText(payload?.steering?.invoiceTurnId) || null,
      usageUnitKind,
      usageUnitCount,
      inputTokens,
      cachedInputTokens,
      outputTokens,
      totalTokens,
      exactness: normalizedExactness,
      amountUsd,
      amountSource: !preferRateCardEstimate && declaredAmountUsd != null ? 'declared-amount' : 'rate-card-estimate',
      rateCardId: normalizeText(payload?.billing?.rateCard?.id) || null,
      rateCardSource: normalizeText(payload?.billing?.rateCard?.source) || null,
      rateCardRetrievedAt: normalizeText(payload?.billing?.rateCard?.retrievedAt) || null,
      pricingBasis: pricingBasisFromTurn(payload),
      provenance: {
        sourceSchema: normalizeText(payload?.provenance?.sourceSchema) || null,
        sourceReceiptPath: normalizeText(payload?.provenance?.sourceReceiptPath) || null,
        sourceReportPath: normalizeText(payload?.provenance?.sourceReportPath) || null,
        usageObservedAt: normalizeText(payload?.provenance?.usageObservedAt) || null
      }
    }
  };
}

function normalizeInvoiceTurnReceipt(input) {
  if (!input) {
    return {
      status: 'missing',
      blockers: []
    };
  }
  const payload = input?.payload;
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'invalid',
      blockers: [createBlocker('invoice-turn-unreadable', 'Invoice turn report could not be read as JSON.', input.path)]
    };
  }
  if (normalizeText(payload.schema) !== INVOICE_TURN_SCHEMA) {
    return {
      status: 'invalid',
      blockers: [
        createBlocker(
          'invoice-turn-schema-mismatch',
          `Invoice turn report schema must remain ${INVOICE_TURN_SCHEMA}.`,
          input.path
        )
      ]
    };
  }

  const creditsPurchased = toNonNegativeNumber(payload?.credits?.purchased);
  const unitPriceUsd = toNonNegativeNumber(payload?.credits?.unitPriceUsd);
  const prepaidUsd = toNonNegativeNumber(payload?.billing?.prepaidUsd);
  const blockers = [];
  if (creditsPurchased == null) {
    blockers.push(createBlocker('invoice-turn-credits-missing', 'Invoice turn credits.purchased is required.', input.path));
  }
  if (unitPriceUsd == null) {
    blockers.push(createBlocker('invoice-turn-unit-price-missing', 'Invoice turn credits.unitPriceUsd is required.', input.path));
  }
  if (prepaidUsd == null) {
    blockers.push(createBlocker('invoice-turn-prepaid-missing', 'Invoice turn billing.prepaidUsd is required.', input.path));
  }
  if (blockers.length > 0) {
    return {
      status: 'invalid',
      blockers
    };
  }

  return {
    status: 'valid',
    blockers: [],
    invoiceTurn: {
      sourcePath: safeRelative(input.path),
      invoiceTurnId: normalizeText(payload.invoiceTurnId) || null,
      invoiceId: normalizeText(payload.invoiceId) || null,
      openedAt: normalizeText(payload?.billingPeriod?.openedAt) || null,
      closedAt: normalizeText(payload?.billingPeriod?.closedAt) || null,
      creditsPurchased,
      unitPriceUsd,
      prepaidUsd,
      pricingBasis: normalizeText(payload?.billing?.pricingBasis) || null,
      activationState: normalizeText(payload?.policy?.activationState) || 'active',
      fundingPurpose: normalizeText(payload?.policy?.fundingPurpose) || 'operational',
      reconciliationStatus: normalizeText(payload?.reconciliation?.status) || 'baseline-only',
      actualUsdConsumed: toNonNegativeNumber(payload?.reconciliation?.actualUsdConsumed),
      actualCreditsConsumed: toNonNegativeNumber(payload?.reconciliation?.actualCreditsConsumed),
      reconciledAt: normalizeDateTime(payload?.reconciliation?.reconciledAt),
      reconciliationSourceKind: normalizeText(payload?.reconciliation?.sourceKind) || null,
      reconciliationNote: normalizeText(payload?.reconciliation?.note) || null,
      sourceKind: normalizeText(payload?.provenance?.sourceKind) || null,
      sourcePathEvidence: normalizeText(payload?.provenance?.sourcePath) || null,
      operatorNote: normalizeText(payload?.provenance?.operatorNote) || null,
      selection: {
        mode: normalizeSelectionMode(payload?.selection?.mode) || 'hold',
        calibrationWindowId: normalizeText(payload?.selection?.calibrationWindowId) || null,
        reason: normalizeText(payload?.selection?.reason) || null
      }
    }
  };
}

function discoverInvoiceTurnPaths() {
  const invoiceDir = path.resolve(DEFAULT_INVOICE_TURN_DIR);
  if (!fs.existsSync(invoiceDir)) {
    return [];
  }
  return fs
    .readdirSync(invoiceDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.json'))
    .map((entry) => path.join(invoiceDir, entry.name))
    .sort((left, right) => left.localeCompare(right));
}

function discoverJsonPaths(directoryPath) {
  const resolvedDirectory = path.resolve(directoryPath);
  if (!fs.existsSync(resolvedDirectory)) {
    return [];
  }
  return fs
    .readdirSync(resolvedDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.json'))
    .map((entry) => path.join(resolvedDirectory, entry.name))
    .sort((left, right) => left.localeCompare(right));
}

function normalizeUsageExportReceipt(input) {
  if (!input) {
    return {
      status: 'missing',
      blockers: []
    };
  }
  const payload = input?.payload;
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'invalid',
      blockers: [createBlocker('usage-export-unreadable', 'Usage export receipt could not be read as JSON.', input.path)]
    };
  }
  if (normalizeText(payload.schema) !== USAGE_EXPORT_SCHEMA) {
    return {
      status: 'invalid',
      blockers: [
        createBlocker(
          'usage-export-schema-mismatch',
          `Usage export receipt schema must remain ${USAGE_EXPORT_SCHEMA}.`,
          input.path
        )
      ]
    };
  }

  const startDate = normalizeText(payload?.reportWindow?.startDate) || null;
  const endDate = normalizeText(payload?.reportWindow?.endDate) || null;
  const rowCount = toNonNegativeInteger(payload?.reportWindow?.rowCount);
  const usageCredits = toNonNegativeNumber(payload?.totals?.usageCredits);
  const usageQuantity = toNonNegativeNumber(payload?.totals?.usageQuantity);
  const blockers = [];
  if (!startDate) {
    blockers.push(createBlocker('usage-export-start-date-missing', 'Usage export reportWindow.startDate is required.', input.path));
  }
  if (!endDate) {
    blockers.push(createBlocker('usage-export-end-date-missing', 'Usage export reportWindow.endDate is required.', input.path));
  }
  if (usageCredits == null) {
    blockers.push(createBlocker('usage-export-credits-missing', 'Usage export totals.usageCredits is required.', input.path));
  }
  if (usageQuantity == null) {
    blockers.push(createBlocker('usage-export-quantity-missing', 'Usage export totals.usageQuantity is required.', input.path));
  }
  if (blockers.length > 0) {
    return {
      status: 'invalid',
      blockers
    };
  }

  return {
    status: 'valid',
    blockers: [],
    usageExport: {
      sourcePath: safeRelative(input.path),
      generatedAt: normalizeDateTime(payload?.generatedAt),
      startDate,
      endDate,
      rowCount,
      usageType: normalizeText(payload?.usageType) || null,
      usageCredits,
      usageQuantity,
      sourceKind: normalizeText(payload?.sourceKind) || normalizeText(payload?.provenance?.sourceKind) || null,
      sourcePathEvidence: normalizeText(payload?.sourcePathEvidence) || normalizeText(payload?.provenance?.sourcePath) || null,
      operatorNote: normalizeText(payload?.operatorNote) || normalizeText(payload?.provenance?.operatorNote) || null
    }
  };
}

function normalizeAccountBalanceReceipt(input) {
  if (!input) {
    return {
      status: 'missing',
      blockers: []
    };
  }
  const payload = input?.payload;
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'invalid',
      blockers: [createBlocker('account-balance-unreadable', 'Account balance receipt could not be read as JSON.', input.path)]
    };
  }
  if (normalizeText(payload.schema) !== ACCOUNT_BALANCE_SCHEMA) {
    return {
      status: 'invalid',
      blockers: [
        createBlocker(
          'account-balance-schema-mismatch',
          `Account balance receipt schema must remain ${ACCOUNT_BALANCE_SCHEMA}.`,
          input.path
        )
      ]
    };
  }

  const snapshotAt = normalizeDateTime(payload?.effectiveAt) || normalizeDateTime(payload?.capturedAt);
  const renewsAt = normalizeDateTime(payload?.plan?.renewsAt);
  const totalCredits = toNonNegativeNumber(payload?.balances?.totalCredits);
  const usedCredits = toNonNegativeNumber(payload?.balances?.usedCredits);
  const remainingCredits = toNonNegativeNumber(payload?.balances?.remainingCredits);
  const blockers = [];
  if (!snapshotAt) {
    blockers.push(
      createBlocker('account-balance-snapshot-missing', 'Account balance effectiveAt or capturedAt is required.', input.path)
    );
  }
  if (totalCredits == null) {
    blockers.push(createBlocker('account-balance-total-missing', 'Account balance balances.totalCredits is required.', input.path));
  }
  if (usedCredits == null) {
    blockers.push(createBlocker('account-balance-used-missing', 'Account balance balances.usedCredits is required.', input.path));
  }
  if (remainingCredits == null) {
    blockers.push(
      createBlocker('account-balance-remaining-missing', 'Account balance balances.remainingCredits is required.', input.path)
    );
  }
  if (blockers.length > 0) {
    return {
      status: 'invalid',
      blockers
    };
  }

  return {
    status: 'valid',
    blockers: [],
    accountBalance: {
      sourcePath: safeRelative(input.path),
      generatedAt: normalizeDateTime(payload?.generatedAt),
      snapshotAt,
      planName: normalizeText(payload?.plan?.name) || null,
      renewsAt,
      totalCredits,
      usedCredits,
      remainingCredits,
      sourceKind: normalizeText(payload?.sourceKind) || normalizeText(payload?.provenance?.sourceKind) || null,
      sourcePathEvidence: normalizeText(payload?.sourcePathEvidence) || normalizeText(payload?.provenance?.sourcePath) || null,
      operatorNote: normalizeText(payload?.operatorNote) || normalizeText(payload?.provenance?.operatorNote) || null
    }
  };
}

function normalizeOperatorSteeringEventReceipt(input) {
  if (!input) {
    return {
      status: 'missing',
      blockers: []
    };
  }
  const payload = input?.payload;
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'invalid',
      blockers: [createBlocker('operator-steering-event-unreadable', 'Operator steering event receipt could not be read as JSON.', input.path)]
    };
  }
  if (normalizeText(payload.schema) !== OPERATOR_STEERING_EVENT_SCHEMA) {
    return {
      status: 'invalid',
      blockers: [
        createBlocker(
          'operator-steering-event-schema-mismatch',
          `Operator steering event receipt schema must remain ${OPERATOR_STEERING_EVENT_SCHEMA}.`,
          input.path
        )
      ]
    };
  }

  const blockers = [];
  if (!normalizeText(payload.eventKey)) {
    blockers.push(createBlocker('operator-steering-event-key-missing', 'Operator steering event eventKey is required.', input.path));
  }
  if (!normalizeText(payload.steeringKind)) {
    blockers.push(createBlocker('operator-steering-kind-missing', 'Operator steering event steeringKind is required.', input.path));
  }
  if (!normalizeText(payload.triggerKind)) {
    blockers.push(createBlocker('operator-steering-trigger-kind-missing', 'Operator steering event triggerKind is required.', input.path));
  }
  if (blockers.length > 0) {
    return {
      status: 'invalid',
      blockers
    };
  }

  return {
    status: 'valid',
    blockers: [],
    operatorSteeringEvent: {
      sourcePath: safeRelative(input.path),
      generatedAt: normalizeDateTime(payload.generatedAt),
      eventKey: normalizeText(payload.eventKey),
      steeringKind: normalizeText(payload.steeringKind) || null,
      triggerKind: normalizeText(payload.triggerKind) || null,
      repository: normalizeText(payload.repository) || null,
      issueNumber: toNonNegativeInteger(payload?.issueContext?.issue),
      observedAt: normalizeDateTime(payload?.issueContext?.observedAt) || normalizeDateTime(payload.generatedAt),
      continuityReferenceAt: normalizeDateTime(payload?.continuity?.continuityReferenceAt),
      activeLaneIssue: toNonNegativeInteger(payload?.continuity?.turnBoundary?.activeLaneIssue),
      operatorTurnEndWouldCreateIdleGap: payload?.continuity?.turnBoundary?.operatorTurnEndWouldCreateIdleGap === true,
      fundingWindowStatus: normalizeText(payload?.fundingWindow?.status) || null,
      fundingWindowPath: normalizeText(payload?.fundingWindow?.path) || null,
      invoiceTurnId: normalizeText(payload?.fundingWindow?.invoiceTurnId) || null,
      fundingPurpose: normalizeText(payload?.fundingWindow?.fundingPurpose) || null,
      activationState: normalizeText(payload?.fundingWindow?.activationState) || null,
      actor: normalizeText(payload?.provenance?.actor) || null,
      sessionName: normalizeText(payload?.provenance?.sessionName) || null
    }
  };
}

function toTimestamp(value) {
  const normalized = normalizeDateTime(value);
  if (!normalized) {
    return null;
  }
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function determineSelectionTimestamp(turns = []) {
  const candidates = turns
    .flatMap((turn) => [toTimestamp(turn?.provenance?.usageObservedAt), toTimestamp(turn?.generatedAt)])
    .filter((value) => value != null);
  if (candidates.length === 0) {
    return Date.now();
  }
  return Math.max(...candidates);
}

function summarizeInvoiceTurnSelection(selectedInvoiceTurn, strategy, extras = {}) {
  const normalizedStrategy = normalizeText(strategy) || 'none';
  const normalizedSelectionMode =
    normalizeSelectionMode(selectedInvoiceTurn?.selection?.mode) ||
    (selectedInvoiceTurn &&
    normalizeText(selectedInvoiceTurn?.fundingPurpose) === 'calibration' &&
    normalizeText(selectedInvoiceTurn?.activationState) !== 'hold'
      ? 'sticky-calibration'
      : 'hold');
  const calibrationWindowId =
    normalizedSelectionMode === 'hold'
      ? null
      : normalizeText(selectedInvoiceTurn?.selection?.calibrationWindowId) ||
        selectedInvoiceTurn?.invoiceTurnId ||
        null;
  const reason =
    normalizeText(selectedInvoiceTurn?.selection?.reason) ||
    (normalizedSelectionMode === 'sticky-calibration'
      ? 'Calibration funding window remains pinned until explicitly ended.'
      : normalizedSelectionMode === 'ended'
        ? 'Calibration funding window was explicitly ended.'
        : 'Calibration funding window remains on hold before activation.');

  return {
    strategy: normalizedStrategy,
    explicitInvoiceTurnId: normalizeText(extras.explicitInvoiceTurnId) || null,
    selectionObservedAt: normalizeText(extras.selectionObservedAt) || null,
    candidateCount: extras.candidateCount ?? 0,
    matchingCandidateCount: extras.matchingCandidateCount ?? 0,
    candidateInvoiceTurnIds: ensureArray(extras.candidateInvoiceTurnIds),
    selectedInvoiceTurnId: selectedInvoiceTurn?.invoiceTurnId ?? null,
    mode: normalizedSelectionMode,
    calibrationWindowId,
    reason
  };
}

function selectInvoiceTurn(invoiceTurns, turns, explicitInvoiceTurnId = null) {
  const validInvoiceTurns = invoiceTurns.filter((entry) => entry?.status === 'valid').map((entry) => entry.invoiceTurn);
  const selectionTimestamp = determineSelectionTimestamp(turns);
  const selectionObservedAt = new Date(selectionTimestamp).toISOString();
  const candidateInvoiceTurnIds = validInvoiceTurns.map((entry) => entry.invoiceTurnId).filter(Boolean).sort();
  const activeInvoiceTurns = validInvoiceTurns.filter((entry) => normalizeText(entry.activationState) !== 'hold');
  const stickyCalibrationInvoiceTurns = activeInvoiceTurns.filter((entry) => normalizeText(entry.fundingPurpose) === 'calibration');

  if (validInvoiceTurns.length === 0) {
    return {
      selectedInvoiceTurn: null,
      selection: summarizeInvoiceTurnSelection(null, 'none', {
        explicitInvoiceTurnId,
        selectionObservedAt,
        candidateCount: 0,
        matchingCandidateCount: 0,
        candidateInvoiceTurnIds: []
      })
    };
  }

  if (normalizeText(explicitInvoiceTurnId)) {
    const selectedInvoiceTurn = validInvoiceTurns.find((entry) => entry.invoiceTurnId === normalizeText(explicitInvoiceTurnId)) ?? null;
    return {
      selectedInvoiceTurn,
      selection: summarizeInvoiceTurnSelection(selectedInvoiceTurn, selectedInvoiceTurn ? 'explicit-id' : 'explicit-id-missing', {
        explicitInvoiceTurnId,
        selectionObservedAt,
        candidateCount: validInvoiceTurns.length,
        matchingCandidateCount: selectedInvoiceTurn ? 1 : 0,
        candidateInvoiceTurnIds
      })
    };
  }

  if (stickyCalibrationInvoiceTurns.length > 0) {
    const selectedInvoiceTurn = [...stickyCalibrationInvoiceTurns].sort((left, right) => {
      const leftOpenedAt = toTimestamp(left.openedAt) ?? 0;
      const rightOpenedAt = toTimestamp(right.openedAt) ?? 0;
      if (rightOpenedAt !== leftOpenedAt) {
        return rightOpenedAt - leftOpenedAt;
      }
      return (right.invoiceTurnId || '').localeCompare(left.invoiceTurnId || '');
    })[0] ?? null;
    return {
      selectedInvoiceTurn,
      selection: summarizeInvoiceTurnSelection(selectedInvoiceTurn, stickyCalibrationInvoiceTurns.length === 1 ? 'sticky-calibration-active' : 'sticky-calibration-latest-openedAt', {
        explicitInvoiceTurnId: null,
        selectionObservedAt,
        candidateCount: validInvoiceTurns.length,
        matchingCandidateCount: stickyCalibrationInvoiceTurns.length,
        candidateInvoiceTurnIds
      })
    };
  }

  if (activeInvoiceTurns.length === 0) {
    return {
      selectedInvoiceTurn: null,
      selection: summarizeInvoiceTurnSelection(null, 'none', {
        explicitInvoiceTurnId: null,
        selectionObservedAt,
        candidateCount: validInvoiceTurns.length,
        matchingCandidateCount: 0,
        candidateInvoiceTurnIds
      })
    };
  }

  if (activeInvoiceTurns.length === 1) {
    return {
      selectedInvoiceTurn: activeInvoiceTurns[0],
      selection: summarizeInvoiceTurnSelection(activeInvoiceTurns[0], 'single-candidate', {
        explicitInvoiceTurnId: null,
        selectionObservedAt,
        candidateCount: validInvoiceTurns.length,
        matchingCandidateCount: 1,
        candidateInvoiceTurnIds
      })
    };
  }

  const activeCandidates = activeInvoiceTurns.filter((entry) => {
    const openedAt = toTimestamp(entry.openedAt);
    const closedAt = toTimestamp(entry.closedAt);
    return openedAt != null && openedAt <= selectionTimestamp && (closedAt == null || selectionTimestamp <= closedAt);
  });
  const candidatesToRank = activeCandidates.length > 0 ? activeCandidates : activeInvoiceTurns;
  const selectedInvoiceTurn = [...candidatesToRank].sort((left, right) => {
    const leftOpenedAt = toTimestamp(left.openedAt) ?? 0;
    const rightOpenedAt = toTimestamp(right.openedAt) ?? 0;
    if (rightOpenedAt !== leftOpenedAt) {
      return rightOpenedAt - leftOpenedAt;
    }
    return (right.invoiceTurnId || '').localeCompare(left.invoiceTurnId || '');
  })[0] ?? null;

  return {
    selectedInvoiceTurn,
    selection: summarizeInvoiceTurnSelection(selectedInvoiceTurn, activeCandidates.length > 0 ? 'active-window-latest-openedAt' : 'latest-openedAt-fallback', {
      explicitInvoiceTurnId: null,
      selectionObservedAt,
      candidateCount: validInvoiceTurns.length,
      matchingCandidateCount: activeCandidates.length > 0 ? activeCandidates.length : validInvoiceTurns.length,
      candidateInvoiceTurnIds
    })
  };
}

function incrementCount(map, key) {
  const normalizedKey = normalizeText(key) || 'unknown';
  map.set(normalizedKey, (map.get(normalizedKey) ?? 0) + 1);
}

function addUsd(map, key, amountUsd) {
  const normalizedKey = normalizeText(key) || 'unknown';
  map.set(normalizedKey, roundUsd((map.get(normalizedKey) ?? 0) + (amountUsd ?? 0)) ?? 0);
}

function materializeBreakdown(countMap, usdMap) {
  return [...countMap.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, turnCount]) => ({
      key,
      turnCount,
      totalUsd: usdMap.get(key) ?? 0
    }));
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    turnReportPaths: [],
    invoiceTurnPaths: [],
    usageExportPaths: [],
    accountBalancePaths: [],
    operatorSteeringEventPaths: [],
    invoiceTurnId: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    failOnInvalidInputs: true,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--no-fail-on-invalid-inputs') {
      options.failOnInvalidInputs = false;
      continue;
    }
    if (token === '--fail-on-invalid-inputs') {
      options.failOnInvalidInputs = true;
      continue;
    }
    if (
      token === '--turn-report' ||
      token === '--invoice-turn' ||
      token === '--usage-export' ||
      token === '--account-balance' ||
      token === '--operator-steering-event' ||
      token === '--invoice-turn-id' ||
      token === '--output' ||
      token === '--repo'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--turn-report') {
        options.turnReportPaths.push(next);
      } else if (token === '--invoice-turn') {
        options.invoiceTurnPaths.push(next);
      } else if (token === '--usage-export') {
        options.usageExportPaths.push(next);
      } else if (token === '--account-balance') {
        options.accountBalancePaths.push(next);
      } else if (token === '--operator-steering-event') {
        options.operatorSteeringEventPaths.push(next);
      } else if (token === '--invoice-turn-id') {
        options.invoiceTurnId = next;
      } else if (token === '--output') {
        options.outputPath = next;
      } else {
        options.repo = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && options.turnReportPaths.length === 0) {
    throw new Error('Missing required option: --turn-report <path>.');
  }
  if (!options.help && options.invoiceTurnPaths.length === 0) {
    options.invoiceTurnPaths = discoverInvoiceTurnPaths();
  }
  if (!options.help && options.usageExportPaths.length === 0) {
    options.usageExportPaths = discoverJsonPaths(DEFAULT_USAGE_EXPORT_DIR);
  }
  if (!options.help && options.accountBalancePaths.length === 0) {
    options.accountBalancePaths = discoverJsonPaths(DEFAULT_ACCOUNT_BALANCE_DIR);
  }
  if (!options.help && options.operatorSteeringEventPaths.length === 0) {
    options.operatorSteeringEventPaths = discoverJsonPaths(DEFAULT_OPERATOR_STEERING_EVENT_DIR);
  }
  return options;
}

export function evaluateAgentCostRollup({ turnInputs, normalizedTurns }) {
  const blockers = [];

  for (const input of turnInputs) {
    if (!input.exists) {
      blockers.push(createBlocker('turn-report-missing', 'Turn report is missing.', input.path));
      continue;
    }
    if (input.error) {
      blockers.push(createBlocker('turn-report-unreadable', `Turn report could not be parsed: ${input.error}`, input.path));
    }
  }

  for (const normalized of normalizedTurns) {
    blockers.push(...ensureArray(normalized.blockers));
  }

  const validTurns = normalizedTurns.filter((entry) => entry.status === 'valid').map((entry) => entry.turn);
  const exactTurns = validTurns.filter((entry) => entry.exactness === 'exact');
  const estimatedTurns = validTurns.filter((entry) => entry.exactness === 'estimated');

  return {
    status: blockers.length === 0 ? 'pass' : 'fail',
    blockerCount: blockers.length,
    blockers,
    recommendation:
      blockers.length > 0
        ? 'repair-input-receipts'
        : estimatedTurns.length > 0
          ? 'continue-estimated-telemetry'
          : 'exact-cost-ready',
    validTurns,
    exactTurns,
    estimatedTurns
  };
}

export function runAgentCostRollup(options) {
  const repo = resolveRepoSlug(options.repo);
  const turnInputs = options.turnReportPaths.map((filePath) => loadInputFile(filePath));
  const normalizedTurns = turnInputs.map((input) => normalizeTurnReceipt(input));
  const invoiceTurnInputs = ensureArray(options.invoiceTurnPaths).map((filePath) => loadInputFile(filePath));
  const normalizedInvoiceTurns = invoiceTurnInputs.map((input) => normalizeInvoiceTurnReceipt(input));
  const usageExportInputs = ensureArray(options.usageExportPaths).map((filePath) => loadInputFile(filePath));
  const normalizedUsageExports = usageExportInputs.map((input) => normalizeUsageExportReceipt(input));
  const accountBalanceInputs = ensureArray(options.accountBalancePaths).map((filePath) => loadInputFile(filePath));
  const normalizedAccountBalances = accountBalanceInputs.map((input) => normalizeAccountBalanceReceipt(input));
  const operatorSteeringEventInputs = ensureArray(options.operatorSteeringEventPaths).map((filePath) => loadInputFile(filePath));
  const normalizedOperatorSteeringEvents = operatorSteeringEventInputs.map((input) => normalizeOperatorSteeringEventReceipt(input));
  const evaluation = evaluateAgentCostRollup({ turnInputs, normalizedTurns });
  const invoiceTurnBlockers = [];
  const usageExportBlockers = [];
  const accountBalanceBlockers = [];
  const operatorSteeringEventBlockers = [];
  for (const invoiceTurnInput of invoiceTurnInputs) {
    if (invoiceTurnInput?.exists === false) {
      invoiceTurnBlockers.push(createBlocker('invoice-turn-missing', 'Invoice turn report is missing.', invoiceTurnInput.path));
      continue;
    }
    if (invoiceTurnInput?.error) {
      invoiceTurnBlockers.push(
        createBlocker('invoice-turn-unreadable', `Invoice turn report could not be parsed: ${invoiceTurnInput.error}`, invoiceTurnInput.path)
      );
    }
  }
  for (const normalizedInvoiceTurn of normalizedInvoiceTurns) {
    invoiceTurnBlockers.push(...ensureArray(normalizedInvoiceTurn.blockers));
  }
  for (const usageExportInput of usageExportInputs) {
    if (usageExportInput?.exists === false) {
      usageExportBlockers.push(createBlocker('usage-export-missing', 'Usage export receipt is missing.', usageExportInput.path));
      continue;
    }
    if (usageExportInput?.error) {
      usageExportBlockers.push(
        createBlocker('usage-export-unreadable', `Usage export receipt could not be parsed: ${usageExportInput.error}`, usageExportInput.path)
      );
    }
  }
  for (const normalizedUsageExport of normalizedUsageExports) {
    usageExportBlockers.push(...ensureArray(normalizedUsageExport.blockers));
  }
  for (const accountBalanceInput of accountBalanceInputs) {
    if (accountBalanceInput?.exists === false) {
      accountBalanceBlockers.push(createBlocker('account-balance-missing', 'Account balance receipt is missing.', accountBalanceInput.path));
      continue;
    }
    if (accountBalanceInput?.error) {
      accountBalanceBlockers.push(
        createBlocker(
          'account-balance-unreadable',
          `Account balance receipt could not be parsed: ${accountBalanceInput.error}`,
          accountBalanceInput.path
        )
      );
    }
  }
  for (const normalizedAccountBalance of normalizedAccountBalances) {
    accountBalanceBlockers.push(...ensureArray(normalizedAccountBalance.blockers));
  }
  for (const operatorSteeringEventInput of operatorSteeringEventInputs) {
    if (operatorSteeringEventInput?.exists === false) {
      operatorSteeringEventBlockers.push(
        createBlocker('operator-steering-event-missing', 'Operator steering event receipt is missing.', operatorSteeringEventInput.path)
      );
      continue;
    }
    if (operatorSteeringEventInput?.error) {
      operatorSteeringEventBlockers.push(
        createBlocker(
          'operator-steering-event-unreadable',
          `Operator steering event receipt could not be parsed: ${operatorSteeringEventInput.error}`,
          operatorSteeringEventInput.path
        )
      );
    }
  }
  for (const normalizedOperatorSteeringEvent of normalizedOperatorSteeringEvents) {
    operatorSteeringEventBlockers.push(...ensureArray(normalizedOperatorSteeringEvent.blockers));
  }

  const validTurns = evaluation.validTurns;
  const validUsageExports = normalizedUsageExports.filter((entry) => entry.status === 'valid').map((entry) => entry.usageExport);
  const validAccountBalances = normalizedAccountBalances.filter((entry) => entry.status === 'valid').map((entry) => entry.accountBalance);
  const validOperatorSteeringEvents = normalizedOperatorSteeringEvents
    .filter((entry) => entry.status === 'valid')
    .map((entry) => entry.operatorSteeringEvent)
    .sort((left, right) => {
      const leftObservedAt = toTimestamp(left.observedAt) ?? toTimestamp(left.generatedAt) ?? 0;
      const rightObservedAt = toTimestamp(right.observedAt) ?? toTimestamp(right.generatedAt) ?? 0;
      if (rightObservedAt !== leftObservedAt) {
        return rightObservedAt - leftObservedAt;
      }
      return (right.eventKey || '').localeCompare(left.eventKey || '');
    });
  const selectedAccountBalance =
    [...validAccountBalances].sort((left, right) => {
      const leftSnapshot = toTimestamp(left.snapshotAt) ?? 0;
      const rightSnapshot = toTimestamp(right.snapshotAt) ?? 0;
      if (rightSnapshot !== leftSnapshot) {
        return rightSnapshot - leftSnapshot;
      }
      return (right.sourcePath || '').localeCompare(left.sourcePath || '');
    })[0] ?? null;
  const invoiceTurnSelection = selectInvoiceTurn(normalizedInvoiceTurns, validTurns, options.invoiceTurnId);
  const invoiceTurn = invoiceTurnSelection.selectedInvoiceTurn;
  if (normalizeText(options.invoiceTurnId) && !invoiceTurn) {
    invoiceTurnBlockers.push(
      createBlocker(
        'invoice-turn-selection-missing',
        `Explicit invoice turn ${normalizeText(options.invoiceTurnId)} could not be resolved from the available receipts.`,
        null
      )
    );
  }
  const totalUsd = sum(validTurns.map((entry) => entry.amountUsd));
  const exactUsd = sum(evaluation.exactTurns.map((entry) => entry.amountUsd));
  const estimatedUsd = sum(evaluation.estimatedTurns.map((entry) => entry.amountUsd));
  const totalInputTokens = validTurns.reduce((sumValue, entry) => sumValue + (entry.inputTokens ?? 0), 0);
  const totalCachedInputTokens = validTurns.reduce((sumValue, entry) => sumValue + (entry.cachedInputTokens ?? 0), 0);
  const totalOutputTokens = validTurns.reduce((sumValue, entry) => sumValue + (entry.outputTokens ?? 0), 0);
  const totalTokens = validTurns.reduce((sumValue, entry) => sumValue + (entry.totalTokens ?? 0), 0);
  const totalUsageUnits = roundUsd(validTurns.reduce((sumValue, entry) => sumValue + (entry.usageUnitCount ?? 0), 0)) ?? 0;
  const steeredTurns = validTurns.filter((entry) => entry.operatorIntervened === true);
  const unsteeredTurns = validTurns.filter((entry) => entry.operatorIntervened !== true);
  const steeredUsd = sum(steeredTurns.map((entry) => entry.amountUsd));
  const unsteeredUsd = sum(unsteeredTurns.map((entry) => entry.amountUsd));
  const usageExportCreditsReported = sum(validUsageExports.map((entry) => entry.usageCredits));
  const usageExportQuantityReported = sum(validUsageExports.map((entry) => entry.usageQuantity));
  const fundingWindowMatchedOperatorSteeringEvents = invoiceTurn
    ? validOperatorSteeringEvents.filter((entry) => normalizeText(entry.invoiceTurnId) === normalizeText(invoiceTurn.invoiceTurnId))
    : [];
  const unmatchedFundingWindowOperatorSteeringEvents = validOperatorSteeringEvents.filter(
    (entry) => !normalizeText(entry.invoiceTurnId) || normalizeText(entry.invoiceTurnId) !== normalizeText(invoiceTurn?.invoiceTurnId)
  );

  const byProviderCount = new Map();
  const byProviderUsd = new Map();
  const byModelCount = new Map();
  const byModelUsd = new Map();
  const byReasoningEffortCount = new Map();
  const byReasoningEffortUsd = new Map();
  const byIssueCount = new Map();
  const byIssueUsd = new Map();
  const byLaneCount = new Map();
  const byLaneUsd = new Map();
  const byAgentRoleCount = new Map();
  const byAgentRoleUsd = new Map();
  const byRepositoryCount = new Map();
  const byRepositoryUsd = new Map();
  const bySteeringCount = new Map();
  const bySteeringUsd = new Map();

  const rateCards = new Map();
  const sessionIds = new Set();
  const issueNumbers = new Set();
  const laneIds = new Set();
  const repositories = new Set();
  const reasoningEfforts = new Set();
  const steeringKinds = new Set();
  const steeringSources = new Set();
  const operatorSteeringTriggerKinds = new Set();
  const operatorSteeringIssueNumbers = new Set();

  for (const turn of validTurns) {
    incrementCount(byProviderCount, turn.providerId);
    addUsd(byProviderUsd, turn.providerId, turn.amountUsd);
    incrementCount(byModelCount, turn.effectiveModel);
    addUsd(byModelUsd, turn.effectiveModel, turn.amountUsd);
    incrementCount(byReasoningEffortCount, turn.effectiveReasoningEffort || 'unspecified');
    addUsd(byReasoningEffortUsd, turn.effectiveReasoningEffort || 'unspecified', turn.amountUsd);
    incrementCount(byIssueCount, turn.issueNumber != null ? String(turn.issueNumber) : 'unknown');
    addUsd(byIssueUsd, turn.issueNumber != null ? String(turn.issueNumber) : 'unknown', turn.amountUsd);
    incrementCount(byLaneCount, turn.laneId);
    addUsd(byLaneUsd, turn.laneId, turn.amountUsd);
    incrementCount(byAgentRoleCount, turn.agentRole);
    addUsd(byAgentRoleUsd, turn.agentRole, turn.amountUsd);
    incrementCount(byRepositoryCount, turn.repository);
    addUsd(byRepositoryUsd, turn.repository, turn.amountUsd);
    incrementCount(bySteeringCount, turn.operatorIntervened ? 'steered' : 'unsteered');
    addUsd(bySteeringUsd, turn.operatorIntervened ? 'steered' : 'unsteered', turn.amountUsd);
    if (turn.rateCardId || turn.rateCardSource) {
      const rateCardKey = `${turn.rateCardId || 'unknown'}|${turn.rateCardSource || 'unknown'}`;
      if (!rateCards.has(rateCardKey)) {
        rateCards.set(rateCardKey, {
          id: turn.rateCardId,
          source: turn.rateCardSource,
          retrievedAt: turn.rateCardRetrievedAt,
          pricingBasis: turn.pricingBasis
        });
      }
    }
    if (turn.sessionId) {
      sessionIds.add(turn.sessionId);
    }
    if (turn.issueNumber != null) {
      issueNumbers.add(turn.issueNumber);
    }
    if (turn.laneId) {
      laneIds.add(turn.laneId);
    }
    if (turn.repository) {
      repositories.add(turn.repository);
    }
    if (turn.effectiveReasoningEffort) {
      reasoningEfforts.add(turn.effectiveReasoningEffort);
    }
    if (turn.steeringKind) {
      steeringKinds.add(turn.steeringKind);
    }
    if (turn.steeringSource) {
      steeringSources.add(turn.steeringSource);
    }
  }
  for (const event of validOperatorSteeringEvents) {
    if (event.steeringKind) {
      steeringKinds.add(event.steeringKind);
    }
    if (event.triggerKind) {
      operatorSteeringTriggerKinds.add(event.triggerKind);
    }
    if (event.issueNumber != null) {
      operatorSteeringIssueNumbers.add(event.issueNumber);
    }
  }

  const estimatedCreditsConsumed =
    invoiceTurn && invoiceTurn.unitPriceUsd > 0 ? roundUsd(totalUsd / invoiceTurn.unitPriceUsd) : null;
  const creditsRemaining =
    invoiceTurn && estimatedCreditsConsumed != null
      ? roundUsd(Math.max(invoiceTurn.creditsPurchased - estimatedCreditsConsumed, 0))
      : null;
  const estimatedPrepaidUsdRemaining =
    invoiceTurn ? roundUsd(Math.max(invoiceTurn.prepaidUsd - totalUsd, 0)) : null;
  const prepaidUsdConsumedRatio =
    invoiceTurn && invoiceTurn.prepaidUsd > 0 ? roundUsd(totalUsd / invoiceTurn.prepaidUsd) : null;
  const actualUsdConsumed = invoiceTurn?.actualUsdConsumed ?? null;
  const actualCreditsConsumed = invoiceTurn?.actualCreditsConsumed ?? null;
  const heuristicUsdDelta =
    actualUsdConsumed != null ? roundUsd(totalUsd - actualUsdConsumed) : null;
  const heuristicUsdDeltaRatio =
    actualUsdConsumed != null && actualUsdConsumed > 0 ? roundUsd((totalUsd - actualUsdConsumed) / actualUsdConsumed) : null;
  const heuristicCreditsDelta =
    actualCreditsConsumed != null && estimatedCreditsConsumed != null
      ? roundUsd(estimatedCreditsConsumed - actualCreditsConsumed)
      : null;

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: new Date().toISOString(),
    repository: repo,
    inputs: {
      turnReportPaths: turnInputs.map((entry) => ({
        path: safeRelative(entry.path),
        exists: entry.exists,
        error: entry.error ?? null
      })),
      invoiceTurnPaths: invoiceTurnInputs.map((entry) => ({
        path: safeRelative(entry.path),
        exists: entry.exists,
        error: entry.error ?? null
      })),
      usageExportPaths: usageExportInputs.map((entry) => ({
        path: safeRelative(entry.path),
        exists: entry.exists,
        error: entry.error ?? null
      })),
      accountBalancePaths: accountBalanceInputs.map((entry) => ({
        path: safeRelative(entry.path),
        exists: entry.exists,
        error: entry.error ?? null
      })),
      operatorSteeringEventPaths: operatorSteeringEventInputs.map((entry) => ({
        path: safeRelative(entry.path),
        exists: entry.exists,
        error: entry.error ?? null
      })),
      selectedInvoiceTurnId: invoiceTurnSelection.selection.selectedInvoiceTurnId,
      explicitInvoiceTurnId: normalizeText(options.invoiceTurnId) || null
    },
    turns: validTurns,
    summary: {
      status:
        evaluation.blockerCount + invoiceTurnBlockers.length + usageExportBlockers.length + accountBalanceBlockers.length + operatorSteeringEventBlockers.length === 0
          ? evaluation.status
          : 'fail',
      recommendation:
        invoiceTurnBlockers.length > 0
          ? 'repair-invoice-turn-baseline'
          : usageExportBlockers.length + accountBalanceBlockers.length + operatorSteeringEventBlockers.length > 0
            ? 'repair-input-receipts'
          : evaluation.recommendation,
      blockerCount: evaluation.blockerCount + invoiceTurnBlockers.length + usageExportBlockers.length + accountBalanceBlockers.length + operatorSteeringEventBlockers.length,
      blockers: [...evaluation.blockers, ...invoiceTurnBlockers, ...usageExportBlockers, ...accountBalanceBlockers, ...operatorSteeringEventBlockers],
      metrics: {
        totalTurns: validTurns.length,
        exactTurnCount: evaluation.exactTurns.length,
        estimatedTurnCount: evaluation.estimatedTurns.length,
        totalUsd,
        exactUsd,
        estimatedUsd,
        totalInputTokens,
        totalCachedInputTokens,
        totalOutputTokens,
        totalTokens,
        totalUsageUnits,
        steeredTurnCount: steeredTurns.length,
        unsteeredTurnCount: unsteeredTurns.length,
        steeredUsd,
        unsteeredUsd,
        estimatedCreditsConsumed,
        creditsRemaining,
        estimatedPrepaidUsdRemaining,
        prepaidUsdConsumedRatio,
        actualUsdConsumed,
        actualCreditsConsumed,
        heuristicUsdDelta,
        heuristicUsdDeltaRatio,
        heuristicCreditsDelta,
        usageExportWindowCount: validUsageExports.length,
        usageExportCreditsReported,
        usageExportQuantityReported,
        operatorSteeringEventCount: validOperatorSteeringEvents.length,
        operatorSteeringFundingWindowMatchedCount: fundingWindowMatchedOperatorSteeringEvents.length,
        operatorSteeringFundingWindowUnmatchedCount: unmatchedFundingWindowOperatorSteeringEvents.length,
        operatorSteeringIssueCount: operatorSteeringIssueNumbers.size,
        accountBalanceTotalCredits: selectedAccountBalance?.totalCredits ?? null,
        accountBalanceUsedCredits: selectedAccountBalance?.usedCredits ?? null,
        accountBalanceRemainingCredits: selectedAccountBalance?.remainingCredits ?? null
      },
      provenance: {
        sessionIds: [...sessionIds].sort(),
        issueNumbers: [...issueNumbers].sort((left, right) => left - right),
        laneIds: [...laneIds].sort(),
        repositories: [...repositories].sort(),
        reasoningEfforts: [...reasoningEfforts].sort(),
        steeringKinds: [...steeringKinds].sort(),
        steeringSources: [...steeringSources].sort(),
        operatorSteeringTriggerKinds: [...operatorSteeringTriggerKinds].sort(),
        rateCards: [...rateCards.values()].sort((left, right) =>
          `${left.id || ''}|${left.source || ''}`.localeCompare(`${right.id || ''}|${right.source || ''}`)
        ),
        invoiceTurn,
        invoiceTurnSelection: invoiceTurnSelection.selection,
        invoiceTurns: normalizedInvoiceTurns
          .filter((entry) => entry.status === 'valid')
          .map((entry) => entry.invoiceTurn)
          .sort((left, right) => (left.invoiceTurnId || '').localeCompare(right.invoiceTurnId || '')),
        usageExports: validUsageExports.sort((left, right) =>
          `${left.startDate || ''}|${left.endDate || ''}`.localeCompare(`${right.startDate || ''}|${right.endDate || ''}`)
        ),
        accountBalance: selectedAccountBalance,
        operatorSteeringEvents: validOperatorSteeringEvents
      }
    },
    billingWindow: invoiceTurn
      ? {
        invoiceTurnId: invoiceTurn.invoiceTurnId,
        invoiceId: invoiceTurn.invoiceId,
        openedAt: invoiceTurn.openedAt,
        closedAt: invoiceTurn.closedAt,
        pricingBasis: invoiceTurn.pricingBasis,
        activationState: invoiceTurn.activationState,
        fundingPurpose: invoiceTurn.fundingPurpose,
        sourceKind: invoiceTurn.sourceKind,
        sourcePathEvidence: invoiceTurn.sourcePathEvidence,
        operatorNote: invoiceTurn.operatorNote,
          reconciliationStatus: invoiceTurn.reconciliationStatus,
          actualUsdConsumed: invoiceTurn.actualUsdConsumed,
          actualCreditsConsumed: invoiceTurn.actualCreditsConsumed,
          reconciledAt: invoiceTurn.reconciledAt,
          reconciliationSourceKind: invoiceTurn.reconciliationSourceKind,
          reconciliationNote: invoiceTurn.reconciliationNote,
          selection: invoiceTurnSelection.selection
        }
      : null,
    operatorSteering: {
      metrics: {
        totalEventCount: validOperatorSteeringEvents.length,
        fundingWindowMatchedEventCount: fundingWindowMatchedOperatorSteeringEvents.length,
        fundingWindowUnmatchedEventCount: unmatchedFundingWindowOperatorSteeringEvents.length,
        issueCount: operatorSteeringIssueNumbers.size,
        latestObservedAt:
          validOperatorSteeringEvents
            .map((entry) => normalizeDateTime(entry.observedAt) || normalizeDateTime(entry.generatedAt))
            .filter(Boolean)
            .sort()
            .at(-1) ?? null
      },
      events: validOperatorSteeringEvents
    },
    breakdown: {
      byProvider: materializeBreakdown(byProviderCount, byProviderUsd),
      byModel: materializeBreakdown(byModelCount, byModelUsd),
      byReasoningEffort: materializeBreakdown(byReasoningEffortCount, byReasoningEffortUsd),
      byIssue: materializeBreakdown(byIssueCount, byIssueUsd),
      byLane: materializeBreakdown(byLaneCount, byLaneUsd),
      byAgentRole: materializeBreakdown(byAgentRoleCount, byAgentRoleUsd),
      byRepository: materializeBreakdown(byRepositoryCount, byRepositoryUsd),
      bySteering: materializeBreakdown(bySteeringCount, bySteeringUsd)
    }
  };

  const outputPath = path.resolve(options.outputPath || DEFAULT_OUTPUT_PATH);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

  const shouldFail = options.failOnInvalidInputs !== false && report.summary.blockerCount > 0;
  return {
    exitCode: shouldFail ? 1 : 0,
    outputPath,
    report
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/agent-cost-rollup.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --turn-report <path>            Agent cost turn receipt path (repeatable, required).');
  console.log(`  --invoice-turn <path>           Optional invoice turn receipt path (repeatable; auto-discovers ${DEFAULT_INVOICE_TURN_DIR} when omitted).`);
  console.log(`  --usage-export <path>           Optional usage export receipt path (repeatable; auto-discovers ${DEFAULT_USAGE_EXPORT_DIR} when omitted).`);
  console.log(`  --account-balance <path>        Optional account balance receipt path (repeatable; auto-discovers ${DEFAULT_ACCOUNT_BALANCE_DIR} when omitted).`);
  console.log(`  --operator-steering-event <path> Optional operator steering event receipt path (repeatable; auto-discovers ${DEFAULT_OPERATOR_STEERING_EVENT_DIR} when omitted).`);
  console.log('  --invoice-turn-id <value>       Optional explicit invoice turn selection override.');
  console.log(`  --output <path>                 Output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --repo <owner/repo>             Repository slug override.');
  console.log('  --fail-on-invalid-inputs        Exit non-zero when input receipts are invalid (default true).');
  console.log('  --no-fail-on-invalid-inputs     Emit rollup without failing process exit.');
  console.log('  -h, --help                      Show help and exit.');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return 0;
    }
    const result = runAgentCostRollup(options);
    console.log(`[agent-cost-rollup] wrote ${path.resolve(options.outputPath || DEFAULT_OUTPUT_PATH)}`);
    return result.exitCode;
  } catch (error) {
    console.error(error?.message || String(error));
    return 1;
  }
}

const entrypointPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = new URL(import.meta.url).protocol === 'file:' ? process.platform === 'win32'
  ? path.normalize(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'))
  : path.normalize(new URL(import.meta.url).pathname)
  : null;
if (entrypointPath && modulePath && modulePath === entrypointPath) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

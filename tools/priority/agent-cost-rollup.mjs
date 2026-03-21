#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

export const TURN_SCHEMA = 'priority/agent-cost-turn@v1';
export const INVOICE_TURN_SCHEMA = 'priority/agent-cost-invoice-turn@v1';
export const REPORT_SCHEMA = 'priority/agent-cost-rollup@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_INVOICE_TURN_DIR = path.join('tests', 'results', '_agent', 'cost', 'invoice-turns');

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
      operatorNote: normalizeText(payload?.provenance?.operatorNote) || null
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

function selectInvoiceTurn(invoiceTurns, turns, explicitInvoiceTurnId = null) {
  const validInvoiceTurns = invoiceTurns.filter((entry) => entry?.status === 'valid').map((entry) => entry.invoiceTurn);
  const autoSelectableInvoiceTurns = validInvoiceTurns.filter((entry) => normalizeText(entry.activationState) !== 'hold');
  const selectionTimestamp = determineSelectionTimestamp(turns);
  const selectionObservedAt = new Date(selectionTimestamp).toISOString();

  if (validInvoiceTurns.length === 0) {
    return {
      selectedInvoiceTurn: null,
      selection: {
        strategy: 'none',
        explicitInvoiceTurnId: normalizeText(explicitInvoiceTurnId) || null,
        selectionObservedAt,
        candidateCount: 0,
        matchingCandidateCount: 0,
        candidateInvoiceTurnIds: [],
        selectedInvoiceTurnId: null
      }
    };
  }

  if (normalizeText(explicitInvoiceTurnId)) {
    const selectedInvoiceTurn = validInvoiceTurns.find((entry) => entry.invoiceTurnId === normalizeText(explicitInvoiceTurnId)) ?? null;
    return {
      selectedInvoiceTurn,
      selection: {
        strategy: selectedInvoiceTurn ? 'explicit-id' : 'explicit-id-missing',
        explicitInvoiceTurnId: normalizeText(explicitInvoiceTurnId),
        selectionObservedAt,
        candidateCount: validInvoiceTurns.length,
        matchingCandidateCount: selectedInvoiceTurn ? 1 : 0,
        candidateInvoiceTurnIds: validInvoiceTurns.map((entry) => entry.invoiceTurnId).filter(Boolean).sort(),
        selectedInvoiceTurnId: selectedInvoiceTurn?.invoiceTurnId ?? null
      }
    };
  }

  if (autoSelectableInvoiceTurns.length === 0) {
    return {
      selectedInvoiceTurn: null,
      selection: {
        strategy: 'none',
        explicitInvoiceTurnId: null,
        selectionObservedAt,
        candidateCount: validInvoiceTurns.length,
        matchingCandidateCount: 0,
        candidateInvoiceTurnIds: validInvoiceTurns.map((entry) => entry.invoiceTurnId).filter(Boolean).sort(),
        selectedInvoiceTurnId: null
      }
    };
  }

  if (autoSelectableInvoiceTurns.length === 1) {
    return {
      selectedInvoiceTurn: autoSelectableInvoiceTurns[0],
      selection: {
        strategy: 'single-candidate',
        explicitInvoiceTurnId: null,
        selectionObservedAt,
        candidateCount: validInvoiceTurns.length,
        matchingCandidateCount: 1,
        candidateInvoiceTurnIds: validInvoiceTurns.map((entry) => entry.invoiceTurnId).filter(Boolean).sort(),
        selectedInvoiceTurnId: autoSelectableInvoiceTurns[0].invoiceTurnId ?? null
      }
    };
  }

  const activeCandidates = autoSelectableInvoiceTurns.filter((entry) => {
    const openedAt = toTimestamp(entry.openedAt);
    const closedAt = toTimestamp(entry.closedAt);
    return openedAt != null && openedAt <= selectionTimestamp && (closedAt == null || selectionTimestamp <= closedAt);
  });
  const candidatesToRank = activeCandidates.length > 0 ? activeCandidates : autoSelectableInvoiceTurns;
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
    selection: {
      strategy: activeCandidates.length > 0 ? 'active-window-latest-openedAt' : 'latest-openedAt-fallback',
      explicitInvoiceTurnId: null,
      selectionObservedAt,
      candidateCount: validInvoiceTurns.length,
      matchingCandidateCount: activeCandidates.length > 0 ? activeCandidates.length : validInvoiceTurns.length,
      candidateInvoiceTurnIds: validInvoiceTurns.map((entry) => entry.invoiceTurnId).filter(Boolean).sort(),
      selectedInvoiceTurnId: selectedInvoiceTurn?.invoiceTurnId ?? null
    }
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
    if (token === '--turn-report' || token === '--invoice-turn' || token === '--invoice-turn-id' || token === '--output' || token === '--repo') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--turn-report') {
        options.turnReportPaths.push(next);
      } else if (token === '--invoice-turn') {
        options.invoiceTurnPaths.push(next);
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
  const evaluation = evaluateAgentCostRollup({ turnInputs, normalizedTurns });
  const invoiceTurnBlockers = [];
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

  const validTurns = evaluation.validTurns;
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

  const rateCards = new Map();
  const sessionIds = new Set();
  const issueNumbers = new Set();
  const laneIds = new Set();
  const repositories = new Set();
  const reasoningEfforts = new Set();

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
      selectedInvoiceTurnId: invoiceTurnSelection.selection.selectedInvoiceTurnId,
      explicitInvoiceTurnId: normalizeText(options.invoiceTurnId) || null
    },
    turns: validTurns,
    summary: {
      status: evaluation.blockerCount + invoiceTurnBlockers.length === 0 ? evaluation.status : 'fail',
      recommendation:
        invoiceTurnBlockers.length > 0
          ? 'repair-invoice-turn-baseline'
          : evaluation.recommendation,
      blockerCount: evaluation.blockerCount + invoiceTurnBlockers.length,
      blockers: [...evaluation.blockers, ...invoiceTurnBlockers],
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
        estimatedCreditsConsumed,
        creditsRemaining,
        estimatedPrepaidUsdRemaining,
        prepaidUsdConsumedRatio,
        actualUsdConsumed,
        actualCreditsConsumed,
        heuristicUsdDelta,
        heuristicUsdDeltaRatio,
        heuristicCreditsDelta
      },
      provenance: {
        sessionIds: [...sessionIds].sort(),
        issueNumbers: [...issueNumbers].sort((left, right) => left - right),
        laneIds: [...laneIds].sort(),
        repositories: [...repositories].sort(),
        reasoningEfforts: [...reasoningEfforts].sort(),
        rateCards: [...rateCards.values()].sort((left, right) =>
          `${left.id || ''}|${left.source || ''}`.localeCompare(`${right.id || ''}|${right.source || ''}`)
        ),
        invoiceTurn,
        invoiceTurnSelection: invoiceTurnSelection.selection,
        invoiceTurns: normalizedInvoiceTurns
          .filter((entry) => entry.status === 'valid')
          .map((entry) => entry.invoiceTurn)
          .sort((left, right) => (left.invoiceTurnId || '').localeCompare(right.invoiceTurnId || ''))
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
    breakdown: {
      byProvider: materializeBreakdown(byProviderCount, byProviderUsd),
      byModel: materializeBreakdown(byModelCount, byModelUsd),
      byReasoningEffort: materializeBreakdown(byReasoningEffortCount, byReasoningEffortUsd),
      byIssue: materializeBreakdown(byIssueCount, byIssueUsd),
      byLane: materializeBreakdown(byLaneCount, byLaneUsd),
      byAgentRole: materializeBreakdown(byAgentRoleCount, byAgentRoleUsd),
      byRepository: materializeBreakdown(byRepositoryCount, byRepositoryUsd)
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

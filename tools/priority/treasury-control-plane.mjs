#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { runMaterializeAgentCostRollup } from './materialize-agent-cost-rollup.mjs';

export const REPORT_SCHEMA = 'priority/treasury-control-plane@v2';
export const POLICY_SCHEMA = 'priority/treasury-control-plane-policy@v2';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'treasury-control-plane.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'cost',
  'treasury-control-plane.json'
);
export const TREASURY_OPERATION = Object.freeze({
  CORE_DELIVERY: 'core-delivery',
  QUEUE_AUTHORITY: 'queue-authority',
  RELEASE_APPLY: 'release-apply',
  BACKGROUND_FANOUT: 'background-fanout',
  NON_ESSENTIAL_WORK: 'non-essential-work',
  PREMIUM_SAGAN: 'premium-sagan'
});

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

function toNonNegativeNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function toPositiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function roundUsd(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return Number(parsed.toFixed(6));
}

function toTimestamp(value) {
  const normalized = asOptional(value);
  if (!normalized) {
    return null;
  }
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function safeRelative(repoRoot, targetPath) {
  if (!targetPath) {
    return null;
  }
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function createBlocker(code, message, details = null) {
  return {
    code,
    message,
    details: asOptional(details)
  };
}

function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: process.cwd(),
    repo: null,
    policyPath: DEFAULT_POLICY_PATH,
    costRollupPath: null,
    outputPath: null,
    materialize: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--materialize') {
      options.materialize = true;
      continue;
    }
    if (token === '--no-materialize') {
      options.materialize = false;
      continue;
    }
    if (['--repo-root', '--repo', '--policy', '--cost-rollup', '--output'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--repo') options.repo = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--output') options.outputPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function loadPolicy(repoRoot, policyPath) {
  const resolvedPolicyPath = path.resolve(repoRoot, policyPath || DEFAULT_POLICY_PATH);
  const payload = readJson(resolvedPolicyPath);
  if (normalizeText(payload?.schema) !== POLICY_SCHEMA) {
    throw new Error(`Treasury control plane policy must remain ${POLICY_SCHEMA}.`);
  }
  return {
    resolvedPolicyPath,
    policy: payload
  };
}

function chooseTargetRepository(repo, rollup) {
  return asOptional(repo) || asOptional(rollup?.repository) || null;
}

function summarizeBillingWindow(rollup) {
  const billingWindow = rollup?.billingWindow;
  const invoiceTurn = rollup?.summary?.provenance?.invoiceTurn;
  if (!billingWindow || typeof billingWindow !== 'object') {
    return null;
  }
  const prepaidUsd = toNonNegativeNumber(billingWindow.prepaidUsd) ?? toNonNegativeNumber(invoiceTurn?.prepaidUsd);
  const tokenSpendUsd = toNonNegativeNumber(rollup?.summary?.metrics?.totalUsd) ?? 0;
  const remainingUsd =
    toNonNegativeNumber(rollup?.summary?.metrics?.estimatedPrepaidUsdRemaining) ??
    (prepaidUsd != null ? roundUsd(prepaidUsd - tokenSpendUsd) : null);
  return {
    invoiceTurnId: asOptional(billingWindow.invoiceTurnId) ?? asOptional(invoiceTurn?.invoiceTurnId),
    invoiceId: asOptional(billingWindow.invoiceId) ?? asOptional(invoiceTurn?.invoiceId),
    fundingPurpose: asOptional(billingWindow.fundingPurpose) ?? asOptional(invoiceTurn?.fundingPurpose),
    activationState: asOptional(billingWindow.activationState) ?? asOptional(invoiceTurn?.activationState),
    prepaidUsd,
    tokenSpendUsd,
    remainingUsd,
    pricingBasis: asOptional(billingWindow.pricingBasis) ?? asOptional(invoiceTurn?.pricingBasis),
    selectionMode: asOptional(billingWindow?.selection?.mode),
    selectionReason: asOptional(billingWindow?.selection?.reason)
  };
}

function summarizeReservedFundingWindows(rollup, policy, billingWindowInvoiceTurnId) {
  const reservedPurposes = Array.isArray(policy.reservedFundingPurposes)
    ? policy.reservedFundingPurposes.map((entry) => normalizeText(entry).toLowerCase()).filter(Boolean)
    : ['calibration'];
  const reservedActivationStates = Array.isArray(policy.reservedActivationStates)
    ? policy.reservedActivationStates.map((entry) => normalizeText(entry).toLowerCase()).filter(Boolean)
    : ['hold'];
  const invoiceTurns = Array.isArray(rollup?.summary?.provenance?.invoiceTurns)
    ? rollup.summary.provenance.invoiceTurns
    : [];
  const reservedWindows = invoiceTurns
    .filter((entry) => {
      const fundingPurpose = normalizeText(entry?.fundingPurpose).toLowerCase();
      const activationState = normalizeText(entry?.activationState).toLowerCase();
      const invoiceTurnId = asOptional(entry?.invoiceTurnId);
      return reservedPurposes.includes(fundingPurpose)
        && reservedActivationStates.includes(activationState)
        && invoiceTurnId
        && invoiceTurnId !== billingWindowInvoiceTurnId;
    })
    .map((entry) => ({
      invoiceTurnId: asOptional(entry.invoiceTurnId),
      invoiceId: asOptional(entry.invoiceId),
      fundingPurpose: asOptional(entry.fundingPurpose),
      activationState: asOptional(entry.activationState),
      prepaidUsd: toNonNegativeNumber(entry.prepaidUsd),
      operatorNote: asOptional(entry.operatorNote)
    }));

  return {
    count: reservedWindows.length,
    totalReservedUsd:
      roundUsd(reservedWindows.reduce((sum, entry) => sum + (Number(entry.prepaidUsd ?? 0) || 0), 0)) ?? 0,
    windows: reservedWindows
  };
}

function summarizeAccountBalance(rollup) {
  const metrics = rollup?.summary?.metrics ?? {};
  const accountBalance = rollup?.summary?.provenance?.accountBalance ?? {};
  const totalCredits = toNonNegativeNumber(metrics.accountBalanceTotalCredits ?? accountBalance?.totalCredits);
  const usedCredits = toNonNegativeNumber(metrics.accountBalanceUsedCredits ?? accountBalance?.usedCredits);
  const remainingCredits = toNonNegativeNumber(
    metrics.accountBalanceRemainingCredits ?? accountBalance?.remainingCredits
  );
  const unitPriceUsd =
    toNonNegativeNumber(rollup?.summary?.provenance?.invoiceTurn?.unitPriceUsd) ??
    toNonNegativeNumber(rollup?.billingWindow?.credits?.unitPriceUsd);
  const remainingUsdEstimate =
    remainingCredits != null && unitPriceUsd != null ? roundUsd(remainingCredits * unitPriceUsd) : null;

  if (totalCredits == null && usedCredits == null && remainingCredits == null && remainingUsdEstimate == null) {
    return null;
  }

  return {
    totalCredits,
    usedCredits,
    remainingCredits,
    unitPriceUsd,
    remainingUsdEstimate,
    sourceKind: asOptional(accountBalance?.sourceKind),
    sourcePathEvidence: asOptional(accountBalance?.sourcePathEvidence),
    operatorNote: asOptional(accountBalance?.operatorNote)
  };
}

function evaluateAccountBalanceFreshness(rollup, policy, now) {
  const accountBalance = rollup?.summary?.provenance?.accountBalance ?? {};
  const snapshotAt = asOptional(accountBalance?.snapshotAt);
  const snapshotTimestamp = toTimestamp(snapshotAt);
  const maxAgeHours = toPositiveInteger(policy?.thresholds?.accountBalanceMaxAgeHours) ?? 24;
  if (snapshotTimestamp == null) {
    return {
      status: 'unknown',
      blocker: createBlocker(
        'account-balance-snapshot-missing',
        'Treasury requires account-balance snapshotAt evidence to enforce safe spend.',
        asOptional(accountBalance?.sourcePathEvidence)
      )
    };
  }

  const ageHours = Math.max(0, (now.getTime() - snapshotTimestamp) / (60 * 60 * 1000));
  if (ageHours > maxAgeHours) {
    return {
      status: 'stale',
      ageHours: roundUsd(ageHours),
      maxAgeHours,
      blocker: createBlocker(
        'account-balance-stale',
        `Treasury requires account-balance evidence no older than ${maxAgeHours}h; current snapshot age is ${roundUsd(ageHours)}h.`,
        asOptional(accountBalance?.sourcePathEvidence) || snapshotAt
      )
    };
  }

  return {
    status: 'fresh',
    ageHours: roundUsd(ageHours),
    maxAgeHours,
    blocker: null
  };
}

function summarizeOperationalHeadroom(accountBalance, reservedFunding, policy) {
  const reservedUsd = toNonNegativeNumber(reservedFunding?.totalReservedUsd) ?? 0;
  const accountRemainingUsdEstimate = toNonNegativeNumber(accountBalance?.remainingUsdEstimate);
  const reserveNearOperationalHeadroomUsd =
    toNonNegativeNumber(policy?.thresholds?.reserveNearOperationalHeadroomUsd) ?? 100;

  if (accountRemainingUsdEstimate == null) {
    return {
      accountRemainingUsdEstimate: null,
      operationalHeadroomUsd: null,
      operationalHeadroomStatus: 'unknown',
      possibleOperationalHeadroomUpperBoundUsd: null,
      basis: 'missing-account-balance'
    };
  }

  const operationalHeadroomUsd = roundUsd(Math.max(accountRemainingUsdEstimate - reservedUsd, 0)) ?? 0;
  const operationalHeadroomStatus =
    operationalHeadroomUsd <= 0
      ? 'reserve-protected-only'
      : operationalHeadroomUsd <= reserveNearOperationalHeadroomUsd
        ? 'reserve-near'
        : 'healthy';

  return {
    accountRemainingUsdEstimate,
    operationalHeadroomUsd,
    operationalHeadroomStatus,
    possibleOperationalHeadroomUpperBoundUsd: operationalHeadroomUsd,
    basis: 'account-balance-minus-reserve'
  };
}

function deriveOperatorBudgetState({ operatorBudgetCapUsd, operatorLaborObservedUsd, operatorLaborMissingTurnCount }) {
  const observedRemainingUpperBoundUsd =
    operatorBudgetCapUsd == null ? null : roundUsd(Math.max(0, operatorBudgetCapUsd - operatorLaborObservedUsd));
  const observedRemainingStatus =
    operatorBudgetCapUsd == null ? 'unknown' : operatorLaborMissingTurnCount > 0 ? 'upper-bound' : 'observed';
  const spendableStatus =
    operatorBudgetCapUsd == null ? 'unknown' : operatorLaborMissingTurnCount > 0 ? 'unreconciled' : 'observed';
  const spendableUsd = spendableStatus === 'observed' ? observedRemainingUpperBoundUsd : null;

  return {
    operatorBudgetCapUsd,
    operatorBudgetObservedRemainingUpperBoundUsd: observedRemainingUpperBoundUsd,
    operatorBudgetObservedRemainingStatus: observedRemainingStatus,
    operatorBudgetRemainingLowerBoundUsd: spendableStatus === 'observed' ? observedRemainingUpperBoundUsd : null,
    operatorBudgetRemainingStatus: spendableStatus === 'observed' ? 'observed' : 'unknown',
    operatorBudgetSpendableUsd: spendableUsd,
    operatorBudgetSpendableStatus: spendableStatus
  };
}

function deriveBudgetPressureState({
  blockers,
  operationalHeadroomStatus,
  operationalHeadroomUsd,
  operatorBudgetSpendableStatus,
  policy
}) {
  const healthyOperationalHeadroomUsd =
    toNonNegativeNumber(policy?.thresholds?.healthyOperationalHeadroomUsd) ?? 250;
  if (Array.isArray(blockers) && blockers.length > 0) {
    return 'blocked';
  }
  if (operationalHeadroomStatus === 'reserve-protected-only') {
    return 'stop-nonessential-spend';
  }
  if (operationalHeadroomStatus === 'reserve-near') {
    return 'tight';
  }
  if (operationalHeadroomUsd == null || operatorBudgetSpendableStatus !== 'observed') {
    return 'cautious';
  }
  if (operationalHeadroomUsd < healthyOperationalHeadroomUsd) {
    return 'cautious';
  }
  return 'healthy';
}

function deriveSpendPolicyState(budgetPressureState) {
  switch (budgetPressureState) {
    case 'healthy':
      return 'healthy';
    case 'cautious':
      return 'cautious-delivery';
    case 'tight':
      return 'core-delivery-only';
    case 'stop-nonessential-spend':
      return 'reserve-protected-only';
    default:
      return 'blocked';
  }
}

function deriveControls({
  budgetPressureState,
  operationalHeadroomUsd,
  operatorBudgetSpendableStatus,
  policy
}) {
  const premiumThreshold = toNonNegativeNumber(policy?.thresholds?.premiumSaganMinimumOperationalHeadroomUsd) ?? 150;
  const backgroundThreshold =
    toNonNegativeNumber(policy?.thresholds?.backgroundFanoutMinimumOperationalHeadroomUsd) ?? 125;
  const nonEssentialThreshold =
    toNonNegativeNumber(policy?.thresholds?.nonEssentialWorkMinimumOperationalHeadroomUsd) ?? 100;
  const healthyBackgroundMax = toPositiveInteger(policy?.limits?.healthyBackgroundSubagentsMax) ?? 2;
  const cautiousBackgroundMax = toPositiveInteger(policy?.limits?.cautiousBackgroundSubagentsMax) ?? 1;

  const premiumEligible =
    budgetPressureState === 'healthy'
    && operatorBudgetSpendableStatus === 'observed'
    && operationalHeadroomUsd != null
    && operationalHeadroomUsd >= premiumThreshold;
  const backgroundEligible =
    (budgetPressureState === 'healthy' || budgetPressureState === 'cautious')
    && operatorBudgetSpendableStatus === 'observed'
    && operationalHeadroomUsd != null
    && operationalHeadroomUsd >= backgroundThreshold;
  const backgroundMax = !backgroundEligible
    ? 0
    : budgetPressureState === 'healthy'
      ? healthyBackgroundMax
      : cautiousBackgroundMax;
  const nonEssentialAllowed =
    budgetPressureState === 'healthy'
    && operationalHeadroomUsd != null
    && operationalHeadroomUsd >= nonEssentialThreshold;

  return {
    premiumSaganMode: {
      allowed: premiumEligible,
      requiresOperatorAuthorization: true,
      requiresExplicitOperatorPrompt: true,
      minimumOperationalHeadroomUsd: premiumThreshold,
      estimatedFollowupAuthorizationsNeeded:
        toPositiveInteger(policy?.limits?.premiumSaganFollowupAuthorizationsEstimate) ?? 1,
      reason: premiumEligible ? 'budget-healthy' : `budget-${budgetPressureState}`
    },
    backgroundFanout: {
      allowed: backgroundEligible,
      minimumOperationalHeadroomUsd: backgroundThreshold,
      maximumConcurrentSubagents: backgroundMax,
      reason: backgroundEligible ? `budget-${budgetPressureState}` : `budget-${budgetPressureState}`
    },
    nonEssentialWork: {
      allowed: nonEssentialAllowed,
      minimumOperationalHeadroomUsd: nonEssentialThreshold,
      reason: nonEssentialAllowed ? 'budget-healthy' : `budget-${budgetPressureState}`
    }
  };
}

function deriveOperationControls({ spendPolicyState, budgetPressureState, controls }) {
  const coreDeliveryAllowed =
    ['healthy', 'cautious-delivery', 'core-delivery-only'].includes(spendPolicyState)
    && budgetPressureState !== 'blocked';
  const coreDeliveryReason = coreDeliveryAllowed
    ? `policy-${spendPolicyState}`
    : budgetPressureState === 'blocked'
      ? 'treasury-blocked'
      : `policy-${spendPolicyState}`;

  return {
    [TREASURY_OPERATION.CORE_DELIVERY]: {
      allowed: coreDeliveryAllowed,
      reason: coreDeliveryReason
    },
    [TREASURY_OPERATION.QUEUE_AUTHORITY]: {
      allowed: coreDeliveryAllowed,
      reason: coreDeliveryReason
    },
    [TREASURY_OPERATION.RELEASE_APPLY]: {
      allowed: coreDeliveryAllowed,
      reason: coreDeliveryReason
    },
    [TREASURY_OPERATION.BACKGROUND_FANOUT]: {
      allowed: controls.backgroundFanout.allowed === true,
      reason: controls.backgroundFanout.reason
    },
    [TREASURY_OPERATION.NON_ESSENTIAL_WORK]: {
      allowed: controls.nonEssentialWork.allowed === true,
      reason: controls.nonEssentialWork.reason
    },
    [TREASURY_OPERATION.PREMIUM_SAGAN]: {
      allowed: controls.premiumSaganMode.allowed === true,
      reason: controls.premiumSaganMode.reason,
      requiresOperatorAuthorization: controls.premiumSaganMode.requiresOperatorAuthorization === true,
      requiresExplicitOperatorPrompt: controls.premiumSaganMode.requiresExplicitOperatorPrompt === true,
      estimatedFollowupAuthorizationsNeeded:
        toPositiveInteger(controls.premiumSaganMode.estimatedFollowupAuthorizationsNeeded) ?? 1
    }
  };
}

function normalizeTreasuryOperation(value) {
  const normalized = asOptional(value)?.toLowerCase();
  return Object.values(TREASURY_OPERATION).includes(normalized) ? normalized : null;
}

function buildAuthorizationEstimate(operationControl = {}) {
  const requiresOperatorAuthorization = operationControl.requiresOperatorAuthorization === true;
  const requiresExplicitOperatorPrompt = operationControl.requiresExplicitOperatorPrompt === true;
  const estimatedFollowupAuthorizationsNeeded =
    requiresOperatorAuthorization
      ? toPositiveInteger(operationControl.estimatedFollowupAuthorizationsNeeded) ?? 1
      : 0;

  return {
    requiresOperatorAuthorization,
    requiresExplicitOperatorPrompt,
    estimatedFollowupAuthorizationsNeeded
  };
}

export function evaluateTreasuryOperation(report, operation) {
  const normalizedOperation = normalizeTreasuryOperation(operation);
  if (!normalizedOperation) {
    return {
      allowed: false,
      operation: operation ?? null,
      code: 'treasury-operation-unknown',
      reason: 'Unknown treasury operation request.',
      operationControl: null,
      authorization: buildAuthorizationEstimate()
    };
  }

  if (!report || typeof report !== 'object') {
    return {
      allowed: false,
      operation: normalizedOperation,
      code: 'treasury-report-missing',
      reason: 'Treasury control plane report is missing.',
      operationControl: null,
      authorization: buildAuthorizationEstimate()
    };
  }

  if (normalizeText(report.schema) !== REPORT_SCHEMA) {
    return {
      allowed: false,
      operation: normalizedOperation,
      code: 'treasury-schema-mismatch',
      reason: `Treasury control plane report must remain ${REPORT_SCHEMA}.`,
      operationControl: null,
      authorization: buildAuthorizationEstimate()
    };
  }

  const operationControl = report?.controls?.operations?.[normalizedOperation];
  const authorization = buildAuthorizationEstimate(operationControl);
  if (!operationControl || typeof operationControl !== 'object') {
    return {
      allowed: false,
      operation: normalizedOperation,
      code: 'treasury-operation-missing',
      reason: `Treasury control plane did not publish an operation control for ${normalizedOperation}.`,
      operationControl: null,
      authorization
    };
  }

  if (operationControl.allowed !== true) {
    return {
      allowed: false,
      operation: normalizedOperation,
      code: 'treasury-operation-denied',
      reason:
        operationControl.reason
          ? `Treasury denied ${normalizedOperation}: ${operationControl.reason}.`
          : `Treasury denied ${normalizedOperation}.`,
      operationControl,
      authorization
    };
  }

  return {
    allowed: true,
    operation: normalizedOperation,
    code: 'treasury-operation-allowed',
    reason: operationControl.reason || 'treasury-allowed',
    operationControl,
    authorization
  };
}

function deriveConfidence({ blockers, sourceConflictCount, operationalHeadroomStatus, operatorBudgetSpendableStatus }) {
  if (Array.isArray(blockers) && blockers.length > 0) {
    return 'blocked';
  }
  if ((sourceConflictCount ?? 0) > 0) {
    return 'conflicted';
  }
  if (operationalHeadroomStatus === 'unknown' || operatorBudgetSpendableStatus !== 'observed') {
    return 'lower-bound-only';
  }
  return 'observed';
}

function determineStatus(budgetPressureState) {
  if (budgetPressureState === 'blocked') {
    return 'blocked';
  }
  return budgetPressureState === 'healthy' ? 'pass' : 'warn';
}

function determineRecommendation({ budgetPressureState, confidence }) {
  switch (budgetPressureState) {
    case 'blocked':
      return 'repair-treasury-inputs';
    case 'stop-nonessential-spend':
      return 'protect-calibration-reserve';
    case 'tight':
      return 'constrain-spend-to-core-delivery';
    case 'cautious':
      return confidence === 'lower-bound-only'
        ? 'reconcile-budget-before-expanding-spend'
        : 'stay-budget-cautious';
    default:
      return 'treasury-control-plane-ready';
  }
}

export function buildTreasuryControlPlaneReport({
  rollup,
  repository,
  operatorBudgetCapUsd,
  reservedFunding,
  billingWindow,
  source,
  blockers,
  policy,
  now
}) {
  const metrics = rollup?.summary?.metrics ?? {};
  const tokenSpendUsd = toNonNegativeNumber(metrics.totalUsd) ?? 0;
  const operatorLaborObservedUsd = toNonNegativeNumber(metrics.operatorLaborUsd) ?? 0;
  const operatorLaborMissingTurnCount = Number(metrics.operatorLaborMissingTurnCount ?? 0) || 0;
  const observedBlendedLowerBoundUsd = roundUsd(tokenSpendUsd + operatorLaborObservedUsd) ?? 0;
  const knownBlendedUsd = toNonNegativeNumber(metrics.blendedTotalUsd);
  const accountBalance = summarizeAccountBalance(rollup);
  const operationalHeadroom = summarizeOperationalHeadroom(accountBalance, reservedFunding, policy);
  const operatorBudget = deriveOperatorBudgetState({
    operatorBudgetCapUsd,
    operatorLaborObservedUsd,
    operatorLaborMissingTurnCount
  });
  const sourceConflictCount = 0;
  const confidence = deriveConfidence({
    blockers,
    sourceConflictCount,
    operationalHeadroomStatus: operationalHeadroom.operationalHeadroomStatus,
    operatorBudgetSpendableStatus: operatorBudget.operatorBudgetSpendableStatus
  });
  const budgetPressureState = deriveBudgetPressureState({
    blockers,
    operationalHeadroomStatus: operationalHeadroom.operationalHeadroomStatus,
    operationalHeadroomUsd: operationalHeadroom.operationalHeadroomUsd,
    operatorBudgetSpendableStatus: operatorBudget.operatorBudgetSpendableStatus,
    policy
  });
  const spendPolicyState = deriveSpendPolicyState(budgetPressureState);
  const controls = deriveControls({
    budgetPressureState,
    operationalHeadroomUsd: operationalHeadroom.operationalHeadroomUsd,
    operatorBudgetSpendableStatus: operatorBudget.operatorBudgetSpendableStatus,
    policy
  });
  const operationControls = deriveOperationControls({
    spendPolicyState,
    budgetPressureState,
    controls
  });
  const safeSpendableUsd = Array.isArray(blockers) && blockers.length > 0 ? 0 : operationalHeadroom.operationalHeadroomUsd;
  const possibleSpendableUpperBoundUsd = operationalHeadroom.possibleOperationalHeadroomUpperBoundUsd;
  const protectedReserveUsd = toNonNegativeNumber(reservedFunding?.totalReservedUsd) ?? 0;

  return {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    summary: {
      status: determineStatus(budgetPressureState),
      recommendation: determineRecommendation({ budgetPressureState, confidence }),
      confidence,
      spendPolicyState,
      budgetPressureState,
      tokenSpendUsd,
      operatorLaborObservedUsd,
      operatorLaborMissingTurnCount,
      observedBlendedLowerBoundUsd,
      knownBlendedUsd,
      protectedReserveUsd,
      accountRemainingUsdEstimate: operationalHeadroom.accountRemainingUsdEstimate,
      operationalHeadroomUsd: operationalHeadroom.operationalHeadroomUsd,
      operationalHeadroomStatus: operationalHeadroom.operationalHeadroomStatus,
      safeSpendableUsd,
      possibleSpendableUpperBoundUsd,
      sourceConflictCount,
      operatorBudgetCapUsd: operatorBudget.operatorBudgetCapUsd,
      operatorBudgetObservedRemainingUpperBoundUsd: operatorBudget.operatorBudgetObservedRemainingUpperBoundUsd,
      operatorBudgetObservedRemainingStatus: operatorBudget.operatorBudgetObservedRemainingStatus,
      operatorBudgetRemainingLowerBoundUsd: operatorBudget.operatorBudgetRemainingLowerBoundUsd,
      operatorBudgetRemainingStatus: operatorBudget.operatorBudgetRemainingStatus,
      operatorBudgetSpendableUsd: operatorBudget.operatorBudgetSpendableUsd,
      operatorBudgetSpendableStatus: operatorBudget.operatorBudgetSpendableStatus,
      coreDeliveryAllowed: operationControls[TREASURY_OPERATION.CORE_DELIVERY].allowed,
      queueAuthorityAllowed: operationControls[TREASURY_OPERATION.QUEUE_AUTHORITY].allowed,
      releaseApplyAllowed: operationControls[TREASURY_OPERATION.RELEASE_APPLY].allowed,
      premiumSaganAllowed: controls.premiumSaganMode.allowed,
      premiumAuthorizationPromptRequired: controls.premiumSaganMode.requiresExplicitOperatorPrompt === true,
      premiumAuthorizationFollowupEstimate:
        toPositiveInteger(controls.premiumSaganMode.estimatedFollowupAuthorizationsNeeded) ?? 1,
      backgroundFanoutAllowed: controls.backgroundFanout.allowed,
      maxBackgroundSubagents: controls.backgroundFanout.maximumConcurrentSubagents,
      nonEssentialWorkAllowed: controls.nonEssentialWork.allowed,
      calibrationReserveProtected: protectedReserveUsd > 0
    },
    turns: {
      totalTurns: Number(metrics.totalTurns ?? 0) || 0,
      liveTurnCount: Number(metrics.liveTurnCount ?? 0) || 0,
      backgroundTurnCount: Number(metrics.backgroundTurnCount ?? 0) || 0
    },
    funding: {
      billingWindow,
      accountBalance,
      reservedFunding
    },
    controls: {
      ...controls,
      operations: operationControls
    },
    source,
    blockers: Array.isArray(blockers) ? blockers.filter(Boolean) : []
  };
}

export function runTreasuryControlPlane(
  options,
  {
    now = new Date(),
    readJsonFn = readJson,
    writeJsonFn = writeJson,
    runMaterializeAgentCostRollupFn = runMaterializeAgentCostRollup
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || process.cwd());
  const { resolvedPolicyPath, policy } = loadPolicy(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  let costRollupPath = path.resolve(
    repoRoot,
    options.costRollupPath || asOptional(policy.costRollupPath) || path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json')
  );
  let costRollupMaterialized = false;
  let costRollupMaterializationReportPath = null;
  const blockers = [];

  const shouldMaterialize = options.materialize ?? Boolean(policy.materializeCostRollup);
  if (shouldMaterialize) {
    try {
      const materializeResult = runMaterializeAgentCostRollupFn({
        repoRoot,
        repo: options.repo,
        policyPath: asOptional(policy.materializationPolicyPath) || undefined,
        costRollupPath,
        outputPath: asOptional(policy.materializationReportPath) || undefined
      });
      costRollupMaterialized = true;
      costRollupPath = path.resolve(materializeResult.costRollupPath || costRollupPath);
      costRollupMaterializationReportPath = safeRelative(repoRoot, materializeResult.outputPath);
    } catch (error) {
      blockers.push(createBlocker('cost-rollup-materialization-failed', error?.message || String(error)));
    }
  }

  let rollup = null;
  if (!fs.existsSync(costRollupPath)) {
    blockers.push(
      createBlocker('cost-rollup-missing', 'Agent cost rollup is missing.', safeRelative(repoRoot, costRollupPath))
    );
  } else {
    try {
      rollup = readJsonFn(costRollupPath);
      if (normalizeText(rollup?.schema) !== 'priority/agent-cost-rollup@v1') {
        blockers.push(
          createBlocker(
            'cost-rollup-schema-mismatch',
            'Agent cost rollup schema must remain priority/agent-cost-rollup@v1.',
            safeRelative(repoRoot, costRollupPath)
          )
        );
      }
    } catch (error) {
      blockers.push(
        createBlocker('cost-rollup-unreadable', error?.message || String(error), safeRelative(repoRoot, costRollupPath))
      );
    }
  }

  if (rollup && typeof rollup === 'object') {
    const accountBalanceFreshness = evaluateAccountBalanceFreshness(rollup, policy, now);
    if (accountBalanceFreshness.blocker) {
      blockers.push(accountBalanceFreshness.blocker);
    }
  }

  const billingWindow = summarizeBillingWindow(rollup);
  const reservedFunding = summarizeReservedFundingWindows(rollup, policy, billingWindow?.invoiceTurnId ?? null);
  const repository = chooseTargetRepository(options.repo, rollup);
  const operatorBudgetCapUsd = toNonNegativeNumber(policy.operatorBudgetCapUsd);
  const outputPath = path.resolve(repoRoot, options.outputPath || asOptional(policy.outputPath) || DEFAULT_OUTPUT_PATH);

  const report = buildTreasuryControlPlaneReport({
    rollup,
    repository,
    operatorBudgetCapUsd,
    reservedFunding,
    billingWindow,
    source: {
      policyPath: safeRelative(repoRoot, resolvedPolicyPath),
      costRollupPath: safeRelative(repoRoot, costRollupPath),
      costRollupMaterialized,
      costRollupMaterializationReportPath,
      operatorCostProfilePath:
        asOptional(rollup?.summary?.provenance?.operatorProfiles?.[0]?.operatorProfilePath) ||
        'tools/policy/operator-cost-profile.json',
      outputPath: safeRelative(repoRoot, outputPath)
    },
    blockers,
    policy,
    now
  });

  writeJsonFn(outputPath, report);
  return {
    report,
    outputPath
  };
}

export function runTreasuryOperationGuard(
  options,
  {
    runTreasuryControlPlaneFn = runTreasuryControlPlane
  } = {}
) {
  const repoRoot = path.resolve(options?.repoRoot || process.cwd());
  let report = null;
  let outputPath = null;
  let decision = null;

  try {
    const treasuryResult = runTreasuryControlPlaneFn({
      repoRoot,
      repo: options?.repo,
      policyPath: options?.policyPath,
      costRollupPath: options?.costRollupPath,
      outputPath: options?.outputPath,
      materialize: options?.materialize
    });
    report = treasuryResult?.report ?? null;
    outputPath = treasuryResult?.outputPath ?? null;
    decision = evaluateTreasuryOperation(report, options?.operation);
  } catch (error) {
    decision = {
      allowed: false,
      operation: normalizeTreasuryOperation(options?.operation),
      code: 'treasury-control-plane-unavailable',
      reason: error?.message || String(error),
      operationControl: null,
      authorization: buildAuthorizationEstimate()
    };
  }

  return {
    report,
    outputPath,
    decision
  };
}

function printUsage() {
  [
    'Usage: node tools/priority/treasury-control-plane.mjs [options]',
    '',
    'Builds the governed treasury control-plane receipt used by governor and comment projections.',
    '',
    `  --policy <path>            Treasury policy path (default: ${DEFAULT_POLICY_PATH}).`,
    '  --repo-root <path>         Repository root (default: cwd).',
    '  --repo <owner/repo>        Repository slug override.',
    '  --cost-rollup <path>       Cost rollup path override.',
    `  --output <path>            JSON report path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  --materialize              Force cost-rollup materialization before read.',
    '  --no-materialize           Skip cost-rollup materialization.',
    '  -h, --help                 Show this message.'
  ].forEach((line) => console.log(line));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv);
    if (options.help) {
      printUsage();
      process.exit(0);
    }
    const result = runTreasuryControlPlane(options);
    console.log(`[treasury-control-plane] wrote ${result.outputPath}`);
  } catch (error) {
    console.error(`[treasury-control-plane] ${error.message}`);
    process.exit(1);
  }
}

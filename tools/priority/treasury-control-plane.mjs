#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { runMaterializeAgentCostRollup } from './materialize-agent-cost-rollup.mjs';

export const REPORT_SCHEMA = 'priority/treasury-control-plane@v1';
export const POLICY_SCHEMA = 'priority/treasury-control-plane-policy@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'treasury-control-plane.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'cost',
  'treasury-control-plane.json'
);

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
      minimumOperationalHeadroomUsd: premiumThreshold,
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
  const safeSpendableUsd = operationalHeadroom.operationalHeadroomUsd;
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
      premiumSaganAllowed: controls.premiumSaganMode.allowed,
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
    controls,
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

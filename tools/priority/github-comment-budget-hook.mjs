#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runMaterializeAgentCostRollup } from './materialize-agent-cost-rollup.mjs';

export const REPORT_SCHEMA = 'priority/github-comment-budget-hook@v1';
export const POLICY_SCHEMA = 'priority/github-comment-budget-hook-policy@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'github-comment-budget-hook.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'github-comment-budget-hook.json');
export const DEFAULT_MARKDOWN_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'github-comment-budget-hook.md');
export const COMMENT_HOOK_START_MARKER = '<!-- priority:github-comment-budget-hook:start -->';
export const COMMENT_HOOK_END_MARKER = '<!-- priority:github-comment-budget-hook:end -->';
export const COMMENT_HOOK_JSON_PREFIX = '<!-- priority:github-comment-budget-hook:json ';

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

function formatUsd(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return 'n/a';
  }
  return `$${numeric.toFixed(6)}`;
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

function writeText(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, payload, 'utf8');
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
    targetKind: 'unknown',
    targetNumber: null,
    policyPath: DEFAULT_POLICY_PATH,
    costRollupPath: null,
    outputPath: null,
    markdownOutputPath: null,
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
    if (['--repo-root', '--repo', '--target-kind', '--target-number', '--policy', '--cost-rollup', '--output', '--markdown-output'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--repo') options.repo = next;
      if (token === '--target-kind') options.targetKind = next;
      if (token === '--target-number') options.targetNumber = toPositiveInteger(next);
      if (token === '--policy') options.policyPath = next;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--markdown-output') options.markdownOutputPath = next;
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
    throw new Error(`Comment budget hook policy must remain ${POLICY_SCHEMA}.`);
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
  const reservedPurposes = Array.isArray(policy.reservedFundingPurposes) ? policy.reservedFundingPurposes.map((entry) => normalizeText(entry).toLowerCase()).filter(Boolean) : ['calibration'];
  const reservedActivationStates = Array.isArray(policy.reservedActivationStates) ? policy.reservedActivationStates.map((entry) => normalizeText(entry).toLowerCase()).filter(Boolean) : ['hold'];
  const invoiceTurns = Array.isArray(rollup?.summary?.provenance?.invoiceTurns) ? rollup.summary.provenance.invoiceTurns : [];
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
    totalReservedUsd: roundUsd(reservedWindows.reduce((sum, entry) => sum + (Number(entry.prepaidUsd ?? 0) || 0), 0)) ?? 0,
    windows: reservedWindows
  };
}

function summarizeAccountBalance(rollup) {
  const metrics = rollup?.summary?.metrics ?? {};
  const accountBalance = rollup?.summary?.provenance?.accountBalance ?? {};
  const totalCredits = toNonNegativeNumber(metrics.accountBalanceTotalCredits ?? accountBalance?.totalCredits);
  const usedCredits = toNonNegativeNumber(metrics.accountBalanceUsedCredits ?? accountBalance?.usedCredits);
  const remainingCredits = toNonNegativeNumber(metrics.accountBalanceRemainingCredits ?? accountBalance?.remainingCredits);
  const unitPriceUsd =
    toNonNegativeNumber(rollup?.summary?.provenance?.invoiceTurn?.unitPriceUsd) ??
    toNonNegativeNumber(rollup?.billingWindow?.credits?.unitPriceUsd);
  const remainingUsdEstimate =
    remainingCredits != null && unitPriceUsd != null
      ? roundUsd(remainingCredits * unitPriceUsd)
      : null;

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

function summarizeOperationalHeadroom(accountBalance, reservedFunding) {
  const reservedUsd = toNonNegativeNumber(reservedFunding?.totalReservedUsd) ?? 0;
  const accountRemainingUsdEstimate = toNonNegativeNumber(accountBalance?.remainingUsdEstimate);
  if (accountRemainingUsdEstimate == null) {
    return {
      accountRemainingUsdEstimate: null,
      operationalHeadroomUsd: null,
      status: 'unknown',
      basis: 'missing-account-balance'
    };
  }

  const operationalHeadroomUsd = roundUsd(Math.max(accountRemainingUsdEstimate - reservedUsd, 0)) ?? 0;
  const status =
    operationalHeadroomUsd <= 0
      ? 'reserve-protected-only'
      : operationalHeadroomUsd <= 100
        ? 'reserve-near'
        : 'healthy';

  return {
    accountRemainingUsdEstimate,
    operationalHeadroomUsd,
    status,
    basis: 'account-balance-minus-reserve'
  };
}

function buildJsonHookPayload(report) {
  return {
    schema: report.schema,
    generatedAt: report.generatedAt,
    repository: report.repository,
    target: report.target,
    status: report.summary.status,
    observedBlendedLowerBoundUsd: report.summary.observedBlendedLowerBoundUsd,
    knownBlendedUsd: report.summary.knownBlendedUsd,
    tokenSpendUsd: report.summary.tokenSpendUsd,
    operatorLaborObservedUsd: report.summary.operatorLaborObservedUsd,
    operatorLaborMissingTurnCount: report.summary.operatorLaborMissingTurnCount,
    operatorBudgetCapUsd: report.summary.operatorBudgetCapUsd,
    operatorBudgetRemainingLowerBoundUsd: report.summary.operatorBudgetRemainingLowerBoundUsd,
    operatorBudgetRemainingStatus: report.summary.operatorBudgetRemainingStatus,
    operatorBudgetSpendableUsd: report.summary.operatorBudgetSpendableUsd,
    operatorBudgetSpendableStatus: report.summary.operatorBudgetSpendableStatus,
    accountRemainingUsdEstimate: report.summary.accountRemainingUsdEstimate,
    operationalHeadroomUsd: report.summary.operationalHeadroomUsd,
    operationalHeadroomStatus: report.summary.operationalHeadroomStatus,
    budgetPressureState: report.summary.budgetPressureState,
    billingWindow: report.funding.billingWindow,
    accountBalance: report.funding.accountBalance,
    reservedFunding: report.funding.reservedFunding,
    turns: report.turns,
    source: report.source,
    blockers: report.blockers
  };
}

function buildMarkdown(report) {
  const jsonPayload = JSON.stringify(buildJsonHookPayload(report));
  const lines = [
    COMMENT_HOOK_START_MARKER,
    `${COMMENT_HOOK_JSON_PREFIX}${jsonPayload} -->`
  ];

  if (report.summary.status === 'blocked') {
    const blockerCodes = report.blockers.map((entry) => `\`${entry.code}\``).join(', ');
    lines.push(`_Budget hook_: unavailable (${blockerCodes || '`unknown-blocker`'}). Receipt: \`${report.source.outputPath ?? 'none'}\`.`);
  } else {
    const billingWindow = report.funding.billingWindow;
    const accountBalance = report.funding.accountBalance;
    const reservedFunding = report.funding.reservedFunding;
    const operatorBudgetText = report.summary.operatorBudgetCapUsd == null
      ? 'operator cap unknown'
      : report.summary.operatorBudgetSpendableStatus === 'observed'
        ? `operator ${formatUsd(report.summary.operatorLaborObservedUsd)} of ${formatUsd(report.summary.operatorBudgetCapUsd)} cap (spendable remaining ${formatUsd(report.summary.operatorBudgetSpendableUsd)})`
        : `operator ${formatUsd(report.summary.operatorLaborObservedUsd)} of ${formatUsd(report.summary.operatorBudgetCapUsd)} cap (spendable remaining unreconciled; lower bound ${report.summary.operatorBudgetRemainingStatus === 'lower-bound' ? '>=' : ''}${formatUsd(report.summary.operatorBudgetRemainingLowerBoundUsd)})`;
    const billingWindowText = billingWindow?.invoiceTurnId
      ? `window \`${billingWindow.invoiceTurnId}\` spent ${formatUsd(billingWindow.tokenSpendUsd)} remaining ${formatUsd(billingWindow.remainingUsd)}`
      : 'window unavailable';
    const accountText = accountBalance?.remainingUsdEstimate != null
      ? `account est ${formatUsd(accountBalance.remainingUsdEstimate)} remaining from ${accountBalance.remainingCredits} credits @ ${formatUsd(accountBalance.unitPriceUsd)} per credit`
      : 'account headroom unavailable';
    const headroomText = report.summary.operationalHeadroomUsd != null
      ? `operational headroom ${formatUsd(report.summary.operationalHeadroomUsd)} (${report.summary.operationalHeadroomStatus})`
      : `operational headroom unavailable (${report.summary.operationalHeadroomStatus})`;
    const reserveText = reservedFunding.count > 0
      ? `; calibration reserve ${formatUsd(reservedFunding.totalReservedUsd)} across ${reservedFunding.count} held window(s)`
      : '';
    const timingText = report.summary.operatorLaborMissingTurnCount > 0
      ? `; ${report.summary.operatorLaborMissingTurnCount} turn(s) still pending labor timing`
      : '';
    lines.push(`_Budget hook_: blended lower bound ${formatUsd(report.summary.observedBlendedLowerBoundUsd)}; ${operatorBudgetText}; ${billingWindowText}; ${accountText}; ${headroomText}; pressure ${report.summary.budgetPressureState}; turns ${report.turns.totalTurns} total (${report.turns.liveTurnCount} live, ${report.turns.backgroundTurnCount} background)${timingText}${reserveText}. Receipt: \`${report.source.outputPath}\`.`);
  }

  lines.push(COMMENT_HOOK_END_MARKER, '');
  return `${lines.join('\n').trimEnd()}\n`;
}

export function stripExistingBudgetHook(body) {
  const normalizedBody = normalizeText(body);
  if (!normalizedBody.includes(COMMENT_HOOK_START_MARKER)) {
    return normalizedBody;
  }
  const startIndex = normalizedBody.indexOf(COMMENT_HOOK_START_MARKER);
  const endIndex = normalizedBody.indexOf(COMMENT_HOOK_END_MARKER, startIndex);
  if (startIndex < 0 || endIndex < 0) {
    return normalizedBody;
  }
  const prefix = normalizedBody.slice(0, startIndex).trimEnd();
  const suffix = normalizedBody.slice(endIndex + COMMENT_HOOK_END_MARKER.length).trimStart();
  if (prefix && suffix) {
    return `${prefix}\n\n${suffix}`.trimEnd();
  }
  return (prefix || suffix || '').trimEnd();
}

export function appendBudgetHook(body, hookMarkdown) {
  const cleanBody = stripExistingBudgetHook(body);
  const hook = normalizeText(hookMarkdown);
  if (!hook) {
    return cleanBody;
  }
  if (!cleanBody) {
    return `${hook}\n`;
  }
  return `${cleanBody}\n\n${hook}\n`;
}

export function buildGitHubCommentBudgetHookReport({ rollup, repository, targetKind, targetNumber, operatorBudgetCapUsd, reservedFunding, billingWindow, source, blockers, now }) {
  const metrics = rollup?.summary?.metrics ?? {};
  const tokenSpendUsd = toNonNegativeNumber(metrics.totalUsd) ?? 0;
  const operatorLaborObservedUsd = toNonNegativeNumber(metrics.operatorLaborUsd) ?? 0;
  const operatorLaborMissingTurnCount = Number(metrics.operatorLaborMissingTurnCount ?? 0) || 0;
  const observedBlendedLowerBoundUsd = roundUsd(tokenSpendUsd + operatorLaborObservedUsd) ?? 0;
  const knownBlendedUsd = toNonNegativeNumber(metrics.blendedTotalUsd);
  const accountBalance = summarizeAccountBalance(rollup);
  const operationalHeadroom = summarizeOperationalHeadroom(accountBalance, reservedFunding);
  const operatorBudgetRemainingLowerBoundUsd =
    operatorBudgetCapUsd == null ? null : roundUsd(Math.max(0, operatorBudgetCapUsd - operatorLaborObservedUsd));
  const operatorBudgetRemainingStatus =
    operatorBudgetCapUsd == null ? 'unknown' : operatorLaborMissingTurnCount > 0 ? 'lower-bound' : 'observed';
  const operatorBudgetSpendableStatus =
    operatorBudgetCapUsd == null ? 'unknown' : operatorLaborMissingTurnCount > 0 ? 'unreconciled' : 'observed';
  const operatorBudgetSpendableUsd =
    operatorBudgetSpendableStatus === 'observed' ? operatorBudgetRemainingLowerBoundUsd : null;

  const blocking = Array.isArray(blockers) ? blockers.filter(Boolean) : [];
  const budgetPressureState =
    blocking.length > 0
      ? 'blocked'
      : operationalHeadroom.status === 'reserve-protected-only'
        ? 'stop-nonessential-spend'
        : operationalHeadroom.status === 'reserve-near'
          ? 'tight'
          : operationalHeadroom.status === 'unknown' || operatorBudgetSpendableStatus !== 'observed'
            ? 'cautious'
            : 'healthy';
  const status =
    blocking.length > 0
      ? 'blocked'
      : budgetPressureState === 'healthy'
        ? 'pass'
        : 'warn';
  const recommendation =
    status === 'blocked'
      ? 'repair-comment-budget-hook-inputs'
      : budgetPressureState === 'stop-nonessential-spend'
        ? 'protect-calibration-reserve'
        : budgetPressureState === 'tight'
          ? 'constrain-spend'
      : operatorLaborMissingTurnCount > 0
        ? 'reconcile-operator-labor-before-assuming-headroom'
        : 'comment-budget-hook-ready';

  return {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    target: {
      kind: asOptional(targetKind) || 'unknown',
      number: targetNumber ?? null
    },
    summary: {
      status,
      recommendation,
      tokenSpendUsd,
      operatorLaborObservedUsd,
      operatorLaborMissingTurnCount,
      observedBlendedLowerBoundUsd,
      knownBlendedUsd,
      operatorBudgetCapUsd,
      operatorBudgetRemainingLowerBoundUsd,
      operatorBudgetRemainingStatus,
      operatorBudgetSpendableUsd,
      operatorBudgetSpendableStatus,
      accountRemainingUsdEstimate: operationalHeadroom.accountRemainingUsdEstimate,
      operationalHeadroomUsd: operationalHeadroom.operationalHeadroomUsd,
      operationalHeadroomStatus: operationalHeadroom.status,
      budgetPressureState
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
    source,
    blockers: blocking
  };
}

export function runGitHubCommentBudgetHook(
  options,
  {
    now = new Date(),
    readJsonFn = readJson,
    writeJsonFn = writeJson,
    writeTextFn = writeText,
    runMaterializeAgentCostRollupFn = runMaterializeAgentCostRollup
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || process.cwd());
  const { resolvedPolicyPath, policy } = loadPolicy(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  let costRollupPath = path.resolve(repoRoot, options.costRollupPath || asOptional(policy.costRollupPath) || DEFAULT_OUTPUT_PATH.replace('github-comment-budget-hook', 'agent-cost-rollup'));
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
    blockers.push(createBlocker('cost-rollup-missing', 'Agent cost rollup is missing.', safeRelative(repoRoot, costRollupPath)));
  } else {
    try {
      rollup = readJsonFn(costRollupPath);
      if (normalizeText(rollup?.schema) !== 'priority/agent-cost-rollup@v1') {
        blockers.push(createBlocker('cost-rollup-schema-mismatch', 'Agent cost rollup schema must remain priority/agent-cost-rollup@v1.', safeRelative(repoRoot, costRollupPath)));
      }
    } catch (error) {
      blockers.push(createBlocker('cost-rollup-unreadable', error?.message || String(error), safeRelative(repoRoot, costRollupPath)));
    }
  }

  const billingWindow = summarizeBillingWindow(rollup);
  const reservedFunding = summarizeReservedFundingWindows(rollup, policy, billingWindow?.invoiceTurnId ?? null);
  const repository = chooseTargetRepository(options.repo, rollup);
  const operatorBudgetCapUsd = toNonNegativeNumber(policy.operatorBudgetCapUsd);
  const outputPath = path.resolve(repoRoot, options.outputPath || asOptional(policy.outputPath) || DEFAULT_OUTPUT_PATH);
  const markdownOutputPath = path.resolve(repoRoot, options.markdownOutputPath || asOptional(policy.markdownOutputPath) || DEFAULT_MARKDOWN_OUTPUT_PATH);

  const report = buildGitHubCommentBudgetHookReport({
    rollup,
    repository,
    targetKind: options.targetKind,
    targetNumber: options.targetNumber,
    operatorBudgetCapUsd,
    reservedFunding,
    billingWindow,
    source: {
      policyPath: safeRelative(repoRoot, resolvedPolicyPath),
      costRollupPath: safeRelative(repoRoot, costRollupPath),
      costRollupMaterialized,
      costRollupMaterializationReportPath,
      operatorCostProfilePath: asOptional(rollup?.summary?.provenance?.operatorProfiles?.[0]?.operatorProfilePath) || 'tools/policy/operator-cost-profile.json',
      outputPath: safeRelative(repoRoot, outputPath),
      markdownOutputPath: safeRelative(repoRoot, markdownOutputPath)
    },
    blockers,
    now
  });

  const markdown = buildMarkdown(report);
  writeJsonFn(outputPath, report);
  writeTextFn(markdownOutputPath, markdown);

  return {
    report,
    markdown,
    outputPath,
    markdownOutputPath
  };
}

function printUsage() {
  [
    'Usage: node tools/priority/github-comment-budget-hook.mjs [options]',
    '',
    'Builds a durable spend/budget hook for automation-authored GitHub comments.',
    '',
    `  --policy <path>            Policy path (default: ${DEFAULT_POLICY_PATH}).`,
    '  --repo-root <path>         Repository root (default: cwd).',
    '  --repo <owner/repo>        Repository slug override.',
    '  --target-kind <issue|pr>   Comment target kind.',
    '  --target-number <number>   Comment target number.',
    '  --cost-rollup <path>       Cost rollup path override.',
    `  --output <path>            JSON report path (default: ${DEFAULT_OUTPUT_PATH}).`,
    `  --markdown-output <path>   Markdown hook path (default: ${DEFAULT_MARKDOWN_OUTPUT_PATH}).`,
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
    const result = runGitHubCommentBudgetHook(options);
    console.log(`[github-comment-budget-hook] wrote ${result.outputPath}`);
    console.log(`[github-comment-budget-hook] markdown ${result.markdownOutputPath}`);
  } catch (error) {
    console.error(`[github-comment-budget-hook] ${error.message}`);
    process.exit(1);
  }
}

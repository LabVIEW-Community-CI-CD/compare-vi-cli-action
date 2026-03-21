#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/agent-cost-invoice-turn@v1';
export const DEFAULT_OUTPUT_DIR = path.join('tests', 'results', '_agent', 'cost', 'invoice-turns');

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
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function roundUsd(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return Number(parsed.toFixed(6));
}

function computeDefaultInvoiceTurnId(invoiceId, openedAt) {
  const normalizedInvoiceId = normalizeText(invoiceId);
  const normalizedOpenedAt = normalizeText(openedAt);
  const datePrefix = normalizedOpenedAt.length >= 7 ? normalizedOpenedAt.slice(0, 7) : 'unknown-period';
  return `invoice-turn-${datePrefix}-${normalizedInvoiceId}`;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    invoiceTurnId: null,
    invoiceId: null,
    openedAt: null,
    closedAt: null,
    creditsPurchased: null,
    unitPriceUsd: null,
    prepaidUsd: null,
    pricingBasis: 'prepaid-credit',
    sourceKind: 'operator-invoice',
    sourcePath: null,
    operatorNote: null,
    activationState: 'active',
    fundingPurpose: 'operational',
    actualUsdConsumed: null,
    actualCreditsConsumed: null,
    reconciledAt: null,
    reconciliationSourceKind: null,
    reconciliationNote: null,
    outputPath: null,
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
      [
        '--invoice-turn-id',
        '--invoice-id',
        '--opened-at',
        '--closed-at',
        '--credits-purchased',
        '--unit-price-usd',
        '--prepaid-usd',
        '--pricing-basis',
        '--source-kind',
        '--source-path',
        '--operator-note',
        '--activation-state',
        '--funding-purpose',
        '--actual-usd-consumed',
        '--actual-credits-consumed',
        '--reconciled-at',
        '--reconciliation-source-kind',
        '--reconciliation-note',
        '--output'
      ].includes(token)
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--invoice-turn-id') options.invoiceTurnId = next;
      if (token === '--invoice-id') options.invoiceId = next;
      if (token === '--opened-at') options.openedAt = next;
      if (token === '--closed-at') options.closedAt = next;
      if (token === '--credits-purchased') options.creditsPurchased = next;
      if (token === '--unit-price-usd') options.unitPriceUsd = next;
      if (token === '--prepaid-usd') options.prepaidUsd = next;
      if (token === '--pricing-basis') options.pricingBasis = next;
      if (token === '--source-kind') options.sourceKind = next;
      if (token === '--source-path') options.sourcePath = next;
      if (token === '--operator-note') options.operatorNote = next;
      if (token === '--activation-state') options.activationState = next;
      if (token === '--funding-purpose') options.fundingPurpose = next;
      if (token === '--actual-usd-consumed') options.actualUsdConsumed = next;
      if (token === '--actual-credits-consumed') options.actualCreditsConsumed = next;
      if (token === '--reconciled-at') options.reconciledAt = next;
      if (token === '--reconciliation-source-kind') options.reconciliationSourceKind = next;
      if (token === '--reconciliation-note') options.reconciliationNote = next;
      if (token === '--output') options.outputPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !normalizeText(options.invoiceId)) {
    throw new Error('Missing required option: --invoice-id <value>.');
  }
  if (!options.help && !normalizeText(options.openedAt)) {
    throw new Error('Missing required option: --opened-at <date-time>.');
  }

  options.creditsPurchased = toNonNegativeNumber(options.creditsPurchased);
  options.unitPriceUsd = toNonNegativeNumber(options.unitPriceUsd);
  options.prepaidUsd = toNonNegativeNumber(options.prepaidUsd);
  options.actualUsdConsumed = toNonNegativeNumber(options.actualUsdConsumed);
  options.actualCreditsConsumed = toNonNegativeNumber(options.actualCreditsConsumed);
  if (!options.help && options.creditsPurchased == null) {
    throw new Error('Missing required option: --credits-purchased <number>.');
  }
  if (!options.help && options.unitPriceUsd == null) {
    throw new Error('Missing required option: --unit-price-usd <number>.');
  }

  if (!options.help && options.prepaidUsd == null) {
    options.prepaidUsd = roundUsd(options.creditsPurchased * options.unitPriceUsd);
  }

  if (!['prepaid-credit', 'usage-billed', 'hybrid'].includes(normalizeText(options.pricingBasis))) {
    throw new Error('pricing-basis must be prepaid-credit, usage-billed, or hybrid.');
  }
  if (!['operator-invoice', 'billing-export', 'manual-baseline'].includes(normalizeText(options.sourceKind))) {
    throw new Error('source-kind must be operator-invoice, billing-export, or manual-baseline.');
  }
  if (!['active', 'hold'].includes(normalizeText(options.activationState))) {
    throw new Error('activation-state must be active or hold.');
  }
  if (!['operational', 'calibration'].includes(normalizeText(options.fundingPurpose))) {
    throw new Error('funding-purpose must be operational or calibration.');
  }
  if (
    normalizeText(options.reconciliationSourceKind) &&
    !['operator-observed', 'billing-export', 'manual-reconciliation'].includes(normalizeText(options.reconciliationSourceKind))
  ) {
    throw new Error('reconciliation-source-kind must be operator-observed, billing-export, or manual-reconciliation.');
  }
  if (
    (options.actualUsdConsumed != null || options.actualCreditsConsumed != null) &&
    !normalizeText(options.reconciliationSourceKind)
  ) {
    throw new Error('reconciliation-source-kind is required when actual reconciliation values are present.');
  }
  if (
    (options.actualUsdConsumed != null || options.actualCreditsConsumed != null) &&
    !normalizeText(options.reconciledAt)
  ) {
    throw new Error('reconciled-at is required when actual reconciliation values are present.');
  }

  return options;
}

export function buildAgentCostInvoiceTurn(options, now = new Date()) {
  const invoiceTurnId = normalizeText(options.invoiceTurnId) || computeDefaultInvoiceTurnId(options.invoiceId, options.openedAt);
  const outputPath =
    normalizeText(options.outputPath) ||
    path.join(DEFAULT_OUTPUT_DIR, `${normalizeText(options.invoiceId).replace(/[^A-Za-z0-9._-]/g, '_')}.json`);

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    invoiceTurnId,
    invoiceId: normalizeText(options.invoiceId),
    billingPeriod: {
      openedAt: normalizeText(options.openedAt),
      closedAt: normalizeText(options.closedAt) || null
    },
    credits: {
      purchased: options.creditsPurchased,
      unitPriceUsd: options.unitPriceUsd
    },
    billing: {
      currency: 'USD',
      prepaidUsd: options.prepaidUsd,
      pricingBasis: normalizeText(options.pricingBasis)
    },
    policy: {
      activationState: normalizeText(options.activationState),
      fundingPurpose: normalizeText(options.fundingPurpose)
    },
    reconciliation: {
      status: options.actualUsdConsumed != null || options.actualCreditsConsumed != null ? 'actual-observed' : 'baseline-only',
      actualUsdConsumed: options.actualUsdConsumed,
      actualCreditsConsumed: options.actualCreditsConsumed,
      reconciledAt: normalizeText(options.reconciledAt) || null,
      sourceKind: normalizeText(options.reconciliationSourceKind) || null,
      note: normalizeText(options.reconciliationNote) || null
    },
    provenance: {
      sourceKind: normalizeText(options.sourceKind),
      sourcePath: normalizeText(options.sourcePath) || null,
      operatorNote: normalizeText(options.operatorNote) || null
    }
  };

  return {
    outputPath: path.resolve(outputPath),
    report
  };
}

export function runAgentCostInvoiceTurn(options, now = new Date()) {
  const result = buildAgentCostInvoiceTurn(options, now);
  fs.mkdirSync(path.dirname(result.outputPath), { recursive: true });
  fs.writeFileSync(result.outputPath, `${JSON.stringify(result.report, null, 2)}\n`, 'utf8');
  return result;
}

function printUsage() {
  console.log('Usage: node tools/priority/agent-cost-invoice-turn.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --invoice-id <value>            Invoice identifier (required).');
  console.log('  --opened-at <date-time>         Invoice turn openedAt timestamp (required).');
  console.log('  --closed-at <date-time>         Optional invoice turn close timestamp.');
  console.log('  --credits-purchased <number>    Credits purchased in this invoice turn (required).');
  console.log('  --unit-price-usd <number>       USD price per credit or usage unit (required).');
  console.log('  --prepaid-usd <number>          Optional explicit prepaid total; defaults to credits * unit price.');
  console.log('  --pricing-basis <mode>          prepaid-credit | usage-billed | hybrid (default: prepaid-credit).');
  console.log('  --source-kind <kind>            operator-invoice | billing-export | manual-baseline.');
  console.log('  --source-path <path>            Optional private/local evidence path.');
  console.log('  --operator-note <text>          Optional note carried into the normalized receipt.');
  console.log('  --activation-state <state>      active | hold (default: active).');
  console.log('  --funding-purpose <purpose>     operational | calibration (default: operational).');
  console.log('  --actual-usd-consumed <number>  Optional reconciled USD consumed for this invoice turn.');
  console.log('  --actual-credits-consumed <n>   Optional reconciled credits consumed for this invoice turn.');
  console.log('  --reconciled-at <date-time>     Required when reconciled values are present.');
  console.log('  --reconciliation-source-kind    operator-observed | billing-export | manual-reconciliation.');
  console.log('  --reconciliation-note <text>    Optional reconciliation note.');
  console.log('  --invoice-turn-id <value>       Optional explicit invoice turn id.');
  console.log('  --output <path>                 Output path override.');
  console.log('  -h, --help                      Show help and exit.');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return 0;
    }
    const result = runAgentCostInvoiceTurn(options);
    console.log(`[agent-cost-invoice-turn] wrote ${result.outputPath}`);
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

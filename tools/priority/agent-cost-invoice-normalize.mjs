#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildAgentCostInvoiceTurn } from './agent-cost-invoice-turn.mjs';

export const INPUT_SCHEMA = 'priority/agent-cost-private-invoice-metadata@v1';

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

function inferInvoiceId(sourcePath) {
  const normalized = normalizeText(sourcePath);
  if (!normalized) {
    return null;
  }
  const leaf = path.basename(normalized);
  const explicit = leaf.match(/Invoice-([^.]+)\.pdf$/i);
  if (explicit?.[1]) {
    return explicit[1];
  }
  return null;
}

function deriveNumericBaseline(metadata) {
  let creditsPurchased = toNonNegativeNumber(metadata.creditsPurchased);
  let unitPriceUsd = toNonNegativeNumber(metadata.unitPriceUsd);
  let prepaidUsd = toNonNegativeNumber(metadata.prepaidUsd);

  if (prepaidUsd == null && creditsPurchased != null && unitPriceUsd != null) {
    prepaidUsd = roundUsd(creditsPurchased * unitPriceUsd);
  }
  if (unitPriceUsd == null && prepaidUsd != null && creditsPurchased != null && creditsPurchased > 0) {
    unitPriceUsd = roundUsd(prepaidUsd / creditsPurchased);
  }
  if (creditsPurchased == null && prepaidUsd != null && unitPriceUsd != null && unitPriceUsd > 0) {
    creditsPurchased = roundUsd(prepaidUsd / unitPriceUsd);
  }

  return {
    creditsPurchased,
    unitPriceUsd,
    prepaidUsd
  };
}

function readMetadata(filePath) {
  const resolved = path.resolve(filePath);
  const payload = JSON.parse(fs.readFileSync(resolved, 'utf8'));
  return { resolved, payload };
}

function validateMetadata(payload) {
  if (!payload || typeof payload !== 'object') {
    throw new Error('Metadata payload must be a JSON object.');
  }
  if (normalizeText(payload.schema) !== INPUT_SCHEMA) {
    throw new Error(`Metadata schema must remain ${INPUT_SCHEMA}.`);
  }
  if (!normalizeText(payload.sourcePath)) {
    throw new Error('Metadata sourcePath is required.');
  }
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    metadataPath: null,
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
    if (token === '--metadata' || token === '--output') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--metadata') {
        options.metadataPath = next;
      } else {
        options.outputPath = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !normalizeText(options.metadataPath)) {
    throw new Error('Missing required option: --metadata <path>.');
  }

  return options;
}

export function buildNormalizedInvoiceTurnFromMetadata(metadataPayload, options = {}) {
  validateMetadata(metadataPayload);
  const invoiceId = normalizeText(metadataPayload.invoiceId) || inferInvoiceId(metadataPayload.sourcePath);
  if (!invoiceId) {
    throw new Error('Could not determine invoiceId. Provide metadata.invoiceId or use a sourcePath named like Invoice-<id>.pdf.');
  }

  const openedAt = normalizeText(metadataPayload.openedAt) || normalizeText(metadataPayload.observedAt);
  if (!openedAt) {
    throw new Error('Metadata must provide openedAt or observedAt.');
  }

  const derived = deriveNumericBaseline(metadataPayload);
  if (derived.creditsPurchased == null || derived.unitPriceUsd == null) {
    throw new Error(
      'Metadata must provide enough baseline values to derive creditsPurchased and unitPriceUsd. Supply at least two of creditsPurchased, unitPriceUsd, or prepaidUsd.'
    );
  }

  return buildAgentCostInvoiceTurn({
    invoiceTurnId: null,
    invoiceId,
    openedAt,
    closedAt: normalizeText(metadataPayload.closedAt) || null,
    creditsPurchased: derived.creditsPurchased,
    unitPriceUsd: derived.unitPriceUsd,
    prepaidUsd: derived.prepaidUsd,
    pricingBasis: normalizeText(metadataPayload.pricingBasis) || 'prepaid-credit',
    sourceKind: normalizeText(metadataPayload.sourceKind) || 'operator-invoice',
    sourcePath: normalizeText(metadataPayload.sourcePath),
    operatorNote: normalizeText(metadataPayload.operatorNote) || 'Normalized from local private invoice metadata.',
    activationState: normalizeText(metadataPayload.activationState) || 'active',
    fundingPurpose: normalizeText(metadataPayload.fundingPurpose) || 'operational',
    actualUsdConsumed: null,
    actualCreditsConsumed: null,
    reconciledAt: null,
    reconciliationSourceKind: null,
    reconciliationNote: null,
    outputPath: options.outputPath || null
  });
}

export function runAgentCostInvoiceNormalize(options) {
  const metadata = readMetadata(options.metadataPath);
  const result = buildNormalizedInvoiceTurnFromMetadata(metadata.payload, {
    outputPath: options.outputPath
  });
  fs.mkdirSync(path.dirname(result.outputPath), { recursive: true });
  fs.writeFileSync(result.outputPath, `${JSON.stringify(result.report, null, 2)}\n`, 'utf8');
  return {
    ...result,
    metadataPath: metadata.resolved
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/agent-cost-invoice-normalize.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --metadata <path>   Local private invoice metadata JSON (${INPUT_SCHEMA}) (required).`);
  console.log('  --output <path>     Optional invoice-turn receipt output override.');
  console.log('  -h, --help          Show help and exit.');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return 0;
    }
    const result = runAgentCostInvoiceNormalize(options);
    console.log(`[agent-cost-invoice-normalize] wrote ${result.outputPath}`);
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

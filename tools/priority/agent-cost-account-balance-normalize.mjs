#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const INPUT_SCHEMA = 'priority/agent-cost-private-account-balance@v1';
export const REPORT_SCHEMA = 'priority/agent-cost-account-balance@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-account-balance.json');

const CONFIDENCE_LEVELS = new Set(['low', 'medium', 'high']);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function normalizeDateTime(value) {
  const text = normalizeText(value);
  if (!text) {
    return '';
  }
  const parsed = Date.parse(text);
  return Number.isFinite(parsed) ? text : '';
}

function normalizeDate(value) {
  const text = normalizeText(value);
  if (!text) {
    return '';
  }
  if (/^\d{4}-\d{2}-\d{2}$/.test(text)) {
    return text;
  }
  const parsed = Date.parse(text);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString().slice(0, 10) : '';
}

function normalizeConfidence(value) {
  const text = normalizeText(value).toLowerCase();
  return CONFIDENCE_LEVELS.has(text) ? text : '';
}

function toNonNegativeInteger(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function deriveBalanceTotals(payload) {
  let total = toNonNegativeInteger(payload?.credits?.total ?? payload?.totalCredits);
  let used = toNonNegativeInteger(payload?.credits?.used ?? payload?.usedCredits);
  let remaining = toNonNegativeInteger(payload?.credits?.remaining ?? payload?.remainingCredits);

  if (total == null && used != null && remaining != null) {
    total = used + remaining;
  }
  if (used == null && total != null && remaining != null) {
    used = total - remaining;
  }
  if (remaining == null && total != null && used != null) {
    remaining = total - used;
  }

  if ([total, used, remaining].some((value) => value == null)) {
    throw new Error('Account balance state must provide enough credits data to derive total, used, and remaining credits.');
  }

  if (total !== used + remaining) {
    throw new Error('Account balance credits are inconsistent: total must equal used + remaining.');
  }

  return { total, used, remaining };
}

function deriveCycleDaysRemaining(payload, snapshotAt, renewsAt) {
  const explicit = toNonNegativeInteger(payload?.cycle?.daysRemaining ?? payload?.daysRemaining);
  if (explicit != null) {
    return explicit;
  }

  const snapshotDate = normalizeDate(snapshotAt);
  const renewalDate = normalizeDate(renewsAt);
  if (!snapshotDate || !renewalDate) {
    return null;
  }

  const snapshotTime = Date.parse(`${snapshotDate}T00:00:00.000Z`);
  const renewalTime = Date.parse(`${renewalDate}T00:00:00.000Z`);
  if (!Number.isFinite(snapshotTime) || !Number.isFinite(renewalTime) || renewalTime < snapshotTime) {
    return null;
  }

  return Math.round((renewalTime - snapshotTime) / 86400000);
}

function validateInputPayload(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error('Account balance payload must be a JSON object.');
  }

  if (normalizeText(payload.schema) && normalizeText(payload.schema) !== INPUT_SCHEMA) {
    throw new Error(`Account balance payload schema must remain ${INPUT_SCHEMA}.`);
  }

  if (!normalizeText(payload.snapshotAt)) {
    throw new Error('Account balance payload must include snapshotAt.');
  }

  const renewsAt = normalizeDate(payload?.plan?.renewsAt ?? payload?.renewsAt);
  if (!renewsAt) {
    throw new Error('Account balance payload must include plan.renewsAt.');
  }

  if (!normalizeText(payload.sourcePath) && !normalizeText(payload?.provenance?.sourcePath)) {
    throw new Error('Account balance payload must include sourcePath.');
  }
}

function readSnapshot(filePath) {
  const resolved = path.resolve(filePath);
  const payload = JSON.parse(fs.readFileSync(resolved, 'utf8'));
  return { resolved, payload };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    snapshotPath: null,
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
    if (token === '--snapshot' || token === '--output') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--snapshot') {
        options.snapshotPath = next;
      } else {
        options.outputPath = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !normalizeText(options.snapshotPath)) {
    throw new Error('Missing required option: --snapshot <path>.');
  }

  return options;
}

export function buildNormalizedAccountBalanceReceiptFromSnapshot(snapshotPayload, options = {}) {
  validateInputPayload(snapshotPayload);

  const snapshotAt = normalizeDateTime(snapshotPayload.snapshotAt);
  if (!snapshotAt) {
    throw new Error('Account balance payload snapshotAt must be a valid date-time.');
  }

  const renewsAt = normalizeDate(snapshotPayload?.plan?.renewsAt ?? snapshotPayload?.renewsAt);
  if (!renewsAt) {
    throw new Error('Account balance payload plan.renewsAt must be a valid date.');
  }

  const credits = deriveBalanceTotals(snapshotPayload);
  const cycleDaysRemaining = deriveCycleDaysRemaining(snapshotPayload, snapshotAt, renewsAt);
  if (cycleDaysRemaining == null) {
    throw new Error('Account balance payload must include cycle.daysRemaining or enough dates to derive it.');
  }

  const confidence = normalizeConfidence(snapshotPayload?.provenance?.confidence ?? snapshotPayload.confidence) || 'high';
  const sourcePath = normalizeText(snapshotPayload.sourcePath) || normalizeText(snapshotPayload?.provenance?.sourcePath);
  const generatedAt = normalizeDateTime(options.generatedAt) || new Date().toISOString();

  return {
    schema: REPORT_SCHEMA,
    generatedAt,
    snapshotAt,
    plan: {
      name: normalizeText(snapshotPayload?.plan?.name) || 'business',
      renewsAt,
      daysRemaining: cycleDaysRemaining
    },
    credits,
    provenance: {
      sourceSchema: normalizeText(snapshotPayload.schema) || INPUT_SCHEMA,
      sourceKind: normalizeText(snapshotPayload?.provenance?.sourceKind) || 'operator-account-state',
      sourcePath,
      observedAt: normalizeDateTime(snapshotPayload?.provenance?.observedAt) || snapshotAt,
      confidence,
      operatorNote:
        normalizeText(snapshotPayload?.provenance?.operatorNote) ||
        'Normalized from a local private account balance snapshot.'
    }
  };
}

export function runAgentCostAccountBalanceNormalize(options) {
  const snapshot = readSnapshot(options.snapshotPath);
  const report = buildNormalizedAccountBalanceReceiptFromSnapshot(snapshot.payload, {
    generatedAt: options.generatedAt
  });
  const outputPath = path.resolve(options.outputPath || DEFAULT_OUTPUT_PATH);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return {
    snapshotPath: snapshot.resolved,
    outputPath,
    report
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/agent-cost-account-balance-normalize.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --snapshot <path>   Local private account balance snapshot JSON (${INPUT_SCHEMA}) (required).`);
  console.log('  --output <path>     Optional account-balance receipt output override.');
  console.log('  -h, --help          Show help and exit.');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return 0;
    }
    const result = runAgentCostAccountBalanceNormalize(options);
    console.log(`[agent-cost-account-balance-normalize] wrote ${result.outputPath}`);
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

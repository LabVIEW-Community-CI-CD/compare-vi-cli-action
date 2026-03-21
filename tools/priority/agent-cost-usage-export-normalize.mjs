#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/agent-cost-usage-export@v1';
export const DEFAULT_OUTPUT_DIR = path.join('tests', 'results', '_agent', 'cost', 'usage-exports');
export const DEFAULT_SOURCE_KIND = 'operator-private-usage-export-csv';
export const DEFAULT_OPERATOR_NOTE = 'Normalized from a local private account usage export CSV.';
export const REQUIRED_HEADERS = [
  'date_partition',
  'account_id',
  'account_user_id',
  'email',
  'name',
  'public_id',
  'usage_type',
  'usage_credits',
  'usage_quantity',
  'usage_units'
];

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function sanitizeFileStem(value) {
  const normalized = normalizeText(value).replace(/\.[^.]+$/, '');
  return normalized.replace(/[^A-Za-z0-9._-]+/g, '_').replace(/_+/g, '_').replace(/^_+|_+$/g, '').toLowerCase();
}

function roundNumber(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return Number(parsed.toFixed(6));
}

function toNonNegativeNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function isIsoDatePartition(value) {
  const normalized = normalizeText(value);
  return /^\d{4}-\d{2}-\d{2}$/.test(normalized) && Number.isFinite(Date.parse(`${normalized}T00:00:00Z`));
}

function parseDatePartition(value) {
  const normalized = normalizeText(value);
  if (!isIsoDatePartition(normalized)) {
    return null;
  }
  const parsed = Date.parse(`${normalized}T00:00:00Z`);
  return Number.isFinite(parsed) ? parsed : null;
}

function daysBetweenDates(leftDate, rightDate) {
  const left = parseDatePartition(leftDate);
  const right = parseDatePartition(rightDate);
  if (left == null || right == null) {
    return null;
  }
  return Math.round((right - left) / 86400000);
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = '';
  let inQuotes = false;

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (inQuotes) {
      if (char === '"') {
        if (text[index + 1] === '"') {
          cell += '"';
          index += 1;
        } else {
          inQuotes = false;
        }
      } else {
        cell += char;
      }
      continue;
    }

    if (char === '"') {
      inQuotes = true;
      continue;
    }
    if (char === ',') {
      row.push(cell);
      cell = '';
      continue;
    }
    if (char === '\r' || char === '\n') {
      row.push(cell);
      rows.push(row);
      row = [];
      cell = '';
      if (char === '\r' && text[index + 1] === '\n') {
        index += 1;
      }
      continue;
    }
    cell += char;
  }

  if (cell.length > 0 || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }

  return rows.filter((entry) => !(entry.length === 1 && normalizeText(entry[0]) === ''));
}

function readCsv(filePath) {
  const resolvedPath = path.resolve(filePath);
  const raw = fs.readFileSync(resolvedPath, 'utf8');
  return {
    resolvedPath,
    raw,
    sourceSha256: crypto.createHash('sha256').update(Buffer.from(raw, 'utf8')).digest('hex')
  };
}

function assertExactHeaders(headers) {
  const normalized = headers.map((header) => normalizeText(header));
  if (normalized.length !== REQUIRED_HEADERS.length) {
    throw new Error(`Usage export CSV must contain ${REQUIRED_HEADERS.length} columns.`);
  }
  for (let index = 0; index < REQUIRED_HEADERS.length; index += 1) {
    if (normalized[index] !== REQUIRED_HEADERS[index]) {
      throw new Error(`Usage export CSV header mismatch at column ${index + 1}: expected ${REQUIRED_HEADERS[index]}.`);
    }
  }
}

function normalizeRow(header, record, index) {
  const row = {};
  for (let headerIndex = 0; headerIndex < header.length; headerIndex += 1) {
    row[header[headerIndex]] = normalizeText(record[headerIndex]);
  }

  if (!isIsoDatePartition(row.date_partition)) {
    throw new Error(`Row ${index} has an invalid date_partition value.`);
  }
  const usageCredits = toNonNegativeNumber(row.usage_credits);
  const usageQuantity = toNonNegativeNumber(row.usage_quantity);
  if (usageCredits == null) {
    throw new Error(`Row ${index} has an invalid usage_credits value.`);
  }
  if (usageQuantity == null) {
    throw new Error(`Row ${index} has an invalid usage_quantity value.`);
  }
  if (!normalizeText(row.usage_type)) {
    throw new Error(`Row ${index} is missing usage_type.`);
  }
  if (!normalizeText(row.usage_units)) {
    throw new Error(`Row ${index} is missing usage_units.`);
  }

  return {
    rowIndex: index,
    datePartition: row.date_partition,
    accountId: row.account_id,
    accountUserId: row.account_user_id,
    email: row.email,
    name: row.name,
    publicId: row.public_id,
    usageType: row.usage_type,
    usageCredits,
    usageQuantity,
    usageUnits: row.usage_units
  };
}

function createUsageTypeTotals(rows) {
  const totals = new Map();
  for (const row of rows) {
    const existing = totals.get(row.usageType) || {
      usageType: row.usageType,
      rowCount: 0,
      usageCredits: 0,
      usageQuantity: 0
    };
    existing.rowCount += 1;
    existing.usageCredits = roundNumber(existing.usageCredits + row.usageCredits) ?? existing.usageCredits;
    existing.usageQuantity = roundNumber(existing.usageQuantity + row.usageQuantity) ?? existing.usageQuantity;
    totals.set(row.usageType, existing);
  }
  return Array.from(totals.values());
}

function ensureSingleValue(rows, fieldName, errorMessage) {
  const firstValue = normalizeText(rows[0][fieldName]);
  for (const row of rows) {
    if (normalizeText(row[fieldName]) !== firstValue) {
      throw new Error(errorMessage);
    }
  }
  return firstValue;
}

function createReceiptFromRows(rows, sourceMeta, now = new Date()) {
  if (rows.length === 0) {
    throw new Error('Usage export CSV must contain at least one normalized row.');
  }

  const usageType = ensureSingleValue(rows, 'usageType', 'Usage export CSV must describe one usage type per receipt.');
  const usageUnits = ensureSingleValue(rows, 'usageUnits', 'Usage export CSV must describe one usage-units family per receipt.');
  const accountId = ensureSingleValue(rows, 'accountId', 'Usage export CSV must describe one account identity per receipt.');
  const accountUserId = ensureSingleValue(rows, 'accountUserId', 'Usage export CSV must describe one account identity per receipt.');
  const email = ensureSingleValue(rows, 'email', 'Usage export CSV must describe one account identity per receipt.');
  const name = ensureSingleValue(rows, 'name', 'Usage export CSV must describe one account identity per receipt.');
  const publicId = ensureSingleValue(rows, 'publicId', 'Usage export CSV must describe one account identity per receipt.');

  const sortedDatePartitions = [...new Set(rows.map((row) => row.datePartition))].sort();
  const reportWindow = {
    startDate: sortedDatePartitions[0],
    endDate: sortedDatePartitions[sortedDatePartitions.length - 1],
    rowCount: rows.length
  };
  const windowId = `${reportWindow.startDate}..${reportWindow.endDate}`;
  const totals = {
    usageCredits: roundNumber(rows.reduce((sum, row) => sum + row.usageCredits, 0)) ?? 0,
    usageQuantity: roundNumber(rows.reduce((sum, row) => sum + row.usageQuantity, 0)) ?? 0
  };
  const sourcePath = normalizeText(sourceMeta.sourcePath) || null;
  const sourceFileName = sourcePath ? path.basename(sourcePath) : null;
  const sourceSha256 = normalizeText(sourceMeta.sourceSha256) || null;
  const sourceKind = normalizeText(sourceMeta.sourceKind) || DEFAULT_SOURCE_KIND;
  const operatorNote = normalizeText(sourceMeta.operatorNote) || DEFAULT_OPERATOR_NOTE;

  return {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    reportWindow,
    usageType,
    totals,
    sourceKind,
    sourcePathEvidence: sourcePath,
    operatorNote,
    provenance: {
      sourceKind,
      sourcePath,
      sourcePathEvidence: sourcePath,
      sourceSha256,
      sourceFileName,
      accountId,
      accountUserId,
      email,
      name,
      publicId,
      usageUnits,
      usageType,
      rowCount: rows.length,
      datePartitionCount: sortedDatePartitions.length,
      windowId
    },
    confidence: {
      level: 'high',
      basis: ['csv-header-match', 'row-count-match', 'uniform-account-identity', 'uniform-usage-units', 'uniform-usage-type', 'numeric-field-parse'],
      rowCoverage: 1,
      accountCoverage: 1,
      windowCoverage: 1
    },
    continuity: {
      windowIndex: 1,
      windowCount: 1,
      previousWindowId: null,
      nextWindowId: null,
      previousReportWindowEndDate: null,
      nextReportWindowStartDate: null,
      gapDaysFromPrevious: null,
      gapDaysToNext: null,
      isContiguousWithPrevious: null,
      isContiguousWithNext: null,
      isFirstWindow: true,
      isLastWindow: true
    }
  };
}

function buildReceiptFromCsv(csvText, options = {}, now = new Date()) {
  const records = parseCsv(csvText);
  if (records.length < 2) {
    throw new Error('Usage export CSV must contain a header and at least one data row.');
  }

  const header = records[0].map((cell) => normalizeText(cell));
  assertExactHeaders(header);

  const rows = records.slice(1).map((record, index) => {
    if (record.length !== header.length) {
      throw new Error(`Row ${index + 1} must contain exactly ${header.length} columns.`);
    }
    return normalizeRow(header, record, index + 1);
  });

  return createReceiptFromRows(rows, options, now);
}

function readReceiptPath(filePath) {
  const receipt = buildReceiptFromCsv(fs.readFileSync(path.resolve(filePath), 'utf8'), {
    sourcePath: path.resolve(filePath),
    sourceKind: DEFAULT_SOURCE_KIND
  });
  return { filePath: path.resolve(filePath), receipt };
}

function decorateContinuity(receipts) {
  if (receipts.length === 0) {
    return [];
  }

  const ordered = [...receipts].sort((left, right) => {
    const dateCompare = left.reportWindow.startDate.localeCompare(right.reportWindow.startDate);
    if (dateCompare !== 0) {
      return dateCompare;
    }
    return normalizeText(left.sourcePathEvidence).localeCompare(normalizeText(right.sourcePathEvidence));
  });

  return ordered.map((receipt, index) => {
    const previous = index > 0 ? ordered[index - 1] : null;
    const next = index < ordered.length - 1 ? ordered[index + 1] : null;

    if (previous) {
      const dayDifference = daysBetweenDates(previous.reportWindow.endDate, receipt.reportWindow.startDate);
      if (dayDifference == null) {
        throw new Error(`Usage export receipts ${previous.provenance.windowId} and ${receipt.provenance.windowId} contain invalid dates.`);
      }
      if (dayDifference <= 0) {
        throw new Error(`Usage export receipts overlap between ${previous.provenance.windowId} and ${receipt.provenance.windowId}.`);
      }
    }

    const previousGapDays = previous ? Math.max(daysBetweenDates(previous.reportWindow.endDate, receipt.reportWindow.startDate) - 1, 0) : null;
    const nextGapDays = next ? Math.max(daysBetweenDates(receipt.reportWindow.endDate, next.reportWindow.startDate) - 1, 0) : null;

    return {
      ...receipt,
      continuity: {
        windowIndex: index + 1,
        windowCount: ordered.length,
        previousWindowId: previous?.provenance?.windowId || null,
        nextWindowId: next?.provenance?.windowId || null,
        previousReportWindowEndDate: previous?.reportWindow?.endDate || null,
        nextReportWindowStartDate: next?.reportWindow?.startDate || null,
        gapDaysFromPrevious: previousGapDays,
        gapDaysToNext: nextGapDays,
        isContiguousWithPrevious: previous ? previousGapDays === 0 : null,
        isContiguousWithNext: next ? nextGapDays === 0 : null,
        isFirstWindow: index === 0,
        isLastWindow: index === ordered.length - 1
      },
      provenance: {
        ...receipt.provenance,
        windowIndex: index + 1,
        windowCount: ordered.length
      }
    };
  });
}

export function deriveDefaultOutputPath(inputPath) {
  const resolvedPath = normalizeText(inputPath) ? path.resolve(inputPath) : null;
  const stem = resolvedPath ? sanitizeFileStem(path.basename(resolvedPath)) || 'usage-export' : 'usage-export';
  return path.resolve(DEFAULT_OUTPUT_DIR, `${stem}.json`);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    inputPaths: [],
    outputPath: null,
    sourceKind: DEFAULT_SOURCE_KIND,
    operatorNote: DEFAULT_OPERATOR_NOTE,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (['--input', '--output', '--source-kind', '--operator-note'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--input') options.inputPaths.push(next);
      if (token === '--output') options.outputPath = next;
      if (token === '--source-kind') options.sourceKind = next;
      if (token === '--operator-note') options.operatorNote = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && options.inputPaths.length === 0) {
    throw new Error('Missing required option: --input <csv>.');
  }

  return options;
}

export function buildNormalizedUsageExportReceiptFromCsv(csvText, options = {}, now = new Date()) {
  const report = buildReceiptFromCsv(csvText, options, now);
  return {
    report,
    outputPath: deriveDefaultOutputPath(options.inputPath || options.sourcePath || 'usage-export.csv')
  };
}

export function buildNormalizedUsageExportReceiptsFromCsvInputs(inputs, options = {}, now = new Date()) {
  if (!Array.isArray(inputs) || inputs.length === 0) {
    throw new Error('Usage export normalization requires at least one input file.');
  }

  const receipts = inputs.map((input) => {
    const csvText = typeof input.raw === 'string' ? input.raw : fs.readFileSync(path.resolve(input.resolvedPath), 'utf8');
    return buildReceiptFromCsv(csvText, {
      sourcePath: input.resolvedPath,
      sourceKind: options.sourceKind || DEFAULT_SOURCE_KIND,
      operatorNote: options.operatorNote || DEFAULT_OPERATOR_NOTE,
      sourceSha256: input.sourceSha256
    }, now);
  });

  const decorated = decorateContinuity(receipts);
  return {
    reports: decorated,
    outputPaths: decorated.map((receipt) => path.resolve(DEFAULT_OUTPUT_DIR, `usage-export-${receipt.reportWindow.startDate}.json`))
  };
}

export const buildNormalizedUsageExportRollupFromCsvInputs = buildNormalizedUsageExportReceiptsFromCsvInputs;

export function runAgentCostUsageExportNormalize(options, now = new Date()) {
  const inputs = options.inputPaths.map((inputPath) => readCsv(inputPath));
  const result = buildNormalizedUsageExportReceiptsFromCsvInputs(inputs, {
    sourceKind: options.sourceKind,
    operatorNote: options.operatorNote
  }, now);

  const isSingleInput = result.reports.length === 1;
  const outputBasePath = options.outputPath
    ? path.resolve(options.outputPath)
    : isSingleInput
      ? result.outputPaths[0]
      : path.resolve(DEFAULT_OUTPUT_DIR);

  fs.mkdirSync(isSingleInput ? path.dirname(outputBasePath) : outputBasePath, { recursive: true });

  if (isSingleInput) {
    fs.writeFileSync(outputBasePath, `${JSON.stringify(result.reports[0], null, 2)}\n`, 'utf8');
  } else {
    for (const receipt of result.reports) {
      const fileStem = `usage-export-${receipt.reportWindow.startDate}`;
      const receiptPath = path.join(outputBasePath, `${fileStem}.json`);
      fs.writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
    }
  }

  return {
    ...result,
    outputPath: outputBasePath
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/agent-cost-usage-export-normalize.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --input <csv>         Private account usage export CSV path (repeatable, required).');
  console.log('  --output <path>       Output receipt file path for one input, or output directory for many inputs.');
  console.log(`  --source-kind <id>    Source kind for provenance (default: ${DEFAULT_SOURCE_KIND}).`);
  console.log(`  --operator-note <msg> Operator note recorded on the receipt (default: ${DEFAULT_OPERATOR_NOTE}).`);
  console.log('  -h, --help            Show help and exit.');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return 0;
    }
    const result = runAgentCostUsageExportNormalize(options);
    console.log(`[agent-cost-usage-export-normalize] wrote ${result.outputPath}`);
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

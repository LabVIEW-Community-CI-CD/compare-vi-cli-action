#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/agent-cost-usage-export@v1';
export const DEFAULT_OUTPUT_DIR = path.join('tests', 'results', '_agent', 'cost', 'usage-export');
export const DEFAULT_SOURCE_KIND = 'operator-private-usage-export-csv';
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

function datePartitionDifferenceInDays(leftValue, rightValue) {
  const left = parseDatePartition(leftValue);
  const right = parseDatePartition(rightValue);
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

function resolveSourceKind(value) {
  return normalizeText(value) || DEFAULT_SOURCE_KIND;
}

function createWindowReceipt(rows, sourceMeta, now = new Date()) {
  if (rows.length === 0) {
    throw new Error('Usage export CSV must contain at least one normalized row.');
  }

  const firstRow = rows[0];
  const accountFields = ['accountId', 'accountUserId', 'email', 'name', 'publicId', 'usageUnits'];
  for (const row of rows) {
    for (const field of accountFields) {
      if (normalizeText(row[field]) !== normalizeText(firstRow[field])) {
        throw new Error('Usage export CSV must describe one account identity and one usage-units family.');
      }
    }
  }

  const sortedDatePartitions = [...new Set(rows.map((row) => row.datePartition))].sort();
  const totalUsageCredits = roundNumber(rows.reduce((sum, row) => sum + row.usageCredits, 0)) ?? 0;
  const totalUsageQuantity = roundNumber(rows.reduce((sum, row) => sum + row.usageQuantity, 0)) ?? 0;
  const usageTypeTotals = createUsageTypeTotals(rows);
  const sourcePath = normalizeText(sourceMeta.sourcePath) || null;
  const sourceFileName = sourcePath ? path.basename(sourcePath) : null;
  const sourceSha256 = normalizeText(sourceMeta.sourceSha256) || null;
  const sourceKind = resolveSourceKind(sourceMeta.sourceKind);
  const firstDatePartition = sortedDatePartitions[0];
  const lastDatePartition = sortedDatePartitions[sortedDatePartitions.length - 1];
  const windowId = `${firstDatePartition}..${lastDatePartition}`;

  return {
    windowId,
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    source: {
      kind: sourceKind,
      path: sourcePath,
      fileName: sourceFileName,
      sha256: sourceSha256,
      header: [...REQUIRED_HEADERS],
      rowCount: rows.length
    },
    account: {
      accountId: firstRow.accountId,
      accountUserId: firstRow.accountUserId,
      email: firstRow.email,
      name: firstRow.name,
      publicId: firstRow.publicId
    },
    period: {
      firstDatePartition,
      lastDatePartition,
      datePartitionCount: sortedDatePartitions.length
    },
    summary: {
      rowCount: rows.length,
      usageUnits: firstRow.usageUnits,
      totalUsageCredits,
      totalUsageQuantity,
      usageTypes: usageTypeTotals.map((entry) => entry.usageType),
      usageTypeTotals
    },
    rows,
    provenance: {
      sourceKind,
      sourcePath,
      sourceSha256,
      sourceFileName,
      accountId: firstRow.accountId,
      accountUserId: firstRow.accountUserId,
      publicId: firstRow.publicId,
      email: firstRow.email,
      windowId,
      windowIndex: 1,
      windowCount: 1
    },
    confidence: {
      level: 'high',
      basis: ['csv-header-match', 'row-count-match', 'uniform-account-identity', 'uniform-usage-units', 'numeric-field-parse'],
      rowCoverage: 1,
      accountCoverage: 1
    },
    continuity: {
      windowIndex: 1,
      windowCount: 1,
      previousWindowId: null,
      nextWindowId: null,
      previousWindowLastDatePartition: null,
      nextWindowFirstDatePartition: null,
      gapDaysFromPrevious: null,
      gapDaysToNext: null,
      isContiguousWithPrevious: null,
      isContiguousWithNext: null,
      isFirstWindow: true,
      isLastWindow: true
    }
  };
}

function buildWindowReceiptFromCsv(csvText, options = {}, now = new Date()) {
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

  return createWindowReceipt(rows, options, now);
}

function buildTransition(prevWindow, nextWindow) {
  const dayDifference = datePartitionDifferenceInDays(prevWindow.period.lastDatePartition, nextWindow.period.firstDatePartition);
  if (dayDifference == null) {
    throw new Error(`Usage export windows ${prevWindow.windowId} and ${nextWindow.windowId} contain invalid dates.`);
  }
  if (dayDifference <= 0) {
    const overlapDays = Math.abs(dayDifference) + 1;
    throw new Error(
      `Usage export windows overlap between ${prevWindow.windowId} and ${nextWindow.windowId} by ${overlapDays} day(s).`
    );
  }

  const gapDays = dayDifference - 1;
  return {
    fromWindowId: prevWindow.windowId,
    fromWindowIndex: prevWindow.continuity.windowIndex,
    toWindowId: nextWindow.windowId,
    toWindowIndex: nextWindow.continuity.windowIndex,
    fromLastDatePartition: prevWindow.period.lastDatePartition,
    toFirstDatePartition: nextWindow.period.firstDatePartition,
    gapDays,
    overlapDays: 0,
    status: gapDays === 0 ? 'adjacent' : 'gap',
    isContiguous: gapDays === 0
  };
}

function decorateWindowsWithContinuity(windows) {
  const windowCount = windows.length;
  if (windowCount === 0) {
    return { windows: [], transitions: [], contiguousTransitionCount: 0, gapTransitionCount: 0, overlapTransitionCount: 0 };
  }

  const decorated = windows.map((window, index) => ({
    ...window,
    continuity: {
      windowIndex: index + 1,
      windowCount,
      previousWindowId: index > 0 ? windows[index - 1].windowId : null,
      nextWindowId: index < windowCount - 1 ? windows[index + 1].windowId : null,
      previousWindowLastDatePartition: index > 0 ? windows[index - 1].period.lastDatePartition : null,
      nextWindowFirstDatePartition: index < windowCount - 1 ? windows[index + 1].period.firstDatePartition : null,
      gapDaysFromPrevious: null,
      gapDaysToNext: null,
      isContiguousWithPrevious: null,
      isContiguousWithNext: null,
      isFirstWindow: index === 0,
      isLastWindow: index === windowCount - 1
    },
    provenance: {
      ...window.provenance,
      windowIndex: index + 1,
      windowCount
    }
  }));

  const transitions = [];
  let contiguousTransitionCount = 0;
  let gapTransitionCount = 0;
  let overlapTransitionCount = 0;

  for (let index = 0; index < decorated.length - 1; index += 1) {
    const transition = buildTransition(decorated[index], decorated[index + 1]);
    transitions.push(transition);
    if (transition.isContiguous) {
      contiguousTransitionCount += 1;
    } else {
      gapTransitionCount += 1;
    }
    decorated[index].continuity.gapDaysToNext = transition.gapDays;
    decorated[index].continuity.isContiguousWithNext = transition.isContiguous;
    decorated[index + 1].continuity.gapDaysFromPrevious = transition.gapDays;
    decorated[index + 1].continuity.isContiguousWithPrevious = transition.isContiguous;
  }

  return { windows: decorated, transitions, contiguousTransitionCount, gapTransitionCount, overlapTransitionCount };
}

function aggregateWindows(windows, transitions) {
  const usageTypeTotals = new Map();
  const usageUnits = windows[0]?.summary?.usageUnits || null;
  const account = windows[0]?.account || null;
  const uniqueDates = new Set();
  let totalUsageCredits = 0;
  let totalUsageQuantity = 0;
  let totalRowCount = 0;

  for (const window of windows) {
    totalUsageCredits = roundNumber(totalUsageCredits + window.summary.totalUsageCredits) ?? totalUsageCredits;
    totalUsageQuantity = roundNumber(totalUsageQuantity + window.summary.totalUsageQuantity) ?? totalUsageQuantity;
    totalRowCount += window.summary.rowCount;
    for (const row of window.rows) {
      uniqueDates.add(row.datePartition);
    }
    for (const usageTypeTotal of window.summary.usageTypeTotals) {
      const existing = usageTypeTotals.get(usageTypeTotal.usageType) || {
        usageType: usageTypeTotal.usageType,
        rowCount: 0,
        usageCredits: 0,
        usageQuantity: 0
      };
      existing.rowCount += usageTypeTotal.rowCount;
      existing.usageCredits = roundNumber(existing.usageCredits + usageTypeTotal.usageCredits) ?? existing.usageCredits;
      existing.usageQuantity = roundNumber(existing.usageQuantity + usageTypeTotal.usageQuantity) ?? existing.usageQuantity;
      usageTypeTotals.set(usageTypeTotal.usageType, existing);
    }
  }

  const firstWindow = windows[0] || null;
  const lastWindow = windows[windows.length - 1] || null;
  const firstDatePartition = firstWindow?.period.firstDatePartition || null;
  const lastDatePartition = lastWindow?.period.lastDatePartition || null;
  const transitionCount = transitions.length;
  const contiguousTransitionCount = transitions.filter((transition) => transition.isContiguous).length;
  const gapTransitionCount = transitions.filter((transition) => transition.status === 'gap').length;
  const overlapTransitionCount = 0;

  return {
    account,
    period: {
      firstDatePartition,
      lastDatePartition,
      datePartitionCount: uniqueDates.size,
      windowCount: windows.length,
      transitionCount,
      contiguousTransitionCount,
      gapTransitionCount,
      overlapTransitionCount
    },
    summary: {
      windowCount: windows.length,
      transitionCount,
      contiguousTransitionCount,
      gapTransitionCount,
      overlapTransitionCount,
      rowCount: totalRowCount,
      totalUsageCredits,
      totalUsageQuantity,
      usageUnits,
      usageTypes: [...usageTypeTotals.keys()],
      usageTypeTotals: [...usageTypeTotals.values()],
      continuityStatus: gapTransitionCount === 0 ? 'contiguous' : 'gapped'
    },
    source: {
      kind: windows[0]?.source?.kind || DEFAULT_SOURCE_KIND,
      inputCount: windows.length,
      windowCount: windows.length,
      rowCount: totalRowCount,
      files: windows.map((window) => ({
        path: window.source.path,
        fileName: window.source.fileName,
        sha256: window.source.sha256,
        header: [...window.source.header],
        rowCount: window.source.rowCount,
        windowId: window.windowId,
        firstDatePartition: window.period.firstDatePartition,
        lastDatePartition: window.period.lastDatePartition
      }))
    },
    provenance: {
      sourceKind: windows[0]?.provenance?.sourceKind || DEFAULT_SOURCE_KIND,
      sourcePaths: windows.map((window) => window.provenance.sourcePath),
      sourceSha256s: windows.map((window) => window.provenance.sourceSha256),
      sourceFileNames: windows.map((window) => window.provenance.sourceFileName),
      accountId: account?.accountId || null,
      accountUserId: account?.accountUserId || null,
      publicId: account?.publicId || null,
      email: account?.email || null,
      windowCount: windows.length,
      windowIds: windows.map((window) => window.windowId)
    },
    confidence: {
      level: gapTransitionCount === 0 ? 'high' : 'medium',
      basis: gapTransitionCount === 0
        ? ['csv-header-match', 'row-count-match', 'uniform-account-identity', 'uniform-usage-units', 'numeric-field-parse', 'adjacent-window-continuity']
        : ['csv-header-match', 'row-count-match', 'uniform-account-identity', 'uniform-usage-units', 'numeric-field-parse', 'window-gap-observed'],
      rowCoverage: 1,
      accountCoverage: 1,
      windowCoverage: 1,
      continuityCoverage: windows.length <= 1 ? 1 : contiguousTransitionCount / transitions.length
    },
    transitions
  };
}

export function deriveDefaultOutputPath(inputPaths = [], report = null) {
  const normalizedPaths = Array.isArray(inputPaths) ? inputPaths.filter((entry) => normalizeText(entry)) : [];
  if (report?.period?.firstDatePartition && report?.period?.lastDatePartition) {
    const windowCount = report?.summary?.windowCount ?? report?.windows?.length ?? normalizedPaths.length;
    const label = `usage-export-${report.period.firstDatePartition}_to_${report.period.lastDatePartition}-${windowCount || 0}-windows.json`;
    return path.resolve(DEFAULT_OUTPUT_DIR, label);
  }
  if (normalizedPaths.length > 0) {
    const stems = normalizedPaths.map((entry) => sanitizeFileStem(path.basename(entry)) || 'usage-export');
    const label = `${stems.join('__') || 'usage-export-rollup'}.json`;
    return path.resolve(DEFAULT_OUTPUT_DIR, label);
  }
  return path.resolve(DEFAULT_OUTPUT_DIR, 'usage-export-rollup.json');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    inputPaths: [],
    outputPath: null,
    sourceKind: DEFAULT_SOURCE_KIND,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (['--input', '--output', '--source-kind'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--input') options.inputPaths.push(next);
      if (token === '--output') options.outputPath = next;
      if (token === '--source-kind') options.sourceKind = next;
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
  const report = buildWindowReceiptFromCsv(csvText, options, now);
  return {
    report,
    outputPath: deriveDefaultOutputPath([options.inputPath || options.sourcePath || 'usage-export.csv'])
  };
}

export function buildNormalizedUsageExportRollupFromCsvInputs(inputs, options = {}, now = new Date()) {
  if (!Array.isArray(inputs) || inputs.length === 0) {
    throw new Error('Usage export normalization requires at least one input file.');
  }

  const windows = inputs.map((input) => {
    const report = buildWindowReceiptFromCsv(input.raw, {
      sourceKind: options.sourceKind || input.sourceKind || DEFAULT_SOURCE_KIND,
      sourcePath: input.resolvedPath,
      sourceSha256: input.sourceSha256
    }, now);
    return report;
  });

  windows.sort((left, right) => {
    const dateCompare = left.period.firstDatePartition.localeCompare(right.period.firstDatePartition);
    if (dateCompare !== 0) {
      return dateCompare;
    }
    return (left.source.fileName || left.source.path || '').localeCompare(right.source.fileName || right.source.path || '');
  });

  const firstWindow = windows[0];
  const accountFields = ['accountId', 'accountUserId', 'email', 'name', 'publicId'];
  const usageUnits = firstWindow.summary.usageUnits;
  for (const window of windows) {
    for (const field of accountFields) {
      if (normalizeText(window.account[field]) !== normalizeText(firstWindow.account[field])) {
        throw new Error('Usage export windows must describe the same account identity.');
      }
    }
    if (normalizeText(window.summary.usageUnits) !== normalizeText(usageUnits)) {
      throw new Error('Usage export windows must use the same usage-units family.');
    }
  }

  const continuity = decorateWindowsWithContinuity(windows);
  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    ...aggregateWindows(continuity.windows, continuity.transitions),
    transitions: continuity.transitions,
    windows: continuity.windows
  };
  const outputPath = deriveDefaultOutputPath(inputs.map((input) => input.resolvedPath), report);
  return { report, outputPath };
}

export function runAgentCostUsageExportNormalize(options, now = new Date()) {
  const inputs = options.inputPaths.map((inputPath) => readCsv(inputPath));
  const result = buildNormalizedUsageExportRollupFromCsvInputs(inputs, {
    outputPath: options.outputPath,
    sourceKind: options.sourceKind
  }, now);

  const outputPath = path.resolve(options.outputPath || result.outputPath);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(result.report, null, 2)}\n`, 'utf8');
  return {
    ...result,
    outputPath
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/agent-cost-usage-export-normalize.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --input <csv>      Private account usage export CSV path (repeatable, required).');
  console.log('  --output <path>    Optional receipt output override.');
  console.log(`  --source-kind <id> Source kind for provenance (default: ${DEFAULT_SOURCE_KIND}).`);
  console.log('  -h, --help         Show help and exit.');
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



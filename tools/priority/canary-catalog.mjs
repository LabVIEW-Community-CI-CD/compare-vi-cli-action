#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';

export const CATALOG_SCHEMA = 'canary-signal-catalog@v1';
export const REPORT_SCHEMA = 'priority/canary-signal-catalog-report@v1';
export const DEFAULT_CATALOG_PATH = path.join('tools', 'priority', 'canary-signal-catalog.json');
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'canary', 'canary-signal-catalog-report.json');

const VALID_SOURCE_TYPES = new Set(['incident-event', 'workflow-run', 'required-check-drift', 'deployment-state']);
const VALID_SEVERITIES = new Set(['critical', 'high', 'medium', 'low', 'info']);
const VALID_ACTION_TYPES = new Set(['open-issue', 'update-issue', 'comment', 'pause-queue', 'noop']);
const VALID_PRIORITIES = new Set(['P0', 'P1', 'P2']);

function printUsage() {
  console.log('Usage: node tools/priority/canary-catalog.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --catalog <path>      Catalog path (default: ${DEFAULT_CATALOG_PATH}).`);
  console.log(`  --report <path>       Report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --strict              Fail when validation issues are detected (default: true).');
  console.log('  --no-strict           Emit report but do not fail on validation issues.');
  console.log('  -h, --help            Show help and exit.');
}

function normalizeText(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text ? text : null;
}

function normalizeLower(value) {
  const text = normalizeText(value);
  return text ? text.toLowerCase() : null;
}

function normalizeLabels(values) {
  const labels = [];
  for (const value of Array.isArray(values) ? values : []) {
    const normalized = normalizeLower(value);
    if (!normalized) continue;
    labels.push(normalized);
  }
  return [...new Set(labels)].sort((left, right) => left.localeCompare(right));
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    catalogPath: DEFAULT_CATALOG_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    strict: true,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--strict') {
      options.strict = true;
      continue;
    }
    if (token === '--no-strict') {
      options.strict = false;
      continue;
    }
    if (token === '--catalog' || token === '--report') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--catalog') options.catalogPath = next;
      if (token === '--report') options.reportPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function readJsonFile(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`File not found: ${resolved}`);
  }
  return readFile(resolved, 'utf8').then((content) => {
    try {
      return JSON.parse(content);
    } catch (error) {
      throw new Error(`Invalid JSON in ${resolved}: ${error.message}`);
    }
  });
}

export function buildSignalKey({ sourceType, incidentClass, branch, signaturePattern }) {
  return [
    normalizeLower(sourceType) ?? 'unknown',
    normalizeLower(incidentClass) ?? 'unknown',
    normalizeLower(branch) ?? '*',
    normalizeLower(signaturePattern) ?? 'unknown'
  ].join('|');
}

function digestText(value) {
  const hash = createHash('sha256');
  hash.update(String(value));
  return hash.digest('hex');
}

function normalizeExpectedRoute(route = {}) {
  const actionType = normalizeLower(route.actionType) ?? 'comment';
  if (!VALID_ACTION_TYPES.has(actionType)) {
    throw new Error(`Invalid expectedRoute.actionType '${route.actionType}'.`);
  }
  const priority = normalizeText(route.priority)?.toUpperCase() ?? 'P2';
  if (!VALID_PRIORITIES.has(priority)) {
    throw new Error(`Invalid expectedRoute.priority '${route.priority}'.`);
  }
  return {
    actionType,
    priority,
    labels: normalizeLabels(route.labels)
  };
}

function normalizeSignal(rawSignal, index) {
  const id = normalizeText(rawSignal?.id);
  if (!id) {
    throw new Error(`Signal at index ${index} is missing id.`);
  }
  const sourceType = normalizeLower(rawSignal.sourceType);
  if (!VALID_SOURCE_TYPES.has(sourceType)) {
    throw new Error(`Signal '${id}' has invalid sourceType '${rawSignal.sourceType}'.`);
  }
  const incidentClass = normalizeLower(rawSignal.incidentClass);
  if (!incidentClass) {
    throw new Error(`Signal '${id}' is missing incidentClass.`);
  }
  const severity = normalizeLower(rawSignal.severity);
  if (!VALID_SEVERITIES.has(severity)) {
    throw new Error(`Signal '${id}' has invalid severity '${rawSignal.severity}'.`);
  }
  const signaturePattern = normalizeLower(rawSignal.signaturePattern);
  if (!signaturePattern) {
    throw new Error(`Signal '${id}' is missing signaturePattern.`);
  }

  const branch = normalizeLower(rawSignal.branch) ?? '*';
  const key = buildSignalKey({
    sourceType,
    incidentClass,
    branch,
    signaturePattern
  });

  return {
    id,
    sourceType,
    incidentClass,
    branch,
    signaturePattern,
    severity,
    owner: normalizeText(rawSignal.owner),
    labels: normalizeLabels(rawSignal.labels),
    expectedRoute: normalizeExpectedRoute(rawSignal.expectedRoute ?? {}),
    key,
    keyDigest: digestText(key)
  };
}

export function normalizeCatalog(catalog = {}) {
  if (catalog?.schema !== CATALOG_SCHEMA) {
    throw new Error(`Invalid catalog schema '${catalog?.schema}'. Expected '${CATALOG_SCHEMA}'.`);
  }
  const signals = (Array.isArray(catalog.signals) ? catalog.signals : [])
    .map((signal, index) => normalizeSignal(signal, index))
    .sort((left, right) => left.id.localeCompare(right.id));
  return {
    schema: CATALOG_SCHEMA,
    schemaVersion: normalizeText(catalog.schemaVersion) ?? '1.0.0',
    description: normalizeText(catalog.description),
    signals
  };
}

export function evaluateCatalog(catalog) {
  const keyToIds = new Map();
  const issues = [];
  const bySourceType = {};
  const bySeverity = {};

  for (const signal of catalog.signals) {
    const existing = keyToIds.get(signal.key) ?? [];
    existing.push(signal.id);
    keyToIds.set(signal.key, existing);

    bySourceType[signal.sourceType] = (bySourceType[signal.sourceType] ?? 0) + 1;
    bySeverity[signal.severity] = (bySeverity[signal.severity] ?? 0) + 1;

    if (!signal.owner) {
      issues.push(`signal:${signal.id}:owner-missing`);
    }
    if (signal.expectedRoute.labels.length === 0) {
      issues.push(`signal:${signal.id}:expected-route-labels-empty`);
    }
  }

  for (const [key, ids] of keyToIds.entries()) {
    if (ids.length > 1) {
      issues.push(`duplicate-key:${key}:${ids.sort((left, right) => left.localeCompare(right)).join(',')}`);
    }
  }

  return {
    issues: issues.sort((left, right) => left.localeCompare(right)),
    bySourceType,
    bySeverity,
    uniqueKeyCount: keyToIds.size
  };
}

async function writeReport(reportPath, report) {
  const resolvedPath = path.resolve(reportPath);
  await mkdir(path.dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

export async function runCanaryCatalog({
  argv = process.argv,
  now = new Date(),
  repoRoot = getRepoRoot(),
  readJsonFileFn = readJsonFile,
  writeReportFn = writeReport
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  const resolvedCatalogPath = path.resolve(repoRoot, options.catalogPath);
  let exitCode = 0;
  let report = null;

  try {
    const catalogPayload = await readJsonFileFn(resolvedCatalogPath);
    const catalog = normalizeCatalog(catalogPayload);
    const evaluation = evaluateCatalog(catalog);
    const pass = evaluation.issues.length === 0;
    if (!pass && options.strict) {
      exitCode = 1;
    }
    report = {
      schema: REPORT_SCHEMA,
      schemaVersion: '1.0.0',
      generatedAt: now.toISOString(),
      status: pass ? 'pass' : options.strict ? 'fail' : 'warn',
      strict: options.strict,
      catalogPath: resolvedCatalogPath,
      catalog: {
        schema: catalog.schema,
        schemaVersion: catalog.schemaVersion,
        signalCount: catalog.signals.length,
        uniqueKeyCount: evaluation.uniqueKeyCount,
        digest: digestText(JSON.stringify(catalog.signals))
      },
      coverage: {
        bySourceType: evaluation.bySourceType,
        bySeverity: evaluation.bySeverity
      },
      signals: catalog.signals,
      issues: evaluation.issues
    };
  } catch (error) {
    exitCode = 1;
    report = {
      schema: REPORT_SCHEMA,
      schemaVersion: '1.0.0',
      generatedAt: now.toISOString(),
      status: 'fail',
      strict: options.strict,
      catalogPath: resolvedCatalogPath,
      catalog: {
        schema: CATALOG_SCHEMA,
        schemaVersion: null,
        signalCount: 0,
        uniqueKeyCount: 0,
        digest: null
      },
      coverage: {
        bySourceType: {},
        bySeverity: {}
      },
      signals: [],
      issues: [error.message || String(error)]
    };
  }

  const resolvedReportPath = await writeReportFn(options.reportPath, report);
  console.log(`[canary-catalog] report: ${resolvedReportPath}`);
  console.log(`[canary-catalog] status=${report.status} signals=${report.catalog.signalCount} issues=${report.issues.length}`);
  return { exitCode, report, reportPath: resolvedReportPath };
}

const isDirectRun = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isDirectRun) {
  runCanaryCatalog().then(({ exitCode }) => {
    process.exit(exitCode);
  }).catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

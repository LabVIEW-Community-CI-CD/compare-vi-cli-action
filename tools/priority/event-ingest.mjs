#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const INCIDENT_EVENT_SCHEMA = 'incident-event@v1';
export const EVENT_INGEST_REPORT_SCHEMA = 'priority/event-ingest-report@v1';
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'ops', 'incident-event-report.json');

const SOURCE_TYPES = new Set(['incident-event', 'workflow-run', 'required-check-drift', 'deployment-state']);
const SEVERITY_VALUES = new Set(['critical', 'high', 'medium', 'low', 'info']);

function printUsage() {
  console.log('Usage: node tools/priority/event-ingest.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --source-type <type>      Source adapter (incident-event|workflow-run|required-check-drift|deployment-state).');
  console.log('  --input <path>            Input JSON payload path.');
  console.log(`  --report <path>           Output report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --class <value>           Optional incident class override.');
  console.log('  --severity <value>        Optional severity override (critical|high|medium|low|info).');
  console.log('  --signature <value>       Optional signature override.');
  console.log('  --dry-run                 Parse/normalize only; still writes report.');
  console.log('  -h, --help                Show help.');
}

function normalizeText(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text ? text : null;
}

function normalizeSeverity(value, fallback = 'medium') {
  const normalized = String(value ?? '').trim().toLowerCase();
  if (SEVERITY_VALUES.has(normalized)) {
    return normalized;
  }
  return fallback;
}

function normalizeSha(value) {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  return normalized.toLowerCase();
}

function normalizeIso(value) {
  if (!value) return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) return null;
  return parsed.toISOString();
}

function toLowerOrUnknown(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : 'unknown';
}

function dedupeSortedLabels(labels) {
  const normalized = [];
  for (const label of Array.isArray(labels) ? labels : []) {
    const value = typeof label === 'string' ? label : label?.name;
    const item = normalizeText(value);
    if (!item) continue;
    normalized.push(item.toLowerCase());
  }
  return [...new Set(normalized)].sort((left, right) => left.localeCompare(right));
}

function stableSortValue(value) {
  if (Array.isArray(value)) {
    return value.map((item) => stableSortValue(item));
  }
  if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    const sorted = {};
    for (const key of Object.keys(value).sort((left, right) => left.localeCompare(right))) {
      sorted[key] = stableSortValue(value[key]);
    }
    return sorted;
  }
  return value;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    sourceType: 'incident-event',
    inputPath: null,
    reportPath: DEFAULT_REPORT_PATH,
    classOverride: null,
    severityOverride: null,
    signatureOverride: null,
    dryRun: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (
      token === '--source-type' ||
      token === '--input' ||
      token === '--report' ||
      token === '--class' ||
      token === '--severity' ||
      token === '--signature'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--source-type') options.sourceType = String(next).trim().toLowerCase();
      if (token === '--input') options.inputPath = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--class') options.classOverride = normalizeText(next);
      if (token === '--severity') options.severityOverride = normalizeSeverity(next, 'invalid');
      if (token === '--signature') options.signatureOverride = normalizeText(next);
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (options.help) {
    return options;
  }
  if (!SOURCE_TYPES.has(options.sourceType)) {
    throw new Error(`Invalid --source-type '${options.sourceType}'.`);
  }
  if (!options.inputPath) {
    throw new Error('Input payload is required. Pass --input <path>.');
  }
  if (options.severityOverride === 'invalid') {
    throw new Error(`Invalid --severity '${options.severityOverride}'.`);
  }
  return options;
}

export function computeIncidentFingerprint({
  sourceType = 'unknown',
  incidentClass = 'unknown',
  branch = null,
  sha = null,
  signature = null
} = {}) {
  const payload = [
    toLowerOrUnknown(sourceType),
    toLowerOrUnknown(incidentClass),
    toLowerOrUnknown(branch),
    toLowerOrUnknown(sha),
    toLowerOrUnknown(signature)
  ].join('|');
  const hash = createHash('sha256');
  hash.update(payload);
  return {
    key: payload,
    sha256: hash.digest('hex')
  };
}

export function computeInputDigest(payload) {
  const stable = stableSortValue(payload ?? null);
  const hash = createHash('sha256');
  hash.update(JSON.stringify(stable));
  return hash.digest('hex');
}

function conclusionToClass(conclusion, status) {
  const normalizedConclusion = toLowerOrUnknown(conclusion);
  const normalizedStatus = toLowerOrUnknown(status);
  if (normalizedStatus !== 'completed') return 'workflow-run-active';
  if (['failure', 'timed_out', 'action_required', 'startup_failure'].includes(normalizedConclusion)) {
    return 'workflow-run-failure';
  }
  if (normalizedConclusion === 'cancelled') return 'workflow-run-cancelled';
  if (normalizedConclusion === 'skipped') return 'workflow-run-skipped';
  if (normalizedConclusion === 'success') return 'workflow-run-success';
  return 'workflow-run-anomaly';
}

function conclusionToSeverity(conclusion, status) {
  const normalizedConclusion = toLowerOrUnknown(conclusion);
  const normalizedStatus = toLowerOrUnknown(status);
  if (normalizedStatus !== 'completed') return 'medium';
  if (['failure', 'timed_out', 'action_required', 'startup_failure'].includes(normalizedConclusion)) return 'high';
  if (normalizedConclusion === 'cancelled') return 'medium';
  if (normalizedConclusion === 'skipped') return 'low';
  if (normalizedConclusion === 'success') return 'info';
  return 'medium';
}

function ensureIncidentClass(value) {
  const incidentClass = normalizeText(value);
  if (!incidentClass) {
    throw new Error('Incident class is required (class/incidentClass/type).');
  }
  return incidentClass;
}

function buildBaseEvent(raw, adapter) {
  const source = normalizeText(adapter.source) ?? adapter.sourceType;
  const incidentClass = ensureIncidentClass(adapter.incidentClass);
  const severity = normalizeSeverity(adapter.severity, 'medium');
  const signature = normalizeText(adapter.signature) ?? incidentClass;
  const branch = normalizeText(adapter.branch);
  const sha = normalizeSha(adapter.sha);
  const occurredAt = normalizeIso(adapter.occurredAt);
  return {
    sourceType: adapter.sourceType,
    source,
    incidentClass,
    severity,
    repository: normalizeText(adapter.repository),
    branch,
    sha,
    signature,
    summary: normalizeText(adapter.summary),
    occurredAt,
    suggestedLabels: dedupeSortedLabels(adapter.suggestedLabels),
    metadata: stableSortValue(adapter.metadata ?? {}),
    raw: stableSortValue(raw ?? {})
  };
}

export function normalizeIncidentEvent(raw) {
  return buildBaseEvent(raw, {
    sourceType: 'incident-event',
    source: raw?.source ?? 'incident-event',
    incidentClass: raw?.incidentClass ?? raw?.class ?? raw?.type,
    severity: raw?.severity,
    repository: raw?.repository ?? raw?.repo,
    branch: raw?.branch ?? raw?.ref ?? raw?.head_branch ?? raw?.headBranch,
    sha: raw?.sha ?? raw?.head_sha ?? raw?.headSha,
    signature: raw?.signature ?? raw?.key,
    summary: raw?.summary ?? raw?.message ?? raw?.title,
    occurredAt: raw?.occurredAt ?? raw?.timestamp ?? raw?.generatedAt,
    suggestedLabels: raw?.labels,
    metadata: raw?.metadata ?? {}
  });
}

export function normalizeWorkflowRunEvent(raw) {
  const workflowName = normalizeText(raw?.name ?? raw?.workflow ?? raw?.workflowName) ?? 'workflow';
  const conclusion = normalizeText(raw?.conclusion);
  const status = normalizeText(raw?.status);
  const incidentClass = conclusionToClass(conclusion, status);
  const severity = conclusionToSeverity(conclusion, status);
  const signature = `${workflowName}:${toLowerOrUnknown(conclusion ?? status)}`;
  return buildBaseEvent(raw, {
    sourceType: 'workflow-run',
    source: 'workflow-run',
    incidentClass,
    severity,
    repository: raw?.repository?.full_name ?? raw?.repository?.fullName ?? raw?.repository,
    branch: raw?.head_branch ?? raw?.headBranch ?? raw?.branch ?? raw?.ref_name ?? raw?.refName,
    sha: raw?.head_sha ?? raw?.headSha ?? raw?.sha,
    signature,
    summary: `${workflowName} ${toLowerOrUnknown(conclusion ?? status)}`,
    occurredAt: raw?.updated_at ?? raw?.updatedAt ?? raw?.created_at ?? raw?.createdAt,
    suggestedLabels: ['ci'],
    metadata: {
      runId: raw?.id ?? raw?.run_id ?? raw?.runId ?? null,
      runAttempt: raw?.run_attempt ?? raw?.runAttempt ?? null,
      event: normalizeText(raw?.event),
      status: normalizeText(status),
      conclusion: normalizeText(conclusion),
      htmlUrl: normalizeText(raw?.html_url ?? raw?.htmlUrl)
    }
  });
}

export function normalizeRequiredCheckDriftEvent(raw) {
  const summary = raw?.summary ?? {};
  const totalDiffCount = Number(summary?.totalDiffCount ?? 0) || 0;
  const branchDiffCount = Number(summary?.branchDiffCount ?? 0) || 0;
  const rulesetDiffCount = Number(summary?.rulesetDiffCount ?? 0) || 0;
  const result = toLowerOrUnknown(raw?.result);
  const hasDrift = totalDiffCount > 0 || result === 'fail' || result === 'error';
  const incidentClass = hasDrift ? 'required-check-drift' : 'required-check-drift-clear';
  const severity = hasDrift ? (result === 'fail' || result === 'error' ? 'high' : 'medium') : 'info';
  const signature = `${result}:${totalDiffCount}:${branchDiffCount}:${rulesetDiffCount}`;
  return buildBaseEvent(raw, {
    sourceType: 'required-check-drift',
    source: 'required-check-drift',
    incidentClass,
    severity,
    repository: raw?.repository,
    branch: raw?.branch ?? raw?.targetBranch,
    sha: raw?.sha ?? raw?.headSha,
    signature,
    summary: hasDrift ? `policy drift detected (${totalDiffCount})` : 'policy drift clear',
    occurredAt: raw?.generatedAt,
    suggestedLabels: hasDrift ? ['governance', 'ci'] : ['ci'],
    metadata: {
      apply: Boolean(raw?.apply),
      result,
      skippedReason: normalizeText(raw?.skippedReason),
      totalDiffCount,
      branchDiffCount,
      rulesetDiffCount
    }
  });
}

export function normalizeDeploymentStateEvent(raw) {
  const result = toLowerOrUnknown(raw?.result);
  const issues = Array.isArray(raw?.issues) ? raw.issues.filter((item) => typeof item === 'string') : [];
  const hasIssues = issues.length > 0 || result !== 'pass';
  const incidentClass = hasIssues ? 'deployment-state-anomaly' : 'deployment-state-healthy';
  const severity = hasIssues ? 'high' : 'info';
  const signature = `${toLowerOrUnknown(raw?.environment)}:${result}:${issues.join(',') || 'none'}`;
  return buildBaseEvent(raw, {
    sourceType: 'deployment-state',
    source: 'deployment-state',
    incidentClass,
    severity,
    repository: raw?.repository,
    branch: raw?.branch ?? raw?.ref,
    sha: raw?.sha,
    signature,
    summary: hasIssues ? `deployment determinism failed (${issues.length} issue(s))` : 'deployment determinism pass',
    occurredAt: raw?.generatedAt,
    suggestedLabels: hasIssues ? ['ci', 'governance'] : ['ci'],
    metadata: {
      environment: normalizeText(raw?.environment),
      result,
      runId: normalizeText(raw?.runId),
      issueCount: issues.length,
      issues
    }
  });
}

export function normalizeBySourceType(sourceType, raw) {
  if (sourceType === 'incident-event') return normalizeIncidentEvent(raw);
  if (sourceType === 'workflow-run') return normalizeWorkflowRunEvent(raw);
  if (sourceType === 'required-check-drift') return normalizeRequiredCheckDriftEvent(raw);
  if (sourceType === 'deployment-state') return normalizeDeploymentStateEvent(raw);
  throw new Error(`Unsupported source type '${sourceType}'.`);
}

function applyOverrides(event, options) {
  const next = { ...event };
  if (options.classOverride) next.incidentClass = options.classOverride;
  if (options.severityOverride) next.severity = normalizeSeverity(options.severityOverride, next.severity);
  if (options.signatureOverride) next.signature = options.signatureOverride;
  return next;
}

function buildNormalizedEvent(sourceType, rawInput, options, now = new Date()) {
  const normalized = applyOverrides(normalizeBySourceType(sourceType, rawInput), options);
  const fingerprint = computeIncidentFingerprint({
    sourceType: normalized.sourceType,
    incidentClass: normalized.incidentClass,
    branch: normalized.branch,
    sha: normalized.sha,
    signature: normalized.signature
  });

  return {
    schema: INCIDENT_EVENT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    sourceType: normalized.sourceType,
    source: normalized.source,
    incidentClass: normalized.incidentClass,
    severity: normalized.severity,
    repository: normalized.repository,
    branch: normalized.branch,
    sha: normalized.sha,
    signature: normalized.signature,
    fingerprint: fingerprint.sha256,
    fingerprintKey: fingerprint.key,
    inputDigest: computeInputDigest(rawInput),
    summary: normalized.summary,
    occurredAt: normalized.occurredAt,
    suggestedLabels: normalized.suggestedLabels,
    metadata: normalized.metadata,
    raw: normalized.raw
  };
}

async function writeReport(reportPath, report) {
  const resolvedPath = path.resolve(reportPath);
  await mkdir(path.dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

async function loadInputJson(inputPath) {
  const resolved = path.resolve(inputPath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`Input path not found: ${resolved}`);
  }
  const raw = await readFile(resolved, 'utf8');
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Input payload is not valid JSON: ${error.message}`);
  }
}

export async function runEventIngest(
  { argv = process.argv, now = new Date(), loadInputJsonFn = loadInputJson, writeReportFn = writeReport } = {}
) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  let report = null;
  let exitCode = 0;
  try {
    const payload = await loadInputJsonFn(options.inputPath);
    const event = buildNormalizedEvent(options.sourceType, payload, options, now);
    report = {
      schema: EVENT_INGEST_REPORT_SCHEMA,
      schemaVersion: '1.0.0',
      generatedAt: now.toISOString(),
      status: 'pass',
      sourceType: options.sourceType,
      inputPath: path.resolve(options.inputPath),
      flags: {
        dryRun: options.dryRun,
        classOverride: Boolean(options.classOverride),
        severityOverride: Boolean(options.severityOverride),
        signatureOverride: Boolean(options.signatureOverride)
      },
      event,
      errors: []
    };
  } catch (error) {
    exitCode = 1;
    report = {
      schema: EVENT_INGEST_REPORT_SCHEMA,
      schemaVersion: '1.0.0',
      generatedAt: now.toISOString(),
      status: 'fail',
      sourceType: options.sourceType,
      inputPath: options.inputPath ? path.resolve(options.inputPath) : null,
      flags: {
        dryRun: options.dryRun,
        classOverride: Boolean(options.classOverride),
        severityOverride: Boolean(options.severityOverride),
        signatureOverride: Boolean(options.signatureOverride)
      },
      event: null,
      errors: [error.message || String(error)]
    };
  }

  const reportPath = await writeReportFn(options.reportPath, report);
  console.log(`[event-ingest] report: ${reportPath}`);
  if (exitCode !== 0) {
    console.error(`[event-ingest] ${report.errors.join('; ')}`);
  } else {
    console.log(
      `[event-ingest] sourceType=${report.sourceType} class=${report.event.incidentClass} fingerprint=${report.event.fingerprint}`
    );
  }
  return { exitCode, report, reportPath };
}

const isDirectRun = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isDirectRun) {
  runEventIngest().then(({ exitCode }) => {
    process.exit(exitCode);
  }).catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

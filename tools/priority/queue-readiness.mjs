#!/usr/bin/env node

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/queue-readiness-report@v1';
export const DEFAULT_READINESS_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'queue',
  'queue-readiness-report.json'
);
export const DEFAULT_SUPERVISOR_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'queue',
  'queue-supervisor-report.json'
);
export const RISK_CLASSES = Object.freeze(['low', 'medium', 'high']);
export const FLAKY_EXPOSURE_CLASSES = Object.freeze(['none', 'medium', 'high']);
export const SCORE_WEIGHTS = Object.freeze({
  readinessBase: 30,
  checksGreen: 20,
  dependencyReady: 15,
  priorityScale: 8,
  priorityBase: 40,
  coupling: Object.freeze({
    independent: 20,
    soft: 10,
    hard: 0
  }),
  riskClass: Object.freeze({
    low: 10,
    medium: 0,
    high: -10
  }),
  flakyExposure: Object.freeze({
    none: 0,
    medium: -10,
    high: -20
  }),
  ageMaxBonus: 12,
  ageHoursPerPoint: 6
});

function printUsage() {
  console.log('Usage: node tools/priority/queue-readiness.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --supervisor-report <path> Source queue supervisor report (default: ${DEFAULT_SUPERVISOR_REPORT_PATH}).`);
  console.log(`  --report <path>            Output queue readiness report (default: ${DEFAULT_READINESS_REPORT_PATH}).`);
  console.log('  -h, --help                 Show this help text and exit.');
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function normalizeLower(value) {
  return normalizeText(value).toLowerCase();
}

function normalizeIso(value) {
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return null;
  return date.toISOString();
}

function parseLabelNames(labels = []) {
  const normalized = [];
  for (const label of labels) {
    const name = typeof label === 'string' ? label : label?.name;
    const entry = normalizeLower(name);
    if (entry) normalized.push(entry);
  }
  return [...new Set(normalized)];
}

export function parseRiskClass({ body = '', labels = [] } = {}) {
  const bodyMatch = String(body).match(/^\s*Risk-Class\s*:\s*(low|medium|high)\s*$/im);
  if (bodyMatch?.[1]) {
    return bodyMatch[1].toLowerCase();
  }

  const labelNames = parseLabelNames(labels);
  if (labelNames.includes('risk-low')) return 'low';
  if (labelNames.includes('risk-high')) return 'high';
  return 'medium';
}

export function parseFlakyExposure({ body = '', labels = [] } = {}) {
  const bodyMatch = String(body).match(/^\s*Flaky-Exposure\s*:\s*(none|medium|high)\s*$/im);
  if (bodyMatch?.[1]) {
    return bodyMatch[1].toLowerCase();
  }

  const labelNames = parseLabelNames(labels);
  if (labelNames.includes('flaky-risk-high')) return 'high';
  if (labelNames.includes('flaky-risk-medium')) return 'medium';
  return 'none';
}

function ageHours(updatedAt, now) {
  const updatedMs = Date.parse(updatedAt || '');
  if (!Number.isFinite(updatedMs)) return 0;
  return Math.max(0, (now.valueOf() - updatedMs) / 3600000);
}

function normalizeCoupling(value) {
  const coupling = normalizeLower(value);
  if (coupling === 'soft' || coupling === 'hard') return coupling;
  return 'independent';
}

function parsePriority(value) {
  const numeric = Number(value);
  if (!Number.isInteger(numeric) || numeric < 0) return 9;
  return numeric;
}

function buildScoreComponents(candidate, now) {
  const priority = parsePriority(candidate?.priority);
  const coupling = normalizeCoupling(candidate?.coupling);
  const riskClass = parseRiskClass({ body: candidate?.body ?? '', labels: candidate?.labels ?? [] });
  const flakyExposure = parseFlakyExposure({ body: candidate?.body ?? '', labels: candidate?.labels ?? [] });
  const checksOk = Boolean(candidate?.checks?.ok);
  const dependencyReady = (candidate?.unresolvedOpenDependencies?.length ?? 0) === 0;
  const candidateAgeHours = ageHours(candidate?.updatedAt, now);
  const ageBonus = Math.min(
    SCORE_WEIGHTS.ageMaxBonus,
    Math.floor(candidateAgeHours / Math.max(1, SCORE_WEIGHTS.ageHoursPerPoint))
  );
  const priorityScore = Math.max(0, SCORE_WEIGHTS.priorityBase - priority * SCORE_WEIGHTS.priorityScale);

  const components = {
    readinessBase: candidate?.eligible ? SCORE_WEIGHTS.readinessBase : -SCORE_WEIGHTS.readinessBase,
    checksGreen: checksOk ? SCORE_WEIGHTS.checksGreen : -SCORE_WEIGHTS.checksGreen,
    dependencyReady: dependencyReady ? SCORE_WEIGHTS.dependencyReady : -SCORE_WEIGHTS.dependencyReady,
    priority: priorityScore,
    coupling: SCORE_WEIGHTS.coupling[coupling] ?? 0,
    riskClass: SCORE_WEIGHTS.riskClass[riskClass] ?? 0,
    flakyExposure: SCORE_WEIGHTS.flakyExposure[flakyExposure] ?? 0,
    age: ageBonus
  };
  const score = Object.values(components).reduce((sum, value) => sum + Number(value || 0), 0);
  return {
    score,
    components,
    priority,
    coupling,
    riskClass,
    flakyExposure,
    checksOk,
    dependencyReady,
    ageHours: Number(candidateAgeHours.toFixed(2))
  };
}

function compareReadySet(a, b) {
  if (a.dependencyRank !== b.dependencyRank) {
    return a.dependencyRank - b.dependencyRank;
  }
  if (a.score !== b.score) {
    return b.score - a.score;
  }
  if (a.priority !== b.priority) {
    return a.priority - b.priority;
  }
  const leftTime = Date.parse(a.updatedAt || '') || 0;
  const rightTime = Date.parse(b.updatedAt || '') || 0;
  if (leftTime !== rightTime) {
    return leftTime - rightTime;
  }
  return a.number - b.number;
}

export function buildQueueReadinessReport({
  repository,
  candidates = [],
  orderedEligible = [],
  now = new Date()
}) {
  const eligibleOrder = new Map(orderedEligible.map((number, index) => [Number(number), index]));
  const entries = candidates.map((candidate) => {
    const scored = buildScoreComponents(candidate, now);
    const number = Number(candidate?.number);
    const dependencyRank = eligibleOrder.has(number) ? eligibleOrder.get(number) : Number.MAX_SAFE_INTEGER;
    return {
      number,
      title: candidate?.title ?? '',
      url: candidate?.url ?? null,
      updatedAt: normalizeIso(candidate?.updatedAt) ?? new Date(0).toISOString(),
      eligible: Boolean(candidate?.eligible),
      reasons: Array.isArray(candidate?.reasons) ? [...candidate.reasons].sort() : [],
      priority: scored.priority,
      coupling: scored.coupling,
      riskClass: scored.riskClass,
      flakyExposure: scored.flakyExposure,
      dependencyReady: scored.dependencyReady,
      checksOk: scored.checksOk,
      dependencyRank,
      ageHours: scored.ageHours,
      score: scored.score,
      scoreComponents: scored.components
    };
  });

  const readySet = entries.filter((entry) => entry.eligible).sort(compareReadySet);
  return {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    scoring: {
      weights: SCORE_WEIGHTS
    },
    summary: {
      candidateCount: entries.length,
      readyCount: readySet.length,
      ineligibleCount: entries.length - readySet.length
    },
    readySet,
    candidates: entries.sort((left, right) => left.number - right.number)
  };
}

async function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

async function readJson(filePath) {
  const resolved = path.resolve(filePath);
  const raw = await readFile(resolved, 'utf8');
  return JSON.parse(raw);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    supervisorReportPath: DEFAULT_SUPERVISOR_REPORT_PATH,
    reportPath: DEFAULT_READINESS_REPORT_PATH,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '-h' || arg === '--help') {
      options.help = true;
      continue;
    }
    if (arg === '--supervisor-report' || arg === '--report') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--supervisor-report') {
        options.supervisorReportPath = next;
      } else {
        options.reportPath = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }
  return options;
}

export async function runQueueReadiness(options = {}) {
  const now = options.now ?? new Date();
  const supervisorReport = options.supervisorReport ?? null;
  const parsed = options.args ?? parseArgs();
  const reportPath = options.reportPath ?? parsed.reportPath;
  const source = supervisorReport ?? (await readJson(parsed.supervisorReportPath));
  const report = buildQueueReadinessReport({
    repository: source?.repository ?? process.env.GITHUB_REPOSITORY ?? 'unknown/unknown',
    candidates: source?.candidates ?? [],
    orderedEligible: source?.orderedEligible ?? [],
    now
  });
  const resolvedPath = await writeJson(reportPath, report);
  return {
    report,
    reportPath: resolvedPath
  };
}

export async function main(argv = process.argv) {
  const parsed = parseArgs(argv);
  if (parsed.help) {
    printUsage();
    return 0;
  }
  const { report, reportPath } = await runQueueReadiness({ args: parsed });
  console.log(
    `[queue-readiness] report: ${reportPath} (candidates=${report.summary.candidateCount}, ready=${report.summary.readyCount})`
  );
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).catch((error) => {
    console.error(error?.stack ?? error?.message ?? String(error));
    process.exitCode = 1;
  });
}

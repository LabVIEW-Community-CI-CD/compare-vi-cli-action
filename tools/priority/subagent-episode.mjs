#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const REPORT_SCHEMA = 'priority/subagent-episode-report@v1';
export const DEFAULT_OUTPUT_DIR = path.join(
  'tests',
  'results',
  '_agent',
  'memory',
  'subagent-episodes'
);

function normalizeText(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function sanitizeSegment(value, fallback = 'episode') {
  return String(value || '')
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '') || fallback;
}

function normalizeStringArray(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((entry) => normalizeText(entry)).filter(Boolean);
}

function normalizeFiniteNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizeInteger(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function normalizeBoolean(value) {
  if (value === true || value === false) {
    return value;
  }
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (normalized === 'true') {
      return true;
    }
    if (normalized === 'false') {
      return false;
    }
  }
  return null;
}

function normalizeObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function toPortablePath(filePath) {
  return String(filePath).replace(/\\/g, '/');
}

function toDisplayPath(repoRoot, filePath) {
  if (!filePath) {
    return null;
  }
  const resolvedRepoRoot = path.resolve(repoRoot);
  const resolvedPath = path.resolve(filePath);
  const relative = path.relative(resolvedRepoRoot, resolvedPath);
  if (!relative.startsWith('..') && !path.isAbsolute(relative)) {
    return toPortablePath(relative);
  }
  return toPortablePath(resolvedPath);
}

function isValidDateTime(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}

function readJsonFile(filePath) {
  const resolvedPath = path.resolve(filePath);
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function writeJsonFile(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    inputPath: null,
    outputPath: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (token === '--repo-root' || token === '--input' || token === '--output') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') {
        options.repoRoot = next;
      } else if (token === '--input') {
        options.inputPath = next;
      } else if (token === '--output') {
        options.outputPath = next;
      }
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !normalizeText(options.inputPath)) {
    throw new Error('--input is required.');
  }

  return options;
}

function buildDefaultOutputPath(repoRoot, report) {
  const timestamp = report.generatedAt.replace(/[:.]/g, '-');
  const agentSlug = sanitizeSegment(report.agent.name || report.agent.id || 'subagent', 'subagent');
  const issueSlug = Number.isInteger(report.task.issueNumber) ? `issue-${report.task.issueNumber}` : 'no-issue';
  return path.resolve(
    repoRoot,
    DEFAULT_OUTPUT_DIR,
    `${timestamp}-${agentSlug}-${issueSlug}.json`
  );
}

export function buildSubagentEpisodeReport(input, options = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const now = options.now || new Date();
  const source = normalizeObject(input) || {};
  const agent = normalizeObject(source.agent) || {};
  const task = normalizeObject(source.task) || {};
  const execution = normalizeObject(source.execution) || {};
  const summary = normalizeObject(source.summary) || {};
  const evidence = normalizeObject(source.evidence) || {};
  const cost = normalizeObject(source.cost) || {};
  const generatedAt = isValidDateTime(source.generatedAt) ? source.generatedAt : now.toISOString();
  const issueNumber =
    normalizeInteger(task.issueNumber) ??
    normalizeInteger(source.issueNumber) ??
    null;

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt,
    repository: normalizeText(source.repository),
    inputs: {
      sourcePath: toDisplayPath(repoRoot, options.inputPath || null)
    },
    episodeId:
      normalizeText(source.episodeId) ||
      `${sanitizeSegment(agent.name || agent.id || 'subagent', 'subagent')}-${generatedAt.replace(/[:.]/g, '-')}`,
    agent: {
      id: normalizeText(agent.id),
      name: normalizeText(agent.name),
      role: normalizeText(agent.role),
      model: normalizeText(agent.model)
    },
    task: {
      summary: normalizeText(task.summary) || '(unspecified task)',
      class: normalizeText(task.class),
      issueNumber,
      issueUrl: normalizeText(task.issueUrl) || normalizeText(source.issueUrl)
    },
    execution: {
      status: normalizeText(execution.status) || 'completed',
      lane: normalizeText(execution.lane),
      branch: normalizeText(execution.branch),
      executionPlane: normalizeText(execution.executionPlane),
      dockerLaneId: normalizeText(execution.dockerLaneId),
      hostCapabilityLeaseId: normalizeText(execution.hostCapabilityLeaseId),
      cellId: normalizeText(execution.cellId),
      executionCellLeaseId: normalizeText(execution.executionCellLeaseId),
      dockerLaneLeaseId: normalizeText(execution.dockerLaneLeaseId),
      cellClass: normalizeText(execution.cellClass),
      suiteClass: normalizeText(execution.suiteClass),
      harnessKind: normalizeText(execution.harnessKind),
      harnessInstanceId: normalizeText(execution.harnessInstanceId),
      harnessInstanceLeaseId: normalizeText(execution.harnessInstanceLeaseId),
      harnessInstanceLeasePath: normalizeText(execution.harnessInstanceLeasePath),
      runtimeSurface: normalizeText(execution.runtimeSurface),
      processModelClass: normalizeText(execution.processModelClass),
      operatorAuthorizationRef: normalizeText(execution.operatorAuthorizationRef),
      premiumSaganMode: normalizeBoolean(execution.premiumSaganMode)
    },
    summary: {
      status: normalizeText(summary.status) || normalizeText(source.status) || 'reported',
      outcome: normalizeText(summary.outcome),
      blocker: normalizeText(summary.blocker),
      nextAction: normalizeText(summary.nextAction),
      detail: normalizeText(summary.detail)
    },
    evidence: {
      filesTouched: normalizeStringArray(evidence.filesTouched),
      receipts: normalizeStringArray(evidence.receipts),
      commands: normalizeStringArray(evidence.commands),
      notes: normalizeStringArray(evidence.notes)
    },
    cost: {
      observedDurationSeconds:
        normalizeFiniteNumber(cost.observedDurationSeconds) ??
        normalizeFiniteNumber(cost.elapsedSeconds),
      tokenUsd: normalizeFiniteNumber(cost.tokenUsd),
      operatorLaborUsd: normalizeFiniteNumber(cost.operatorLaborUsd),
      blendedLowerBoundUsd:
        normalizeFiniteNumber(cost.blendedLowerBoundUsd) ??
        normalizeFiniteNumber(cost.blendedUsd)
    }
  };

  return report;
}

export async function runSubagentEpisode(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const inputPath = path.resolve(repoRoot, options.inputPath);
  const readJsonFn = deps.readJsonFn || readJsonFile;
  const writeJsonFn = deps.writeJsonFn || writeJsonFile;
  const now = deps.now || new Date();

  const input = readJsonFn(inputPath);
  const report = buildSubagentEpisodeReport(input, {
    repoRoot,
    inputPath,
    now
  });
  const outputPath = path.resolve(
    repoRoot,
    options.outputPath || buildDefaultOutputPath(repoRoot, report)
  );
  const writtenPath = writeJsonFn(outputPath, report);
  return { report, outputPath: writtenPath };
}

function printHelp() {
  console.log('Usage: node tools/priority/subagent-episode.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>   Repository root (default: current repo).');
  console.log('  --input <path>       Required input JSON path describing a subagent episode.');
  console.log(`  --output <path>      Optional output path (default under ${DEFAULT_OUTPUT_DIR}).`);
  console.log('  -h, --help           Show this help text.');
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[subagent-episode] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runSubagentEpisode(options);
    console.log(
      `[subagent-episode] wrote ${outputPath} (${report.agent.name || report.agent.id || 'subagent'} -> ${report.summary.status})`
    );
    return 0;
  } catch (error) {
    console.error(`[subagent-episode] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) {
        process.exitCode = code;
      }
    })
    .catch((error) => {
      console.error(`[subagent-episode] ${error.message}`);
      process.exitCode = 1;
    });
}

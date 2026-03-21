#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/operator-steering-event@v1';
export const DEFAULT_CONTINUITY_PATH = path.join('tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json');
export const DEFAULT_RUNTIME_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'operator-steering-event.json');
export const DEFAULT_HANDOFF_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'handoff', 'operator-steering-event.json');
export const DEFAULT_HISTORY_DIR = path.join('tests', 'results', '_agent', 'runtime', 'operator-steering-events');
export const DEFAULT_INVOICE_TURN_DIR = path.join('tests', 'results', '_agent', 'cost', 'invoice-turns');
export const DEFAULT_REPO_FAMILY_PREFIX = 'compare-vi-cli-action';

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function ensureParentDir(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function writeJson(filePath, payload) {
  ensureParentDir(filePath);
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function safeReadJson(filePath) {
  try {
    if (!fs.existsSync(filePath)) {
      return { exists: false, payload: null, error: null };
    }
    return { exists: true, payload: readJson(filePath), error: null };
  } catch (error) {
    return { exists: true, payload: null, error: error instanceof Error ? error.message : String(error) };
  }
}

function parseDate(value) {
  if (!normalizeText(value)) {
    return null;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? new Date(parsed) : null;
}

function newestByMtime(filePaths = []) {
  const candidates = filePaths
    .filter((filePath) => fs.existsSync(filePath))
    .map((filePath) => ({ filePath, mtimeMs: fs.statSync(filePath).mtimeMs }))
    .sort((left, right) => right.mtimeMs - left.mtimeMs);
  return candidates[0]?.filePath ?? null;
}

function listJsonFiles(dirPath) {
  if (!fs.existsSync(dirPath)) {
    return [];
  }
  return fs.readdirSync(dirPath)
    .filter((entry) => entry.toLowerCase().endsWith('.json'))
    .map((entry) => path.join(dirPath, entry));
}

function sanitizeFileToken(value) {
  return normalizeText(value).replace(/[^A-Za-z0-9._-]/g, '-');
}

function uniquePaths(values = []) {
  return Array.from(new Set(values.filter(Boolean).map((value) => path.resolve(value))));
}

function deriveRepoFamilyPrefix(repoRoot) {
  const baseName = path.basename(path.resolve(repoRoot));
  if (!normalizeText(baseName)) {
    return DEFAULT_REPO_FAMILY_PREFIX;
  }
  const dotIndex = baseName.indexOf('.');
  return dotIndex > 0 ? baseName.slice(0, dotIndex) : baseName;
}

function discoverInvoiceTurnDirs(invoiceTurnDir, repoRoot) {
  const discovered = [invoiceTurnDir];
  const repoFamilyPrefix = deriveRepoFamilyPrefix(repoRoot);
  const repoParent = path.dirname(path.resolve(repoRoot));

  let siblingDirs = [];
  try {
    siblingDirs = fs.readdirSync(repoParent, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && entry.name.startsWith(repoFamilyPrefix))
      .map((entry) => path.join(repoParent, entry.name));
  } catch {
    siblingDirs = [];
  }

  for (const siblingDir of siblingDirs) {
    discovered.push(path.join(siblingDir, 'tests', 'results', '_agent', 'cost', 'invoice-turns'));
    discovered.push(path.join(siblingDir, repoFamilyPrefix, 'tests', 'results', '_agent', 'cost', 'invoice-turns'));
  }

  return uniquePaths(discovered);
}

function scoreInvoiceTurnCandidate(filePath, payload, mtimeMs) {
  const fileName = path.basename(filePath).toLowerCase();
  const normalizedPath = filePath.toLowerCase();
  let score = 0;

  if (fileName.endsWith('.local.json')) {
    score += 100;
  }
  if (!/[.-](sample|smoke|fixture)([.-]|$)/.test(fileName) && !normalizedPath.includes('__fixtures__')) {
    score += 25;
  }
  if (normalizeText(payload?.policy?.activationState) === 'active') {
    score += 10;
  }
  if (normalizeText(payload?.invoiceTurnId)) {
    score += 5;
  }

  return { score, mtimeMs };
}

function resolveLatestInvoiceTurn(invoiceTurnDir, repoRoot) {
  const invoiceTurnDirs = discoverInvoiceTurnDirs(invoiceTurnDir, repoRoot);
  const candidatePaths = invoiceTurnDirs.flatMap((dirPath) => listJsonFiles(dirPath));
  if (!candidatePaths.length) {
    return {
      status: 'missing',
      path: path.resolve(invoiceTurnDir),
      invoiceTurnId: null,
      fundingPurpose: null,
      activationState: null
    };
  }

  const rankedCandidates = candidatePaths
    .map((filePath) => {
      const loaded = safeReadJson(filePath);
      const stat = fs.existsSync(filePath) ? fs.statSync(filePath) : null;
      return {
        filePath,
        loaded,
        stat,
        ranking: scoreInvoiceTurnCandidate(filePath, loaded.payload, stat?.mtimeMs ?? 0)
      };
    })
    .sort((left, right) => {
      if (right.ranking.score !== left.ranking.score) {
        return right.ranking.score - left.ranking.score;
      }
      return right.ranking.mtimeMs - left.ranking.mtimeMs;
    });

  const latest = rankedCandidates[0];
  if (!latest?.filePath) {
    return {
      status: 'missing',
      path: path.resolve(invoiceTurnDir),
      invoiceTurnId: null,
      fundingPurpose: null,
      activationState: null
    };
  }

  if (!latest.loaded.payload || typeof latest.loaded.payload !== 'object') {
    return {
      status: 'invalid',
      path: path.resolve(latest.filePath),
      invoiceTurnId: null,
      fundingPurpose: null,
      activationState: null,
      error: latest.loaded.error || 'invoice-turn-unreadable'
    };
  }

  const payload = latest.loaded.payload;
  return {
    status: 'resolved',
    path: path.resolve(latest.filePath),
    invoiceTurnId: normalizeText(payload.invoiceTurnId) || null,
    fundingPurpose: normalizeText(payload?.policy?.fundingPurpose) || null,
    activationState: normalizeText(payload?.policy?.activationState) || null
  };
}

function computeEventKey(continuityPayload) {
  const issue = continuityPayload?.issueContext?.issue ?? 'none';
  const boundaryStatus = normalizeText(continuityPayload?.continuity?.turnBoundary?.status) || 'none';
  const continuityReferenceAt = normalizeText(continuityPayload?.continuity?.quietPeriod?.continuityReferenceAt) || 'none';
  const wakeCondition = normalizeText(continuityPayload?.continuity?.turnBoundary?.wakeCondition) || 'none';
  return ['continuity-resume', issue, boundaryStatus, continuityReferenceAt, wakeCondition].join('|');
}

export function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    repoRoot: process.cwd(),
    continuityPath: null,
    runtimeOutputPath: null,
    handoffOutputPath: null,
    historyDir: null,
    invoiceTurnDir: null,
    steeringKind: 'operator-prompt-resume',
    triggerKind: 'continuity-failure',
    now: null,
    help: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    switch (token) {
      case '--repo-root':
        options.repoRoot = path.resolve(argv[++index] || options.repoRoot);
        break;
      case '--continuity':
        options.continuityPath = argv[++index] || null;
        break;
      case '--output':
        options.runtimeOutputPath = argv[++index] || null;
        break;
      case '--handoff-output':
        options.handoffOutputPath = argv[++index] || null;
        break;
      case '--history-dir':
        options.historyDir = argv[++index] || null;
        break;
      case '--invoice-turn-dir':
        options.invoiceTurnDir = argv[++index] || null;
        break;
      case '--steering-kind':
        options.steeringKind = argv[++index] || options.steeringKind;
        break;
      case '--trigger-kind':
        options.triggerKind = argv[++index] || options.triggerKind;
        break;
      case '--now':
        options.now = argv[++index] || null;
        break;
      case '--help':
      case '-h':
        options.help = true;
        break;
      default:
        throw new Error(`Unknown option: ${token}`);
    }
  }

  options.continuityPath = path.resolve(options.repoRoot, options.continuityPath || DEFAULT_CONTINUITY_PATH);
  options.runtimeOutputPath = path.resolve(options.repoRoot, options.runtimeOutputPath || DEFAULT_RUNTIME_OUTPUT_PATH);
  options.handoffOutputPath = path.resolve(options.repoRoot, options.handoffOutputPath || DEFAULT_HANDOFF_OUTPUT_PATH);
  options.historyDir = path.resolve(options.repoRoot, options.historyDir || DEFAULT_HISTORY_DIR);
  options.invoiceTurnDir = path.resolve(options.repoRoot, options.invoiceTurnDir || DEFAULT_INVOICE_TURN_DIR);
  return options;
}

export function buildOperatorSteeringEvent(options = {}, now = new Date()) {
  const continuityInput = safeReadJson(options.continuityPath);
  if (!continuityInput.exists) {
    return {
      status: 'missing-continuity',
      report: null,
      blocker: {
        code: 'continuity-report-missing',
        message: `Continuity telemetry not found at ${options.continuityPath}.`
      }
    };
  }
  if (!continuityInput.payload || typeof continuityInput.payload !== 'object') {
    return {
      status: 'invalid-continuity',
      report: null,
      blocker: {
        code: 'continuity-report-invalid',
        message: continuityInput.error || 'Continuity telemetry could not be parsed.'
      }
    };
  }

  const continuity = continuityInput.payload;
  const turnBoundary = continuity?.continuity?.turnBoundary;
  if (turnBoundary?.operatorTurnEndWouldCreateIdleGap !== true) {
    return {
      status: 'no-event',
      report: null,
      blocker: null
    };
  }

  const eventKey = computeEventKey(continuity);
  const latest = safeReadJson(options.runtimeOutputPath);
  if (latest.payload && normalizeText(latest.payload.eventKey) === eventKey) {
    return {
      status: 'deduped',
      report: latest.payload,
      blocker: null
    };
  }

  const invoiceTurn = resolveLatestInvoiceTurn(options.invoiceTurnDir, options.repoRoot);
  const timestamp = now.toISOString();
  const issueNumber = continuity?.issueContext?.issue ?? null;
  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: timestamp,
    eventKey,
    steeringKind: normalizeText(options.steeringKind) || 'operator-prompt-resume',
    triggerKind: normalizeText(options.triggerKind) || 'continuity-failure',
    repository: normalizeText(process.env.GITHUB_REPOSITORY) || null,
    issueContext: {
      mode: normalizeText(continuity?.issueContext?.mode) || null,
      issue: issueNumber,
      observedAt: normalizeText(continuity?.issueContext?.observedAt) || null
    },
    continuity: {
      sourcePath: path.relative(options.repoRoot, options.continuityPath).replace(/\\/g, '/'),
      status: normalizeText(continuity?.status) || null,
      recommendation: normalizeText(continuity?.continuity?.recommendation) || null,
      continuityReferenceAt: normalizeText(continuity?.continuity?.quietPeriod?.continuityReferenceAt) || null,
      turnBoundary: {
        status: normalizeText(turnBoundary?.status) || null,
        operatorTurnEndWouldCreateIdleGap: turnBoundary?.operatorTurnEndWouldCreateIdleGap === true,
        activeLaneIssue: turnBoundary?.activeLaneIssue ?? null,
        wakeCondition: normalizeText(turnBoundary?.wakeCondition) || null,
        source: normalizeText(turnBoundary?.source) || null,
        reason: normalizeText(turnBoundary?.reason) || null
      }
    },
    fundingWindow: invoiceTurn,
    provenance: {
      source: 'bootstrap-resume-detection',
      sessionName: normalizeText(process.env.AGENT_SESSION_NAME) || null,
      actor: normalizeText(process.env.GITHUB_ACTOR) || normalizeText(process.env.USERNAME) || null
    }
  };

  const historyFile = path.join(
    options.historyDir,
    `${sanitizeFileToken(timestamp)}-${sanitizeFileToken(issueNumber ?? 'none')}.json`
  );

  return {
    status: 'created',
    report,
    historyFile
  };
}

export function runOperatorSteeringEvent(options = {}, now = new Date()) {
  const result = buildOperatorSteeringEvent(options, now);
  if (result.status !== 'created') {
    return result;
  }

  writeJson(options.runtimeOutputPath, result.report);
  writeJson(options.handoffOutputPath, result.report);
  ensureParentDir(result.historyFile);
  writeJson(result.historyFile, result.report);

  return {
    ...result,
    runtimeOutputPath: options.runtimeOutputPath,
    handoffOutputPath: options.handoffOutputPath
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/operator-steering-event.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>         Repository root (default: cwd).');
  console.log('  --continuity <path>        Continuity telemetry path.');
  console.log('  --output <path>            Runtime latest-event output path.');
  console.log('  --handoff-output <path>    Handoff copy output path.');
  console.log('  --history-dir <path>       History directory for immutable event receipts.');
  console.log('  --invoice-turn-dir <path>  Directory containing normalized invoice-turn receipts.');
  console.log('  --steering-kind <kind>     Steering kind label (default: operator-prompt-resume).');
  console.log('  --trigger-kind <kind>      Trigger label (default: continuity-failure).');
  console.log('  --now <iso>                Deterministic timestamp for tests.');
  console.log('  -h, --help                 Show help and exit.');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv.slice(2));
    if (options.help) {
      printUsage();
      return 0;
    }
    const now = options.now ? new Date(options.now) : new Date();
    const result = runOperatorSteeringEvent(options, now);
    if (result.status === 'created') {
      console.log(`[operator-steering-event] wrote ${result.runtimeOutputPath}`);
      return 0;
    }
    if (result.status === 'deduped') {
      console.log('[operator-steering-event] existing event already covers this continuity state');
      return 0;
    }
    if (result.status === 'no-event') {
      console.log('[operator-steering-event] continuity state does not require a steering event');
      return 0;
    }
    if (result.blocker) {
      console.warn(`[operator-steering-event] ${result.blocker.message}`);
    }
    return 0;
  } catch (error) {
    console.error(`[operator-steering-event] ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}

const entrypointPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (entrypointPath && modulePath === entrypointPath) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

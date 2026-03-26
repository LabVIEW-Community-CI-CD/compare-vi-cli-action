#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { deriveCurrentCycleIdleAuthority } from './lib/current-cycle-idle-authority.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const SNAPSHOT_SCHEMA = 'priority/background-agent-state-snapshot@v1';
export const REPORT_SCHEMA = 'agent-handoff/background-agent-saturation-v1';
export const DEFAULT_SNAPSHOT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'background-agent-state.json'
);
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'background-agent-saturation.json'
);
export const DEFAULT_PRIORITY_CACHE_PATH = '.agent_priority_cache.json';
export const DEFAULT_ROUTER_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'router.json'
);
export const DEFAULT_NO_STANDING_PRIORITY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'no-standing-priority.json'
);
export const DEFAULT_DELIVERY_RUNTIME_STATE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'delivery-agent-state.json'
);
export const DEFAULT_OBSERVER_HEARTBEAT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'observer-heartbeat.json'
);

export const MODE_DEFAULTS = {
  conserve: { target: 0.33, band: { min: 0.17, max: 0.5 } },
  balanced: { target: 0.67, band: { min: 0.5, max: 0.83 } },
  aggressive: { target: 0.83, band: { min: 0.67, max: 1.0 } },
  'max-burn': { target: 1.0, band: { min: 0.83, max: 1.0 } }
};

export const STATE_WEIGHTS = {
  productive: 1.0,
  'awaiting-instruction': 0.25,
  done: 0.0,
  idle: 0.0,
  blocked: 0.0,
  duplicate: 0.0,
  'polling-only': 0.0,
  'speculative-churn': 0.0,
  other: 0.0
};

const PRODUCTIVE_STATES = new Set([
  'productive',
  'active',
  'running',
  'in-progress',
  'in_progress',
  'working',
  'reported'
]);

const AWAITING_STATES = new Set([
  'awaiting instruction',
  'awaiting-instruction',
  'awaiting_input',
  'awaiting-input',
  'awaiting input',
  'awaiting-instructions',
  'waiting-for-instructions'
]);

const DONE_STATES = new Set([
  'done',
  'completed',
  'complete',
  'pass',
  'passed',
  'success',
  'successful',
  'closed',
  'retired'
]);

const IDLE_STATES = new Set(['idle', 'unassigned']);
const BLOCKED_STATES = new Set(['blocked']);
const DUPLICATE_STATES = new Set(['duplicate']);
const POLLING_ONLY_STATES = new Set(['polling-only', 'polling only']);
const SPECULATIVE_CHURN_STATES = new Set(['speculative-churn', 'speculative churn']);

function normalizeText(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeInteger(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function normalizeNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizeRatio(value) {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(0, Math.min(1, Number(value.toFixed(4))));
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

function readOptionalJson(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function ensureSchema(payload, filePath, schema) {
  if (payload?.schema !== schema) {
    throw new Error(`Expected ${schema} at ${filePath}.`);
  }
  return payload;
}

function classifyAgentState(value) {
  const normalized = (normalizeText(value) || 'other').toLowerCase();
  if (PRODUCTIVE_STATES.has(normalized)) {
    return 'productive';
  }
  if (AWAITING_STATES.has(normalized)) {
    return 'awaiting-instruction';
  }
  if (DONE_STATES.has(normalized)) {
    return 'done';
  }
  if (IDLE_STATES.has(normalized)) {
    return 'idle';
  }
  if (BLOCKED_STATES.has(normalized)) {
    return 'blocked';
  }
  if (DUPLICATE_STATES.has(normalized)) {
    return 'duplicate';
  }
  if (POLLING_ONLY_STATES.has(normalized)) {
    return 'polling-only';
  }
  if (SPECULATIVE_CHURN_STATES.has(normalized)) {
    return 'speculative-churn';
  }
  return 'other';
}

function defaultBandForMode(mode, targetSaturation) {
  const defaults = MODE_DEFAULTS[mode];
  if (defaults) {
    return defaults.band;
  }
  const target = normalizeNumber(targetSaturation) ?? MODE_DEFAULTS.balanced.target;
  return {
    min: normalizeRatio(target - 0.15),
    max: 1.0
  };
}

function defaultTargetForMode(mode) {
  return MODE_DEFAULTS[mode]?.target ?? MODE_DEFAULTS.balanced.target;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    snapshotPath: DEFAULT_SNAPSHOT_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    priorityCachePath: DEFAULT_PRIORITY_CACHE_PATH,
    routerPath: DEFAULT_ROUTER_PATH,
    noStandingPriorityPath: DEFAULT_NO_STANDING_PRIORITY_PATH,
    owner: null,
    mode: null,
    targetSaturation: null,
    availableAgents: null,
    measurementWindow: 'rolling-30m',
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    const needsValue = new Set([
      '--repo-root',
      '--snapshot',
      '--output',
      '--priority-cache',
      '--router',
      '--no-standing-priority',
      '--owner',
      '--mode',
      '--target-saturation',
      '--available-agents',
      '--measurement-window'
    ]);
    if (needsValue.has(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      switch (token) {
        case '--repo-root':
          options.repoRoot = next;
          break;
        case '--snapshot':
          options.snapshotPath = next;
          break;
        case '--output':
          options.outputPath = next;
          break;
        case '--priority-cache':
          options.priorityCachePath = next;
          break;
        case '--router':
          options.routerPath = next;
          break;
        case '--no-standing-priority':
          options.noStandingPriorityPath = next;
          break;
        case '--owner':
          options.owner = next;
          break;
        case '--mode':
          options.mode = next;
          break;
        case '--target-saturation':
          options.targetSaturation = next;
          break;
        case '--available-agents':
          options.availableAgents = next;
          break;
        case '--measurement-window':
          options.measurementWindow = next;
          break;
        default:
          break;
      }
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function buildAgentEntries(snapshotAgents = []) {
  return snapshotAgents.map((agent, index) => {
    const state = classifyAgentState(agent?.state);
    return {
      id: normalizeText(agent?.id) || `agent-${index + 1}`,
      name: normalizeText(agent?.name),
      state,
      weight: STATE_WEIGHTS[state] ?? 0,
      taskSummary: normalizeText(agent?.taskSummary),
      detail: normalizeText(agent?.detail)
    };
  });
}

function countAgentStates(agents) {
  const counts = {
    productive: 0,
    awaitingInstruction: 0,
    done: 0,
    idle: 0,
    blocked: 0,
    duplicate: 0,
    pollingOnly: 0,
    speculativeChurn: 0,
    other: 0
  };

  for (const agent of agents) {
    switch (agent.state) {
      case 'productive':
        counts.productive += 1;
        break;
      case 'awaiting-instruction':
        counts.awaitingInstruction += 1;
        break;
      case 'done':
        counts.done += 1;
        break;
      case 'idle':
        counts.idle += 1;
        break;
      case 'blocked':
        counts.blocked += 1;
        break;
      case 'duplicate':
        counts.duplicate += 1;
        break;
      case 'polling-only':
        counts.pollingOnly += 1;
        break;
      case 'speculative-churn':
        counts.speculativeChurn += 1;
        break;
      default:
        counts.other += 1;
        break;
    }
  }

  return counts;
}

function resolveConstraint({ noStandingPriority, router, currentCycleIdleAuthority }) {
  if (noStandingPriority?.reason === 'queue-empty' && !normalizeInteger(router?.issue)) {
    return {
      status: 'constrained',
      reason: currentCycleIdleAuthority?.status === 'observed' ? 'queue-empty-current-cycle-idle' : 'queue-empty'
    };
  }
  return {
    status: 'active',
    reason: null
  };
}

export function buildBackgroundAgentSaturationReport(snapshotInput = {}, options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const now = deps.now || new Date();
  const readJsonFn = deps.readJsonFn || readOptionalJson;
  const snapshot = snapshotInput || {};

  if (snapshot.schema) {
    ensureSchema(snapshot, options.snapshotPath || DEFAULT_SNAPSHOT_PATH, SNAPSHOT_SCHEMA);
  }

  const owner = normalizeText(options.owner) || normalizeText(snapshot.owner) || 'Sagan';
  const mode = normalizeText(options.mode) || normalizeText(snapshot.mode) || 'balanced';
  const targetSaturation =
    normalizeNumber(options.targetSaturation) ??
    normalizeNumber(snapshot.targetSaturation) ??
    defaultTargetForMode(mode);

  const snapshotBand = snapshot.acceptableBand && typeof snapshot.acceptableBand === 'object'
    ? {
        min: normalizeNumber(snapshot.acceptableBand.min),
        max: normalizeNumber(snapshot.acceptableBand.max)
      }
    : null;
  const band = snapshotBand?.min != null && snapshotBand?.max != null
    ? snapshotBand
    : defaultBandForMode(mode, targetSaturation);

  const agents = buildAgentEntries(Array.isArray(snapshot.agents) ? snapshot.agents : []);
  const observedAgents = agents.length;
  const availableAgents =
    normalizeInteger(options.availableAgents) ??
    normalizeInteger(snapshot.availableAgents) ??
    observedAgents;
  const counts = countAgentStates(agents);
  const weightedProductiveAgents = Number(
    agents.reduce((sum, agent) => sum + (STATE_WEIGHTS[agent.state] ?? 0), 0).toFixed(4)
  );
  const rawOccupancy = availableAgents > 0 ? normalizeRatio(observedAgents / availableAgents) : 0;
  const effectiveSaturation = availableAgents > 0 ? normalizeRatio(weightedProductiveAgents / availableAgents) : 0;

  const priorityCachePath = path.resolve(repoRoot, options.priorityCachePath || DEFAULT_PRIORITY_CACHE_PATH);
  const routerPath = path.resolve(repoRoot, options.routerPath || DEFAULT_ROUTER_PATH);
  const noStandingPriorityPath = path.resolve(repoRoot, options.noStandingPriorityPath || DEFAULT_NO_STANDING_PRIORITY_PATH);
  const deliveryRuntimeStatePath = path.resolve(repoRoot, options.deliveryRuntimeStatePath || DEFAULT_DELIVERY_RUNTIME_STATE_PATH);
  const observerHeartbeatPath = path.resolve(repoRoot, options.observerHeartbeatPath || DEFAULT_OBSERVER_HEARTBEAT_PATH);
  const priorityCache = readJsonFn(priorityCachePath);
  const router = readJsonFn(routerPath);
  const noStandingPriority = readJsonFn(noStandingPriorityPath);
  const deliveryRuntimeState = readJsonFn(deliveryRuntimeStatePath);
  const observerHeartbeat = readJsonFn(observerHeartbeatPath);
  const currentCycleIdleAuthority = deriveCurrentCycleIdleAuthority({
    deliveryRuntimeState,
    observerHeartbeat,
    now
  });
  const resolvedConstraint = resolveConstraint({ noStandingPriority, router, currentCycleIdleAuthority });
  const explicitConstraintReason = normalizeText(snapshot.constraintReason);
  const constraintReason = explicitConstraintReason || resolvedConstraint.reason;
  const status = availableAgents <= 0 ? 'not-applicable' : constraintReason ? 'constrained' : resolvedConstraint.status;

  return {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    owner,
    mode,
    targetSaturation,
    acceptableBand: {
      min: normalizeRatio(band.min),
      max: normalizeRatio(band.max)
    },
    measurementWindow: normalizeText(options.measurementWindow) || normalizeText(snapshot.measurementWindow) || 'rolling-30m',
    availableAgents,
    observedAgents,
    productiveAgents: counts.productive,
    awaitingInstructionAgents: counts.awaitingInstruction,
    doneAgents: counts.done,
    stateCounts: counts,
    weights: {
      productive: STATE_WEIGHTS.productive,
      awaitingInstruction: STATE_WEIGHTS['awaiting-instruction'],
      done: STATE_WEIGHTS.done
    },
    weightedProductiveAgents,
    rawOccupancy,
    rollingSaturation: effectiveSaturation,
    effectiveSaturation,
    status,
    constraintReason,
    currentCycleIdleAuthority,
    applicable: availableAgents > 0,
    priorityRule: 'throughput-and-proof-quality-outrank-saturation',
    countingRule: {
      productive: 'distinct bounded work that materially advances the active rail or pre-validates the next bounded slice',
      weights: {
        productive: STATE_WEIGHTS.productive,
        'awaiting-instruction': STATE_WEIGHTS['awaiting-instruction'],
        done: STATE_WEIGHTS.done,
        idle: STATE_WEIGHTS.idle,
        blocked: STATE_WEIGHTS.blocked,
        duplicate: STATE_WEIGHTS.duplicate,
        'polling-only': STATE_WEIGHTS['polling-only'],
        'speculative-churn': STATE_WEIGHTS['speculative-churn'],
        other: STATE_WEIGHTS.other
      },
      excluded: ['idle', 'blocked', 'duplicate', 'polling-only', 'speculative-churn']
    },
    evidence: {
      snapshotPath: toDisplayPath(repoRoot, path.resolve(repoRoot, options.snapshotPath || DEFAULT_SNAPSHOT_PATH)),
      priorityCache: toDisplayPath(repoRoot, priorityCachePath),
      router: toDisplayPath(repoRoot, routerPath),
      noStandingPriority: toDisplayPath(repoRoot, noStandingPriorityPath),
      deliveryRuntimeState: toDisplayPath(repoRoot, deliveryRuntimeStatePath),
      observerHeartbeat: toDisplayPath(repoRoot, observerHeartbeatPath)
    },
    notes: [
      `Mode ${mode} uses target saturation ${targetSaturation}.`,
      'Awaiting-instruction agents incur a partial penalty (0.25) instead of counting as fully productive.',
      'Done agents count as fully non-productive for effective saturation.',
      currentCycleIdleAuthority.status === 'observed'
        ? `Current-cycle idle authority is sourced from ${currentCycleIdleAuthority.source}.`
        : 'Current-cycle idle authority is not currently observed in the source runtime receipts.'
    ].concat(Array.isArray(snapshot.notes) ? snapshot.notes.map((entry) => normalizeText(entry)).filter(Boolean) : []),
    agents
  };
}

export async function runBackgroundAgentSaturation(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const snapshotPath = path.resolve(repoRoot, options.snapshotPath || DEFAULT_SNAPSHOT_PATH);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);
  const readJsonFn = deps.readJsonFn || readOptionalJson;
  const writeJsonFn = deps.writeJsonFn || writeJson;
  const now = deps.now || new Date();
  const snapshot = readJsonFn(snapshotPath) || {};
  const report = buildBackgroundAgentSaturationReport(snapshot, {
    ...options,
    repoRoot,
    snapshotPath
  }, {
    ...deps,
    now,
    readJsonFn
  });
  const writtenPath = writeJsonFn(outputPath, report);
  return { report, outputPath: writtenPath };
}

function printHelp() {
  console.log('Usage: node tools/priority/background-agent-saturation.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>            Repository root (default: current repo).');
  console.log(`  --snapshot <path>             Agent-state snapshot path (default: ${DEFAULT_SNAPSHOT_PATH}).`);
  console.log(`  --output <path>               Output handoff path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --priority-cache <path>       Optional priority cache path.');
  console.log('  --router <path>               Optional router path.');
  console.log('  --no-standing-priority <path> Optional no-standing-priority path.');
  console.log('  --owner <name>                Override report owner.');
  console.log('  --mode <name>                 Saturation mode (conserve|balanced|aggressive|max-burn|custom).');
  console.log('  --target-saturation <ratio>   Override target saturation.');
  console.log('  --available-agents <count>    Override available background-agent count.');
  console.log('  --measurement-window <text>   Override measurement window label.');
  console.log('  -h, --help                    Show this help text.');
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[background-agent-saturation] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runBackgroundAgentSaturation(options);
    console.log(
      `[background-agent-saturation] wrote ${outputPath} (${report.status}, saturation=${report.effectiveSaturation})`
    );
    return 0;
  } catch (error) {
    console.error(`[background-agent-saturation] ${error.message}`);
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
      console.error(`[background-agent-saturation] ${error.message}`);
      process.exitCode = 1;
    });
}

#!/usr/bin/env node

import { existsSync } from 'node:fs';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { loadCopilotCliReviewPolicy } from '../../priority/copilot-cli-review.mjs';
import {
  describeLocalReviewProvider,
  SUPPORTED_LOCAL_REVIEW_PROVIDERS
} from '../providers/local-review-providers.mjs';
import {
  DEFAULT_LOCAL_COLLAB_LEDGER_ROOT,
  LOCAL_COLLAB_LEDGER_RECEIPT_SCHEMA
} from '../ledger/local-review-ledger.mjs';

export const LOCAL_COLLAB_KPI_SCHEMA = 'comparevi/local-collab-kpi-summary@v1';
export const DEFAULT_LOCAL_COLLAB_KPI_ROOT = path.join('tests', 'results', '_agent', 'local-collab', 'kpi');
export const DEFAULT_LOCAL_COLLAB_KPI_SUMMARY_PATH = path.join(DEFAULT_LOCAL_COLLAB_KPI_ROOT, 'summary.json');
export const SUPPORTED_LOCAL_COLLAB_PLANES = ['personal', 'origin', 'upstream'];

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function normalizeInteger(value) {
  return Number.isInteger(value) ? value : 0;
}

function normalizeArray(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((entry) => normalizeText(entry)).filter(Boolean);
}

function normalizeTimestamp(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = new Date(normalized);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

function toSerializableCounts(map) {
  return Object.fromEntries(
    [...map.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, value]) => [key, value])
  );
}

function bumpCount(map, key, amount = 1) {
  const normalizedKey = normalizeText(key) || 'unknown';
  map.set(normalizedKey, (map.get(normalizedKey) ?? 0) + amount);
}

function addOptionalCount(map, key) {
  const normalizedKey = normalizeText(key);
  if (!normalizedKey) {
    return;
  }
  bumpCount(map, normalizedKey);
}

function createMetricsAccumulator() {
  return {
    receiptCount: 0,
    durationMs: 0,
    findingCount: 0,
    headShas: new Set(),
    phases: new Map(),
    statuses: new Map(),
    outcomes: new Map(),
    requestedModels: new Map(),
    effectiveModels: new Map(),
    providerIds: new Map()
  };
}

function addMetricsEvent(accumulator, event = {}) {
  accumulator.receiptCount += 1;
  accumulator.durationMs += normalizeInteger(event.durationMs);
  accumulator.findingCount += normalizeInteger(event.findingCount);
  addOptionalCount(accumulator.phases, event.phase);
  addOptionalCount(accumulator.statuses, event.status);
  addOptionalCount(accumulator.outcomes, event.outcome);
  addOptionalCount(accumulator.requestedModels, event.requestedModel);
  addOptionalCount(accumulator.effectiveModels, event.effectiveModel);
  addOptionalCount(accumulator.providerIds, event.providerId);

  const headSha = normalizeText(event.headSha);
  if (headSha) {
    accumulator.headShas.add(headSha);
  }
}

function finalizeMetrics(accumulator) {
  return {
    receiptCount: accumulator.receiptCount,
    uniqueHeadCount: accumulator.headShas.size,
    durationMs: accumulator.durationMs,
    findingCount: accumulator.findingCount,
    phases: toSerializableCounts(accumulator.phases),
    statuses: toSerializableCounts(accumulator.statuses),
    outcomes: toSerializableCounts(accumulator.outcomes),
    requestedModels: toSerializableCounts(accumulator.requestedModels),
    effectiveModels: toSerializableCounts(accumulator.effectiveModels),
    providers: toSerializableCounts(accumulator.providerIds)
  };
}

function createPlaneAccumulator(plane) {
  return {
    plane,
    receiptEffort: createMetricsAccumulator(),
    providerEffort: createMetricsAccumulator(),
    personas: new Map()
  };
}

function getPersonaAccumulator(planeAccumulator, persona) {
  const normalizedPersona = normalizeText(persona) || 'unknown';
  if (!planeAccumulator.personas.has(normalizedPersona)) {
    planeAccumulator.personas.set(normalizedPersona, {
      persona: normalizedPersona,
      receiptEffort: createMetricsAccumulator(),
      providerEffort: createMetricsAccumulator()
    });
  }
  return planeAccumulator.personas.get(normalizedPersona);
}

function finalizePlaneAccumulator(planeAccumulator) {
  const personas = Object.fromEntries(
    [...planeAccumulator.personas.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([persona, accumulator]) => [
        persona,
        {
          persona,
          receiptEffort: finalizeMetrics(accumulator.receiptEffort),
          providerEffort: finalizeMetrics(accumulator.providerEffort)
        }
      ])
  );

  return {
    plane: planeAccumulator.plane,
    receiptEffort: finalizeMetrics(planeAccumulator.receiptEffort),
    providerEffort: finalizeMetrics(planeAccumulator.providerEffort),
    personas
  };
}

function createProviderAccumulator(providerId, assignment) {
  const description = describeLocalReviewProvider(providerId);
  return {
    providerId,
    executable: description.executable,
    reserved: description.reserved,
    plane: assignment.plane,
    persona: assignment.persona,
    effortType: assignment.effortType,
    totals: createMetricsAccumulator()
  };
}

function buildProviderAssignments(collaboration) {
  const reviewPlane = normalizeText(collaboration?.reviewRemote) || 'origin';
  const reviewPersona = normalizeText(collaboration?.reviewPersona) || 'copilot-cli';
  const authoringPlane = normalizeText(collaboration?.authoringRemote) || 'personal';
  const authoringPersona = normalizeText(collaboration?.authoringPersona) || 'codex';

  return {
    'copilot-cli': {
      plane: reviewPlane,
      persona: reviewPersona,
      effortType: 'review'
    },
    simulation: {
      plane: reviewPlane,
      persona: 'simulation',
      effortType: 'review'
    },
    'codex-cli': {
      plane: authoringPlane,
      persona: authoringPersona,
      effortType: 'authoring'
    },
    ollama: {
      plane: reviewPlane,
      persona: 'ollama',
      effortType: 'review'
    }
  };
}

function allocateEvenly(total, count) {
  const normalizedCount = Number.isInteger(count) && count > 0 ? count : 0;
  if (normalizedCount === 0) {
    return [];
  }
  const normalizedTotal = normalizeInteger(total);
  const base = Math.floor(normalizedTotal / normalizedCount);
  let remainder = normalizedTotal - base * normalizedCount;
  return Array.from({ length: normalizedCount }, () => {
    if (remainder > 0) {
      remainder -= 1;
      return base + 1;
    }
    return base;
  });
}

function shouldRecordModelForProvider(receiptProviders, providerId, receiptProviderId) {
  if (receiptProviders.length === 1) {
    return receiptProviders[0] === providerId;
  }
  return normalizeText(receiptProviderId) === providerId;
}

function normalizeLedgerReceipt(value) {
  const receipt = value && typeof value === 'object' ? value : {};
  const providers = normalizeArray(receipt.providers);
  return {
    schema: normalizeText(receipt.schema),
    receiptId: normalizeText(receipt.receiptId),
    phase: normalizeText(receipt.phase),
    forkPlane: normalizeText(receipt.forkPlane) || 'unknown',
    persona: normalizeText(receipt.persona) || 'unknown',
    headSha: normalizeText(receipt.headSha),
    baseSha: normalizeText(receipt.baseSha),
    providerId: normalizeText(receipt.providerId) || (providers.length === 1 ? providers[0] : providers.length > 1 ? 'multi' : 'none'),
    providers,
    requestedModel: normalizeText(receipt.requestedModel) || null,
    effectiveModel: normalizeText(receipt.effectiveModel) || null,
    startedAt: normalizeTimestamp(receipt.startedAt),
    finishedAt: normalizeTimestamp(receipt.finishedAt),
    durationMs: normalizeInteger(receipt.durationMs),
    findingCount: normalizeInteger(receipt.findingCount),
    status: normalizeText(receipt.status) || 'unknown',
    outcome: normalizeText(receipt.outcome) || 'unknown',
    selectionSource: normalizeText(receipt.selectionSource) || null,
    sourceReceiptIds: normalizeArray(receipt.sourceReceiptIds)
  };
}

async function readLedgerReceiptFile(filePath) {
  let parsed;
  try {
    parsed = JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to parse local collaboration ledger receipt '${filePath}': ${error.message}`);
  }

  const receipt = normalizeLedgerReceipt(parsed);
  if (receipt.schema !== LOCAL_COLLAB_LEDGER_RECEIPT_SCHEMA) {
    throw new Error(`Unexpected local collaboration ledger receipt schema in '${filePath}': ${receipt.schema || '(missing)'}`);
  }
  if (!receipt.phase || !receipt.headSha || !receipt.receiptId) {
    throw new Error(`Local collaboration ledger receipt '${filePath}' is missing required fields.`);
  }
  return receipt;
}

export async function loadLocalCollaborationLedgerReceipts({ repoRoot, ledgerRoot = DEFAULT_LOCAL_COLLAB_LEDGER_ROOT } = {}) {
  const resolvedRepoRoot = path.resolve(normalizeText(repoRoot) || process.cwd());
  const resolvedLedgerRoot = path.resolve(resolvedRepoRoot, normalizeText(ledgerRoot) || DEFAULT_LOCAL_COLLAB_LEDGER_ROOT);
  const receiptsRoot = path.join(resolvedLedgerRoot, 'receipts');

  if (!existsSync(receiptsRoot)) {
    return {
      repoRoot: resolvedRepoRoot,
      ledgerRoot: resolvedLedgerRoot,
      receipts: []
    };
  }

  const phaseEntries = await readdir(receiptsRoot, { withFileTypes: true });
  const receipts = [];

  for (const phaseEntry of phaseEntries) {
    if (!phaseEntry.isDirectory()) {
      continue;
    }
    const phaseRoot = path.join(receiptsRoot, phaseEntry.name);
    const fileEntries = await readdir(phaseRoot, { withFileTypes: true });
    for (const fileEntry of fileEntries) {
      if (!fileEntry.isFile() || path.extname(fileEntry.name) !== '.json') {
        continue;
      }
      const filePath = path.join(phaseRoot, fileEntry.name);
      const receipt = await readLedgerReceiptFile(filePath);
      receipts.push(receipt);
    }
  }

  receipts.sort((left, right) => {
    const leftTime = left.finishedAt || left.startedAt || '';
    const rightTime = right.finishedAt || right.startedAt || '';
    if (leftTime !== rightTime) {
      return leftTime.localeCompare(rightTime);
    }
    if (left.headSha !== right.headSha) {
      return left.headSha.localeCompare(right.headSha);
    }
    return left.phase.localeCompare(right.phase);
  });

  return {
    repoRoot: resolvedRepoRoot,
    ledgerRoot: resolvedLedgerRoot,
    receipts
  };
}

export async function rollupLocalCollaborationKpi({
  repoRoot = process.cwd(),
  ledgerRoot = DEFAULT_LOCAL_COLLAB_LEDGER_ROOT,
  outputPath = DEFAULT_LOCAL_COLLAB_KPI_SUMMARY_PATH
} = {}) {
  const resolvedRepoRoot = path.resolve(normalizeText(repoRoot) || process.cwd());
  const resolvedOutputPath = path.resolve(resolvedRepoRoot, normalizeText(outputPath) || DEFAULT_LOCAL_COLLAB_KPI_SUMMARY_PATH);
  const { receipts, ledgerRoot: resolvedLedgerRoot } = await loadLocalCollaborationLedgerReceipts({
    repoRoot: resolvedRepoRoot,
    ledgerRoot
  });
  const copilotPolicy = await loadCopilotCliReviewPolicy(resolvedRepoRoot);
  const providerAssignments = buildProviderAssignments(copilotPolicy.collaboration);
  const planes = new Map(SUPPORTED_LOCAL_COLLAB_PLANES.map((plane) => [plane, createPlaneAccumulator(plane)]));
  const combinedPlane = createPlaneAccumulator('local');
  const providerAccumulators = new Map(
    SUPPORTED_LOCAL_REVIEW_PROVIDERS.map((providerId) => [
      providerId,
      createProviderAccumulator(providerId, providerAssignments[providerId] ?? { plane: 'origin', persona: providerId, effortType: 'review' })
    ])
  );
  const phaseCounts = new Map();
  const actorCounts = new Map();
  const selectionSources = new Map();
  const headShas = new Set();

  for (const receipt of receipts) {
    headShas.add(receipt.headSha);
    bumpCount(phaseCounts, receipt.phase);
    bumpCount(actorCounts, `${receipt.forkPlane}:${receipt.persona}`);
    addOptionalCount(selectionSources, receipt.selectionSource);

    const planeAccumulator = planes.get(receipt.forkPlane);
    if (planeAccumulator) {
      addMetricsEvent(planeAccumulator.receiptEffort, receipt);
      addMetricsEvent(getPersonaAccumulator(planeAccumulator, receipt.persona).receiptEffort, receipt);
    }
    addMetricsEvent(combinedPlane.receiptEffort, receipt);
    addMetricsEvent(getPersonaAccumulator(combinedPlane, receipt.persona).receiptEffort, receipt);

    const uniqueProviders = [...new Set(receipt.providers)];
    if (uniqueProviders.length === 0) {
      continue;
    }

    const durationAllocations = allocateEvenly(receipt.durationMs, uniqueProviders.length);
    const findingAllocations = allocateEvenly(receipt.findingCount, uniqueProviders.length);

    uniqueProviders.forEach((providerId, index) => {
      const assignment = providerAssignments[providerId] ?? { plane: 'origin', persona: providerId, effortType: 'review' };
      const providerEvent = {
        ...receipt,
        forkPlane: assignment.plane,
        persona: assignment.persona,
        providerId,
        durationMs: durationAllocations[index] ?? 0,
        findingCount: findingAllocations[index] ?? 0,
        requestedModel:
          shouldRecordModelForProvider(uniqueProviders, providerId, receipt.providerId) ? receipt.requestedModel : null,
        effectiveModel:
          shouldRecordModelForProvider(uniqueProviders, providerId, receipt.providerId) ? receipt.effectiveModel : null
      };

      const providerAccumulator = providerAccumulators.get(providerId);
      addMetricsEvent(providerAccumulator.totals, providerEvent);

      const providerPlaneAccumulator = planes.get(assignment.plane);
      if (providerPlaneAccumulator) {
        addMetricsEvent(providerPlaneAccumulator.providerEffort, providerEvent);
        addMetricsEvent(getPersonaAccumulator(providerPlaneAccumulator, assignment.persona).providerEffort, providerEvent);
      }

      addMetricsEvent(combinedPlane.providerEffort, providerEvent);
      addMetricsEvent(getPersonaAccumulator(combinedPlane, assignment.persona).providerEffort, providerEvent);
    });
  }

  const summary = {
    schema: LOCAL_COLLAB_KPI_SCHEMA,
    generatedAt: new Date().toISOString(),
    repoRoot: resolvedRepoRoot,
    ledgerRoot: path.relative(resolvedRepoRoot, resolvedLedgerRoot).replace(/\\/g, '/'),
    summaryPath: path.relative(resolvedRepoRoot, resolvedOutputPath).replace(/\\/g, '/'),
    allocationPolicy: {
      providerDurationMs: 'even-split-per-phase-provider',
      providerFindingCount: 'even-split-per-phase-provider',
      providerModels: 'single-provider-receipts-only'
    },
    receiptInventory: {
      receiptCount: receipts.length,
      uniqueHeadCount: headShas.size,
      phases: toSerializableCounts(phaseCounts),
      actors: toSerializableCounts(actorCounts),
      selectionSources: toSerializableCounts(selectionSources)
    },
    combinedLocalPlane: finalizePlaneAccumulator(combinedPlane),
    planes: Object.fromEntries(
      [...planes.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([plane, accumulator]) => [plane, finalizePlaneAccumulator(accumulator)])
    ),
    providers: Object.fromEntries(
      [...providerAccumulators.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([providerId, accumulator]) => [
          providerId,
          {
            providerId,
            executable: accumulator.executable,
            reserved: accumulator.reserved,
            plane: accumulator.plane,
            persona: accumulator.persona,
            effortType: accumulator.effortType,
            placeholderOnly: accumulator.totals.receiptCount === 0,
            totals: finalizeMetrics(accumulator.totals)
          }
        ])
    )
  };

  await mkdir(path.dirname(resolvedOutputPath), { recursive: true });
  await writeFile(resolvedOutputPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');

  return {
    summary,
    summaryPath: resolvedOutputPath
  };
}

export function parseArgs(argv = process.argv) {
  const args = Array.isArray(argv) ? argv.slice(2) : [];
  const options = {
    help: false,
    repoRoot: process.cwd(),
    ledgerRoot: DEFAULT_LOCAL_COLLAB_LEDGER_ROOT,
    outputPath: DEFAULT_LOCAL_COLLAB_KPI_SUMMARY_PATH
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    switch (token) {
      case '-h':
      case '--help':
        options.help = true;
        break;
      case '--repo-root':
        options.repoRoot = args[index + 1];
        index += 1;
        break;
      case '--ledger-root':
        options.ledgerRoot = args[index + 1];
        index += 1;
        break;
      case '--output':
        options.outputPath = args[index + 1];
        index += 1;
        break;
      default:
        throw new Error(`Unknown option: ${token}`);
    }
  }

  return options;
}

function printUsage() {
  console.log('Usage: node tools/local-collab/kpi/rollup-local-collab-kpi.mjs [options]');
  console.log('');
  console.log('Roll up local collaboration ledger receipts into per-plane KPI summaries.');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>     Repository root (default: current working directory).');
  console.log(`  --ledger-root <path>   Ledger root (default: ${DEFAULT_LOCAL_COLLAB_LEDGER_ROOT}).`);
  console.log(`  --output <path>        Output JSON path (default: ${DEFAULT_LOCAL_COLLAB_KPI_SUMMARY_PATH}).`);
  console.log('  -h, --help             Show help.');
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(error.message);
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  try {
    const result = await rollupLocalCollaborationKpi(options);
    console.log(JSON.stringify({
      schema: LOCAL_COLLAB_KPI_SCHEMA,
      summaryPath: path.relative(path.resolve(options.repoRoot), result.summaryPath).replace(/\\/g, '/'),
      receiptCount: result.summary.receiptInventory.receiptCount,
      uniqueHeadCount: result.summary.receiptInventory.uniqueHeadCount
    }, null, 2));
    return 0;
  } catch (error) {
    console.error(error?.stack || error?.message || String(error));
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

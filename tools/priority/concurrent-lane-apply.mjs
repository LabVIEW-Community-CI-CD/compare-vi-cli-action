#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  CONCURRENT_LANE_PLAN_SCHEMA,
  DEFAULT_HOST_PLANE_REPORT_PATH,
  DEFAULT_HOST_RAM_BUDGET_PATH,
  buildConcurrentLanePlan
} from './concurrent-lane-plan.mjs';
import { dispatchValidate, writeValidateDispatchReport } from './dispatch-validate.mjs';

export const CONCURRENT_LANE_APPLY_RECEIPT_SCHEMA = 'priority/concurrent-lane-apply-receipt@v1';
export const DEFAULT_PLAN_PATH = path.join('tests', 'results', '_agent', 'runtime', 'concurrent-lane-plan.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'concurrent-lane-apply-receipt.json');

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toOptionalText(value) {
  const normalized = normalizeText(value);
  return normalized || null;
}

function normalizeShadowMode(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (['auto', 'disabled', 'prefer'].includes(normalized)) {
    return normalized;
  }
  return 'auto';
}

function normalizeAvailability(value, fallback = 'available') {
  const normalized = normalizeText(value).toLowerCase();
  if (['available', 'disabled', 'unavailable'].includes(normalized)) {
    return normalized;
  }
  return fallback;
}

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

async function readJsonRequired(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    planPath: DEFAULT_PLAN_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    hostPlaneReportPath: DEFAULT_HOST_PLANE_REPORT_PATH,
    hostRamBudgetPath: DEFAULT_HOST_RAM_BUDGET_PATH,
    dockerRuntimeSnapshotPath: '',
    hostedLinux: 'available',
    hostedWindows: 'available',
    shadowMode: 'auto',
    ref: null,
    sampleId: null,
    historyScenarioSet: 'smoke',
    allowFork: false,
    pushMissing: false,
    forcePushOk: false,
    allowNonCanonicalViHistory: false,
    allowNonCanonicalHistoryCore: false,
    dryRun: false,
    recomputePlan: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (
      token === '--dry-run' ||
      token === '--allow-fork' ||
      token === '--push-missing' ||
      token === '--force-push-ok' ||
      token === '--allow-noncanonical-vi-history' ||
      token === '--allow-noncanonical-history-core' ||
      token === '--recompute-plan'
    ) {
      if (token === '--dry-run') options.dryRun = true;
      if (token === '--allow-fork') options.allowFork = true;
      if (token === '--push-missing') options.pushMissing = true;
      if (token === '--force-push-ok') options.forcePushOk = true;
      if (token === '--allow-noncanonical-vi-history') options.allowNonCanonicalViHistory = true;
      if (token === '--allow-noncanonical-history-core') options.allowNonCanonicalHistoryCore = true;
      if (token === '--recompute-plan') options.recomputePlan = true;
      continue;
    }
    if (
      token === '--plan' ||
      token === '--output' ||
      token === '--host-plane-report' ||
      token === '--host-ram-budget' ||
      token === '--docker-runtime-snapshot' ||
      token === '--hosted-linux' ||
      token === '--hosted-windows' ||
      token === '--shadow-mode' ||
      token === '--ref' ||
      token === '--sample-id' ||
      token === '--history-scenario-set'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--plan') options.planPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--host-plane-report') options.hostPlaneReportPath = next;
      if (token === '--host-ram-budget') options.hostRamBudgetPath = next;
      if (token === '--docker-runtime-snapshot') options.dockerRuntimeSnapshotPath = next;
      if (token === '--hosted-linux') options.hostedLinux = normalizeAvailability(next);
      if (token === '--hosted-windows') options.hostedWindows = normalizeAvailability(next);
      if (token === '--shadow-mode') options.shadowMode = normalizeShadowMode(next);
      if (token === '--ref') options.ref = next;
      if (token === '--sample-id') options.sampleId = next;
      if (token === '--history-scenario-set') options.historyScenarioSet = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function buildValidateDispatchArgv(options) {
  const argv = ['node', 'dispatch-validate.mjs'];
  if (options.ref) {
    argv.push('--ref', options.ref);
  }
  if (toOptionalText(options.sampleId)) {
    argv.push('--sample-id', normalizeText(options.sampleId));
  }
  argv.push('--history-scenario-set', normalizeText(options.historyScenarioSet) || 'smoke');
  if (options.allowFork) argv.push('--allow-fork');
  if (options.pushMissing) argv.push('--push-missing');
  if (options.forcePushOk) argv.push('--force-push-ok');
  if (options.allowNonCanonicalViHistory) argv.push('--allow-noncanonical-vi-history');
  if (options.allowNonCanonicalHistoryCore) argv.push('--allow-noncanonical-history-core');
  return argv;
}

function buildValidateHelperCommand(options) {
  const command = ['node', 'tools/npm/run-script.mjs', 'priority:validate', '--'];
  if (options.ref) {
    command.push('--ref', options.ref);
  }
  if (toOptionalText(options.sampleId)) {
    command.push('--sample-id', normalizeText(options.sampleId));
  }
  command.push('--history-scenario-set', normalizeText(options.historyScenarioSet) || 'smoke');
  if (options.allowFork) command.push('--allow-fork');
  if (options.pushMissing) command.push('--push-missing');
  if (options.forcePushOk) command.push('--force-push-ok');
  if (options.allowNonCanonicalViHistory) command.push('--allow-noncanonical-vi-history');
  if (options.allowNonCanonicalHistoryCore) command.push('--allow-noncanonical-history-core');
  return command;
}

function cloneLaneForReceipt(lane, decision) {
  return {
    id: lane.id,
    laneClass: lane.laneClass,
    executionPlane: lane.executionPlane,
    resourceGroup: lane.resourceGroup,
    availability: lane.availability,
    decision,
    reasons: Array.isArray(lane.reasons) ? [...lane.reasons] : [],
    metadata: lane.metadata && typeof lane.metadata === 'object' ? { ...lane.metadata } : {}
  };
}

function summarizeSelectedLanes(selectedLanes) {
  const hostedLanes = selectedLanes.filter((entry) => entry.executionPlane === 'hosted');
  const deferredLanes = selectedLanes.filter((entry) => entry.decision === 'deferred');
  return {
    hostedLaneIds: hostedLanes.map((entry) => entry.id),
    deferredLaneIds: deferredLanes.map((entry) => entry.id),
    manualLaneIds: deferredLanes.filter((entry) => entry.executionPlane === 'local').map((entry) => entry.id),
    shadowLaneIds: deferredLanes.filter((entry) => entry.executionPlane === 'local-shadow').map((entry) => entry.id)
  };
}

export function buildConcurrentLaneApplyReceipt({
  repository,
  plan,
  planPath = null,
  planSource = 'file',
  selectedBundle,
  selectedLanes,
  validateDispatch,
  now = new Date(),
  status = 'succeeded'
}) {
  const laneSummary = summarizeSelectedLanes(selectedLanes);
  return {
    schema: CONCURRENT_LANE_APPLY_RECEIPT_SCHEMA,
    generatedAt: now.toISOString(),
    repository: toOptionalText(repository) ?? toOptionalText(plan?.repository) ?? null,
    status,
    plan: {
      source: planSource,
      path: toOptionalText(planPath),
      schema: toOptionalText(plan?.schema),
      recommendedBundleId: toOptionalText(plan?.summary?.recommendedBundleId) ?? toOptionalText(plan?.recommendedBundle?.id),
      selectedBundle: selectedBundle
        ? {
            id: selectedBundle.id,
            classification: selectedBundle.classification,
            laneIds: Array.isArray(selectedBundle.laneIds) ? [...selectedBundle.laneIds] : [],
            reasons: Array.isArray(selectedBundle.reasons) ? [...selectedBundle.reasons] : []
          }
        : null
    },
    validateDispatch,
    selectedLanes,
    observations: Array.isArray(plan?.observations) ? [...plan.observations] : [],
    summary: {
      selectedBundleId: selectedBundle?.id ?? null,
      selectedLaneCount: selectedLanes.length,
      hostedDispatchCount: validateDispatch.status === 'dispatched' ? laneSummary.hostedLaneIds.length : 0,
      deferredLaneCount: laneSummary.deferredLaneIds.length,
      hostedLaneIds: laneSummary.hostedLaneIds,
      deferredLaneIds: laneSummary.deferredLaneIds,
      manualLaneIds: laneSummary.manualLaneIds,
      shadowLaneIds: laneSummary.shadowLaneIds
    }
  };
}

async function writeReceipt(outputPath, receipt) {
  const resolved = path.resolve(process.cwd(), outputPath);
  await fs.mkdir(path.dirname(resolved), { recursive: true });
  await fs.writeFile(resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
  return resolved;
}

async function loadOrBuildPlan(options) {
  const buildPlanFromCurrentInputs = async () => {
    const hostPlaneReport = await readJsonIfPresent(path.resolve(process.cwd(), options.hostPlaneReportPath));
    const hostRamBudget = await readJsonIfPresent(path.resolve(process.cwd(), options.hostRamBudgetPath));
    const dockerRuntimeSnapshot = options.dockerRuntimeSnapshotPath
      ? await readJsonIfPresent(path.resolve(process.cwd(), options.dockerRuntimeSnapshotPath))
      : null;
    return {
      payload: buildConcurrentLanePlan({
        hostPlaneReport,
        hostRamBudget,
        dockerRuntimeSnapshot,
        hostedLinux: options.hostedLinux,
        hostedWindows: options.hostedWindows,
        shadowMode: options.shadowMode
      }),
      planPath: null,
      planSource: 'recomputed'
    };
  };

  if (!options.recomputePlan) {
    const resolvedPlanPath = path.resolve(process.cwd(), options.planPath);
    let payload;
    try {
      payload = await readJsonRequired(resolvedPlanPath);
    } catch (error) {
      if (error?.code === 'ENOENT' && options.planPath === DEFAULT_PLAN_PATH) {
        return buildPlanFromCurrentInputs();
      }
      throw error;
    }
    if (payload?.schema !== CONCURRENT_LANE_PLAN_SCHEMA) {
      throw new Error(
        `Concurrent lane plan at '${resolvedPlanPath}' has schema '${payload?.schema ?? 'unknown'}'; expected '${CONCURRENT_LANE_PLAN_SCHEMA}'.`
      );
    }
    return {
      payload,
      planPath: resolvedPlanPath,
      planSource: 'file'
    };
  }

  return buildPlanFromCurrentInputs();
}

export async function applyConcurrentLanePlan(
  options,
  {
    dispatchValidateFn = dispatchValidate,
    writeValidateDispatchReportFn = writeValidateDispatchReport
  } = {}
) {
  const { payload: plan, planPath, planSource } = await loadOrBuildPlan(options);
  const selectedBundle = plan?.recommendedBundle ?? null;
  const hostedHelperCommand = buildValidateHelperCommand(options);
  const validateDispatch = {
    status: 'not-required',
    command: hostedHelperCommand,
    repository: null,
    remote: null,
    ref: toOptionalText(options.ref),
    sampleIdStrategy: normalizeText(options.sampleIdStrategy) || (toOptionalText(options.sampleId) ? 'explicit' : 'auto'),
    sampleId: toOptionalText(options.sampleId),
    historyScenarioSet: normalizeText(options.historyScenarioSet) || 'smoke',
    allowFork: options.allowFork === true,
    pushMissing: options.pushMissing === true,
    forcePushOk: options.forcePushOk === true,
    allowNonCanonicalViHistory: options.allowNonCanonicalViHistory === true,
    allowNonCanonicalHistoryCore: options.allowNonCanonicalHistoryCore === true,
    reportPath: null,
    runDatabaseId: null,
    error: null
  };

  if (!selectedBundle) {
    const receipt = buildConcurrentLaneApplyReceipt({
      repository: plan?.repository,
      plan,
      planPath,
      planSource,
      selectedBundle: null,
      selectedLanes: [],
      validateDispatch,
      status: 'noop'
    });
    const outputPath = await writeReceipt(options.outputPath, receipt);
    return { receipt, outputPath, error: null };
  }

  const laneMap = new Map((Array.isArray(plan?.lanes) ? plan.lanes : []).map((entry) => [entry.id, entry]));
  const selectedRawLanes = selectedBundle.laneIds.map((laneId) => {
    const lane = laneMap.get(laneId);
    if (!lane) {
      throw new Error(`Concurrent lane plan bundle '${selectedBundle.id}' references unknown lane '${laneId}'.`);
    }
    return lane;
  });
  const hostedSelectedLanes = selectedRawLanes.filter((entry) => entry.executionPlane === 'hosted');

  let resultError = null;
  if (hostedSelectedLanes.length > 0) {
    if (options.dryRun) {
      validateDispatch.status = 'dry-run';
    } else {
      try {
        const dispatchResult = dispatchValidateFn({
          argv: buildValidateDispatchArgv(options),
          env: process.env
        });
        const reportResult = writeValidateDispatchReportFn(dispatchResult);
        validateDispatch.status = 'dispatched';
        validateDispatch.repository = dispatchResult.repo ?? null;
        validateDispatch.remote = dispatchResult.remote ?? null;
        validateDispatch.ref = dispatchResult.ref ?? validateDispatch.ref;
        validateDispatch.sampleId = dispatchResult.sampleId ?? validateDispatch.sampleId;
        validateDispatch.historyScenarioSet = dispatchResult.historyScenarioSet ?? validateDispatch.historyScenarioSet;
        validateDispatch.reportPath = reportResult?.reportPath ?? null;
        validateDispatch.runDatabaseId = dispatchResult.run?.databaseId ?? null;
      } catch (error) {
        resultError = error;
        validateDispatch.status = 'failed';
        validateDispatch.error = error?.message || String(error);
      }
    }
  }

  const selectedLanes = selectedRawLanes.map((lane) => {
    if (lane.executionPlane === 'hosted') {
      if (validateDispatch.status === 'dispatched') {
        return cloneLaneForReceipt(lane, 'dispatched');
      }
      if (validateDispatch.status === 'dry-run') {
        return cloneLaneForReceipt(lane, 'planned-dispatch');
      }
      return cloneLaneForReceipt(lane, 'blocked');
    }
    return cloneLaneForReceipt(lane, 'deferred');
  });

  const receipt = buildConcurrentLaneApplyReceipt({
    repository: plan?.repository,
    plan,
    planPath,
    planSource,
    selectedBundle,
    selectedLanes,
    validateDispatch,
    status: resultError ? 'failed' : 'succeeded'
  });
  const outputPath = await writeReceipt(options.outputPath, receipt);
  return { receipt, outputPath, error: resultError };
}

function printUsage() {
  console.log('Usage: node tools/priority/concurrent-lane-apply.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --plan <path>                    Existing concurrent lane plan path (default: ${DEFAULT_PLAN_PATH})`);
  console.log(`  --output <path>                  Receipt path (default: ${DEFAULT_OUTPUT_PATH})`);
  console.log(`  --host-plane-report <path>       Host plane report for --recompute-plan (default: ${DEFAULT_HOST_PLANE_REPORT_PATH})`);
  console.log(`  --host-ram-budget <path>         Host RAM budget for --recompute-plan (default: ${DEFAULT_HOST_RAM_BUDGET_PATH})`);
  console.log('  --docker-runtime-snapshot <path> Optional docker-runtime snapshot for --recompute-plan.');
  console.log('  --hosted-linux <state>           available|disabled|unavailable for --recompute-plan.');
  console.log('  --hosted-windows <state>         available|disabled|unavailable for --recompute-plan.');
  console.log('  --shadow-mode <mode>             auto|disabled|prefer for --recompute-plan.');
  console.log('  --ref <branch>                   Validate dispatch ref (defaults to current branch).');
  console.log('  --sample-id <id>                 Validate workflow sample_id override.');
  console.log('  --history-scenario-set <set>     none|smoke|history-core (default: smoke).');
  console.log('  --allow-fork                     Forward allow-fork to priority:validate.');
  console.log('  --push-missing                   Forward push-missing to priority:validate.');
  console.log('  --force-push-ok                  Forward force-push-ok to priority:validate.');
  console.log('  --allow-noncanonical-vi-history  Forward non-canonical VI history override.');
  console.log('  --allow-noncanonical-history-core Forward non-canonical history-core override.');
  console.log('  --dry-run                        Do not dispatch hosted lanes; record planned launch only.');
  console.log('  --recompute-plan                 Recompute the concurrent lane plan instead of reading --plan.');
  console.log('  -h, --help                       Show help.');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const { receipt, outputPath, error } = await applyConcurrentLanePlan(options);
  console.log(
    `[concurrent-lane-apply] receipt=${outputPath} bundle=${receipt.summary.selectedBundleId ?? 'none'} status=${receipt.status}`
  );
  if (receipt.summary.deferredLaneIds.length > 0) {
    console.log(`[concurrent-lane-apply] deferred=${receipt.summary.deferredLaneIds.join(',')}`);
  }
  if (error) {
    console.error(`[concurrent-lane-apply] ${error.message || String(error)}`);
    return 1;
  }
  return 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).then(
    (exitCode) => process.exit(exitCode),
    (error) => {
      process.stderr.write(`${error?.message || String(error)}\n`);
      process.exit(1);
    }
  );
}

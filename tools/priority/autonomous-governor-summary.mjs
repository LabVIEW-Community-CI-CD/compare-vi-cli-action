#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'autonomous-governor-summary.json'
);
export const DEFAULT_QUEUE_EMPTY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'no-standing-priority.json'
);
export const DEFAULT_CONTINUITY_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'continuity-summary.json'
);
export const DEFAULT_MONITORING_MODE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'monitoring-mode.json'
);
export const DEFAULT_WAKE_LIFECYCLE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'wake-lifecycle.json'
);
export const DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'capital',
  'wake-investment-accounting.json'
);
export const DEFAULT_DELIVERY_RUNTIME_STATE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'delivery-agent-state.json'
);

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
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

function toRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
}

function ensureSchema(payload, filePath, schema) {
  if (payload?.schema !== schema) {
    throw new Error(`Expected ${schema} at ${filePath}.`);
  }
  return payload;
}

function parseBoolean(value) {
  return value === true;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    queueEmptyReportPath: DEFAULT_QUEUE_EMPTY_REPORT_PATH,
    continuitySummaryPath: DEFAULT_CONTINUITY_SUMMARY_PATH,
    monitoringModePath: DEFAULT_MONITORING_MODE_PATH,
    wakeLifecyclePath: DEFAULT_WAKE_LIFECYCLE_PATH,
    wakeInvestmentAccountingPath: DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH,
    deliveryRuntimeStatePath: DEFAULT_DELIVERY_RUNTIME_STATE_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--queue-empty-report', 'queueEmptyReportPath'],
    ['--continuity-summary', 'continuitySummaryPath'],
    ['--monitoring-mode', 'monitoringModePath'],
    ['--wake-lifecycle', 'wakeLifecyclePath'],
    ['--wake-investment-accounting', 'wakeInvestmentAccountingPath'],
    ['--delivery-runtime-state', 'deliveryRuntimeStatePath'],
    ['--output', 'outputPath']
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (stringFlags.has(token)) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      options[stringFlags.get(token)] = next;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  [
    'Usage: node tools/priority/autonomous-governor-summary.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>                 Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --queue-empty-report <path>       Queue-empty report path (default: ${DEFAULT_QUEUE_EMPTY_REPORT_PATH}).`,
    `  --continuity-summary <path>       Continuity summary path (default: ${DEFAULT_CONTINUITY_SUMMARY_PATH}).`,
    `  --monitoring-mode <path>          Monitoring mode path (default: ${DEFAULT_MONITORING_MODE_PATH}).`,
    `  --wake-lifecycle <path>           Wake lifecycle path (default: ${DEFAULT_WAKE_LIFECYCLE_PATH}).`,
    `  --wake-investment-accounting <path> Wake investment accounting path (default: ${DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH}).`,
    `  --delivery-runtime-state <path>   Delivery runtime state path (default: ${DEFAULT_DELIVERY_RUNTIME_STATE_PATH}).`,
    `  --output <path>                   Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  -h, --help                        Show help.'
  ].forEach((line) => console.log(line));
}

function deriveQueueState(queueEmptyReport, monitoringMode) {
  if (queueEmptyReport?.schema === 'standing-priority/no-standing@v1') {
    return {
      status: asOptional(queueEmptyReport.reason) || 'queue-empty',
      reason: asOptional(queueEmptyReport.reason),
      openIssueCount: Number.isInteger(queueEmptyReport.openIssueCount) ? queueEmptyReport.openIssueCount : null,
      ready: queueEmptyReport.reason === 'queue-empty'
    };
  }
  return {
    status: asOptional(monitoringMode?.compare?.queueState?.status) || 'unknown',
    reason: asOptional(monitoringMode?.compare?.queueState?.detail),
    openIssueCount: null,
    ready: parseBoolean(monitoringMode?.compare?.queueState?.ready)
  };
}

function deriveContinuity(continuitySummary, monitoringMode) {
  return {
    status: asOptional(continuitySummary?.status) || asOptional(monitoringMode?.compare?.continuity?.status),
    turnBoundary: asOptional(continuitySummary?.continuity?.turnBoundary?.status),
    supervisionState: asOptional(continuitySummary?.continuity?.turnBoundary?.supervisionState),
    operatorPromptRequiredToResume: continuitySummary?.continuity?.turnBoundary?.operatorPromptRequiredToResume === true
  };
}

function deriveWake(wakeLifecycle) {
  if (wakeLifecycle?.schema !== 'priority/wake-lifecycle-report@v1') {
    return {
      terminalState: null,
      currentStage: null,
      classification: null,
      decision: null,
      monitoringStatus: null,
      authoritativeTier: null,
      blockedLowerTierEvidence: false,
      replayMatched: false,
      replayAuthorityCompatible: null,
      issueNumber: null,
      issueUrl: null,
      recommendedOwnerRepository: null
    };
  }
  return {
    terminalState: asOptional(wakeLifecycle?.summary?.terminalState),
    currentStage: asOptional(wakeLifecycle?.summary?.currentStage),
    classification: asOptional(wakeLifecycle?.summary?.wakeClassification),
    decision: asOptional(wakeLifecycle?.summary?.decision),
    monitoringStatus: asOptional(wakeLifecycle?.summary?.monitoringStatus),
    authoritativeTier: asOptional(wakeLifecycle?.summary?.authoritativeTier),
    blockedLowerTierEvidence: wakeLifecycle?.summary?.blockedLowerTierEvidence === true,
    replayMatched: wakeLifecycle?.summary?.replayMatched === true,
    replayAuthorityCompatible:
      typeof wakeLifecycle?.summary?.replayAuthorityCompatible === 'boolean'
        ? wakeLifecycle.summary.replayAuthorityCompatible
        : null,
    issueNumber: Number.isInteger(wakeLifecycle?.summary?.issueNumber) ? wakeLifecycle.summary.issueNumber : null,
    issueUrl: asOptional(wakeLifecycle?.summary?.issueUrl),
    recommendedOwnerRepository: asOptional(wakeLifecycle?.wake?.recommendedOwnerRepository)
  };
}

function deriveFunding(wakeInvestmentAccounting) {
  return {
    accountingBucket: asOptional(wakeInvestmentAccounting?.summary?.accountingBucket),
    status: asOptional(wakeInvestmentAccounting?.summary?.status),
    paybackStatus: asOptional(wakeInvestmentAccounting?.summary?.paybackStatus),
    recommendation: asOptional(wakeInvestmentAccounting?.summary?.recommendation),
    invoiceTurnId: asOptional(wakeInvestmentAccounting?.billingWindow?.invoiceTurnId),
    fundingPurpose: asOptional(wakeInvestmentAccounting?.billingWindow?.fundingPurpose),
    activationState: asOptional(wakeInvestmentAccounting?.billingWindow?.activationState),
    benchmarkIssueUsd:
      typeof wakeInvestmentAccounting?.summary?.metrics?.benchmarkIssueUsd === 'number'
        ? wakeInvestmentAccounting.summary.metrics.benchmarkIssueUsd
        : null,
    observedWakeIssueUsd:
      typeof wakeInvestmentAccounting?.summary?.metrics?.observedWakeIssueUsd === 'number'
        ? wakeInvestmentAccounting.summary.metrics.observedWakeIssueUsd
        : null,
    netPaybackUsd:
      typeof wakeInvestmentAccounting?.summary?.metrics?.netPaybackUsd === 'number'
        ? wakeInvestmentAccounting.summary.metrics.netPaybackUsd
        : null
  };
}

function deriveDeliveryRuntime(deliveryRuntimeState) {
  const activeLane = deliveryRuntimeState?.activeLane || {};
  const prUrl = asOptional(activeLane?.prUrl);
  const laneLifecycle = asOptional(activeLane?.laneLifecycle) || asOptional(deliveryRuntimeState?.laneLifecycle);
  const blockerClass = asOptional(activeLane?.blockerClass);
  const outcome = asOptional(activeLane?.outcome);

  let status = 'none';
  if (prUrl) {
    if (laneLifecycle === 'waiting-ci') {
      status = 'checks-pending';
    } else if (laneLifecycle === 'ready-merge') {
      status = 'merge-queue-progress';
    } else if (blockerClass === 'merge' || outcome === 'merge-blocked') {
      status = 'merge-blocked';
    } else {
      status = 'pr-active';
    }
  }

  return {
    status,
    runtimeStatus: asOptional(deliveryRuntimeState?.status),
    laneLifecycle,
    actionType: asOptional(activeLane?.actionType),
    outcome,
    blockerClass,
    nextWakeCondition: asOptional(activeLane?.nextWakeCondition),
    prUrl,
    issueNumber: Number.isInteger(activeLane?.issue) ? activeLane.issue : null,
    reason: asOptional(activeLane?.reason)
  };
}

function deriveGovernorMode({ queueState, continuity, monitoringMode, wake }) {
  switch (wake.terminalState) {
    case 'compare-work':
      return 'compare-governance-work';
    case 'template-work':
      return 'template-work';
    case 'external-route':
      return 'external-route';
    case 'suppressed':
      return 'suppressed';
    case 'monitoring':
      return 'monitoring';
    case 'retired':
      return 'retired';
    default:
      break;
  }

  if (
    queueState.status === 'queue-empty' &&
    continuity.status === 'maintained' &&
    continuity.turnBoundary === 'safe-idle' &&
    asOptional(monitoringMode?.summary?.status) === 'active'
  ) {
    return 'monitoring-active';
  }

  return 'attention-required';
}

function deriveSignalQuality({ governorMode, wake }) {
  if ((wake.terminalState === 'suppressed' || wake.terminalState === 'monitoring') && wake.blockedLowerTierEvidence) {
    return 'noise-contained';
  }
  if (wake.terminalState === 'compare-work' && wake.blockedLowerTierEvidence) {
    return 'validated-governance-work';
  }
  if (wake.terminalState === 'compare-work') {
    return 'actionable-governance-work';
  }
  if (wake.terminalState === 'template-work') {
    return 'validated-template-work';
  }
  if (wake.terminalState === 'external-route') {
    return 'routed-external-signal';
  }
  if (governorMode === 'monitoring-active') {
    return 'idle-monitoring';
  }
  return 'unknown';
}

function deriveOwners({ governorMode, monitoringMode, wake, repository }) {
  const compareRepository =
    asOptional(monitoringMode?.policy?.compareRepository) ||
    asOptional(monitoringMode?.repository) ||
    asOptional(repository);
  const pivotTargetRepository = asOptional(monitoringMode?.policy?.pivotTargetRepository);

  switch (governorMode) {
    case 'compare-governance-work':
      return {
        currentOwnerRepository: wake.recommendedOwnerRepository || compareRepository,
        nextOwnerRepository: wake.recommendedOwnerRepository || compareRepository
      };
    case 'template-work':
      return {
        currentOwnerRepository: wake.recommendedOwnerRepository || pivotTargetRepository,
        nextOwnerRepository: wake.recommendedOwnerRepository || pivotTargetRepository
      };
    case 'monitoring-active':
      return {
        currentOwnerRepository: compareRepository,
        nextOwnerRepository:
          asOptional(monitoringMode?.summary?.futureAgentAction) === 'future-agent-may-pivot'
            ? pivotTargetRepository
            : compareRepository
      };
    case 'external-route':
      return {
        currentOwnerRepository: compareRepository,
        nextOwnerRepository: wake.recommendedOwnerRepository || compareRepository
      };
    default:
      return {
        currentOwnerRepository: compareRepository,
        nextOwnerRepository: compareRepository
      };
  }
}

function deriveNextAction({ governorMode, monitoringMode, wake }) {
  switch (governorMode) {
    case 'compare-governance-work':
      return wake.issueNumber ? 'continue-standing-work' : 'continue-compare-governance-work';
    case 'template-work':
      return 'route-to-template-work';
    case 'external-route':
      return 'follow-external-route';
    case 'suppressed':
      return 'stay-suppressed';
    case 'monitoring':
      return 'remain-in-monitoring';
    case 'retired':
      return 'no-further-action';
    case 'monitoring-active':
      return asOptional(monitoringMode?.summary?.futureAgentAction) || 'remain-in-monitoring';
    default:
      return 'refresh-governor-inputs';
  }
}

function buildReport({
  repoRoot,
  queueEmptyReportPath,
  queueEmptyReport,
  continuitySummaryPath,
  continuitySummary,
  monitoringModePath,
  monitoringMode,
  wakeLifecyclePath,
  wakeLifecycle,
  wakeInvestmentAccountingPath,
  wakeInvestmentAccounting,
  deliveryRuntimeStatePath,
  deliveryRuntimeState,
  now
}) {
  const repository =
    asOptional(monitoringMode?.repository) ||
    asOptional(wakeLifecycle?.repository) ||
    asOptional(wakeInvestmentAccounting?.repository) ||
    null;

  const queueState = deriveQueueState(queueEmptyReport, monitoringMode);
  const continuity = deriveContinuity(continuitySummary, monitoringMode);
  const wake = deriveWake(wakeLifecycle);
  const funding = deriveFunding(wakeInvestmentAccounting);
  const deliveryRuntime = deriveDeliveryRuntime(deliveryRuntimeState);
  const governorMode = deriveGovernorMode({ queueState, continuity, monitoringMode, wake });
  const signalQuality = deriveSignalQuality({ governorMode, wake });
  const owners = deriveOwners({ governorMode, monitoringMode, wake, repository });
  const nextAction = deriveNextAction({ governorMode, monitoringMode, wake });

  return {
    schema: 'priority/autonomous-governor-summary-report@v1',
    generatedAt: now.toISOString(),
    repository,
    inputs: {
      queueEmptyReportPath: toRelative(repoRoot, queueEmptyReportPath),
      continuitySummaryPath: toRelative(repoRoot, continuitySummaryPath),
      monitoringModePath: toRelative(repoRoot, monitoringModePath),
      wakeLifecyclePath: toRelative(repoRoot, wakeLifecyclePath),
      wakeInvestmentAccountingPath: toRelative(repoRoot, wakeInvestmentAccountingPath),
      deliveryRuntimeStatePath: toRelative(repoRoot, deliveryRuntimeStatePath)
    },
    compare: {
      queueState,
      continuity,
      monitoringMode: {
        status: asOptional(monitoringMode?.summary?.status),
        futureAgentAction: asOptional(monitoringMode?.summary?.futureAgentAction),
        wakeConditionCount: Number.isInteger(monitoringMode?.summary?.wakeConditionCount)
          ? monitoringMode.summary.wakeConditionCount
          : null
      },
      deliveryRuntime
    },
    wake,
    funding,
    summary: {
      governorMode,
      currentOwnerRepository: owners.currentOwnerRepository,
      nextOwnerRepository: owners.nextOwnerRepository,
      nextAction,
      signalQuality,
      queueState: queueState.status,
      continuityStatus: continuity.status,
      wakeTerminalState: wake.terminalState,
      monitoringStatus: asOptional(monitoringMode?.summary?.status),
      futureAgentAction: asOptional(monitoringMode?.summary?.futureAgentAction),
      queueHandoffStatus: deliveryRuntime.status,
      queueHandoffNextWakeCondition: deliveryRuntime.nextWakeCondition,
      queueHandoffPrUrl: deliveryRuntime.prUrl
    }
  };
}

export async function runAutonomousGovernorSummary(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const queueEmptyReportPath = path.resolve(repoRoot, options.queueEmptyReportPath || DEFAULT_QUEUE_EMPTY_REPORT_PATH);
  const continuitySummaryPath = path.resolve(repoRoot, options.continuitySummaryPath || DEFAULT_CONTINUITY_SUMMARY_PATH);
  const monitoringModePath = path.resolve(repoRoot, options.monitoringModePath || DEFAULT_MONITORING_MODE_PATH);
  const wakeLifecyclePath = path.resolve(repoRoot, options.wakeLifecyclePath || DEFAULT_WAKE_LIFECYCLE_PATH);
  const wakeInvestmentAccountingPath = path.resolve(
    repoRoot,
    options.wakeInvestmentAccountingPath || DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH
  );
  const deliveryRuntimeStatePath = path.resolve(
    repoRoot,
    options.deliveryRuntimeStatePath || DEFAULT_DELIVERY_RUNTIME_STATE_PATH
  );
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);

  const readOptionalJsonFn = deps.readOptionalJsonFn || readOptionalJson;
  const writeJsonFn = deps.writeJsonFn || writeJson;
  const now = deps.now || new Date();

  const queueEmptyReport = readOptionalJsonFn(queueEmptyReportPath);
  const continuitySummary = readOptionalJsonFn(continuitySummaryPath);
  const monitoringMode = readOptionalJsonFn(monitoringModePath);
  const wakeLifecycle = readOptionalJsonFn(wakeLifecyclePath);
  const wakeInvestmentAccounting = readOptionalJsonFn(wakeInvestmentAccountingPath);
  const deliveryRuntimeState = readOptionalJsonFn(deliveryRuntimeStatePath);

  if (queueEmptyReport) {
    ensureSchema(queueEmptyReport, queueEmptyReportPath, 'standing-priority/no-standing@v1');
  }
  if (continuitySummary) {
    ensureSchema(continuitySummary, continuitySummaryPath, 'priority/continuity-telemetry-report@v1');
  }
  if (monitoringMode) {
    ensureSchema(monitoringMode, monitoringModePath, 'agent-handoff/monitoring-mode-v1');
  }
  if (wakeLifecycle) {
    ensureSchema(wakeLifecycle, wakeLifecyclePath, 'priority/wake-lifecycle-report@v1');
  }
  if (wakeInvestmentAccounting) {
    ensureSchema(wakeInvestmentAccounting, wakeInvestmentAccountingPath, 'priority/wake-investment-accounting-report@v1');
  }
  if (deliveryRuntimeState) {
    ensureSchema(deliveryRuntimeState, deliveryRuntimeStatePath, 'priority/delivery-agent-runtime-state@v1');
  }

  const report = buildReport({
    repoRoot,
    queueEmptyReportPath,
    queueEmptyReport,
    continuitySummaryPath,
    continuitySummary,
    monitoringModePath,
    monitoringMode,
    wakeLifecyclePath,
    wakeLifecycle,
    wakeInvestmentAccountingPath,
    wakeInvestmentAccounting,
    deliveryRuntimeStatePath,
    deliveryRuntimeState,
    now
  });

  const writtenPath = writeJsonFn(outputPath, report);
  return { report, outputPath: writtenPath };
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[autonomous-governor-summary] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runAutonomousGovernorSummary(options);
    console.log(
      `[autonomous-governor-summary] wrote ${outputPath} (${report.summary.governorMode}, next=${report.summary.nextAction})`
    );
    return 0;
  } catch (error) {
    console.error(`[autonomous-governor-summary] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && modulePath === invokedPath) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

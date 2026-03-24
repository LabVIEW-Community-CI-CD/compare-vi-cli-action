#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import {
  DEFAULT_OUTPUT_PATH as DEFAULT_DOCKER_REPORT_PATH,
  DOCKER_LANE_CAPABILITY,
  NATIVE_LV32_CAPABILITY,
  runDockerLaneHandshake
} from './docker-lane-handshake.mjs';
import {
  DEFAULT_HARNESS_KIND,
  DEFAULT_OUTPUT_PATH as DEFAULT_EXECUTION_CELL_REPORT_PATH,
  runExecutionCellLease
} from './execution-cell-lease.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const EXECUTION_CELL_BUNDLE_REPORT_SCHEMA = 'priority/execution-cell-bundle-report@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'execution-cell-bundle.json');

export const STATUS = Object.freeze({
  requested: 'requested',
  granted: 'granted',
  committed: 'committed',
  renewed: 'renewed',
  released: 'released',
  active: 'active',
  busy: 'busy',
  denied: 'denied',
  notFound: 'not-found',
  mismatch: 'mismatch',
  invalidState: 'invalid-state',
  stale: 'stale',
  partial: 'partial'
});

const SUCCESS_STATUS = new Set([
  STATUS.requested,
  STATUS.granted,
  STATUS.committed,
  STATUS.renewed,
  STATUS.released,
  STATUS.active
]);

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

function normalizeCapabilities(capabilities = []) {
  const values = [];
  for (const entry of capabilities) {
    const normalized = normalizeText(entry);
    if (normalized) {
      values.push(normalized);
    }
  }
  return [...new Set(values)];
}

function wantsDockerLane(options = {}) {
  return Boolean(toOptionalText(options.laneId)) || normalizeCapabilities(options.capabilities).includes(DOCKER_LANE_CAPABILITY);
}

function inferBundleCapabilities(capabilities = [], planeBinding, dockerRequested) {
  const normalized = new Set(normalizeCapabilities(capabilities));
  const normalizedPlaneBinding = normalizeText(planeBinding).toLowerCase();
  if (dockerRequested) {
    normalized.add(DOCKER_LANE_CAPABILITY);
  }
  if (normalizedPlaneBinding === 'native-labview-2026-32' || normalizedPlaneBinding === 'dual-plane-parity') {
    normalized.add(NATIVE_LV32_CAPABILITY);
  }
  return [...normalized];
}

function isWindowsNativeTestStand(planeBinding, harnessKind) {
  if (!toOptionalText(harnessKind)) {
    return null;
  }
  if (normalizeText(harnessKind) !== DEFAULT_HARNESS_KIND) {
    return null;
  }
  const normalizedPlaneBinding = normalizeText(planeBinding).toLowerCase();
  if (!normalizedPlaneBinding) {
    return true;
  }
  return normalizedPlaneBinding === 'dual-plane-parity' || normalizedPlaneBinding.startsWith('native-labview-');
}

function isSuccessfulStatus(status) {
  return SUCCESS_STATUS.has(normalizeText(status));
}

function firstFailureStatus(...reports) {
  for (const report of reports) {
    const status = normalizeText(report?.status);
    if (status && !isSuccessfulStatus(status)) {
      return status;
    }
  }
  return null;
}

function summarizeEffectiveRate(reports = []) {
  const multipliers = reports
    .map((report) => report?.summary?.billableRateMultiplier)
    .filter((value) => Number.isFinite(value));
  const rates = reports
    .map((report) => report?.summary?.billableRateUsdPerHour)
    .filter((value) => Number.isFinite(value));
  return {
    multiplier: multipliers.length > 0 ? Math.max(...multipliers) : null,
    usdPerHour: rates.length > 0 ? Math.max(...rates) : null
  };
}

function collectSummaryStrings(reports, field) {
  const values = [];
  for (const report of reports) {
    const entries = report?.summary?.[field];
    if (Array.isArray(entries)) {
      values.push(...entries.filter(Boolean));
    }
  }
  return [...new Set(values)];
}

function hasReciprocalBundleLink(executionCell, dockerLane, cellId, laneId) {
  const executionSummary = executionCell?.summary ?? {};
  const dockerSummary = dockerLane?.summary ?? {};
  const executionLeaseId = normalizeText(executionSummary.leaseId);
  const dockerLeaseId = normalizeText(dockerSummary.leaseId);
  if (!executionLeaseId || !dockerLeaseId) {
    return false;
  }

  return (
    normalizeText(executionSummary.linkedDockerLaneId) === normalizeText(laneId) &&
    normalizeText(executionSummary.linkedDockerLaneLeaseId) === dockerLeaseId &&
    normalizeText(dockerSummary.linkedExecutionCellId) === normalizeText(cellId) &&
    normalizeText(dockerSummary.linkedExecutionCellLeaseId) === executionLeaseId
  );
}

function resolveBundleStatus(action, executionCell, dockerLane, rollbacks) {
  const failure = firstFailureStatus(executionCell, dockerLane, rollbacks.executionCell, rollbacks.dockerLane);
  if (failure) {
    return failure;
  }

  if (!dockerLane) {
    return normalizeText(executionCell?.status) || STATUS.notFound;
  }

  if (action === 'inspect') {
    const executionStatus = normalizeText(executionCell?.status);
    const dockerStatus = normalizeText(dockerLane?.status);
    if (executionStatus === STATUS.stale || dockerStatus === STATUS.stale) {
      return STATUS.stale;
    }
    if (executionStatus === STATUS.active || dockerStatus === STATUS.active) {
      return STATUS.active;
    }
    if (executionStatus === STATUS.granted || dockerStatus === STATUS.granted) {
      return STATUS.granted;
    }
    if (executionStatus === STATUS.requested || dockerStatus === STATUS.requested) {
      return STATUS.requested;
    }
    if (executionStatus === STATUS.released || dockerStatus === STATUS.released) {
      return STATUS.released;
    }
    if (executionStatus === STATUS.notFound && dockerStatus === STATUS.notFound) {
      return STATUS.notFound;
    }
    return STATUS.partial;
  }

  if (normalizeText(executionCell?.status) === normalizeText(dockerLane?.status)) {
    return normalizeText(executionCell?.status);
  }

  if (
    action === 'release' &&
    [STATUS.released, STATUS.notFound].includes(normalizeText(executionCell?.status)) &&
    [STATUS.released, STATUS.notFound].includes(normalizeText(dockerLane?.status))
  ) {
    return STATUS.released;
  }

  return STATUS.partial;
}

async function writeReport(outputPath, report) {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
}

async function maybeReleaseExecutionCell(options, now, outputPath, leaseId) {
  return runExecutionCellLease({
    action: 'release',
    cellId: options.cellId,
    leaseId,
    artifactPaths: [],
    hostPlaneReportPath: options.hostPlaneReportPath,
    operatorCostProfilePath: options.operatorCostProfilePath,
    leaseRoot: options.leaseRoot,
    repoRoot: options.repoRoot,
    now,
    outputPath
  });
}

async function maybeReleaseDockerLane(options, now, outputPath) {
  const inspect = await runDockerLaneHandshake({
    action: 'inspect',
    laneId: options.laneId,
    agentId: options.agentId,
    agentClass: options.agentClass,
    hostPlaneReportPath: options.hostPlaneReportPath,
    operatorCostProfilePath: options.operatorCostProfilePath,
    handshakeRoot: options.handshakeRoot,
    repoRoot: options.repoRoot,
    now,
    outputPath
  });
  if (!inspect?.handshake || [STATUS.notFound, STATUS.released].includes(normalizeText(inspect.status))) {
    return inspect;
  }
  return runDockerLaneHandshake({
    action: 'release',
    laneId: options.laneId,
    agentId: options.agentId,
    agentClass: options.agentClass,
    leaseId: inspect?.handshake?.grant?.leaseId,
    artifactPaths: [],
    hostPlaneReportPath: options.hostPlaneReportPath,
    operatorCostProfilePath: options.operatorCostProfilePath,
    handshakeRoot: options.handshakeRoot,
    repoRoot: options.repoRoot,
    now,
    outputPath
  });
}

function buildReport({
  action,
  generatedAt,
  cellId,
  laneId,
  outputPath,
  dockerRequested,
  capabilities,
  executionCell,
  dockerLane,
  rollbacks
}) {
  const reports = [executionCell, dockerLane].filter(Boolean);
  const effectiveRate = summarizeEffectiveRate(reports);
  const premiumSaganMode =
    executionCell?.summary?.premiumSaganMode === true || dockerLane?.summary?.premiumSaganMode === true;
  const observations = collectSummaryStrings(reports, 'observations');
  if (reports.length > 1 && effectiveRate.usdPerHour != null) {
    observations.push('agent-billed-once-at-effective-rate');
  }
  if (rollbacks.executionCell) {
    observations.push(`execution-cell-rollback-${rollbacks.executionCell.status}`);
  }
  if (rollbacks.dockerLane) {
    observations.push(`docker-lane-rollback-${rollbacks.dockerLane.status}`);
  }

  return {
    schema: EXECUTION_CELL_BUNDLE_REPORT_SCHEMA,
    generatedAt,
    action,
    status: resolveBundleStatus(action, executionCell, dockerLane, rollbacks),
    cellId,
    laneId: toOptionalText(laneId),
    outputPath,
    executionCellReportPath: executionCell?.leasePath || null,
    dockerLaneReportPath: dockerLane?.handshakePath || null,
    executionCell,
    dockerLane: dockerLane || null,
    rollbacks: {
      executionCell: rollbacks.executionCell || null,
      dockerLane: rollbacks.dockerLane || null
    },
    summary: {
      holder: toOptionalText(executionCell?.summary?.holder) || toOptionalText(dockerLane?.summary?.holder),
      agentClass:
        toOptionalText(executionCell?.summary?.agentClass) || toOptionalText(dockerLane?.handshake?.request?.agentClass),
      cellClass: toOptionalText(executionCell?.summary?.cellClass),
      suiteClass: toOptionalText(executionCell?.summary?.suiteClass),
      planeBinding: toOptionalText(executionCell?.summary?.planeBinding),
      harnessKind: toOptionalText(executionCell?.summary?.harnessKind),
      harnessInstanceId: toOptionalText(executionCell?.summary?.harnessInstanceId),
      executionCellLeaseId: toOptionalText(executionCell?.summary?.leaseId),
      dockerLaneLeaseId: toOptionalText(dockerLane?.summary?.leaseId),
      linkedExecutionCellId: toOptionalText(dockerLane?.summary?.linkedExecutionCellId),
      linkedExecutionCellLeaseId: toOptionalText(dockerLane?.summary?.linkedExecutionCellLeaseId),
      linkedDockerLaneId: toOptionalText(executionCell?.summary?.linkedDockerLaneId),
      linkedDockerLaneLeaseId: toOptionalText(executionCell?.summary?.linkedDockerLaneLeaseId),
      reciprocalLinkReady: hasReciprocalBundleLink(executionCell, dockerLane, cellId, laneId),
      dockerRequested,
      windowsNativeTestStand: isWindowsNativeTestStand(
        executionCell?.summary?.planeBinding,
        executionCell?.summary?.harnessKind
      ),
      effectiveBillableRateMultiplier: effectiveRate.multiplier,
      effectiveBillableRateUsdPerHour: effectiveRate.usdPerHour,
      premiumSaganMode,
      operatorAuthorizationRef:
        toOptionalText(executionCell?.summary?.operatorAuthorizationRef) ||
        toOptionalText(dockerLane?.summary?.operatorAuthorizationRef),
      isolatedLaneGroupId:
        toOptionalText(executionCell?.summary?.isolatedLaneGroupId) ||
        toOptionalText(dockerLane?.summary?.isolatedLaneGroupId),
      fingerprintSha256:
        toOptionalText(executionCell?.summary?.fingerprintSha256) ||
        toOptionalText(dockerLane?.summary?.fingerprintSha256),
      capabilities,
      denialReasons: collectSummaryStrings([...reports, rollbacks.executionCell, rollbacks.dockerLane], 'denialReasons'),
      observations: [...new Set(observations.filter(Boolean))]
    }
  };
}

function parseArgs(argv) {
  const options = {
    action: '',
    cellId: '',
    laneId: '',
    agentId: '',
    agentClass: '',
    cellClass: '',
    suiteClass: '',
    planeBinding: '',
    harnessKind: DEFAULT_HARNESS_KIND,
    capabilities: [],
    operatorId: '',
    operatorAuthorizationRef: '',
    workingRoot: '',
    artifactRoot: '',
    harnessInstanceId: '',
    hostPlaneReportPath: '',
    operatorCostProfilePath: '',
    executionCellReportPath: '',
    dockerLaneReportPath: '',
    outputPath: '',
    leaseRoot: '',
    handshakeRoot: '',
    artifactPaths: [],
    help: false
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    const next = argv[index + 1];
    switch (token) {
      case '--help':
      case '-h':
        options.help = true;
        break;
      case '--action':
        options.action = next;
        index += 1;
        break;
      case '--cell-id':
        options.cellId = next;
        index += 1;
        break;
      case '--lane-id':
        options.laneId = next;
        index += 1;
        break;
      case '--agent-id':
        options.agentId = next;
        index += 1;
        break;
      case '--agent-class':
        options.agentClass = next;
        index += 1;
        break;
      case '--cell-class':
        options.cellClass = next;
        index += 1;
        break;
      case '--suite-class':
        options.suiteClass = next;
        index += 1;
        break;
      case '--plane-binding':
        options.planeBinding = next;
        index += 1;
        break;
      case '--harness-kind':
        options.harnessKind = next;
        index += 1;
        break;
      case '--capability':
        options.capabilities.push(next);
        index += 1;
        break;
      case '--operator-id':
        options.operatorId = next;
        index += 1;
        break;
      case '--operator-authorization-ref':
        options.operatorAuthorizationRef = next;
        index += 1;
        break;
      case '--working-root':
        options.workingRoot = next;
        index += 1;
        break;
      case '--artifact-root':
        options.artifactRoot = next;
        index += 1;
        break;
      case '--harness-instance-id':
        options.harnessInstanceId = next;
        index += 1;
        break;
      case '--host-plane-report':
        options.hostPlaneReportPath = next;
        index += 1;
        break;
      case '--operator-cost-profile':
        options.operatorCostProfilePath = next;
        index += 1;
        break;
      case '--execution-cell-report':
        options.executionCellReportPath = next;
        index += 1;
        break;
      case '--docker-lane-report':
        options.dockerLaneReportPath = next;
        index += 1;
        break;
      case '--lease-root':
        options.leaseRoot = next;
        index += 1;
        break;
      case '--handshake-root':
        options.handshakeRoot = next;
        index += 1;
        break;
      case '--artifact-path':
        options.artifactPaths.push(next);
        index += 1;
        break;
      case '--output':
        options.outputPath = next;
        index += 1;
        break;
      default:
        throw new Error(`Unknown argument '${token}'`);
    }
  }

  return options;
}

function printUsage() {
  console.log(
    'Usage: node tools/priority/execution-cell-bundle.mjs --action <request|grant|commit|heartbeat|release|inspect> --cell-id <id> [options]'
  );
}

export async function runExecutionCellBundle(options = {}) {
  const now = options.now || new Date();
  const generatedAt = now.toISOString();
  const repoRoot = path.resolve(options.repoRoot || REPO_ROOT);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);
  const dockerRequested = wantsDockerLane(options);
  const capabilities = inferBundleCapabilities(options.capabilities, options.planeBinding, dockerRequested);

  if (!toOptionalText(options.cellId)) {
    const report = buildReport({
      action: options.action,
      generatedAt,
      cellId: '',
      laneId: options.laneId,
      outputPath,
      dockerRequested,
      capabilities,
      executionCell: null,
      dockerLane: null,
      rollbacks: {}
    });
    report.status = STATUS.invalidState;
    report.summary.denialReasons = ['cell-id-required'];
    await writeReport(outputPath, report);
    return report;
  }

  if (dockerRequested && !toOptionalText(options.laneId)) {
    const report = buildReport({
      action: options.action,
      generatedAt,
      cellId: options.cellId,
      laneId: '',
      outputPath,
      dockerRequested,
      capabilities,
      executionCell: null,
      dockerLane: null,
      rollbacks: {}
    });
    report.status = STATUS.invalidState;
    report.summary.denialReasons = ['lane-id-required'];
    await writeReport(outputPath, report);
    return report;
  }

  const executionCellReportPath = path.resolve(
    repoRoot,
    options.executionCellReportPath || DEFAULT_EXECUTION_CELL_REPORT_PATH
  );
  const dockerLaneReportPath = path.resolve(repoRoot, options.dockerLaneReportPath || DEFAULT_DOCKER_REPORT_PATH);

  const executionCellOptions = {
    action: options.action,
    cellId: options.cellId,
    agentId: options.agentId,
    agentClass: options.agentClass,
    cellClass: options.cellClass,
    suiteClass: options.suiteClass,
    planeBinding: options.planeBinding,
    harnessKind: options.harnessKind || DEFAULT_HARNESS_KIND,
    capabilities,
    operatorId: options.operatorId,
    operatorAuthorizationRef: options.operatorAuthorizationRef,
    workingRoot: options.workingRoot,
    artifactRoot: options.artifactRoot,
    harnessInstanceId: options.harnessInstanceId,
    dockerLaneReportPath,
    hostPlaneReportPath: options.hostPlaneReportPath,
    operatorCostProfilePath: options.operatorCostProfilePath,
    leaseRoot: options.leaseRoot,
    repoRoot,
    now,
    artifactPaths: options.artifactPaths,
    outputPath: executionCellReportPath
  };

  const dockerLaneOptions = dockerRequested
    ? {
        action: options.action,
        laneId: options.laneId,
        agentId: options.agentId,
        agentClass: options.agentClass,
        capabilities,
        operatorId: options.operatorId,
        operatorAuthorizationRef: options.operatorAuthorizationRef,
        executionCellReportPath,
        hostPlaneReportPath: options.hostPlaneReportPath,
        operatorCostProfilePath: options.operatorCostProfilePath,
        handshakeRoot: options.handshakeRoot,
        repoRoot,
        now,
        artifactPaths: options.artifactPaths,
        outputPath: dockerLaneReportPath
      }
    : null;

  let executionCell = null;
  let dockerLane = null;
  const rollbacks = {};

  switch (normalizeText(options.action).toLowerCase()) {
    case 'request':
      executionCell = await runExecutionCellLease(executionCellOptions);
      if (dockerLaneOptions) {
        dockerLane = await runDockerLaneHandshake(dockerLaneOptions);
        await writeReport(dockerLaneReportPath, dockerLane);
      }
      break;
    case 'grant':
      executionCell = await runExecutionCellLease(executionCellOptions);
      if (dockerLaneOptions) {
        if (normalizeText(executionCell?.status) === STATUS.granted) {
          dockerLane = await runDockerLaneHandshake(dockerLaneOptions);
          await writeReport(dockerLaneReportPath, dockerLane);
          if (normalizeText(dockerLane?.status) !== STATUS.granted) {
            rollbacks.executionCell = await maybeReleaseExecutionCell(
              executionCellOptions,
              now,
              executionCellReportPath,
              executionCell?.lease?.grant?.leaseId
            );
          }
        } else {
          rollbacks.dockerLane = await maybeReleaseDockerLane(dockerLaneOptions, now, dockerLaneReportPath);
        }
      }
      break;
    case 'commit':
      if (dockerLaneOptions) {
        dockerLane = await runDockerLaneHandshake(dockerLaneOptions);
        await writeReport(dockerLaneReportPath, dockerLane);
        if (normalizeText(dockerLane?.status) === STATUS.committed) {
          executionCell = await runExecutionCellLease(executionCellOptions);
          if (normalizeText(executionCell?.status) !== STATUS.committed) {
            rollbacks.dockerLane = await maybeReleaseDockerLane(dockerLaneOptions, now, dockerLaneReportPath);
          }
        } else {
          executionCell = await runExecutionCellLease({ ...executionCellOptions, action: 'inspect' });
        }
      } else {
        executionCell = await runExecutionCellLease(executionCellOptions);
      }
      break;
    case 'heartbeat':
      if (dockerLaneOptions) {
        dockerLane = await runDockerLaneHandshake(dockerLaneOptions);
        await writeReport(dockerLaneReportPath, dockerLane);
      }
      executionCell = await runExecutionCellLease(executionCellOptions);
      break;
    case 'release':
      if (dockerLaneOptions) {
        dockerLane = await runDockerLaneHandshake(dockerLaneOptions);
        await writeReport(dockerLaneReportPath, dockerLane);
      }
      executionCell = await runExecutionCellLease(executionCellOptions);
      break;
    case 'inspect':
      executionCell = await runExecutionCellLease({ ...executionCellOptions, action: 'inspect' });
      if (dockerLaneOptions) {
        dockerLane = await runDockerLaneHandshake({ ...dockerLaneOptions, action: 'inspect' });
        await writeReport(dockerLaneReportPath, dockerLane);
      }
      break;
    default:
      throw new Error(`Unsupported action '${options.action}'`);
  }

  const report = buildReport({
    action: normalizeText(options.action).toLowerCase(),
    generatedAt,
    cellId: options.cellId,
    laneId: options.laneId,
    outputPath,
    dockerRequested,
    capabilities,
    executionCell,
    dockerLane,
    rollbacks
  });
  await writeReport(outputPath, report);
  return report;
}

function exitCodeForStatus(status) {
  if ([STATUS.requested, STATUS.granted, STATUS.committed, STATUS.renewed, STATUS.released, STATUS.active].includes(status)) {
    return 0;
  }
  if (status === STATUS.notFound) {
    return 0;
  }
  return 1;
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const report = await runExecutionCellBundle({
    ...options,
    repoRoot: process.cwd()
  });
  console.log(
    `[execution-cell-bundle] report: ${path.resolve(process.cwd(), options.outputPath || DEFAULT_OUTPUT_PATH)} status=${report.status} cell=${report.cellId} lane=${report.laneId ?? 'none'}`
  );
  return exitCodeForStatus(report.status);
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

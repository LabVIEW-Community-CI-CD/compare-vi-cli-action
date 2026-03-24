#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { resolveGitAdminPaths } from './lib/git-admin-paths.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const EXECUTION_CELL_LEASE_SCHEMA = 'priority/execution-cell-lease@v1';
export const EXECUTION_CELL_LEASE_REPORT_SCHEMA = 'priority/execution-cell-lease-report@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'execution-cell-lease.json');
export const DEFAULT_HOST_PLANE_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'host-planes',
  'labview-2026-host-plane-report.json'
);
export const DEFAULT_OPERATOR_COST_PROFILE_PATH = path.join('tools', 'policy', 'operator-cost-profile.json');
export const DEFAULT_TTL_SECONDS = 1800;
export const DEFAULT_HARNESS_KIND = 'teststand-compare-harness';
export const PREMIUM_RATE_MULTIPLIER = 1.5;
export const ORDINARY_RATE_MULTIPLIER = 1.0;
export const DOCKER_LANE_CAPABILITY = 'docker-lane';
export const NATIVE_LV32_CAPABILITY = 'native-labview-2026-32';
export const DEFAULT_CELL_CLASS = 'worker';

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
  stale: 'stale'
});

export const CELL_CLASS = Object.freeze({
  worker: 'worker',
  coordinator: 'coordinator',
  kernelCoordinator: 'kernel-coordinator'
});

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

function normalizeAgentClass(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (['sagan', 'subagent', 'other'].includes(normalized)) {
    return normalized;
  }
  return 'subagent';
}

function normalizeCellClass(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (Object.values(CELL_CLASS).includes(normalized)) {
    return normalized;
  }
  return DEFAULT_CELL_CLASS;
}

function nowIso(now = new Date()) {
  return now.toISOString();
}

function uniqueId(prefix = 'id', now = Date.now()) {
  return `${prefix}-${now}-${Math.random().toString(16).slice(2, 10)}`;
}

function sanitizeCellId(cellId) {
  return normalizeText(cellId).replace(/[^a-zA-Z0-9._-]+/g, '__');
}

function resolveDefaultLeaseRoot(options = {}) {
  try {
    return path.join(
      resolveGitAdminPaths({
        cwd: options.repoRoot || REPO_ROOT,
        env: options.env || process.env,
        spawnSyncFn: options.spawnSyncFn || spawnSync
      }).gitCommonDir,
      'execution-cell-leases'
    );
  } catch {
    return path.join(options.repoRoot || REPO_ROOT, '.git', 'execution-cell-leases');
  }
}

export function defaultLeaseRoot(options = {}) {
  return options.leaseRoot || process.env.EXECUTION_CELL_LEASE_ROOT || resolveDefaultLeaseRoot(options);
}

export function leasePathForCell(cellId, leaseRoot = defaultLeaseRoot()) {
  return path.join(leaseRoot, `${sanitizeCellId(cellId)}.json`);
}

async function ensureParentDir(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
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

async function writeJsonAtomic(filePath, payload) {
  await ensureParentDir(filePath);
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  const body = `${JSON.stringify(payload, null, 2)}\n`;
  await fs.writeFile(tempPath, body, 'utf8');
  try {
    await fs.rename(tempPath, filePath);
  } finally {
    await fs.rm(tempPath, { force: true });
  }
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

function isPremiumDualLaneRequest(capabilities = []) {
  const set = new Set(normalizeCapabilities(capabilities));
  return set.has(DOCKER_LANE_CAPABILITY) && set.has(NATIVE_LV32_CAPABILITY);
}

function isWindowsNativeTestStandPlaneBinding(planeBinding) {
  const normalized = normalizeText(planeBinding).toLowerCase();
  if (!normalized) {
    return true;
  }
  return normalized === 'dual-plane-parity' || normalized.startsWith('native-labview-');
}

function resolveHeartbeatTimestamp(lease) {
  return (
    lease?.heartbeatAt ||
    lease?.commit?.committedAt ||
    lease?.grant?.grantedAt ||
    lease?.request?.requestedAt ||
    null
  );
}

function leaseAgeSeconds(lease, nowMs = Date.now()) {
  const timestamp = resolveHeartbeatTimestamp(lease);
  if (!timestamp) {
    return Number.POSITIVE_INFINITY;
  }
  const parsed = Date.parse(timestamp);
  if (!Number.isFinite(parsed)) {
    return Number.POSITIVE_INFINITY;
  }
  return Math.max(0, (nowMs - parsed) / 1000);
}

function resolveTtlSeconds(lease) {
  return Number.isInteger(lease?.grant?.ttlSeconds) ? lease.grant.ttlSeconds : DEFAULT_TTL_SECONDS;
}

export function isExecutionCellLeaseStale(lease, nowMs = Date.now()) {
  if (!lease || lease.state === 'released') {
    return false;
  }
  return leaseAgeSeconds(lease, nowMs) > resolveTtlSeconds(lease);
}

function buildHostContext(hostPlaneReport) {
  const fingerprint = hostPlaneReport?.host?.osFingerprint;
  if (!fingerprint || typeof fingerprint !== 'object') {
    return {
      context: null,
      observations: ['host-os-fingerprint-missing']
    };
  }

  return {
    context: {
      isolatedLaneGroupId: toOptionalText(fingerprint.isolatedLaneGroupId),
      fingerprintSha256: toOptionalText(fingerprint.fingerprintSha256),
      platform: toOptionalText(fingerprint.platform),
      computerName: toOptionalText(hostPlaneReport?.host?.computerName),
      canonical: {
        version: toOptionalText(fingerprint?.canonical?.version),
        buildNumber: toOptionalText(fingerprint?.canonical?.buildNumber),
        ubr: Number.isInteger(fingerprint?.canonical?.ubr) ? fingerprint.canonical.ubr : null
      }
    },
    observations: []
  };
}

function resolveOperatorProfile(profile, explicitOperatorId) {
  const operators = Array.isArray(profile?.operators) ? profile.operators : [];
  const desiredId = toOptionalText(explicitOperatorId) || toOptionalText(profile?.defaultOperatorId);
  const activeOperators = operators.filter((entry) => entry?.active !== false);
  const resolved =
    activeOperators.find((entry) => normalizeText(entry?.id) === normalizeText(desiredId)) ||
    activeOperators[0] ||
    null;

  return {
    operatorId: toOptionalText(resolved?.id) || desiredId,
    currency: toOptionalText(profile?.currency) || 'USD',
    laborRateUsdPerHour: Number.isFinite(resolved?.laborRateUsdPerHour)
      ? Number(resolved.laborRateUsdPerHour)
      : null
  };
}

function buildRequestRecord({
  cellId,
  agentId,
  agentClass,
  cellClass,
  suiteClass,
  planeBinding,
  harnessKind,
  capabilities,
  operatorId,
  operatorAuthorizationRef,
  workingRoot,
  artifactRoot,
  now,
  requestId,
  hostContext
}) {
  const requestedCapabilities = normalizeCapabilities(capabilities);
  const premiumDualLaneRequested = isPremiumDualLaneRequest(requestedCapabilities);
  const generatedAt = nowIso(now);
  return {
    schema: EXECUTION_CELL_LEASE_SCHEMA,
    generatedAt,
    cellId,
    resourceKind: 'execution-cell',
    state: 'requested',
    sequence: 1,
    heartbeatAt: generatedAt,
    host: hostContext,
    request: {
      requestId,
      requestedAt: generatedAt,
      agentId,
      agentClass,
      cellClass,
      suiteClass: toOptionalText(suiteClass),
      planeBinding: toOptionalText(planeBinding),
      harnessKind: toOptionalText(harnessKind) || DEFAULT_HARNESS_KIND,
      capabilities: requestedCapabilities,
      premiumDualLaneRequested,
      operatorId: toOptionalText(operatorId),
      operatorAuthorizationRef: toOptionalText(operatorAuthorizationRef),
      workingRoot: toOptionalText(workingRoot),
      artifactRoot: toOptionalText(artifactRoot)
    },
    grant: null,
    commit: null,
    release: null
  };
}

function buildGrantDecision(lease, operatorProfile, nowMs = Date.now()) {
  const reasons = [];
  const stale = isExecutionCellLeaseStale(lease, nowMs);
  const leaseState = toOptionalText(lease?.state);
  const requestedCapabilities = normalizeCapabilities(lease?.request?.capabilities);
  const premiumDualLaneRequested = lease?.request?.premiumDualLaneRequested === true;
  const requestedCellClass = normalizeCellClass(lease?.request?.cellClass);
  const requestedHarnessKind = toOptionalText(lease?.request?.harnessKind) || DEFAULT_HARNESS_KIND;
  const requestedPlaneBinding = toOptionalText(lease?.request?.planeBinding);
  if (leaseState === 'active' && !stale) {
    reasons.push('execution-cell-already-active');
  }
  if (
    requestedHarnessKind === DEFAULT_HARNESS_KIND &&
    !isWindowsNativeTestStandPlaneBinding(requestedPlaneBinding)
  ) {
    reasons.push('teststand-windows-native-only');
  }
  if (requestedCellClass === CELL_CLASS.kernelCoordinator && lease?.request?.agentClass !== 'sagan') {
    reasons.push('kernel-cell-sagan-only');
  }
  if (premiumDualLaneRequested && lease?.request?.agentClass !== 'sagan') {
    reasons.push('premium-sagan-only');
  }
  if (premiumDualLaneRequested && requestedCellClass !== CELL_CLASS.kernelCoordinator) {
    reasons.push('premium-kernel-cell-required');
  }
  if (premiumDualLaneRequested && !toOptionalText(lease?.request?.operatorAuthorizationRef)) {
    reasons.push('operator-authorization-required');
  }
  if (!Number.isFinite(operatorProfile?.laborRateUsdPerHour)) {
    reasons.push('operator-cost-rate-unavailable');
  }

  const billableRateMultiplier = premiumDualLaneRequested ? PREMIUM_RATE_MULTIPLIER : ORDINARY_RATE_MULTIPLIER;
  return {
    allowed: reasons.length === 0,
    reasons,
    premiumDualLaneRequested,
    premiumSaganMode: premiumDualLaneRequested,
    policyDecision: premiumDualLaneRequested ? 'sagan-premium-dual-lane' : 'ordinary-execution-cell',
    grantedCapabilities: requestedCapabilities,
    billableRateMultiplier,
    billableRateUsdPerHour: Number.isFinite(operatorProfile?.laborRateUsdPerHour)
      ? Number((operatorProfile.laborRateUsdPerHour * billableRateMultiplier).toFixed(3))
      : null
  };
}

function buildBaseReport(action, cellId, leasePath, generatedAt, lease, extras = {}) {
  const stale = isExecutionCellLeaseStale(lease, Date.parse(generatedAt));
  return {
    schema: EXECUTION_CELL_LEASE_REPORT_SCHEMA,
    generatedAt,
    action,
    cellId,
    leasePath,
    lease,
    summary: {
      leaseState: lease?.state ?? null,
      leaseId: toOptionalText(lease?.grant?.leaseId),
      holder: toOptionalText(lease?.request?.agentId),
      agentClass: toOptionalText(lease?.request?.agentClass),
      cellClass: toOptionalText(lease?.request?.cellClass),
      harnessKind: toOptionalText(lease?.request?.harnessKind),
      harnessInstanceId: toOptionalText(lease?.commit?.harnessInstanceId),
      suiteClass: toOptionalText(lease?.request?.suiteClass),
      planeBinding: toOptionalText(lease?.request?.planeBinding),
      premiumSaganMode:
        lease?.grant?.premiumSaganMode === true || lease?.request?.premiumDualLaneRequested === true,
      billableRateMultiplier: Number.isFinite(lease?.grant?.billableRateMultiplier)
        ? lease.grant.billableRateMultiplier
        : null,
      billableRateUsdPerHour: Number.isFinite(lease?.grant?.billableRateUsdPerHour)
        ? lease.grant.billableRateUsdPerHour
        : null,
      operatorAuthorizationRef: toOptionalText(lease?.request?.operatorAuthorizationRef),
      isolatedLaneGroupId: toOptionalText(lease?.host?.isolatedLaneGroupId),
      fingerprintSha256: toOptionalText(lease?.host?.fingerprintSha256),
      workingRoot: toOptionalText(lease?.commit?.workingRoot) || toOptionalText(lease?.request?.workingRoot),
      artifactRoot: toOptionalText(lease?.commit?.artifactRoot) || toOptionalText(lease?.request?.artifactRoot),
      isStale: stale,
      ageSeconds: Number.isFinite(leaseAgeSeconds(lease, Date.parse(generatedAt)))
        ? Number(leaseAgeSeconds(lease, Date.parse(generatedAt)).toFixed(3))
        : null,
      ttlSeconds: lease ? resolveTtlSeconds(lease) : null,
      denialReasons: [],
      observations: []
    },
    ...extras
  };
}

function parseArgs(argv) {
  const result = {
    action: 'inspect',
    capabilities: [],
    artifactPaths: []
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--action') {
      result.action = argv[++index];
    } else if (token === '--cell-id') {
      result.cellId = argv[++index];
    } else if (token === '--agent-id') {
      result.agentId = argv[++index];
    } else if (token === '--agent-class') {
      result.agentClass = argv[++index];
    } else if (token === '--cell-class') {
      result.cellClass = argv[++index];
    } else if (token === '--suite-class') {
      result.suiteClass = argv[++index];
    } else if (token === '--plane-binding') {
      result.planeBinding = argv[++index];
    } else if (token === '--harness-kind') {
      result.harnessKind = argv[++index];
    } else if (token === '--working-root') {
      result.workingRoot = argv[++index];
    } else if (token === '--artifact-root') {
      result.artifactRoot = argv[++index];
    } else if (token === '--lease-id') {
      result.leaseId = argv[++index];
    } else if (token === '--harness-instance-id') {
      result.harnessInstanceId = argv[++index];
    } else if (token === '--operator-id') {
      result.operatorId = argv[++index];
    } else if (token === '--operator-authorization-ref') {
      result.operatorAuthorizationRef = argv[++index];
    } else if (token === '--host-plane-report-path') {
      result.hostPlaneReportPath = argv[++index];
    } else if (token === '--operator-cost-profile-path') {
      result.operatorCostProfilePath = argv[++index];
    } else if (token === '--output-path') {
      result.outputPath = argv[++index];
    } else if (token === '--lease-root') {
      result.leaseRoot = argv[++index];
    } else if (token === '--capability') {
      result.capabilities.push(argv[++index]);
    } else if (token === '--premium-dual-lane') {
      result.capabilities.push(DOCKER_LANE_CAPABILITY);
      result.capabilities.push(NATIVE_LV32_CAPABILITY);
    } else if (token === '--artifact-path') {
      result.artifactPaths.push(argv[++index]);
    }
  }
  return result;
}

async function loadOptionalJson(filePath) {
  if (!filePath) {
    return null;
  }
  return readJsonIfPresent(filePath);
}

export async function runExecutionCellLease(options = {}) {
  const action = toOptionalText(options.action) || 'inspect';
  const cellId = toOptionalText(options.cellId);
  if (!cellId) {
    throw new Error('cellId is required');
  }

  const repoRoot = options.repoRoot || REPO_ROOT;
  const leaseRoot = defaultLeaseRoot({ ...options, repoRoot });
  const leasePath = leasePathForCell(cellId, leaseRoot);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);
  const hostPlaneReportPath = path.resolve(repoRoot, options.hostPlaneReportPath || DEFAULT_HOST_PLANE_REPORT_PATH);
  const operatorCostProfilePath = path.resolve(
    repoRoot,
    options.operatorCostProfilePath || DEFAULT_OPERATOR_COST_PROFILE_PATH
  );
  const now = options.now || new Date();
  const generatedAt = nowIso(now);

  const hostPlaneReport = await loadOptionalJson(hostPlaneReportPath);
  const operatorCostProfile = await loadOptionalJson(operatorCostProfilePath);
  const hostContext = buildHostContext(hostPlaneReport);
  const operatorProfile = resolveOperatorProfile(operatorCostProfile, options.operatorId);
  const agentClass = normalizeAgentClass(options.agentClass);
  const cellClass = normalizeCellClass(options.cellClass);
  const capabilities = normalizeCapabilities(options.capabilities);

  const existing = await readJsonIfPresent(leasePath);

  if (action === 'request') {
    const lease = buildRequestRecord({
      cellId,
      agentId: toOptionalText(options.agentId),
      agentClass,
      cellClass,
      suiteClass: options.suiteClass,
      planeBinding: options.planeBinding,
      harnessKind: options.harnessKind,
      capabilities,
      operatorId: operatorProfile.operatorId,
      operatorAuthorizationRef: options.operatorAuthorizationRef,
      workingRoot: options.workingRoot,
      artifactRoot: options.artifactRoot,
      now,
      requestId: uniqueId('request', now.getTime()),
      hostContext: hostContext.context
    });

    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, cellId, leasePath, generatedAt, lease, {
      status: STATUS.requested,
      policy: {
        operatorId: operatorProfile.operatorId,
        currency: operatorProfile.currency,
        laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
      }
    });
    report.summary.observations.push(...hostContext.observations);
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (!existing) {
    const report = buildBaseReport(action, cellId, leasePath, generatedAt, null, {
      status: STATUS.notFound,
      policy: {
        operatorId: operatorProfile.operatorId,
        currency: operatorProfile.currency,
        laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
      }
    });
    report.summary.observations.push('execution-cell-lease-missing');
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'grant') {
    const decision = buildGrantDecision(existing, operatorProfile, now.getTime());
    if (!decision.allowed) {
      const report = buildBaseReport(action, cellId, leasePath, generatedAt, existing, {
        status: decision.reasons.includes('execution-cell-already-active') ? STATUS.busy : STATUS.denied,
        policy: {
          operatorId: operatorProfile.operatorId,
          currency: operatorProfile.currency,
          laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
        }
      });
      report.summary.denialReasons.push(...decision.reasons);
      await writeJsonAtomic(outputPath, report);
      return report;
    }

    const lease = {
      ...existing,
      generatedAt,
      state: 'granted',
      sequence: Number.isInteger(existing.sequence) ? existing.sequence + 1 : 2,
      heartbeatAt: generatedAt,
      host: hostContext.context || existing.host || null,
      grant: {
        grantedAt: generatedAt,
        grantor: toOptionalText(options.grantor) || 'execution-cell-governor',
        leaseId: uniqueId('lease', now.getTime()),
        ttlSeconds: Number.isInteger(options.ttlSeconds) ? options.ttlSeconds : DEFAULT_TTL_SECONDS,
        premiumDualLaneRequested: decision.premiumDualLaneRequested,
        premiumSaganMode: decision.premiumSaganMode,
        policyDecision: decision.policyDecision,
        grantedCapabilities: decision.grantedCapabilities,
        billableRateMultiplier: decision.billableRateMultiplier,
        billableRateUsdPerHour: decision.billableRateUsdPerHour
      }
    };

    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, cellId, leasePath, generatedAt, lease, {
      status: STATUS.granted,
      policy: {
        operatorId: operatorProfile.operatorId,
        currency: operatorProfile.currency,
        laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
      }
    });
    report.summary.observations.push(...hostContext.observations);
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'commit' || action === 'heartbeat') {
    const leaseId = toOptionalText(options.leaseId);
    if (leaseId && leaseId !== toOptionalText(existing?.grant?.leaseId)) {
      const report = buildBaseReport(action, cellId, leasePath, generatedAt, existing, {
        status: STATUS.mismatch,
        policy: {
          operatorId: operatorProfile.operatorId,
          currency: operatorProfile.currency,
          laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
        }
      });
      report.summary.denialReasons.push('lease-id-mismatch');
      await writeJsonAtomic(outputPath, report);
      return report;
    }

    if (toOptionalText(existing.state) !== 'granted' && toOptionalText(existing.state) !== 'active') {
      const report = buildBaseReport(action, cellId, leasePath, generatedAt, existing, {
        status: STATUS.invalidState,
        policy: {
          operatorId: operatorProfile.operatorId,
          currency: operatorProfile.currency,
          laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
        }
      });
      report.summary.denialReasons.push('execution-cell-not-granted');
      await writeJsonAtomic(outputPath, report);
      return report;
    }

    const lease = {
      ...existing,
      generatedAt,
      state: 'active',
      sequence: Number.isInteger(existing.sequence) ? existing.sequence + 1 : 2,
      heartbeatAt: generatedAt,
      host: hostContext.context || existing.host || null,
      commit: {
        committedAt: generatedAt,
        harnessInstanceId:
          toOptionalText(options.harnessInstanceId) || toOptionalText(existing?.commit?.harnessInstanceId),
        workingRoot: toOptionalText(options.workingRoot) || toOptionalText(existing?.request?.workingRoot),
        artifactRoot: toOptionalText(options.artifactRoot) || toOptionalText(existing?.request?.artifactRoot)
      }
    };

    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, cellId, leasePath, generatedAt, lease, {
      status: action === 'commit' ? STATUS.committed : STATUS.renewed,
      policy: {
        operatorId: operatorProfile.operatorId,
        currency: operatorProfile.currency,
        laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
      }
    });
    report.summary.observations.push(...hostContext.observations);
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'release') {
    const leaseId = toOptionalText(options.leaseId);
    if (leaseId && leaseId !== toOptionalText(existing?.grant?.leaseId)) {
      const report = buildBaseReport(action, cellId, leasePath, generatedAt, existing, {
        status: STATUS.mismatch,
        policy: {
          operatorId: operatorProfile.operatorId,
          currency: operatorProfile.currency,
          laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
        }
      });
      report.summary.denialReasons.push('lease-id-mismatch');
      await writeJsonAtomic(outputPath, report);
      return report;
    }

    const lease = {
      ...existing,
      generatedAt,
      state: 'released',
      sequence: Number.isInteger(existing.sequence) ? existing.sequence + 1 : 2,
      heartbeatAt: generatedAt,
      release: {
        releasedAt: generatedAt,
        artifactPaths: options.artifactPaths?.map((entry) => normalizeText(entry)).filter(Boolean) || []
      }
    };
    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, cellId, leasePath, generatedAt, lease, {
      status: STATUS.released,
      policy: {
        operatorId: operatorProfile.operatorId,
        currency: operatorProfile.currency,
        laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
      }
    });
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'inspect') {
    const stale = isExecutionCellLeaseStale(existing, now.getTime());
    const report = buildBaseReport(action, cellId, leasePath, generatedAt, existing, {
      status: stale ? STATUS.stale : toOptionalText(existing.state) === 'released' ? STATUS.released : STATUS.active,
      policy: {
        operatorId: operatorProfile.operatorId,
        currency: operatorProfile.currency,
        laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour
      }
    });
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  throw new Error(`Unsupported action '${action}'`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const report = await runExecutionCellLease(options);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}

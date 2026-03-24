#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { resolveGitAdminPaths } from './lib/git-admin-paths.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const TESTSTAND_HARNESS_INSTANCE_SCHEMA = 'priority/teststand-harness-instance-lease@v1';
export const TESTSTAND_HARNESS_INSTANCE_REPORT_SCHEMA = 'priority/teststand-harness-instance-lease-report@v1';
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'teststand-harness-instance-lease.json'
);
export const DEFAULT_TTL_SECONDS = 1800;
export const DEFAULT_HARNESS_KIND = 'teststand-compare-harness';
export const DEFAULT_RUNTIME_SURFACE = 'windows-native-teststand';

export const STATUS = Object.freeze({
  requested: 'requested',
  granted: 'granted',
  committed: 'committed',
  renewed: 'renewed',
  released: 'released',
  active: 'active',
  stale: 'stale',
  denied: 'denied',
  invalidState: 'invalid-state',
  notFound: 'not-found',
  mismatch: 'mismatch'
});

export const ROLE = Object.freeze({
  singlePlane: 'single-plane',
  coordinator: 'coordinator',
  planeChild: 'plane-child'
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

function nowIso(now = new Date()) {
  return now.toISOString();
}

function uniqueId(prefix = 'id', now = Date.now()) {
  return `${prefix}-${now}-${Math.random().toString(16).slice(2, 10)}`;
}

function sanitizeId(value, fallback = 'instance') {
  return normalizeText(value)
    .replace(/[^A-Za-z0-9._-]+/g, '--')
    .replace(/^-+|-+$/g, '') || fallback;
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
  await fs.writeFile(tempPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  try {
    await fs.rename(tempPath, filePath);
  } finally {
    await fs.rm(tempPath, { force: true });
  }
}

function resolveDefaultLeaseRoot(options = {}) {
  try {
    return path.join(
      resolveGitAdminPaths({
        cwd: options.repoRoot || REPO_ROOT,
        env: options.env || process.env,
        spawnSyncFn: options.spawnSyncFn || spawnSync
      }).gitCommonDir,
      'teststand-harness-instance-leases'
    );
  } catch {
    return path.join(options.repoRoot || REPO_ROOT, '.git', 'teststand-harness-instance-leases');
  }
}

function defaultLeaseRoot(options = {}) {
  return options.leaseRoot || process.env.TESTSTAND_HARNESS_INSTANCE_LEASE_ROOT || resolveDefaultLeaseRoot(options);
}

export function leasePathForHarnessInstance(instanceId, leaseRoot = defaultLeaseRoot()) {
  return path.join(leaseRoot, `${sanitizeId(instanceId)}.json`);
}

function isWindowsNativeTestStandPlaneBinding(planeBinding) {
  const normalized = normalizeText(planeBinding).toLowerCase();
  if (!normalized) {
    return true;
  }
  return normalized === 'dual-plane-parity' || normalized.startsWith('native-labview-');
}

function deriveRole(value, suiteClass, planeKey) {
  const normalized = normalizeText(value).toLowerCase();
  if (Object.values(ROLE).includes(normalized)) {
    return normalized;
  }
  if (normalizeText(suiteClass) === 'dual-plane-parity') {
    return planeKey ? ROLE.planeChild : ROLE.coordinator;
  }
  return ROLE.singlePlane;
}

function deriveProcessModelClass(value, suiteClass) {
  const normalized = normalizeText(value).toLowerCase();
  if (normalized) {
    return normalized;
  }
  return normalizeText(suiteClass) === 'dual-plane-parity'
    ? 'parallel-process-model'
    : 'sequential-process-model';
}

function deriveInstanceId({
  requestedInstanceId,
  executionCell,
  role,
  planeKey,
  parentInstanceId,
  harnessKind
}) {
  const explicit = toOptionalText(requestedInstanceId);
  if (explicit) {
    return explicit;
  }
  if (role === ROLE.planeChild && parentInstanceId) {
    return `${parentInstanceId}-${sanitizeId(planeKey || 'plane')}`;
  }
  const base =
    toOptionalText(executionCell?.cellId) ||
    toOptionalText(executionCell?.leaseId) ||
    'cell';
  const suffix = role === ROLE.coordinator ? 'coordinator' : 'single';
  return `${sanitizeId(harnessKind || DEFAULT_HARNESS_KIND)}-${sanitizeId(base)}-${suffix}`;
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

export function isTestStandHarnessInstanceLeaseStale(lease, nowMs = Date.now()) {
  if (!lease || lease.state === 'released') {
    return false;
  }
  return leaseAgeSeconds(lease, nowMs) > resolveTtlSeconds(lease);
}

function buildExecutionCellContext(leasePath, lease) {
  const request = lease?.request || {};
  const grant = lease?.grant || {};
  const host = lease?.host || {};
  return {
    leasePath: toOptionalText(leasePath),
    cellId: toOptionalText(lease?.cellId),
    leaseId: toOptionalText(grant.leaseId),
    state: toOptionalText(lease?.state),
    agentId: toOptionalText(request.agentId),
    agentClass: toOptionalText(request.agentClass),
    cellClass: toOptionalText(request.cellClass),
    suiteClass: toOptionalText(request.suiteClass),
    planeBinding: toOptionalText(request.planeBinding),
    harnessKind: toOptionalText(request.harnessKind) || DEFAULT_HARNESS_KIND,
    premiumSaganMode: grant.premiumSaganMode === true,
    operatorAuthorizationRef: toOptionalText(request.operatorAuthorizationRef),
    workingRoot: toOptionalText(request.workingRoot),
    artifactRoot: toOptionalText(request.artifactRoot),
    isolatedLaneGroupId: toOptionalText(host.isolatedLaneGroupId),
    fingerprintSha256: toOptionalText(host.fingerprintSha256)
  };
}

function buildRequestRecord({
  instanceId,
  executionCell,
  role,
  planeKey,
  parentInstanceId,
  processModelClass,
  harnessKind,
  now
}) {
  const generatedAt = nowIso(now);
  return {
    schema: TESTSTAND_HARNESS_INSTANCE_SCHEMA,
    generatedAt,
    instanceId,
    resourceKind: 'teststand-harness-instance',
    state: 'requested',
    sequence: 1,
    heartbeatAt: generatedAt,
    host: {
      isolatedLaneGroupId: executionCell.isolatedLaneGroupId,
      fingerprintSha256: executionCell.fingerprintSha256
    },
    request: {
      requestId: uniqueId('request', now.getTime()),
      requestedAt: generatedAt,
      executionCellLeasePath: executionCell.leasePath,
      executionCellId: executionCell.cellId,
      executionCellLeaseId: executionCell.leaseId,
      agentId: executionCell.agentId,
      agentClass: executionCell.agentClass,
      cellClass: executionCell.cellClass,
      suiteClass: executionCell.suiteClass,
      planeBinding: executionCell.planeBinding,
      role,
      planeKey: toOptionalText(planeKey),
      parentInstanceId: toOptionalText(parentInstanceId),
      harnessKind,
      runtimeSurface: DEFAULT_RUNTIME_SURFACE,
      processModelClass,
      premiumSaganMode: executionCell.premiumSaganMode,
      operatorAuthorizationRef: executionCell.operatorAuthorizationRef,
      workingRoot: executionCell.workingRoot,
      artifactRoot: executionCell.artifactRoot
    },
    grant: null,
    commit: null,
    release: null
  };
}

function buildBaseReport(action, instanceId, leasePath, generatedAt, lease, extras = {}) {
  const stale = isTestStandHarnessInstanceLeaseStale(lease, Date.parse(generatedAt));
  return {
    schema: TESTSTAND_HARNESS_INSTANCE_REPORT_SCHEMA,
    generatedAt,
    action,
    instanceId,
    leasePath,
    lease,
    summary: {
      leaseState: lease?.state ?? null,
      leaseId: toOptionalText(lease?.grant?.leaseId),
      executionCellId: toOptionalText(lease?.request?.executionCellId),
      executionCellLeaseId: toOptionalText(lease?.request?.executionCellLeaseId),
      agentId: toOptionalText(lease?.request?.agentId),
      agentClass: toOptionalText(lease?.request?.agentClass),
      cellClass: toOptionalText(lease?.request?.cellClass),
      suiteClass: toOptionalText(lease?.request?.suiteClass),
      role: toOptionalText(lease?.request?.role),
      planeKey: toOptionalText(lease?.request?.planeKey),
      parentInstanceId: toOptionalText(lease?.request?.parentInstanceId),
      harnessKind: toOptionalText(lease?.request?.harnessKind),
      runtimeSurface: toOptionalText(lease?.request?.runtimeSurface),
      processModelClass: toOptionalText(lease?.request?.processModelClass),
      premiumSaganMode: lease?.request?.premiumSaganMode === true,
      operatorAuthorizationRef: toOptionalText(lease?.request?.operatorAuthorizationRef),
      isolatedLaneGroupId: toOptionalText(lease?.host?.isolatedLaneGroupId),
      fingerprintSha256: toOptionalText(lease?.host?.fingerprintSha256),
      isStale: stale,
      ageSeconds: Number.isFinite(leaseAgeSeconds(lease, Date.parse(generatedAt)))
        ? Number(leaseAgeSeconds(lease, Date.parse(generatedAt)).toFixed(3))
        : null,
      ttlSeconds: lease ? resolveTtlSeconds(lease) : null,
      workingRoot: toOptionalText(lease?.commit?.workingRoot) || toOptionalText(lease?.request?.workingRoot),
      artifactRoot: toOptionalText(lease?.commit?.artifactRoot) || toOptionalText(lease?.request?.artifactRoot),
      denialReasons: [],
      observations: []
    },
    ...extras
  };
}

function buildGrantDecision(lease, executionCell) {
  const reasons = [];
  if (!executionCell?.leaseId) {
    reasons.push('execution-cell-lease-missing');
  }
  if (executionCell?.state && !['granted', 'active'].includes(executionCell.state)) {
    reasons.push('execution-cell-not-granted');
  }
  if (!isWindowsNativeTestStandPlaneBinding(executionCell?.planeBinding)) {
    reasons.push('teststand-windows-native-only');
  }
  const role = toOptionalText(lease?.request?.role);
  const suiteClass = toOptionalText(lease?.request?.suiteClass);
  const planeKey = toOptionalText(lease?.request?.planeKey);
  const processModelClass = toOptionalText(lease?.request?.processModelClass);
  const parentInstanceId = toOptionalText(lease?.request?.parentInstanceId);
  if (role === ROLE.coordinator && suiteClass !== 'dual-plane-parity') {
    reasons.push('coordinator-dual-plane-only');
  }
  if (role === ROLE.planeChild && !parentInstanceId) {
    reasons.push('plane-child-parent-required');
  }
  if (role === ROLE.planeChild && !planeKey) {
    reasons.push('plane-child-plane-key-required');
  }
  if (role === ROLE.singlePlane && processModelClass === 'parallel-process-model') {
    reasons.push('single-plane-parallel-mismatch');
  }
  if (processModelClass === 'parallel-process-model' && suiteClass !== 'dual-plane-parity') {
    reasons.push('parallel-process-model-requires-dual-plane');
  }
  return reasons;
}

function parseArgs(argv) {
  const result = {
    action: 'inspect',
    artifactPaths: []
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--action') {
      result.action = argv[++index];
    } else if (token === '--instance-id') {
      result.instanceId = argv[++index];
    } else if (token === '--execution-cell-lease-path') {
      result.executionCellLeasePath = argv[++index];
    } else if (token === '--role') {
      result.role = argv[++index];
    } else if (token === '--plane-key') {
      result.planeKey = argv[++index];
    } else if (token === '--parent-instance-id') {
      result.parentInstanceId = argv[++index];
    } else if (token === '--process-model-class') {
      result.processModelClass = argv[++index];
    } else if (token === '--harness-kind') {
      result.harnessKind = argv[++index];
    } else if (token === '--lease-id') {
      result.leaseId = argv[++index];
    } else if (token === '--ttl-seconds') {
      result.ttlSeconds = Number.parseInt(argv[++index], 10);
    } else if (token === '--grantor') {
      result.grantor = argv[++index];
    } else if (token === '--working-root') {
      result.workingRoot = argv[++index];
    } else if (token === '--artifact-root') {
      result.artifactRoot = argv[++index];
    } else if (token === '--artifact-path') {
      result.artifactPaths.push(argv[++index]);
    } else if (token === '--repo-root') {
      result.repoRoot = argv[++index];
    } else if (token === '--lease-root') {
      result.leaseRoot = argv[++index];
    } else if (token === '--output-path') {
      result.outputPath = argv[++index];
    }
  }
  return result;
}

export async function runTestStandHarnessInstanceLease(options = {}) {
  const repoRoot = path.resolve(options.repoRoot || REPO_ROOT);
  const action = toOptionalText(options.action) || 'inspect';
  const executionCellLeasePath = options.executionCellLeasePath
    ? path.resolve(repoRoot, options.executionCellLeasePath)
    : null;
  const executionCellLease = executionCellLeasePath
    ? await readJsonIfPresent(executionCellLeasePath)
    : null;
  const executionCell = buildExecutionCellContext(executionCellLeasePath, executionCellLease);
  const role = deriveRole(options.role, executionCell.suiteClass, options.planeKey);
  const harnessKind = toOptionalText(options.harnessKind) || executionCell.harnessKind || DEFAULT_HARNESS_KIND;
  const processModelClass = deriveProcessModelClass(options.processModelClass, executionCell.suiteClass);
  const instanceId = deriveInstanceId({
    requestedInstanceId: options.instanceId,
    executionCell,
    role,
    planeKey: options.planeKey,
    parentInstanceId: options.parentInstanceId,
    harnessKind
  });
  if (!instanceId) {
    throw new Error('instanceId is required');
  }

  const leaseRoot = path.resolve(options.leaseRoot || defaultLeaseRoot({ repoRoot }));
  const leasePath = leasePathForHarnessInstance(instanceId, leaseRoot);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);
  const now = options.now || new Date();
  const generatedAt = nowIso(now);

  if (action === 'request') {
    if (!executionCell.leaseId) {
      throw new Error('executionCellLeasePath is required for request');
    }
    const lease = buildRequestRecord({
      instanceId,
      executionCell,
      role,
      planeKey: options.planeKey,
      parentInstanceId: options.parentInstanceId,
      processModelClass,
      harnessKind,
      now
    });
    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, instanceId, leasePath, generatedAt, lease, {
      status: STATUS.requested
    });
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  const existing = await readJsonIfPresent(leasePath);
  if (!existing) {
    const report = buildBaseReport(action, instanceId, leasePath, generatedAt, null, {
      status: STATUS.notFound
    });
    report.summary.denialReasons.push('teststand-harness-instance-missing');
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'grant') {
    const reasons = buildGrantDecision(existing, executionCell);
    if (reasons.length > 0) {
      const report = buildBaseReport(action, instanceId, leasePath, generatedAt, existing, {
        status: STATUS.denied
      });
      report.summary.denialReasons.push(...reasons);
      await writeJsonAtomic(outputPath, report);
      return report;
    }
    const lease = {
      ...existing,
      generatedAt,
      state: 'granted',
      sequence: Number.isInteger(existing.sequence) ? existing.sequence + 1 : 2,
      heartbeatAt: generatedAt,
      grant: {
        grantedAt: generatedAt,
        grantor: toOptionalText(options.grantor) || 'teststand-harness-governor',
        leaseId: uniqueId('harness-lease', now.getTime()),
        ttlSeconds: Number.isInteger(options.ttlSeconds) ? options.ttlSeconds : DEFAULT_TTL_SECONDS
      }
    };
    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, instanceId, leasePath, generatedAt, lease, {
      status: STATUS.granted
    });
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'commit' || action === 'heartbeat') {
    const leaseId = toOptionalText(options.leaseId);
    if (leaseId && leaseId !== toOptionalText(existing?.grant?.leaseId)) {
      const report = buildBaseReport(action, instanceId, leasePath, generatedAt, existing, {
        status: STATUS.mismatch
      });
      report.summary.denialReasons.push('lease-id-mismatch');
      await writeJsonAtomic(outputPath, report);
      return report;
    }
    if (!['granted', 'active'].includes(toOptionalText(existing.state))) {
      const report = buildBaseReport(action, instanceId, leasePath, generatedAt, existing, {
        status: STATUS.invalidState
      });
      report.summary.denialReasons.push('teststand-harness-instance-not-granted');
      await writeJsonAtomic(outputPath, report);
      return report;
    }
    const lease = {
      ...existing,
      generatedAt,
      state: 'active',
      sequence: Number.isInteger(existing.sequence) ? existing.sequence + 1 : 2,
      heartbeatAt: generatedAt,
      commit: {
        committedAt: generatedAt,
        workingRoot: toOptionalText(options.workingRoot) || toOptionalText(existing?.request?.workingRoot),
        artifactRoot: toOptionalText(options.artifactRoot) || toOptionalText(existing?.request?.artifactRoot)
      }
    };
    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, instanceId, leasePath, generatedAt, lease, {
      status: action === 'commit' ? STATUS.committed : STATUS.renewed
    });
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'release') {
    const leaseId = toOptionalText(options.leaseId);
    if (leaseId && leaseId !== toOptionalText(existing?.grant?.leaseId)) {
      const report = buildBaseReport(action, instanceId, leasePath, generatedAt, existing, {
        status: STATUS.mismatch
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
        artifactPaths: (options.artifactPaths || []).map((entry) => normalizeText(entry)).filter(Boolean)
      }
    };
    await writeJsonAtomic(leasePath, lease);
    const report = buildBaseReport(action, instanceId, leasePath, generatedAt, lease, {
      status: STATUS.released
    });
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  if (action === 'inspect') {
    const stale = isTestStandHarnessInstanceLeaseStale(existing, now.getTime());
    const report = buildBaseReport(action, instanceId, leasePath, generatedAt, existing, {
      status: stale ? STATUS.stale : toOptionalText(existing.state) === 'released' ? STATUS.released : STATUS.active
    });
    await writeJsonAtomic(outputPath, report);
    return report;
  }

  throw new Error(`Unsupported action '${action}'`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const report = await runTestStandHarnessInstanceLease(options);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}

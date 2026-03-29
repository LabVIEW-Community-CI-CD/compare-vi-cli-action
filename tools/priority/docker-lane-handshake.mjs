#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { defaultOwner } from './agent-writer-lease.mjs';
import { resolveGitAdminPaths } from './lib/git-admin-paths.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const DOCKER_LANE_HANDSHAKE_SCHEMA = 'priority/docker-lane-handshake@v1';
export const DOCKER_LANE_HANDSHAKE_REPORT_SCHEMA = 'priority/docker-lane-handshake-report@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'docker-lane-handshake.json');
export const DEFAULT_HOST_PLANE_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'host-planes',
  'labview-2026-host-plane-report.json'
);
export const DEFAULT_OPERATOR_COST_PROFILE_PATH = path.join('tools', 'policy', 'operator-cost-profile.json');
export const DEFAULT_TTL_SECONDS = 1800;
export const PREMIUM_RATE_MULTIPLIER = 1.5;
export const ORDINARY_RATE_MULTIPLIER = 1.0;
export const DOCKER_LANE_CAPABILITY = 'docker-lane';
export const NATIVE_LV32_CAPABILITY = 'native-labview-2026-32';
const DEFAULT_AGENT_ID_USAGE = 'env/actor-derived lease owner';

export const STATUS = Object.freeze({
  requested: 'requested',
  granted: 'granted',
  committed: 'committed',
  released: 'released',
  renewed: 'renewed',
  active: 'active',
  busy: 'busy',
  denied: 'denied',
  notFound: 'not-found',
  mismatch: 'mismatch',
  invalidState: 'invalid-state',
  stale: 'stale'
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

function nowIso(now = new Date()) {
  return now.toISOString();
}

function uniqueId(prefix = 'id', now = Date.now()) {
  return `${prefix}-${now}-${Math.random().toString(16).slice(2, 10)}`;
}

function sanitizeLaneId(laneId) {
  return normalizeText(laneId).replace(/[^a-zA-Z0-9._-]+/g, '__');
}

function resolveDefaultHandshakeRoot(options = {}) {
  try {
    return path.join(
      resolveGitAdminPaths({
        cwd: options.repoRoot || REPO_ROOT,
        env: options.env || process.env,
        spawnSyncFn: options.spawnSyncFn || spawnSync
      }).gitCommonDir,
      'docker-lane-handshakes'
    );
  } catch {
    return path.join(options.repoRoot || REPO_ROOT, '.git', 'docker-lane-handshakes');
  }
}

export function defaultHandshakeRoot(options = {}) {
  return options.handshakeRoot || process.env.DOCKER_LANE_HANDSHAKE_ROOT || resolveDefaultHandshakeRoot(options);
}

export function handshakePathForLane(laneId, handshakeRoot = defaultHandshakeRoot()) {
  return path.join(handshakeRoot, `${sanitizeLaneId(laneId)}.json`);
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

function resolveHeartbeatTimestamp(handshake) {
  return (
    handshake?.heartbeatAt ||
    handshake?.commit?.committedAt ||
    handshake?.grant?.grantedAt ||
    handshake?.request?.requestedAt ||
    null
  );
}

function handshakeAgeSeconds(handshake, nowMs = Date.now()) {
  const timestamp = resolveHeartbeatTimestamp(handshake);
  if (!timestamp) {
    return Number.POSITIVE_INFINITY;
  }
  const parsed = Date.parse(timestamp);
  if (!Number.isFinite(parsed)) {
    return Number.POSITIVE_INFINITY;
  }
  return Math.max(0, (nowMs - parsed) / 1000);
}

function resolveTtlSeconds(handshake) {
  return Number.isInteger(handshake?.grant?.ttlSeconds) ? handshake.grant.ttlSeconds : DEFAULT_TTL_SECONDS;
}

export function isHandshakeStale(handshake, nowMs = Date.now()) {
  if (!handshake || handshake.state === 'released') {
    return false;
  }
  return handshakeAgeSeconds(handshake, nowMs) > resolveTtlSeconds(handshake);
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

function buildGrantDecision(handshake, operatorProfile) {
  const requestedCapabilities = normalizeCapabilities(handshake?.request?.capabilities);
  const premiumDualLaneRequested = handshake?.request?.premiumDualLaneRequested === true;
  const reasons = [];

  if (!requestedCapabilities.includes(DOCKER_LANE_CAPABILITY)) {
    reasons.push('docker-lane-capability-required');
  }
  if (premiumDualLaneRequested && handshake?.request?.agentClass !== 'sagan') {
    reasons.push('premium-sagan-only');
  }
  if (premiumDualLaneRequested && !toOptionalText(handshake?.request?.operatorAuthorizationRef)) {
    reasons.push('operator-authorization-required');
  }
  if (!Number.isFinite(operatorProfile?.laborRateUsdPerHour)) {
    reasons.push('operator-cost-rate-unavailable');
  }

  const billableRateMultiplier = premiumDualLaneRequested ? PREMIUM_RATE_MULTIPLIER : ORDINARY_RATE_MULTIPLIER;
  const billableRateUsdPerHour = Number.isFinite(operatorProfile?.laborRateUsdPerHour)
    ? Number((operatorProfile.laborRateUsdPerHour * billableRateMultiplier).toFixed(3))
    : null;

  return {
    allowed: reasons.length === 0,
    reasons,
    premiumDualLaneRequested,
    premiumSaganMode: premiumDualLaneRequested,
    policyDecision: premiumDualLaneRequested ? 'sagan-premium-dual-lane' : 'ordinary-docker-lane',
    grantedCapabilities: requestedCapabilities,
    billableRateMultiplier,
    billableRateUsdPerHour
  };
}

function buildBaseReport(action, laneId, handshakePath, generatedAt, handshake, extras = {}) {
  const stale = isHandshakeStale(handshake, Date.parse(generatedAt));
  return {
    schema: DOCKER_LANE_HANDSHAKE_REPORT_SCHEMA,
    generatedAt,
    action,
    laneId,
    handshakePath,
    handshake,
    summary: {
      handshakeState: handshake?.state ?? null,
      leaseId: toOptionalText(handshake?.grant?.leaseId),
      holder: toOptionalText(handshake?.request?.agentId),
      premiumSaganMode:
        handshake?.grant?.premiumSaganMode === true || handshake?.request?.premiumDualLaneRequested === true,
      billableRateMultiplier: Number.isFinite(handshake?.grant?.billableRateMultiplier)
        ? handshake.grant.billableRateMultiplier
        : null,
      billableRateUsdPerHour: Number.isFinite(handshake?.grant?.billableRateUsdPerHour)
        ? handshake.grant.billableRateUsdPerHour
        : null,
      operatorAuthorizationRef: toOptionalText(handshake?.request?.operatorAuthorizationRef),
      isolatedLaneGroupId: toOptionalText(handshake?.host?.isolatedLaneGroupId),
      fingerprintSha256: toOptionalText(handshake?.host?.fingerprintSha256),
      linkedExecutionCellId: toOptionalText(handshake?.commit?.executionCellId),
      linkedExecutionCellLeaseId: toOptionalText(handshake?.commit?.executionCellLeaseId),
      isStale: stale,
      ageSeconds: Number.isFinite(handshakeAgeSeconds(handshake, Date.parse(generatedAt)))
        ? Number(handshakeAgeSeconds(handshake, Date.parse(generatedAt)).toFixed(3))
        : null,
      ttlSeconds: handshake ? resolveTtlSeconds(handshake) : null,
      denialReasons: [],
      observations: []
    },
    ...extras
  };
}

function isWindowsNativeExecutionCellLink(linkedExecutionCell) {
  const harnessKind = normalizeText(linkedExecutionCell?.harnessKind);
  const planeBinding = normalizeText(linkedExecutionCell?.planeBinding).toLowerCase();
  if (!harnessKind || harnessKind !== 'teststand-compare-harness') {
    return false;
  }
  if (!planeBinding) {
    return true;
  }
  return planeBinding === 'dual-plane-parity' || planeBinding.startsWith('native-labview-');
}

function resolveExecutionCellLinkContext(report) {
  if (!report || typeof report !== 'object') {
    return null;
  }
  const lease = report.lease;
  if (!lease || typeof lease !== 'object') {
    return null;
  }
  return {
    cellId: toOptionalText(report?.cellId) || toOptionalText(lease?.cellId),
    leaseId: toOptionalText(report?.summary?.leaseId) || toOptionalText(lease?.grant?.leaseId),
    holder: toOptionalText(report?.summary?.holder) || toOptionalText(lease?.request?.agentId),
    isolatedLaneGroupId:
      toOptionalText(report?.summary?.isolatedLaneGroupId) || toOptionalText(lease?.host?.isolatedLaneGroupId),
    fingerprintSha256:
      toOptionalText(report?.summary?.fingerprintSha256) || toOptionalText(lease?.host?.fingerprintSha256),
    planeBinding: toOptionalText(report?.summary?.planeBinding) || toOptionalText(lease?.request?.planeBinding),
    harnessKind: toOptionalText(report?.summary?.harnessKind) || toOptionalText(lease?.request?.harnessKind)
  };
}

function validateExecutionCellLink(handshake, linkedExecutionCell) {
  if (!linkedExecutionCell) {
    return ['execution-cell-report-invalid'];
  }

  const reasons = [];
  if (!linkedExecutionCell.cellId) {
    reasons.push('execution-cell-id-missing');
  }
  if (!linkedExecutionCell.leaseId) {
    reasons.push('execution-cell-lease-id-missing');
  }
  if (!linkedExecutionCell.holder) {
    reasons.push('execution-cell-holder-missing');
  }
  if (!linkedExecutionCell.isolatedLaneGroupId || !linkedExecutionCell.fingerprintSha256) {
    reasons.push('execution-cell-host-fingerprint-missing');
  }
  if (!isWindowsNativeExecutionCellLink(linkedExecutionCell)) {
    reasons.push('execution-cell-not-windows-native-teststand');
  }

  const handshakeHolder = toOptionalText(handshake?.request?.agentId);
  if (handshakeHolder && linkedExecutionCell.holder && linkedExecutionCell.holder !== handshakeHolder) {
    reasons.push('execution-cell-owner-mismatch');
  }

  const handshakeIsolatedLaneGroupId = toOptionalText(handshake?.host?.isolatedLaneGroupId);
  const handshakeFingerprintSha256 = toOptionalText(handshake?.host?.fingerprintSha256);
  if (
    handshakeIsolatedLaneGroupId &&
    linkedExecutionCell.isolatedLaneGroupId &&
    linkedExecutionCell.isolatedLaneGroupId !== handshakeIsolatedLaneGroupId
  ) {
    reasons.push('execution-cell-isolated-lane-group-mismatch');
  }
  if (
    handshakeFingerprintSha256 &&
    linkedExecutionCell.fingerprintSha256 &&
    linkedExecutionCell.fingerprintSha256 !== handshakeFingerprintSha256
  ) {
    reasons.push('execution-cell-host-fingerprint-mismatch');
  }

  return reasons;
}

function buildRequestRecord({
  laneId,
  agentId,
  agentClass,
  capabilities,
  operatorId,
  operatorAuthorizationRef,
  hostContext,
  now,
  requestId
}) {
  const requestedCapabilities = normalizeCapabilities(capabilities);
  const generatedAt = nowIso(now);
  return {
    schema: DOCKER_LANE_HANDSHAKE_SCHEMA,
    generatedAt,
    laneId,
    resourceKind: DOCKER_LANE_CAPABILITY,
    state: 'requested',
    sequence: 1,
    heartbeatAt: generatedAt,
    host: hostContext,
    request: {
      requestId,
      requestedAt: generatedAt,
      agentId,
      agentClass,
      capabilities: requestedCapabilities,
      premiumDualLaneRequested: isPremiumDualLaneRequest(requestedCapabilities),
      operatorId: toOptionalText(operatorId),
      operatorAuthorizationRef: toOptionalText(operatorAuthorizationRef)
    },
    grant: null,
    commit: null,
    release: null
  };
}

function cloneForTransition(handshake, now) {
  return {
    ...handshake,
    generatedAt: nowIso(now),
    sequence: Number.isInteger(handshake?.sequence) ? handshake.sequence + 1 : 1
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/docker-lane-handshake.mjs --action <request|grant|commit|heartbeat|release|inspect> --lane-id <id> [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --output <path>                    Report output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --lane-id <id>                     Logical isolated Docker lane id.');
  console.log('  --action <name>                    Handshake action (request|grant|commit|heartbeat|release|inspect).');
  console.log(`  --agent-id <id>                    Request owner (default: ${DEFAULT_AGENT_ID_USAGE}).`);
  console.log('  --agent-class <sagan|subagent|other> Agent class (default: subagent).');
  console.log(`  --host-plane-report <path>         Host-plane report path (default: ${DEFAULT_HOST_PLANE_REPORT_PATH}).`);
  console.log(`  --operator-cost-profile <path>     Operator cost profile path (default: ${DEFAULT_OPERATOR_COST_PROFILE_PATH}).`);
  console.log('  --operator-id <id>                 Operator id for billable-rate resolution.');
  console.log('  --operator-authorization-ref <ref> Authorization receipt/reference for premium Sagan mode.');
  console.log(`  --ttl-seconds <n>                  Grant TTL in seconds (default: ${DEFAULT_TTL_SECONDS}).`);
  console.log('  --grantor <id>                     Grantor id recorded on grant (default: sagan-governor).');
  console.log('  --lease-id <id>                    Lease id matcher for commit/heartbeat/release.');
  console.log('  --execution-cell-report <path>     Execution-cell report used to bind a committed Docker lane to a cell.');
  console.log('  --capability <name>                Requested capability (repeatable).');
  console.log(`  --premium-dual-lane                Shortcut for ${DOCKER_LANE_CAPABILITY} + ${NATIVE_LV32_CAPABILITY}.`);
  console.log('  --final-status <status>            Release final status (default: succeeded).');
  console.log('  --artifact-path <path>             Artifact path to attach on release (repeatable).');
  console.log('  --handshake-root <path>            Override handshake state directory.');
  console.log('  --help                             Show this help text and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    action: '',
    laneId: '',
    outputPath: DEFAULT_OUTPUT_PATH,
    agentId: defaultOwner(),
    agentClass: 'subagent',
    hostPlaneReportPath: DEFAULT_HOST_PLANE_REPORT_PATH,
    operatorCostProfilePath: DEFAULT_OPERATOR_COST_PROFILE_PATH,
    operatorId: '',
    operatorAuthorizationRef: '',
    ttlSeconds: DEFAULT_TTL_SECONDS,
    grantor: 'sagan-governor',
    leaseId: '',
    capabilities: [],
    premiumDualLane: false,
    finalStatus: 'succeeded',
    artifactPaths: [],
    handshakeRoot: '',
    executionCellReportPath: '',
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    if (token === '--premium-dual-lane') {
      options.premiumDualLane = true;
      continue;
    }

    if (
      token === '--action' ||
      token === '--lane-id' ||
      token === '--output' ||
      token === '--agent-id' ||
      token === '--agent-class' ||
      token === '--host-plane-report' ||
      token === '--operator-cost-profile' ||
      token === '--operator-id' ||
      token === '--operator-authorization-ref' ||
      token === '--ttl-seconds' ||
      token === '--grantor' ||
      token === '--lease-id' ||
      token === '--execution-cell-report' ||
      token === '--final-status' ||
      token === '--handshake-root'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--action') options.action = next;
      if (token === '--lane-id') options.laneId = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--agent-id') options.agentId = next;
      if (token === '--agent-class') options.agentClass = normalizeAgentClass(next);
      if (token === '--host-plane-report') options.hostPlaneReportPath = next;
      if (token === '--operator-cost-profile') options.operatorCostProfilePath = next;
      if (token === '--operator-id') options.operatorId = next;
      if (token === '--operator-authorization-ref') options.operatorAuthorizationRef = next;
      if (token === '--ttl-seconds') {
        const ttl = Number.parseInt(next, 10);
        if (!Number.isInteger(ttl) || ttl <= 0) {
          throw new Error(`Invalid --ttl-seconds value '${next}'.`);
        }
        options.ttlSeconds = ttl;
      }
      if (token === '--grantor') options.grantor = next;
      if (token === '--lease-id') options.leaseId = next;
      if (token === '--execution-cell-report') options.executionCellReportPath = next;
      if (token === '--final-status') options.finalStatus = next;
      if (token === '--handshake-root') options.handshakeRoot = next;
      continue;
    }

    if (token === '--capability' || token === '--artifact-path') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--capability') options.capabilities.push(next);
      if (token === '--artifact-path') options.artifactPaths.push(next);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.premiumDualLane) {
    options.capabilities.push(DOCKER_LANE_CAPABILITY, NATIVE_LV32_CAPABILITY);
  }
  options.capabilities = normalizeCapabilities(options.capabilities);

  return options;
}

async function writeReport(outputPath, report, repoRoot = process.cwd()) {
  const resolved = path.resolve(repoRoot, outputPath);
  await ensureParentDir(resolved);
  await fs.writeFile(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

function withObservations(report, observations = []) {
  return {
    ...report,
    summary: {
      ...report.summary,
      observations: [...report.summary.observations, ...observations.filter(Boolean)]
    }
  };
}

function withDenialReasons(report, reasons = []) {
  return {
    ...report,
    summary: {
      ...report.summary,
      denialReasons: [...report.summary.denialReasons, ...reasons.filter(Boolean)]
    }
  };
}

export async function runDockerLaneHandshake(options = {}) {
  const action = normalizeText(options.action).toLowerCase();
  const laneId = normalizeText(options.laneId);
  const repoRoot = options.repoRoot || REPO_ROOT;
  const agentId = toOptionalText(options.agentId) || defaultOwner();
  const agentClass = normalizeAgentClass(options.agentClass);
  const handshakeRoot = defaultHandshakeRoot({ repoRoot, handshakeRoot: options.handshakeRoot });
  const handshakePath = handshakePathForLane(laneId, handshakeRoot);
  const generatedAt = nowIso(options.now || new Date());
  const current = await readJsonIfPresent(handshakePath);
  const hostPlaneReport = options.hostPlaneReport ?? (await readJsonIfPresent(path.resolve(repoRoot, options.hostPlaneReportPath || DEFAULT_HOST_PLANE_REPORT_PATH)));
  const operatorCostProfile =
    options.operatorCostProfile ?? (await readJsonIfPresent(path.resolve(repoRoot, options.operatorCostProfilePath || DEFAULT_OPERATOR_COST_PROFILE_PATH)));
  const { context: hostContext, observations: hostObservations } = buildHostContext(hostPlaneReport);
  const operatorProfile = resolveOperatorProfile(operatorCostProfile, options.operatorId);
  const base = buildBaseReport(action, laneId, handshakePath, generatedAt, current, {
    policy: {
      operatorId: operatorProfile.operatorId,
      currency: operatorProfile.currency,
      laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour,
      premiumSaganRateMultiplier: PREMIUM_RATE_MULTIPLIER
    }
  });
  const reportWithHost = withObservations(base, hostObservations);

  if (!laneId) {
    return withDenialReasons({ ...reportWithHost, status: STATUS.invalidState }, ['lane-id-required']);
  }

  if (!['request', 'grant', 'commit', 'heartbeat', 'release', 'inspect'].includes(action)) {
    return withDenialReasons({ ...reportWithHost, status: STATUS.invalidState }, ['action-invalid']);
  }

  if (action === 'inspect') {
    if (!current) {
      return { ...reportWithHost, status: STATUS.notFound, handshake: null };
    }
    return { ...reportWithHost, status: isHandshakeStale(current, Date.parse(generatedAt)) ? STATUS.stale : STATUS.active };
  }

  if (action === 'request') {
    if (current && current.state !== 'released') {
      const status = isHandshakeStale(current, Date.parse(generatedAt)) ? STATUS.stale : STATUS.busy;
      return withDenialReasons({ ...reportWithHost, status }, [status === STATUS.stale ? 'stale-handshake-present' : 'lane-already-held']);
    }
    if (normalizeCapabilities(options.capabilities).length === 0) {
      return withDenialReasons({ ...reportWithHost, status: STATUS.denied }, ['capabilities-required']);
    }

    const next = buildRequestRecord({
      laneId,
      agentId,
      agentClass,
      capabilities: options.capabilities,
      operatorId: options.operatorId || operatorProfile.operatorId,
      operatorAuthorizationRef: options.operatorAuthorizationRef,
      hostContext,
      now: options.now || new Date(),
      requestId: options.requestId || uniqueId('request', Date.parse(generatedAt))
    });
    await writeJsonAtomic(handshakePath, next);
    return buildResultReport(action, laneId, handshakePath, generatedAt, next, operatorProfile, hostObservations, STATUS.requested);
  }

  if (!current) {
    return { ...reportWithHost, status: STATUS.notFound, handshake: null };
  }

  const sameAgent = normalizeText(current?.request?.agentId) === agentId;
  if (!sameAgent) {
    return withDenialReasons({ ...reportWithHost, status: STATUS.mismatch }, ['request-owner-mismatch']);
  }

  if (action === 'grant') {
    if (current.state !== 'requested') {
      return withDenialReasons({ ...reportWithHost, status: STATUS.invalidState }, ['grant-requires-requested-state']);
    }
    const decision = buildGrantDecision(current, operatorProfile);
    if (!decision.allowed) {
      return withDenialReasons({ ...reportWithHost, status: STATUS.denied }, decision.reasons);
    }

    const next = cloneForTransition(current, options.now || new Date());
    next.state = 'granted';
    next.heartbeatAt = generatedAt;
    next.host = hostContext || current.host || null;
    next.grant = {
      grantedAt: generatedAt,
      grantor: toOptionalText(options.grantor) || 'sagan-governor',
      leaseId: options.leaseId || uniqueId('lease', Date.parse(generatedAt)),
      ttlSeconds: Number.isInteger(options.ttlSeconds) ? options.ttlSeconds : DEFAULT_TTL_SECONDS,
      grantedCapabilities: decision.grantedCapabilities,
      billableRateMultiplier: decision.billableRateMultiplier,
      billableRateUsdPerHour: decision.billableRateUsdPerHour,
      premiumSaganMode: decision.premiumSaganMode,
      policyDecision: decision.policyDecision,
      operatorAuthorizationRef: toOptionalText(current.request.operatorAuthorizationRef)
    };
    await writeJsonAtomic(handshakePath, next);
    return buildResultReport(action, laneId, handshakePath, generatedAt, next, operatorProfile, hostObservations, STATUS.granted);
  }

  const leaseId = toOptionalText(options.leaseId);
  const leaseIdMatches = !leaseId || normalizeText(current?.grant?.leaseId) === leaseId;
  if (!leaseIdMatches) {
    return withDenialReasons({ ...reportWithHost, status: STATUS.mismatch }, ['lease-id-mismatch']);
  }

  if (action === 'commit') {
    if (current.state !== 'granted') {
      return withDenialReasons({ ...reportWithHost, status: STATUS.invalidState }, ['commit-requires-granted-state']);
    }

    let linkedExecutionCell = null;
    if (toOptionalText(options.executionCellReportPath)) {
      linkedExecutionCell = resolveExecutionCellLinkContext(
        await readJsonIfPresent(path.resolve(repoRoot, options.executionCellReportPath))
      );
      const linkReasons = validateExecutionCellLink(current, linkedExecutionCell);
      if (linkReasons.length > 0) {
        return withDenialReasons({ ...reportWithHost, status: STATUS.mismatch }, linkReasons);
      }
    }

    const next = cloneForTransition(current, options.now || new Date());
    next.state = 'active';
    next.heartbeatAt = generatedAt;
    next.commit = {
      committedAt: generatedAt,
      executionCellId: linkedExecutionCell?.cellId || toOptionalText(current?.commit?.executionCellId),
      executionCellLeaseId: linkedExecutionCell?.leaseId || toOptionalText(current?.commit?.executionCellLeaseId)
    };
    await writeJsonAtomic(handshakePath, next);
    const report = buildResultReport(
      action,
      laneId,
      handshakePath,
      generatedAt,
      next,
      operatorProfile,
      hostObservations,
      STATUS.committed
    );
    if (linkedExecutionCell?.cellId) {
      report.summary.observations.push('linked-execution-cell-commit');
    }
    return report;
  }

  if (action === 'heartbeat') {
    if (current.state !== 'active') {
      return withDenialReasons({ ...reportWithHost, status: STATUS.invalidState }, ['heartbeat-requires-active-state']);
    }
    const next = cloneForTransition(current, options.now || new Date());
    next.heartbeatAt = generatedAt;
    await writeJsonAtomic(handshakePath, next);
    return buildResultReport(action, laneId, handshakePath, generatedAt, next, operatorProfile, hostObservations, STATUS.renewed);
  }

  if (action === 'release') {
    if (!['requested', 'granted', 'active'].includes(current.state)) {
      return withDenialReasons({ ...reportWithHost, status: STATUS.invalidState }, ['release-requires-live-state']);
    }
    const next = cloneForTransition(current, options.now || new Date());
    next.state = 'released';
    next.heartbeatAt = generatedAt;
    next.release = {
      releasedAt: generatedAt,
      finalStatus: toOptionalText(options.finalStatus) || 'succeeded',
      artifactPaths: normalizeCapabilities(options.artifactPaths)
    };
    await writeJsonAtomic(handshakePath, next);
    return buildResultReport(action, laneId, handshakePath, generatedAt, next, operatorProfile, hostObservations, STATUS.released);
  }

  return withDenialReasons({ ...reportWithHost, status: STATUS.invalidState }, ['action-unhandled']);
}

function exitCodeForStatus(status) {
  if ([STATUS.requested, STATUS.granted, STATUS.committed, STATUS.released, STATUS.renewed, STATUS.active].includes(status)) {
    return 0;
  }
  if (status === STATUS.notFound) {
    return 0;
  }
  return 1;
}

function buildResultReport(action, laneId, handshakePath, generatedAt, handshake, operatorProfile, hostObservations, status) {
  const base = buildBaseReport(action, laneId, handshakePath, generatedAt, handshake, {
    policy: {
      operatorId: operatorProfile.operatorId,
      currency: operatorProfile.currency,
      laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour,
      premiumSaganRateMultiplier: PREMIUM_RATE_MULTIPLIER
    }
  });
  return {
    ...withObservations(base, hostObservations),
    status,
    handshake
  };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const report = await runDockerLaneHandshake({
    ...options,
    repoRoot: process.cwd()
  });
  const outputPath = await writeReport(options.outputPath, report, process.cwd());
  console.log(
    `[docker-lane-handshake] report: ${outputPath} status=${report.status} lane=${report.laneId} state=${report.summary.handshakeState ?? 'none'}`
  );
  return exitCodeForStatus(report.status);
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

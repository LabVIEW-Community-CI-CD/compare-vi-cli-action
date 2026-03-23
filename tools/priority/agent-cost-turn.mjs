#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/agent-cost-turn@v1';
export const DEFAULT_OUTPUT_DIR = path.join('tests', 'results', '_agent', 'cost', 'turns');
export const DEFAULT_OPERATOR_COST_PROFILE_PATH = path.join('tools', 'policy', 'operator-cost-profile.json');
export const REASONING_EFFORTS = new Set(['low', 'medium', 'high', 'xhigh']);
const TIMING_SOURCE_CANDIDATE_FIELDS = [
  { path: ['elapsedSeconds'], divisor: 1 },
  { path: ['elapsedMilliseconds'], divisor: 1000 },
  { path: ['durationSeconds'], divisor: 1 },
  { path: ['durationMs'], divisor: 1000 },
  { path: ['metrics', 'elapsedSeconds'], divisor: 1 },
  { path: ['metrics', 'elapsedMilliseconds'], divisor: 1000 },
  { path: ['metrics', 'durationSeconds'], divisor: 1 },
  { path: ['metrics', 'durationMs'], divisor: 1000 },
  { path: ['timings', 'elapsedSeconds'], divisor: 1 },
  { path: ['timings', 'elapsedMilliseconds'], divisor: 1000 },
  { path: ['summary', 'durationSeconds'], divisor: 1 },
  { path: ['summary', 'durationMs'], divisor: 1000 },
  { path: ['cli', 'duration_s'], divisor: 1 }
];
const TIMING_START_CANDIDATE_FIELDS = [
  ['startedAt'],
  ['startTime'],
  ['metrics', 'startedAt'],
  ['timings', 'startedAt']
];
const TIMING_END_CANDIDATE_FIELDS = [
  ['endedAt'],
  ['endTime'],
  ['metrics', 'endedAt'],
  ['timings', 'endedAt']
];

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toNonNegativeInteger(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function toNonNegativeNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function normalizeDateTime(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? normalized : null;
}

function roundNumber(value, precision = 6) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return Number(parsed.toFixed(precision));
}

function normalizeReasoningEffort(value) {
  const normalized = normalizeText(value).toLowerCase();
  return REASONING_EFFORTS.has(normalized) ? normalized : null;
}

function sanitizeFileSegment(value, fallback) {
  const normalized = normalizeText(value).replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  return normalized || fallback;
}

function looksLikeLaneBranch(value) {
  const normalized = normalizeText(value);
  return normalized.length > 0 && normalized !== 'HEAD' && normalized.includes('/') && !/\s/.test(normalized);
}

function readJsonIfExists(filePath) {
  const normalizedPath = normalizeText(filePath);
  if (!normalizedPath) {
    return null;
  }
  const resolvedPath = path.resolve(normalizedPath);
  if (!fs.existsSync(resolvedPath)) {
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
  } catch {
    return null;
  }
}

function safeRelative(targetPath) {
  if (!normalizeText(targetPath)) {
    return null;
  }
  return path.relative(process.cwd(), path.resolve(targetPath)).replace(/\\/g, '/');
}

function getPathValue(payload, pathSegments) {
  let current = payload;
  for (const segment of pathSegments) {
    if (!current || typeof current !== 'object' || !(segment in current)) {
      return null;
    }
    current = current[segment];
  }
  return current;
}

function inferLaneBranchFromPayload(payload) {
  const candidatePaths = [
    ['context', 'laneBranch'],
    ['laneBranch'],
    ['pullRequest', 'headRefName'],
    ['pullRequest', 'branch'],
    ['activePullRequest', 'headRefName'],
    ['taskPacket', 'laneBranch'],
    ['taskPacket', 'pullRequest', 'headRefName'],
    ['headRefName'],
    ['headRef'],
    ['branch']
  ];

  for (const candidatePath of candidatePaths) {
    const candidate = normalizeText(getPathValue(payload, candidatePath));
    if (looksLikeLaneBranch(candidate)) {
      return candidate;
    }
  }

  return null;
}

function inferElapsedSecondsFromPayload(payload) {
  for (const candidate of TIMING_SOURCE_CANDIDATE_FIELDS) {
    const rawValue = getPathValue(payload, candidate.path);
    const normalized = toNonNegativeNumber(rawValue);
    if (normalized != null) {
      return roundNumber(normalized / candidate.divisor);
    }
  }
  return null;
}

function inferDateTimeFromPayload(payload, candidatePaths) {
  for (const candidatePath of candidatePaths) {
    const candidate = normalizeDateTime(getPathValue(payload, candidatePath));
    if (candidate) {
      return candidate;
    }
  }
  return null;
}

function inferCurrentGitBranch(spawnSyncFn = spawnSync) {
  try {
    const result = spawnSyncFn('git', ['branch', '--show-current'], {
      cwd: process.cwd(),
      encoding: 'utf8'
    });
    if ((result?.status ?? 1) !== 0) {
      return null;
    }
    const branch = normalizeText(result?.stdout);
    return looksLikeLaneBranch(branch) ? branch : null;
  } catch {
    return null;
  }
}

function resolveLaneBranch(options, { readJsonFn = readJsonIfExists, inferCurrentGitBranchFn = inferCurrentGitBranch } = {}) {
  const explicitLaneBranch = normalizeText(options.laneBranch);
  if (explicitLaneBranch) {
    return explicitLaneBranch;
  }

  for (const candidatePath of [options.sourceReceiptPath, options.sourceReportPath]) {
    const payload = readJsonFn(candidatePath);
    const inferredFromPayload = inferLaneBranchFromPayload(payload);
    if (inferredFromPayload) {
      return inferredFromPayload;
    }
  }

  const laneIdAsBranch = normalizeText(options.laneId);
  if (looksLikeLaneBranch(laneIdAsBranch)) {
    return laneIdAsBranch;
  }

  return inferCurrentGitBranchFn();
}

function resolveRuntimeTiming(options, { readJsonFn = readJsonIfExists } = {}) {
  const explicitStartedAt = normalizeDateTime(options.startedAt);
  const explicitEndedAt = normalizeDateTime(options.endedAt);
  const explicitElapsedSeconds = toNonNegativeNumber(options.elapsedSeconds);

  if (explicitElapsedSeconds != null) {
    return {
      startedAt: explicitStartedAt,
      endedAt: explicitEndedAt,
      elapsedSeconds: roundNumber(explicitElapsedSeconds),
      elapsedSource: 'explicit'
    };
  }

  if (explicitStartedAt && explicitEndedAt) {
    return {
      startedAt: explicitStartedAt,
      endedAt: explicitEndedAt,
      elapsedSeconds: roundNumber((Date.parse(explicitEndedAt) - Date.parse(explicitStartedAt)) / 1000),
      elapsedSource: 'derived-start-end'
    };
  }

  for (const candidate of [
    { filePath: options.sourceReceiptPath, source: 'source-receipt' },
    { filePath: options.sourceReportPath, source: 'source-report' }
  ]) {
    const payload = readJsonFn(candidate.filePath);
    if (!payload) {
      continue;
    }
    const elapsedSeconds = inferElapsedSecondsFromPayload(payload);
    const startedAt = inferDateTimeFromPayload(payload, TIMING_START_CANDIDATE_FIELDS);
    const endedAt = inferDateTimeFromPayload(payload, TIMING_END_CANDIDATE_FIELDS);
    if (elapsedSeconds != null || (startedAt && endedAt)) {
      return {
        startedAt,
        endedAt,
        elapsedSeconds: elapsedSeconds ?? roundNumber((Date.parse(endedAt) - Date.parse(startedAt)) / 1000),
        elapsedSource: candidate.source
      };
    }
  }

  return {
    startedAt: explicitStartedAt,
    endedAt: explicitEndedAt,
    elapsedSeconds: null,
    elapsedSource: null
  };
}

function resolveOperatorProfile(options, { readJsonFn = readJsonIfExists } = {}) {
  const configuredProfilePath = normalizeText(options.operatorCostProfilePath) || DEFAULT_OPERATOR_COST_PROFILE_PATH;
  const payload = readJsonFn(configuredProfilePath);
  if (!payload || payload.schema !== 'priority/operator-cost-profile@v1') {
    return {
      operatorProfilePath: safeRelative(configuredProfilePath) ?? configuredProfilePath,
      operatorId: normalizeText(options.operatorId) || null,
      operatorName: null,
      laborRateUsdPerHour: null,
      currency: 'USD',
      pricingBasis: 'agent-runtime-hour',
      status: 'missing-operator-profile'
    };
  }

  const selectedOperatorId = normalizeText(options.operatorId) || normalizeText(payload.defaultOperatorId);
  const selectedOperator = Array.isArray(payload.operators)
    ? payload.operators.find((entry) => normalizeText(entry?.id) === selectedOperatorId)
    : null;
  if (!selectedOperator || selectedOperator.active !== true || selectedOperator.appliesToAgentRuntime !== true) {
    return {
      operatorProfilePath: safeRelative(configuredProfilePath) ?? configuredProfilePath,
      operatorId: selectedOperatorId || null,
      operatorName: null,
      laborRateUsdPerHour: null,
      currency: normalizeText(payload.currency) || 'USD',
      pricingBasis: 'agent-runtime-hour',
      status: 'missing-operator-profile'
    };
  }

  return {
    operatorProfilePath: safeRelative(configuredProfilePath) ?? configuredProfilePath,
    operatorId: normalizeText(selectedOperator.id),
    operatorName: normalizeText(selectedOperator.displayName),
    laborRateUsdPerHour: toNonNegativeNumber(selectedOperator.laborRateUsdPerHour),
    currency: normalizeText(payload.currency) || 'USD',
    pricingBasis: normalizeText(selectedOperator.pricingBasis) || 'agent-runtime-hour',
    status: 'configured'
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    providerId: null,
    providerKind: null,
    providerRuntime: null,
    executionPlane: null,
    requestedModel: null,
    effectiveModel: null,
    requestedReasoningEffort: null,
    effectiveReasoningEffort: null,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    totalTokens: null,
    usageUnitKind: null,
    usageUnitCount: 1,
    exactness: 'estimated',
    amountUsd: null,
    rateCardId: null,
    rateCardSource: null,
    rateCardRetrievedAt: null,
    pricingBasis: null,
    inputUsdPer1kTokens: null,
    cachedInputUsdPer1kTokens: null,
    outputUsdPer1kTokens: null,
    usageUnitUsd: null,
    repository: null,
    issueNumber: null,
    laneId: null,
    laneBranch: null,
    sessionId: null,
    turnId: null,
    workerSlotId: null,
    agentRole: null,
    sourceSchema: null,
    sourceReceiptPath: null,
    sourceReportPath: null,
    usageObservedAt: null,
    operatorCostProfilePath: DEFAULT_OPERATOR_COST_PROFILE_PATH,
    operatorId: null,
    startedAt: null,
    endedAt: null,
    elapsedSeconds: null,
    operatorSteered: false,
    operatorSteeringKind: null,
    operatorSteeringSource: null,
    operatorSteeringObservedAt: null,
    operatorSteeringNote: null,
    steeringInvoiceTurnId: null,
    outputPath: null,
    help: false
  };

  const tokensWithValue = new Set([
    '--provider-id',
    '--provider-kind',
    '--provider-runtime',
    '--execution-plane',
    '--requested-model',
    '--effective-model',
    '--requested-reasoning-effort',
    '--effective-reasoning-effort',
    '--input-tokens',
    '--cached-input-tokens',
    '--output-tokens',
    '--total-tokens',
    '--usage-unit-kind',
    '--usage-unit-count',
    '--exactness',
    '--amount-usd',
    '--rate-card-id',
    '--rate-card-source',
    '--rate-card-retrieved-at',
    '--pricing-basis',
    '--input-usd-per-1k-tokens',
    '--cached-input-usd-per-1k-tokens',
    '--output-usd-per-1k-tokens',
    '--usage-unit-usd',
    '--repository',
    '--issue-number',
    '--lane-id',
    '--lane-branch',
    '--session-id',
    '--turn-id',
    '--worker-slot-id',
    '--agent-role',
    '--source-schema',
    '--source-receipt-path',
    '--source-report-path',
    '--usage-observed-at',
    '--operator-cost-profile',
    '--operator-id',
    '--started-at',
    '--ended-at',
    '--elapsed-seconds',
    '--operator-steering-kind',
    '--operator-steering-source',
    '--operator-steering-observed-at',
    '--operator-steering-note',
    '--steering-invoice-turn-id',
    '--output'
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--operator-steered') {
      options.operatorSteered = true;
      continue;
    }
    if (tokensWithValue.has(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      switch (token) {
        case '--provider-id': options.providerId = next; break;
        case '--provider-kind': options.providerKind = next; break;
        case '--provider-runtime': options.providerRuntime = next; break;
        case '--execution-plane': options.executionPlane = next; break;
        case '--requested-model': options.requestedModel = next; break;
        case '--effective-model': options.effectiveModel = next; break;
        case '--requested-reasoning-effort': options.requestedReasoningEffort = next; break;
        case '--effective-reasoning-effort': options.effectiveReasoningEffort = next; break;
        case '--input-tokens': options.inputTokens = next; break;
        case '--cached-input-tokens': options.cachedInputTokens = next; break;
        case '--output-tokens': options.outputTokens = next; break;
        case '--total-tokens': options.totalTokens = next; break;
        case '--usage-unit-kind': options.usageUnitKind = next; break;
        case '--usage-unit-count': options.usageUnitCount = next; break;
        case '--exactness': options.exactness = next; break;
        case '--amount-usd': options.amountUsd = next; break;
        case '--rate-card-id': options.rateCardId = next; break;
        case '--rate-card-source': options.rateCardSource = next; break;
        case '--rate-card-retrieved-at': options.rateCardRetrievedAt = next; break;
        case '--pricing-basis': options.pricingBasis = next; break;
        case '--input-usd-per-1k-tokens': options.inputUsdPer1kTokens = next; break;
        case '--cached-input-usd-per-1k-tokens': options.cachedInputUsdPer1kTokens = next; break;
        case '--output-usd-per-1k-tokens': options.outputUsdPer1kTokens = next; break;
        case '--usage-unit-usd': options.usageUnitUsd = next; break;
        case '--repository': options.repository = next; break;
        case '--issue-number': options.issueNumber = next; break;
        case '--lane-id': options.laneId = next; break;
        case '--lane-branch': options.laneBranch = next; break;
        case '--session-id': options.sessionId = next; break;
        case '--turn-id': options.turnId = next; break;
        case '--worker-slot-id': options.workerSlotId = next; break;
        case '--agent-role': options.agentRole = next; break;
        case '--source-schema': options.sourceSchema = next; break;
        case '--source-receipt-path': options.sourceReceiptPath = next; break;
        case '--source-report-path': options.sourceReportPath = next; break;
        case '--usage-observed-at': options.usageObservedAt = next; break;
        case '--operator-cost-profile': options.operatorCostProfilePath = next; break;
        case '--operator-id': options.operatorId = next; break;
        case '--started-at': options.startedAt = next; break;
        case '--ended-at': options.endedAt = next; break;
        case '--elapsed-seconds': options.elapsedSeconds = next; break;
        case '--operator-steering-kind': options.operatorSteeringKind = next; break;
        case '--operator-steering-source': options.operatorSteeringSource = next; break;
        case '--operator-steering-observed-at': options.operatorSteeringObservedAt = next; break;
        case '--operator-steering-note': options.operatorSteeringNote = next; break;
        case '--steering-invoice-turn-id': options.steeringInvoiceTurnId = next; break;
        case '--output': options.outputPath = next; break;
        default: break;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (options.help) {
    return options;
  }

  for (const [field, label] of [
    ['providerId', '--provider-id'],
    ['providerKind', '--provider-kind'],
    ['providerRuntime', '--provider-runtime'],
    ['executionPlane', '--execution-plane'],
    ['requestedModel', '--requested-model'],
    ['repository', '--repository'],
    ['laneId', '--lane-id'],
    ['sessionId', '--session-id'],
    ['turnId', '--turn-id'],
    ['agentRole', '--agent-role'],
    ['sourceSchema', '--source-schema'],
    ['usageObservedAt', '--usage-observed-at']
  ]) {
    if (!normalizeText(options[field])) {
      throw new Error(`Missing required option: ${label} <value>.`);
    }
  }

  options.issueNumber = toNonNegativeInteger(options.issueNumber);
  if (options.issueNumber == null) {
    throw new Error('Missing required option: --issue-number <integer>.');
  }

  options.inputTokens = toNonNegativeInteger(options.inputTokens) ?? 0;
  options.cachedInputTokens = toNonNegativeInteger(options.cachedInputTokens) ?? 0;
  options.outputTokens = toNonNegativeInteger(options.outputTokens) ?? 0;
  options.totalTokens = toNonNegativeInteger(options.totalTokens);
  options.usageUnitCount = toNonNegativeNumber(options.usageUnitCount) ?? 1;
  options.amountUsd = toNonNegativeNumber(options.amountUsd);
  options.elapsedSeconds = toNonNegativeNumber(options.elapsedSeconds);
  options.inputUsdPer1kTokens = toNonNegativeNumber(options.inputUsdPer1kTokens);
  options.cachedInputUsdPer1kTokens = toNonNegativeNumber(options.cachedInputUsdPer1kTokens);
  options.outputUsdPer1kTokens = toNonNegativeNumber(options.outputUsdPer1kTokens);
  options.usageUnitUsd = toNonNegativeNumber(options.usageUnitUsd);

  if (!['exact', 'estimated'].includes(normalizeText(options.exactness).toLowerCase())) {
    throw new Error('exactness must be exact or estimated.');
  }
  if (!['live', 'background'].includes(normalizeText(options.agentRole).toLowerCase())) {
    throw new Error('agent-role must be live or background.');
  }

  options.effectiveModel = normalizeText(options.effectiveModel) || normalizeText(options.requestedModel);
  options.requestedReasoningEffort = normalizeReasoningEffort(options.requestedReasoningEffort);
  options.effectiveReasoningEffort =
    normalizeReasoningEffort(options.effectiveReasoningEffort) ??
    normalizeReasoningEffort(options.requestedReasoningEffort);

  if (normalizeText(options.requestedReasoningEffort) && !options.requestedReasoningEffort) {
    throw new Error('requested-reasoning-effort must be one of: low, medium, high, xhigh.');
  }
  if (normalizeText(options.effectiveReasoningEffort) && !options.effectiveReasoningEffort) {
    throw new Error('effective-reasoning-effort must be one of: low, medium, high, xhigh.');
  }

  return options;
}

export function buildAgentCostTurn(options, now = new Date(), helpers = {}) {
  const { readJsonFn = readJsonIfExists } = helpers;
  const normalizedRequestedModel = normalizeText(options.requestedModel);
  const normalizedEffectiveModel = normalizeText(options.effectiveModel) || normalizedRequestedModel;
  const normalizedRequestedReasoningEffort = normalizeReasoningEffort(options.requestedReasoningEffort);
  const normalizedEffectiveReasoningEffort =
    normalizeReasoningEffort(options.effectiveReasoningEffort) ?? normalizedRequestedReasoningEffort;
  const normalizedInputTokens = toNonNegativeInteger(options.inputTokens) ?? 0;
  const normalizedCachedInputTokens = toNonNegativeInteger(options.cachedInputTokens) ?? 0;
  const normalizedOutputTokens = toNonNegativeInteger(options.outputTokens) ?? 0;
  const normalizedTotalTokens =
    toNonNegativeInteger(options.totalTokens) ??
    (normalizedInputTokens + normalizedCachedInputTokens + normalizedOutputTokens);
  const normalizedUsageUnitCount = toNonNegativeNumber(options.usageUnitCount) ?? 1;
  const normalizedAmountUsd = toNonNegativeNumber(options.amountUsd);
  const normalizedInputUsdPer1kTokens = toNonNegativeNumber(options.inputUsdPer1kTokens);
  const normalizedCachedInputUsdPer1kTokens = toNonNegativeNumber(options.cachedInputUsdPer1kTokens);
  const normalizedOutputUsdPer1kTokens = toNonNegativeNumber(options.outputUsdPer1kTokens);
  const normalizedUsageUnitUsd = toNonNegativeNumber(options.usageUnitUsd);
  const normalizedExactness = normalizeText(options.exactness).toLowerCase() || 'estimated';
  const outputPath =
    normalizeText(options.outputPath) ||
    path.join(
      DEFAULT_OUTPUT_DIR,
      `${sanitizeFileSegment(options.sessionId, 'session')}--${sanitizeFileSegment(options.turnId, 'turn')}.json`
    );
  const normalizedOperatorSteeringKind = normalizeText(options.operatorSteeringKind) || null;
  const normalizedOperatorSteeringSource = normalizeText(options.operatorSteeringSource) || null;
  const normalizedOperatorSteeringObservedAt = normalizeText(options.operatorSteeringObservedAt) || null;
  const normalizedOperatorSteeringNote = normalizeText(options.operatorSteeringNote) || null;
  const normalizedSteeringInvoiceTurnId = normalizeText(options.steeringInvoiceTurnId) || null;
  const normalizedLaneBranch = resolveLaneBranch(options, helpers);
  const runtimeTiming = resolveRuntimeTiming(options, { readJsonFn });
  const operatorProfile = resolveOperatorProfile(options, { readJsonFn });
  const normalizedOperatorSteered =
    Boolean(options.operatorSteered) ||
    normalizedOperatorSteeringKind !== null ||
    normalizedOperatorSteeringSource !== null ||
    normalizedOperatorSteeringObservedAt !== null ||
    normalizedOperatorSteeringNote !== null ||
    normalizedSteeringInvoiceTurnId !== null;

  const rateCardPresent = [
    options.rateCardId,
    options.rateCardSource,
    options.rateCardRetrievedAt,
    options.pricingBasis,
    normalizedInputUsdPer1kTokens,
    normalizedCachedInputUsdPer1kTokens,
    normalizedOutputUsdPer1kTokens,
    normalizedUsageUnitUsd
  ].some((value) => value != null && value !== '');

  if (!normalizedLaneBranch) {
    throw new Error('Missing required option: --lane-branch <value>.');
  }

  const operatorLaborUsd =
    runtimeTiming.elapsedSeconds != null && operatorProfile.laborRateUsdPerHour != null
      ? roundNumber((runtimeTiming.elapsedSeconds / 3600) * operatorProfile.laborRateUsdPerHour)
      : null;
  const laborStatus =
    operatorProfile.status !== 'configured'
      ? operatorProfile.status
      : operatorLaborUsd == null
        ? 'missing-elapsed-seconds'
        : 'computed';
  const blendedTotalUsd =
    normalizedAmountUsd != null && operatorLaborUsd != null
      ? roundNumber(normalizedAmountUsd + operatorLaborUsd)
      : null;

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    provider: {
      id: normalizeText(options.providerId),
      kind: normalizeText(options.providerKind),
      runtime: normalizeText(options.providerRuntime),
      executionPlane: normalizeText(options.executionPlane)
    },
    model: {
      requested: normalizedRequestedModel,
      effective: normalizedEffectiveModel,
      requestedReasoningEffort: normalizedRequestedReasoningEffort ?? null,
      effectiveReasoningEffort: normalizedEffectiveReasoningEffort ?? null
    },
    usage: {
      inputTokens: normalizedInputTokens,
      cachedInputTokens: normalizedCachedInputTokens,
      outputTokens: normalizedOutputTokens,
      totalTokens: normalizedTotalTokens,
      usageUnitKind: normalizeText(options.usageUnitKind) || null,
      usageUnitCount: normalizedUsageUnitCount
    },
    billing: {
      exactness: normalizedExactness,
      currency: 'USD',
      amountUsd: normalizedAmountUsd,
      rateCard: rateCardPresent
        ? {
            id: normalizeText(options.rateCardId) || 'manual-rate-card',
            source: normalizeText(options.rateCardSource) || 'manual',
            retrievedAt: normalizeText(options.rateCardRetrievedAt) || now.toISOString(),
            pricingBasis: normalizeText(options.pricingBasis) || 'manual',
            inputUsdPer1kTokens: normalizedInputUsdPer1kTokens,
            cachedInputUsdPer1kTokens: normalizedCachedInputUsdPer1kTokens,
            outputUsdPer1kTokens: normalizedOutputUsdPer1kTokens,
            usageUnitUsd: normalizedUsageUnitUsd
          }
        : null
    },
    context: {
      repository: normalizeText(options.repository),
      issueNumber: options.issueNumber,
      laneId: normalizeText(options.laneId),
      laneBranch: normalizedLaneBranch,
      sessionId: normalizeText(options.sessionId),
      turnId: normalizeText(options.turnId),
      workerSlotId: normalizeText(options.workerSlotId) || null,
      agentRole: normalizeText(options.agentRole).toLowerCase() || 'background'
    },
    provenance: {
      sourceSchema: normalizeText(options.sourceSchema) || null,
      sourceReceiptPath: normalizeText(options.sourceReceiptPath) || null,
      sourceReportPath: normalizeText(options.sourceReportPath) || null,
      usageObservedAt: normalizeText(options.usageObservedAt)
    },
    runtime: {
      startedAt: runtimeTiming.startedAt,
      endedAt: runtimeTiming.endedAt,
      elapsedSeconds: runtimeTiming.elapsedSeconds,
      elapsedSource: runtimeTiming.elapsedSource
    },
    labor: {
      operatorProfilePath: operatorProfile.operatorProfilePath,
      operatorId: operatorProfile.operatorId,
      operatorName: operatorProfile.operatorName,
      laborRateUsdPerHour: operatorProfile.laborRateUsdPerHour,
      currency: operatorProfile.currency,
      pricingBasis: operatorProfile.pricingBasis,
      amountUsd: operatorLaborUsd,
      blendedTotalUsd,
      status: laborStatus
    },
    steering: {
      operatorIntervened: normalizedOperatorSteered,
      kind: normalizedOperatorSteeringKind,
      source: normalizedOperatorSteeringSource,
      observedAt: normalizedOperatorSteeringObservedAt,
      note: normalizedOperatorSteeringNote,
      invoiceTurnId: normalizedSteeringInvoiceTurnId
    }
  };

  return {
    outputPath: path.resolve(outputPath),
    report
  };
}

export function runAgentCostTurn(options, now = new Date(), helpers = {}) {
  const result = buildAgentCostTurn(options, now, helpers);
  fs.mkdirSync(path.dirname(result.outputPath), { recursive: true });
  fs.writeFileSync(result.outputPath, `${JSON.stringify(result.report, null, 2)}\n`, 'utf8');
  return result;
}

function printUsage() {
  console.log('Usage: node tools/priority/agent-cost-turn.mjs [options]');
  console.log('');
  console.log('Required options:');
  console.log('  --provider-id <value>');
  console.log('  --provider-kind <value>');
  console.log('  --provider-runtime <value>');
  console.log('  --execution-plane <value>');
  console.log('  --requested-model <value>');
  console.log('  --repository <owner/repo>');
  console.log('  --issue-number <integer>');
  console.log('  --lane-id <value>');
  console.log('  --session-id <value>');
  console.log('  --turn-id <value>');
  console.log('  --agent-role <live|background>');
  console.log('  --source-schema <value>');
  console.log('  --usage-observed-at <date-time>');
  console.log('');
  console.log('Branch attribution:');
  console.log('  --lane-branch <value>           Optional explicit branch ref.');
  console.log('                                  When omitted, the helper tries source receipts/reports,');
  console.log('                                  then a branch-like lane id, then the current git branch.');
  console.log('');
  console.log('Optional model metadata:');
  console.log('  --effective-model <value>');
  console.log('  --requested-reasoning-effort <low|medium|high|xhigh>');
  console.log('  --effective-reasoning-effort <low|medium|high|xhigh>');
  console.log('');
  console.log('Optional usage/billing metadata:');
  console.log('  --input-tokens <integer>');
  console.log('  --cached-input-tokens <integer>');
  console.log('  --output-tokens <integer>');
  console.log('  --total-tokens <integer>');
  console.log('  --usage-unit-kind <value>');
  console.log('  --usage-unit-count <number>');
  console.log('  --exactness <exact|estimated>');
  console.log('  --amount-usd <number>');
  console.log('  --rate-card-id <value>');
  console.log('  --rate-card-source <value>');
  console.log('  --rate-card-retrieved-at <date-time>');
  console.log('  --pricing-basis <value>');
  console.log('  --input-usd-per-1k-tokens <number>');
  console.log('  --cached-input-usd-per-1k-tokens <number>');
  console.log('  --output-usd-per-1k-tokens <number>');
  console.log('  --usage-unit-usd <number>');
  console.log('');
  console.log('Optional provenance/output metadata:');
  console.log('  --worker-slot-id <value>');
  console.log('  --source-receipt-path <path>');
  console.log('  --source-report-path <path>');
  console.log(`  --operator-cost-profile <path>  Optional operator labor profile (default: ${DEFAULT_OPERATOR_COST_PROFILE_PATH}).`);
  console.log('  --operator-id <value>');
  console.log('  --started-at <date-time>');
  console.log('  --ended-at <date-time>');
  console.log('  --elapsed-seconds <number>');
  console.log('  --operator-steered');
  console.log('  --operator-steering-kind <value>');
  console.log('  --operator-steering-source <value>');
  console.log('  --operator-steering-observed-at <date-time>');
  console.log('  --operator-steering-note <text>');
  console.log('  --steering-invoice-turn-id <value>');
  console.log('  --output <path>');
  console.log('  -h, --help');
}

export async function main(argv = process.argv) {
  try {
    const options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return 0;
    }
    const result = runAgentCostTurn(options);
    console.log(`[agent-cost-turn] wrote ${result.outputPath}`);
    return 0;
  } catch (error) {
    console.error(error?.message || String(error));
    return 1;
  }
}

const entrypointPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (entrypointPath && modulePath === entrypointPath) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

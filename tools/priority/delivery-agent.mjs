#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  applyConcurrentLanePlan,
  DEFAULT_OUTPUT_PATH as DEFAULT_CONCURRENT_LANE_APPLY_RECEIPT_PATH,
  DEFAULT_PLAN_PATH as DEFAULT_CONCURRENT_LANE_PLAN_PATH
} from './concurrent-lane-apply.mjs';
import {
  DEFAULT_HOST_PLANE_REPORT_PATH,
  DEFAULT_HOST_RAM_BUDGET_PATH
} from './concurrent-lane-plan.mjs';
import {
  DEFAULT_STATUS_OUTPUT_PATH as DEFAULT_CONCURRENT_LANE_STATUS_RECEIPT_PATH,
  observeConcurrentLaneStatus
} from './concurrent-lane-status.mjs';
import { loadBranchClassContract, resolveBranchPlaneTransition } from './lib/branch-classification.mjs';
import { resolveRequiredLaneBranchPrefix } from './lib/runtime-lane-branch-contract.mjs';
import {
  assessDockerDesktopReviewLoopReceipt,
  buildLocalReviewLoopCliArgs,
  DOCKER_PARITY_RESULTS_ROOT,
  DEFAULT_LOCAL_REVIEW_LOOP_COMMAND
} from './docker-desktop-review-loop.mjs';
import { handoffStandingPriority } from './standing-priority-handoff.mjs';
import {
  fetchIssue,
  resolveStandingPriorityLabels,
  selectAutoStandingPriorityCandidateForRepo
} from './sync-standing-priority.mjs';
import {
  collectMarketplaceSnapshot,
  DEFAULT_MARKETPLACE_SNAPSHOT_PATH,
  selectMarketplaceRecommendation,
  writeMarketplaceSnapshot
} from './lane-marketplace.mjs';
import { extractGitResultMessage, refreshUpstreamTrackingRef } from './lib/upstream-ref-refresh.mjs';
import {
  buildLiveAgentModelSelectionProjection,
  DEFAULT_POLICY_PATH as DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH,
  loadLiveAgentModelSelectionPolicy,
  loadLiveAgentModelSelectionReport
} from './live-agent-model-selection.mjs';

export const DELIVERY_AGENT_POLICY_SCHEMA = 'priority/delivery-agent-policy@v1';
export const DELIVERY_AGENT_RUNTIME_STATE_SCHEMA = 'priority/delivery-agent-runtime-state@v1';
export const DELIVERY_AGENT_LANE_STATE_SCHEMA = 'priority/delivery-agent-lane-state@v1';
export const READY_VALIDATION_CLEARANCE_SCHEMA = 'priority/ready-validation-clearance@v1';
export const DELIVERY_AGENT_POLICY_RELATIVE_PATH = path.join('tools', 'priority', 'delivery-agent.policy.json');
export const DELIVERY_AGENT_STATE_FILENAME = 'delivery-agent-state.json';
export const DELIVERY_AGENT_LANES_DIRNAME = 'delivery-agent-lanes';
export const DELIVERY_AGENT_LIFECYCLE_STATES = new Set([
  'planning',
  'reshaping-backlog',
  'coding',
  'waiting-ci',
  'waiting-review',
  'ready-merge',
  'blocked',
  'complete',
  'idle'
]);
const DEFAULT_WORKER_PROVIDER_BLUEPRINTS = Object.freeze([
  Object.freeze({
    id: 'local-codex',
    kind: 'local-codex',
    executionPlane: 'local',
    assignmentMode: 'interactive-coding',
    dispatchSurface: 'runtime-harness',
    completionMode: 'sync',
    requiresLocalCheckout: true
  }),
  Object.freeze({
    id: 'hosted-github-workflow',
    kind: 'hosted-github-workflow',
    executionPlane: 'hosted',
    assignmentMode: 'async-validation',
    dispatchSurface: 'github-actions',
    completionMode: 'async',
    requiresLocalCheckout: false
  }),
  Object.freeze({
    id: 'remote-copilot-lane',
    kind: 'remote-copilot-lane',
    executionPlane: 'remote',
    assignmentMode: 'remote-implementation',
    dispatchSurface: 'remote-copilot',
    completionMode: 'async',
    requiresLocalCheckout: false
  }),
  Object.freeze({
    id: 'local-shadow-native',
    kind: 'local-shadow-native',
    executionPlane: 'local-shadow',
    assignmentMode: 'shadow-validation',
    dispatchSurface: 'native-shadow',
    completionMode: 'sync',
    requiresLocalCheckout: false
  })
]);
const DEFAULT_WORKER_RELEASE_WAITING_STATES = Object.freeze(['waiting-ci', 'waiting-review', 'ready-merge']);
const SUPPORTED_WORKER_PROVIDER_KINDS = new Set(
  DEFAULT_WORKER_PROVIDER_BLUEPRINTS.map((provider) => provider.kind)
);
const SUPPORTED_WORKER_EXECUTION_PLANES = new Set(
  DEFAULT_WORKER_PROVIDER_BLUEPRINTS.map((provider) => provider.executionPlane)
);
const SUPPORTED_WORKER_ASSIGNMENT_MODES = new Set(
  DEFAULT_WORKER_PROVIDER_BLUEPRINTS.map((provider) => provider.assignmentMode)
);
const SUPPORTED_WORKER_DISPATCH_SURFACES = new Set(
  DEFAULT_WORKER_PROVIDER_BLUEPRINTS.map((provider) => provider.dispatchSurface)
);
const SUPPORTED_WORKER_COMPLETION_MODES = new Set(
  DEFAULT_WORKER_PROVIDER_BLUEPRINTS.map((provider) => provider.completionMode)
);

function buildWorkerProviderCapabilities(source, fallbackBlueprint) {
  const capabilitiesSource =
    source?.capabilities && typeof source.capabilities === 'object' ? source.capabilities : {};
  return {
    executionPlane: normalizeAllowedString(
      capabilitiesSource.executionPlane ?? source?.executionPlane,
      SUPPORTED_WORKER_EXECUTION_PLANES,
      fallbackBlueprint.executionPlane
    ),
    assignmentMode: normalizeAllowedString(
      capabilitiesSource.assignmentMode ?? source?.assignmentMode,
      SUPPORTED_WORKER_ASSIGNMENT_MODES,
      fallbackBlueprint.assignmentMode
    ),
    dispatchSurface: normalizeAllowedString(
      capabilitiesSource.dispatchSurface ?? source?.dispatchSurface,
      SUPPORTED_WORKER_DISPATCH_SURFACES,
      fallbackBlueprint.dispatchSurface
    ),
    completionMode: normalizeAllowedString(
      capabilitiesSource.completionMode ?? source?.completionMode,
      SUPPORTED_WORKER_COMPLETION_MODES,
      fallbackBlueprint.completionMode
    ),
    requiresLocalCheckout:
      typeof capabilitiesSource.requiresLocalCheckout === 'boolean'
        ? capabilitiesSource.requiresLocalCheckout
        : typeof source?.requiresLocalCheckout === 'boolean'
          ? source.requiresLocalCheckout
          : fallbackBlueprint.requiresLocalCheckout
  };
}

function buildWorkerProviderPolicyEntry(source, fallbackBlueprint, overrides = {}) {
  const capabilities = buildWorkerProviderCapabilities(source, fallbackBlueprint);
  return {
    id: normalizeText(overrides.id ?? source?.id) || fallbackBlueprint.id,
    kind: normalizeAllowedString(
      overrides.kind ?? source?.kind,
      SUPPORTED_WORKER_PROVIDER_KINDS,
      fallbackBlueprint.kind
    ),
    capabilities,
    executionPlane: capabilities.executionPlane,
    assignmentMode: capabilities.assignmentMode,
    dispatchSurface: capabilities.dispatchSurface,
    completionMode: capabilities.completionMode,
    requiresLocalCheckout: capabilities.requiresLocalCheckout,
    enabled: overrides.enabled ?? source?.enabled !== false,
    slotCount: coercePositiveInteger(overrides.slotCount ?? source?.slotCount) ?? 1
  };
}

const DEFAULT_POLICY = {
  schema: DELIVERY_AGENT_POLICY_SCHEMA,
  backlogAuthority: 'issues',
  implementationRemote: 'origin',
  copilotReviewStrategy: 'draft-only-explicit',
  autoSlice: true,
  autoMerge: true,
  maxActiveCodingLanes: 4,
  allowPolicyMutations: false,
  allowReleaseAdmin: false,
  stopWhenNoOpenEpics: true,
  workerPool: {
    targetSlotCount: 4,
    prewarmSlotCount: 1,
    releaseWaitingStates: [...DEFAULT_WORKER_RELEASE_WAITING_STATES],
    providers: DEFAULT_WORKER_PROVIDER_BLUEPRINTS.map((provider) =>
      buildWorkerProviderPolicyEntry(provider, provider)
    )
  },
  hostIsolation: {
    mode: 'hard-cutover',
    wslDistro: 'Ubuntu',
    runnerServicePolicy: 'stop-all-actions-runner-services',
    restoreRunnerServicesOnExit: true,
    pauseOnFingerprintDrift: true,
  },
  dockerRuntime: {
    provider: 'native-wsl',
    dockerHost: 'unix:///var/run/docker.sock',
    expectedOsType: 'linux',
    expectedContext: '',
    manageDockerEngine: false,
    allowHostEngineMutation: false,
  },
  concurrentLaneDispatch: {
    historyScenarioSet: 'smoke',
    sampleIdStrategy: 'auto',
    sampleId: '',
    allowForkMode: 'auto',
    pushMissing: true,
    forcePushOk: false,
    allowNonCanonicalViHistory: false,
    allowNonCanonicalHistoryCore: false
  },
  localReviewLoop: {
    enabled: true,
    bodyMarkers: ['Daemon-first local iteration extension'],
    receiptPath: path.join('tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json'),
    command: [...DEFAULT_LOCAL_REVIEW_LOOP_COMMAND],
    actionlint: true,
    markdownlint: true,
    docs: true,
    workflow: true,
    dotnetCliBuild: true,
    requirementsVerification: true,
    niLinuxReviewSuite: true,
    singleViHistory: {
      enabled: false,
      targetPath: '',
      branchRef: 'develop',
      baselineRef: '',
      maxCommitCount: 256
    }
  },
  turnBudget: {
    maxMinutes: 20,
    maxToolCalls: 12
  },
  retry: {
    maxAttempts: 3,
    blockerBackoffMinutes: 10,
    rateLimitCooldownMinutes: 30
  },
  codingTurnCommand: []
};

const SUCCESSFUL_CHECK_CONCLUSIONS = new Set(['SUCCESS', 'NEUTRAL', 'SKIPPED']);
const PENDING_CHECK_STATES = new Set(['QUEUED', 'IN_PROGRESS', 'PENDING', 'EXPECTED', 'WAITING']);
const BLOCKING_CHECK_STATES = new Set(['FAILURE', 'FAILED', 'TIMED_OUT', 'ERROR', 'ACTION_REQUIRED', 'CANCELLED']);
const COPILOT_REVIEW_WORKFLOW_NAME = 'Copilot code review';
const PENDING_WORKFLOW_RUN_STATUSES = new Set(['QUEUED', 'IN_PROGRESS', 'PENDING', 'REQUESTED', 'WAITING']);
const COPILOT_REVIEW_ACTIVE_POLL_HINT_SECONDS = 10;
const COPILOT_REVIEW_POST_POLL_HINT_SECONDS = 5;
const COPILOT_REVIEW_METADATA_CACHE_TTL_MS =
  Math.max(COPILOT_REVIEW_ACTIVE_POLL_HINT_SECONDS, COPILOT_REVIEW_POST_POLL_HINT_SECONDS) * 1000;
const COPILOT_REVIEW_METADATA_RETENTION_MS = 24 * 60 * 60 * 1000;
const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const COPILOT_LOGINS = new Set([
  'copilot',
  'copilot-pull-request-reviewer',
  'copilot-pull-request-reviewer[bot]'
]);
const REVIEW_THREADS_QUERY = [
  'query($owner:String!,$repo:String!,$number:Int!){',
  'repository(owner:$owner,name:$repo){',
  'pullRequest(number:$number){',
  'reviewThreads(first:100){',
  'nodes{',
  'id',
  'isResolved',
  'isOutdated',
  'path',
  'line',
  'originalLine',
  'comments(first:100){',
  'nodes{',
  'id',
  'createdAt',
  'publishedAt',
  'url',
  'author{login}',
  'originalCommit{oid}',
  'pullRequestReview{',
  'databaseId',
  'state',
  'author{login}',
  'submittedAt',
  'commit{oid}',
  '}',
  '}',
  '}',
  '}',
  '}',
  '}',
  '}',
  '}'
].join(' ');

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function toIso(now = new Date()) {
  return now.toISOString();
}

function coercePositiveInteger(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function sanitizeSegment(value) {
  return String(value || '')
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'runtime';
}

function resolvePath(repoRoot, filePath) {
  return path.isAbsolute(filePath) ? filePath : path.join(repoRoot, filePath);
}

function resolveExecutionRoot(repoRoot, taskPacket) {
  const workerCheckoutPath =
    normalizeText(taskPacket?.evidence?.lane?.workerCheckoutPath) ||
    normalizeText(taskPacket?.branch?.checkoutPath) ||
    '';
  return workerCheckoutPath ? resolvePath(repoRoot, workerCheckoutPath) : repoRoot;
}

function resolveReadyValidationClearancePath({ repoRoot, repository, pullRequestNumber }) {
  const repositorySegment = sanitizeSegment(repository || 'repo');
  const pullRequestSegment = sanitizeSegment(`pr-${pullRequestNumber || 'unknown'}`);
  return path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'runtime',
    'ready-validation-clearance',
    `${repositorySegment}-${pullRequestSegment}.json`
  );
}

function isJsonParseError(error) {
  return error instanceof SyntaxError || error?.name === 'SyntaxError';
}

async function readJsonIfPresent(filePath, { deleteCorrupt = false } = {}) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    if (deleteCorrupt && isJsonParseError(error)) {
      await rm(filePath, { force: true });
      return null;
    }
    throw error;
  }
}

function parseJsonObjectOutput(raw, source = 'command output') {
  const trimmed = normalizeText(raw);
  if (!trimmed) {
    return null;
  }
  try {
    const parsed = JSON.parse(trimmed);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (error) {
    throw new Error(`Unable to parse ${source} as JSON: ${error.message}`);
  }
}

async function writeJsonAtomically(filePath, payload) {
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(tempPath, payload, 'utf8');
  try {
    await rename(tempPath, filePath);
  } catch (error) {
    if (error?.code !== 'EEXIST' && error?.code !== 'EPERM') {
      throw error;
    }
    await rm(filePath, { force: true });
    await rename(tempPath, filePath);
  } finally {
    await rm(tempPath, { force: true });
  }
}

async function loadReadyValidationClearance({ repoRoot, repository, pullRequestNumber }) {
  const clearancePath = resolveReadyValidationClearancePath({ repoRoot, repository, pullRequestNumber });
  const payload = await readJsonIfPresent(clearancePath, { deleteCorrupt: true });
  if (!payload || typeof payload !== 'object') {
    return {
      path: clearancePath,
      receipt: null
    };
  }
  return {
    path: clearancePath,
    receipt: payload
  };
}

async function persistReadyValidationClearance({
  repoRoot,
  repository,
  pullRequest,
  localReviewLoop = null,
  readyHeadShaOverride = null,
  currentHeadShaOverride = null,
  status = 'current',
  reason = ''
}) {
  const pullRequestNumber = coercePositiveInteger(pullRequest?.number);
  if (!pullRequestNumber) {
    throw new Error('pullRequest.number is required to persist ready-validation clearance.');
  }
  const receiptPath = resolveReadyValidationClearancePath({ repoRoot, repository, pullRequestNumber });
  const receipt = {
    schema: READY_VALIDATION_CLEARANCE_SCHEMA,
    generatedAt: toIso(),
    repository: normalizeText(repository) || null,
    pullRequestNumber,
    pullRequestUrl: normalizeText(pullRequest?.url) || null,
    readyHeadSha: normalizeText(readyHeadShaOverride) || normalizeText(pullRequest?.headRefOid) || null,
    currentHeadSha: normalizeText(currentHeadShaOverride) || normalizeText(pullRequest?.headRefOid) || null,
    status: normalizeText(status) || 'current',
    reason: normalizeText(reason) || null,
    localReviewLoop: localReviewLoop && typeof localReviewLoop === 'object'
      ? {
          receiptPath: normalizeText(localReviewLoop.receiptPath) || null,
          receiptHeadSha: normalizeText(localReviewLoop.receiptHeadSha) || null,
          currentHeadSha: normalizeText(localReviewLoop.currentHeadSha) || null,
          receiptFreshForHead:
            typeof localReviewLoop.receiptFreshForHead === 'boolean' ? localReviewLoop.receiptFreshForHead : null,
          requestedCoverageSatisfied:
            typeof localReviewLoop.requestedCoverageSatisfied === 'boolean'
              ? localReviewLoop.requestedCoverageSatisfied
              : null
        }
      : null
  };
  await writeJsonAtomically(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
  return {
    receiptPath,
    receipt
  };
}

async function invalidateReadyValidationClearance({
  repoRoot,
  repository,
  pullRequest,
  localReviewLoop = null,
  readyHeadShaOverride = null,
  currentHeadShaOverride = null,
  status = 'invalidated',
  reason = ''
}) {
  return persistReadyValidationClearance({
    repoRoot,
    repository,
    pullRequest,
    localReviewLoop,
    readyHeadShaOverride,
    currentHeadShaOverride,
    status,
    reason
  });
}

function normalizeCommandList(value) {
  return Array.isArray(value) ? value.map((entry) => normalizeText(entry)).filter(Boolean) : [];
}

function normalizeStringList(value) {
  return Array.isArray(value) ? value.map((entry) => normalizeText(entry)).filter(Boolean) : [];
}

function normalizeUniqueStringList(value) {
  return uniqueStrings(normalizeStringList(value));
}

function normalizeAllowedString(value, allowedValues, fallbackValue) {
  const normalized = normalizeText(value);
  return allowedValues.has(normalized) ? normalized : fallbackValue;
}

function buildDefaultWorkerPoolProviders() {
  return DEFAULT_WORKER_PROVIDER_BLUEPRINTS.map((blueprint) =>
    buildWorkerProviderPolicyEntry(blueprint, blueprint)
  );
}

function normalizeWorkerProviderPolicy(value, { fallbackIndex = 0 } = {}) {
  const provider = value && typeof value === 'object' ? value : {};
  const fallbackBlueprint =
    DEFAULT_WORKER_PROVIDER_BLUEPRINTS[fallbackIndex % DEFAULT_WORKER_PROVIDER_BLUEPRINTS.length];
  return buildWorkerProviderPolicyEntry(provider, fallbackBlueprint);
}

function normalizeWorkerPoolPolicy(value, { maxActiveCodingLanes = DEFAULT_POLICY.maxActiveCodingLanes } = {}) {
  const workerPool = value && typeof value === 'object' ? value : {};
  const requestedMaxActiveCodingLanes =
    coercePositiveInteger(maxActiveCodingLanes) ?? DEFAULT_POLICY.maxActiveCodingLanes;
  const providers =
    Array.isArray(workerPool.providers) && workerPool.providers.length > 0
      ? workerPool.providers.map((provider, index) =>
          normalizeWorkerProviderPolicy(provider, { fallbackIndex: index })
        )
      : buildDefaultWorkerPoolProviders(requestedMaxActiveCodingLanes);
  const providerIds = new Set();
  for (const provider of providers) {
    const providerKey = provider.id.toLowerCase();
    if (providerIds.has(providerKey)) {
      throw new Error(`Duplicate workerPool provider id: ${provider.id}`);
    }
    providerIds.add(providerKey);
  }
  const enabledSlotCount = providers
    .filter((provider) => provider.enabled !== false)
    .reduce((total, provider) => total + (coercePositiveInteger(provider.slotCount) ?? 1), 0);
  const targetSlotCount = Math.max(
    coercePositiveInteger(workerPool.targetSlotCount) ?? requestedMaxActiveCodingLanes,
    enabledSlotCount,
    1
  );
  const releaseWaitingStates = uniqueStrings(
    Array.isArray(workerPool.releaseWaitingStates)
      ? workerPool.releaseWaitingStates
      : DEFAULT_WORKER_RELEASE_WAITING_STATES
  )
    .map((entry) => normalizeLifecycle(entry))
    .filter((entry) => DEFAULT_WORKER_RELEASE_WAITING_STATES.includes(entry));
  return {
    targetSlotCount,
    prewarmSlotCount: Math.min(
      coercePositiveInteger(workerPool.prewarmSlotCount) ?? Math.min(1, targetSlotCount),
      targetSlotCount
    ),
    releaseWaitingStates:
      releaseWaitingStates.length > 0 ? releaseWaitingStates : [...DEFAULT_WORKER_RELEASE_WAITING_STATES],
    providers
  };
}

export function buildWorkerPoolPolicySnapshot(policy = {}) {
  const maxActiveCodingLanes =
    coercePositiveInteger(policy?.maxActiveCodingLanes) ?? DEFAULT_POLICY.maxActiveCodingLanes;
  const workerPool = normalizeWorkerPoolPolicy(policy?.workerPool, { maxActiveCodingLanes });
  return {
    targetSlotCount: workerPool.targetSlotCount,
    prewarmSlotCount: workerPool.prewarmSlotCount,
    releaseWaitingStates: [...workerPool.releaseWaitingStates],
    providers: workerPool.providers.map((provider) => ({
      ...provider,
      capabilities: provider.capabilities && typeof provider.capabilities === 'object'
        ? { ...provider.capabilities }
        : null
    }))
  };
}

function buildDefaultWorkerProviderSelection({ laneLifecycle, selectedActionType }) {
  const normalizedLaneLifecycle = normalizeLifecycle(laneLifecycle, 'coding');
  const normalizedActionType = normalizeText(selectedActionType);
  if (['waiting-ci', 'waiting-review', 'ready-merge'].includes(normalizedLaneLifecycle)) {
    return {
      source: 'lane-lifecycle-default',
      laneLifecycle: normalizedLaneLifecycle,
      selectedActionType: normalizedActionType || null,
      requiredAssignmentMode: 'async-validation',
      preferredProviderIds: ['hosted-github-workflow'],
      preferredExecutionPlanes: ['hosted'],
      requiresLocalCheckout: false
    };
  }
  return {
    source: 'selected-action-default',
    laneLifecycle: normalizedLaneLifecycle,
    selectedActionType: normalizedActionType || null,
    requiredAssignmentMode: 'interactive-coding',
    preferredProviderIds: ['local-codex'],
    preferredExecutionPlanes: ['local'],
    requiresLocalCheckout: true
  };
}

function normalizeWorkerProviderSelection(value, defaults = {}) {
  const normalizedDefaults = buildDefaultWorkerProviderSelection(defaults);
  const raw = value && typeof value === 'object' ? value : {};
  const preferredProviderIds = normalizeUniqueStringList(
    raw.preferredProviderIds ??
      raw.providerIds ??
      [raw.selectedProviderId, raw.workerProviderId, raw.providerId].filter(Boolean)
  );
  const explicitAssignmentMode = normalizeAllowedString(
    raw.requiredAssignmentMode,
    SUPPORTED_WORKER_ASSIGNMENT_MODES,
    ''
  );
  return {
    source: normalizeText(raw.source) || normalizedDefaults.source,
    laneLifecycle: normalizeLifecycle(raw.laneLifecycle, normalizedDefaults.laneLifecycle),
    selectedActionType: normalizeText(raw.selectedActionType) || normalizedDefaults.selectedActionType,
    requiredAssignmentMode:
      explicitAssignmentMode || (preferredProviderIds.length > 0 ? null : normalizedDefaults.requiredAssignmentMode),
    preferredProviderIds:
      preferredProviderIds.length > 0 ? preferredProviderIds : [...normalizedDefaults.preferredProviderIds],
    preferredExecutionPlanes: normalizeUniqueStringList(raw.preferredExecutionPlanes).filter((entry) =>
      SUPPORTED_WORKER_EXECUTION_PLANES.has(entry)
    ),
    requiresLocalCheckout:
      typeof raw.requiresLocalCheckout === 'boolean' ? raw.requiresLocalCheckout : normalizedDefaults.requiresLocalCheckout
  };
}

export function buildWorkerProviderSelectionRequest({
  schedulerDecision = null,
  laneLifecycle = '',
  selectedActionType = '',
  override = null
} = {}) {
  const artifacts = schedulerDecision?.artifacts ?? {};
  return normalizeWorkerProviderSelection(
    override ?? artifacts.workerProviderSelection ?? null,
    {
      laneLifecycle: laneLifecycle || artifacts.laneLifecycle || schedulerDecision?.activeLane?.laneLifecycle || 'coding',
      selectedActionType: selectedActionType || artifacts.selectedActionType || ''
    }
  );
}

function matchesWorkerProviderSelection(provider, selection) {
  if (!provider || provider.enabled === false) {
    return false;
  }
  if (selection.requiredAssignmentMode && provider.assignmentMode !== selection.requiredAssignmentMode) {
    return false;
  }
  return true;
}

function rankWorkerProvider(provider, selection) {
  const preferredProviderIndex = selection.preferredProviderIds.findIndex(
    (providerId) => providerId.toLowerCase() === provider.id.toLowerCase()
  );
  const preferredExecutionPlaneIndex = selection.preferredExecutionPlanes.findIndex(
    (executionPlane) => executionPlane === provider.executionPlane
  );
  return [
    preferredProviderIndex >= 0 ? preferredProviderIndex : Number.MAX_SAFE_INTEGER,
    preferredExecutionPlaneIndex >= 0 ? preferredExecutionPlaneIndex : Number.MAX_SAFE_INTEGER,
    provider.id
  ];
}

export function selectWorkerProviderAssignment({
  policy = {},
  selection = null,
  preferredSlotId = null,
  availableSlots = []
} = {}) {
  const workerPoolPolicy = buildWorkerPoolPolicySnapshot(policy);
  const normalizedSelection = normalizeWorkerProviderSelection(selection, selection ?? {});
  const enabledProviders = workerPoolPolicy.providers.filter((provider) => provider.enabled !== false);
  const eligibleProviders = enabledProviders.filter((provider) => matchesWorkerProviderSelection(provider, normalizedSelection));
  const rankedProviders = [...eligibleProviders].sort((left, right) => {
    const leftRank = rankWorkerProvider(left, normalizedSelection);
    const rightRank = rankWorkerProvider(right, normalizedSelection);
    for (let index = 0; index < leftRank.length; index += 1) {
      if (leftRank[index] < rightRank[index]) return -1;
      if (leftRank[index] > rightRank[index]) return 1;
    }
    return 0;
  });
  const selectedProvider = rankedProviders[0] ?? null;
  const normalizedPreferredSlotId = normalizeText(preferredSlotId) || null;
  const selectedSlot =
    normalizedPreferredSlotId && Array.isArray(availableSlots)
      ? availableSlots.find((slot) => normalizeText(slot?.slotId) === normalizedPreferredSlotId) ?? null
      : null;
  return {
    ...normalizedSelection,
    eligibleProviderIds: eligibleProviders.map((provider) => provider.id),
    selectedProviderId: selectedProvider?.id ?? null,
    selectedProviderKind: selectedProvider?.kind ?? null,
    selectedExecutionPlane: selectedProvider?.executionPlane ?? null,
    selectedAssignmentMode: selectedProvider?.assignmentMode ?? null,
    dispatchSurface: selectedProvider?.dispatchSurface ?? null,
    completionMode: selectedProvider?.completionMode ?? null,
    requiresLocalCheckout:
      selectedProvider?.requiresLocalCheckout ?? normalizedSelection.requiresLocalCheckout ?? true,
    selectedSlotId: normalizeText(selectedSlot?.slotId) || normalizedPreferredSlotId
  };
}

function buildWorkerProviderDispatchReceipt(providerSelection, {
  dispatchStatus = '',
  completionStatus = '',
  workerSlotId = null,
  failureClass = null
} = {}) {
  if (!providerSelection?.selectedProviderId) {
    return null;
  }
  return {
    providerId: providerSelection.selectedProviderId,
    providerKind: providerSelection.selectedProviderKind ?? null,
    executionPlane: providerSelection.selectedExecutionPlane ?? null,
    assignmentMode: providerSelection.selectedAssignmentMode ?? null,
    dispatchSurface: providerSelection.dispatchSurface ?? null,
    completionMode: providerSelection.completionMode ?? null,
    workerSlotId: normalizeText(workerSlotId ?? providerSelection.selectedSlotId) || null,
    dispatchStatus: normalizeText(dispatchStatus) || null,
    completionStatus: normalizeText(completionStatus) || null,
    failureClass: normalizeText(failureClass) || null
  };
}

function commandUsesLocalCollabOrchestrator(command = []) {
  return Array.isArray(command)
    ? command.some((entry) => normalizeText(entry).replace(/\\/g, '/').includes('tools/local-collab/orchestrator/run-phase.mjs'))
    : false;
}

function normalizeCopilotReviewStrategy(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return DEFAULT_POLICY.copilotReviewStrategy;
  }
  if (normalized === 'draft-only-explicit') {
    return normalized;
  }
  throw new Error(`Unsupported copilotReviewStrategy: ${normalized}`);
}

function normalizeConcurrentLaneDispatchPolicy(value) {
  const concurrentLaneDispatch = value && typeof value === 'object' ? value : {};
  const historyScenarioSet = normalizeText(concurrentLaneDispatch.historyScenarioSet).toLowerCase();
  const sampleIdStrategy = normalizeText(concurrentLaneDispatch.sampleIdStrategy).toLowerCase();
  const allowForkMode =
    normalizeText(concurrentLaneDispatch.allowForkMode).toLowerCase() ||
    (typeof concurrentLaneDispatch.allowFork === 'boolean'
      ? concurrentLaneDispatch.allowFork
        ? 'always'
        : 'never'
      : '');

  const normalizedHistoryScenarioSet = historyScenarioSet || DEFAULT_POLICY.concurrentLaneDispatch.historyScenarioSet;
  if (!['none', 'smoke', 'history-core'].includes(normalizedHistoryScenarioSet)) {
    throw new Error(`Unsupported concurrentLaneDispatch.historyScenarioSet: ${normalizedHistoryScenarioSet}`);
  }

  const normalizedSampleIdStrategy = sampleIdStrategy || DEFAULT_POLICY.concurrentLaneDispatch.sampleIdStrategy;
  if (!['auto', 'explicit'].includes(normalizedSampleIdStrategy)) {
    throw new Error(`Unsupported concurrentLaneDispatch.sampleIdStrategy: ${normalizedSampleIdStrategy}`);
  }

  const normalizedAllowForkMode = allowForkMode || DEFAULT_POLICY.concurrentLaneDispatch.allowForkMode;
  if (!['auto', 'always', 'never'].includes(normalizedAllowForkMode)) {
    throw new Error(`Unsupported concurrentLaneDispatch.allowForkMode: ${normalizedAllowForkMode}`);
  }

  const sampleId = normalizeText(concurrentLaneDispatch.sampleId);
  if (normalizedSampleIdStrategy === 'explicit' && !sampleId) {
    throw new Error('concurrentLaneDispatch.sampleId is required when sampleIdStrategy is explicit.');
  }

  return {
    ...DEFAULT_POLICY.concurrentLaneDispatch,
    ...concurrentLaneDispatch,
    historyScenarioSet: normalizedHistoryScenarioSet,
    sampleIdStrategy: normalizedSampleIdStrategy,
    sampleId,
    allowForkMode: normalizedAllowForkMode,
    pushMissing:
      typeof concurrentLaneDispatch.pushMissing === 'boolean'
        ? concurrentLaneDispatch.pushMissing
        : DEFAULT_POLICY.concurrentLaneDispatch.pushMissing,
    forcePushOk:
      typeof concurrentLaneDispatch.forcePushOk === 'boolean'
        ? concurrentLaneDispatch.forcePushOk
        : DEFAULT_POLICY.concurrentLaneDispatch.forcePushOk,
    allowNonCanonicalViHistory:
      typeof concurrentLaneDispatch.allowNonCanonicalViHistory === 'boolean'
        ? concurrentLaneDispatch.allowNonCanonicalViHistory
        : DEFAULT_POLICY.concurrentLaneDispatch.allowNonCanonicalViHistory,
    allowNonCanonicalHistoryCore:
      typeof concurrentLaneDispatch.allowNonCanonicalHistoryCore === 'boolean'
        ? concurrentLaneDispatch.allowNonCanonicalHistoryCore
        : DEFAULT_POLICY.concurrentLaneDispatch.allowNonCanonicalHistoryCore
  };
}

function normalizeLocalReviewLoopPolicy(value) {
  const localReviewLoop = value && typeof value === 'object' ? value : {};
  const singleViHistory =
    localReviewLoop.singleViHistory && typeof localReviewLoop.singleViHistory === 'object'
      ? localReviewLoop.singleViHistory
      : {};
  const bodyMarkers = normalizeStringList(localReviewLoop.bodyMarkers);
  const command = normalizeCommandList(localReviewLoop.command);
  return {
    ...DEFAULT_POLICY.localReviewLoop,
    ...localReviewLoop,
    bodyMarkers: bodyMarkers.length > 0
      ? bodyMarkers
      : [...DEFAULT_POLICY.localReviewLoop.bodyMarkers],
    receiptPath: normalizeText(localReviewLoop.receiptPath) || DEFAULT_POLICY.localReviewLoop.receiptPath,
    command: command.length > 0
      ? command
      : [...DEFAULT_POLICY.localReviewLoop.command],
    singleViHistory: {
      ...DEFAULT_POLICY.localReviewLoop.singleViHistory,
      ...singleViHistory,
      targetPath: normalizeText(singleViHistory.targetPath) || DEFAULT_POLICY.localReviewLoop.singleViHistory.targetPath,
      branchRef: normalizeText(singleViHistory.branchRef) || DEFAULT_POLICY.localReviewLoop.singleViHistory.branchRef,
      baselineRef: normalizeText(singleViHistory.baselineRef),
      maxCommitCount: coercePositiveInteger(singleViHistory.maxCommitCount) ?? 0
    }
  };
}

function bodyContainsAnyMarker(body, markers = []) {
  const normalizedBody = normalizeText(body).toLowerCase();
  if (!normalizedBody) {
    return false;
  }
  return normalizeStringList(markers).some((marker) => normalizedBody.includes(normalizeText(marker).toLowerCase()));
}

export function buildLocalReviewLoopRequest({ standingIssue, selectedIssue, policy } = {}) {
  const localReviewLoopPolicy = normalizeLocalReviewLoopPolicy(policy?.localReviewLoop);
  if (localReviewLoopPolicy.enabled !== true) {
    return null;
  }
  const standingBody = typeof standingIssue?.body === 'string' ? standingIssue.body : '';
  const selectedBody = typeof selectedIssue?.body === 'string' ? selectedIssue.body : '';
  const standingHasMarker = bodyContainsAnyMarker(standingBody, localReviewLoopPolicy.bodyMarkers);
  const selectedHasMarker = bodyContainsAnyMarker(selectedBody, localReviewLoopPolicy.bodyMarkers);
  const directiveBody = [
    standingHasMarker ? standingBody : '',
    selectedHasMarker ? selectedBody : ''
  ]
    .filter(Boolean)
    .join('\n');
  if (!standingHasMarker && !selectedHasMarker) {
    return null;
  }

  const singleViRequested = /single-vi|single vi|touch-aware/i.test(directiveBody);
  const singleViTargetPath = normalizeText(localReviewLoopPolicy.singleViHistory.targetPath);
  const singleViHistory =
    localReviewLoopPolicy.singleViHistory?.enabled === true && singleViRequested && singleViTargetPath
      ? {
          enabled: true,
          targetPath: singleViTargetPath,
          branchRef: normalizeText(localReviewLoopPolicy.singleViHistory.branchRef) || null,
          baselineRef: normalizeText(localReviewLoopPolicy.singleViHistory.baselineRef) || null,
          maxCommitCount: coercePositiveInteger(localReviewLoopPolicy.singleViHistory.maxCommitCount) ?? 0
        }
      : null;
  const source = standingHasMarker && selectedHasMarker
    ? 'both-issue-bodies'
    : standingHasMarker
      ? 'standing-issue-body'
      : 'selected-issue-body';
  const requestedChecks = {
    actionlint: localReviewLoopPolicy.actionlint === true,
    markdownlint: localReviewLoopPolicy.markdownlint === true,
    docs: localReviewLoopPolicy.docs === true,
    workflow: localReviewLoopPolicy.workflow === true,
    dotnetCliBuild: localReviewLoopPolicy.dotnetCliBuild === true,
    requirementsVerification: localReviewLoopPolicy.requirementsVerification === true
  };

  return {
    requested: true,
    source,
    standingIssueNumber: coercePositiveInteger(standingIssue?.number),
    standingIssueUrl: normalizeText(standingIssue?.url) || null,
    receiptPath: localReviewLoopPolicy.receiptPath,
    ...requestedChecks,
    niLinuxReviewSuite: localReviewLoopPolicy.niLinuxReviewSuite === true || singleViHistory?.enabled === true,
    singleViHistory
  };
}

function parsePriorityOrdinal(title) {
  const match = String(title || '').match(/\[\s*p(?<priority>\d+)\s*\]/i);
  const parsed = Number(match?.groups?.priority ?? '9');
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : 9;
}

function isEpicTitle(title) {
  return /^\s*epic\s*:/i.test(String(title || ''));
}

function normalizeLabelEntries(labels) {
  return Array.isArray(labels)
    ? labels
        .map((label) => {
          if (typeof label === 'string') return label;
          if (label && typeof label === 'object') return label.name;
          return null;
        })
        .map((entry) => normalizeText(entry).toLowerCase())
        .filter(Boolean)
    : [];
}

function normalizeIssueLike(issue, { repository } = {}) {
  if (!issue || typeof issue !== 'object') return null;
  const number = coercePositiveInteger(issue.number);
  if (!number) return null;
  return {
    id: normalizeText(issue.id) || null,
    number,
    title: normalizeText(issue.title) || null,
    body: typeof issue.body === 'string' ? issue.body : '',
    url: normalizeText(issue.url) || null,
    state: normalizeText(issue.state || issue.status || 'OPEN').toUpperCase() || 'OPEN',
    createdAt: normalizeText(issue.createdAt) || null,
    updatedAt: normalizeText(issue.updatedAt) || null,
    labels: normalizeLabelEntries(issue.labels),
    repository: normalizeText(issue.repository) || repository || null,
    priority: parsePriorityOrdinal(issue.title),
    epic: isEpicTitle(issue.title)
  };
}

function compareIssueRank(left, right) {
  if (left.priority !== right.priority) {
    return left.priority - right.priority;
  }
  const leftCreated = Date.parse(left.createdAt || '') || Number.POSITIVE_INFINITY;
  const rightCreated = Date.parse(right.createdAt || '') || Number.POSITIVE_INFINITY;
  if (leftCreated !== rightCreated) {
    return leftCreated - rightCreated;
  }
  const leftUpdated = Date.parse(left.updatedAt || '') || Number.POSITIVE_INFINITY;
  const rightUpdated = Date.parse(right.updatedAt || '') || Number.POSITIVE_INFINITY;
  if (leftUpdated !== rightUpdated) {
    return leftUpdated - rightUpdated;
  }
  return left.number - right.number;
}

function selectBestIssueCandidate(candidates = []) {
  const normalized = candidates.filter(Boolean).slice().sort(compareIssueRank);
  return normalized[0] ?? null;
}

function resolveIssueBranchName({
  issueNumber,
  title,
  implementationRemote = 'origin',
  repoRoot = process.cwd(),
  branchClassContract = null,
  loadBranchClassContractFn = loadBranchClassContract
}) {
  const slug = normalizeText(title)
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^A-Za-z0-9]+/g, ' ')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .toLowerCase()
    .replace(/^-+|-+$/g, '') || 'work';
  const { laneBranchPrefix } = resolveRequiredLaneBranchPrefix({
    plane: normalizeText(implementationRemote) || 'upstream',
    repoRoot,
    branchClassContract,
    loadBranchClassContractFn
  });
  return `${laneBranchPrefix}${issueNumber}-${slug}`;
}

function inspectLocalMergedLaneState({
  issue,
  implementationRemote,
  repoRoot = process.cwd(),
  branchClassContract = null,
  loadBranchClassContractFn = loadBranchClassContract,
  deps = {}
}) {
  if (typeof deps.inspectLocalMergedLaneStateFn === 'function') {
    return deps.inspectLocalMergedLaneStateFn({
      issue,
      implementationRemote,
      repoRoot,
      branchClassContract,
      loadBranchClassContractFn
    });
  }

  const mergedPullRequests = Array.isArray(issue?.pullRequests)
    ? issue.pullRequests.filter((pullRequest) => normalizeText(pullRequest?.state).toUpperCase() === 'MERGED')
    : [];
  if (mergedPullRequests.length === 0) {
    return {
      stale: false,
      reason: 'no-merged-pr'
    };
  }

  const branch = resolveIssueBranchName({
    issueNumber: issue?.number,
    title: issue?.title,
    implementationRemote,
    repoRoot,
    branchClassContract,
    loadBranchClassContractFn
  });
  if (!branch) {
    return {
      stale: false,
      reason: 'branch-unresolved'
    };
  }

  const spawnSyncFn = deps.spawnSyncFn ?? spawnSync;
  const probe = spawnSyncFn('git', ['rev-list', '--left-right', '--count', `upstream/develop...${branch}`], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (probe.status !== 0) {
    return {
      stale: false,
      reason: 'branch-probe-unavailable',
      branch
    };
  }

  const [behindRaw, aheadRaw] = String(probe.stdout || '')
    .trim()
    .split(/\s+/, 2);
  const behindCount = Number.parseInt(behindRaw, 10);
  const aheadCount = Number.parseInt(aheadRaw, 10);
  if (!Number.isInteger(behindCount) || !Number.isInteger(aheadCount)) {
    return {
      stale: false,
      reason: 'branch-probe-invalid',
      branch
    };
  }

  return {
    stale: aheadCount === 0,
    reason: aheadCount === 0 ? 'merged-pr-zero-diff' : 'branch-has-local-diff',
    branch,
    aheadCount,
    behindCount,
    mergedPullRequestNumbers: mergedPullRequests
      .map((pullRequest) => coercePositiveInteger(pullRequest?.number))
      .filter((number) => number !== null)
  };
}

function parseRepositorySlug(repository) {
  const trimmed = normalizeText(repository);
  if (!trimmed.includes('/')) {
    throw new Error(`Invalid repository slug '${repository}'. Expected owner/repo.`);
  }
  const [owner, repo] = trimmed.split('/', 2);
  return { owner, repo };
}

function summarizeCheckRollup(rollup = []) {
  return Array.isArray(rollup)
    ? rollup
        .map((entry) => {
          if (!entry || typeof entry !== 'object') return null;
          const typeName = normalizeText(entry.__typename);
          if (typeName === 'StatusContext') {
            return {
              name: normalizeText(entry.context) || null,
              status: normalizeText(entry.state).toUpperCase() || null,
              conclusion: normalizeText(entry.state).toUpperCase() || null,
              url: normalizeText(entry.targetUrl) || null
            };
          }
          return {
            name: normalizeText(entry.name) || null,
            status: normalizeText(entry.status).toUpperCase() || null,
            conclusion: normalizeText(entry.conclusion).toUpperCase() || null,
            url: normalizeText(entry.detailsUrl) || null
          };
        })
        .filter(Boolean)
    : [];
}

function classifyChecks(rollup = []) {
  const checks = summarizeCheckRollup(rollup);
  if (checks.length === 0) {
    return {
      status: 'not-linked',
      blockerClass: 'none'
    };
  }
  let hasPending = false;
  let hasFailure = false;
  for (const check of checks) {
    const status = normalizeText(check.status).toUpperCase();
    const conclusion = normalizeText(check.conclusion).toUpperCase();
    if (PENDING_CHECK_STATES.has(status) || PENDING_CHECK_STATES.has(conclusion)) {
      hasPending = true;
      continue;
    }
    if (BLOCKING_CHECK_STATES.has(status) || BLOCKING_CHECK_STATES.has(conclusion)) {
      hasFailure = true;
      continue;
    }
    if (status === 'COMPLETED' && conclusion && !SUCCESSFUL_CHECK_CONCLUSIONS.has(conclusion)) {
      hasFailure = true;
    }
  }
  if (hasFailure) {
    return {
      status: 'failed',
      blockerClass: 'ci'
    };
  }
  if (hasPending) {
    return {
      status: 'pending',
      blockerClass: 'ci'
    };
  }
  return {
    status: 'success',
    blockerClass: 'none'
  };
}

export function classifyPullRequestWork(pr = {}) {
  const checks = classifyChecks(pr.statusCheckRollup);
  const mergeStateStatus = normalizeText(pr.mergeStateStatus).toUpperCase();
  const mergeable = normalizeText(pr.mergeable).toUpperCase();
  const reviewDecision = normalizeText(pr.reviewDecision).toUpperCase();
  const isDraft = pr.isDraft === true;
  const copilotReviewSignal = pr.copilotReviewSignal ?? null;
  const copilotReviewWorkflow = pr.copilotReviewWorkflow ?? null;
  const copilotReviewWorkflowStatus = normalizeText(copilotReviewWorkflow?.status).toUpperCase();
  const copilotReviewWorkflowConclusion = normalizeText(copilotReviewWorkflow?.conclusion).toUpperCase();
  const hasActionableCurrentHeadItems =
    (copilotReviewSignal?.actionableCommentCount ?? 0) > 0 ||
    (copilotReviewSignal?.actionableThreadCount ?? 0) > 0;
  const reviewPendingRequired =
    !reviewDecision || reviewDecision === 'REVIEW_REQUIRED' || reviewDecision === 'CHANGES_REQUESTED';
  const reviewPendingFromSignal =
    reviewPendingRequired &&
    ((copilotReviewSignal != null &&
      (copilotReviewSignal.hasCurrentHeadReview !== true || hasActionableCurrentHeadItems)) ||
      (copilotReviewSignal == null &&
        copilotReviewWorkflow != null &&
        (PENDING_WORKFLOW_RUN_STATUSES.has(copilotReviewWorkflowStatus) ||
          (copilotReviewWorkflowStatus === 'COMPLETED' && copilotReviewWorkflowConclusion === 'SUCCESS'))));
  let nextWakeCondition = 'review-disposition-updated';
  let pollIntervalSecondsHint = null;

  if (mergeStateStatus === 'BEHIND') {
    return {
      laneLifecycle: 'waiting-ci',
      blockerClass: 'ci',
      checksStatus: checks.status,
      readyToMerge: false,
      retryable: true,
      nextWakeCondition: 'branch-synced',
      syncRequired: true
    };
  }
  if (copilotReviewWorkflow && PENDING_WORKFLOW_RUN_STATUSES.has(copilotReviewWorkflowStatus)) {
    nextWakeCondition = 'copilot-review-workflow-completed';
    pollIntervalSecondsHint = COPILOT_REVIEW_ACTIVE_POLL_HINT_SECONDS;
  } else if (
    copilotReviewWorkflow &&
    copilotReviewWorkflowStatus === 'COMPLETED' &&
    copilotReviewWorkflowConclusion === 'SUCCESS'
  ) {
    nextWakeCondition = 'copilot-review-post-expected';
    pollIntervalSecondsHint = COPILOT_REVIEW_POST_POLL_HINT_SECONDS;
  } else if (
    copilotReviewWorkflow &&
    copilotReviewWorkflowStatus === 'COMPLETED' &&
    copilotReviewWorkflowConclusion &&
    copilotReviewWorkflowConclusion !== 'SUCCESS'
  ) {
    nextWakeCondition = 'copilot-review-workflow-rerun-or-fixed';
  }

  if (hasActionableCurrentHeadItems) {
    return {
      laneLifecycle: 'coding',
      blockerClass: 'review',
      checksStatus: checks.status,
      readyToMerge: false,
      retryable: true,
      nextWakeCondition: 'review-comments-addressed',
      pollIntervalSecondsHint: null,
      reviewMonitor: {
        workflow: copilotReviewWorkflow,
        signal: copilotReviewSignal
      }
    };
  }
  if (isDraft || reviewDecision === 'REVIEW_REQUIRED' || reviewDecision === 'CHANGES_REQUESTED' || reviewPendingFromSignal) {
    return {
      laneLifecycle: 'waiting-review',
      blockerClass: 'review',
      checksStatus: checks.status,
      readyToMerge: false,
      retryable: true,
      nextWakeCondition,
      pollIntervalSecondsHint,
      reviewMonitor: {
        workflow: copilotReviewWorkflow,
        signal: copilotReviewSignal
      },
      syncRequired: false
    };
  }
  if (mergeStateStatus === 'DIRTY' || mergeable === 'CONFLICTING' || mergeable === 'UNMERGEABLE') {
    return {
      laneLifecycle: 'blocked',
      blockerClass: 'merge',
      checksStatus: checks.status,
      readyToMerge: false,
      retryable: false,
      nextWakeCondition: 'manual-conflict-resolution',
      syncRequired: false
    };
  }
  if (checks.blockerClass === 'ci') {
    return {
      laneLifecycle: 'waiting-ci',
      blockerClass: 'ci',
      checksStatus: checks.status,
      readyToMerge: false,
      retryable: true,
      nextWakeCondition: 'checks-green',
      syncRequired: false
    };
  }
  return {
    laneLifecycle: 'ready-merge',
    blockerClass: 'none',
    checksStatus: checks.status,
    readyToMerge: true,
    retryable: false,
    nextWakeCondition: 'merge-attempt',
    syncRequired: false
  };
}

function prLifecyclePriority(status) {
  const lifecycle = typeof status === 'string' ? status : normalizeText(status?.laneLifecycle).toLowerCase();
  const syncRequired = status && typeof status === 'object' ? status.syncRequired === true : false;
  switch (lifecycle) {
    case 'ready-merge':
      return 0;
    case 'waiting-ci':
      return syncRequired ? 1 : 3;
    case 'waiting-review':
      return 2;
    case 'blocked':
      return 4;
    default:
      return 5;
  }
}

function canOffloadPullRequestForWorkSteal(status = {}) {
  const lifecycle = normalizeText(status?.laneLifecycle).toLowerCase();
  if (lifecycle === 'waiting-review') {
    return true;
  }
  if (lifecycle === 'waiting-ci' && status?.syncRequired !== true) {
    return true;
  }
  return false;
}

function summarizeOffloadedPullRequestCandidate(candidate = null) {
  if (!candidate?.pullRequest) {
    return null;
  }
  return {
    issueNumber: candidate.issue?.number ?? null,
    epicNumber: candidate.epicNumber ?? null,
    pullRequestNumber: candidate.pullRequest.number ?? null,
    pullRequestUrl: normalizeText(candidate.pullRequest.url) || null,
    branch: normalizeText(candidate.pullRequest.headRefName) || null,
    laneLifecycle: normalizeText(candidate.prStatus?.laneLifecycle) || null,
    blockerClass: normalizeText(candidate.prStatus?.blockerClass) || null,
    nextWakeCondition: normalizeText(candidate.prStatus?.nextWakeCondition) || null,
    pollIntervalSecondsHint: coercePositiveInteger(candidate.prStatus?.pollIntervalSecondsHint) ?? null
  };
}

function dedupePullRequests(pullRequests = []) {
  const byNumber = new Map();
  for (const pr of pullRequests) {
    const number = coercePositiveInteger(pr?.number);
    if (!number || byNumber.has(number)) continue;
    byNumber.set(number, pr);
  }
  return [...byNumber.values()];
}

function normalizePullRequest(pr, fallbackRepository) {
  if (!pr || typeof pr !== 'object') return null;
  const number = coercePositiveInteger(pr.number);
  if (!number) return null;
  const statusCheckRollupNodes = Array.isArray(pr.statusCheckRollup?.contexts?.nodes)
    ? pr.statusCheckRollup.contexts.nodes
    : pr.statusCheckRollup;
  return {
    id: normalizeText(pr.id) || null,
    number,
    title: normalizeText(pr.title) || null,
    url: normalizeText(pr.url) || null,
    state: normalizeText(pr.state || 'OPEN').toUpperCase() || 'OPEN',
    isDraft: pr.isDraft === true,
    createdAt: normalizeText(pr.createdAt) || null,
    updatedAt: normalizeText(pr.updatedAt) || null,
    baseRefName: normalizeText(pr.baseRefName) || null,
    headRefName: normalizeText(pr.headRefName) || null,
    headRefOid: normalizeText(pr.headRefOid) || null,
    mergeStateStatus: normalizeText(pr.mergeStateStatus) || null,
    mergeable: normalizeText(pr.mergeable) || null,
    reviewDecision: normalizeText(pr.reviewDecision) || null,
    statusCheckRollup: summarizeCheckRollup(statusCheckRollupNodes),
    repository: normalizeText(pr.repository?.nameWithOwner) || normalizeText(pr.repository) || fallbackRepository || null,
    headRepositoryOwner: normalizeText(pr.headRepositoryOwner?.login) || normalizeText(pr.headRepositoryOwner) || null,
    isCrossRepository: pr.isCrossRepository === true
  };
}

function collectPullRequestCandidates(issue, epicNumber = null) {
  const candidates = [];
  for (const pullRequest of issue.pullRequests ?? []) {
    if (normalizeText(pullRequest.state) !== 'OPEN') continue;
    const prStatus = classifyPullRequestWork(pullRequest);
    candidates.push({
      issue,
      epicNumber,
      pullRequest,
      prStatus
    });
  }
  return candidates;
}

function buildIssueGraphSummary(issueGraph) {
  const standingIssue = issueGraph?.standingIssue ?? null;
  const selectedIssue = issueGraph?.selectedIssue ?? null;
  return {
    standingIssueNumber: standingIssue?.number ?? null,
    selectedIssueNumber: selectedIssue?.number ?? null,
    standingIsEpic: standingIssue?.epic === true,
    openChildIssueCount: Array.isArray(issueGraph?.subIssues)
      ? issueGraph.subIssues.filter((issue) => normalizeText(issue.state) === 'OPEN').length
      : 0,
    openPullRequestCount: Array.isArray(issueGraph?.pullRequests)
      ? issueGraph.pullRequests.filter((pullRequest) => normalizeText(pullRequest.state) === 'OPEN').length
      : 0
  };
}
function selectCanonicalCandidate({
  issueGraph,
  implementationRemote,
  repoRoot = process.cwd(),
  branchClassContract = null,
  loadBranchClassContractFn = loadBranchClassContract,
  deps = {}
}) {
  const standingIssue = issueGraph?.standingIssue ?? null;
  if (!standingIssue) {
    return null;
  }

  const openStandingPullRequests = collectPullRequestCandidates(standingIssue, standingIssue.epic === true ? standingIssue.number : null);
  const openChildIssues = Array.isArray(issueGraph?.subIssues)
    ? issueGraph.subIssues.filter((issue) => normalizeText(issue.state) === 'OPEN')
    : [];
  const actionableChildIssues = openChildIssues.filter((issue) => {
    if (collectPullRequestCandidates(issue).length > 0) {
      return false;
    }
    const localLaneState = inspectLocalMergedLaneState({
      issue,
      implementationRemote,
      repoRoot,
      branchClassContract,
      loadBranchClassContractFn,
      deps
    });
    return localLaneState?.stale !== true;
  });
  const childPullRequests = openChildIssues.flatMap((issue) => collectPullRequestCandidates(issue, standingIssue.epic === true ? standingIssue.number : null));
  const prCandidates = dedupePullRequests(
    [...openStandingPullRequests, ...childPullRequests].map((entry) => ({
      ...entry.pullRequest,
      _candidate: entry
    }))
  )
    .map((pullRequest) => pullRequest._candidate)
    .sort((left, right) => {
      const lifecycleDelta = prLifecyclePriority(left.prStatus) - prLifecyclePriority(right.prStatus);
      if (lifecycleDelta !== 0) return lifecycleDelta;
      return compareIssueRank(left.issue, right.issue);
    });

  const selectedChild = actionableChildIssues.length > 0 ? selectBestIssueCandidate(actionableChildIssues) : null;
  const selectedPullRequestCandidate = prCandidates[0] ?? null;

  if (selectedPullRequestCandidate && !(selectedChild && canOffloadPullRequestForWorkSteal(selectedPullRequestCandidate.prStatus))) {
    const selected = selectedPullRequestCandidate;
    return {
      actionType: 'existing-pr-unblock',
      laneLifecycle: selected.prStatus.laneLifecycle,
      selectedIssue: selected.issue,
      epicNumber: selected.epicNumber,
      pullRequest: selected.pullRequest,
      pullRequestStatus: selected.prStatus,
      branch:
        normalizeText(selected.pullRequest.headRefName) ||
        resolveIssueBranchName({
          issueNumber: selected.issue.number,
          title: selected.issue.title,
          implementationRemote,
          repoRoot,
          branchClassContract,
          loadBranchClassContractFn
        })
    };
  }

  if (selectedChild) {
    return {
      actionType: 'advance-child-issue',
      laneLifecycle: 'coding',
      selectedIssue: selectedChild,
      epicNumber: standingIssue.epic === true ? standingIssue.number : null,
      pullRequest: null,
      pullRequestStatus: null,
      offloadedPullRequest: summarizeOffloadedPullRequestCandidate(selectedPullRequestCandidate),
      branch: resolveIssueBranchName({
        issueNumber: selectedChild.number,
        title: selectedChild.title,
        implementationRemote,
        repoRoot,
        branchClassContract,
        loadBranchClassContractFn
      })
    };
  }

  if (standingIssue.epic === true) {
    return {
      actionType: 'reshape-backlog',
      laneLifecycle: 'reshaping-backlog',
      selectedIssue: standingIssue,
      epicNumber: standingIssue.number,
      pullRequest: null,
      pullRequestStatus: null,
      backlogRepair: {
        mode: 'repair-child-slice',
        parentIssueNumber: standingIssue.number,
        parentIssueUrl: standingIssue.url,
        reason: 'standing epic has no executable open child issues'
      },
      branch: resolveIssueBranchName({
        issueNumber: standingIssue.number,
        title: standingIssue.title,
        implementationRemote,
        repoRoot,
        branchClassContract,
        loadBranchClassContractFn
      })
    };
  }

  return {
    actionType: 'advance-standing-issue',
    laneLifecycle: 'coding',
    selectedIssue: standingIssue,
    epicNumber: null,
    pullRequest: null,
    pullRequestStatus: null,
    branch: resolveIssueBranchName({
      issueNumber: standingIssue.number,
      title: standingIssue.title,
      implementationRemote,
      repoRoot,
      branchClassContract,
      loadBranchClassContractFn
    })
  };
}

function buildGraphqlArgs(query, variables = {}) {
  const args = ['api', 'graphql', '-f', `query=${query}`];
  for (const [key, value] of Object.entries(variables)) {
    if (value == null) continue;
    const switchName = typeof value === 'number' ? '-F' : '-f';
    args.push(switchName, `${key}=${String(value)}`);
  }
  return args;
}

function runGhGraphql(repoRoot, query, variables = {}, deps = {}) {
  if (typeof deps.runGhGraphqlFn === 'function') {
    return deps.runGhGraphqlFn({ repoRoot, query, variables });
  }
  const result = spawnSync('gh', buildGraphqlArgs(query, variables), {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES
  });
  if (result.status !== 0) {
    throw new Error(`gh api graphql failed (${result.status}): ${normalizeText(result.stderr) || 'unknown error'}`);
  }
  return JSON.parse(result.stdout || '{}');
}

function runGhApiJson(repoRoot, endpoint, deps = {}) {
  if (typeof deps.runGhApiJsonFn === 'function') {
    return deps.runGhApiJsonFn({ repoRoot, endpoint });
  }
  const result = spawnSync('gh', ['api', endpoint], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES
  });
  if (result.status !== 0) {
    throw new Error(`gh api ${endpoint} failed (${result.status}): ${normalizeText(result.stderr) || 'unknown error'}`);
  }
  return JSON.parse(result.stdout || '{}');
}

function normalizeCopilotReviewWorkflowRun(run, headSha) {
  if (!run || typeof run !== 'object') {
    return null;
  }
  const workflowName = normalizeText(run.name || run.workflowName);
  const normalizedHeadSha = normalizeText(run.head_sha || run.headSha).toLowerCase() || null;
  if (!workflowName || !normalizedHeadSha || (headSha && normalizedHeadSha !== String(headSha).trim().toLowerCase())) {
    return null;
  }
  return {
    workflowName,
    runId: coercePositiveInteger(run.id || run.databaseId),
    event: normalizeText(run.event) || null,
    status: normalizeText(run.status).toUpperCase() || null,
    conclusion: normalizeText(run.conclusion).toUpperCase() || null,
    url: normalizeText(run.html_url || run.url) || null,
    headSha: normalizedHeadSha,
    createdAt: normalizeText(run.created_at || run.createdAt) || null,
    updatedAt: normalizeText(run.updated_at || run.updatedAt) || null
  };
}

function selectCopilotReviewWorkflowRun(runs, headSha) {
  const normalizedHeadSha = normalizeText(headSha).toLowerCase() || null;
  if (!normalizedHeadSha) {
    return null;
  }
  const normalizedRuns = (Array.isArray(runs) ? runs : [])
    .map((run) => normalizeCopilotReviewWorkflowRun(run, normalizedHeadSha))
    .filter(Boolean)
    .filter((run) => run.workflowName === COPILOT_REVIEW_WORKFLOW_NAME)
    .sort((left, right) => {
      const byUpdatedAt = normalizeText(right.updatedAt).localeCompare(normalizeText(left.updatedAt));
      if (byUpdatedAt !== 0) {
        return byUpdatedAt;
      }
      return (right.runId ?? 0) - (left.runId ?? 0);
    });
  return normalizedRuns[0] ?? null;
}

async function loadCopilotReviewWorkflowRun({ repoRoot, repository, headSha, deps = {} }) {
  if (!normalizeText(repository) || !normalizeText(headSha)) {
    return null;
  }
  if (typeof deps.loadCopilotReviewWorkflowRunFn === 'function') {
    return await deps.loadCopilotReviewWorkflowRunFn({ repoRoot, repository, headSha });
  }
  const { owner, repo } = parseRepositorySlug(repository);
  const endpoint = `repos/${owner}/${repo}/actions/runs?head_sha=${encodeURIComponent(headSha)}&per_page=100`;
  const payload = runGhApiJson(repoRoot, endpoint, deps);
  return selectCopilotReviewWorkflowRun(payload?.workflow_runs, headSha);
}

function isCopilotLogin(login) {
  const normalized = normalizeText(login).toLowerCase();
  return normalized ? COPILOT_LOGINS.has(normalized) : false;
}

function normalizeCopilotReview(review, headSha) {
  if (!isCopilotLogin(review?.user?.login)) {
    return null;
  }
  const commitId = normalizeText(review?.commit_id).toLowerCase() || null;
  return {
    id: coercePositiveInteger(review?.id) ?? (normalizeText(review?.id) || null),
    state: normalizeText(review?.state) || null,
    commitId,
    submittedAt: normalizeText(review?.submitted_at) || null,
    url: normalizeText(review?.html_url) || null,
    isCurrentHead: Boolean(headSha && commitId && commitId === String(headSha).trim().toLowerCase())
  };
}

function normalizeCopilotThreadComment(comment, headSha) {
  const authorLogin = normalizeText(comment?.author?.login) || normalizeText(comment?.pullRequestReview?.author?.login);
  if (!isCopilotLogin(authorLogin)) {
    return null;
  }
  const commitId = normalizeText(comment?.pullRequestReview?.commit?.oid || comment?.originalCommit?.oid).toLowerCase() || null;
  return {
    id: normalizeText(comment?.id) || null,
    url: normalizeText(comment?.url) || null,
    publishedAt: normalizeText(comment?.publishedAt || comment?.createdAt) || null,
    commitId,
    isCurrentHead: Boolean(headSha && commitId && commitId === String(headSha).trim().toLowerCase())
  };
}

function normalizeCopilotThread(thread, headSha) {
  const comments = Array.isArray(thread?.comments?.nodes)
    ? thread.comments.nodes
        .map((comment) => normalizeCopilotThreadComment(comment, headSha))
        .filter(Boolean)
    : [];
  if (comments.length === 0) {
    return null;
  }
  const actionableComments = comments.filter((comment) => comment.isCurrentHead);
  return {
    threadId: normalizeText(thread?.id) || null,
    path: normalizeText(thread?.path) || null,
    line: coercePositiveInteger(thread?.line),
    originalLine: coercePositiveInteger(thread?.originalLine),
    isResolved: thread?.isResolved === true,
    isOutdated: thread?.isOutdated === true,
    actionableComments
  };
}

async function loadCopilotReviewSignal({ repoRoot, repository, pullRequestNumber, headSha, deps = {} }) {
  if (!normalizeText(repository) || !coercePositiveInteger(pullRequestNumber) || !normalizeText(headSha)) {
    return null;
  }
  if (typeof deps.loadCopilotReviewSignalFn === 'function') {
    return await deps.loadCopilotReviewSignalFn({ repoRoot, repository, pullRequestNumber, headSha });
  }
  const { owner, repo } = parseRepositorySlug(repository);
  const reviewsPayload = runGhApiJson(repoRoot, `repos/${owner}/${repo}/pulls/${pullRequestNumber}/reviews?per_page=100`, deps);
  const threadsPayload = runGhGraphql(
    repoRoot,
    REVIEW_THREADS_QUERY,
    { owner, repo, number: pullRequestNumber },
    deps
  );
  const reviews = (Array.isArray(reviewsPayload) ? reviewsPayload : [])
    .map((review) => normalizeCopilotReview(review, headSha))
    .filter(Boolean)
    .sort((left, right) => normalizeText(right.submittedAt).localeCompare(normalizeText(left.submittedAt)));
  const threads = (threadsPayload?.data?.repository?.pullRequest?.reviewThreads?.nodes ?? [])
    .map((thread) => normalizeCopilotThread(thread, headSha))
    .filter(Boolean);
  const actionableThreads = threads.filter(
    (thread) => thread.isResolved !== true && thread.isOutdated !== true && thread.actionableComments.length > 0
  );
  return {
    hasCopilotReview: reviews.length > 0,
    hasCurrentHeadReview: reviews.some((review) => review.isCurrentHead),
    latestCopilotReview: reviews[0] ?? null,
    actionableThreadCount: actionableThreads.length,
    actionableCommentCount: actionableThreads.reduce((total, thread) => total + thread.actionableComments.length, 0)
  };
}

export async function loadDeliveryAgentPolicy(repoRoot, deps = {}) {
  if (typeof deps.loadDeliveryAgentPolicyFn === 'function') {
    return deps.loadDeliveryAgentPolicyFn({ repoRoot, defaultPolicy: { ...DEFAULT_POLICY } });
  }
  const policyPath = resolvePath(repoRoot, deps.policyPath || DELIVERY_AGENT_POLICY_RELATIVE_PATH);
  const filePolicy = await readJsonIfPresent(policyPath);
  const requestedMaxActiveCodingLanes =
    coercePositiveInteger(filePolicy?.maxActiveCodingLanes) ?? DEFAULT_POLICY.maxActiveCodingLanes;
  const workerPool = normalizeWorkerPoolPolicy(filePolicy?.workerPool, {
    maxActiveCodingLanes: requestedMaxActiveCodingLanes
  });
  return {
    ...DEFAULT_POLICY,
    ...(filePolicy && typeof filePolicy === 'object' ? filePolicy : {}),
    schema: DELIVERY_AGENT_POLICY_SCHEMA,
    copilotReviewStrategy: normalizeCopilotReviewStrategy(filePolicy?.copilotReviewStrategy),
    maxActiveCodingLanes: Math.max(requestedMaxActiveCodingLanes, workerPool.targetSlotCount),
    workerPool,
    turnBudget: {
      ...DEFAULT_POLICY.turnBudget,
      ...(filePolicy?.turnBudget && typeof filePolicy.turnBudget === 'object' ? filePolicy.turnBudget : {})
    },
    retry: {
      ...DEFAULT_POLICY.retry,
      ...(filePolicy?.retry && typeof filePolicy.retry === 'object' ? filePolicy.retry : {})
    },
    hostIsolation: {
      ...DEFAULT_POLICY.hostIsolation,
      ...(filePolicy?.hostIsolation && typeof filePolicy.hostIsolation === 'object' ? filePolicy.hostIsolation : {})
    },
    dockerRuntime: {
      ...DEFAULT_POLICY.dockerRuntime,
      ...(filePolicy?.dockerRuntime && typeof filePolicy.dockerRuntime === 'object' ? filePolicy.dockerRuntime : {})
    },
    concurrentLaneDispatch: normalizeConcurrentLaneDispatchPolicy(filePolicy?.concurrentLaneDispatch),
    localReviewLoop: normalizeLocalReviewLoopPolicy(filePolicy?.localReviewLoop),
    codingTurnCommand: normalizeCommandList(filePolicy?.codingTurnCommand)
  };
}

export async function fetchIssueExecutionGraph({ repoRoot, repository, issueNumber, deps = {} }) {
  if (typeof deps.fetchIssueExecutionGraphFn === 'function') {
    return deps.fetchIssueExecutionGraphFn({ repoRoot, repository, issueNumber });
  }

  const { owner, repo } = parseRepositorySlug(repository);
  const query = `
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) {
          id
          number
          title
          body
          url
          state
          createdAt
          updatedAt
          labels(first: 50) { nodes { name } }
          subIssues(first: 25) {
            totalCount
            nodes {
              id
              number
              title
              body
              url
              state
              createdAt
              updatedAt
              labels(first: 20) { nodes { name } }
              timelineItems(first: 25, itemTypes: [CROSS_REFERENCED_EVENT]) {
                nodes {
                  ... on CrossReferencedEvent {
                    source {
                      __typename
                      ... on PullRequest {
                        id
                        number
                        title
                        url
                        state
                        isDraft
                        createdAt
                        updatedAt
                        baseRefName
                        headRefName
                        headRefOid
                        mergeStateStatus
                        mergeable
                        reviewDecision
                        isCrossRepository
                        headRepositoryOwner { login }
                        repository { nameWithOwner }
                        statusCheckRollup {
                          contexts(first: 50) {
                            nodes {
                              __typename
                              ... on CheckRun {
                                name
                                status
                                conclusion
                                detailsUrl
                              }
                              ... on StatusContext {
                                context
                                state
                                targetUrl
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          timelineItems(first: 25, itemTypes: [CROSS_REFERENCED_EVENT]) {
            nodes {
              ... on CrossReferencedEvent {
                source {
                  __typename
                  ... on PullRequest {
                    id
                    number
                    title
                    url
                    state
                    isDraft
                    createdAt
                    updatedAt
                    baseRefName
                    headRefName
                    headRefOid
                    mergeStateStatus
                    mergeable
                    reviewDecision
                    isCrossRepository
                    headRepositoryOwner { login }
                    repository { nameWithOwner }
                    statusCheckRollup {
                      contexts(first: 50) {
                        nodes {
                          __typename
                          ... on CheckRun {
                            name
                            status
                            conclusion
                            detailsUrl
                          }
                          ... on StatusContext {
                            context
                            state
                            targetUrl
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  `;
  const payload = runGhGraphql(repoRoot, query, { owner, repo, number: issueNumber }, deps);
  const issueNode = payload?.data?.repository?.issue;
  if (!issueNode?.number) {
    throw new Error(`Unable to resolve execution graph for issue #${issueNumber} in ${repository}.`);
  }

  const standingIssue = normalizeIssueLike(issueNode, { repository });
  const standingPullRequests = dedupePullRequests(
    (issueNode.timelineItems?.nodes ?? [])
      .map((entry) => normalizePullRequest(entry?.source?.__typename === 'PullRequest' ? entry.source : null, repository))
      .filter(Boolean)
  );
  const subIssues = (issueNode.subIssues?.nodes ?? [])
    .map((entry) => {
      const normalizedIssue = normalizeIssueLike(entry, { repository });
      if (!normalizedIssue) return null;
      return {
        ...normalizedIssue,
        pullRequests: dedupePullRequests(
          (entry.timelineItems?.nodes ?? [])
            .map((item) => normalizePullRequest(item?.source?.__typename === 'PullRequest' ? item.source : null, repository))
            .filter(Boolean)
        )
      };
    })
    .filter(Boolean);

  return {
    standingIssue: {
      ...standingIssue,
      pullRequests: standingPullRequests
    },
    subIssues,
    pullRequests: dedupePullRequests([
      ...standingPullRequests,
      ...subIssues.flatMap((issue) => issue.pullRequests ?? [])
    ])
  };
}

export async function buildCanonicalDeliveryDecision({
  repoRoot,
  issueSnapshot,
  issueGraph,
  upstreamRepository,
  targetRepository,
  policy,
  source = 'comparevi-standing-priority-live',
  deps = {},
  now = new Date()
}) {
  const effectivePolicy = policy ?? (await loadDeliveryAgentPolicy(repoRoot));
  const implementationRemote = normalizeText(effectivePolicy.implementationRemote) || 'origin';
  const standingIssue = normalizeIssueLike(issueSnapshot, { repository: targetRepository || upstreamRepository });
  if (!standingIssue) {
    return null;
  }
  const graph = issueGraph ?? {
    standingIssue: {
      ...standingIssue,
      pullRequests: []
    },
    subIssues: [],
    pullRequests: []
  };
  const selected = selectCanonicalCandidate({
    issueGraph: graph,
    implementationRemote,
    repoRoot,
    loadBranchClassContractFn: deps.loadBranchClassContractFn,
    deps
  });
  if (!selected?.selectedIssue) {
    return null;
  }
  const selectedIssue = selected.selectedIssue;
  let pullRequest = selected.pullRequest ?? null;
  let pullRequestStatus = selected.pullRequestStatus ?? null;
  if (pullRequest && shouldLoadCopilotReviewMetadata(pullRequest, pullRequestStatus)) {
    const pullRequestRepository =
      normalizeText(pullRequest.repository) ||
      normalizeText(targetRepository) ||
      normalizeText(upstreamRepository) ||
      null;
    let reviewWorkflow = null;
    let reviewSignal = null;
    try {
      ({ reviewWorkflow, reviewSignal } = await loadCachedCopilotReviewMetadata({
        repoRoot,
        repository: pullRequestRepository,
        pullRequestNumber: pullRequest.number,
        headSha: pullRequest.headRefOid,
        deps,
        now
      }));
    } catch {
      reviewWorkflow = null;
      reviewSignal = null;
    }
    if (reviewWorkflow || reviewSignal) {
      pullRequest = {
        ...pullRequest,
        copilotReviewWorkflow: reviewWorkflow,
        copilotReviewSignal: reviewSignal
      };
      pullRequestStatus = classifyPullRequestWork(pullRequest);
    }
  }
  const blockerClass = pullRequestStatus?.blockerClass ?? 'none';
  const laneId = `${implementationRemote}-${selectedIssue.number}`;
  const reason =
    selected.actionType === 'existing-pr-unblock'
      ? `standing issue #${standingIssue.number} prioritizes existing PR #${pullRequest.number} for issue #${selectedIssue.number}`
      : selected.actionType === 'advance-child-issue'
        ? selected.offloadedPullRequest?.pullRequestNumber
          ? `standing epic #${standingIssue.number} work-steals onto child issue #${selectedIssue.number} while PR #${selected.offloadedPullRequest.pullRequestNumber} waits for ${selected.offloadedPullRequest.nextWakeCondition || 'external progress'}`
          : `standing epic #${standingIssue.number} selects child issue #${selectedIssue.number}`
        : selected.actionType === 'reshape-backlog'
          ? `standing epic #${standingIssue.number} requires child-slice repair before coding`
          : `standing issue #${selectedIssue.number}`;

  return {
    source,
    outcome: 'selected',
    reason,
    stepOptions: {
      lane: laneId,
      issue: selectedIssue.number,
      epic: selected.epicNumber,
      forkRemote: implementationRemote,
      branch: selected.branch,
      prUrl: pullRequest?.url ?? null,
      blockerClass
    },
    artifacts: {
      standingIssueNumber: standingIssue.number,
      standingRepository: normalizeText(targetRepository) || normalizeText(upstreamRepository) || null,
      canonicalIssueNumber: selectedIssue.number,
      canonicalRepository: normalizeText(upstreamRepository) || normalizeText(targetRepository) || null,
      issueUrl: selectedIssue.url,
      issueTitle: selectedIssue.title,
      cadence: false,
      executionMode: 'canonical-delivery',
      selectedActionType: selected.actionType,
      laneLifecycle: pullRequestStatus?.laneLifecycle ?? selected.laneLifecycle,
      selectedIssueSnapshot: selectedIssue,
      standingIssueSnapshot: standingIssue,
      issueGraph: buildIssueGraphSummary({
        ...graph,
        selectedIssue
      }),
      backlogRepair: selected.backlogRepair ?? null,
      pullRequest:
        pullRequest == null
          ? null
          : {
              number: pullRequest.number,
              url: pullRequest.url,
              title: pullRequest.title,
              state: pullRequest.state,
              isDraft: pullRequest.isDraft === true,
              headRefName: pullRequest.headRefName,
              headRefOid: pullRequest.headRefOid,
              baseRefName: pullRequest.baseRefName,
              reviewDecision: pullRequest.reviewDecision,
              mergeStateStatus: pullRequest.mergeStateStatus,
              mergeable: pullRequest.mergeable,
              syncRequired: pullRequestStatus?.syncRequired === true,
              nextWakeCondition: pullRequestStatus?.nextWakeCondition ?? null,
              pollIntervalSecondsHint: pullRequestStatus?.pollIntervalSecondsHint ?? null,
              copilotReviewWorkflow:
                pullRequestStatus?.reviewMonitor?.workflow ??
                pullRequest.copilotReviewWorkflow ??
                null,
              copilotReviewSignal:
                pullRequestStatus?.reviewMonitor?.signal ??
                pullRequest.copilotReviewSignal ??
                null,
              checks: {
                status: pullRequestStatus?.checksStatus ?? 'not-linked',
                blockerClass: pullRequestStatus?.blockerClass ?? 'none'
              },
              readyToMerge: pullRequestStatus?.readyToMerge === true
            },
      offloadedPullRequest: selected.offloadedPullRequest ?? null
    }
  };
}

function isRateLimitMessage(message) {
  return /rate limit/i.test(normalizeText(message));
}

function shouldLoadCopilotReviewMetadata(pr, prStatus = null) {
  if (!pr?.headRefOid) {
    return false;
  }
  const laneLifecycle = normalizeText(prStatus?.laneLifecycle).toLowerCase();
  if (laneLifecycle === 'waiting-review' || laneLifecycle === 'coding') {
    return true;
  }
  if (laneLifecycle !== 'ready-merge') {
    return false;
  }
  const reviewDecision = normalizeText(pr.reviewDecision).toUpperCase();
  const mergeStateStatus = normalizeText(pr.mergeStateStatus).toUpperCase();
  return !reviewDecision && mergeStateStatus === 'BLOCKED';
}

function resolveCopilotReviewMetadataCachePath({ repoRoot, repository, pullRequestNumber, headSha }) {
  const repositorySegment = sanitizeSegment(repository || 'repo');
  const pullRequestSegment = sanitizeSegment(`pr-${pullRequestNumber || 'unknown'}`);
  const headSegment = sanitizeSegment(headSha || 'head');
  return path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'runtime',
    'copilot-review-cache',
    `${repositorySegment}-${pullRequestSegment}-${headSegment}.json`
  );
}

async function pruneCopilotReviewMetadataCache({ repoRoot, repository, pullRequestNumber, headSha, now = new Date() }) {
  const cachePath = resolveCopilotReviewMetadataCachePath({
    repoRoot,
    repository,
    pullRequestNumber,
    headSha
  });
  const cacheDir = path.dirname(cachePath);
  const repositorySegment = sanitizeSegment(repository || 'repo');
  const pullRequestSegment = sanitizeSegment(`pr-${pullRequestNumber || 'unknown'}`);
  const cachePrefix = `${repositorySegment}-${pullRequestSegment}-`;
  const nowTime = now instanceof Date ? now.getTime() : Date.parse(now);
  let entries = [];
  try {
    entries = await readdir(cacheDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return;
    }
    throw error;
  }
  await Promise.all(
    entries
      .filter((entry) => entry.isFile() && entry.name.startsWith(cachePrefix) && entry.name.endsWith('.json'))
      .map(async (entry) => {
        const entryPath = path.join(cacheDir, entry.name);
        if (entryPath === cachePath) {
          return;
        }
        await rm(entryPath, { force: true });
      })
  );
  await Promise.all(
    entries
      .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
      .map(async (entry) => {
        const entryPath = path.join(cacheDir, entry.name);
        if (entryPath === cachePath) {
          return;
        }
        const cached = await readJsonIfPresent(entryPath, { deleteCorrupt: true });
        const generatedAt = Date.parse(cached?.generatedAt || '');
        if (
          Number.isFinite(nowTime) &&
          Number.isFinite(generatedAt) &&
          nowTime - generatedAt > COPILOT_REVIEW_METADATA_RETENTION_MS
        ) {
          await rm(entryPath, { force: true });
        }
      })
  );
}

async function loadCachedCopilotReviewMetadata({
  repoRoot,
  repository,
  pullRequestNumber,
  headSha,
  deps = {},
  now = new Date()
}) {
  const cachePath = resolveCopilotReviewMetadataCachePath({
    repoRoot,
    repository,
    pullRequestNumber,
    headSha
  });
  const cached = await readJsonIfPresent(cachePath, { deleteCorrupt: true });
  const nowTime = now instanceof Date ? now.getTime() : Date.parse(now);
  const cachedTime = Date.parse(cached?.generatedAt || '');
  if (
    cached &&
    cached.repository === repository &&
    cached.pullRequestNumber === pullRequestNumber &&
    cached.headSha === headSha &&
    Number.isFinite(nowTime) &&
    Number.isFinite(cachedTime) &&
    nowTime - cachedTime <= COPILOT_REVIEW_METADATA_CACHE_TTL_MS
  ) {
    return {
      reviewWorkflow: cached.reviewWorkflow ?? null,
      reviewSignal: cached.reviewSignal ?? null
    };
  }
  const reviewWorkflow = await loadCopilotReviewWorkflowRun({
    repoRoot,
    repository,
    headSha,
    deps
  });
  const reviewSignal = await loadCopilotReviewSignal({
    repoRoot,
    repository,
    pullRequestNumber,
    headSha,
    deps
  });
  await mkdir(path.dirname(cachePath), { recursive: true });
  await writeJsonAtomically(
    cachePath,
    JSON.stringify(
      {
        generatedAt: Number.isFinite(nowTime) ? new Date(nowTime).toISOString() : toIso(),
        repository,
        pullRequestNumber,
        headSha,
        reviewWorkflow,
        reviewSignal
      },
      null,
      2
    )
  );
  await pruneCopilotReviewMetadataCache({
    repoRoot,
    repository,
    pullRequestNumber,
    headSha,
    now
  });
  return {
    reviewWorkflow,
    reviewSignal
  };
}

function extractIssueNumberFromUrl(url) {
  const match = normalizeText(url).match(/\/issues\/(\d+)$/i);
  return coercePositiveInteger(match?.[1]);
}

function extractPullRequestNumberFromUrl(url) {
  const match = normalizeText(url).match(/\/pull\/(\d+)$/i);
  return coercePositiveInteger(match?.[1]);
}

function normalizeLifecycle(value, fallback = 'idle') {
  const normalized = normalizeText(value).toLowerCase();
  return DELIVERY_AGENT_LIFECYCLE_STATES.has(normalized) ? normalized : fallback;
}

function laneLifecycleConsumesWorkerSlot(lifecycle, releaseWaitingStates = []) {
  const normalizedLifecycle = normalizeLifecycle(lifecycle, 'idle');
  if (releaseWaitingStates.includes(normalizedLifecycle)) {
    return false;
  }
  return normalizedLifecycle === 'planning' || normalizedLifecycle === 'reshaping-backlog' || normalizedLifecycle === 'coding';
}

function buildWorkerPoolRuntimeState({ policy, laneId, issue, laneLifecycle, preferredSlotId = null }) {
  const workerPoolPolicy = buildWorkerPoolPolicySnapshot(policy);
  const slots = [];
  let slotIndex = 0;
  for (const provider of workerPoolPolicy.providers.filter((entry) => entry.enabled !== false)) {
    const slotCount = coercePositiveInteger(provider.slotCount) ?? 1;
    for (let providerSlot = 0; providerSlot < slotCount && slotIndex < workerPoolPolicy.targetSlotCount; providerSlot += 1) {
      slotIndex += 1;
      slots.push({
        slotId: `worker-slot-${slotIndex}`,
        providerId: provider.id,
        providerKind: provider.kind,
        executionPlane: provider.executionPlane,
        assignmentMode: provider.assignmentMode,
        dispatchSurface: provider.dispatchSurface,
        completionMode: provider.completionMode,
        requiresLocalCheckout: provider.requiresLocalCheckout,
        status: 'available',
        laneId: null,
        issue: null,
        laneLifecycle: null
      });
    }
  }
  while (slots.length < workerPoolPolicy.targetSlotCount) {
    slots.push({
      slotId: `worker-slot-${slots.length + 1}`,
      providerId: null,
      providerKind: null,
      executionPlane: null,
      assignmentMode: null,
      dispatchSurface: null,
      completionMode: null,
      requiresLocalCheckout: null,
      status: 'available',
      laneId: null,
      issue: null,
      laneLifecycle: null
    });
  }

  const releasedLanes = [];
  const preferredSlotIndex = slots.findIndex((slot) => slot.slotId === normalizeText(preferredSlotId));
  const selectedSlotIndex = preferredSlotIndex >= 0 ? preferredSlotIndex : 0;
  const selectedSlotId =
    preferredSlotIndex >= 0 ? slots[selectedSlotIndex]?.slotId ?? null : normalizeText(preferredSlotId) || null;
  if (workerPoolPolicy.releaseWaitingStates.includes(laneLifecycle) && selectedSlotId) {
    releasedLanes.push({
      slotId: selectedSlotId,
      laneId,
      issue,
      laneLifecycle,
      releaseReason: 'waiting-state-released'
    });
  } else if (laneLifecycleConsumesWorkerSlot(laneLifecycle, workerPoolPolicy.releaseWaitingStates) && slots.length > 0) {
    slots[selectedSlotIndex] = {
      ...slots[selectedSlotIndex],
      status: 'occupied',
      laneId,
      issue,
      laneLifecycle
    };
  }

  const occupiedSlotCount = slots.filter((slot) => slot.status === 'occupied').length;
  const availableSlotCount = slots.filter((slot) => slot.status === 'available').length;
  return {
    targetSlotCount: workerPoolPolicy.targetSlotCount,
    prewarmSlotCount: workerPoolPolicy.prewarmSlotCount,
    releaseWaitingStates: [...workerPoolPolicy.releaseWaitingStates],
    providers: workerPoolPolicy.providers.map((provider) => ({ ...provider })),
    slots,
    occupiedSlotCount,
    availableSlotCount,
    releasedLaneCount: releasedLanes.length,
    releasedLanes,
    utilizationRatio:
      workerPoolPolicy.targetSlotCount > 0
        ? Number((occupiedSlotCount / workerPoolPolicy.targetSlotCount).toFixed(4))
        : 0
  };
}

function normalizeOptionalObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function toRepoRelativePath(repoRoot, candidatePath) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    return null;
  }
  const resolved = path.isAbsolute(normalized) ? normalized : path.resolve(repoRoot, normalized);
  const relative = path.relative(repoRoot, resolved);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
    return normalized;
  }
  return relative.replaceAll('\\', '/');
}

function buildConcurrentLaneApplyRuntimeState({ taskPacket, executionReceipt }) {
  const concurrentLaneApply =
    normalizeOptionalObject(executionReceipt?.details?.concurrentLaneApply) ??
    normalizeOptionalObject(taskPacket?.evidence?.delivery?.concurrentLaneApply);
  if (!concurrentLaneApply) {
    return null;
  }

  const validateDispatch = normalizeOptionalObject(concurrentLaneApply.validateDispatch);
  return {
    receiptPath: normalizeText(concurrentLaneApply.receiptPath) || null,
    status: normalizeText(concurrentLaneApply.status) || null,
    selectedBundleId: normalizeText(concurrentLaneApply.selectedBundleId) || null,
        validateDispatch: validateDispatch
      ? {
          status: normalizeText(validateDispatch.status) || null,
          repository: normalizeText(validateDispatch.repository) || null,
          remote: normalizeText(validateDispatch.remote) || null,
          ref: normalizeText(validateDispatch.ref) || null,
          sampleIdStrategy: normalizeText(validateDispatch.sampleIdStrategy) || null,
          sampleId: normalizeText(validateDispatch.sampleId) || null,
          historyScenarioSet: normalizeText(validateDispatch.historyScenarioSet) || null,
          allowFork: validateDispatch.allowFork === true,
          pushMissing: validateDispatch.pushMissing === true,
          forcePushOk: validateDispatch.forcePushOk === true,
          allowNonCanonicalViHistory: validateDispatch.allowNonCanonicalViHistory === true,
          allowNonCanonicalHistoryCore: validateDispatch.allowNonCanonicalHistoryCore === true,
          reportPath: normalizeText(validateDispatch.reportPath) || null,
          runDatabaseId: coercePositiveInteger(validateDispatch.runDatabaseId),
          error: normalizeText(validateDispatch.error) || null
        }
      : null
  };
}

function buildConcurrentLaneStatusRuntimeState({ taskPacket, executionReceipt }) {
  const concurrentLaneStatus =
    normalizeOptionalObject(executionReceipt?.details?.concurrentLaneStatus) ??
    normalizeOptionalObject(taskPacket?.evidence?.delivery?.concurrentLaneStatus);
  if (!concurrentLaneStatus) {
    return null;
  }

  const summary = normalizeOptionalObject(concurrentLaneStatus.summary);
  const hostedRun = normalizeOptionalObject(concurrentLaneStatus.hostedRun);
  const pullRequest = normalizeOptionalObject(concurrentLaneStatus.pullRequest);
  const mergeQueue = normalizeOptionalObject(pullRequest?.mergeQueue);

  return {
    receiptPath: normalizeText(concurrentLaneStatus.receiptPath) || null,
    status: normalizeText(concurrentLaneStatus.status) || null,
    selectedBundleId: normalizeText(concurrentLaneStatus.selectedBundleId) || null,
    hostedRun: hostedRun
      ? {
          observationStatus: normalizeText(hostedRun.observationStatus) || null,
          runId: coercePositiveInteger(hostedRun.runId),
          url: normalizeText(hostedRun.url) || null,
          reportPath: normalizeText(hostedRun.reportPath) || null
        }
      : null,
    pullRequest: pullRequest
      ? {
          observationStatus: normalizeText(pullRequest.observationStatus) || null,
          number: coercePositiveInteger(pullRequest.number),
          url: normalizeText(pullRequest.url) || null,
          mergeQueue: mergeQueue
            ? {
                status: normalizeText(mergeQueue.status) || null,
                position: coercePositiveInteger(mergeQueue.position),
                estimatedTimeToMerge: coercePositiveInteger(mergeQueue.estimatedTimeToMerge),
                enqueuedAt: normalizeText(mergeQueue.enqueuedAt) || null
              }
            : null
        }
      : null,
    summary: summary
      ? {
          laneCount: coercePositiveInteger(summary.laneCount) ?? 0,
          activeLaneCount: coercePositiveInteger(summary.activeLaneCount) ?? 0,
          completedLaneCount: coercePositiveInteger(summary.completedLaneCount) ?? 0,
          failedLaneCount: coercePositiveInteger(summary.failedLaneCount) ?? 0,
          deferredLaneCount: coercePositiveInteger(summary.deferredLaneCount) ?? 0,
          manualLaneCount: coercePositiveInteger(summary.manualLaneCount) ?? 0,
          shadowLaneCount: coercePositiveInteger(summary.shadowLaneCount) ?? 0,
          pullRequestStatus: normalizeText(summary.pullRequestStatus) || null,
          orchestratorDisposition: normalizeText(summary.orchestratorDisposition) || null
        }
      : null
  };
}

function buildConcurrentLaneWatchPlan(concurrentLaneStatus = null) {
  const status = normalizeText(concurrentLaneStatus?.status).toLowerCase();
  const disposition = normalizeText(concurrentLaneStatus?.summary?.orchestratorDisposition).toLowerCase();
  if (!status && !disposition) {
    return null;
  }

  if (status === 'failed' || disposition === 'hold-investigate') {
    return {
      actionType: 'watch-concurrent-lanes',
      laneLifecycle: 'blocked',
      blockerClass: 'helper',
      retryable: true,
      nextWakeCondition: 'concurrent-lane-status-repaired',
      reason: 'Concurrent lane status receipt reported a failed or non-releasable state that needs investigation.',
      concurrentLaneStatus
    };
  }

  if (disposition === 'wait-hosted-run') {
    return {
      actionType: 'watch-concurrent-lanes',
      laneLifecycle: 'waiting-ci',
      blockerClass: 'ci',
      retryable: true,
      nextWakeCondition: 'hosted-lane-settled',
      reason: 'Hosted concurrent lane work is still queued or running remotely.',
      concurrentLaneStatus
    };
  }

  if (disposition === 'release-merge-queue') {
    return {
      actionType: 'watch-concurrent-lanes',
      laneLifecycle: 'waiting-ci',
      blockerClass: 'ci',
      retryable: true,
      nextWakeCondition: 'merge-queue-progress',
      reason: 'Concurrent lane state is now merge-queue bound, so the local worker slot can be released.',
      concurrentLaneStatus
    };
  }

  if (disposition === 'release-with-deferred-local') {
    return {
      actionType: 'watch-concurrent-lanes',
      laneLifecycle: 'waiting-ci',
      blockerClass: 'none',
      retryable: true,
      nextWakeCondition: 'deferred-local-lane-dispatched',
      reason: 'Only deferred manual or shadow lane obligations remain locally, so the coding slot can be reused.',
      concurrentLaneStatus
    };
  }

  return null;
}

function shouldDispatchConcurrentLanes(taskPacket = {}) {
  const delivery = taskPacket?.evidence?.delivery ?? {};
  const pullRequest = normalizeOptionalObject(delivery.pullRequest);
  const concurrentLaneStatus = normalizeOptionalObject(delivery.concurrentLaneStatus);
  const providerSelection = buildTaskPacketProviderSelection(taskPacket);
  if (pullRequest?.url || concurrentLaneStatus) {
    return false;
  }
  if (!providerSelection) {
    return false;
  }
  return normalizeText(providerSelection.selectedAssignmentMode).toLowerCase() === 'async-validation';
}

function buildConcurrentLaneApplyOptions({ repoRoot, taskPacket, policy }) {
  const branchName = normalizeText(taskPacket?.branch?.name);
  const forkRemote = normalizeText(taskPacket?.branch?.forkRemote).toLowerCase();
  const request = normalizeOptionalObject(taskPacket?.evidence?.delivery?.concurrentLaneDispatch);
  const concurrentLaneDispatch = normalizeConcurrentLaneDispatchPolicy({
    ...(policy?.concurrentLaneDispatch && typeof policy.concurrentLaneDispatch === 'object'
      ? policy.concurrentLaneDispatch
      : {}),
    ...(request ?? {})
  });
  const allowFork =
    concurrentLaneDispatch.allowForkMode === 'always'
      ? true
      : concurrentLaneDispatch.allowForkMode === 'never'
        ? false
        : Boolean(forkRemote && forkRemote !== 'upstream');
  const sampleIdStrategy =
    concurrentLaneDispatch.sampleIdStrategy === 'explicit' && normalizeText(concurrentLaneDispatch.sampleId)
      ? 'explicit'
      : 'auto';
  return {
    planPath: path.resolve(repoRoot, DEFAULT_CONCURRENT_LANE_PLAN_PATH),
    outputPath: path.resolve(repoRoot, DEFAULT_CONCURRENT_LANE_APPLY_RECEIPT_PATH),
    hostPlaneReportPath: path.resolve(repoRoot, DEFAULT_HOST_PLANE_REPORT_PATH),
    hostRamBudgetPath: path.resolve(repoRoot, DEFAULT_HOST_RAM_BUDGET_PATH),
    dockerRuntimeSnapshotPath: '',
    hostedLinux: 'available',
    hostedWindows: 'available',
    shadowMode: 'auto',
    ref: branchName || null,
    sampleIdStrategy,
    sampleId: sampleIdStrategy === 'explicit' ? normalizeText(concurrentLaneDispatch.sampleId) : null,
    historyScenarioSet: concurrentLaneDispatch.historyScenarioSet,
    allowFork,
    pushMissing: concurrentLaneDispatch.pushMissing === true,
    forcePushOk: concurrentLaneDispatch.forcePushOk === true,
    allowNonCanonicalViHistory: concurrentLaneDispatch.allowNonCanonicalViHistory === true,
    allowNonCanonicalHistoryCore: concurrentLaneDispatch.allowNonCanonicalHistoryCore === true,
    dryRun: false,
    recomputePlan: false,
    help: false
  };
}

function buildConcurrentLaneStatusOptions({ repoRoot, taskPacket, applyReceiptPath }) {
  return {
    applyReceiptPath,
    outputPath: path.resolve(repoRoot, DEFAULT_CONCURRENT_LANE_STATUS_RECEIPT_PATH),
    repo: normalizeText(taskPacket?.repository) || null,
    pr: null,
    ref: normalizeText(taskPacket?.branch?.name) || null,
    help: false
  };
}

function buildConcurrentLaneHelperCommands({ repoRoot, applyOptions, statusOptions }) {
  const applyCommand = ['node', 'tools/priority/concurrent-lane-apply.mjs'];
  applyCommand.push('--plan', toRepoRelativePath(repoRoot, applyOptions.planPath) || DEFAULT_CONCURRENT_LANE_PLAN_PATH);
  applyCommand.push('--output', toRepoRelativePath(repoRoot, applyOptions.outputPath) || DEFAULT_CONCURRENT_LANE_APPLY_RECEIPT_PATH);
  applyCommand.push(
    '--host-plane-report',
    toRepoRelativePath(repoRoot, applyOptions.hostPlaneReportPath) || DEFAULT_HOST_PLANE_REPORT_PATH
  );
  applyCommand.push(
    '--host-ram-budget',
    toRepoRelativePath(repoRoot, applyOptions.hostRamBudgetPath) || DEFAULT_HOST_RAM_BUDGET_PATH
  );
  if (normalizeText(applyOptions.ref)) {
    applyCommand.push('--ref', normalizeText(applyOptions.ref));
  }
  if (normalizeText(applyOptions.sampleId)) {
    applyCommand.push('--sample-id', normalizeText(applyOptions.sampleId));
  }
  applyCommand.push('--history-scenario-set', normalizeText(applyOptions.historyScenarioSet) || 'smoke');
  if (applyOptions.allowFork) applyCommand.push('--allow-fork');
  if (applyOptions.pushMissing) applyCommand.push('--push-missing');
  if (applyOptions.forcePushOk) applyCommand.push('--force-push-ok');
  if (applyOptions.allowNonCanonicalViHistory) applyCommand.push('--allow-noncanonical-vi-history');
  if (applyOptions.allowNonCanonicalHistoryCore) applyCommand.push('--allow-noncanonical-history-core');
  if (applyOptions.dryRun) applyCommand.push('--dry-run');
  if (applyOptions.recomputePlan) applyCommand.push('--recompute-plan');

  const statusCommand = ['node', 'tools/priority/concurrent-lane-status.mjs'];
  statusCommand.push(
    '--apply-receipt',
    toRepoRelativePath(repoRoot, statusOptions.applyReceiptPath) || DEFAULT_CONCURRENT_LANE_APPLY_RECEIPT_PATH
  );
  statusCommand.push(
    '--output',
    toRepoRelativePath(repoRoot, statusOptions.outputPath) || DEFAULT_CONCURRENT_LANE_STATUS_RECEIPT_PATH
  );
  if (normalizeText(statusOptions.repo)) {
    statusCommand.push('--repo', normalizeText(statusOptions.repo));
  }
  if (normalizeText(statusOptions.ref)) {
    statusCommand.push('--ref', normalizeText(statusOptions.ref));
  }
  if (statusOptions.pr != null) {
    statusCommand.push('--pr', String(statusOptions.pr));
  }

  return [applyCommand.join(' '), statusCommand.join(' ')];
}

async function dispatchConcurrentLanes({
  taskPacket,
  repoRoot,
  policy,
  deps = {}
}) {
  const applyConcurrentLanePlanFn = deps.applyConcurrentLanePlanFn ?? applyConcurrentLanePlan;
  const observeConcurrentLaneStatusFn = deps.observeConcurrentLaneStatusFn ?? observeConcurrentLaneStatus;
  const applyOptions = buildConcurrentLaneApplyOptions({ repoRoot, taskPacket, policy });
  const statusOptions = buildConcurrentLaneStatusOptions({
    repoRoot,
    taskPacket,
    applyReceiptPath: applyOptions.outputPath
  });
  const helperCallsExecuted = buildConcurrentLaneHelperCommands({
    repoRoot,
    applyOptions,
    statusOptions
  });

  let applyResult;
  try {
    applyResult = await applyConcurrentLanePlanFn(applyOptions);
  } catch (error) {
    return {
      status: 'blocked',
      outcome: 'concurrent-lane-dispatch-failed',
      reason: normalizeText(error?.message) || 'Concurrent lane apply dispatch failed before a receipt was written.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'dispatch-concurrent-lanes',
        laneLifecycle: 'blocked',
        blockerClass: 'helper',
        retryable: true,
        nextWakeCondition: 'concurrent-lane-apply-repaired',
        helperCallsExecuted,
        filesTouched: []
      }
    };
  }

  const applyReceipt = normalizeOptionalObject(applyResult?.receipt);
  const applyReceiptPath = normalizeText(applyResult?.outputPath) || normalizeText(applyOptions.outputPath);
  statusOptions.applyReceiptPath = applyReceiptPath || statusOptions.applyReceiptPath;

  let statusResult;
  try {
    statusResult = await observeConcurrentLaneStatusFn(statusOptions, {
      getRepoRootFn: () => repoRoot
    });
  } catch (error) {
    return {
      status: 'blocked',
      outcome: 'concurrent-lane-status-failed',
      reason: normalizeText(error?.message) || 'Concurrent lane status observation failed.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'dispatch-concurrent-lanes',
        laneLifecycle: 'blocked',
        blockerClass: 'helper',
        retryable: true,
        nextWakeCondition: 'concurrent-lane-status-repaired',
        helperCallsExecuted,
        filesTouched: [toRepoRelativePath(repoRoot, applyReceiptPath)].filter(Boolean),
        concurrentLaneApply: applyReceipt
          ? {
              receiptPath: toRepoRelativePath(repoRoot, applyReceiptPath),
              status: normalizeText(applyReceipt.status) || null,
              selectedBundleId: normalizeText(applyReceipt.summary?.selectedBundleId) || null,
              validateDispatch: normalizeOptionalObject(applyReceipt.validateDispatch)
            }
          : null
      }
    };
  }

  const statusReceipt = normalizeOptionalObject(statusResult?.receipt);
  const statusReceiptPath = normalizeText(statusResult?.outputPath) || normalizeText(statusOptions.outputPath);
  const projectedStatus = {
    receiptPath: toRepoRelativePath(repoRoot, statusReceiptPath),
    status: normalizeText(statusReceipt?.status) || null,
    selectedBundleId:
      normalizeText(statusReceipt?.summary?.selectedBundleId) ||
      normalizeText(statusReceipt?.applyReceipt?.selectedBundleId) ||
      null,
    hostedRun: normalizeOptionalObject(statusReceipt?.hostedRun),
    pullRequest: normalizeOptionalObject(statusReceipt?.pullRequest),
    summary: normalizeOptionalObject(statusReceipt?.summary)
  };
  const watchPlan = buildConcurrentLaneWatchPlan(projectedStatus);
  const blocked = watchPlan?.laneLifecycle === 'blocked';
  const filesTouched = [applyReceiptPath, statusReceiptPath]
    .map((entry) => toRepoRelativePath(repoRoot, entry))
    .filter(Boolean);

  return {
    status: blocked ? 'blocked' : 'completed',
    outcome: watchPlan?.laneLifecycle || 'complete',
    reason:
      watchPlan?.reason ||
      'Concurrent lane planner/apply/status completed without further remote work to watch.',
    source: 'delivery-agent-broker',
    details: {
      actionType: 'dispatch-concurrent-lanes',
      laneLifecycle: watchPlan?.laneLifecycle || 'complete',
      blockerClass: watchPlan?.blockerClass || 'none',
      retryable: watchPlan?.retryable === true,
      nextWakeCondition: watchPlan?.nextWakeCondition || 'scheduler-rescan',
      helperCallsExecuted,
      filesTouched,
      concurrentLaneApply: {
        receiptPath: toRepoRelativePath(repoRoot, applyReceiptPath),
        status: normalizeText(applyReceipt?.status) || null,
        selectedBundleId: normalizeText(applyReceipt?.summary?.selectedBundleId) || null,
        validateDispatch: normalizeOptionalObject(applyReceipt?.validateDispatch)
      },
      concurrentLaneStatus: projectedStatus
    }
  };
}

function buildRuntimeWorkerProviderSelection({ taskPacket, executionReceipt, policy, preferredSlotId = null }) {
  const selectionSource =
    normalizeOptionalObject(executionReceipt?.details?.workerProviderSelection) ??
    normalizeOptionalObject(taskPacket?.evidence?.delivery?.workerProviderSelection);
  if (selectionSource) {
    return selectWorkerProviderAssignment({
      policy,
      selection: selectionSource,
      preferredSlotId
    });
  }
  return null;
}

function buildRuntimeWorkerProviderDispatch({ taskPacket, executionReceipt, providerSelection }) {
  const detailsDispatch = normalizeOptionalObject(executionReceipt?.details?.providerDispatch);
  if (detailsDispatch) {
    return detailsDispatch;
  }
  return buildWorkerProviderDispatchReceipt(providerSelection, {
    workerSlotId:
      normalizeText(executionReceipt?.details?.workerSlotId) ||
      normalizeText(taskPacket?.evidence?.lane?.workerSlotId) ||
      null
  });
}

function buildRuntimeLiveAgentModelSelection({ taskPacket, executionReceipt, repoRoot }) {
  const detailsSelection = normalizeOptionalObject(executionReceipt?.details?.liveAgentModelSelection);
  if (detailsSelection) {
    return detailsSelection;
  }
  const packetSelection = normalizeOptionalObject(taskPacket?.evidence?.delivery?.liveAgentModelSelection);
  if (packetSelection) {
    return packetSelection;
  }
  const policyLoad = loadLiveAgentModelSelectionPolicy(repoRoot, DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH);
  const reportLoad = loadLiveAgentModelSelectionReport(repoRoot, policyLoad.policy.outputPath);
  return buildLiveAgentModelSelectionProjection({
    policy: {
      ...policyLoad.policy,
      __policyPath: path.relative(repoRoot, policyLoad.path).replace(/\\/g, '/')
    },
    report: reportLoad.report,
    selectedProviderId:
      normalizeText(executionReceipt?.details?.workerProviderSelection?.selectedProviderId) ||
      normalizeText(taskPacket?.evidence?.delivery?.workerProviderSelection?.selectedProviderId) ||
      null
  });
}

function buildLocalReviewLoopRuntimeState({ taskPacket, executionReceipt }) {
  const request = normalizeOptionalObject(taskPacket?.evidence?.delivery?.localReviewLoop);
  const details = normalizeOptionalObject(executionReceipt?.details?.localReviewLoop);
  const receipt = normalizeOptionalObject(details?.receipt);
  const overall = normalizeOptionalObject(receipt?.overall);
  const artifacts = normalizeOptionalObject(receipt?.artifacts);
  const git = normalizeOptionalObject(receipt?.git);
  const niLinuxHistoryReview = normalizeOptionalObject(receipt?.niLinuxHistoryReview);
  const requirementsCoverage = normalizeOptionalObject(receipt?.requirementsCoverage);
  const recommendedReviewOrder = uniqueStrings(Array.isArray(receipt?.recommendedReviewOrder) ? receipt.recommendedReviewOrder : []);
  const singleViHistoryRequest = normalizeOptionalObject(request?.singleViHistory);

  if (!request && !details && !receipt) {
    return null;
  }

  return {
    requested: request?.requested === true,
    status: normalizeText(details?.status) || (request?.requested === true ? 'requested' : null),
    source: normalizeText(details?.source) || normalizeText(request?.source) || null,
    reason: normalizeText(details?.reason) || normalizeText(overall?.message) || null,
    receiptPath: normalizeText(details?.receiptPath) || normalizeText(request?.receiptPath) || null,
    receiptStatus: normalizeText(overall?.status) || null,
    failedCheck: normalizeText(overall?.failedCheck) || null,
    currentHeadSha: normalizeText(details?.currentHeadSha) || null,
    receiptHeadSha: normalizeText(details?.receiptHeadSha) || normalizeText(git?.headSha) || null,
    receiptFreshForHead: typeof details?.receiptFreshForHead === 'boolean' ? details.receiptFreshForHead : null,
    requestedCoverageSatisfied:
      typeof details?.requestedCoverageSatisfied === 'boolean' ? details.requestedCoverageSatisfied : null,
    requestedCoverageReason: normalizeText(details?.requestedCoverageReason) || null,
    requestedCoverageMissingChecks: uniqueStrings(
      Array.isArray(details?.requestedCoverageMissingChecks) ? details.requestedCoverageMissingChecks : []
    ),
    git: git
      ? {
          headSha: normalizeText(git.headSha) || null,
          branch: normalizeText(git.branch) || null,
          upstreamDevelopMergeBase: normalizeText(git.upstreamDevelopMergeBase) || null,
          dirtyTracked: git.dirtyTracked === true
        }
      : null,
    requirementsVerificationRequested: request?.requirementsVerification === true,
    markdownlintRequested: request?.markdownlint === true,
    niLinuxReviewSuiteRequested: request?.niLinuxReviewSuite === true,
    singleViHistory:
      singleViHistoryRequest?.enabled === true
        ? {
            enabled: true,
            targetPath: normalizeText(singleViHistoryRequest.targetPath) || null,
            branchRef: normalizeText(singleViHistoryRequest.branchRef) || null,
            baselineRef: normalizeText(singleViHistoryRequest.baselineRef) || null,
            maxCommitCount: coercePositiveInteger(singleViHistoryRequest.maxCommitCount)
          }
        : null,
    artifacts,
    niLinuxHistoryReview,
    requirementsCoverage,
    recommendedReviewOrder: recommendedReviewOrder.length > 0 ? recommendedReviewOrder : null
  };
}

function buildReadyValidationClearanceRuntimeState({ taskPacket, executionReceipt }) {
  const details = normalizeOptionalObject(executionReceipt?.details?.readyValidationClearance);
  const pullRequest = normalizeOptionalObject(taskPacket?.evidence?.delivery?.pullRequest);
  if (!details && !pullRequest) {
    return null;
  }
  return {
    status: normalizeText(details?.status) || null,
    receiptPath: normalizeText(details?.receiptPath) || null,
    readyHeadSha: normalizeText(details?.readyHeadSha) || null,
    currentHeadSha:
      normalizeText(details?.currentHeadSha) ||
      normalizeText(pullRequest?.headRefOid) ||
      null,
    staleForCurrentHead:
      typeof details?.staleForCurrentHead === 'boolean' ? details.staleForCurrentHead : null,
    reason: normalizeText(details?.reason) || null
  };
}

function normalizePlaneTransitionRecord(value) {
  const record = normalizeOptionalObject(value);
  if (!record) {
    return null;
  }
  return {
    from: normalizeText(record.from) || null,
    to: normalizeText(record.to) || null,
    action: normalizeText(record.action) || null,
    via: normalizeText(record.via) || null,
    branchClass: normalizeText(record.branchClass) || null,
    sourceRepository: normalizeText(record.sourceRepository) || null,
    targetRepository: normalizeText(record.targetRepository) || null
  };
}

function planeTransitionRecordsMatch(expected, actual) {
  if (!expected && !actual) {
    return true;
  }
  if (!expected || !actual) {
    return false;
  }
  return (
    expected.from === actual.from &&
    expected.to === actual.to &&
    expected.action === actual.action &&
    expected.via === actual.via &&
    expected.branchClass === actual.branchClass &&
    expected.sourceRepository === actual.sourceRepository &&
    expected.targetRepository === actual.targetRepository
  );
}

function resolveDeliveryPlaneTransition({
  repoRoot = null,
  repository,
  policy,
  schedulerDecision,
  taskPacket
}) {
  const explicit = normalizePlaneTransitionRecord(
    taskPacket?.evidence?.delivery?.planeTransition ??
    schedulerDecision?.artifacts?.planeTransition
  );
  const branch =
    normalizeText(taskPacket?.branch?.name) ||
    normalizeText(schedulerDecision?.activeLane?.branch) ||
    null;
  const sourcePlane =
    normalizeText(taskPacket?.branch?.forkRemote) ||
    normalizeText(schedulerDecision?.activeLane?.forkRemote) ||
    normalizeText(policy?.implementationRemote) ||
    null;
  const targetRepository =
    normalizeText(taskPacket?.repository) ||
    normalizeText(schedulerDecision?.artifacts?.canonicalRepository) ||
    normalizeText(repository) ||
    null;

  if (!branch || !sourcePlane || !targetRepository || !repoRoot) {
    return explicit;
  }

  let contract;
  try {
    contract = loadBranchClassContract(repoRoot);
  } catch (error) {
    if (explicit) {
      return explicit;
    }
    throw error;
  }
  const expected = resolveBranchPlaneTransition({
    branch,
    sourcePlane,
    targetRepository,
    contract
  });
  if (!expected) {
    if (explicit) {
      throw new Error(`Unexpected planeTransition evidence for ${sourcePlane} lane '${branch}'.`);
    }
    return null;
  }
  if (!explicit) {
    throw new Error(
      `Missing planeTransition evidence for ${sourcePlane} lane '${branch}' targeting '${targetRepository}'.`
    );
  }
  if (!planeTransitionRecordsMatch(expected, explicit)) {
    throw new Error(
      `planeTransition evidence for ${sourcePlane} lane '${branch}' does not match the branch class contract.`
    );
  }
  return explicit;
}

export function buildDeliveryAgentRuntimeRecord({
  now = new Date(),
  repoRoot = null,
  repository,
  runtimeDir,
  policy,
  schedulerDecision,
  taskPacket,
  executionReceipt,
  statePath,
  lanePath,
  marketplace = null
}) {
  const laneId =
    normalizeText(executionReceipt?.laneId) ||
    normalizeText(taskPacket?.laneId) ||
    normalizeText(schedulerDecision?.activeLane?.laneId) ||
    'idle';
  const issue =
    coercePositiveInteger(executionReceipt?.issue) ??
    coercePositiveInteger(schedulerDecision?.activeLane?.issue) ??
    null;
  const epic = coercePositiveInteger(schedulerDecision?.activeLane?.epic) ?? null;
  const prUrl =
    normalizeText(taskPacket?.pullRequest?.url) ||
    normalizeText(schedulerDecision?.activeLane?.prUrl) ||
    null;
  const blockerClass =
    normalizeText(executionReceipt?.details?.blockerClass) ||
    normalizeText(taskPacket?.checks?.blockerClass) ||
    normalizeText(schedulerDecision?.activeLane?.blockerClass) ||
    'none';
  const laneLifecycle = normalizeLifecycle(
    executionReceipt?.details?.laneLifecycle ||
      taskPacket?.evidence?.delivery?.laneLifecycle ||
      schedulerDecision?.artifacts?.laneLifecycle,
    schedulerDecision?.outcome === 'idle' ? 'idle' : blockerClass !== 'none' ? 'blocked' : 'planning'
  );
  const activeCodingLanes = laneLifecycle === 'coding' ? 1 : 0;
  const workerPoolPolicy = buildWorkerPoolPolicySnapshot(policy);
  const normalizedMaxActiveCodingLanes = Math.max(
    coercePositiveInteger(policy?.maxActiveCodingLanes) ?? workerPoolPolicy.targetSlotCount,
    workerPoolPolicy.targetSlotCount
  );
  const workerPool = buildWorkerPoolRuntimeState({
    policy: {
      ...policy,
      maxActiveCodingLanes: normalizedMaxActiveCodingLanes,
      workerPool: workerPoolPolicy
    },
    laneId,
    issue,
    laneLifecycle,
    preferredSlotId:
      normalizeText(taskPacket?.evidence?.lane?.workerSlotId) ||
      normalizeText(executionReceipt?.details?.workerSlotId) ||
      null
  });
  const workerProviderSelection = buildRuntimeWorkerProviderSelection({
    taskPacket,
    executionReceipt,
    policy: {
      ...policy,
      workerPool: workerPoolPolicy
    },
    preferredSlotId:
      normalizeText(taskPacket?.evidence?.lane?.workerSlotId) ||
      normalizeText(executionReceipt?.details?.workerSlotId) ||
      null
  });
  const providerDispatch = buildRuntimeWorkerProviderDispatch({
    taskPacket,
    executionReceipt,
    providerSelection: workerProviderSelection
  });
  const reviewMonitor =
    executionReceipt?.details?.reviewMonitor ??
    taskPacket?.evidence?.delivery?.pullRequest?.copilotReviewWorkflow ??
    schedulerDecision?.artifacts?.pullRequest?.copilotReviewWorkflow ??
    null;
  const pollIntervalSecondsHint =
    coercePositiveInteger(executionReceipt?.details?.pollIntervalSecondsHint) ??
    coercePositiveInteger(taskPacket?.evidence?.delivery?.pullRequest?.pollIntervalSecondsHint) ??
    coercePositiveInteger(schedulerDecision?.artifacts?.pullRequest?.pollIntervalSecondsHint) ??
    null;
  const localReviewLoop = buildLocalReviewLoopRuntimeState({ taskPacket, executionReceipt });
  const readyValidationClearance = buildReadyValidationClearanceRuntimeState({ taskPacket, executionReceipt });
  const concurrentLaneApply = buildConcurrentLaneApplyRuntimeState({ taskPacket, executionReceipt });
  const concurrentLaneStatus = buildConcurrentLaneStatusRuntimeState({ taskPacket, executionReceipt });
  const liveAgentModelSelection = buildRuntimeLiveAgentModelSelection({ taskPacket, executionReceipt, repoRoot });
  const planeTransition = resolveDeliveryPlaneTransition({
    repoRoot,
    repository,
    policy,
    schedulerDecision,
    taskPacket
  });
  const activeLane = {
    schema: DELIVERY_AGENT_LANE_STATE_SCHEMA,
    generatedAt: toIso(now),
    laneId,
    issue,
    epic,
    branch:
      normalizeText(taskPacket?.branch?.name) ||
      normalizeText(schedulerDecision?.activeLane?.branch) ||
      null,
    forkRemote:
      normalizeText(taskPacket?.branch?.forkRemote) ||
      normalizeText(schedulerDecision?.activeLane?.forkRemote) ||
      null,
    prUrl,
    blockerClass,
    laneLifecycle,
    actionType: normalizeText(executionReceipt?.details?.actionType) || normalizeText(schedulerDecision?.artifacts?.selectedActionType) || null,
    outcome: normalizeText(executionReceipt?.outcome) || null,
    reason: normalizeText(executionReceipt?.reason) || null,
    retryable: executionReceipt?.details?.retryable === true,
    nextWakeCondition: normalizeText(executionReceipt?.details?.nextWakeCondition) || null,
    reviewPhase: normalizeText(executionReceipt?.details?.reviewPhase) || null,
    pollIntervalSecondsHint,
    reviewMonitor,
    planeTransition,
    localReviewLoop,
    readyValidationClearance,
    concurrentLaneApply,
    concurrentLaneStatus,
    liveAgentModelSelection,
    workerProviderSelection,
    providerDispatch
  };
  if (workerPoolPolicy.releaseWaitingStates.includes(laneLifecycle) && workerPool.releasedLanes.length > 0) {
    workerPool.releasedLanes = workerPool.releasedLanes.map((releasedLane, index) =>
      index === 0
        ? {
            ...releasedLane,
            branch: activeLane.branch,
            forkRemote: activeLane.forkRemote,
            prUrl: activeLane.prUrl,
            blockerClass: activeLane.blockerClass,
            nextWakeCondition: activeLane.nextWakeCondition,
            pollIntervalSecondsHint: activeLane.pollIntervalSecondsHint,
            releasedAt: toIso(now)
          }
        : releasedLane
    );
  }
  return {
    schema: DELIVERY_AGENT_RUNTIME_STATE_SCHEMA,
    generatedAt: toIso(now),
    repository,
    runtimeDir,
    policy: {
      schema: DELIVERY_AGENT_POLICY_SCHEMA,
      backlogAuthority: policy.backlogAuthority,
      implementationRemote: policy.implementationRemote,
      copilotReviewStrategy: normalizeCopilotReviewStrategy(policy.copilotReviewStrategy),
      autoSlice: policy.autoSlice === true,
      autoMerge: policy.autoMerge === true,
      maxActiveCodingLanes: normalizedMaxActiveCodingLanes,
      allowPolicyMutations: policy.allowPolicyMutations === true,
      allowReleaseAdmin: policy.allowReleaseAdmin === true,
      stopWhenNoOpenEpics: policy.stopWhenNoOpenEpics === true,
      workerPool: workerPoolPolicy
    },
    status: laneLifecycle === 'blocked' ? 'blocked' : laneLifecycle === 'idle' ? 'idle' : 'running',
    laneLifecycle,
    activeCodingLanes,
    workerPool,
    localReviewLoop,
    concurrentLaneApply,
    concurrentLaneStatus,
    liveAgentModelSelection,
    marketplace,
    activeLane,
    artifacts: {
      statePath,
      lanePath,
      localReviewLoopReceiptPath: normalizeText(localReviewLoop?.receiptPath) || null,
      concurrentLaneApplyReceiptPath: normalizeText(concurrentLaneApply?.receiptPath) || null,
      concurrentLaneStatusReceiptPath: normalizeText(concurrentLaneStatus?.receiptPath) || null,
      marketplaceSnapshotPath: normalizeText(marketplace?.snapshotPath) || null,
      planeTransition,
      providerDispatch
    }
  };
}

export async function persistDeliveryAgentRuntimeState({
  repoRoot = null,
  runtimeDir,
  repository,
  policy,
  schedulerDecision,
  taskPacket,
  executionReceipt,
  now = new Date(),
  collectMarketplaceSnapshotFn = collectMarketplaceSnapshot,
  writeMarketplaceSnapshotFn = writeMarketplaceSnapshot,
  selectMarketplaceRecommendationFn = selectMarketplaceRecommendation
}) {
  await mkdir(runtimeDir, { recursive: true });
  const statePath = path.join(runtimeDir, DELIVERY_AGENT_STATE_FILENAME);
  const laneId =
    normalizeText(executionReceipt?.laneId) ||
    normalizeText(taskPacket?.laneId) ||
    normalizeText(schedulerDecision?.activeLane?.laneId) ||
    'idle';
  const lanesDir = path.join(runtimeDir, DELIVERY_AGENT_LANES_DIRNAME);
  await mkdir(lanesDir, { recursive: true });
  const lanePath = path.join(lanesDir, `${sanitizeSegment(laneId)}.json`);
  let payload = buildDeliveryAgentRuntimeRecord({
    now,
    repoRoot,
    repository,
    runtimeDir,
    policy,
    schedulerDecision,
    taskPacket,
    executionReceipt,
    statePath,
    lanePath
  });
  if (['idle', 'waiting-ci', 'waiting-review', 'ready-merge'].includes(payload.laneLifecycle)) {
    try {
      const snapshot = await collectMarketplaceSnapshotFn({
        repoRoot
      });
      const snapshotPath = await writeMarketplaceSnapshotFn(
        DEFAULT_MARKETPLACE_SNAPSHOT_PATH,
        snapshot,
        repoRoot
      );
      payload = buildDeliveryAgentRuntimeRecord({
        now,
        repoRoot,
        repository,
        runtimeDir,
        policy,
        schedulerDecision,
        taskPacket,
        executionReceipt,
        statePath,
        lanePath,
        marketplace: {
          status: 'ready',
          snapshotPath,
          summary: snapshot.summary ?? null,
          recommendedLane: selectMarketplaceRecommendationFn(snapshot, {
            currentRepository: repository,
            requireDifferentRepository: true
          })
        }
      });
    } catch (error) {
      payload = buildDeliveryAgentRuntimeRecord({
        now,
        repoRoot,
        repository,
        runtimeDir,
        policy,
        schedulerDecision,
        taskPacket,
        executionReceipt,
        statePath,
        lanePath,
        marketplace: {
          status: 'error',
          snapshotPath: null,
          summary: null,
          recommendedLane: null,
          error: normalizeText(error?.message) || String(error)
        }
      });
    }
  }
  await writeFile(statePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  await writeFile(lanePath, `${JSON.stringify(payload.activeLane, null, 2)}\n`, 'utf8');
  return {
    statePath,
    lanePath,
    payload
  };
}

function buildAutoSliceTitle(parentIssue) {
  return `Slice: ${normalizeText(parentIssue?.title) || `Issue #${parentIssue?.number}`}`;
}

function buildAutoSliceBody(parentIssue, taskPacket) {
  return [
    `Auto-created child slice for parent issue #${parentIssue.number}.`,
    '',
    '## Context',
    `- Parent issue: ${parentIssue.url || `#${parentIssue.number}`}`,
    `- Objective: ${normalizeText(taskPacket?.objective?.summary) || 'Unattended delivery backlog repair'}`,
    '',
    '## Initial acceptance',
    '- Produce one executable, bounded implementation slice.',
    '- Preserve upstream issue/PR policy contracts.',
    '- Keep the delivery lane suitable for unattended execution.'
  ].join('\n');
}

async function runCommand(command, args, { cwd, env }, deps = {}) {
  if (typeof deps.runCommandFn === 'function') {
    return deps.runCommandFn(command, args, { cwd, env });
  }
  const result = spawnSync(command, args, {
    cwd,
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return {
    status: Number.isInteger(result.status) ? result.status : 1,
    stdout: result.stdout ?? '',
    stderr: [
      normalizeText(result.stderr),
      normalizeText(result.error?.message),
      normalizeText(result.signal ? `Process terminated by signal ${result.signal}.` : '')
    ]
      .filter(Boolean)
      .join('\n')
  };
}

function buildPrReadyArgs({ repository, pullRequestNumber, ready }) {
  const args = ['pr', 'ready', String(pullRequestNumber), '--repo', repository];
  if (!ready) {
    args.push('--undo');
  }
  return args;
}

async function setPullRequestReadyState({
  repository,
  pullRequest,
  ready,
  repoRoot,
  deps = {}
}) {
  const pullRequestNumber = coercePositiveInteger(pullRequest?.number);
  if (!normalizeText(repository) || !pullRequestNumber) {
    return {
      ok: false,
      helperCall: null,
      result: {
        status: 1,
        stdout: '',
        stderr: 'Pull request number or repository is missing.'
      }
    };
  }
  const args = buildPrReadyArgs({
    repository,
    pullRequestNumber,
    ready
  });
  const result = await runCommand('gh', args, { cwd: repoRoot, env: process.env }, deps);
  return {
    ok: result.status === 0,
    helperCall: `gh ${args.join(' ')}`,
    result
  };
}

function uniqueStrings(values = []) {
  return [...new Set(values.map((entry) => normalizeText(entry)).filter(Boolean))];
}

function evaluateDraftPhaseCopilotClearance(pullRequest = {}) {
  const copilotReviewSignal = normalizeOptionalObject(pullRequest?.copilotReviewSignal);
  const copilotReviewWorkflow = normalizeOptionalObject(pullRequest?.copilotReviewWorkflow);
  const actionableCommentCount = Number(copilotReviewSignal?.actionableCommentCount ?? 0) || 0;
  const actionableThreadCount = Number(copilotReviewSignal?.actionableThreadCount ?? 0) || 0;
  const hasActionableItems = actionableCommentCount > 0 || actionableThreadCount > 0;
  const hasCurrentHeadReview = copilotReviewSignal?.hasCurrentHeadReview === true;
  const workflowStatus = normalizeText(copilotReviewWorkflow?.status).toUpperCase();
  const workflowConclusion = normalizeText(copilotReviewWorkflow?.conclusion).toUpperCase();
  const reviewRunCompletedClean =
    workflowStatus === 'COMPLETED' &&
    workflowConclusion === 'SUCCESS' &&
    actionableCommentCount === 0 &&
    actionableThreadCount === 0;
  const ok =
    actionableCommentCount === 0 &&
    actionableThreadCount === 0 &&
    hasCurrentHeadReview;
  const reasons = [];
  if (hasActionableItems) {
    reasons.push('actionable-current-head-items');
  }
  if (!hasCurrentHeadReview) {
    if (PENDING_WORKFLOW_RUN_STATUSES.has(workflowStatus)) {
      reasons.push('draft-review-workflow-pending');
    } else if (workflowStatus === 'COMPLETED' && workflowConclusion && workflowConclusion !== 'SUCCESS') {
      reasons.push('draft-review-workflow-failed');
    } else {
      reasons.push('draft-review-clearance-missing');
    }
  }
  const nextWakeCondition =
    hasActionableItems
      ? 'review-comments-addressed'
      : PENDING_WORKFLOW_RUN_STATUSES.has(workflowStatus)
        ? 'copilot-review-workflow-completed'
        : workflowStatus === 'COMPLETED' && workflowConclusion === 'SUCCESS'
          ? 'copilot-review-post-expected'
          : 'review-disposition-updated';
  const pollIntervalSecondsHint = PENDING_WORKFLOW_RUN_STATUSES.has(workflowStatus)
    ? COPILOT_REVIEW_ACTIVE_POLL_HINT_SECONDS
    : workflowStatus === 'COMPLETED' && workflowConclusion === 'SUCCESS'
      ? COPILOT_REVIEW_POST_POLL_HINT_SECONDS
      : null;
  return {
    ok,
    reasons,
    nextWakeCondition,
    pollIntervalSecondsHint,
    signal: copilotReviewSignal,
    workflow: copilotReviewWorkflow,
    hasCurrentHeadReview,
    reviewRunCompletedClean,
    actionableCommentCount,
    actionableThreadCount
  };
}

function localReviewLoopSatisfied(localReviewLoop) {
  if (!localReviewLoop || typeof localReviewLoop !== 'object') {
    return true;
  }
  const receipt = normalizeOptionalObject(localReviewLoop.receipt);
  const git = normalizeOptionalObject(receipt?.git);
  const overall = normalizeOptionalObject(receipt?.overall);
  return (
    normalizeText(localReviewLoop.status).toLowerCase() === 'passed' &&
    localReviewLoop.receiptFreshForHead === true &&
    localReviewLoop.requestedCoverageSatisfied === true &&
    normalizeText(overall?.status).toLowerCase() === 'passed' &&
    git?.dirtyTracked !== true
  );
}

async function enforceDraftOnlyReviewContract({
  planned,
  taskPacket,
  policy,
  repoRoot,
  deps = {}
}) {
  const pullRequest = normalizeOptionalObject(planned?.pullRequest);
  if (!pullRequest?.url || !coercePositiveInteger(pullRequest.number)) {
    return null;
  }
  const reviewStrategy = normalizeCopilotReviewStrategy(
    taskPacket?.evidence?.delivery?.mutationEnvelope?.copilotReviewStrategy || policy?.copilotReviewStrategy
  );
  if (reviewStrategy !== 'draft-only-explicit') {
    return null;
  }

  const localReviewRequested = taskPacket?.evidence?.delivery?.localReviewLoop?.requested === true;
  const repository = normalizeText(taskPacket?.repository);
  const currentHeadSha = normalizeText(pullRequest?.headRefOid) || null;
  const readyValidationClearance = await loadReadyValidationClearance({
    repoRoot,
    repository,
    pullRequestNumber: pullRequest.number
  });
  let localReviewLoopReceipt = null;
  let localReviewLoopHelperCalls = [];
  let localReviewLoopFilesTouched = [];
  if (localReviewRequested) {
    const localReviewResult = await maybeRunLocalReviewLoop({
      baseReceipt: {
        status: 'completed',
        outcome: 'draft-review-assessment',
        reason: 'Assessing local Docker/Desktop review receipt before final ready validation.',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'local-review-loop',
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'local-review-loop-green',
          helperCallsExecuted: [],
          filesTouched: [],
          reviewPhase: 'draft-review'
        }
      },
      taskPacket,
      policy,
      repoRoot,
      deps
    });
    if (localReviewResult.status !== 'completed') {
      if (pullRequest.isDraft !== true) {
        const toDraft = await setPullRequestReadyState({
          repository: normalizeText(taskPacket?.repository),
          pullRequest,
          ready: false,
          repoRoot,
          deps
        });
        if (!toDraft.ok) {
          return {
            status: 'blocked',
            outcome: 'draft-transition-failed',
            reason:
              normalizeText(toDraft.result?.stderr) ||
              normalizeText(toDraft.result?.stdout) ||
              `Failed to mark PR #${pullRequest.number} as draft after local review clearance failed.`,
            source: 'delivery-agent-broker',
            details: {
              actionType: 'watch-pr',
              laneLifecycle: 'blocked',
              blockerClass: 'helperbug',
              retryable: false,
              nextWakeCondition: 'draft-transition-fixed',
              reviewPhase: 'draft-review',
              helperCallsExecuted: uniqueStrings([
                ...(Array.isArray(localReviewResult.details?.helperCallsExecuted)
                  ? localReviewResult.details.helperCallsExecuted
                  : []),
                toDraft.helperCall
              ]),
              filesTouched: Array.isArray(localReviewResult.details?.filesTouched)
                ? localReviewResult.details.filesTouched
                : [],
              localReviewLoop: normalizeOptionalObject(localReviewResult.details?.localReviewLoop)
            }
          };
        }
        if (toDraft.helperCall) {
          localReviewResult.details.helperCallsExecuted = uniqueStrings([
            ...(Array.isArray(localReviewResult.details?.helperCallsExecuted)
              ? localReviewResult.details.helperCallsExecuted
              : []),
            toDraft.helperCall
          ]);
        }
      }
      localReviewResult.details = {
        ...(localReviewResult.details && typeof localReviewResult.details === 'object' ? localReviewResult.details : {}),
        reviewPhase: 'draft-review'
      };
      return localReviewResult;
    }
    localReviewLoopReceipt = normalizeOptionalObject(localReviewResult?.details?.localReviewLoop);
    localReviewLoopHelperCalls = uniqueStrings(
      Array.isArray(localReviewResult.details?.helperCallsExecuted) ? localReviewResult.details.helperCallsExecuted : []
    );
    localReviewLoopFilesTouched = uniqueStrings(
      Array.isArray(localReviewResult.details?.filesTouched) ? localReviewResult.details.filesTouched : []
    );
  }

  const reviewClearance = evaluateDraftPhaseCopilotClearance(pullRequest);
  const localReviewSatisfiedFlag = !localReviewRequested || localReviewLoopSatisfied(localReviewLoopReceipt);
  const storedReadyHeadSha = normalizeText(readyValidationClearance.receipt?.readyHeadSha) || null;
  const readyHeadMismatch = Boolean(
    pullRequest.isDraft !== true &&
      currentHeadSha &&
      storedReadyHeadSha &&
      currentHeadSha !== storedReadyHeadSha
  );

  if (pullRequest.isDraft === true) {
    if (reviewClearance.ok && localReviewSatisfiedFlag) {
      const toReady = await setPullRequestReadyState({
        repository: normalizeText(taskPacket?.repository),
        pullRequest,
        ready: true,
        repoRoot,
        deps
      });
      if (!toReady.ok) {
        return {
          status: 'blocked',
          outcome: 'ready-transition-failed',
          reason:
            normalizeText(toReady.result?.stderr) ||
            normalizeText(toReady.result?.stdout) ||
            `Failed to mark PR #${pullRequest.number} ready for review.`,
          source: 'delivery-agent-broker',
          details: {
            actionType: 'watch-pr',
            laneLifecycle: 'blocked',
            blockerClass: 'helperbug',
            retryable: false,
            nextWakeCondition: 'ready-transition-fixed',
            reviewPhase: 'ready-validation',
            helperCallsExecuted: uniqueStrings([...localReviewLoopHelperCalls, toReady.helperCall]),
            filesTouched: localReviewLoopFilesTouched,
            localReviewLoop: localReviewLoopReceipt
          }
        };
      }
      const persistedClearance = await persistReadyValidationClearance({
        repoRoot,
        repository,
        pullRequest,
        localReviewLoop: localReviewLoopReceipt,
        status: 'current',
        reason: 'PR entered ready-validation on the current head after clean draft-phase review clearance.'
      });
      return {
        status: 'completed',
        outcome: 'waiting-ci',
        reason: 'Marked the PR ready for review after clean draft-phase Copilot review and local validation.',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'watch-pr',
          laneLifecycle: 'waiting-ci',
          blockerClass: 'ci',
          retryable: true,
          nextWakeCondition: 'checks-green',
          reviewPhase: 'ready-validation',
          helperCallsExecuted: uniqueStrings([...localReviewLoopHelperCalls, toReady.helperCall]),
          filesTouched: localReviewLoopFilesTouched,
          localReviewLoop: localReviewLoopReceipt,
          readyValidationClearance: {
            status: 'current',
            receiptPath: persistedClearance.receiptPath,
            readyHeadSha: normalizeText(persistedClearance.receipt?.readyHeadSha) || currentHeadSha,
            currentHeadSha,
            staleForCurrentHead: false,
            reason: normalizeText(persistedClearance.receipt?.reason) || null
          }
        }
      };
    }

    return {
      status: 'completed',
      outcome: 'waiting-review',
      reason:
        localReviewRequested && !localReviewSatisfiedFlag
          ? 'Pull request remains draft until the local Docker/Desktop review receipt is current-head, clean, and request-complete.'
          : 'Pull request remains draft until draft-phase Copilot review clearance exists on the current head.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'watch-pr',
        laneLifecycle: 'waiting-review',
        blockerClass: 'review',
        retryable: true,
        nextWakeCondition: localReviewRequested && !localReviewSatisfiedFlag
          ? 'local-review-loop-green'
          : reviewClearance.nextWakeCondition,
        pollIntervalSecondsHint: localReviewRequested && !localReviewSatisfiedFlag ? null : reviewClearance.pollIntervalSecondsHint,
        reviewMonitor: reviewClearance.workflow,
        reviewPhase: 'draft-review',
        helperCallsExecuted: localReviewLoopHelperCalls,
        filesTouched: localReviewLoopFilesTouched,
        localReviewLoop: localReviewLoopReceipt,
        readyValidationClearance:
          readyValidationClearance.receipt && storedReadyHeadSha
            ? {
                status: normalizeText(readyValidationClearance.receipt.status) || null,
                receiptPath: readyValidationClearance.path,
                readyHeadSha: storedReadyHeadSha,
                currentHeadSha,
                staleForCurrentHead: currentHeadSha ? currentHeadSha !== storedReadyHeadSha : null,
                reason: normalizeText(readyValidationClearance.receipt.reason) || null
              }
            : null
      }
    };
  }

  if (readyHeadMismatch || !reviewClearance.ok || !localReviewSatisfiedFlag) {
    const toDraft = await setPullRequestReadyState({
      repository,
      pullRequest,
      ready: false,
      repoRoot,
      deps
    });
    if (!toDraft.ok) {
      return {
        status: 'blocked',
        outcome: 'draft-transition-failed',
        reason:
          normalizeText(toDraft.result?.stderr) ||
          normalizeText(toDraft.result?.stdout) ||
          `Failed to mark PR #${pullRequest.number} as draft.`,
        source: 'delivery-agent-broker',
        details: {
          actionType: 'watch-pr',
          laneLifecycle: 'blocked',
          blockerClass: 'helperbug',
          retryable: false,
          nextWakeCondition: 'draft-transition-fixed',
          reviewPhase: 'draft-review',
          helperCallsExecuted: uniqueStrings([...localReviewLoopHelperCalls, toDraft.helperCall]),
          filesTouched: localReviewLoopFilesTouched,
          localReviewLoop: localReviewLoopReceipt,
          readyValidationClearance: {
            status: normalizeText(readyValidationClearance.receipt?.status) || null,
            receiptPath: readyValidationClearance.path,
            readyHeadSha: storedReadyHeadSha,
            currentHeadSha,
            staleForCurrentHead: readyHeadMismatch,
            reason:
              readyHeadMismatch
                ? `Ready-validation clearance head ${storedReadyHeadSha} does not match current head ${currentHeadSha}.`
                : normalizeText(readyValidationClearance.receipt?.reason) || null
          }
        }
      };
    }
    const invalidatedClearance = await invalidateReadyValidationClearance({
      repoRoot,
      repository,
      pullRequest,
      localReviewLoop: localReviewLoopReceipt,
      readyHeadShaOverride: storedReadyHeadSha,
      currentHeadShaOverride: currentHeadSha,
      status: readyHeadMismatch ? 'invalidated-head-mismatch' : 'invalidated',
      reason: readyHeadMismatch
        ? `Ready-validation clearance head ${storedReadyHeadSha} no longer matches current head ${currentHeadSha}.`
        : localReviewRequested && !localReviewSatisfiedFlag
          ? 'Ready-validation clearance invalidated because local Docker/Desktop review clearance no longer matches the current head.'
          : 'Ready-validation clearance invalidated because current-head draft-phase Copilot review clearance is missing or unresolved.'
    });
    return {
      status: 'completed',
      outcome: 'waiting-review',
      reason:
        readyHeadMismatch
          ? 'PR was returned to draft because the current head changed after ready-validation clearance was recorded.'
          : localReviewRequested && !localReviewSatisfiedFlag
          ? 'PR was returned to draft because local Docker/Desktop review clearance no longer matches the current head.'
          : 'PR was returned to draft because current-head draft-phase Copilot review clearance is missing or unresolved.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'watch-pr',
        laneLifecycle: 'waiting-review',
        blockerClass: 'review',
        retryable: true,
        nextWakeCondition: localReviewRequested && !localReviewSatisfiedFlag
          ? 'local-review-loop-green'
          : reviewClearance.nextWakeCondition,
        pollIntervalSecondsHint: localReviewRequested && !localReviewSatisfiedFlag ? null : reviewClearance.pollIntervalSecondsHint,
        reviewMonitor: reviewClearance.workflow,
        reviewPhase: 'draft-review',
        helperCallsExecuted: uniqueStrings([...localReviewLoopHelperCalls, toDraft.helperCall]),
        filesTouched: localReviewLoopFilesTouched,
        localReviewLoop: localReviewLoopReceipt,
        readyValidationClearance: {
          status: normalizeText(invalidatedClearance.receipt?.status) || null,
          receiptPath: invalidatedClearance.receiptPath,
          readyHeadSha: normalizeText(invalidatedClearance.receipt?.readyHeadSha) || storedReadyHeadSha,
          currentHeadSha,
          staleForCurrentHead: readyHeadMismatch,
          reason: normalizeText(invalidatedClearance.receipt?.reason) || null
        }
      }
    };
  }

  const persistedReadyClearance = await persistReadyValidationClearance({
    repoRoot,
    repository,
    pullRequest,
    localReviewLoop: localReviewLoopReceipt,
    status: 'current',
    reason: 'PR remains in ready-validation on the same cleared head.'
  });
  void persistedReadyClearance;

  return null;
}

function resolveRepoContainedPath(repoRoot, candidatePath, { label = 'path', requiredRoot = '' } = {}) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    throw new Error(`${label} must be a non-empty repo-relative path.`);
  }
  if (path.isAbsolute(normalized)) {
    throw new Error(`${label} must stay under the repository root: ${normalized}`);
  }
  const resolved = path.resolve(repoRoot, normalized);
  const relativeToRepo = path.relative(repoRoot, resolved);
  if (!relativeToRepo || relativeToRepo.startsWith('..') || path.isAbsolute(relativeToRepo)) {
    throw new Error(`${label} escapes the repository root: ${normalized}`);
  }
  if (requiredRoot) {
    const requiredRootPath = path.resolve(repoRoot, requiredRoot);
    const relativeToRequiredRoot = path.relative(requiredRootPath, resolved);
    if (!relativeToRequiredRoot || relativeToRequiredRoot.startsWith('..') || path.isAbsolute(relativeToRequiredRoot)) {
      throw new Error(`${label} must stay under ${requiredRoot}: ${normalized}`);
    }
  }
  return {
    normalized,
    resolved
  };
}

async function maybeRunLocalReviewLoop({
  baseReceipt,
  taskPacket,
  policy,
  repoRoot,
  deps = {}
}) {
  const request = taskPacket?.evidence?.delivery?.localReviewLoop;
  if (!request || request.requested !== true) {
    return baseReceipt;
  }
  if (baseReceipt?.status !== 'completed') {
    return baseReceipt;
  }

  const localReviewLoopPolicy = normalizeLocalReviewLoopPolicy(policy?.localReviewLoop);
  const wrapperCommand =
    normalizeCommandList(localReviewLoopPolicy.command).length > 0
      ? normalizeCommandList(localReviewLoopPolicy.command)
      : [...DEFAULT_LOCAL_REVIEW_LOOP_COMMAND];
  const wrapperArgs = buildLocalReviewLoopCliArgs({ repoRoot, request });
  const daemonReviewProviders = normalizeStringList(localReviewLoopPolicy.reviewProviders);
  const command = wrapperCommand[0];
  const args = [...wrapperCommand.slice(1)];
  if (commandUsesLocalCollabOrchestrator(wrapperCommand) && daemonReviewProviders.length > 0) {
    args.push('--providers', daemonReviewProviders.join(','));
  }
  args.push(...wrapperArgs);
  const commandText = [command, ...args].join(' ');
  let resolvedReceiptPathInfo;
  try {
    resolvedReceiptPathInfo = resolveRepoContainedPath(
      repoRoot,
      normalizeText(request.receiptPath) || localReviewLoopPolicy.receiptPath,
      {
        label: 'Local review loop receipt path',
        requiredRoot: DOCKER_PARITY_RESULTS_ROOT
      }
    );
  } catch (error) {
    return {
      status: 'blocked',
      outcome: 'local-review-loop-failed',
      reason: normalizeText(error?.message) || 'Invalid local review loop receipt path.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'local-review-loop',
        laneLifecycle: 'blocked',
        blockerClass: 'policy',
        retryable: false,
        nextWakeCondition: 'local-review-loop-policy-fixed',
        helperCallsExecuted: uniqueStrings([
          ...(Array.isArray(baseReceipt?.details?.helperCallsExecuted) ? baseReceipt.details.helperCallsExecuted : []),
          commandText
        ]),
        filesTouched: uniqueStrings(Array.isArray(baseReceipt?.details?.filesTouched) ? baseReceipt.details.filesTouched : []),
        localReviewLoop: {
          status: 'failed',
          source: 'docker-desktop-review-loop',
          reason: normalizeText(error?.message) || 'Invalid local review loop receipt path.',
          receiptPath: normalizeText(request.receiptPath) || localReviewLoopPolicy.receiptPath,
          receipt: null
        }
      }
    };
  }
  const receiptPath = resolvedReceiptPathInfo.normalized;
  const resolvedReceiptPath = resolvedReceiptPathInfo.resolved;
  const existingReceiptAssessment = await assessDockerDesktopReviewLoopReceipt({
    repoRoot,
    receiptPath,
    request
  });
  if (existingReceiptAssessment.status === 'passed' && existingReceiptAssessment.reusable === true) {
    return {
      ...baseReceipt,
      reason: `${normalizeText(baseReceipt.reason) || 'Coding turn completed.'} Reused current Docker/Desktop review loop receipt.`,
      details: {
        ...(baseReceipt.details && typeof baseReceipt.details === 'object' ? baseReceipt.details : {}),
        helperCallsExecuted: uniqueStrings(Array.isArray(baseReceipt?.details?.helperCallsExecuted) ? baseReceipt.details.helperCallsExecuted : []),
        filesTouched: uniqueStrings([
          ...(Array.isArray(baseReceipt?.details?.filesTouched) ? baseReceipt.details.filesTouched : []),
          receiptPath
        ]),
        localReviewLoop: {
          status: 'passed',
          source: 'docker-desktop-review-loop-cache',
          reason: existingReceiptAssessment.reason,
          receiptPath,
          currentHeadSha: existingReceiptAssessment.currentHeadSha,
          receiptHeadSha: existingReceiptAssessment.receiptHeadSha,
          receiptFreshForHead: existingReceiptAssessment.receiptFreshForHead,
          requestedCoverageSatisfied: existingReceiptAssessment.requestedCoverageSatisfied,
          requestedCoverageReason: existingReceiptAssessment.requestedCoverageReason,
          requestedCoverageMissingChecks: existingReceiptAssessment.requestedCoverageMissingChecks,
          receipt: existingReceiptAssessment.receipt
        }
      }
    };
  }
  const result = await runCommand(command, args, { cwd: repoRoot, env: process.env }, deps);
  let reviewLoopResult = null;
  let stdoutParseError = '';
  try {
    reviewLoopResult = parseJsonObjectOutput(result.stdout, 'local review loop stdout');
  } catch (error) {
    stdoutParseError = normalizeText(error?.message);
    reviewLoopResult = null;
  }
  let receiptFromFile = null;
  let receiptReadError = '';
  try {
    receiptFromFile = await readJsonIfPresent(resolvedReceiptPath);
  } catch (error) {
    receiptReadError = normalizeText(error?.message);
  }
  if (!reviewLoopResult && receiptFromFile && typeof receiptFromFile === 'object') {
    reviewLoopResult = {
      status: normalizeText(receiptFromFile?.overall?.status) || 'failed',
      source: 'docker-desktop-review-loop-receipt',
      reason: normalizeText(receiptFromFile?.overall?.message),
      receiptPath,
      receipt: receiptFromFile
    };
  }
  const ambiguousOutputReason = [
    stdoutParseError ? `Local review loop stdout was not valid JSON: ${stdoutParseError}` : '',
    receiptReadError ? `Receipt read failed: ${receiptReadError}` : '',
    !reviewLoopResult ? 'Docker/Desktop review loop did not yield a valid machine-readable result.' : ''
  ]
    .filter(Boolean)
    .join(' ');
  const localReviewLoopDetails = {
    status: normalizeText(reviewLoopResult?.status) || 'failed',
    source: normalizeText(reviewLoopResult?.source) || 'docker-desktop-review-loop',
    reason:
      normalizeText(reviewLoopResult?.reason) ||
      normalizeText(reviewLoopResult?.receipt?.overall?.message) ||
      ambiguousOutputReason ||
      normalizeText(result.stderr) ||
      normalizeText(result.stdout) ||
      'Docker/Desktop review loop did not return a status.',
    receiptPath,
    currentHeadSha: normalizeText(reviewLoopResult?.currentHeadSha) || null,
    receiptHeadSha: normalizeText(reviewLoopResult?.receiptHeadSha) || normalizeText(receiptFromFile?.git?.headSha) || null,
    receiptFreshForHead: typeof reviewLoopResult?.receiptFreshForHead === 'boolean' ? reviewLoopResult.receiptFreshForHead : null,
    requestedCoverageSatisfied:
      typeof reviewLoopResult?.requestedCoverageSatisfied === 'boolean' ? reviewLoopResult.requestedCoverageSatisfied : null,
    requestedCoverageReason: normalizeText(reviewLoopResult?.requestedCoverageReason) || null,
    requestedCoverageMissingChecks: uniqueStrings(
      Array.isArray(reviewLoopResult?.requestedCoverageMissingChecks) ? reviewLoopResult.requestedCoverageMissingChecks : []
    ),
    receipt: reviewLoopResult?.receipt ?? receiptFromFile ?? null
  };

  if (result.status !== 0 || localReviewLoopDetails.status !== 'passed') {
    return {
      status: 'blocked',
      outcome: 'local-review-loop-failed',
      reason: localReviewLoopDetails.reason,
      source: 'delivery-agent-broker',
      details: {
        actionType: 'local-review-loop',
        laneLifecycle: 'blocked',
        blockerClass: 'ci',
        retryable: true,
        nextWakeCondition: 'local-review-loop-green',
        helperCallsExecuted: uniqueStrings([
          ...(Array.isArray(baseReceipt?.details?.helperCallsExecuted) ? baseReceipt.details.helperCallsExecuted : []),
          commandText
        ]),
        filesTouched: uniqueStrings([
          ...(Array.isArray(baseReceipt?.details?.filesTouched) ? baseReceipt.details.filesTouched : []),
          receiptPath
        ]),
        localReviewLoop: localReviewLoopDetails
      }
    };
  }

  return {
    ...baseReceipt,
    reason: `${normalizeText(baseReceipt.reason) || 'Coding turn completed.'} Local Docker/Desktop review loop passed.`,
    details: {
      ...(baseReceipt.details && typeof baseReceipt.details === 'object' ? baseReceipt.details : {}),
      helperCallsExecuted: uniqueStrings([
        ...(Array.isArray(baseReceipt?.details?.helperCallsExecuted) ? baseReceipt.details.helperCallsExecuted : []),
        commandText
      ]),
      filesTouched: uniqueStrings([
        ...(Array.isArray(baseReceipt?.details?.filesTouched) ? baseReceipt.details.filesTouched : []),
        receiptPath
      ]),
      localReviewLoop: localReviewLoopDetails
    }
  };
}

async function listOpenIssues({ repository, repoRoot, deps = {} }) {
  if (typeof deps.listOpenIssuesFn === 'function') {
    const result = await deps.listOpenIssuesFn({ repository, repoRoot });
    return Array.isArray(result) ? result : [];
  }

  const result = await runCommand(
    'gh',
    [
      'issue',
      'list',
      '--repo',
      repository,
      '--state',
      'open',
      '--limit',
      '100',
      '--json',
      'number,title,body,labels,createdAt,updatedAt,url'
    ],
    { cwd: repoRoot, env: process.env },
    deps
  );
  if (result.status !== 0) {
    throw new Error(normalizeText(result.stderr) || normalizeText(result.stdout) || 'gh issue list failed');
  }

  let parsed = [];
  try {
    parsed = JSON.parse(result.stdout || '[]');
  } catch (error) {
    throw new Error(`Unable to parse gh issue list output: ${error.message}`);
  }

  return Array.isArray(parsed)
    ? parsed
        .map((entry) => normalizeIssueLike({ ...entry, repository }))
        .filter((entry) => entry && entry.state === 'OPEN')
    : [];
}

async function editIssueLabels({ repository, issueNumber, repoRoot, removeLabels = [], addLabels = [], deps = {} }) {
  if (typeof deps.editIssueLabelsFn === 'function') {
    return deps.editIssueLabelsFn({ repository, issueNumber, repoRoot, removeLabels, addLabels });
  }

  const args = ['issue', 'edit', String(issueNumber), '--repo', repository];
  for (const label of removeLabels.map((entry) => normalizeText(entry)).filter(Boolean)) {
    args.push('--remove-label', label);
  }
  for (const label of addLabels.map((entry) => normalizeText(entry)).filter(Boolean)) {
    args.push('--add-label', label);
  }

  if (args.length === 5) {
    return { status: 0, stdout: '', stderr: '' };
  }

  const result = await runCommand('gh', args, { cwd: repoRoot, env: process.env }, deps);
  if (result.status !== 0) {
    throw new Error(normalizeText(result.stderr) || normalizeText(result.stdout) || 'gh issue edit failed');
  }
  return result;
}

async function closeIssueWithComment({ repository, issueNumber, repoRoot, comment, deps = {} }) {
  if (typeof deps.closeIssueWithCommentFn === 'function') {
    return deps.closeIssueWithCommentFn({ repository, issueNumber, repoRoot, comment });
  }

  const args = ['issue', 'close', String(issueNumber), '--repo', repository];
  if (normalizeText(comment)) {
    args.push('--comment', normalizeText(comment));
  }

  const result = await runCommand('gh', args, { cwd: repoRoot, env: process.env }, deps);
  if (result.status !== 0) {
    throw new Error(normalizeText(result.stderr) || normalizeText(result.stdout) || 'gh issue close failed');
  }
  return result;
}

function shellEscapeHelperValue(value) {
  if (value == null) {
    return '';
  }
  const text = String(value);
  if (text === '') {
    return "''";
  }
  if (/^[A-Za-z0-9._\-/:]+$/.test(text)) {
    return text;
  }
  return `'${text.replace(/'/g, `'\\''`)}'`;
}

function buildRemoveLabelHelperCall(issueNumber, repository, labels = []) {
  const removeLabelFlags = labels
    .map((label) => normalizeText(label))
    .filter(Boolean)
    .map((label) => `--remove-label ${shellEscapeHelperValue(label)}`)
    .join(' ');
  return [`gh issue edit ${issueNumber}`, `--repo ${shellEscapeHelperValue(repository)}`, removeLabelFlags].filter(Boolean).join(' ');
}

function buildCloseIssueHelperCall(issueNumber, repository, { hasComment = false } = {}) {
  const repoArgument = `--repo ${shellEscapeHelperValue(repository)}`;
  return hasComment
    ? `gh issue close ${issueNumber} ${repoArgument} --comment <omitted>`
    : `gh issue close ${issueNumber} ${repoArgument}`;
}

async function syncStandingPriorityForRepo({ repository, repoRoot, deps = {} }) {
  if (typeof deps.syncStandingPriorityFn === 'function') {
    return deps.syncStandingPriorityFn({
      repository,
      repoRoot,
      env: {
        ...process.env,
        GITHUB_REPOSITORY: repository
      }
    });
  }

  const syncResult = await runCommand(
    'node',
    ['tools/priority/sync-standing-priority.mjs'],
    {
      cwd: repoRoot,
      env: {
        ...process.env,
        GITHUB_REPOSITORY: repository
      }
    },
    deps
  );
  if (syncResult.status !== 0) {
    throw new Error(
      normalizeText(syncResult.stderr) || normalizeText(syncResult.stdout) || 'priority sync failed after merge finalization'
    );
  }
  return syncResult;
}

function buildMergedIssueCloseComment({
  issueNumber,
  pullRequestNumber,
  pullRequestUrl,
  nextStandingIssueNumber,
  standingSelectionWarning = ''
}) {
  const parsedPullRequestNumber = Number.isInteger(pullRequestNumber)
    ? pullRequestNumber
    : Number.parseInt(String(pullRequestNumber ?? ''), 10);
  let prReference = 'the merged pull request';
  if (pullRequestUrl && Number.isInteger(parsedPullRequestNumber)) {
    prReference = `PR #${parsedPullRequestNumber} (${pullRequestUrl})`;
  } else if (pullRequestUrl) {
    prReference = `PR ${pullRequestUrl}`;
  } else if (Number.isInteger(parsedPullRequestNumber)) {
    prReference = `PR #${parsedPullRequestNumber}`;
  }
  if (nextStandingIssueNumber) {
    return `Completed by ${prReference}. Standing priority has advanced from #${issueNumber} to #${nextStandingIssueNumber}.`;
  }
  if (normalizeText(standingSelectionWarning)) {
    return `Completed by ${prReference}. Automatic standing-priority handoff is still pending because the next eligible issue could not be resolved cleanly.`;
  }
  return `Completed by ${prReference}. No next standing-priority issue is currently labeled, so the queue is now idle until a new issue is promoted.`;
}

async function finalizeMergedPullRequest({ taskPacket, repoRoot, deps = {} }) {
  if (typeof deps.finalizeMergedPullRequestFn === 'function') {
    return deps.finalizeMergedPullRequestFn({ taskPacket, repoRoot });
  }

  const repository = normalizeText(taskPacket?.repository);
  const delivery = taskPacket?.evidence?.delivery ?? {};
  const selectedIssue = delivery.selectedIssue ?? delivery.standingIssue ?? null;
  const standingIssue = delivery.standingIssue ?? null;
  const pullRequest = delivery.pullRequest ?? taskPacket?.pullRequest ?? null;
  const selectedIssueNumber = coercePositiveInteger(selectedIssue?.number);
  const standingIssueNumber = coercePositiveInteger(standingIssue?.number);
  const pullRequestNumber = coercePositiveInteger(pullRequest?.number) ?? extractPullRequestNumberFromUrl(pullRequest?.url);

  if (!repository || !selectedIssueNumber) {
    return {
      selectedIssueNumber: null,
      standingIssueNumber,
      nextStandingIssueNumber: null,
      helperCallsExecuted: []
    };
  }

  const helperCallsExecuted = [];
  let nextStandingIssueNumber = null;
  let standingSelectionWarning = '';
  let nextCandidate = null;
  if (standingIssueNumber && standingIssueNumber === selectedIssueNumber) {
    try {
      const openIssues = await listOpenIssues({ repository, repoRoot, deps });
      nextCandidate = await selectAutoStandingPriorityCandidateForRepo(repoRoot, repository, openIssues, {
        excludeIssueNumbers: [standingIssueNumber],
        fetchIssueDetailsFn: async (issueNumber) =>
          fetchIssue(issueNumber, repoRoot, repository, {
            ghIssueFetcher: deps.ghIssueFetcher,
            restIssueFetcher: deps.restIssueFetcher
          })
      });
    } catch (error) {
      standingSelectionWarning = normalizeText(error?.message) || 'unknown error';
    }

    if (!normalizeText(standingSelectionWarning)) {
      if (nextCandidate?.number) {
        const handoffFn = deps.handoffStandingPriorityFn ?? handoffStandingPriority;
        await handoffFn(nextCandidate.number, {
          repoSlug: repository,
          repoRoot,
          env: {
            ...process.env,
            GITHUB_REPOSITORY: repository
          },
          logger: deps.handoffLogger ?? (() => {}),
          releaseLease: false
        });
        nextStandingIssueNumber = nextCandidate.number;
        helperCallsExecuted.push(`node tools/priority/standing-priority-handoff.mjs ${nextCandidate.number}`);
      } else {
        const standingLabels = resolveStandingPriorityLabels(repoRoot, repository, process.env);
        if (standingLabels.length > 0) {
          await editIssueLabels({
            repository,
            issueNumber: standingIssueNumber,
            repoRoot,
            removeLabels: standingLabels,
            deps
          });
          helperCallsExecuted.push(buildRemoveLabelHelperCall(standingIssueNumber, repository, standingLabels));
        }
        await syncStandingPriorityForRepo({ repository, repoRoot, deps });
        helperCallsExecuted.push('node tools/priority/sync-standing-priority.mjs');
      }
    }
  }

  if (normalizeText(standingSelectionWarning)) {
    return {
      selectedIssueNumber,
      standingIssueNumber,
      nextStandingIssueNumber: null,
      standingSelectionWarning,
      issueClosed: false,
      helperCallsExecuted
    };
  }

  await closeIssueWithComment({
    repository,
    issueNumber: selectedIssueNumber,
    repoRoot,
    comment: buildMergedIssueCloseComment({
      issueNumber: selectedIssueNumber,
      pullRequestNumber,
      pullRequestUrl: normalizeText(pullRequest?.url) || null,
      nextStandingIssueNumber,
      standingSelectionWarning
    }),
    deps
  });
  helperCallsExecuted.push(buildCloseIssueHelperCall(selectedIssueNumber, repository, { hasComment: true }));

  return {
    selectedIssueNumber,
    standingIssueNumber,
    nextStandingIssueNumber,
    standingSelectionWarning,
    issueClosed: true,
    helperCallsExecuted
  };
}

async function autoSliceIssue({ taskPacket, repoRoot, deps = {} }) {
  if (typeof deps.autoSliceIssueFn === 'function') {
    return deps.autoSliceIssueFn({ taskPacket, repoRoot });
  }

  const repository = normalizeText(taskPacket?.repository);
  const parentIssue = taskPacket?.evidence?.delivery?.standingIssue ?? taskPacket?.evidence?.delivery?.selectedIssue ?? null;
  if (!repository || !parentIssue?.number || !parentIssue?.url) {
    throw new Error('Auto-slice requires repository and parent issue context.');
  }

  const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-slice-'));
  const bodyPath = path.join(tmpDir, 'issue-body.md');
  try {
    await writeFile(bodyPath, `${buildAutoSliceBody(parentIssue, taskPacket)}\n`, 'utf8');
    const createResult = await runCommand(
      'gh',
      [
        'issue',
        'create',
        '--repo',
        repository,
        '--title',
        buildAutoSliceTitle(parentIssue),
        '--body-file',
        bodyPath
      ],
      { cwd: repoRoot, env: process.env },
      deps
    );
    if (createResult.status !== 0) {
      throw new Error(normalizeText(createResult.stderr) || normalizeText(createResult.stdout) || 'gh issue create failed');
    }
    const childUrl = normalizeText(createResult.stdout)
      .split(/\r?\n/)
      .map((entry) => normalizeText(entry))
      .filter(Boolean)
      .pop();
    const childNumber = extractIssueNumberFromUrl(childUrl);
    if (!childUrl || !childNumber) {
      throw new Error(`Unable to parse created child issue URL from gh output: ${normalizeText(createResult.stdout)}`);
    }

    const metadataResult = await runCommand(
      'node',
      [
        'tools/npm/run-script.mjs',
        'priority:github:metadata:apply',
        '--',
        '--url',
        parentIssue.url,
        '--sub-issue',
        childUrl
      ],
      { cwd: repoRoot, env: process.env },
      deps
    );
    if (metadataResult.status !== 0) {
      throw new Error(
        normalizeText(metadataResult.stderr) || normalizeText(metadataResult.stdout) || 'priority:github:metadata:apply failed'
      );
    }

    const portfolioResult = await runCommand(
      'node',
      [
        'tools/npm/run-script.mjs',
        'priority:project:portfolio:apply',
        '--',
        '--url',
        childUrl,
        '--use-config'
      ],
      { cwd: repoRoot, env: process.env },
      deps
    );

    return {
      status: 'completed',
      outcome: 'child-issue-created',
      reason: `Created child issue #${childNumber} and linked it to parent issue #${parentIssue.number}.`,
      source: 'delivery-agent-broker',
      details: {
        actionType: 'create-child-issue',
        laneLifecycle: 'complete',
        blockerClass: 'none',
        retryable: false,
        nextWakeCondition: 'next-scheduler-cycle',
        helperCallsExecuted: [
          'gh issue create',
          'node tools/npm/run-script.mjs priority:github:metadata:apply',
          'node tools/npm/run-script.mjs priority:project:portfolio:apply'
        ],
        filesTouched: [],
        childIssue: {
          number: childNumber,
          url: childUrl
        },
        portfolioApplyStatus: portfolioResult.status === 0 ? 'applied' : 'best-effort-failed'
      }
    };
  } finally {
    await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  }
}
async function mergePullRequest({ taskPacket, repoRoot, deps = {} }) {
  if (typeof deps.mergePullRequestFn === 'function') {
    return deps.mergePullRequestFn({ taskPacket, repoRoot });
  }
  const pullRequest = taskPacket?.evidence?.delivery?.pullRequest ?? null;
  const repository = normalizeText(taskPacket?.repository);
  const prNumber = coercePositiveInteger(pullRequest?.number) ?? extractPullRequestNumberFromUrl(pullRequest?.url);
  if (!repository || !prNumber) {
    throw new Error('Merge action requires repository and pull request number.');
  }
  const result = await runCommand(
    'node',
    ['tools/priority/merge-sync-pr.mjs', '--pr', String(prNumber), '--repo', repository],
    { cwd: repoRoot, env: process.env },
    deps
  );
  if (result.status !== 0) {
    const message = normalizeText(result.stderr) || normalizeText(result.stdout) || `merge-sync failed (${result.status})`;
    return {
      status: 'blocked',
      outcome: isRateLimitMessage(message) ? 'rate-limit' : 'merge-blocked',
      reason: message,
      source: 'delivery-agent-broker',
      details: {
        actionType: 'merge-pr',
        laneLifecycle: 'blocked',
        blockerClass: isRateLimitMessage(message) ? 'rate-limit' : 'merge',
        retryable: isRateLimitMessage(message),
        nextWakeCondition: isRateLimitMessage(message) ? 'github-rate-limit-reset' : 'mergeable-pr'
      }
    };
  }
  return {
    status: 'completed',
    outcome: 'merged',
    reason: `Merged PR #${prNumber}.`,
    source: 'delivery-agent-broker',
    details: {
      actionType: 'merge-pr',
      laneLifecycle: 'complete',
      blockerClass: 'none',
      retryable: false,
      nextWakeCondition: 'next-scheduler-cycle',
      helperCallsExecuted: ['node tools/priority/merge-sync-pr.mjs'],
      filesTouched: []
    }
  };
}

async function updatePullRequestBranch({ taskPacket, repoRoot, executionRoot = repoRoot, deps = {} }) {
  if (typeof deps.updatePullRequestBranchFn === 'function') {
    return deps.updatePullRequestBranchFn({ taskPacket, repoRoot, executionRoot });
  }
  const pullRequest = taskPacket?.evidence?.delivery?.pullRequest ?? null;
  const repository = normalizeText(taskPacket?.repository);
  const prNumber = coercePositiveInteger(pullRequest?.number) ?? extractPullRequestNumberFromUrl(pullRequest?.url);
  const branchName =
    normalizeText(pullRequest?.headRefName) ||
    normalizeText(taskPacket?.branch?.name) ||
    normalizeText(taskPacket?.evidence?.lane?.branch) ||
    null;
  const baseRefName = normalizeText(pullRequest?.baseRefName) || 'develop';
  if (!repository || !prNumber) {
    throw new Error('Branch sync action requires repository and pull request number.');
  }
  const result = await runCommand(
    'gh',
    ['pr', 'update-branch', String(prNumber), '--repo', repository],
    { cwd: executionRoot, env: process.env },
    deps
  );
  if (result.status !== 0) {
    const message = normalizeText(result.stderr) || normalizeText(result.stdout) || `pr update-branch failed (${result.status})`;
    const mergeBlocked = /conflict|rebase|merge/i.test(message);
    const helperCallsExecuted = ['gh pr update-branch'];
    if (!isRateLimitMessage(message) && !mergeBlocked && branchName) {
      const workspaceStatus = await runCommand(
        'git',
        ['status', '--porcelain'],
        { cwd: executionRoot, env: process.env },
        deps
      );
      if (workspaceStatus.status === 0 && !normalizeText(workspaceStatus.stdout)) {
        const upstreamRefresh = await refreshUpstreamTrackingRef({
          baseRefName,
          initialArgs: ['fetch', 'upstream', baseRefName],
          runGitFn: async (args) =>
            runCommand('git', args, { cwd: executionRoot, env: process.env }, deps)
        });
        const upstreamFetchResult = upstreamRefresh.result;
        helperCallsExecuted.push(...upstreamRefresh.attempts);
        if (upstreamFetchResult.status !== 0) {
          const upstreamFetchMessage =
            normalizeText(upstreamRefresh.initialMessage) ||
            extractGitResultMessage(upstreamFetchResult) ||
            `git fetch upstream failed (${upstreamFetchResult.status})`;
          return {
            status: 'blocked',
            outcome: isRateLimitMessage(upstreamFetchMessage) ? 'rate-limit' : 'branch-sync-failed',
            reason: upstreamFetchMessage,
            source: 'delivery-agent-broker',
            details: {
              actionType: 'sync-pr-branch',
              laneLifecycle: 'waiting-ci',
              blockerClass: isRateLimitMessage(upstreamFetchMessage) ? 'rate-limit' : 'ci',
              retryable: true,
              nextWakeCondition: isRateLimitMessage(upstreamFetchMessage) ? 'github-rate-limit-reset' : 'branch-sync-retry',
              helperCallsExecuted,
              filesTouched: []
            }
          };
        }
        const originFetchResult = await runCommand(
          'git',
          ['fetch', 'origin', branchName],
          { cwd: executionRoot, env: process.env },
          deps
        );
        helperCallsExecuted.push(`git fetch origin ${branchName}`);
        if (originFetchResult.status !== 0) {
          const originFetchMessage =
            normalizeText(originFetchResult.stderr) ||
            normalizeText(originFetchResult.stdout) ||
            `git fetch origin failed (${originFetchResult.status})`;
          return {
            status: 'blocked',
            outcome: isRateLimitMessage(originFetchMessage) ? 'rate-limit' : 'branch-sync-failed',
            reason: originFetchMessage,
            source: 'delivery-agent-broker',
            details: {
              actionType: 'sync-pr-branch',
              laneLifecycle: 'waiting-ci',
              blockerClass: isRateLimitMessage(originFetchMessage) ? 'rate-limit' : 'ci',
              retryable: true,
              nextWakeCondition: isRateLimitMessage(originFetchMessage) ? 'github-rate-limit-reset' : 'branch-sync-retry',
              helperCallsExecuted,
              filesTouched: []
            }
          };
        }
        const checkoutResult = await runCommand('git', ['checkout', branchName], { cwd: executionRoot, env: process.env }, deps);
        helperCallsExecuted.push(`git checkout ${branchName}`);
        if (checkoutResult.status !== 0) {
          const checkoutMessage =
            normalizeText(checkoutResult.stderr) ||
            normalizeText(checkoutResult.stdout) ||
            `git checkout failed (${checkoutResult.status})`;
          return {
            status: 'blocked',
            outcome: isRateLimitMessage(checkoutMessage) ? 'rate-limit' : 'branch-sync-failed',
            reason: checkoutMessage,
            source: 'delivery-agent-broker',
            details: {
              actionType: 'sync-pr-branch',
              laneLifecycle: 'waiting-ci',
              blockerClass: isRateLimitMessage(checkoutMessage) ? 'rate-limit' : 'ci',
              retryable: true,
              nextWakeCondition: isRateLimitMessage(checkoutMessage) ? 'github-rate-limit-reset' : 'branch-sync-retry',
              helperCallsExecuted,
              filesTouched: []
            }
          };
        }
        const rebaseResult = await runCommand(
          'git',
          ['rebase', `upstream/${baseRefName}`],
          { cwd: executionRoot, env: process.env },
          deps
        );
        helperCallsExecuted.push(`git rebase upstream/${baseRefName}`);
        if (rebaseResult.status === 0) {
          const pushResult = await runCommand(
            'git',
            ['push', '--force-with-lease', 'origin', `HEAD:${branchName}`],
            { cwd: executionRoot, env: process.env },
            deps
          );
          helperCallsExecuted.push(`git push --force-with-lease origin HEAD:${branchName}`);
          if (pushResult.status === 0) {
            return {
              status: 'completed',
              outcome: 'branch-updated',
              reason: `Updated PR #${prNumber} with the latest base branch.`,
              source: 'delivery-agent-broker',
              details: {
                actionType: 'sync-pr-branch',
                laneLifecycle: 'waiting-ci',
                blockerClass: 'ci',
                retryable: true,
                nextWakeCondition: 'checks-green',
                helperCallsExecuted,
                filesTouched: []
              }
            };
          }
          const pushMessage =
            normalizeText(pushResult.stderr) || normalizeText(pushResult.stdout) || `git push failed (${pushResult.status})`;
          return {
            status: 'blocked',
            outcome: isRateLimitMessage(pushMessage) ? 'rate-limit' : 'branch-sync-failed',
            reason: pushMessage,
            source: 'delivery-agent-broker',
            details: {
              actionType: 'sync-pr-branch',
              laneLifecycle: 'waiting-ci',
              blockerClass: isRateLimitMessage(pushMessage) ? 'rate-limit' : 'ci',
              retryable: true,
              nextWakeCondition: isRateLimitMessage(pushMessage) ? 'github-rate-limit-reset' : 'branch-sync-retry',
              helperCallsExecuted,
              filesTouched: []
            }
          };
        }
        const rebaseMessage =
          normalizeText(rebaseResult.stderr) || normalizeText(rebaseResult.stdout) || `git rebase failed (${rebaseResult.status})`;
        if (/conflict|could not apply|resolve all conflicts/i.test(rebaseMessage)) {
          const abortResult = await runCommand(
            'git',
            ['rebase', '--abort'],
            { cwd: executionRoot, env: process.env },
            deps
          );
          if (abortResult.status === 0) {
            helperCallsExecuted.push('git rebase --abort');
          }
        }
        return {
          status: 'blocked',
          outcome: /conflict|could not apply|resolve all conflicts/i.test(rebaseMessage)
            ? 'branch-sync-blocked'
            : 'branch-sync-failed',
          reason: rebaseMessage,
          source: 'delivery-agent-broker',
          details: {
            actionType: 'sync-pr-branch',
            laneLifecycle: /conflict|could not apply|resolve all conflicts/i.test(rebaseMessage) ? 'blocked' : 'waiting-ci',
            blockerClass: /conflict|could not apply|resolve all conflicts/i.test(rebaseMessage) ? 'merge' : 'ci',
            retryable: /conflict|could not apply|resolve all conflicts/i.test(rebaseMessage) ? false : true,
            nextWakeCondition: /conflict|could not apply|resolve all conflicts/i.test(rebaseMessage)
              ? 'manual-conflict-resolution'
              : 'branch-sync-retry',
            helperCallsExecuted,
            filesTouched: []
          }
        };
      }
    }
    return {
      status: 'blocked',
      outcome: isRateLimitMessage(message) ? 'rate-limit' : mergeBlocked ? 'branch-sync-blocked' : 'branch-sync-failed',
      reason: message,
      source: 'delivery-agent-broker',
      details: {
        actionType: 'sync-pr-branch',
        laneLifecycle: mergeBlocked ? 'blocked' : 'waiting-ci',
        blockerClass: isRateLimitMessage(message) ? 'rate-limit' : mergeBlocked ? 'merge' : 'ci',
        retryable: isRateLimitMessage(message) || !mergeBlocked,
        nextWakeCondition: isRateLimitMessage(message)
          ? 'github-rate-limit-reset'
          : mergeBlocked
            ? 'manual-conflict-resolution'
            : 'branch-sync-retry',
        helperCallsExecuted,
        filesTouched: []
      }
    };
  }
  return {
    status: 'completed',
    outcome: 'branch-updated',
    reason: `Updated PR #${prNumber} with the latest base branch.`,
    source: 'delivery-agent-broker',
    details: {
      actionType: 'sync-pr-branch',
      laneLifecycle: 'waiting-ci',
      blockerClass: 'ci',
      retryable: true,
      nextWakeCondition: 'checks-green',
      helperCallsExecuted: ['gh pr update-branch'],
      filesTouched: []
    }
  };
}

async function invokeCodingTurnCommand({ taskPacket, policy, repoRoot, executionRoot = repoRoot, policyPath, deps = {} }) {
  if (typeof deps.invokeCodingTurnFn === 'function') {
    const injectedReceipt = await deps.invokeCodingTurnFn({ taskPacket, policy, repoRoot, executionRoot, policyPath });
    return maybeRunLocalReviewLoop({
      baseReceipt: injectedReceipt,
      taskPacket,
      policy,
      repoRoot,
      deps
    });
  }

  const command = normalizeCommandList(policy?.codingTurnCommand);
  if (command.length === 0) {
    return {
      status: 'blocked',
      outcome: 'coding-command-missing',
      reason: 'delivery-agent policy does not define codingTurnCommand for unattended coding turns.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'execute-coding-turn',
        laneLifecycle: 'blocked',
        blockerClass: 'scope',
        retryable: false,
        nextWakeCondition: 'policy-updated-with-coding-command',
        helperCallsExecuted: [],
        filesTouched: []
      }
    };
  }

  const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-turn-'));
  const receiptPath = path.join(tmpDir, 'coding-receipt.json');
  try {
    const liveAgentModelSelection = normalizeOptionalObject(taskPacket?.evidence?.delivery?.liveAgentModelSelection);
    const liveAgentCurrentProvider = normalizeOptionalObject(liveAgentModelSelection?.currentProvider);
    const env = {
      ...process.env,
      COMPAREVI_DELIVERY_TASK_PACKET_PATH: taskPacket.__taskPacketPath || '',
      COMPAREVI_DELIVERY_RECEIPT_PATH: receiptPath,
      COMPAREVI_DELIVERY_POLICY_PATH: policyPath || '',
      COMPAREVI_DELIVERY_REPO_ROOT: executionRoot,
      COMPAREVI_DELIVERY_CONTROL_ROOT: repoRoot,
      COMPAREVI_LIVE_AGENT_MODEL_SELECTION_PATH: normalizeText(liveAgentModelSelection?.reportPath) || '',
      COMPAREVI_LIVE_AGENT_MODEL_SELECTION_MODE: normalizeText(liveAgentModelSelection?.mode) || '',
      COMPAREVI_LIVE_AGENT_MODEL_PROVIDER_ID: normalizeText(liveAgentCurrentProvider?.providerId) || '',
      COMPAREVI_LIVE_AGENT_MODEL_CURRENT: normalizeText(liveAgentCurrentProvider?.currentModel) || '',
      COMPAREVI_LIVE_AGENT_MODEL_SELECTED: normalizeText(liveAgentCurrentProvider?.selectedModel) || '',
      COMPAREVI_LIVE_AGENT_MODEL_ACTION: normalizeText(liveAgentCurrentProvider?.action) || '',
      COMPAREVI_LIVE_AGENT_MODEL_CONFIDENCE: normalizeText(liveAgentCurrentProvider?.confidence) || ''
    };
    const result = await runCommand(command[0], command.slice(1), { cwd: executionRoot, env }, deps);
    const fileReceipt = await readJsonIfPresent(receiptPath);
    if (result.status !== 0) {
      const message = normalizeText(result.stderr) || normalizeText(result.stdout) || `${command[0]} failed (${result.status})`;
      return {
        status: 'blocked',
        outcome: isRateLimitMessage(message) ? 'rate-limit' : 'coding-command-failed',
        reason: message,
        source: 'delivery-agent-broker',
        details: {
          actionType: 'execute-coding-turn',
          laneLifecycle: 'blocked',
          blockerClass: isRateLimitMessage(message) ? 'rate-limit' : 'helperbug',
          retryable: isRateLimitMessage(message),
          nextWakeCondition: isRateLimitMessage(message) ? 'github-rate-limit-reset' : 'coding-command-fixed',
          helperCallsExecuted: [command.join(' ')],
          filesTouched: fileReceipt?.details?.filesTouched ?? []
        }
      };
    }
    if (fileReceipt && typeof fileReceipt === 'object') {
      return maybeRunLocalReviewLoop({
        baseReceipt: {
        ...fileReceipt,
        source: normalizeText(fileReceipt.source) || 'delivery-agent-broker',
        details: {
          ...(fileReceipt.details && typeof fileReceipt.details === 'object' ? fileReceipt.details : {}),
          helperCallsExecuted: [command.join(' '), ...(Array.isArray(fileReceipt.details?.helperCallsExecuted) ? fileReceipt.details.helperCallsExecuted : [])],
          laneLifecycle: normalizeLifecycle(fileReceipt.details?.laneLifecycle, 'coding')
        }
        },
        taskPacket,
        policy,
        repoRoot,
        deps
      });
    }
    try {
      const stdoutReceipt = JSON.parse(result.stdout);
      if (stdoutReceipt && typeof stdoutReceipt === 'object') {
        return maybeRunLocalReviewLoop({
          baseReceipt: {
          ...stdoutReceipt,
          source: normalizeText(stdoutReceipt.source) || 'delivery-agent-broker'
          },
          taskPacket,
          policy,
          repoRoot,
          deps
        });
      }
    } catch {
      // Ignore stdout parse failures and fall back to a generic success receipt.
    }
    return maybeRunLocalReviewLoop({
      baseReceipt: {
      status: 'completed',
      outcome: 'coding-command-finished',
      reason: 'codingTurnCommand completed without an explicit receipt payload.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'execute-coding-turn',
        laneLifecycle: 'coding',
        blockerClass: 'none',
        retryable: true,
        nextWakeCondition: 'scheduler-rescan',
        helperCallsExecuted: [command.join(' ')],
        filesTouched: []
      }
      },
      taskPacket,
      policy,
      repoRoot,
      deps
    });
  } finally {
    await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  }
}

export function planDeliveryBrokerAction(taskPacket = {}) {
  const delivery = taskPacket?.evidence?.delivery ?? {};
  const pullRequest = delivery.pullRequest ?? null;
  const concurrentLaneStatus = normalizeOptionalObject(delivery.concurrentLaneStatus);
  const backlog = delivery.backlog ?? null;
  const lifecycle = normalizeLifecycle(delivery.laneLifecycle, taskPacket.status === 'idle' ? 'idle' : 'planning');
  if (taskPacket.status === 'idle') {
    return {
      actionType: 'idle',
      laneLifecycle: 'idle'
    };
  }
  if (backlog?.mode === 'repair-child-slice') {
    return {
      actionType: 'reshape-backlog',
      laneLifecycle: 'reshaping-backlog'
    };
  }
  if (shouldDispatchConcurrentLanes(taskPacket)) {
    return {
      actionType: 'dispatch-concurrent-lanes',
      laneLifecycle: lifecycle === 'planning' ? 'waiting-ci' : lifecycle
    };
  }
  if (!pullRequest?.url) {
    const concurrentLanePlan = buildConcurrentLaneWatchPlan(concurrentLaneStatus);
    if (concurrentLanePlan) {
      return concurrentLanePlan;
    }
  }
  if (pullRequest?.url) {
    if (pullRequest.syncRequired === true || normalizeText(pullRequest.mergeStateStatus).toUpperCase() === 'BEHIND') {
      return {
        actionType: 'sync-pr-branch',
        laneLifecycle: 'waiting-ci'
      };
    }
    if (pullRequest.readyToMerge === true) {
      return {
        actionType: 'merge-pr',
        laneLifecycle: 'ready-merge',
        pullRequest
      };
    }
    if (lifecycle === 'coding') {
      return {
        actionType: 'execute-coding-turn',
        laneLifecycle: 'coding',
        pullRequest
      };
    }
    if (pullRequest.checks?.blockerClass === 'ci' || lifecycle === 'waiting-ci') {
      return {
        actionType: 'watch-pr',
        laneLifecycle: 'waiting-ci',
        pullRequest
      };
    }
    if (lifecycle === 'waiting-review') {
      return {
        actionType: 'watch-pr',
        laneLifecycle: 'waiting-review',
        pullRequest
      };
    }
    return {
      actionType: 'watch-pr',
      laneLifecycle: lifecycle,
      pullRequest
    };
  }
  return {
    actionType: 'execute-coding-turn',
    laneLifecycle: lifecycle === 'planning' ? 'coding' : lifecycle
  };
}

function resolveProviderDispatchOutcome(result = {}) {
  const status = normalizeText(result.status).toLowerCase();
  const laneLifecycle = normalizeLifecycle(result.details?.laneLifecycle, 'idle');
  const blockerClass = normalizeText(result.details?.blockerClass) || null;
  if (status === 'blocked' || laneLifecycle === 'blocked') {
    return {
      dispatchStatus: 'blocked',
      completionStatus: 'blocked',
      failureClass: blockerClass
    };
  }
  if (['waiting-ci', 'waiting-review', 'ready-merge'].includes(laneLifecycle)) {
    return {
      dispatchStatus: 'completed',
      completionStatus: 'waiting',
      failureClass: null
    };
  }
  return {
    dispatchStatus: 'completed',
    completionStatus: 'completed',
    failureClass: null
  };
}

function buildTaskPacketProviderSelection(taskPacket) {
  return normalizeOptionalObject(taskPacket?.evidence?.delivery?.workerProviderSelection);
}

function withWorkerProviderDispatch(result, taskPacket) {
  if (!result || typeof result !== 'object') {
    return result;
  }
  const providerSelection = buildTaskPacketProviderSelection(taskPacket);
  if (!providerSelection?.selectedProviderId) {
    return result;
  }
  const dispatchOutcome = resolveProviderDispatchOutcome(result);
  return {
    ...result,
    details: {
      ...(result.details && typeof result.details === 'object' ? result.details : {}),
      workerProviderSelection: providerSelection,
      providerDispatch: buildWorkerProviderDispatchReceipt(providerSelection, {
        workerSlotId: normalizeText(taskPacket?.evidence?.lane?.workerSlotId) || null,
        ...dispatchOutcome
      })
    }
  };
}

export async function runDeliveryTurnBroker({
  taskPacket,
  taskPacketPath = '',
  repoRoot,
  policyPath,
  now = new Date(),
  deps = {}
}) {
  if (!taskPacket || typeof taskPacket !== 'object') {
    throw new Error('runDeliveryTurnBroker requires a task packet object.');
  }
  const effectivePolicyPath = resolvePath(repoRoot, policyPath || DELIVERY_AGENT_POLICY_RELATIVE_PATH);
  const policy = await loadDeliveryAgentPolicy(repoRoot, {
    ...deps,
    policyPath: effectivePolicyPath
  });
  const enrichedPacket = {
    ...taskPacket,
    __taskPacketPath: taskPacketPath
  };
  const executionRoot = resolveExecutionRoot(repoRoot, enrichedPacket);
  const planned = planDeliveryBrokerAction(enrichedPacket);

  if (planned.actionType === 'idle') {
    return withWorkerProviderDispatch({
      status: 'completed',
      outcome: 'idle',
      reason: normalizeText(taskPacket.objective?.summary) || 'No actionable delivery lane is selected.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'idle',
        laneLifecycle: 'idle',
        blockerClass: 'none',
        retryable: false,
        nextWakeCondition: 'next-scheduler-cycle',
        helperCallsExecuted: [],
        filesTouched: []
      }
    }, enrichedPacket);
  }

  if (planned.actionType === 'watch-pr') {
    const draftOnlyResult = await enforceDraftOnlyReviewContract({
      planned,
      taskPacket: enrichedPacket,
      policy,
      repoRoot,
      deps
    });
    if (draftOnlyResult) {
      return withWorkerProviderDispatch(draftOnlyResult, enrichedPacket);
    }
    return withWorkerProviderDispatch({
      status: 'completed',
      outcome: planned.laneLifecycle,
      reason:
        planned.laneLifecycle === 'waiting-review'
          ? 'Pull request is waiting on review disposition.'
          : 'Pull request is waiting on required checks.',
      source: 'delivery-agent-broker',
      details: {
        actionType: 'watch-pr',
        laneLifecycle: planned.laneLifecycle,
        blockerClass: planned.laneLifecycle === 'waiting-review' ? 'review' : 'ci',
        retryable: true,
        nextWakeCondition:
          planned.laneLifecycle === 'waiting-review'
            ? normalizeText(planned.pullRequest?.nextWakeCondition) || 'review-disposition-updated'
            : 'checks-green',
        pollIntervalSecondsHint:
          coercePositiveInteger(planned.pullRequest?.pollIntervalSecondsHint) ?? null,
        reviewPhase: planned.pullRequest?.isDraft === true ? 'draft-review' : 'ready-validation',
        reviewMonitor:
          planned.laneLifecycle === 'waiting-review'
            ? planned.pullRequest?.copilotReviewWorkflow ?? null
            : null,
        helperCallsExecuted: [],
        filesTouched: []
      }
    }, enrichedPacket);
  }

  if (planned.actionType === 'watch-concurrent-lanes') {
    return withWorkerProviderDispatch({
      status: planned.laneLifecycle === 'blocked' ? 'blocked' : 'completed',
      outcome: planned.laneLifecycle,
      reason: planned.reason,
      source: 'delivery-agent-broker',
      details: {
        actionType: 'watch-concurrent-lanes',
        laneLifecycle: planned.laneLifecycle,
        blockerClass: planned.blockerClass,
        retryable: planned.retryable === true,
        nextWakeCondition: planned.nextWakeCondition,
        helperCallsExecuted: [],
        filesTouched: [],
        concurrentLaneStatus: planned.concurrentLaneStatus
      }
    }, enrichedPacket);
  }

  if (planned.actionType === 'dispatch-concurrent-lanes') {
    const dispatchResult = await dispatchConcurrentLanes({
      taskPacket: enrichedPacket,
      repoRoot,
      policy,
      deps
    });
    return withWorkerProviderDispatch(dispatchResult, enrichedPacket);
  }

  if (planned.actionType === 'sync-pr-branch') {
    return withWorkerProviderDispatch(await updatePullRequestBranch({
      taskPacket: enrichedPacket,
      repoRoot,
      executionRoot,
      deps
    }), enrichedPacket);
  }

  if (planned.actionType === 'merge-pr') {
    const mergeResult = await mergePullRequest({
      taskPacket: enrichedPacket,
      repoRoot,
      deps
    });
    if (mergeResult.status !== 'completed' || mergeResult.outcome !== 'merged') {
      return withWorkerProviderDispatch(mergeResult, enrichedPacket);
    }

    try {
      const finalization = await finalizeMergedPullRequest({
        taskPacket: enrichedPacket,
        repoRoot,
        deps
      });
      if (normalizeText(finalization.standingSelectionWarning)) {
        return withWorkerProviderDispatch({
          status: 'blocked',
          outcome: 'merged-finalization-blocked',
          reason: `Merged PR for issue #${finalization.selectedIssueNumber}, but automatic standing-priority handoff is still pending: ${finalization.standingSelectionWarning}. The standing issue remains open for deterministic retry.`,
          source: 'delivery-agent-broker',
          details: {
            actionType: 'merge-pr',
            laneLifecycle: 'blocked',
            blockerClass: 'helper',
            retryable: true,
            nextWakeCondition: 'merged-lane-finalization-retry',
            helperCallsExecuted: [
              ...(Array.isArray(mergeResult.details?.helperCallsExecuted) ? mergeResult.details.helperCallsExecuted : []),
              ...(Array.isArray(finalization.helperCallsExecuted) ? finalization.helperCallsExecuted : [])
            ],
            filesTouched: [],
            finalizedIssueNumber: null,
            pendingIssueNumber: finalization.selectedIssueNumber,
            standingIssueNumber: finalization.standingIssueNumber,
            nextStandingIssueNumber: finalization.nextStandingIssueNumber ?? null,
            standingSelectionWarning: normalizeText(finalization.standingSelectionWarning) || ''
          }
        }, enrichedPacket);
      }
      return withWorkerProviderDispatch({
        ...mergeResult,
        reason:
          finalization.selectedIssueNumber && finalization.nextStandingIssueNumber
            ? `Merged PR and closed issue #${finalization.selectedIssueNumber}; standing priority advanced to #${finalization.nextStandingIssueNumber}.`
            : finalization.selectedIssueNumber && normalizeText(finalization.standingSelectionWarning)
              ? `Merged PR and closed issue #${finalization.selectedIssueNumber}; automatic standing-priority handoff is pending.`
            : finalization.selectedIssueNumber
              ? `Merged PR and closed issue #${finalization.selectedIssueNumber}.`
              : mergeResult.reason,
        details: {
          ...mergeResult.details,
          helperCallsExecuted: [
            ...(Array.isArray(mergeResult.details?.helperCallsExecuted) ? mergeResult.details.helperCallsExecuted : []),
            ...(Array.isArray(finalization.helperCallsExecuted) ? finalization.helperCallsExecuted : [])
          ],
          finalizedIssueNumber: finalization.selectedIssueNumber,
          standingIssueNumber: finalization.standingIssueNumber,
          nextStandingIssueNumber: finalization.nextStandingIssueNumber ?? null,
          standingSelectionWarning: normalizeText(finalization.standingSelectionWarning) || ''
        }
      }, enrichedPacket);
    } catch (error) {
      return withWorkerProviderDispatch({
        status: 'blocked',
        outcome: 'merged-finalization-blocked',
        reason: `${mergeResult.reason} Finalization failed: ${error.message}`,
        source: 'delivery-agent-broker',
        details: {
          actionType: 'merge-pr',
          laneLifecycle: 'blocked',
          blockerClass: 'helperbug',
          retryable: true,
          nextWakeCondition: 'merged-lane-finalization-retry',
          helperCallsExecuted: Array.isArray(mergeResult.details?.helperCallsExecuted)
            ? mergeResult.details.helperCallsExecuted
            : [],
          filesTouched: []
        }
      }, enrichedPacket);
    }
  }

  if (planned.actionType === 'reshape-backlog') {
    if (policy.autoSlice !== true) {
      return withWorkerProviderDispatch({
        status: 'blocked',
        outcome: 'auto-slice-disabled',
        reason: 'delivery-agent policy disables unattended child-slice creation.',
        source: 'delivery-agent-broker',
        details: {
          actionType: 'reshape-backlog',
          laneLifecycle: 'blocked',
          blockerClass: 'policy',
          retryable: false,
          nextWakeCondition: 'policy-updated-to-enable-auto-slice',
          helperCallsExecuted: [],
          filesTouched: []
        }
      }, enrichedPacket);
    }
    return withWorkerProviderDispatch(await autoSliceIssue({
      taskPacket: enrichedPacket,
      repoRoot,
      deps,
      now
    }), enrichedPacket);
  }

  return withWorkerProviderDispatch(await invokeCodingTurnCommand({
    taskPacket: enrichedPacket,
    policy,
    repoRoot,
    executionRoot,
    policyPath: effectivePolicyPath,
    deps
  }), enrichedPacket);
}

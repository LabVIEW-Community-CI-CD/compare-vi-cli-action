#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const POLICY_SCHEMA = 'priority/live-agent-model-selection-policy@v1';
export const REPORT_SCHEMA = 'priority/live-agent-model-selection-report@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'live-agent-model-selection.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'live-agent-model-selection.json');
export const DEFAULT_COST_ROLLUP_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_THROUGHPUT_SCORECARD_PATH = path.join('tests', 'results', '_agent', 'throughput', 'throughput-scorecard.json');
export const DEFAULT_DELIVERY_MEMORY_PATH = path.join('tests', 'results', '_agent', 'runtime', 'delivery-memory.json');

const CONFIDENCE_LEVELS = ['low', 'medium', 'high'];
const HELP = [
  'Usage: node tools/priority/live-agent-model-selection.mjs [options]',
  '',
  'Options:',
  `  --policy <path>             Policy path (default: ${DEFAULT_POLICY_PATH}).`,
  `  --cost-rollup <path>        Agent cost rollup path (default: ${DEFAULT_COST_ROLLUP_PATH}).`,
  `  --throughput <path>         Throughput scorecard path (default: ${DEFAULT_THROUGHPUT_SCORECARD_PATH}).`,
  `  --delivery-memory <path>    Delivery memory path (default: ${DEFAULT_DELIVERY_MEMORY_PATH}).`,
  '  --previous-report <path>    Previous selector report path (default: policy.previousReportPath or output).',
  `  --output <path>             Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --repo <owner/repo>         Repository slug override.',
  '  --fail-on-blockers          Exit non-zero when blockers are present.',
  '  --no-fail-on-blockers       Always emit the report and exit zero (default).',
  '  -h, --help                  Show help.'
];

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function normalizeReasoningEffort(value) {
  const normalized = normalizeText(value).toLowerCase();
  return ['low', 'medium', 'high', 'xhigh'].includes(normalized) ? normalized : null;
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function toNonNegativeInteger(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : null;
}

function toNonNegativeNumber(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function toRatio(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.min(Math.max(parsed, 0), 1) : null;
}

function roundNumber(value, digits = 6) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  return Number(parsed.toFixed(digits));
}

function safeRelative(filePath) {
  return path.relative(process.cwd(), path.resolve(filePath)).replace(/\\/g, '/');
}

function inferPolicyRoot(policyPath) {
  const normalized = path.resolve(policyPath);
  const marker = `${path.sep}tools${path.sep}policy${path.sep}`;
  const markerIndex = normalized.lastIndexOf(marker);
  if (markerIndex >= 0) {
    return normalized.slice(0, markerIndex);
  }
  return path.dirname(normalized);
}

function resolvePathFromRoot(baseRoot, candidatePath) {
  if (!normalizeText(candidatePath)) {
    return path.resolve(baseRoot);
  }
  return path.isAbsolute(candidatePath) ? candidatePath : path.resolve(baseRoot, candidatePath);
}

function ensureArray(value) {
  return Array.isArray(value) ? value : [];
}

function uniqueStrings(values) {
  return [...new Set(ensureArray(values).map((entry) => normalizeText(entry)).filter(Boolean))];
}

function compareReasoningEffort(left, right) {
  const order = ['low', 'medium', 'high', 'xhigh'];
  return order.indexOf(normalizeReasoningEffort(left)) - order.indexOf(normalizeReasoningEffort(right));
}

function compareConfidence(left, right) {
  return CONFIDENCE_LEVELS.indexOf(normalizeText(left).toLowerCase()) - CONFIDENCE_LEVELS.indexOf(normalizeText(right).toLowerCase());
}

function maxConfidence(left, right) {
  return compareConfidence(left, right) >= 0 ? left : right;
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) return null;
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo) {
  if (normalizeText(explicitRepo).includes('/')) return normalizeText(explicitRepo);
  if (normalizeText(process.env.GITHUB_REPOSITORY).includes('/')) return normalizeText(process.env.GITHUB_REPOSITORY);
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remote}.url`, { stdio: ['ignore', 'pipe', 'ignore'] })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) return slug;
    } catch {
      // ignore
    }
  }
  return null;
}

function readJsonInput(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    return { exists: false, path: resolved, payload: null, error: null };
  }
  try {
    return { exists: true, path: resolved, payload: JSON.parse(fs.readFileSync(resolved, 'utf8')), error: null };
  } catch (error) {
    return { exists: true, path: resolved, payload: null, error: error?.message || String(error) };
  }
}

function createBlocker(code, message, inputPath = null) {
  return { code, message, inputPath: inputPath ? safeRelative(inputPath) : null };
}

function normalizeCandidateModels(value, fallbackModel = '', fallbackReasoningEffort = null) {
  const models = ensureArray(value)
    .map((entry, index) => {
      if (typeof entry === 'string') {
        return {
          model: normalizeText(entry),
          reasoningEffort: normalizeReasoningEffort(fallbackReasoningEffort),
          strength: index + 1,
          costTier: index + 1,
          notes: null
        };
      }
      return {
        model: normalizeText(entry?.model),
        reasoningEffort: normalizeReasoningEffort(entry?.reasoningEffort),
        strength: toNonNegativeInteger(entry?.strength) ?? index + 1,
        costTier: toNonNegativeInteger(entry?.costTier) ?? index + 1,
        notes: normalizeText(entry?.notes) || null
      };
    })
    .filter((entry) => entry.model);
  if (models.length === 0 && normalizeText(fallbackModel)) {
    return [{
      model: normalizeText(fallbackModel),
      reasoningEffort: normalizeReasoningEffort(fallbackReasoningEffort),
      strength: 1,
      costTier: 1,
      notes: null
    }];
  }
  return models;
}

function normalizePolicy(rawPolicy = {}, fallbackOutputPath = DEFAULT_OUTPUT_PATH) {
  const providers = ensureArray(rawPolicy?.providers).map((provider) => {
    const defaultModel = normalizeText(provider?.defaultModel);
    const defaultReasoningEffort = normalizeReasoningEffort(provider?.defaultReasoningEffort);
    const candidateModels = normalizeCandidateModels(provider?.candidateModels, defaultModel, defaultReasoningEffort);
    return {
      providerId: normalizeText(provider?.providerId),
      providerKind: normalizeText(provider?.providerKind) || null,
      agentRole: normalizeText(provider?.agentRole).toLowerCase() || 'live',
      defaultModel: defaultModel || candidateModels[0]?.model || null,
      defaultReasoningEffort: defaultReasoningEffort ?? candidateModels[0]?.reasoningEffort ?? null,
      forcedModel: normalizeText(provider?.forcedModel) || null,
      forcedReasoningEffort: normalizeReasoningEffort(provider?.forcedReasoningEffort),
      candidateModels,
      costOnlySwitchAllowed: provider?.costOnlySwitchAllowed === true
    };
  }).filter((provider) => provider.providerId && provider.defaultModel && provider.candidateModels.length > 0);

  return {
    schema: POLICY_SCHEMA,
    mode: normalizeText(rawPolicy?.mode).toLowerCase() === 'enforce' ? 'enforce' : 'recommend-only',
    outputPath: normalizeText(rawPolicy?.outputPath) || fallbackOutputPath,
    previousReportPath: normalizeText(rawPolicy?.previousReportPath) || (normalizeText(rawPolicy?.outputPath) || fallbackOutputPath),
    inputs: {
      costRollupPath: normalizeText(rawPolicy?.inputs?.costRollupPath) || DEFAULT_COST_ROLLUP_PATH,
      throughputScorecardPath: normalizeText(rawPolicy?.inputs?.throughputScorecardPath) || DEFAULT_THROUGHPUT_SCORECARD_PATH,
      deliveryMemoryPath: normalizeText(rawPolicy?.inputs?.deliveryMemoryPath) || DEFAULT_DELIVERY_MEMORY_PATH
    },
    evidenceWindow: {
      minLiveTurnCount: toNonNegativeInteger(rawPolicy?.evidenceWindow?.minLiveTurnCount) ?? 1,
      minTerminalPullRequests: toNonNegativeInteger(rawPolicy?.evidenceWindow?.minTerminalPullRequests) ?? 1,
      confidenceThreshold: CONFIDENCE_LEVELS.includes(normalizeText(rawPolicy?.evidenceWindow?.confidenceThreshold).toLowerCase())
        ? normalizeText(rawPolicy?.evidenceWindow?.confidenceThreshold).toLowerCase()
        : 'medium'
    },
    stability: {
      cooldownReports: toNonNegativeInteger(rawPolicy?.stability?.cooldownReports) ?? 1,
      hysteresisScoreDelta: toNonNegativeNumber(rawPolicy?.stability?.hysteresisScoreDelta) ?? 0.5,
      holdCurrentOnCostOnly: rawPolicy?.stability?.holdCurrentOnCostOnly !== false,
      performancePressureOverridesCooldown: rawPolicy?.stability?.performancePressureOverridesCooldown !== false,
      throughputWarnEscalates: rawPolicy?.stability?.throughputWarnEscalates !== false,
      meanTerminalDurationWarningMinutes: toNonNegativeNumber(rawPolicy?.stability?.meanTerminalDurationWarningMinutes) ?? 180,
      minMergeSuccessRatio: toRatio(rawPolicy?.stability?.minMergeSuccessRatio) ?? 0.6,
      maxHostedWaitEscapeCount: toNonNegativeInteger(rawPolicy?.stability?.maxHostedWaitEscapeCount) ?? 0
    },
    providers
  };
}

export function loadLiveAgentModelSelectionPolicy(repoRoot = process.cwd(), policyPath = DEFAULT_POLICY_PATH) {
  const resolvedPolicyPath = path.resolve(repoRoot, policyPath);
  const input = readJsonInput(resolvedPolicyPath);
  const blockers = [];
  if (!input.exists) {
    blockers.push(createBlocker('policy-missing', 'Live-agent model selection policy is missing.', resolvedPolicyPath));
  } else if (input.error) {
    blockers.push(createBlocker('policy-unreadable', `Live-agent model selection policy could not be parsed: ${input.error}`, resolvedPolicyPath));
  } else if (normalizeText(input.payload?.schema) !== POLICY_SCHEMA) {
    blockers.push(createBlocker('policy-schema-mismatch', `Policy schema must remain ${POLICY_SCHEMA}.`, resolvedPolicyPath));
  }
  const policy = normalizePolicy(input.payload ?? {}, DEFAULT_OUTPUT_PATH);
  return { path: resolvedPolicyPath, input, policy, blockers };
}

export function loadLiveAgentModelSelectionReport(repoRoot = process.cwd(), reportPath = DEFAULT_OUTPUT_PATH) {
  const resolvedReportPath = path.resolve(repoRoot, reportPath);
  const input = readJsonInput(resolvedReportPath);
  if (!input.exists || input.error || !input.payload || normalizeText(input.payload?.schema) !== REPORT_SCHEMA) {
    return { path: resolvedReportPath, input, report: null };
  }
  return { path: resolvedReportPath, input, report: input.payload };
}

function getTurnEvidence(costRollupPayload, providerPolicy) {
  const turns = ensureArray(costRollupPayload?.turns).filter((turn) => {
    if (normalizeText(turn?.providerId) !== providerPolicy.providerId) return false;
    if (providerPolicy.agentRole !== 'any' && normalizeText(turn?.agentRole).toLowerCase() !== providerPolicy.agentRole) return false;
    return true;
  });
  const observedModels = uniqueStrings(turns.map((turn) => turn?.effectiveModel));
  const observedReasoningEfforts = uniqueStrings(turns.map((turn) => turn?.effectiveReasoningEffort));
  const turnCount = turns.length;
  const totalUsd = roundNumber(turns.reduce((sum, turn) => sum + (toNonNegativeNumber(turn?.amountUsd) ?? 0), 0)) ?? 0;
  const averageUsdPerTurn = turnCount > 0 ? roundNumber(totalUsd / turnCount) : null;
  return { turns, observedModels, observedReasoningEfforts, turnCount, totalUsd, averageUsdPerTurn };
}

function buildPressureSummary({ throughputPayload, deliveryMemoryPayload, policy }) {
  const throughputReasons = uniqueStrings(throughputPayload?.summary?.reasons);
  const throughputStatus = normalizeText(throughputPayload?.summary?.status) || 'not-observed';
  const queueReadyPrInventory = toNonNegativeInteger(throughputPayload?.summary?.metrics?.readyPrInventory) ?? 0;
  const queueOccupancyRatio = toRatio(throughputPayload?.summary?.metrics?.mergeQueueOccupancyRatio);
  const totalTerminalPullRequestCount = toNonNegativeInteger(deliveryMemoryPayload?.summary?.totalTerminalPullRequestCount) ?? 0;
  const mergedPullRequestCount = toNonNegativeInteger(deliveryMemoryPayload?.summary?.mergedPullRequestCount) ?? 0;
  const hostedWaitEscapeCount = toNonNegativeInteger(deliveryMemoryPayload?.summary?.hostedWaitEscapeCount) ?? 0;
  const meanTerminalDurationMinutes = toNonNegativeNumber(deliveryMemoryPayload?.summary?.meanTerminalDurationMinutes);
  const mergeSuccessRatio = totalTerminalPullRequestCount > 0 ? roundNumber(mergedPullRequestCount / totalTerminalPullRequestCount) : null;

  const throughputPressure = policy.stability.throughputWarnEscalates && throughputStatus === 'warn';
  const outcomePressure = mergeSuccessRatio != null && mergeSuccessRatio < policy.stability.minMergeSuccessRatio;
  const durationPressure = meanTerminalDurationMinutes != null && meanTerminalDurationMinutes > policy.stability.meanTerminalDurationWarningMinutes;
  const hostedWaitPressure = hostedWaitEscapeCount > policy.stability.maxHostedWaitEscapeCount;
  const queuePressure = throughputReasons.some((reason) =>
    ['actionable-work-with-idle-worker-pool', 'actionable-work-below-worker-slot-target', 'merge-queue-ready-inventory-below-floor', 'merge-queue-occupancy-below-floor'].includes(reason)
  );

  const activePressureReasons = [
    throughputPressure ? 'throughput-pressure' : null,
    queuePressure ? 'queue-pressure' : null,
    outcomePressure ? 'outcome-quality-pressure' : null,
    durationPressure ? 'terminal-duration-pressure' : null,
    hostedWaitPressure ? 'hosted-wait-pressure' : null
  ].filter(Boolean);

  return {
    throughputStatus,
    throughputReasons,
    queueReadyPrInventory,
    queueOccupancyRatio,
    totalTerminalPullRequestCount,
    mergedPullRequestCount,
    mergeSuccessRatio,
    hostedWaitEscapeCount,
    meanTerminalDurationMinutes,
    performancePressure: activePressureReasons.length > 0,
    performancePressureReasons: activePressureReasons
  };
}

function determineConfidence({ turnCount, pressureSummary, policy }) {
  let confidence = 'low';
  if (
    turnCount >= policy.evidenceWindow.minLiveTurnCount &&
    pressureSummary.totalTerminalPullRequestCount >= policy.evidenceWindow.minTerminalPullRequests
  ) {
    confidence = 'medium';
  }
  if (
    turnCount >= policy.evidenceWindow.minLiveTurnCount * 2 &&
    pressureSummary.totalTerminalPullRequestCount >= policy.evidenceWindow.minTerminalPullRequests * 2
  ) {
    confidence = 'high';
  }
  return confidence;
}

function buildCandidateScore(candidate, { pressureSummary, currentModel, currentReasoningEffort }) {
  const performanceSignal = pressureSummary.performancePressureReasons.length;
  const performanceWeight = performanceSignal > 0 ? 0.75 + (performanceSignal * 0.25) : 0.25;
  const currentModelBonus =
    candidate.model === currentModel &&
    normalizeReasoningEffort(candidate.reasoningEffort) === normalizeReasoningEffort(currentReasoningEffort)
      ? 0.25
      : 0;
  const score = (candidate.strength * performanceWeight) - (candidate.costTier * 0.5) + currentModelBonus;
  return roundNumber(score) ?? 0;
}

function getCandidateByIdentity(candidateModels, model, reasoningEffort = null) {
  const normalizedModel = normalizeText(model);
  const normalizedReasoningEffort = normalizeReasoningEffort(reasoningEffort);
  return candidateModels.find((candidate) =>
    candidate.model === normalizedModel &&
    normalizeReasoningEffort(candidate.reasoningEffort) === normalizedReasoningEffort
  ) ?? null;
}

function getCandidateByModel(candidateModels, model) {
  return candidateModels.find((candidate) => candidate.model === model) ?? null;
}

function selectStrongestCandidate(candidateModels) {
  return [...candidateModels].sort((left, right) => {
    if (left.strength !== right.strength) return right.strength - left.strength;
    if (left.costTier !== right.costTier) return left.costTier - right.costTier;
    if (compareReasoningEffort(left.reasoningEffort, right.reasoningEffort) !== 0) {
      return compareReasoningEffort(right.reasoningEffort, left.reasoningEffort);
    }
    return left.model.localeCompare(right.model);
  })[0] ?? null;
}

function selectCheapestCandidate(candidateModels) {
  return [...candidateModels].sort((left, right) => {
    if (left.costTier !== right.costTier) return left.costTier - right.costTier;
    if (left.strength !== right.strength) return right.strength - left.strength;
    if (compareReasoningEffort(left.reasoningEffort, right.reasoningEffort) !== 0) {
      return compareReasoningEffort(left.reasoningEffort, right.reasoningEffort);
    }
    return left.model.localeCompare(right.model);
  })[0] ?? null;
}

function indexPreviousProvider(previousReport, providerId) {
  return ensureArray(previousReport?.providers).find((provider) => normalizeText(provider?.providerId) === providerId) ?? null;
}

function evaluateProviderRecommendation({ providerPolicy, costRollupPayload, throughputPayload, deliveryMemoryPayload, policy, previousReport }) {
  const previousProvider = indexPreviousProvider(previousReport, providerPolicy.providerId);
  const costTurnSummary = getTurnEvidence(costRollupPayload, providerPolicy);
  const currentModel =
    normalizeText(previousProvider?.selectedModel) ||
    normalizeText(costTurnSummary.observedModels[0]) ||
    providerPolicy.defaultModel;
  const currentReasoningEffort =
    normalizeReasoningEffort(previousProvider?.selectedReasoningEffort) ||
    normalizeReasoningEffort(costTurnSummary.observedReasoningEfforts[0]) ||
    normalizeReasoningEffort(providerPolicy.defaultReasoningEffort);
  const pressureSummary = buildPressureSummary({ throughputPayload, deliveryMemoryPayload, policy });
  const confidence = determineConfidence({ turnCount: costTurnSummary.turnCount, pressureSummary, policy });
  const strongestCandidate = selectStrongestCandidate(providerPolicy.candidateModels);
  const cheapestCandidate = selectCheapestCandidate(providerPolicy.candidateModels);
  const previousCooldownRemaining = toNonNegativeInteger(previousProvider?.stability?.cooldownRemainingReports) ?? 0;
  const reasonCodes = [];
  let selectedModel = currentModel;
  let selectedReasoningEffort = currentReasoningEffort;
  let action = 'stay';
  let recommendationSource = 'current-model-hold';

  if (providerPolicy.forcedModel) {
    const forcedCandidate =
      getCandidateByIdentity(providerPolicy.candidateModels, providerPolicy.forcedModel, providerPolicy.forcedReasoningEffort) ??
      getCandidateByModel(providerPolicy.candidateModels, providerPolicy.forcedModel);
    selectedModel = forcedCandidate?.model ?? providerPolicy.forcedModel;
    selectedReasoningEffort =
      normalizeReasoningEffort(forcedCandidate?.reasoningEffort) ??
      normalizeReasoningEffort(providerPolicy.forcedReasoningEffort) ??
      currentReasoningEffort;
    action = selectedModel === currentModel && selectedReasoningEffort === currentReasoningEffort ? 'stay' : 'override';
    recommendationSource = 'policy-override';
    reasonCodes.push('policy-override');
  } else if (
    !getCandidateByIdentity(providerPolicy.candidateModels, currentModel, currentReasoningEffort) &&
    !getCandidateByModel(providerPolicy.candidateModels, currentModel)
  ) {
    selectedModel = providerPolicy.defaultModel;
    selectedReasoningEffort = normalizeReasoningEffort(providerPolicy.defaultReasoningEffort);
    action = selectedModel === currentModel && selectedReasoningEffort === currentReasoningEffort ? 'stay' : 'switch';
    recommendationSource = 'policy-default';
    reasonCodes.push('current-model-not-in-policy');
  } else if (pressureSummary.performancePressure) {
    const desiredCandidate = strongestCandidate ?? getCandidateByIdentity(providerPolicy.candidateModels, currentModel, currentReasoningEffort);
    const desiredModel = desiredCandidate?.model ?? currentModel;
    const desiredReasoningEffort =
      normalizeReasoningEffort(desiredCandidate?.reasoningEffort) ?? currentReasoningEffort;
    if (desiredModel !== currentModel || desiredReasoningEffort !== currentReasoningEffort) {
      if (
        previousCooldownRemaining > 0 &&
        policy.stability.performancePressureOverridesCooldown !== true
      ) {
        selectedModel = currentModel;
        selectedReasoningEffort = currentReasoningEffort;
        action = 'hold';
        recommendationSource = 'cooldown-hold';
        reasonCodes.push('cooldown-active');
      } else if (compareConfidence(confidence, policy.evidenceWindow.confidenceThreshold) < 0) {
        selectedModel = currentModel;
        selectedReasoningEffort = currentReasoningEffort;
        action = 'hold';
        recommendationSource = 'insufficient-evidence';
        reasonCodes.push('insufficient-confidence');
      } else {
        selectedModel = desiredModel;
        selectedReasoningEffort = desiredReasoningEffort;
        action = 'switch';
        recommendationSource = 'telemetry-escalation';
        reasonCodes.push(...pressureSummary.performancePressureReasons);
      }
    } else {
      reasonCodes.push('already-strongest-model');
    }
  } else {
    const cheaperIdentityAvailable =
      cheapestCandidate &&
      (cheapestCandidate.model !== currentModel ||
        normalizeReasoningEffort(cheapestCandidate.reasoningEffort) !== currentReasoningEffort);
    if (cheaperIdentityAvailable && policy.stability.holdCurrentOnCostOnly && providerPolicy.costOnlySwitchAllowed !== true) {
      reasonCodes.push('cost-only-not-enough');
    } else {
      reasonCodes.push('stable-current-model');
    }
  }

  if (reasonCodes.length === 0) {
    reasonCodes.push('stable-current-model');
  }

  const providerBlockers = [];
  if (costTurnSummary.turnCount < policy.evidenceWindow.minLiveTurnCount) {
    providerBlockers.push(createBlocker('insufficient-live-turns', 'Not enough live turns are available to meet the evidence window.', null));
  }
  if (pressureSummary.totalTerminalPullRequestCount < policy.evidenceWindow.minTerminalPullRequests) {
    providerBlockers.push(createBlocker('insufficient-terminal-history', 'Not enough terminal pull requests are available to meet the evidence window.', null));
  }

  const cooldownRemainingReports =
    selectedModel !== currentModel || selectedReasoningEffort !== currentReasoningEffort
      ? policy.stability.cooldownReports
      : Math.max(previousCooldownRemaining - 1, 0);

  const candidateScores = providerPolicy.candidateModels.map((candidate) => ({
    model: candidate.model,
    reasoningEffort: normalizeReasoningEffort(candidate.reasoningEffort),
    strength: candidate.strength,
    costTier: candidate.costTier,
    notes: candidate.notes,
    score: buildCandidateScore(candidate, { pressureSummary, currentModel, currentReasoningEffort })
  }));

  const currentScore = candidateScores.find((candidate) =>
    candidate.model === currentModel &&
    normalizeReasoningEffort(candidate.reasoningEffort) === currentReasoningEffort
  )?.score ?? null;
  const selectedScore = candidateScores.find((candidate) =>
    candidate.model === selectedModel &&
    normalizeReasoningEffort(candidate.reasoningEffort) === selectedReasoningEffort
  )?.score ?? null;
  if (
    (selectedModel !== currentModel || selectedReasoningEffort !== currentReasoningEffort) &&
    recommendationSource === 'telemetry-escalation' &&
    currentScore != null &&
    selectedScore != null &&
    Math.abs(selectedScore - currentScore) <= policy.stability.hysteresisScoreDelta
  ) {
    selectedModel = currentModel;
    selectedReasoningEffort = currentReasoningEffort;
    action = 'hold';
    recommendationSource = 'cooldown-hold';
    reasonCodes.push('hysteresis-hold');
  }

  return {
    providerId: providerPolicy.providerId,
    providerKind: providerPolicy.providerKind,
    agentRole: providerPolicy.agentRole,
    currentModel,
    currentReasoningEffort,
    selectedModel,
    selectedReasoningEffort,
    action,
    recommendationSource,
    mode: policy.mode,
    confidence,
    reasonCodes: uniqueStrings(reasonCodes),
    evidence: {
      turnCount: costTurnSummary.turnCount,
      observedModels: costTurnSummary.observedModels,
      observedReasoningEfforts: costTurnSummary.observedReasoningEfforts,
      totalUsd: costTurnSummary.totalUsd,
      averageUsdPerTurn: costTurnSummary.averageUsdPerTurn,
      throughputStatus: pressureSummary.throughputStatus,
      throughputReasons: pressureSummary.throughputReasons,
      queueReadyPrInventory: pressureSummary.queueReadyPrInventory,
      queueOccupancyRatio: pressureSummary.queueOccupancyRatio,
      totalTerminalPullRequestCount: pressureSummary.totalTerminalPullRequestCount,
      mergedPullRequestCount: pressureSummary.mergedPullRequestCount,
      mergeSuccessRatio: pressureSummary.mergeSuccessRatio,
      hostedWaitEscapeCount: pressureSummary.hostedWaitEscapeCount,
      meanTerminalDurationMinutes: pressureSummary.meanTerminalDurationMinutes,
      performancePressure: pressureSummary.performancePressure,
      performancePressureReasons: pressureSummary.performancePressureReasons
    },
    candidates: candidateScores,
    blockers: providerBlockers,
    stability: {
      cooldownRemainingReports,
      previousSelectedModel: normalizeText(previousProvider?.selectedModel) || null,
      previousSelectedReasoningEffort: normalizeReasoningEffort(previousProvider?.selectedReasoningEffort),
      previousAction: normalizeText(previousProvider?.action) || null,
      previousGeneratedAt: normalizeText(previousReport?.generatedAt) || null
    }
  };
}

export function evaluateLiveAgentModelSelection({ policy, costRollupInput, throughputInput, deliveryMemoryInput, previousReport = null, repository = null, now = new Date() }) {
  const blockers = [];
  for (const [kind, input] of [
    ['cost-rollup', costRollupInput],
    ['throughput', throughputInput],
    ['delivery-memory', deliveryMemoryInput]
  ]) {
    if (!input?.exists) {
      blockers.push(createBlocker(`${kind}-missing`, `${kind} input is missing.`, input?.path ?? null));
      continue;
    }
    if (input?.error) {
      blockers.push(createBlocker(`${kind}-unreadable`, `${kind} input could not be parsed: ${input.error}`, input.path));
    }
  }

  const providers = policy.providers.map((providerPolicy) =>
    evaluateProviderRecommendation({
      providerPolicy,
      costRollupPayload: costRollupInput?.payload,
      throughputPayload: throughputInput?.payload,
      deliveryMemoryPayload: deliveryMemoryInput?.payload,
      policy,
      previousReport
    })
  );
  const providerBlockers = providers.flatMap((provider) => ensureArray(provider.blockers));
  const allBlockers = [...blockers, ...providerBlockers];

  const switchCount = providers.filter((provider) => provider.action === 'switch').length;
  const overrideCount = providers.filter((provider) => provider.action === 'override').length;
  const holdCount = providers.filter((provider) => provider.action === 'hold').length;
  const insufficientEvidenceCount = providers.filter((provider) => provider.reasonCodes.includes('insufficient-confidence')).length;
  const status = allBlockers.length > 0 ? 'warn' : 'pass';

  return {
    schema: REPORT_SCHEMA,
    generatedAt: toIso(now),
    repository: normalizeText(repository) || null,
    mode: policy.mode,
    policyPath: normalizeText(policy.__policyPath) || safeRelative(path.resolve(DEFAULT_POLICY_PATH)),
    inputs: {
      costRollupPath: safeRelative(costRollupInput.path),
      throughputScorecardPath: safeRelative(throughputInput.path),
      deliveryMemoryPath: safeRelative(deliveryMemoryInput.path),
      previousReportPath: previousReport ? safeRelative(path.resolve(policy.previousReportPath)) : null
    },
    providers,
    summary: {
      status,
      blockerCount: allBlockers.length,
      blockers: allBlockers,
      recommendationCount: providers.length,
      switchCount,
      overrideCount,
      holdCount,
      insufficientEvidenceCount,
      recommendationMode: policy.mode
    }
  };
}

export function selectLiveAgentProviderRecommendation(report, providerId = '') {
  return ensureArray(report?.providers).find((provider) => normalizeText(provider?.providerId) === normalizeText(providerId)) ?? null;
}

export function buildLiveAgentModelSelectionProjection({ policy, report, selectedProviderId = '' } = {}) {
  const currentProvider = selectLiveAgentProviderRecommendation(report, selectedProviderId);
  return {
    mode: policy?.mode ?? 'recommend-only',
    policyPath: normalizeText(policy?.__policyPath) || DEFAULT_POLICY_PATH,
    reportPath: normalizeText(policy?.outputPath) || DEFAULT_OUTPUT_PATH,
    previousReportPath: normalizeText(policy?.previousReportPath) || normalizeText(policy?.outputPath) || DEFAULT_OUTPUT_PATH,
    recommendationStatus: normalizeText(report?.summary?.status) || 'not-observed',
    generatedAt: normalizeText(report?.generatedAt) || null,
    blockerCount: toNonNegativeInteger(report?.summary?.blockerCount) ?? 0,
    selectedProviderId: normalizeText(selectedProviderId) || null,
        currentProvider: currentProvider
      ? {
          providerId: currentProvider.providerId,
          providerKind: currentProvider.providerKind,
          agentRole: currentProvider.agentRole,
          currentModel: currentProvider.currentModel,
          currentReasoningEffort: currentProvider.currentReasoningEffort ?? null,
          selectedModel: currentProvider.selectedModel,
          selectedReasoningEffort: currentProvider.selectedReasoningEffort ?? null,
          action: currentProvider.action,
          confidence: currentProvider.confidence,
          reasonCodes: uniqueStrings(currentProvider.reasonCodes)
        }
      : null,
    providers: ensureArray(report?.providers).map((provider) => ({
      providerId: provider.providerId,
      currentModel: provider.currentModel,
      currentReasoningEffort: provider.currentReasoningEffort ?? null,
      selectedModel: provider.selectedModel,
      selectedReasoningEffort: provider.selectedReasoningEffort ?? null,
      action: provider.action,
      confidence: provider.confidence,
      reasonCodes: uniqueStrings(provider.reasonCodes)
    }))
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    policyPath: DEFAULT_POLICY_PATH,
    costRollupPath: DEFAULT_COST_ROLLUP_PATH,
    throughputScorecardPath: DEFAULT_THROUGHPUT_SCORECARD_PATH,
    deliveryMemoryPath: DEFAULT_DELIVERY_MEMORY_PATH,
    previousReportPath: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    failOnBlockers: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--fail-on-blockers') {
      options.failOnBlockers = true;
      continue;
    }
    if (token === '--no-fail-on-blockers') {
      options.failOnBlockers = false;
      continue;
    }
    if (['--policy', '--cost-rollup', '--throughput', '--delivery-memory', '--previous-report', '--output', '--repo'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--policy') options.policyPath = next;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--throughput') options.throughputScorecardPath = next;
      if (token === '--delivery-memory') options.deliveryMemoryPath = next;
      if (token === '--previous-report') options.previousReportPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  for (const line of HELP) {
    console.log(line);
  }
}

export function runLiveAgentModelSelection(options = {}) {
  const repository = resolveRepoSlug(options.repo);
  const policyLoad = loadLiveAgentModelSelectionPolicy(process.cwd(), options.policyPath || DEFAULT_POLICY_PATH);
  const policyRoot = inferPolicyRoot(policyLoad.path);
  const policy = {
    ...policyLoad.policy,
    __policyPath: path.relative(policyRoot, policyLoad.path).replace(/\\/g, '/'),
    outputPath: normalizeText(options.outputPath) || policyLoad.policy.outputPath,
    previousReportPath:
      normalizeText(options.previousReportPath) || policyLoad.policy.previousReportPath || normalizeText(options.outputPath) || policyLoad.policy.outputPath
  };
  const costRollupInput = readJsonInput(resolvePathFromRoot(policyRoot, options.costRollupPath || policy.inputs.costRollupPath));
  const throughputInput = readJsonInput(resolvePathFromRoot(policyRoot, options.throughputScorecardPath || policy.inputs.throughputScorecardPath));
  const deliveryMemoryInput = readJsonInput(resolvePathFromRoot(policyRoot, options.deliveryMemoryPath || policy.inputs.deliveryMemoryPath));
  const previousReportInput = readJsonInput(resolvePathFromRoot(policyRoot, policy.previousReportPath));
  const previousReport =
    previousReportInput.exists && !previousReportInput.error && normalizeText(previousReportInput.payload?.schema) === REPORT_SCHEMA
      ? previousReportInput.payload
      : null;
  const report = evaluateLiveAgentModelSelection({
    policy,
    costRollupInput,
    throughputInput,
    deliveryMemoryInput,
    previousReport,
    repository,
    now: new Date()
  });
  if (policyLoad.blockers.length > 0) {
    report.summary.status = 'warn';
    report.summary.blockers = [...policyLoad.blockers, ...ensureArray(report.summary.blockers)];
    report.summary.blockerCount = report.summary.blockers.length;
  }
  const resolvedOutputPath = resolvePathFromRoot(policyRoot, policy.outputPath);
  fs.mkdirSync(path.dirname(resolvedOutputPath), { recursive: true });
  fs.writeFileSync(resolvedOutputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return {
    outputPath: resolvedOutputPath,
    policy,
    report,
    exitCode: options.failOnBlockers === true && report.summary.blockerCount > 0 ? 1 : 0
  };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return 0;
  }
  const result = runLiveAgentModelSelection(options);
  console.log(`[live-agent-model-selection] wrote ${result.outputPath} status=${result.report.summary.status} switches=${result.report.summary.switchCount}`);
  return result.exitCode;
}

const entrypointPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = fileURLToPath(import.meta.url);
if (entrypointPath && path.resolve(entrypointPath) === path.resolve(modulePath)) {
  try {
    process.exitCode = main(process.argv);
  } catch (error) {
    console.error(`[live-agent-model-selection] ${error.message || error}`);
    process.exitCode = 1;
  }
}

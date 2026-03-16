#!/usr/bin/env node

import {
  DEFAULT_COPILOT_CLI_REVIEW_POLICY,
  normalizeCopilotCliReviewPolicy,
  runCopilotCliReview
} from './copilot-cli-review.mjs';
import {
  DEFAULT_CODEX_CLI_REVIEW_POLICY,
  normalizeCodexCliReviewPolicy,
  runCodexCliReview
} from './codex-cli-review.mjs';
import {
  DEFAULT_SIMULATION_REVIEW_POLICY,
  normalizeSimulationReviewPolicy,
  runSimulationReview
} from './simulation-review.mjs';

export const SUPPORTED_LOCAL_REVIEW_PROVIDERS = ['copilot-cli', 'codex-cli', 'simulation', 'ollama'];
export const EXECUTABLE_LOCAL_REVIEW_PROVIDERS = ['copilot-cli', 'codex-cli', 'simulation'];
export const SUPPORTED_LOCAL_REVIEW_PROFILES = ['pre-commit', 'daemon', 'pre-push'];

const EXECUTABLE_PROVIDER_SET = new Set(EXECUTABLE_LOCAL_REVIEW_PROVIDERS);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function normalizeFailureClass(value) {
  const normalized = normalizeText(value).toLowerCase();
  return [
    'transport-timeout',
    'runtime-wrapper-failure',
    'invalid-review-output'
  ].includes(normalized)
    ? normalized
    : '';
}

export function normalizeLocalReviewProviderId(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (!normalized) {
    return '';
  }
  if (!SUPPORTED_LOCAL_REVIEW_PROVIDERS.includes(normalized)) {
    throw new Error(`Unsupported local review provider: ${value}`);
  }
  return normalized;
}

export function normalizeLocalReviewProviderList(value) {
  const rawList = Array.isArray(value)
    ? value
    : typeof value === 'string'
      ? value.split(/[,\r\n]+/)
      : [];
  return Array.from(new Set(rawList.map(normalizeLocalReviewProviderId).filter(Boolean)));
}

export function normalizeLocalReviewProfile(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (!normalized) {
    return 'daemon';
  }
  if (!SUPPORTED_LOCAL_REVIEW_PROFILES.includes(normalized)) {
    throw new Error(`Unsupported local review profile: ${value}`);
  }
  return normalized;
}

export function normalizeLocalReviewProviderPolicies(value = {}) {
  const raw = value && typeof value === 'object' ? value : {};
  return {
    reviewProviders: normalizeLocalReviewProviderList(raw.reviewProviders),
    copilotCli: normalizeCopilotCliReviewPolicy(
      raw.copilotCli && typeof raw.copilotCli === 'object' ? raw.copilotCli : DEFAULT_COPILOT_CLI_REVIEW_POLICY
    ),
    codexCli: normalizeCodexCliReviewPolicy(
      raw.codexCli && typeof raw.codexCli === 'object' ? raw.codexCli : DEFAULT_CODEX_CLI_REVIEW_POLICY
    ),
    simulation: normalizeSimulationReviewPolicy(
      raw.simulation && typeof raw.simulation === 'object' ? raw.simulation : DEFAULT_SIMULATION_REVIEW_POLICY
    ),
    ollama: raw.ollama && typeof raw.ollama === 'object' ? { ...raw.ollama } : { enabled: false }
  };
}

export function buildUnsupportedLocalReviewProviderResult(providerId, repoGitState) {
  return {
    providerId,
    status: 'failed',
    source: 'agent-review-policy',
    reason: `Provider ${providerId} is not implemented yet.`,
    receiptPath: null,
    receipt: {
      schema: 'priority/agent-review-policy@v1',
      generatedAt: toIso(),
      provider: providerId,
      git: repoGitState,
      overall: {
        status: 'failed',
        actionableFindingCount: 0,
        message: `Provider ${providerId} is not implemented yet.`,
        exitCode: 1
      }
    }
  };
}

export function summarizeLocalReviewProviderResult(result) {
  const providerId = normalizeText(result?.providerId);
  const receipt = result && typeof result === 'object' ? result.receipt : null;
  const overall = receipt && typeof receipt === 'object' && receipt.overall && typeof receipt.overall === 'object'
    ? receipt.overall
    : {};
  const normalizedFailureClass =
    normalizeFailureClass(result?.failureClass) ||
    normalizeFailureClass(result?.receipt?.copilot?.transport?.failureClass) ||
    normalizeFailureClass(overall.disposition);
  return {
    providerId,
    status: normalizeText(result?.status) || normalizeText(overall.status) || 'failed',
    disposition: normalizeText(result?.disposition) || normalizeText(overall.disposition) || null,
    reason: normalizeText(result?.reason) || normalizeText(overall.message) || null,
    receiptPath: normalizeText(result?.receiptPath) || null,
    actionableFindingCount: Number.isInteger(overall.actionableFindingCount) ? overall.actionableFindingCount : 0,
    failureClass: normalizedFailureClass || null,
    convergence: result?.receipt?.convergence ?? null,
    scenario: normalizeText(result?.receipt?.scenario) || null,
    executionPlane: normalizeText(result?.executionPlane) || normalizeText(result?.receipt?.executionPlane) || null,
    providerRuntime: normalizeText(result?.providerRuntime) || normalizeText(result?.receipt?.providerRuntime) || providerId || null,
    requestedModel: normalizeText(result?.requestedModel) || normalizeText(result?.receipt?.requestedModel) || null,
    effectiveModel: normalizeText(result?.effectiveModel) || normalizeText(result?.receipt?.effectiveModel) || null,
    inputTokens: Number.isInteger(result?.inputTokens) ? result.inputTokens : Number.isInteger(result?.receipt?.usage?.inputTokens) ? result.receipt.usage.inputTokens : 0,
    cachedInputTokens: Number.isInteger(result?.cachedInputTokens) ? result.cachedInputTokens : Number.isInteger(result?.receipt?.usage?.cachedInputTokens) ? result.receipt.usage.cachedInputTokens : 0,
    outputTokens: Number.isInteger(result?.outputTokens) ? result.outputTokens : Number.isInteger(result?.receipt?.usage?.outputTokens) ? result.receipt.usage.outputTokens : 0,
    receipt
  };
}

export async function executeLocalReviewProvider({
  providerId,
  repoRoot,
  executionProfile = 'daemon',
  repoGitState = {},
  policies = {},
  runCopilotCliReviewFn = runCopilotCliReview,
  runCodexCliReviewFn = runCodexCliReview,
  runSimulationReviewFn = runSimulationReview,
  resolveRepoGitStateFn
}) {
  const normalizedProviderId = normalizeLocalReviewProviderId(providerId);
  const normalizedProfile = normalizeLocalReviewProfile(executionProfile);
  const normalizedPolicies = normalizeLocalReviewProviderPolicies(policies);

  if (!EXECUTABLE_PROVIDER_SET.has(normalizedProviderId)) {
    return buildUnsupportedLocalReviewProviderResult(normalizedProviderId, repoGitState);
  }

  if (normalizedProviderId === 'copilot-cli') {
    const result = await runCopilotCliReviewFn({
      repoRoot,
      profile: normalizedProfile,
      policy: normalizedPolicies.copilotCli
    });
    return {
      ...result,
      providerId: 'copilot-cli'
    };
  }

  if (normalizedProviderId === 'codex-cli') {
    const result = await runCodexCliReviewFn({
      repoRoot,
      profile: normalizedProfile,
      policy: normalizedPolicies.codexCli
    });
    return {
      ...result,
      providerId: 'codex-cli'
    };
  }

  if (normalizedProviderId === 'simulation') {
    const result = await runSimulationReviewFn({
      repoRoot,
      policy: normalizedPolicies.simulation,
      resolveRepoGitStateFn
    });
    return {
      ...result,
      providerId: 'simulation'
    };
  }

  return buildUnsupportedLocalReviewProviderResult(normalizedProviderId, repoGitState);
}

export function describeLocalReviewProvider(providerId) {
  const normalizedProviderId = normalizeLocalReviewProviderId(providerId);
  return {
    providerId: normalizedProviderId,
    executable: EXECUTABLE_PROVIDER_SET.has(normalizedProviderId),
    reserved: !EXECUTABLE_PROVIDER_SET.has(normalizedProviderId),
    supportsProfiles: normalizedProviderId === 'simulation'
      ? ['daemon', 'pre-commit', 'pre-push']
      : [...SUPPORTED_LOCAL_REVIEW_PROFILES]
  };
}

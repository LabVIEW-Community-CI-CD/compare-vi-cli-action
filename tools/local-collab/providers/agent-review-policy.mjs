#!/usr/bin/env node

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  DEFAULT_COPILOT_CLI_REVIEW_POLICY,
  normalizeCopilotCliReviewPolicy,
  resolveRepoGitState
} from './copilot-cli-review.mjs';
import { DEFAULT_SIMULATION_REVIEW_POLICY, normalizeSimulationReviewPolicy, runSimulationReview } from './simulation-review.mjs';
import {
  describeLocalReviewProvider,
  executeLocalReviewProvider,
  normalizeLocalReviewProfile,
  normalizeLocalReviewProviderId,
  normalizeLocalReviewProviderList,
  normalizeLocalReviewProviderPolicies,
  summarizeLocalReviewProviderResult,
  SUPPORTED_LOCAL_REVIEW_PROFILES,
  SUPPORTED_LOCAL_REVIEW_PROVIDERS
} from './local-review-providers.mjs';
import { isEntrypoint } from './shim-utils.mjs';

export const AGENT_REVIEW_POLICY_RECEIPT_SCHEMA = 'priority/agent-review-policy@v1';
export const DELIVERY_AGENT_POLICY_PATH = path.join('tools', 'priority', 'delivery-agent.policy.json');
export const DEFAULT_AGENT_REVIEW_POLICY_RECEIPT_PATH = path.join(
  'tests',
  'results',
  'docker-tools-parity',
  'agent-review-policy',
  'receipt.json'
);
export const SUPPORTED_AGENT_REVIEW_PROVIDERS = SUPPORTED_LOCAL_REVIEW_PROVIDERS;
export const SUPPORTED_AGENT_REVIEW_PROFILES = SUPPORTED_LOCAL_REVIEW_PROFILES;
const PROFILE_RECEIPT_PATHS = {
  'pre-commit': path.join('tests', 'results', '_hooks', 'pre-commit-agent-review-policy.json'),
  daemon: DEFAULT_AGENT_REVIEW_POLICY_RECEIPT_PATH,
  'pre-push': path.join('tests', 'results', '_hooks', 'pre-push-agent-review-policy.json')
};

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function resolveRepoPath(repoRoot, candidatePath) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    throw new Error('Agent review policy receipt path must be a non-empty repo-relative path.');
  }
  if (path.isAbsolute(normalized)) {
    throw new Error(`Agent review policy receipt path must stay under the repository root: ${normalized}`);
  }
  const resolved = path.resolve(repoRoot, normalized);
  const relativeToRepo = path.relative(repoRoot, resolved);
  if (!relativeToRepo || relativeToRepo.startsWith('..') || path.isAbsolute(relativeToRepo)) {
    throw new Error(`Agent review policy receipt path escapes the repository root: ${normalized}`);
  }
  return {
    normalized,
    resolved
  };
}

export function normalizeAgentReviewPolicy(value = {}) {
  const raw = value && typeof value === 'object' ? value : {};
  const normalizedPolicies = normalizeLocalReviewProviderPolicies(raw);
  return {
    receiptPath: normalizeText(raw.receiptPath) || DEFAULT_AGENT_REVIEW_POLICY_RECEIPT_PATH,
    reviewProviders: normalizedPolicies.reviewProviders,
    copilotCli: normalizedPolicies.copilotCli,
    simulation: normalizedPolicies.simulation,
    codexCli: normalizedPolicies.codexCli,
    ollama: normalizedPolicies.ollama
  };
}

export function parseArgs(argv = process.argv) {
  const args = Array.isArray(argv) ? [...argv] : [];
  const options = {
    repoRoot: process.cwd(),
    request: {
      requested: true,
      profile: 'daemon',
      reviewProviders: []
    }
  };

  while (args.length > 0) {
    const token = args.shift();
    if (token === 'node' || normalizeText(token).endsWith('agent-review-policy.mjs')) {
      continue;
    }
    switch (token) {
      case '--repo-root':
        if (args.length === 0) {
          throw new Error('Missing value for --repo-root');
        }
        options.repoRoot = args.shift();
        break;
      case '--receipt-path':
        if (args.length === 0) {
          throw new Error('Missing value for --receipt-path');
        }
        options.request.agentReviewPolicyReceiptPath = args.shift();
        break;
      case '--profile':
        if (args.length === 0) {
          throw new Error('Missing value for --profile');
        }
        options.request.profile = normalizeLocalReviewProfile(args.shift());
        break;
      case '--review-provider':
        if (args.length === 0) {
          throw new Error('Missing value for --review-provider');
        }
        options.request.reviewProviders.push(normalizeLocalReviewProviderId(args.shift()));
        break;
      case '--copilot-cli-review':
        options.request.copilotCliReview = true;
        break;
      case '--simulation-review':
        options.request.simulationReview = true;
        break;
      default:
        throw new Error(`Unknown option: ${token}`);
    }
  }

  options.request.reviewProviders = normalizeLocalReviewProviderList(options.request.reviewProviders);
  if (!normalizeText(options.request.agentReviewPolicyReceiptPath)) {
    options.request.agentReviewPolicyReceiptPath = PROFILE_RECEIPT_PATHS[options.request.profile];
  }
  return options;
}

export async function loadAgentReviewPolicy(repoRoot) {
  try {
    const raw = JSON.parse(await readFile(path.join(repoRoot, DELIVERY_AGENT_POLICY_PATH), 'utf8'));
    const localReviewLoop = raw?.localReviewLoop && typeof raw.localReviewLoop === 'object' ? raw.localReviewLoop : {};
    return normalizeAgentReviewPolicy({
      receiptPath: localReviewLoop.agentReviewPolicyReceiptPath,
      reviewProviders: localReviewLoop.reviewProviders,
      copilotCli:
        localReviewLoop.copilotCliReviewConfig && typeof localReviewLoop.copilotCliReviewConfig === 'object'
          ? {
              ...localReviewLoop.copilotCliReviewConfig,
              enabled: localReviewLoop.copilotCliReview !== false &&
                localReviewLoop.copilotCliReviewConfig.enabled !== false
            }
          : {
              ...DEFAULT_COPILOT_CLI_REVIEW_POLICY,
              enabled: localReviewLoop.copilotCliReview !== false
            },
      simulation:
        localReviewLoop.simulationReviewConfig && typeof localReviewLoop.simulationReviewConfig === 'object'
          ? {
              ...localReviewLoop.simulationReviewConfig,
              enabled: localReviewLoop.simulationReview === true &&
                localReviewLoop.simulationReviewConfig.enabled !== false
            }
          : {
              ...DEFAULT_SIMULATION_REVIEW_POLICY,
              enabled: localReviewLoop.simulationReview === true
            },
      codexCli:
        localReviewLoop.codexCliReviewConfig && typeof localReviewLoop.codexCliReviewConfig === 'object'
          ? localReviewLoop.codexCliReviewConfig
          : { enabled: false },
      ollama:
        localReviewLoop.ollamaReviewConfig && typeof localReviewLoop.ollamaReviewConfig === 'object'
          ? localReviewLoop.ollamaReviewConfig
          : { enabled: false }
    });
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return normalizeAgentReviewPolicy({});
    }
    throw error;
  }
}

function resolveRequestedProviders(request = {}, policy = {}) {
  const normalizedRequestProviders = normalizeLocalReviewProviderList(request.reviewProviders);
  const policyProviders = normalizeLocalReviewProviderList(policy.reviewProviders);
  if (normalizedRequestProviders.length > 0) {
    return {
      providers: normalizedRequestProviders,
      selectionSource: 'explicit-request',
      explicitProviders: normalizedRequestProviders,
      policyProviders,
      impliedProviders: []
    };
  }
  if (policyProviders.length > 0) {
    return {
      providers: [...policyProviders],
      selectionSource: 'policy-default',
      explicitProviders: [],
      policyProviders,
      impliedProviders: []
    };
  }
  const providers = [];
  if (request.copilotCliReview === true) {
    providers.push('copilot-cli');
  }
  if (request.simulationReview === true) {
    providers.push('simulation');
  }
  const impliedProviders = normalizeLocalReviewProviderList(providers);
  return {
    providers: impliedProviders,
    selectionSource: impliedProviders.length > 0 ? 'legacy-boolean-fallback' : 'none',
    explicitProviders: [],
    policyProviders,
    impliedProviders
  };
}

export async function runAgentReviewPolicy({
  repoRoot,
  request = {},
  policy = null,
  runCopilotCliReviewFn,
  runSimulationReviewFn = runSimulationReview,
  resolveRepoGitStateFn = resolveRepoGitState
}) {
  const normalizedPolicy = normalizeAgentReviewPolicy(policy ?? await loadAgentReviewPolicy(repoRoot));
  const executionProfile = normalizeLocalReviewProfile(request.profile);
  const providerSelection = resolveRequestedProviders(request, normalizedPolicy);
  const requestedProviders = providerSelection.providers;
  const receiptPathInfo = resolveRepoPath(
    repoRoot,
    normalizeText(request.agentReviewPolicyReceiptPath) || PROFILE_RECEIPT_PATHS[executionProfile] || normalizedPolicy.receiptPath
  );
  const repoGitState = resolveRepoGitStateFn(repoRoot) ?? {};

  if (request.requested !== true || requestedProviders.length === 0) {
    const receipt = {
      schema: AGENT_REVIEW_POLICY_RECEIPT_SCHEMA,
      generatedAt: toIso(),
      profile: executionProfile,
      git: repoGitState,
      providerSelection,
      requestedProviders,
      executedProviders: [],
      overall: {
        status: 'skipped',
        actionableFindingCount: 0,
        message: 'No local agent review providers were requested.',
        exitCode: 0
      },
      providers: {}
    };
    await mkdir(path.dirname(receiptPathInfo.resolved), { recursive: true });
    await writeFile(receiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
    return {
      status: 'skipped',
      source: 'agent-review-policy',
      reason: receipt.overall.message,
      receiptPath: receiptPathInfo.normalized,
      receipt
    };
  }

  const providerResults = [];
  for (const providerId of requestedProviders) {
    const result = await executeLocalReviewProvider({
      providerId,
      repoRoot,
      executionProfile,
      repoGitState,
      policies: normalizedPolicy,
      runCopilotCliReviewFn,
      runSimulationReviewFn,
      resolveRepoGitStateFn
    });
    providerResults.push(summarizeLocalReviewProviderResult(result));
  }

  const failedProvider = providerResults.find((provider) => provider.status === 'failed') ?? null;
  const passedProviders = providerResults.filter((provider) => provider.status === 'passed');
  const overallStatus = failedProvider ? 'failed' : passedProviders.length > 0 ? 'passed' : 'skipped';
  const overallMessage = failedProvider
    ? failedProvider.reason || `Local agent review failed in provider ${failedProvider.providerId}.`
    : overallStatus === 'passed'
      ? 'Local agent review providers passed.'
      : 'Local agent review providers were skipped.';
  const receipt = {
    schema: AGENT_REVIEW_POLICY_RECEIPT_SCHEMA,
    generatedAt: toIso(),
    profile: executionProfile,
    git: repoGitState,
    providerSelection,
    requestedProviders,
    executedProviders: providerResults.map((provider) => provider.providerId),
    overall: {
      status: overallStatus,
      actionableFindingCount: providerResults.reduce(
        (sum, provider) => sum + (Number.isInteger(provider.actionableFindingCount) ? provider.actionableFindingCount : 0),
        0
      ),
      message: overallMessage,
      exitCode: overallStatus === 'passed' || overallStatus === 'skipped' ? 0 : 1,
      failedProvider: failedProvider?.providerId || null
    },
    providers: Object.fromEntries(
      providerResults.map((provider) => [
        provider.providerId,
        {
          status: provider.status,
          reason: provider.reason,
          receiptPath: provider.receiptPath,
          actionableFindingCount: provider.actionableFindingCount,
          convergence: provider.convergence,
          scenario: provider.scenario
        }
      ])
    ),
    recommendedReviewOrder: providerResults.map((provider) => provider.providerId)
  };
  receipt.providerCatalog = Object.fromEntries(
    requestedProviders.map((providerId) => [providerId, describeLocalReviewProvider(providerId)])
  );

  await mkdir(path.dirname(receiptPathInfo.resolved), { recursive: true });
  await writeFile(receiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');

  return {
    status: overallStatus,
    source: 'agent-review-policy',
    reason: overallMessage,
    receiptPath: receiptPathInfo.normalized,
    receipt
  };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  const result = await runAgentReviewPolicy(options);
  process.stdout.write(`${JSON.stringify(result.receipt, null, 2)}\n`);
  process.exitCode = result.status === 'failed' ? 1 : 0;
}

if (isEntrypoint(import.meta.url)) {
  main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}

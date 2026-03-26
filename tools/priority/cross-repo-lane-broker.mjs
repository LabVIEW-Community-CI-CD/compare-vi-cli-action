#!/usr/bin/env node
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  DEFAULT_MARKETPLACE_SNAPSHOT_PATH,
  collectMarketplaceSnapshot,
  selectMarketplaceRecommendation,
  writeMarketplaceSnapshot
} from './lane-marketplace.mjs';
import {
  DELIVERY_AGENT_POLICY_RELATIVE_PATH,
  buildWorkerPoolPolicySnapshot,
  buildWorkerProviderSelectionRequest,
  loadDeliveryAgentPolicy,
  selectWorkerProviderAssignment
} from './delivery-agent.mjs';

const MODULE_FILE_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = path.resolve(path.dirname(MODULE_FILE_PATH), '../..');

export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'cross-repo-lane-broker-decision.json'
);

const SUPPORTED_GOVERNOR_PIVOT_ACTIONS = new Set(['future-agent-may-pivot', 'reopen-template-monitoring-work']);

function normalizeText(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function toRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replaceAll('\\', '/');
}

function coercePositiveInteger(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    return null;
  }
  return parsed;
}

async function writeJson(outputPath, payload, repoRoot = REPO_ROOT) {
  const resolvedPath = path.resolve(repoRoot, outputPath);
  await mkdir(path.dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function buildAvailableSlots(workerPoolPolicy) {
  const slots = [];
  const targetSlotCount = coercePositiveInteger(workerPoolPolicy?.targetSlotCount) ?? 0;
  let slotIndex = 0;
  for (const provider of Array.isArray(workerPoolPolicy?.providers) ? workerPoolPolicy.providers : []) {
    if (provider?.enabled === false) {
      continue;
    }
    const slotCount = coercePositiveInteger(provider?.slotCount) ?? 1;
    for (let providerSlot = 0; providerSlot < slotCount && slotIndex < targetSlotCount; providerSlot += 1) {
      slotIndex += 1;
      slots.push({
        slotId: `worker-slot-${slotIndex}`,
        providerId: normalizeText(provider?.id) || null
      });
    }
  }
  while (slots.length < targetSlotCount) {
    slots.push({
      slotId: `worker-slot-${slots.length + 1}`,
      providerId: null
    });
  }
  return slots;
}

function resolveSelectedSlotId(providerSelection, availableSlots) {
  const explicitSlotId = normalizeText(providerSelection?.selectedSlotId) || null;
  if (explicitSlotId) {
    return explicitSlotId;
  }
  const selectedProviderId = normalizeText(providerSelection?.selectedProviderId)?.toLowerCase() || null;
  if (!selectedProviderId) {
    return null;
  }
  return (
    normalizeText(
      availableSlots.find((slot) => normalizeText(slot?.providerId)?.toLowerCase() === selectedProviderId)?.slotId
    ) || null
  );
}

function resolveGovernorExternalSelection(governorPortfolioHandoff, currentRepository) {
  const currentRepositoryNormalized = normalizeText(currentRepository);
  const status = normalizeText(governorPortfolioHandoff?.status) || 'missing';
  const currentOwnerRepository = normalizeText(governorPortfolioHandoff?.currentOwnerRepository);
  const nextOwnerRepository = normalizeText(governorPortfolioHandoff?.nextOwnerRepository);
  const nextAction = normalizeText(governorPortfolioHandoff?.nextAction);
  const ownerDecisionSource = normalizeText(governorPortfolioHandoff?.ownerDecisionSource);
  const governorMode = normalizeText(governorPortfolioHandoff?.governorMode);
  const dependencyStatus = normalizeText(governorPortfolioHandoff?.viHistoryDistributorDependencyStatus);
  const dependencyTarget = normalizeText(governorPortfolioHandoff?.viHistoryDistributorDependencyTargetRepository);
  const dependencyBlocker = normalizeText(governorPortfolioHandoff?.viHistoryDistributorDependencyExternalBlocker);

  if (status === 'missing' || status === 'invalid') {
    return {
      status: 'governor-unavailable',
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      governorSuggestedRepository: null,
      dependencyStatus,
      dependencyTarget,
      dependencyBlocker,
      reason: `Governor portfolio handoff is unavailable (${status}).`
    };
  }

  if (dependencyStatus === 'blocked') {
    return {
      status: 'blocked-dependency',
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      governorSuggestedRepository: null,
      dependencyStatus,
      dependencyTarget,
      dependencyBlocker,
      reason:
        `Governor portfolio blocks external repo selection while the vi-history distributor dependency for ` +
        `${dependencyTarget || 'the external target'} remains blocked` +
        (dependencyBlocker ? ` (${dependencyBlocker}).` : '.')
    };
  }

  if (
    status === 'external-owner' &&
    currentOwnerRepository &&
    currentOwnerRepository.toLowerCase() !== normalizeText(currentRepositoryNormalized)?.toLowerCase()
  ) {
    return {
      status: 'external-selection-allowed',
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      governorSuggestedRepository: currentOwnerRepository,
      dependencyStatus,
      dependencyTarget,
      dependencyBlocker,
      reason: `Governor portfolio assigns external ownership to ${currentOwnerRepository}.`
    };
  }

  if (
    status === 'owner-match' &&
    nextOwnerRepository &&
    nextOwnerRepository.toLowerCase() !== normalizeText(currentRepositoryNormalized)?.toLowerCase() &&
    SUPPORTED_GOVERNOR_PIVOT_ACTIONS.has((nextAction || '').toLowerCase())
  ) {
    return {
      status: 'external-selection-allowed',
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      governorSuggestedRepository: nextOwnerRepository,
      dependencyStatus,
      dependencyTarget,
      dependencyBlocker,
      reason: `Governor portfolio allows external repo selection toward ${nextOwnerRepository}.`
    };
  }

  return {
    status: 'same-repository',
    currentOwnerRepository,
    nextOwnerRepository,
    nextAction,
    ownerDecisionSource,
    governorMode,
    governorSuggestedRepository: null,
    dependencyStatus,
    dependencyTarget,
    dependencyBlocker,
    reason: `Governor portfolio keeps ownership in ${currentOwnerRepository || currentRepositoryNormalized || 'the current repository'}.`
  };
}

function findEligibleMarketplaceEntry(snapshot, repository) {
  const normalizedRepository = normalizeText(repository)?.toLowerCase();
  if (!normalizedRepository) {
    return null;
  }
  return (Array.isArray(snapshot?.entries) ? snapshot.entries : []).find((entry) => {
    return entry?.eligible === true && normalizeText(entry?.repository)?.toLowerCase() === normalizedRepository;
  }) ?? null;
}

function projectDeferredCandidates(snapshot, selectedRepository) {
  const normalizedSelectedRepository = normalizeText(selectedRepository)?.toLowerCase() || null;
  return (Array.isArray(snapshot?.entries) ? snapshot.entries : [])
    .filter((entry) => entry?.eligible === true)
    .filter((entry) => normalizeText(entry?.repository)?.toLowerCase() !== normalizedSelectedRepository)
    .map((entry) => ({
      repository: normalizeText(entry?.repository),
      issueNumber: coercePositiveInteger(entry?.standing?.number),
      issueUrl: normalizeText(entry?.standing?.url),
      issueTitle: normalizeText(entry?.standing?.title),
      authorityTier: normalizeText(entry?.authorityTier),
      laneClass: normalizeText(entry?.laneClass),
      promotionRail: normalizeText(entry?.promotionRail),
      rankingOrder: coercePositiveInteger(entry?.ranking?.order),
      deferReason: 'higher-ranked-or-governor-preferred-candidate-selected'
    }));
}

export function buildCrossRepoLaneBrokerDecision({
  repoRoot = REPO_ROOT,
  currentRepository,
  governorPortfolioHandoff = null,
  marketplaceSnapshot,
  marketplaceSnapshotPath = null,
  policy = {},
  policyPath = DELIVERY_AGENT_POLICY_RELATIVE_PATH,
  now = new Date()
} = {}) {
  const currentRepositoryNormalized = normalizeText(currentRepository);
  const governor = resolveGovernorExternalSelection(governorPortfolioHandoff, currentRepositoryNormalized);
  const workerPoolPolicy = buildWorkerPoolPolicySnapshot(policy);
  const availableSlots = buildAvailableSlots(workerPoolPolicy);
  const providerSelection = selectWorkerProviderAssignment({
    policy,
    selection: buildWorkerProviderSelectionRequest({
      laneLifecycle: 'coding',
      selectedActionType: 'cross-repo-broker'
    }),
    availableSlots
  });
  const selectedSlotId = resolveSelectedSlotId(providerSelection, availableSlots);
  const marketplaceRecommendation = selectMarketplaceRecommendation(marketplaceSnapshot, {
    currentRepository: currentRepositoryNormalized,
    requireDifferentRepository: true
  });
  const governorPreferredEntry = findEligibleMarketplaceEntry(
    marketplaceSnapshot,
    governor.governorSuggestedRepository
  );
  const selectedEntry =
    governor.status === 'external-selection-allowed'
      ? governorPreferredEntry ??
        findEligibleMarketplaceEntry(marketplaceSnapshot, marketplaceRecommendation?.repository)
      : null;
  const selectionSource =
    governor.status !== 'external-selection-allowed'
      ? 'none'
      : governorPreferredEntry
        ? 'governor-preferred'
        : marketplaceRecommendation
          ? 'marketplace-top-ranked'
          : 'none';

  let status = governor.status;
  let reason = governor.reason;
  if (governor.status === 'external-selection-allowed') {
    if (!selectedEntry) {
      status = 'no-eligible-repository';
      reason = 'Cross-repo lane marketplace does not expose an eligible external standing lane.';
    } else if (!providerSelection.selectedProviderId) {
      status = 'no-provider';
      reason = 'Worker-provider policy does not expose an eligible provider for cross-repo broker dispatch.';
    } else {
      status = 'ready';
      reason =
        `Cross-repo broker selected ${selectedEntry.repository}` +
        (selectedEntry?.standing?.number ? ` issue #${selectedEntry.standing.number}` : '') +
        ` via provider ${providerSelection.selectedProviderId}.`;
    }
  }

  const selectedRepository = normalizeText(selectedEntry?.repository) || null;
  const selectedIssueNumber = coercePositiveInteger(selectedEntry?.standing?.number);
  const report = {
    schema: 'priority/cross-repo-lane-broker-decision@v1',
    generatedAt: toIso(now),
    repoRoot,
    currentRepository: currentRepositoryNormalized,
    policyPath: normalizeText(policyPath),
    marketplaceSnapshotPath: normalizeText(marketplaceSnapshotPath),
    governor,
    marketplace: {
      summary: marketplaceSnapshot?.summary ?? {
        repositoryCount: 0,
        eligibleLaneCount: 0,
        queueEmptyCount: 0,
        labelMissingCount: 0,
        errorCount: 0,
        topEligibleLane: null
      },
      recommendation: marketplaceRecommendation,
      governorPreferredRepository: governor.governorSuggestedRepository,
      governorPreferredEligible: governorPreferredEntry != null
    },
    workerProviderSelection: {
      selectedProviderId: providerSelection.selectedProviderId,
      selectedProviderKind: providerSelection.selectedProviderKind,
      selectedExecutionPlane: providerSelection.selectedExecutionPlane,
      selectedAssignmentMode: providerSelection.selectedAssignmentMode,
      dispatchSurface: providerSelection.dispatchSurface,
      completionMode: providerSelection.completionMode,
      requiresLocalCheckout: providerSelection.requiresLocalCheckout,
      selectedSlotId,
      eligibleProviderIds: Array.isArray(providerSelection.eligibleProviderIds)
        ? [...providerSelection.eligibleProviderIds]
        : []
    },
    decision: {
      status,
      reason,
      selectionSource,
      selectedRepository,
      selectedIssueNumber,
      selectedIssueUrl: normalizeText(selectedEntry?.standing?.url),
      selectedIssueTitle: normalizeText(selectedEntry?.standing?.title),
      selectedAuthorityTier: normalizeText(selectedEntry?.authorityTier),
      selectedLaneClass: normalizeText(selectedEntry?.laneClass),
      selectedPromotionRail: normalizeText(selectedEntry?.promotionRail),
      selectedRankingOrder: coercePositiveInteger(selectedEntry?.ranking?.order),
      selectedProviderId: providerSelection.selectedProviderId,
      selectedExecutionPlane: providerSelection.selectedExecutionPlane,
      selectedAssignmentMode: providerSelection.selectedAssignmentMode,
      selectedDispatchSurface: providerSelection.dispatchSurface,
      selectedSlotId,
      requiresLocalCheckout: providerSelection.requiresLocalCheckout === true,
      deferredCandidates: projectDeferredCandidates(marketplaceSnapshot, selectedRepository)
    }
  };

  return report;
}

export async function runCrossRepoLaneBroker({
  repoRoot = REPO_ROOT,
  currentRepository,
  governorPortfolioHandoff = null,
  policy = null,
  policyPath = DELIVERY_AGENT_POLICY_RELATIVE_PATH,
  registryPath = null,
  outputPath = DEFAULT_OUTPUT_PATH,
  marketplaceSnapshot = null,
  marketplaceSnapshotPath = null,
  marketplaceSnapshotOutputPath = DEFAULT_MARKETPLACE_SNAPSHOT_PATH,
  collectMarketplaceSnapshotFn = collectMarketplaceSnapshot,
  writeMarketplaceSnapshotFn = writeMarketplaceSnapshot,
  loadDeliveryAgentPolicyFn = loadDeliveryAgentPolicy,
  now = new Date()
} = {}) {
  const effectivePolicy =
    policy ??
    (await loadDeliveryAgentPolicyFn(repoRoot, {
      policyPath
    }));
  const snapshot =
    marketplaceSnapshot ??
    (await collectMarketplaceSnapshotFn({
      repoRoot,
      registryPath: registryPath || undefined
    }));
  const effectiveMarketplaceSnapshotPath =
    marketplaceSnapshotPath ??
    (marketplaceSnapshot
      ? null
      : await writeMarketplaceSnapshotFn(marketplaceSnapshotOutputPath, snapshot, repoRoot));
  const report = buildCrossRepoLaneBrokerDecision({
    repoRoot,
    currentRepository,
    governorPortfolioHandoff,
    marketplaceSnapshot: snapshot,
    marketplaceSnapshotPath: effectiveMarketplaceSnapshotPath
      ? toRelative(repoRoot, effectiveMarketplaceSnapshotPath)
      : null,
    policy: effectivePolicy,
    policyPath,
    now
  });
  const writtenOutputPath = await writeJson(outputPath, report, repoRoot);
  return {
    report,
    outputPath: writtenOutputPath
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: REPO_ROOT,
    currentRepository: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    policyPath: DELIVERY_AGENT_POLICY_RELATIVE_PATH,
    registryPath: null
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (
      token === '--repo-root' ||
      token === '--current-repository' ||
      token === '--output' ||
      token === '--policy' ||
      token === '--registry'
    ) {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') {
        options.repoRoot = value;
      } else if (token === '--current-repository') {
        options.currentRepository = value;
      } else if (token === '--output') {
        options.outputPath = value;
      } else if (token === '--policy') {
        options.policyPath = value;
      } else if (token === '--registry') {
        options.registryPath = value;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }
  return options;
}

function printHelp() {
  console.log('Usage: node tools/priority/cross-repo-lane-broker.mjs [options]');
  console.log('');
  console.log(`  --repo-root <path>           Repository root (default: ${REPO_ROOT})`);
  console.log('  --current-repository <slug>  Current repository slug');
  console.log(`  --policy <path>              Delivery-agent policy path (default: ${DELIVERY_AGENT_POLICY_RELATIVE_PATH})`);
  console.log('  --registry <path>            Optional marketplace registry override');
  console.log(`  --output <path>              Decision receipt path (default: ${DEFAULT_OUTPUT_PATH})`);
  console.log('  -h, --help                   Show help');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return 0;
  }
  const currentRepository = normalizeText(options.currentRepository) || process.env.GITHUB_REPOSITORY || null;
  const result = await runCrossRepoLaneBroker({
    repoRoot: options.repoRoot,
    currentRepository,
    policyPath: options.policyPath,
    registryPath: options.registryPath,
    outputPath: options.outputPath
  });
  console.log(
    `[cross-repo-lane-broker] wrote ${result.outputPath} status=${result.report.decision.status} selected=${result.report.decision.selectedRepository ?? 'none'}`
  );
  return 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === MODULE_FILE_PATH) {
  main(process.argv).then((code) => {
    if (code !== 0) {
      process.exitCode = code;
    }
  }).catch((error) => {
    console.error(error?.stack ?? error?.message ?? String(error));
    process.exitCode = 1;
  });
}


import { execFile, spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import {
  WORKER_READY_SCHEMA,
  ACTIONS,
  BLOCKER_CLASSES,
  BLOCKER_SCHEMA,
  DEFAULT_LEASE_SCOPE,
  DEFAULT_RUNTIME_DIR,
  EVENT_SCHEMA,
  LANE_SCHEMA,
  REPORT_SCHEMA,
  STATE_SCHEMA,
  STOP_REQUEST_SCHEMA,
  TASK_PACKET_SCHEMA,
  TURN_SCHEMA,
  WORKER_CHECKOUT_SCHEMA,
  __test,
  createRuntimeAdapter,
  EXECUTION_RECEIPT_SCHEMA,
  parseArgs,
  runCli as runCoreCli,
  runRuntimeSupervisor as runCoreRuntimeSupervisor
} from '../../packages/runtime-harness/index.mjs';
import { acquireWriterLease, defaultOwner, releaseWriterLease } from './agent-writer-lease.mjs';
import { loadBranchClassContract, resolveBranchPlaneTransition } from './lib/branch-classification.mjs';
import { resolveRequiredLaneBranchPrefix } from './lib/runtime-lane-branch-contract.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { handoffStandingPriority } from './standing-priority-handoff.mjs';
import {
  CONCURRENT_LANE_APPLY_RECEIPT_SCHEMA,
  DEFAULT_OUTPUT_PATH as DEFAULT_CONCURRENT_LANE_APPLY_PATH
} from './concurrent-lane-apply.mjs';
import {
  CONCURRENT_LANE_STATUS_RECEIPT_SCHEMA,
  DEFAULT_STATUS_OUTPUT_PATH as DEFAULT_CONCURRENT_LANE_STATUS_PATH
} from './concurrent-lane-status.mjs';
import {
  __test as workerCheckoutTest,
  bootstrapCompareviWorkerCheckout,
  activateCompareviWorkerLane,
  prepareCompareviWorkerCheckout,
  repairRegisteredWorktreeGitPointers,
  resolveCompareviWorkerCheckoutLocation,
  resolveCompareviWorkerCheckoutPath
} from './runtime-worker-checkout.mjs';
import {
  classifyNoStandingPriorityCondition,
  fetchIssue,
  parseUpstreamIssuePointerFromBody,
  resolveStandingPriorityForRepo,
  resolveStandingPriorityLabels,
  selectAutoStandingPriorityCandidateForRepo
} from './sync-standing-priority.mjs';
import {
  buildWorkerProviderSelectionRequest,
  buildLocalReviewLoopRequest,
  buildCanonicalDeliveryDecision,
  selectWorkerProviderAssignment,
  buildWorkerPoolPolicySnapshot,
  DELIVERY_AGENT_POLICY_RELATIVE_PATH,
  fetchIssueExecutionGraph,
  loadDeliveryAgentPolicy,
  persistDeliveryAgentRuntimeState
} from './delivery-agent.mjs';
import {
  DEFAULT_POLICY_PATH as DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH,
  buildLiveAgentModelSelectionProjection,
  loadLiveAgentModelSelectionPolicy,
  loadLiveAgentModelSelectionReport
} from './live-agent-model-selection.mjs';
import {
  DEFAULT_OUTPUT_PATH as DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH,
  runTemplateAgentVerificationReport
} from './template-agent-verification-report.mjs';
import {
  DEFAULT_OUTPUT_PATH as DEFAULT_MONITORING_WORK_INJECTION_PATH,
  runMonitoringWorkInjection
} from './monitoring-work-injection.mjs';

export {
  ACTIONS,
  BLOCKER_CLASSES,
  BLOCKER_SCHEMA,
  DEFAULT_LEASE_SCOPE,
  DEFAULT_RUNTIME_DIR,
  EVENT_SCHEMA,
  LANE_SCHEMA,
  REPORT_SCHEMA,
  STATE_SCHEMA,
  STOP_REQUEST_SCHEMA,
  TASK_PACKET_SCHEMA,
  TURN_SCHEMA,
  WORKER_CHECKOUT_SCHEMA,
  WORKER_READY_SCHEMA,
  EXECUTION_RECEIPT_SCHEMA,
  __test,
  createRuntimeAdapter,
  parseArgs
};

const COMPAREVI_UPSTREAM_REPOSITORY = 'LabVIEW-Community-CI-CD/compare-vi-cli-action';
const PRIORITY_CACHE_FILENAME = '.agent_priority_cache.json';
const PRIORITY_ISSUE_DIR = path.join('tests', 'results', '_agent', 'issue');
const DEFAULT_AUTONOMOUS_GOVERNOR_PORTFOLIO_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'autonomous-governor-portfolio-summary.json'
);
const DEFAULT_MONITORING_ENTRYPOINTS_PATH = path.join('..', 'monitoring-entrypoints.json');
const execFileAsync = promisify(execFile);
const COMPAREVI_PREFERRED_HELPERS = [
  'node tools/npm/run-script.mjs priority:github:metadata:apply',
  'node tools/npm/run-script.mjs priority:project:portfolio:apply',
  'node tools/npm/run-script.mjs priority:pr',
  'node tools/npm/run-script.mjs priority:merge-sync',
  'node tools/npm/run-script.mjs priority:validate'
];
const COMPAREVI_FALLBACK_HELPERS = [
  'gh issue create --body-file <path>',
  'gh pr create --body-file <path>',
  'gh pr merge --match-head-commit <sha>'
];

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function parseJsonObjectOutput(raw, source = 'command output') {
  const trimmed = normalizeText(raw);
  if (!trimmed) {
    return {};
  }
  try {
    return JSON.parse(trimmed);
  } catch (error) {
    const rootStart = trimmed.lastIndexOf('\n{');
    if (rootStart >= 0) {
      try {
        return JSON.parse(trimmed.slice(rootStart + 1));
      } catch {
        // Fall through to the explicit error below.
      }
    }
    const preview = trimmed.length > 240 ? `${trimmed.slice(0, 240)}...` : trimmed;
    throw new Error(`Unable to parse JSON from ${source}: ${error.message} (output=${JSON.stringify(preview)})`);
  }
}

function coercePositiveInteger(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    return null;
  }
  return parsed;
}

function toDisplayPath(repoRoot, candidatePath) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    return null;
  }
  const resolved = path.resolve(normalized);
  const relative = path.relative(repoRoot, resolved);
  if (!relative || (!relative.startsWith('..') && !path.isAbsolute(relative))) {
    return relative.replace(/\\/g, '/');
  }
  return resolved;
}

function resolveLiveAgentModelSelectionEvidence({
  repoRoot,
  deps = {},
  selectedProviderId = ''
}) {
  const policyLoad = loadLiveAgentModelSelectionPolicy(
    repoRoot,
    deps.liveAgentModelSelectionPolicyPath || DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH
  );
  const reportLoad = loadLiveAgentModelSelectionReport(
    repoRoot,
    deps.liveAgentModelSelectionReportPath || policyLoad.policy.outputPath
  );
  return buildLiveAgentModelSelectionProjection({
    policy: {
      ...policyLoad.policy,
      __policyPath: path.relative(repoRoot, policyLoad.path).replace(/\\/g, '/')
    },
    report: reportLoad.report,
    selectedProviderId
  });
}

const CADENCE_CHECK_MARKER_REGEX = /<!--\s*cadence-check:/i;

function isCadenceAlertIssue(title, body) {
  const normalizedTitle = normalizeText(title).toLowerCase();
  const bodyText = typeof body === 'string' ? body : '';
  return normalizedTitle.startsWith('[cadence]') || CADENCE_CHECK_MARKER_REGEX.test(bodyText);
}

function runGhCommand(args, { quiet = false } = {}) {
  const result = spawnSync('gh', args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', quiet ? 'ignore' : 'pipe']
  });
  if (result.status !== 0) {
    throw new Error(`gh ${args.join(' ')} failed (${result.status}): ${(result.stderr || '').trim() || 'unknown error'}`);
  }
  return (result.stdout || '').trim();
}

function parseIssueRows(raw, { source = 'gh issue list' } = {}) {
  const trimmed = normalizeText(raw);
  if (!trimmed) {
    return [];
  }
  try {
    const parsed = JSON.parse(trimmed);
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    const preview = trimmed.length > 240 ? `${trimmed.slice(0, 240)}...` : trimmed;
    throw new Error(
      `Unable to parse issue rows from ${source}: ${error?.message || String(error)} (output=${JSON.stringify(preview)})`
    );
  }
}

async function listOpenIssuesForTargetRepository(targetRepository, deps = {}) {
  if (typeof deps.listRepoOpenIssuesFn === 'function') {
    const result = await deps.listRepoOpenIssuesFn({ repository: targetRepository });
    return Array.isArray(result) ? result : [];
  }
  return parseIssueRows(
    runGhCommand(
      [
        'issue',
        'list',
        '--repo',
        targetRepository,
        '--state',
        'open',
        '--limit',
        '100',
        '--json',
        'number,title,body,labels,createdAt,updatedAt,url'
      ],
      { quiet: true }
    ),
    {
      source: `gh issue list --repo ${targetRepository} --state open --limit 100 --json number,title,body,labels,createdAt,updatedAt,url`
    }
  );
}

async function closeIssueWithComment(repository, issueNumber, comment, deps = {}) {
  if (typeof deps.closeIssueFn === 'function') {
    return deps.closeIssueFn({ repository, issueNumber, comment });
  }
  runGhCommand(['issue', 'close', String(issueNumber), '--repo', repository, '--comment', comment]);
  return { status: 'closed' };
}

function resolveCompareviIssueSlug(title) {
  const normalized = normalizeText(title)
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^A-Za-z0-9]+/g, ' ')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .toLowerCase()
    .trim();
  return normalized.replace(/^-+|-+$/g, '') || 'work';
}

function resolveCompareviIssueBranchName({
  issueNumber,
  title,
  forkRemote,
  repoRoot = process.cwd(),
  branchClassContract = null,
  loadBranchClassContractFn = loadBranchClassContract
}) {
  const slug = resolveCompareviIssueSlug(title);
  const { laneBranchPrefix } = resolveRequiredLaneBranchPrefix({
    plane: normalizeText(forkRemote) || 'upstream',
    repoRoot,
    branchClassContract,
    loadBranchClassContractFn
  });
  return `${laneBranchPrefix}${issueNumber}-${slug}`;
}

function parseIssueNumberFromLaneBranch(branch) {
  const normalized = normalizeText(branch);
  if (!normalized.toLowerCase().startsWith('issue/')) {
    return null;
  }

  const suffix = normalized.slice('issue/'.length);
  const tokens = suffix
    .split('-')
    .map((entry) => entry.trim())
    .filter(Boolean);
  for (const token of tokens) {
    if (!/^\d+$/.test(token)) {
      continue;
    }
    const issueNumber = Number.parseInt(token, 10);
    if (issueNumber > 0) {
      return issueNumber;
    }
  }

  return null;
}

function resolveForkRemoteFromLaneBranch(branch) {
  const normalized = normalizeText(branch).toLowerCase();
  if (!normalized.startsWith('issue/')) {
    return null;
  }
  if (normalized.startsWith('issue/origin-')) {
    return 'origin';
  }
  if (normalized.startsWith('issue/personal-')) {
    return 'personal';
  }
  return 'upstream';
}

async function tryReadGitStdout(execFileFn, args, options = {}) {
  try {
    const result = await execFileFn('git', args, options);
    return normalizeText(result?.stdout);
  } catch {
    return '';
  }
}

async function applyAuthoritativeLaneBranchOverride({ repoRoot, decision, deps = {} }) {
  if (!decision || decision.outcome !== 'selected') {
    return decision;
  }

  const issueNumber = coercePositiveInteger(decision?.stepOptions?.issue);
  if (!issueNumber) {
    return decision;
  }

  const execFileFn = deps.execFileFn ?? execFileAsync;
  const currentBranch = await tryReadGitStdout(execFileFn, ['branch', '--show-current'], { cwd: repoRoot });
  if (!currentBranch || parseIssueNumberFromLaneBranch(currentBranch) !== issueNumber) {
    return decision;
  }

  const forkRemote = resolveForkRemoteFromLaneBranch(currentBranch);
  if (!forkRemote) {
    return decision;
  }

  return {
    ...decision,
    stepOptions: {
      ...(decision.stepOptions ?? {}),
      lane: `${forkRemote}-${issueNumber}`,
      forkRemote,
      branch: currentBranch
    },
    artifacts: {
      ...(decision.artifacts ?? {}),
      authoritativeCurrentBranch: currentBranch,
      authoritativeCurrentBranchSource: 'repo-root-current-branch',
      authoritativeCurrentForkRemote: forkRemote
    }
  };
}

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

async function resolveGovernorPortfolioHandoff({ repoRoot, repository, deps = {} }) {
  const reportPath = path.resolve(
    repoRoot,
    deps.governorPortfolioSummaryPath || DEFAULT_AUTONOMOUS_GOVERNOR_PORTFOLIO_SUMMARY_PATH
  );
  const summaryPath = path.relative(repoRoot, reportPath).replace(/\\/g, '/');

  let payload = null;
  try {
    if (typeof deps.readGovernorPortfolioSummaryFn === 'function') {
      payload = await deps.readGovernorPortfolioSummaryFn({ repoRoot, reportPath, repository });
    } else {
      payload = await readJsonIfPresent(reportPath);
    }
  } catch (error) {
    return {
      summaryPath,
      status: 'invalid',
      currentOwnerRepository: null,
      nextOwnerRepository: null,
      nextAction: null,
      ownerDecisionSource: null,
      governorMode: null,
      viHistoryDistributorDependencyStatus: null,
      viHistoryDistributorDependencyTargetRepository: null,
      viHistoryDistributorDependencyExternalBlocker: null,
      viHistoryDistributorDependencyPublicationState: null,
      reason: `Unable to read governor portfolio summary: ${error?.message || String(error)}`
    };
  }

  if (!payload) {
    return {
      summaryPath,
      status: 'missing',
      currentOwnerRepository: null,
      nextOwnerRepository: null,
      nextAction: null,
      ownerDecisionSource: null,
      governorMode: null,
      viHistoryDistributorDependencyStatus: null,
      viHistoryDistributorDependencyTargetRepository: null,
      viHistoryDistributorDependencyExternalBlocker: null,
      viHistoryDistributorDependencyPublicationState: null,
      reason: 'Governor portfolio summary is unavailable for queue-empty handoff.'
    };
  }

  if (normalizeText(payload?.schema) !== 'priority/autonomous-governor-portfolio-summary-report@v1') {
    return {
      summaryPath,
      status: 'invalid',
      currentOwnerRepository: null,
      nextOwnerRepository: null,
      nextAction: null,
      ownerDecisionSource: null,
      governorMode: null,
      viHistoryDistributorDependencyStatus: null,
      viHistoryDistributorDependencyTargetRepository: null,
      viHistoryDistributorDependencyExternalBlocker: null,
      viHistoryDistributorDependencyPublicationState: null,
      reason: 'Governor portfolio summary does not match the expected schema.'
    };
  }

  const currentOwnerRepository = normalizeText(payload?.summary?.currentOwnerRepository) || null;
  const nextOwnerRepository = normalizeText(payload?.summary?.nextOwnerRepository) || null;
  const nextAction = normalizeText(payload?.summary?.nextAction) || null;
  const ownerDecisionSource = normalizeText(payload?.summary?.ownerDecisionSource) || null;
  const governorMode = normalizeText(payload?.summary?.governorMode) || null;
  const viHistoryDistributorDependencyStatus =
    normalizeText(payload?.summary?.viHistoryDistributorDependencyStatus) || null;
  const viHistoryDistributorDependencyTargetRepository =
    normalizeText(payload?.summary?.viHistoryDistributorDependencyTargetRepository) || null;
  const viHistoryDistributorDependencyExternalBlocker =
    normalizeText(payload?.summary?.viHistoryDistributorDependencyExternalBlocker) || null;
  const viHistoryDistributorDependencyPublicationState =
    normalizeText(payload?.summary?.viHistoryDistributorDependencyPublicationState) || null;

  if (!currentOwnerRepository || !nextOwnerRepository || !nextAction || !ownerDecisionSource || !governorMode) {
    return {
      summaryPath,
      status: 'invalid',
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      viHistoryDistributorDependencyStatus,
      viHistoryDistributorDependencyTargetRepository,
      viHistoryDistributorDependencyExternalBlocker,
      viHistoryDistributorDependencyPublicationState,
      reason: 'Governor portfolio summary is missing required owner handoff fields.'
    };
  }

  let reason = null;
  if (currentOwnerRepository === repository) {
    if (viHistoryDistributorDependencyStatus === 'blocked' && viHistoryDistributorDependencyTargetRepository) {
      reason =
        `Governor portfolio keeps current ownership in ${currentOwnerRepository} while the vi-history distributor ` +
        `dependency for ${viHistoryDistributorDependencyTargetRepository} remains blocked` +
        (viHistoryDistributorDependencyExternalBlocker
          ? ` (${viHistoryDistributorDependencyExternalBlocker}).`
          : '.');
    } else if (viHistoryDistributorDependencyStatus === 'unknown' && viHistoryDistributorDependencyTargetRepository) {
      reason =
        `Governor portfolio keeps current ownership in ${currentOwnerRepository} until the vi-history distributor ` +
        `dependency for ${viHistoryDistributorDependencyTargetRepository} is refreshed.`;
    } else {
      reason = `Governor portfolio keeps current ownership in ${currentOwnerRepository}.`;
    }
  } else {
    reason = `Governor portfolio assigns current ownership to ${currentOwnerRepository}.`;
  }

  return {
    summaryPath,
    status: currentOwnerRepository === repository ? 'owner-match' : 'external-owner',
    currentOwnerRepository,
    nextOwnerRepository,
    nextAction,
    ownerDecisionSource,
    governorMode,
    viHistoryDistributorDependencyStatus,
    viHistoryDistributorDependencyTargetRepository,
    viHistoryDistributorDependencyExternalBlocker,
    viHistoryDistributorDependencyPublicationState,
    reason
  };
}

function resolveMonitoringEntrypointByRepository(payload, repository) {
  const normalizedRepository = normalizeText(repository).toLowerCase();
  if (!normalizedRepository) {
    return null;
  }
  if (normalizedRepository === COMPAREVI_UPSTREAM_REPOSITORY.toLowerCase()) {
    return payload?.compare ?? null;
  }
  if (normalizedRepository === 'labview-community-ci-cd/labviewgithubcitemplate') {
    return payload?.template ?? null;
  }
  return null;
}

async function resolveGovernorPortfolioPivotExecution({
  repoRoot,
  repository,
  governorPortfolioHandoff,
  env = {},
  deps = {}
}) {
  const currentRepository =
    normalizeText(repository) || normalizeText(env.GITHUB_REPOSITORY) || COMPAREVI_UPSTREAM_REPOSITORY;
  const currentOwnerRepository = normalizeText(governorPortfolioHandoff?.currentOwnerRepository) || currentRepository;
  const nextOwnerRepository = normalizeText(governorPortfolioHandoff?.nextOwnerRepository) || currentOwnerRepository;
  const nextAction = normalizeText(governorPortfolioHandoff?.nextAction) || null;
  const ownerDecisionSource = normalizeText(governorPortfolioHandoff?.ownerDecisionSource) || null;
  const governorMode = normalizeText(governorPortfolioHandoff?.governorMode) || null;
  const viHistoryDistributorDependencyStatus =
    normalizeText(governorPortfolioHandoff?.viHistoryDistributorDependencyStatus) || null;
  const viHistoryDistributorDependencyTargetRepository =
    normalizeText(governorPortfolioHandoff?.viHistoryDistributorDependencyTargetRepository) || null;
  const viHistoryDistributorDependencyExternalBlocker =
    normalizeText(governorPortfolioHandoff?.viHistoryDistributorDependencyExternalBlocker) || null;
  const viHistoryDistributorDependencyPublicationState =
    normalizeText(governorPortfolioHandoff?.viHistoryDistributorDependencyPublicationState) || null;

  if (!nextOwnerRepository || nextOwnerRepository.toLowerCase() === currentRepository.toLowerCase()) {
    let reason = `Governor portfolio keeps repo-context ownership in ${currentRepository}.`;
    if (viHistoryDistributorDependencyStatus === 'blocked' && viHistoryDistributorDependencyTargetRepository) {
      reason =
        `Governor portfolio keeps repo-context ownership in ${currentRepository} while the vi-history distributor ` +
        `dependency for ${viHistoryDistributorDependencyTargetRepository} remains blocked` +
        (viHistoryDistributorDependencyExternalBlocker
          ? ` (${viHistoryDistributorDependencyExternalBlocker}).`
          : '.');
    } else if (viHistoryDistributorDependencyStatus === 'unknown' && viHistoryDistributorDependencyTargetRepository) {
      reason =
        `Governor portfolio keeps repo-context ownership in ${currentRepository} until the vi-history distributor ` +
        `dependency for ${viHistoryDistributorDependencyTargetRepository} is refreshed.`;
    }
    return {
      status: 'same-repository',
      registryPath: null,
      currentRepository,
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      viHistoryDistributorDependencyStatus,
      viHistoryDistributorDependencyTargetRepository,
      viHistoryDistributorDependencyExternalBlocker,
      viHistoryDistributorDependencyPublicationState,
      targetEntrypointPath: null,
      targetHeadSha: null,
      targetCheckoutState: null,
      targetReceipts: null,
      targetCurrentState: null,
      reason
    };
  }

  if (!['future-agent-may-pivot', 'reopen-template-monitoring-work'].includes(nextAction)) {
    return {
      status: 'unsupported-action',
      registryPath: null,
      currentRepository,
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      viHistoryDistributorDependencyStatus,
      viHistoryDistributorDependencyTargetRepository,
      viHistoryDistributorDependencyExternalBlocker,
      viHistoryDistributorDependencyPublicationState,
      targetEntrypointPath: null,
      targetHeadSha: null,
      targetCheckoutState: null,
      targetReceipts: null,
      targetCurrentState: null,
      reason: `Governor portfolio requested '${nextAction || 'unknown'}', which is not a supported runtime pivot action.`
    };
  }

  const entrypointsPath = path.resolve(
    repoRoot,
    deps.monitoringEntrypointsPath ||
      env.AGENT_MONITORING_ENTRYPOINTS_PATH ||
      env.COMPAREVI_MONITORING_ENTRYPOINTS_PATH ||
      DEFAULT_MONITORING_ENTRYPOINTS_PATH
  );
  const registryPath = toDisplayPath(repoRoot, entrypointsPath);

  let payload = null;
  try {
    if (typeof deps.readMonitoringEntrypointsFn === 'function') {
      payload = await deps.readMonitoringEntrypointsFn({ repoRoot, entrypointsPath, repository: nextOwnerRepository });
    } else {
      payload = await readJsonIfPresent(entrypointsPath);
    }
  } catch (error) {
    return {
      status: 'invalid',
      registryPath,
      currentRepository,
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      viHistoryDistributorDependencyStatus,
      viHistoryDistributorDependencyTargetRepository,
      viHistoryDistributorDependencyExternalBlocker,
      viHistoryDistributorDependencyPublicationState,
      targetEntrypointPath: null,
      targetHeadSha: null,
      targetCheckoutState: null,
      targetReceipts: null,
      targetCurrentState: null,
      reason: `Unable to read monitoring entrypoints registry: ${error?.message || String(error)}`
    };
  }

  if (!payload) {
    return {
      status: 'missing',
      registryPath,
      currentRepository,
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      viHistoryDistributorDependencyStatus,
      viHistoryDistributorDependencyTargetRepository,
      viHistoryDistributorDependencyExternalBlocker,
      viHistoryDistributorDependencyPublicationState,
      targetEntrypointPath: null,
      targetHeadSha: null,
      targetCheckoutState: null,
      targetReceipts: null,
      targetCurrentState: null,
      reason: 'Monitoring entrypoints registry is unavailable for runtime repo-context pivot.'
    };
  }

  if (normalizeText(payload?.schema) !== 'local/monitoring-entrypoints-v1') {
    return {
      status: 'invalid',
      registryPath,
      currentRepository,
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      viHistoryDistributorDependencyStatus,
      viHistoryDistributorDependencyTargetRepository,
      viHistoryDistributorDependencyExternalBlocker,
      viHistoryDistributorDependencyPublicationState,
      targetEntrypointPath: null,
      targetHeadSha: null,
      targetCheckoutState: null,
      targetReceipts: null,
      targetCurrentState: null,
      reason: 'Monitoring entrypoints registry does not match the expected schema.'
    };
  }

  const entrypoint = resolveMonitoringEntrypointByRepository(payload, nextOwnerRepository);
  if (!entrypoint) {
    return {
      status: 'unsupported-target',
      registryPath,
      currentRepository,
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      governorMode,
      targetEntrypointPath: null,
      targetHeadSha: null,
      targetCheckoutState: null,
      targetReceipts: null,
      targetCurrentState: null,
      reason: `Monitoring entrypoints registry does not expose a supported target for ${nextOwnerRepository}.`
    };
  }

  return {
    status: 'ready',
    registryPath,
    currentRepository,
    currentOwnerRepository,
    nextOwnerRepository,
    nextAction,
    ownerDecisionSource,
    governorMode,
    viHistoryDistributorDependencyStatus,
    viHistoryDistributorDependencyTargetRepository,
    viHistoryDistributorDependencyExternalBlocker,
    viHistoryDistributorDependencyPublicationState,
    targetEntrypointPath: normalizeText(entrypoint.path) || null,
    targetHeadSha: normalizeText(entrypoint.headSha) || null,
    targetCheckoutState: normalizeText(entrypoint.checkoutState) || null,
    targetReceipts: entrypoint.receipts ?? null,
    targetCurrentState: entrypoint.currentState ?? null,
    reason: `Runtime repo-context pivot is ready for ${nextOwnerRepository}.`
  };
}

function resolveCheckoutPath(repoRoot, checkoutPath) {
  const normalized = normalizeText(checkoutPath);
  if (!normalized) {
    return null;
  }
  return path.isAbsolute(normalized) ? normalized : path.resolve(repoRoot, normalized);
}

function projectConcurrentLaneApplyReceipt(receiptPath, receipt) {
  if (!receipt || receipt.schema !== CONCURRENT_LANE_APPLY_RECEIPT_SCHEMA) {
    return null;
  }

  const summary = receipt.summary && typeof receipt.summary === 'object' ? receipt.summary : {};
  const validateDispatch =
    receipt.validateDispatch && typeof receipt.validateDispatch === 'object' ? receipt.validateDispatch : {};

  return {
    receiptPath,
    status: normalizeText(receipt.status) || null,
    selectedBundleId: normalizeText(summary.selectedBundleId) || null,
    validateDispatch: {
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
  };
}

async function resolveConcurrentLaneApplyEvidence({ repoRoot, preparedWorker, workerReady, workerBranch }) {
  const checkoutCandidates = [
    workerBranch?.checkoutPath,
    workerReady?.checkoutPath,
    preparedWorker?.checkoutPath,
    repoRoot
  ];
  const visited = new Set();
  for (const candidate of checkoutCandidates) {
    const checkoutRoot = resolveCheckoutPath(repoRoot, candidate) ?? path.resolve(repoRoot);
    if (!checkoutRoot || visited.has(checkoutRoot)) {
      continue;
    }
    visited.add(checkoutRoot);
    const receiptPath = path.join(checkoutRoot, DEFAULT_CONCURRENT_LANE_APPLY_PATH);
    const receipt = await readJsonIfPresent(receiptPath);
    const projected = projectConcurrentLaneApplyReceipt(receiptPath, receipt);
    if (projected) {
      return projected;
    }
  }

  return null;
}

function projectConcurrentLaneStatusReceipt(receiptPath, receipt) {
  if (!receipt || receipt.schema !== CONCURRENT_LANE_STATUS_RECEIPT_SCHEMA) {
    return null;
  }

  const summary = receipt.summary && typeof receipt.summary === 'object' ? receipt.summary : {};
  const hostedRun = receipt.hostedRun && typeof receipt.hostedRun === 'object' ? receipt.hostedRun : {};
  const pullRequest = receipt.pullRequest && typeof receipt.pullRequest === 'object' ? receipt.pullRequest : {};
  const mergeQueue = pullRequest.mergeQueue && typeof pullRequest.mergeQueue === 'object' ? pullRequest.mergeQueue : {};
  const executionBundle = receipt.executionBundle && typeof receipt.executionBundle === 'object' ? receipt.executionBundle : {};

  return {
    receiptPath,
    status: normalizeText(receipt.status) || null,
    selectedBundleId: normalizeText(summary.selectedBundleId) || normalizeText(receipt.applyReceipt?.selectedBundleId) || null,
    hostedRun: {
      observationStatus: normalizeText(hostedRun.observationStatus) || null,
      runId: coercePositiveInteger(hostedRun.runId),
      url: normalizeText(hostedRun.url) || null,
      reportPath: normalizeText(hostedRun.reportPath) || null
    },
    pullRequest: {
      observationStatus: normalizeText(pullRequest.observationStatus) || null,
      number: coercePositiveInteger(pullRequest.number),
      url: normalizeText(pullRequest.url) || null,
      mergeQueue: {
        status: normalizeText(mergeQueue.status) || null,
        position: coercePositiveInteger(mergeQueue.position),
        estimatedTimeToMerge: coercePositiveInteger(mergeQueue.estimatedTimeToMerge),
        enqueuedAt: normalizeText(mergeQueue.enqueuedAt) || null
      }
    },
    executionBundle: {
      path: normalizeText(executionBundle.path) || null,
      schema: normalizeText(executionBundle.schema) || null,
      status: normalizeText(executionBundle.status) || null,
      cellId: normalizeText(executionBundle.cellId) || null,
      laneId: normalizeText(executionBundle.laneId) || null,
      executionCellLeaseId: normalizeText(executionBundle.executionCellLeaseId) || null,
      dockerLaneLeaseId: normalizeText(executionBundle.dockerLaneLeaseId) || null,
      harnessInstanceId: normalizeText(executionBundle.harnessInstanceId) || null,
      planeBinding: normalizeText(executionBundle.planeBinding) || null,
      premiumSaganMode: executionBundle.premiumSaganMode === true,
      reciprocalLinkReady: executionBundle.reciprocalLinkReady === true,
      effectiveBillableRateUsdPerHour: Number.isFinite(executionBundle.effectiveBillableRateUsdPerHour)
        ? executionBundle.effectiveBillableRateUsdPerHour
        : null,
      isolatedLaneGroupId: normalizeText(executionBundle.isolatedLaneGroupId) || null,
      fingerprintSha256: normalizeText(executionBundle.fingerprintSha256) || null
    },
    summary: {
      laneCount: coercePositiveInteger(summary.laneCount) ?? 0,
      activeLaneCount: coercePositiveInteger(summary.activeLaneCount) ?? 0,
      completedLaneCount: coercePositiveInteger(summary.completedLaneCount) ?? 0,
      failedLaneCount: coercePositiveInteger(summary.failedLaneCount) ?? 0,
      deferredLaneCount: coercePositiveInteger(summary.deferredLaneCount) ?? 0,
      manualLaneCount: coercePositiveInteger(summary.manualLaneCount) ?? 0,
      shadowLaneCount: coercePositiveInteger(summary.shadowLaneCount) ?? 0,
      executionBundleStatus: normalizeText(summary.executionBundleStatus) || null,
      executionBundleReciprocalLinkReady: summary.executionBundleReciprocalLinkReady === true,
      executionBundlePremiumSaganMode: summary.executionBundlePremiumSaganMode === true,
      pullRequestStatus: normalizeText(summary.pullRequestStatus) || null,
      orchestratorDisposition: normalizeText(summary.orchestratorDisposition) || null
    }
  };
}

async function resolveConcurrentLaneStatusEvidence({ repoRoot, preparedWorker, workerReady, workerBranch }) {
  const checkoutCandidates = [
    workerBranch?.checkoutPath,
    workerReady?.checkoutPath,
    preparedWorker?.checkoutPath,
    repoRoot
  ];
  const visited = new Set();
  for (const candidate of checkoutCandidates) {
    const checkoutRoot = resolveCheckoutPath(repoRoot, candidate) ?? path.resolve(repoRoot);
    if (!checkoutRoot || visited.has(checkoutRoot)) {
      continue;
    }
    visited.add(checkoutRoot);
    const receiptPath = path.join(checkoutRoot, DEFAULT_CONCURRENT_LANE_STATUS_PATH);
    const receipt = await readJsonIfPresent(receiptPath);
    const projected = projectConcurrentLaneStatusReceipt(receiptPath, receipt);
    if (projected) {
      return projected;
    }
  }

  return null;
}

function deriveConcurrentLaneLifecycle(defaultLifecycle, concurrentLaneApply, concurrentLaneStatus) {
  if (!concurrentLaneStatus || typeof concurrentLaneStatus !== 'object') {
    const applyStatus = normalizeText(concurrentLaneApply?.status).toLowerCase();
    if (['succeeded', 'noop'].includes(applyStatus)) {
      return 'waiting-ci';
    }
    return defaultLifecycle;
  }

  const status = normalizeText(concurrentLaneStatus.status).toLowerCase();
  const disposition = normalizeText(concurrentLaneStatus.summary?.orchestratorDisposition).toLowerCase();
  if (status === 'failed' || disposition === 'hold-investigate') {
    return 'blocked';
  }

  if (['wait-hosted-run', 'release-merge-queue', 'release-with-deferred-local'].includes(disposition)) {
    return 'waiting-ci';
  }

  return defaultLifecycle;
}

function parseRepositoryFromIssueUrl(url) {
  const match = String(url || '').match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/issues\/\d+$/i);
  return match?.[1] || '';
}

function normalizeMirrorOfPointer(rawMirrorOf) {
  if (!rawMirrorOf || typeof rawMirrorOf !== 'object') {
    return null;
  }
  const number = coercePositiveInteger(rawMirrorOf.number);
  const url = normalizeText(rawMirrorOf.url) || null;
  const repository = normalizeText(rawMirrorOf.repository) || parseRepositoryFromIssueUrl(url) || null;
  if (!number && !url && !repository) {
    return null;
  }
  return {
    repository,
    number,
    url
  };
}

function resolveForkRemoteForRepository(repository, upstreamRepository, implementationRemote = 'origin') {
  const normalizedRepository = normalizeText(repository);
  const normalizedUpstream = normalizeText(upstreamRepository) || COMPAREVI_UPSTREAM_REPOSITORY;
  if (!normalizedRepository || !normalizedUpstream) return null;
  if (normalizedRepository === normalizedUpstream) {
    return normalizeText(implementationRemote) || 'origin';
  }

  const [upstreamOwner] = normalizedUpstream.split('/');
  const [repositoryOwner] = normalizedRepository.split('/');
  return repositoryOwner === upstreamOwner ? 'origin' : 'personal';
}

function buildSchedulerDecisionFromSnapshot({
  snapshot,
  repoRoot = process.cwd(),
  upstreamRepository,
  implementationRemote,
  branchClassContract = null,
  loadBranchClassContractFn = loadBranchClassContract,
  source,
  artifactPaths
}) {
  if (!snapshot) {
    return {
      source,
      outcome: 'idle',
      reason: 'standing-priority artifacts are not available yet',
      artifacts: artifactPaths
    };
  }

  if (snapshot.schema === 'standing-priority/no-standing@v1') {
    return {
      source,
      outcome: 'idle',
      reason: normalizeText(snapshot.message) || normalizeText(snapshot.reason) || 'standing-priority queue is empty',
      artifacts: artifactPaths
    };
  }

  const standingRepository =
    normalizeText(snapshot.repository) ||
    parseRepositoryFromIssueUrl(snapshot.url) ||
    normalizeText(snapshot.mirrorOf?.repository) ||
    normalizeText(upstreamRepository);
  const selectedIssue = Number.isInteger(snapshot.mirrorOf?.number) ? snapshot.mirrorOf.number : snapshot.number;
  if (!Number.isInteger(selectedIssue) || selectedIssue <= 0) {
    return {
      source,
      outcome: 'idle',
      reason: 'standing-priority snapshot does not resolve to an executable issue number',
      artifacts: artifactPaths
    };
  }

  const forkRemote = resolveForkRemoteForRepository(standingRepository, upstreamRepository, implementationRemote);
  const laneId = [forkRemote, selectedIssue].filter(Boolean).join('-') || `issue-${selectedIssue}`;
  const branch = resolveCompareviIssueBranchName({
    issueNumber: selectedIssue,
    title: snapshot.title,
    forkRemote,
    repoRoot,
    branchClassContract,
    loadBranchClassContractFn
  });
  const reason =
    Number.isInteger(snapshot.mirrorOf?.number) && snapshot.mirrorOf.number !== snapshot.number
      ? `standing mirror #${snapshot.number} routes to upstream issue #${snapshot.mirrorOf.number}`
      : `standing issue #${selectedIssue}`;
  const cadence = isCadenceAlertIssue(snapshot.title, snapshot.body);

  return {
    source,
    outcome: 'selected',
    reason,
    stepOptions: {
      lane: laneId,
      issue: selectedIssue,
      forkRemote,
      branch
    },
    artifacts: {
      ...(artifactPaths || {}),
      standingIssueNumber: Number.isInteger(snapshot.number) ? snapshot.number : null,
      standingRepository,
      canonicalIssueNumber: selectedIssue,
      canonicalRepository: normalizeText(snapshot.mirrorOf?.repository) || standingRepository,
      mirrorOf: snapshot.mirrorOf ?? null,
      issueUrl: normalizeText(snapshot.url) || null,
      issueTitle: normalizeText(snapshot.title) || null,
      cadence
    }
  };
}

async function planCompareviRuntimeStepFromLiveStanding({ repoRoot, targetRepository, upstreamRepository, deps, env }) {
  if (!targetRepository) {
    return null;
  }

  const deliveryPolicy = await loadDeliveryAgentPolicy(repoRoot, {
    ...deps,
    policyPath: deps.deliveryAgentPolicyPath || DELIVERY_AGENT_POLICY_RELATIVE_PATH
  });
  const standingPriorityLabels = resolveStandingPriorityLabels(repoRoot, targetRepository, env);
  const resolveStandingPriorityForRepoFn =
    deps.resolveStandingPriorityForRepoFn ?? resolveStandingPriorityForRepo;
  const standingLookup = await resolveStandingPriorityForRepoFn(repoRoot, targetRepository, standingPriorityLabels);
  if (standingLookup?.found?.number) {
    const issueSnapshot = await fetchIssue(standingLookup.found.number, repoRoot, targetRepository, {
      ghIssueFetcher: deps.ghIssueFetcher,
      restIssueFetcher: deps.restIssueFetcher
    });
    const mirrorOf = parseUpstreamIssuePointerFromBody(issueSnapshot.body);
    const snapshotWithRepo = {
      ...issueSnapshot,
      repository: targetRepository,
      mirrorOf
    };
    if (!mirrorOf?.number && targetRepository === upstreamRepository) {
      try {
        const issueGraph = await fetchIssueExecutionGraph({
          repoRoot,
          repository: targetRepository,
          issueNumber: standingLookup.found.number,
          deps
        });
        return applyAuthoritativeLaneBranchOverride({
          repoRoot,
          decision: await buildCanonicalDeliveryDecision({
            repoRoot,
            issueSnapshot: snapshotWithRepo,
            issueGraph,
            upstreamRepository,
            targetRepository,
            policy: deliveryPolicy,
            source: 'comparevi-standing-priority-live',
            deps
          }),
          deps
        });
      } catch {
        // Fall back to snapshot-only scheduling when the live execution graph
        // cannot be resolved in this cycle.
      }
    }
    return applyAuthoritativeLaneBranchOverride({
      repoRoot,
      decision: buildSchedulerDecisionFromSnapshot({
        snapshot: snapshotWithRepo,
        repoRoot,
        upstreamRepository,
        implementationRemote: deliveryPolicy.implementationRemote,
        branchClassContract: deps.branchClassContract ?? null,
        loadBranchClassContractFn: deps.loadBranchClassContractFn ?? loadBranchClassContract,
        source: 'comparevi-standing-priority-live',
        artifactPaths: {
          standingLabel: standingLookup.found.label || null,
          liveRepository: targetRepository
        }
      }),
      deps
    });
  }

  const classifyNoStandingPriorityConditionFn =
    deps.classifyNoStandingPriorityConditionFn ?? classifyNoStandingPriorityCondition;
  const classification = await classifyNoStandingPriorityConditionFn(
    repoRoot,
    targetRepository,
    standingPriorityLabels,
    {
      env,
      targetSlug: targetRepository
    }
  );
  if (classification?.status === 'classified') {
    const artifactPaths = {
      liveRepository: targetRepository,
      noStandingReason: classification.reason,
      openIssueCount: classification.openIssueCount,
      standingLabels: standingPriorityLabels
    };
    if (classification.reason === 'queue-empty') {
      const runMonitoringWorkInjectionFn = deps.runMonitoringWorkInjectionFn ?? runMonitoringWorkInjection;
      const injection = await runMonitoringWorkInjectionFn({
        repoRoot,
        repository: targetRepository,
        outputPath: deps.monitoringWorkInjectionOutputPath ?? DEFAULT_MONITORING_WORK_INJECTION_PATH
      });
      if (normalizeText(injection?.outputPath)) {
        artifactPaths.monitoringWorkInjectionPath = injection.outputPath;
      }
      if (normalizeText(injection?.ledgerPath)) {
        artifactPaths.monitoringDecisionLedgerPath = injection.ledgerPath;
      }
      if (Number.isInteger(injection?.issueNumber)) {
        const issueSnapshot = await fetchIssue(injection.issueNumber, repoRoot, targetRepository, {
          ghIssueFetcher: deps.ghIssueFetcher,
          restIssueFetcher: deps.restIssueFetcher
        });
        const mirrorOf = parseUpstreamIssuePointerFromBody(issueSnapshot.body);
        return applyAuthoritativeLaneBranchOverride({
          repoRoot,
          decision: buildSchedulerDecisionFromSnapshot({
            snapshot: {
              ...issueSnapshot,
              repository: targetRepository,
              mirrorOf
            },
            repoRoot,
            upstreamRepository,
            implementationRemote: deliveryPolicy.implementationRemote,
            branchClassContract: deps.branchClassContract ?? null,
            loadBranchClassContractFn: deps.loadBranchClassContractFn ?? loadBranchClassContract,
            source: 'comparevi-monitoring-work-injection',
            artifactPaths: {
              ...artifactPaths,
              monitoringInjectedIssueNumber: injection.issueNumber,
              monitoringInjectedIssueUrl: normalizeText(injection.issueUrl) || null
            }
          }),
          deps
        });
      }

      const governorPortfolioHandoff = await resolveGovernorPortfolioHandoff({
        repoRoot,
        repository: targetRepository,
        deps
      });
      artifactPaths.governorPortfolioHandoff = governorPortfolioHandoff;

      let reason = classification.message;
      if (governorPortfolioHandoff.status === 'owner-match') {
        if (normalizeText(governorPortfolioHandoff.viHistoryDistributorDependencyStatus) === 'blocked') {
          const dependencyTarget =
            normalizeText(governorPortfolioHandoff.viHistoryDistributorDependencyTargetRepository) ||
            'the canonical template';
          const dependencyBlocker = normalizeText(governorPortfolioHandoff.viHistoryDistributorDependencyExternalBlocker);
          reason =
            `standing queue is empty; governor portfolio keeps ownership in ${governorPortfolioHandoff.currentOwnerRepository} ` +
            `while the vi-history distributor dependency for ${dependencyTarget} remains blocked` +
            (dependencyBlocker ? ` (${dependencyBlocker}).` : '.');
        } else if (
          normalizeText(governorPortfolioHandoff.nextOwnerRepository) &&
          normalizeText(governorPortfolioHandoff.nextOwnerRepository).toLowerCase() !== targetRepository.toLowerCase() &&
          ['future-agent-may-pivot', 'reopen-template-monitoring-work'].includes(
            normalizeText(governorPortfolioHandoff.nextAction)
          )
        ) {
          reason =
            `standing queue is empty; governor portfolio keeps ownership in ${governorPortfolioHandoff.currentOwnerRepository} ` +
            `while preparing repo-context pivot to ${governorPortfolioHandoff.nextOwnerRepository}.`;
        } else {
          reason = `standing queue is empty; governor portfolio keeps ownership in ${governorPortfolioHandoff.currentOwnerRepository}.`;
        }
      } else if (governorPortfolioHandoff.status === 'external-owner') {
        reason = `standing queue is empty; governor portfolio hands ownership to ${governorPortfolioHandoff.currentOwnerRepository}.`;
      } else if (governorPortfolioHandoff.status === 'missing') {
        reason = 'standing queue is empty; governor portfolio handoff is unavailable (missing).';
      } else if (governorPortfolioHandoff.status === 'invalid') {
        reason = 'standing queue is empty; governor portfolio handoff is unavailable (invalid).';
      }

      return {
        source: 'comparevi-standing-priority-live',
        outcome: 'idle',
        reason,
        artifacts: artifactPaths
      };
    }
    return {
      source: 'comparevi-standing-priority-live',
      outcome: 'idle',
      reason: classification.message,
      artifacts: artifactPaths
    };
  }

  return null;
}

async function planCompareviRuntimeStep({ repoRoot, env, explicitStepOptions, options = {}, deps = {} }) {
  if (explicitStepOptions?.issue || explicitStepOptions?.lane) {
    return {
      source: 'comparevi-manual',
      outcome: 'selected',
      reason: 'using explicit observer lane input',
      stepOptions: explicitStepOptions
    };
  }

  const upstreamRepository =
    normalizeText(env.AGENT_PRIORITY_UPSTREAM_REPOSITORY) || COMPAREVI_UPSTREAM_REPOSITORY;
  const deliveryPolicy = await loadDeliveryAgentPolicy(repoRoot, {
    ...deps,
    policyPath: deps.deliveryAgentPolicyPath || DELIVERY_AGENT_POLICY_RELATIVE_PATH
  });
  const targetRepository = normalizeText(options.repo) || normalizeText(env.GITHUB_REPOSITORY);
  const liveDecision = await planCompareviRuntimeStepFromLiveStanding({
    repoRoot,
    targetRepository,
    upstreamRepository,
    deps,
    env
  });
  if (liveDecision) {
    return liveDecision;
  }

  const cachePath = path.join(repoRoot, PRIORITY_CACHE_FILENAME);
  const cacheSnapshot = await readJsonIfPresent(cachePath);
  if (cacheSnapshot) {
    return applyAuthoritativeLaneBranchOverride({
      repoRoot,
      decision: buildSchedulerDecisionFromSnapshot({
        snapshot: cacheSnapshot,
        repoRoot,
        upstreamRepository,
        implementationRemote: deliveryPolicy.implementationRemote,
        branchClassContract: deps.branchClassContract ?? null,
        loadBranchClassContractFn: deps.loadBranchClassContractFn ?? loadBranchClassContract,
        source: 'comparevi-standing-priority-cache',
        artifactPaths: {
          cachePath
        }
      }),
      deps
    });
  }

  const routerPath = path.join(repoRoot, PRIORITY_ISSUE_DIR, 'router.json');
  const router = await readJsonIfPresent(routerPath);
  if (!Number.isInteger(router?.issue)) {
    return {
      source: 'comparevi-standing-priority-router',
      outcome: 'idle',
      reason: 'standing-priority router does not point to an active issue',
      artifacts: {
        routerPath
      }
    };
  }

  const issuePath = path.join(repoRoot, PRIORITY_ISSUE_DIR, `${router.issue}.json`);
  const issueSnapshot = await readJsonIfPresent(issuePath);
  return applyAuthoritativeLaneBranchOverride({
    repoRoot,
    decision: buildSchedulerDecisionFromSnapshot({
      snapshot: issueSnapshot,
      repoRoot,
      upstreamRepository,
      implementationRemote: deliveryPolicy.implementationRemote,
      branchClassContract: deps.branchClassContract ?? null,
      loadBranchClassContractFn: deps.loadBranchClassContractFn ?? loadBranchClassContract,
      source: 'comparevi-standing-priority-router',
      artifactPaths: {
        routerPath,
        issuePath
      }
    }),
    deps
  });
}

async function resolveCompareviTaskPacketSnapshot({ repoRoot, schedulerDecision }) {
  const artifactPaths = schedulerDecision?.artifacts ?? {};
  if (artifactPaths.selectedIssueSnapshot && typeof artifactPaths.selectedIssueSnapshot === 'object') {
    return artifactPaths.selectedIssueSnapshot;
  }
  for (const candidate of [artifactPaths.issuePath, artifactPaths.cachePath]) {
    const resolved = normalizeText(candidate);
    if (!resolved) {
      continue;
    }
    const snapshot = await readJsonIfPresent(resolved);
    if (snapshot) {
      return snapshot;
    }
  }

  const issueNumber = schedulerDecision?.activeLane?.issue;
  if (!Number.isInteger(issueNumber)) {
    return null;
  }
  return readJsonIfPresent(path.join(repoRoot, PRIORITY_ISSUE_DIR, `${issueNumber}.json`));
}

async function buildCompareviTaskPacket({ repoRoot, schedulerDecision, preparedWorker, workerReady, workerBranch, deps = {} }) {
  const activeLane = schedulerDecision?.activeLane ?? null;
  const artifacts = schedulerDecision?.artifacts ?? {};
  const deliveryPolicy = await loadDeliveryAgentPolicy(repoRoot, {
    ...deps,
    policyPath: deps.deliveryAgentPolicyPath || DELIVERY_AGENT_POLICY_RELATIVE_PATH
  });
  const snapshot = await resolveCompareviTaskPacketSnapshot({ repoRoot, schedulerDecision });
  const issueNumber = activeLane?.issue;
  const issueTitle = normalizeText(snapshot?.title);
  const branchName = normalizeText(workerBranch?.branch) || normalizeText(activeLane?.branch);
  const selectedActionType = normalizeText(artifacts.selectedActionType);
  const defaultLaneLifecycle = normalizeText(artifacts.laneLifecycle) || (activeLane?.prUrl ? 'waiting-ci' : 'coding');
  const concurrentLaneApply = await resolveConcurrentLaneApplyEvidence({
    repoRoot,
    preparedWorker,
    workerReady,
    workerBranch
  });
  const concurrentLaneStatus = await resolveConcurrentLaneStatusEvidence({
    repoRoot,
    preparedWorker,
    workerReady,
    workerBranch
  });
  const laneLifecycle = deriveConcurrentLaneLifecycle(defaultLaneLifecycle, concurrentLaneApply, concurrentLaneStatus);
  const loadBranchClassContractFn = deps.loadBranchClassContractFn ?? loadBranchClassContract;
  const canonicalRepository =
    normalizeText(artifacts.canonicalRepository) ||
    normalizeText(snapshot?.repository) ||
    normalizeText(artifacts.standingRepository) ||
    COMPAREVI_UPSTREAM_REPOSITORY;
  const planeTransition = resolveBranchPlaneTransition({
    branch: branchName,
    sourcePlane: normalizeText(activeLane?.forkRemote) || normalizeText(deliveryPolicy.implementationRemote) || 'origin',
    targetRepository: canonicalRepository,
    contract: loadBranchClassContractFn(repoRoot)
  });
  const objectiveSummary =
    selectedActionType === 'reshape-backlog'
      ? `Reshape epic #${issueNumber}${issueTitle ? `: ${issueTitle}` : ''} into an executable child slice`
      : Number.isInteger(issueNumber)
        ? `Advance issue #${issueNumber}${issueTitle ? `: ${issueTitle}` : ''}${branchName ? ` on ${branchName}` : ''}`
        : normalizeText(schedulerDecision?.reason) || 'No compare-vi lane selected.';
  const pullRequestArtifact = artifacts.pullRequest ?? null;
  const standingIssueSnapshot = artifacts.standingIssueSnapshot ?? null;
  const localReviewLoop = buildLocalReviewLoopRequest({
    standingIssue: standingIssueSnapshot,
    selectedIssue: snapshot,
    policy: deliveryPolicy
  });
  const workerPool =
    deliveryPolicy?.workerPool && typeof deliveryPolicy.workerPool === 'object'
      ? buildWorkerPoolPolicySnapshot(deliveryPolicy)
      : null;
  const workerProviderSelection = selectWorkerProviderAssignment({
    policy: deliveryPolicy,
    selection: buildWorkerProviderSelectionRequest({
      schedulerDecision,
      laneLifecycle,
      selectedActionType
    }),
    preferredSlotId:
      normalizeText(preparedWorker?.slotId) ||
      normalizeText(workerReady?.slotId) ||
      normalizeText(workerBranch?.slotId) ||
      null,
    availableSlots: workerPool?.providers?.map((provider, index) => ({
      slotId: `worker-slot-${index + 1}`,
      providerId: provider.id
    })) ?? []
  });
  const liveAgentModelSelection = resolveLiveAgentModelSelectionEvidence({
    repoRoot,
    deps,
    selectedProviderId: workerProviderSelection.selectedProviderId
  });

  return {
    source: 'comparevi-runtime',
    status: laneLifecycle,
    objective: {
      summary: objectiveSummary,
      source: issueTitle ? 'comparevi-issue-snapshot' : 'comparevi-runtime'
    },
    pullRequest: {
      url: normalizeText(activeLane?.prUrl) || normalizeText(pullRequestArtifact?.url) || null,
      status:
        pullRequestArtifact?.readyToMerge === true
          ? 'ready-merge'
          : normalizeText(activeLane?.prUrl) || normalizeText(pullRequestArtifact?.url)
            ? 'linked'
            : 'none'
    },
    checks: {
      status:
        normalizeText(pullRequestArtifact?.checks?.status) ||
        (activeLane?.blockerClass === 'ci' ? 'blocked' : normalizeText(activeLane?.prUrl) ? 'pending-or-unknown' : 'not-linked'),
      blockerClass: normalizeText(pullRequestArtifact?.checks?.blockerClass) || normalizeText(activeLane?.blockerClass) || 'none'
    },
    helperSurface: {
      preferred: COMPAREVI_PREFERRED_HELPERS,
      fallbacks: COMPAREVI_FALLBACK_HELPERS
    },
    evidence: {
      priority: {
        cachePath: normalizeText(schedulerDecision?.artifacts?.cachePath) || null,
        routerPath: normalizeText(schedulerDecision?.artifacts?.routerPath) || null,
        issuePath: normalizeText(schedulerDecision?.artifacts?.issuePath) || null
      },
      lane: {
        workerSlotId:
          normalizeText(workerBranch?.slotId) ||
          normalizeText(workerReady?.slotId) ||
          normalizeText(preparedWorker?.slotId) ||
          null,
        workerProviderId:
          normalizeText(workerBranch?.providerId) ||
          normalizeText(workerReady?.providerId) ||
          normalizeText(preparedWorker?.providerId) ||
          workerProviderSelection.selectedProviderId ||
          null,
        workerCheckoutRoot:
          normalizeText(workerBranch?.checkoutRoot) ||
          normalizeText(workerReady?.checkoutRoot) ||
          normalizeText(preparedWorker?.checkoutRoot) ||
          null,
        workerCheckoutRootPolicy:
          workerBranch?.checkoutRootPolicy ??
          workerReady?.checkoutRootPolicy ??
          preparedWorker?.checkoutRootPolicy ??
          null,
        workerCheckoutPath:
          normalizeText(workerBranch?.checkoutPath) ||
          normalizeText(workerReady?.checkoutPath) ||
          normalizeText(preparedWorker?.checkoutPath) ||
          null
      },
      delivery: {
        executionMode: normalizeText(artifacts.executionMode) || 'fork-mirror-auto-drain',
        laneLifecycle,
        selectedActionType: selectedActionType || null,
        standingIssue:
          standingIssueSnapshot && typeof standingIssueSnapshot === 'object'
            ? {
                number: coercePositiveInteger(standingIssueSnapshot.number),
                title: normalizeText(standingIssueSnapshot.title) || null,
                url: normalizeText(standingIssueSnapshot.url) || null
              }
            : {
                number: coercePositiveInteger(artifacts.standingIssueNumber),
                title: null,
                url: null
              },
        selectedIssue:
          snapshot && typeof snapshot === 'object'
            ? {
                number: coercePositiveInteger(snapshot.number),
                title: normalizeText(snapshot.title) || null,
                url: normalizeText(snapshot.url) || null
              }
            : null,
        issueGraph: artifacts.issueGraph ?? null,
        pullRequest: pullRequestArtifact,
        backlog: artifacts.backlogRepair ?? null,
        concurrentLaneApply,
        concurrentLaneStatus,
        planeTransition,
        localReviewLoop,
        liveAgentModelSelection,
        workerPool,
        workerProviderSelection,
        mutationEnvelope: {
          backlogAuthority: 'issues',
          implementationRemote: normalizeText(activeLane?.forkRemote) || 'origin',
          copilotReviewStrategy: deliveryPolicy.copilotReviewStrategy,
          readyForReviewPurpose: 'final-validation',
          allowPolicyMutations: false,
          allowReleaseAdmin: false,
          maxActiveCodingLanes: deliveryPolicy.maxActiveCodingLanes
        },
        turnBudget: deliveryPolicy.turnBudget,
        relevantFiles: [
          path.join(repoRoot, 'tools', 'priority', 'runtime-supervisor.mjs'),
          path.join(repoRoot, 'tools', 'priority', 'runtime-turn-broker.mjs'),
          path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'),
          path.join(repoRoot, 'tools', 'priority', 'concurrent-lane-status.mjs'),
          path.join(repoRoot, 'tools', 'priority', 'docker-desktop-review-loop.mjs'),
          path.join(repoRoot, 'tools', 'Run-NonLVChecksInDocker.ps1')
        ]
      }
    }
  };
}

function buildTemplateAgentVerificationReportRefreshOptions({
  repoRoot,
  repository,
  policy,
  taskPacket,
  executionReceipt
}) {
  const lane = policy?.templateAgentVerificationLane ?? {};
  const receiptStatus = normalizeText(executionReceipt?.status).toLowerCase();
  const laneLifecycle = normalizeText(executionReceipt?.details?.laneLifecycle).toLowerCase();
  if (lane.enabled !== true) {
    return null;
  }
  if (receiptStatus !== 'completed') {
    return null;
  }
  if (!lane.reportPath) {
    return null;
  }
  if (laneLifecycle === 'idle' || laneLifecycle === 'blocked') {
    return null;
  }

  const issueNumber =
    coercePositiveInteger(taskPacket?.evidence?.delivery?.selectedIssue?.number) ??
    coercePositiveInteger(taskPacket?.issue);
  const branchName = normalizeText(taskPacket?.branch?.name);
  const iterationLabel =
    issueNumber != null
      ? `post-merge #${issueNumber}`
      : branchName
        ? `post-merge ${branchName}`
        : normalizeText(taskPacket?.objective?.summary) || 'post-merge iteration';
  const iterationRef = branchName || normalizeText(taskPacket?.pullRequest?.url) || null;
  const iterationHeadSha =
    normalizeText(executionReceipt?.details?.endHead) ||
    normalizeText(executionReceipt?.details?.startHead) ||
    null;
  const reportPath = path.isAbsolute(lane.reportPath)
    ? lane.reportPath
    : path.join(repoRoot, lane.reportPath);

  return {
    policyPath: path.join(repoRoot, DELIVERY_AGENT_POLICY_RELATIVE_PATH),
    outputPath: reportPath || DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH,
    repo: normalizeText(repository) || normalizeText(taskPacket?.repository) || null,
    iterationLabel,
    iterationRef,
    iterationHeadSha,
    verificationStatus: 'pending',
    durationSeconds: null,
    provider: 'hosted-github-workflow',
    runUrl: null,
    templateRepo: normalizeText(lane.targetRepository) || null,
    failOnBlockers: false
  };
}

function buildMirrorCloseComment({ upstreamIssueNumber, upstreamIssueUrl, implementationLanded = false }) {
  if (implementationLanded) {
    return `Closing this fork mirror. The implementation has already landed upstream for canonical issue #${upstreamIssueNumber} (${upstreamIssueUrl}). Future work should continue on the upstream issue or a rematerialized fork mirror if local execution is needed again.`;
  }
  return `Closing this fork mirror so the fork queue keeps only active local work. Canonical tracking continues on upstream issue #${upstreamIssueNumber} (${upstreamIssueUrl}); rematerialize a fork mirror later if local execution needs to resume.`;
}

async function invokeCanonicalDeliveryTurn({
  repoRoot,
  deps,
  taskPacket,
  taskPacketArtifacts,
  schedulerDecision
}) {
  if (typeof deps.invokeDeliveryTurnBrokerFn === 'function') {
    return deps.invokeDeliveryTurnBrokerFn({
      repoRoot,
      taskPacket,
      taskPacketPath: taskPacketArtifacts?.latestPath || null,
      schedulerDecision
    });
  }

  const brokerModulePath = path.join(repoRoot, 'tools', 'priority', 'runtime-turn-broker.mjs');
  const taskPacketPath = normalizeText(taskPacketArtifacts?.latestPath);
  if (!taskPacketPath) {
    throw new Error('task packet artifact path is required for canonical delivery turns');
  }
  const brokerReceiptPath = path.join(path.dirname(taskPacketPath), 'broker-execution-receipt.json');
  const execFn = deps.execFileFn ?? execFileAsync;
  const { stdout } = await execFn(
    'node',
    [
      brokerModulePath,
      '--repo-root',
      repoRoot,
      '--task-packet',
      taskPacketPath,
      '--policy',
      DELIVERY_AGENT_POLICY_RELATIVE_PATH,
      '--receipt-out',
      brokerReceiptPath
    ],
    {
      cwd: repoRoot,
      env: process.env
    }
  );
  const fileReceipt = await readJsonIfPresent(brokerReceiptPath);
  if (fileReceipt && typeof fileReceipt === 'object') {
    return fileReceipt;
  }
  const parsed = parseJsonObjectOutput(stdout, 'runtime-turn-broker stdout');
  return parsed && typeof parsed === 'object' ? parsed : {};
}

async function persistCompareviDeliveryRuntime({
  repository,
  runtimeArtifactPaths,
  schedulerDecision,
  taskPacket,
  executionReceipt,
  repoRoot,
  deps,
  now
}) {
  if (!runtimeArtifactPaths?.runtimeDir) {
    return null;
  }
  const deliveryPolicy = await loadDeliveryAgentPolicy(repoRoot, {
    ...deps,
    policyPath: deps.deliveryAgentPolicyPath || DELIVERY_AGENT_POLICY_RELATIVE_PATH
  });
  const runtimeState = await persistDeliveryAgentRuntimeState({
    repoRoot,
    runtimeDir: runtimeArtifactPaths.runtimeDir,
    repository,
    policy: deliveryPolicy,
    schedulerDecision,
    taskPacket,
    executionReceipt,
    now
  });
  const templateVerificationReportOptions = buildTemplateAgentVerificationReportRefreshOptions({
    repoRoot,
    repository,
    policy: deliveryPolicy,
    taskPacket,
    executionReceipt
  });
  if (templateVerificationReportOptions) {
    const runTemplateAgentVerificationReportFn =
      deps.runTemplateAgentVerificationReportFn ?? runTemplateAgentVerificationReport;
    await runTemplateAgentVerificationReportFn(templateVerificationReportOptions);
  }
  return runtimeState;
}

async function executeCompareviTurn({
  options,
  env,
  repoRoot,
  deps,
  schedulerDecision,
  taskPacket,
  taskPacketArtifacts,
  runtimeArtifactPaths,
  repository,
  now
}) {
  const upstreamRepository = normalizeText(env.AGENT_PRIORITY_UPSTREAM_REPOSITORY) || COMPAREVI_UPSTREAM_REPOSITORY;
  let standingRepository =
    normalizeText(schedulerDecision?.artifacts?.standingRepository) ||
    normalizeText(options.repo) ||
    normalizeText(env.GITHUB_REPOSITORY) ||
    null;
  let standingIssueNumber =
    coercePositiveInteger(schedulerDecision?.artifacts?.standingIssueNumber) ||
    coercePositiveInteger(schedulerDecision?.activeLane?.issue) ||
    coercePositiveInteger(options.issue);
  let mirrorOf = normalizeMirrorOfPointer(schedulerDecision?.artifacts?.mirrorOf);
  let cadenceKnown = schedulerDecision?.artifacts?.cadence === true || schedulerDecision?.artifacts?.cadence === false;
  let cadence = schedulerDecision?.artifacts?.cadence === true;

  if (standingRepository && standingIssueNumber) {
    const localSnapshot = await readJsonIfPresent(path.join(repoRoot, PRIORITY_ISSUE_DIR, `${standingIssueNumber}.json`));
    if (localSnapshot) {
      mirrorOf = mirrorOf ?? normalizeMirrorOfPointer(localSnapshot.mirrorOf) ?? parseUpstreamIssuePointerFromBody(localSnapshot.body);
      cadence = cadence || isCadenceAlertIssue(localSnapshot.title, localSnapshot.body);
      cadenceKnown = true;
      standingRepository = standingRepository || parseRepositoryFromIssueUrl(localSnapshot.url);
    }

    if (!mirrorOf || !mirrorOf.number || !normalizeText(mirrorOf.url) || !cadenceKnown) {
      try {
        const issueSnapshot = await fetchIssue(standingIssueNumber, repoRoot, standingRepository, {
          ghIssueFetcher: deps.ghIssueFetcher,
          restIssueFetcher: deps.restIssueFetcher
        });
        mirrorOf = mirrorOf ?? normalizeMirrorOfPointer(issueSnapshot.mirrorOf) ?? parseUpstreamIssuePointerFromBody(issueSnapshot.body);
        cadence = cadence || isCadenceAlertIssue(issueSnapshot.title, issueSnapshot.body);
        cadenceKnown = true;
        standingRepository = standingRepository || parseRepositoryFromIssueUrl(issueSnapshot.url);
      } catch {
        // Keep the current context and let the decision logic below retry in later cycles.
      }
    }
  }

  if (!standingRepository || !Number.isInteger(standingIssueNumber) || standingIssueNumber <= 0) {
    const governorPortfolioPivot = await resolveGovernorPortfolioPivotExecution({
      repoRoot,
      repository: repository || options.repo || env.GITHUB_REPOSITORY || upstreamRepository,
      governorPortfolioHandoff: schedulerDecision?.artifacts?.governorPortfolioHandoff ?? null,
      env,
      deps
    });
    if (governorPortfolioPivot.status === 'ready') {
      const receipt = {
        status: 'completed',
        outcome: 'repo-context-pivot',
        reason: `Standing queue is empty; runtime repo-context pivots to ${governorPortfolioPivot.nextOwnerRepository}.`,
        source: 'comparevi-runtime',
        details: {
          laneLifecycle: 'idle',
          blockerClass: 'none',
          actionType: 'repo-context-pivot',
          retryable: true,
          nextWakeCondition: 'target-repository-cycle',
          currentRepository: governorPortfolioPivot.currentRepository,
          currentOwnerRepository: governorPortfolioPivot.currentOwnerRepository,
          nextOwnerRepository: governorPortfolioPivot.nextOwnerRepository,
          nextAction: governorPortfolioPivot.nextAction,
          ownerDecisionSource: governorPortfolioPivot.ownerDecisionSource,
          governorMode: governorPortfolioPivot.governorMode,
          monitoringEntrypointsPath: governorPortfolioPivot.registryPath,
          targetEntrypointPath: governorPortfolioPivot.targetEntrypointPath,
          targetHeadSha: governorPortfolioPivot.targetHeadSha,
          targetCheckoutState: governorPortfolioPivot.targetCheckoutState,
          targetCurrentState: governorPortfolioPivot.targetCurrentState,
          targetReceipts: governorPortfolioPivot.targetReceipts
        },
        artifacts: {
          governorPortfolioHandoff: schedulerDecision?.artifacts?.governorPortfolioHandoff ?? null,
          governorPortfolioPivot
        }
      };
      await persistCompareviDeliveryRuntime({
        repository: repository || standingRepository || options.repo || env.GITHUB_REPOSITORY || 'unknown/unknown',
        runtimeArtifactPaths,
        schedulerDecision,
        taskPacket,
        executionReceipt: receipt,
        repoRoot,
        deps,
        now
      });
      return receipt;
    }

    if (governorPortfolioPivot.status !== 'same-repository') {
      const receipt = {
        status: 'completed',
        outcome: 'idle',
        reason:
          `Standing queue is empty; runtime repo-context pivot to ${governorPortfolioPivot.nextOwnerRepository || 'the next owner'} ` +
          `is unavailable (${governorPortfolioPivot.status}).`,
        source: 'comparevi-runtime',
        details: {
          laneLifecycle: 'idle',
          blockerClass: governorPortfolioPivot.status === 'invalid' ? 'helper' : 'none',
          actionType: 'repo-context-pivot-pending',
          retryable: true,
          nextWakeCondition: 'portfolio-handoff-refreshed',
          currentRepository: governorPortfolioPivot.currentRepository,
          currentOwnerRepository: governorPortfolioPivot.currentOwnerRepository,
          nextOwnerRepository: governorPortfolioPivot.nextOwnerRepository,
          nextAction: governorPortfolioPivot.nextAction,
          ownerDecisionSource: governorPortfolioPivot.ownerDecisionSource,
          governorMode: governorPortfolioPivot.governorMode,
          monitoringEntrypointsPath: governorPortfolioPivot.registryPath,
          targetEntrypointPath: governorPortfolioPivot.targetEntrypointPath,
          targetHeadSha: governorPortfolioPivot.targetHeadSha,
          targetCheckoutState: governorPortfolioPivot.targetCheckoutState,
          targetCurrentState: governorPortfolioPivot.targetCurrentState,
          targetReceipts: governorPortfolioPivot.targetReceipts,
          pivotStatus: governorPortfolioPivot.status
        },
        artifacts: {
          governorPortfolioHandoff: schedulerDecision?.artifacts?.governorPortfolioHandoff ?? null,
          governorPortfolioPivot
        }
      };
      await persistCompareviDeliveryRuntime({
        repository: repository || standingRepository || options.repo || env.GITHUB_REPOSITORY || 'unknown/unknown',
        runtimeArtifactPaths,
        schedulerDecision,
        taskPacket,
        executionReceipt: receipt,
        repoRoot,
        deps,
        now
      });
      return receipt;
    }

    const receipt = {
      status: 'completed',
      outcome: 'idle',
      reason: 'standing repository or issue number unavailable for unattended execution',
      source: 'comparevi-runtime',
      details: {
        laneLifecycle: 'idle',
        blockerClass: 'none',
        actionType: 'idle',
        retryable: false,
        nextWakeCondition: 'next-scheduler-cycle'
      }
    };
    await persistCompareviDeliveryRuntime({
      repository: repository || standingRepository || options.repo || env.GITHUB_REPOSITORY || 'unknown/unknown',
      runtimeArtifactPaths,
      schedulerDecision,
      taskPacket,
      executionReceipt: receipt,
      repoRoot,
      deps,
      now
    });
    return receipt;
  }

  if (cadence) {
    const receipt = {
      status: 'completed',
      outcome: 'cadence-only',
      reason: `Standing issue #${standingIssueNumber} is a cadence alert; unattended development loop is stopping.`,
      stopLoop: true,
      details: {
        laneLifecycle: 'idle',
        blockerClass: 'none',
        actionType: 'cadence-stop',
        retryable: false,
        nextWakeCondition: 'new-standing-issue',
        standingRepository,
        standingIssueNumber
      }
    };
    await persistCompareviDeliveryRuntime({
      repository: repository || standingRepository,
      runtimeArtifactPaths,
      schedulerDecision,
      taskPacket,
      executionReceipt: receipt,
      repoRoot,
      deps,
      now
    });
    return receipt;
  }

  if (standingRepository === upstreamRepository || !Number.isInteger(mirrorOf?.number) || !normalizeText(mirrorOf?.url)) {
    const receipt = await invokeCanonicalDeliveryTurn({
      repoRoot,
      deps,
      taskPacket,
      taskPacketArtifacts,
      schedulerDecision
    });
    await persistCompareviDeliveryRuntime({
      repository: repository || standingRepository,
      runtimeArtifactPaths,
      schedulerDecision,
      taskPacket,
      executionReceipt: receipt,
      repoRoot,
      deps,
      now
    });
    return receipt;
  }

  let nextCandidate = null;
  let hasNextDevelopmentIssue = false;
  let nextStandingSelectionWarning = '';
  try {
    const openIssues = await listOpenIssuesForTargetRepository(standingRepository, deps);
    nextCandidate = await selectAutoStandingPriorityCandidateForRepo(repoRoot, standingRepository, openIssues, {
      excludeIssueNumbers: [standingIssueNumber],
      fetchIssueDetailsFn: async (issueNumber) =>
        fetchIssue(issueNumber, repoRoot, standingRepository, {
          ghIssueFetcher: deps.ghIssueFetcher,
          restIssueFetcher: deps.restIssueFetcher
        })
    });
    hasNextDevelopmentIssue = Boolean(nextCandidate?.number) && nextCandidate?.cadence !== true;
  } catch (error) {
    nextStandingSelectionWarning = normalizeText(error?.message) || 'unknown error';
  }

  const handoffPending = Boolean(nextStandingSelectionWarning);
  if (handoffPending) {
    const receipt = {
      schema: EXECUTION_RECEIPT_SCHEMA,
      status: 'blocked',
      outcome: 'mirror-handoff-blocked',
      reason:
        `Unable to evaluate the next standing issue for ${standingRepository}: ` +
        `${nextStandingSelectionWarning}. The fork mirror remains open for deterministic retry.`,
      stopLoop: false,
      details: {
        laneLifecycle: 'blocked',
        blockerClass: 'helper',
        actionType: 'fork-mirror-auto-drain',
        retryable: true,
        nextWakeCondition: 'next-standing-selection-succeeds',
        standingRepository,
        standingIssueNumber,
        canonicalIssueNumber: mirrorOf.number,
        canonicalIssueUrl: mirrorOf.url,
        nextStandingIssueNumber: null,
        standingSelectionWarning: nextStandingSelectionWarning,
        helperCallsExecuted: ['node tools/priority/standing-priority-handoff.mjs --auto']
      }
    };
    await persistCompareviDeliveryRuntime({
      repository: repository || standingRepository,
      runtimeArtifactPaths,
      schedulerDecision,
      taskPacket,
      executionReceipt: receipt,
      repoRoot,
      deps,
      now
    });
    return receipt;
  }

  if (hasNextDevelopmentIssue) {
    try {
      await handoffStandingPriority(nextCandidate.number, {
        repoSlug: standingRepository,
        env: {
          ...env,
          GITHUB_REPOSITORY: standingRepository,
          AGENT_PRIORITY_UPSTREAM_REPOSITORY: upstreamRepository
        },
        logger: deps.handoffLogger ?? (() => {}),
        ghRunner: deps.handoffGhRunner,
        patchIssueLabelsFn: deps.patchIssueLabelsFn,
        syncFn: deps.handoffSyncFn,
        leaseReleaseFn: deps.handoffLeaseReleaseFn,
        releaseLease: false
      });
    } catch (error) {
      const receipt = {
        schema: EXECUTION_RECEIPT_SCHEMA,
        status: 'blocked',
        outcome: 'mirror-handoff-apply-blocked',
        reason:
          `Unable to advance standing-priority to #${nextCandidate.number} in ${standingRepository}: ` +
          `${normalizeText(error?.message) || 'unknown error'}. The fork mirror remains open for recovery.`,
        stopLoop: false,
        details: {
          laneLifecycle: 'blocked',
          blockerClass: 'helperbug',
          actionType: 'fork-mirror-auto-drain',
          retryable: true,
          nextWakeCondition: 'handoff-apply-recovery',
          standingRepository,
          standingIssueNumber,
          canonicalIssueNumber: mirrorOf.number,
          canonicalIssueUrl: mirrorOf.url,
          nextStandingIssueNumber: nextCandidate.number,
          standingSelectionWarning: '',
          helperCallsExecuted: [`node tools/priority/standing-priority-handoff.mjs ${nextCandidate.number}`]
        }
      };
      await persistCompareviDeliveryRuntime({
        repository: repository || standingRepository,
        runtimeArtifactPaths,
        schedulerDecision,
        taskPacket,
        executionReceipt: receipt,
        repoRoot,
        deps,
        now
      });
      return receipt;
    }
  }

  await closeIssueWithComment(
    standingRepository,
    standingIssueNumber,
    buildMirrorCloseComment({
      upstreamIssueNumber: mirrorOf.number,
      upstreamIssueUrl: mirrorOf.url,
      implementationLanded: hasNextDevelopmentIssue === false
    }),
    deps
  );

  const receipt = {
    schema: EXECUTION_RECEIPT_SCHEMA,
    status: 'completed',
    outcome: hasNextDevelopmentIssue ? 'mirror-closed-advanced' : 'mirror-closed-queue-exhausted',
    reason: hasNextDevelopmentIssue
      ? `Closed fork mirror #${standingIssueNumber} and advanced standing-priority to #${nextCandidate.number}.`
      : `Closed fork mirror #${standingIssueNumber}; no non-cadence development issues remain in ${standingRepository}.`,
    stopLoop: !hasNextDevelopmentIssue,
    details: {
      laneLifecycle: 'complete',
      blockerClass: 'none',
      actionType: 'fork-mirror-auto-drain',
      retryable: false,
      nextWakeCondition: hasNextDevelopmentIssue ? 'next-standing-issue' : 'new-standing-issue',
      standingRepository,
      standingIssueNumber,
      canonicalIssueNumber: mirrorOf.number,
      canonicalIssueUrl: mirrorOf.url,
      nextStandingIssueNumber: hasNextDevelopmentIssue ? nextCandidate.number : null,
      standingSelectionWarning: ''
    }
  };
  await persistCompareviDeliveryRuntime({
    repository: repository || standingRepository,
    runtimeArtifactPaths,
    schedulerDecision,
    taskPacket,
    executionReceipt: receipt,
    repoRoot,
    deps,
    now
  });
  return receipt;
}

export const compareviRuntimeAdapter = createRuntimeAdapter({
  name: 'comparevi',
  resolveRepoRoot: () => getRepoRoot(),
  resolveRepository: ({ options, env }) => String(options.repo || env.GITHUB_REPOSITORY || '').trim() || 'unknown/unknown',
  resolveOwner: ({ options }) => String(options.owner || '').trim() || defaultOwner(),
  acquireLease: (leaseOptions) => acquireWriterLease(leaseOptions),
  releaseLease: (leaseOptions) => releaseWriterLease(leaseOptions),
  planStep: (context) => planCompareviRuntimeStep(context),
  prepareWorker: (context) => prepareCompareviWorkerCheckout(context),
  bootstrapWorker: (context) => bootstrapCompareviWorkerCheckout(context),
  activateWorker: (context) => activateCompareviWorkerLane(context),
  buildTaskPacket: (context) => buildCompareviTaskPacket(context),
  executeTurn: (context) => executeCompareviTurn(context)
});

export const compareviRuntimeTest = {
  activateCompareviWorkerLane,
  buildSchedulerDecisionFromSnapshot,
  buildCompareviTaskPacket,
  buildTemplateAgentVerificationReportRefreshOptions,
  bootstrapCompareviWorkerCheckout,
  executeCompareviTurn,
  isCadenceAlertIssue,
  isPathWithin: workerCheckoutTest.isPathWithin,
  parseIssueRows,
  planCompareviRuntimeStep,
  planCompareviRuntimeStepFromLiveStanding,
  prepareCompareviWorkerCheckout,
  repairRegisteredWorktreeGitPointers,
  resolveCompareviIssueBranchName,
  resolveCompareviWorkerCheckoutLocation,
  resolveCompareviWorkerCheckoutPath,
  resolveForkRemoteForRepository
};

export async function runRuntimeSupervisor(options = {}, deps = {}) {
  return runCoreRuntimeSupervisor(options, {
    ...deps,
    adapter: deps.adapter ?? compareviRuntimeAdapter
  });
}

export async function runCli(argv = process.argv, deps = {}) {
  return runCoreCli(argv, {
    ...deps,
    adapter: deps.adapter ?? compareviRuntimeAdapter
  });
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await runCli(process.argv);
    process.exit(exitCode);
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify(
        {
          schema: REPORT_SCHEMA,
          action: 'error',
          status: 'error',
          message: error?.message || String(error)
        },
        null,
        2
      )}\n`
    );
    process.exit(1);
  }
}

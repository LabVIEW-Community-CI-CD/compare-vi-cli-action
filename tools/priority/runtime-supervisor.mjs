
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
  __test as workerCheckoutTest,
  bootstrapCompareviWorkerCheckout,
  activateCompareviWorkerLane,
  prepareCompareviWorkerCheckout,
  repairRegisteredWorktreeGitPointers,
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
  buildLocalReviewLoopRequest,
  buildCanonicalDeliveryDecision,
  buildWorkerPoolPolicySnapshot,
  DELIVERY_AGENT_POLICY_RELATIVE_PATH,
  fetchIssueExecutionGraph,
  loadDeliveryAgentPolicy,
  persistDeliveryAgentRuntimeState
} from './delivery-agent.mjs';

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

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
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
        return buildCanonicalDeliveryDecision({
          repoRoot,
          issueSnapshot: snapshotWithRepo,
          issueGraph,
          upstreamRepository,
          targetRepository,
          policy: deliveryPolicy,
          source: 'comparevi-standing-priority-live',
          deps
        });
      } catch {
        // Fall back to snapshot-only scheduling when the live execution graph
        // cannot be resolved in this cycle.
      }
    }
    return buildSchedulerDecisionFromSnapshot({
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
    return {
      source: 'comparevi-standing-priority-live',
      outcome: 'idle',
      reason: classification.message,
      artifacts: {
        liveRepository: targetRepository,
        noStandingReason: classification.reason,
        openIssueCount: classification.openIssueCount,
        standingLabels: standingPriorityLabels
      }
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
    return buildSchedulerDecisionFromSnapshot({
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
  return buildSchedulerDecisionFromSnapshot({
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
  const laneLifecycle = normalizeText(artifacts.laneLifecycle) || (activeLane?.prUrl ? 'waiting-ci' : 'coding');
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
        planeTransition,
        localReviewLoop,
        workerPool,
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
          path.join(repoRoot, 'tools', 'priority', 'docker-desktop-review-loop.mjs'),
          path.join(repoRoot, 'tools', 'Run-NonLVChecksInDocker.ps1')
        ]
      }
    }
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
  return persistDeliveryAgentRuntimeState({
    repoRoot,
    runtimeDir: runtimeArtifactPaths.runtimeDir,
    repository,
    policy: deliveryPolicy,
    schedulerDecision,
    taskPacket,
    executionReceipt,
    now
  });
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

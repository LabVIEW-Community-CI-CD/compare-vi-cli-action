#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { handoffStandingPriority } from './standing-priority-handoff.mjs';
import {
  resolveStandingPriorityLabels,
  selectAutoStandingPriorityCandidate
} from './sync-standing-priority.mjs';

export const DELIVERY_AGENT_POLICY_SCHEMA = 'priority/delivery-agent-policy@v1';
export const DELIVERY_AGENT_RUNTIME_STATE_SCHEMA = 'priority/delivery-agent-runtime-state@v1';
export const DELIVERY_AGENT_LANE_STATE_SCHEMA = 'priority/delivery-agent-lane-state@v1';
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

const DEFAULT_POLICY = {
  schema: DELIVERY_AGENT_POLICY_SCHEMA,
  backlogAuthority: 'issues',
  implementationRemote: 'origin',
  autoSlice: true,
  autoMerge: true,
  maxActiveCodingLanes: 1,
  allowPolicyMutations: false,
  allowReleaseAdmin: false,
  stopWhenNoOpenEpics: true,
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
const COPILOT_REVIEW_METADATA_CACHE_TTL_MS = 60 * 1000;
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

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

function normalizeCommandList(value) {
  return Array.isArray(value) ? value.map((entry) => normalizeText(entry)).filter(Boolean) : [];
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

function resolveIssueBranchName({ issueNumber, title, implementationRemote = 'origin', branchPrefix = 'issue' }) {
  const slug = normalizeText(title)
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^A-Za-z0-9]+/g, ' ')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .toLowerCase()
    .replace(/^-+|-+$/g, '') || 'work';
  const remotePrefix = normalizeText(implementationRemote) ? `${normalizeText(implementationRemote).toLowerCase()}-` : '';
  return `${branchPrefix}/${remotePrefix}${issueNumber}-${slug}`;
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
  const hasActionableCurrentHeadComments = (copilotReviewSignal?.actionableCommentCount ?? 0) > 0;
  const reviewPendingFromSignal =
    (copilotReviewSignal != null &&
      (copilotReviewSignal.hasCurrentHeadReview !== true || hasActionableCurrentHeadComments)) ||
    (copilotReviewSignal == null &&
      copilotReviewWorkflow != null &&
      (PENDING_WORKFLOW_RUN_STATUSES.has(copilotReviewWorkflowStatus) ||
        (copilotReviewWorkflowStatus === 'COMPLETED' && copilotReviewWorkflowConclusion === 'SUCCESS')));
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

  if (hasActionableCurrentHeadComments) {
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
function selectCanonicalCandidate({ issueGraph, implementationRemote }) {
  const standingIssue = issueGraph?.standingIssue ?? null;
  if (!standingIssue) {
    return null;
  }

  const openStandingPullRequests = collectPullRequestCandidates(standingIssue, standingIssue.epic === true ? standingIssue.number : null);
  const openChildIssues = Array.isArray(issueGraph?.subIssues)
    ? issueGraph.subIssues.filter((issue) => normalizeText(issue.state) === 'OPEN')
    : [];
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

  if (prCandidates.length > 0) {
    const selected = prCandidates[0];
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
          implementationRemote
        })
    };
  }

  if (openChildIssues.length > 0) {
    const selectedChild = selectBestIssueCandidate(openChildIssues);
    return {
      actionType: 'advance-child-issue',
      laneLifecycle: 'coding',
      selectedIssue: selectedChild,
      epicNumber: standingIssue.epic === true ? standingIssue.number : null,
      pullRequest: null,
      pullRequestStatus: null,
      branch: resolveIssueBranchName({
        issueNumber: selectedChild.number,
        title: selectedChild.title,
        implementationRemote
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
        implementationRemote
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
      implementationRemote
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
  return {
    ...DEFAULT_POLICY,
    ...(filePolicy && typeof filePolicy === 'object' ? filePolicy : {}),
    schema: DELIVERY_AGENT_POLICY_SCHEMA,
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
    implementationRemote
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
        ? `standing epic #${standingIssue.number} selects child issue #${selectedIssue.number}`
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
            }
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
        const cached = await readJsonIfPresent(entryPath);
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
  const cached = await readJsonIfPresent(cachePath);
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
  await writeFile(
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
export function buildDeliveryAgentRuntimeRecord({
  now = new Date(),
  repository,
  runtimeDir,
  policy,
  schedulerDecision,
  taskPacket,
  executionReceipt,
  statePath,
  lanePath
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
  return {
    schema: DELIVERY_AGENT_RUNTIME_STATE_SCHEMA,
    generatedAt: toIso(now),
    repository,
    runtimeDir,
    policy: {
      schema: DELIVERY_AGENT_POLICY_SCHEMA,
      backlogAuthority: policy.backlogAuthority,
      implementationRemote: policy.implementationRemote,
      autoSlice: policy.autoSlice === true,
      autoMerge: policy.autoMerge === true,
      maxActiveCodingLanes: policy.maxActiveCodingLanes,
      allowPolicyMutations: policy.allowPolicyMutations === true,
      allowReleaseAdmin: policy.allowReleaseAdmin === true,
      stopWhenNoOpenEpics: policy.stopWhenNoOpenEpics === true
    },
    status: laneLifecycle === 'blocked' ? 'blocked' : laneLifecycle === 'idle' ? 'idle' : 'running',
    laneLifecycle,
    activeCodingLanes,
    activeLane: {
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
      pollIntervalSecondsHint,
      reviewMonitor
    },
    artifacts: {
      statePath,
      lanePath
    }
  };
}

export async function persistDeliveryAgentRuntimeState({
  runtimeDir,
  repository,
  policy,
  schedulerDecision,
  taskPacket,
  executionReceipt,
  now = new Date()
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
  const payload = buildDeliveryAgentRuntimeRecord({
    now,
    repository,
    runtimeDir,
    policy,
    schedulerDecision,
    taskPacket,
    executionReceipt,
    statePath,
    lanePath
  });
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
    status: result.status ?? 0,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? ''
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

function buildMergedIssueCloseComment({ issueNumber, pullRequestNumber, pullRequestUrl, nextStandingIssueNumber }) {
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
  if (standingIssueNumber && standingIssueNumber === selectedIssueNumber) {
    const openIssues = await listOpenIssues({ repository, repoRoot, deps });
    const nextCandidate = selectAutoStandingPriorityCandidate(openIssues, {
      excludeIssueNumbers: [standingIssueNumber]
    });
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
      helperCallsExecuted.push('node tools/priority/standing-priority-handoff.mjs --auto');
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

  await closeIssueWithComment({
    repository,
    issueNumber: selectedIssueNumber,
    repoRoot,
    comment: buildMergedIssueCloseComment({
      issueNumber: selectedIssueNumber,
      pullRequestNumber,
      pullRequestUrl: normalizeText(pullRequest?.url) || null,
      nextStandingIssueNumber
    }),
    deps
  });
  helperCallsExecuted.push(buildCloseIssueHelperCall(selectedIssueNumber, repository, { hasComment: true }));

  return {
    selectedIssueNumber,
    standingIssueNumber,
    nextStandingIssueNumber,
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
        const upstreamFetchResult = await runCommand(
          'git',
          ['fetch', 'upstream', baseRefName],
          { cwd: executionRoot, env: process.env },
          deps
        );
        helperCallsExecuted.push(`git fetch upstream ${baseRefName}`);
        if (upstreamFetchResult.status !== 0) {
          const upstreamFetchMessage =
            normalizeText(upstreamFetchResult.stderr) ||
            normalizeText(upstreamFetchResult.stdout) ||
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
    return deps.invokeCodingTurnFn({ taskPacket, policy, repoRoot, executionRoot, policyPath });
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
    const env = {
      ...process.env,
      COMPAREVI_DELIVERY_TASK_PACKET_PATH: taskPacket.__taskPacketPath || '',
      COMPAREVI_DELIVERY_RECEIPT_PATH: receiptPath,
      COMPAREVI_DELIVERY_POLICY_PATH: policyPath || '',
      COMPAREVI_DELIVERY_REPO_ROOT: executionRoot,
      COMPAREVI_DELIVERY_CONTROL_ROOT: repoRoot
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
      return {
        ...fileReceipt,
        source: normalizeText(fileReceipt.source) || 'delivery-agent-broker',
        details: {
          ...(fileReceipt.details && typeof fileReceipt.details === 'object' ? fileReceipt.details : {}),
          helperCallsExecuted: [command.join(' '), ...(Array.isArray(fileReceipt.details?.helperCallsExecuted) ? fileReceipt.details.helperCallsExecuted : [])],
          laneLifecycle: normalizeLifecycle(fileReceipt.details?.laneLifecycle, 'coding')
        }
      };
    }
    try {
      const stdoutReceipt = JSON.parse(result.stdout);
      if (stdoutReceipt && typeof stdoutReceipt === 'object') {
        return {
          ...stdoutReceipt,
          source: normalizeText(stdoutReceipt.source) || 'delivery-agent-broker'
        };
      }
    } catch {
      // Ignore stdout parse failures and fall back to a generic success receipt.
    }
    return {
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
    };
  } finally {
    await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  }
}

export function planDeliveryBrokerAction(taskPacket = {}) {
  const delivery = taskPacket?.evidence?.delivery ?? {};
  const pullRequest = delivery.pullRequest ?? null;
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
    return {
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
    };
  }

  if (planned.actionType === 'watch-pr') {
    return {
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
        reviewMonitor:
          planned.laneLifecycle === 'waiting-review'
            ? planned.pullRequest?.copilotReviewWorkflow ?? null
            : null,
        helperCallsExecuted: [],
        filesTouched: []
      }
    };
  }

  if (planned.actionType === 'sync-pr-branch') {
    return updatePullRequestBranch({
      taskPacket: enrichedPacket,
      repoRoot,
      executionRoot,
      deps
    });
  }

  if (planned.actionType === 'merge-pr') {
    const mergeResult = await mergePullRequest({
      taskPacket: enrichedPacket,
      repoRoot,
      deps
    });
    if (mergeResult.status !== 'completed' || mergeResult.outcome !== 'merged') {
      return mergeResult;
    }

    try {
      const finalization = await finalizeMergedPullRequest({
        taskPacket: enrichedPacket,
        repoRoot,
        deps
      });
      return {
        ...mergeResult,
        reason:
          finalization.selectedIssueNumber && finalization.nextStandingIssueNumber
            ? `Merged PR and closed issue #${finalization.selectedIssueNumber}; standing priority advanced to #${finalization.nextStandingIssueNumber}.`
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
          nextStandingIssueNumber: finalization.nextStandingIssueNumber ?? null
        }
      };
    } catch (error) {
      return {
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
      };
    }
  }

  if (planned.actionType === 'reshape-backlog') {
    if (policy.autoSlice !== true) {
      return {
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
      };
    }
    return autoSliceIssue({
      taskPacket: enrichedPacket,
      repoRoot,
      deps,
      now
    });
  }

  return invokeCodingTurnCommand({
    taskPacket: enrichedPacket,
    policy,
    repoRoot,
    executionRoot,
    policyPath: effectivePolicyPath,
    deps
  });
}

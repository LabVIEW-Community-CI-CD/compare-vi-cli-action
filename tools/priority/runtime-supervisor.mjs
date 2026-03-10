#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
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
  parseArgs,
  runCli as runCoreCli,
  runRuntimeSupervisor as runCoreRuntimeSupervisor
} from '../../packages/runtime-harness/index.mjs';
import { acquireWriterLease, defaultOwner, releaseWriterLease } from './agent-writer-lease.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';
import {
  bootstrapCompareviWorkerCheckout,
  activateCompareviWorkerLane,
  prepareCompareviWorkerCheckout,
  resolveCompareviWorkerCheckoutPath
} from './runtime-worker-checkout.mjs';

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
  __test,
  createRuntimeAdapter,
  parseArgs
};

const COMPAREVI_UPSTREAM_REPOSITORY = 'LabVIEW-Community-CI-CD/compare-vi-cli-action';
const PRIORITY_CACHE_FILENAME = '.agent_priority_cache.json';
const PRIORITY_ISSUE_DIR = path.join('tests', 'results', '_agent', 'issue');
const COMPAREVI_PREFERRED_HELPERS = [
  'pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1',
  'node tools/npm/run-script.mjs priority:develop:sync',
  'node tools/npm/run-script.mjs priority:github:metadata:apply',
  'node tools/npm/run-script.mjs priority:project:portfolio:apply',
  'node tools/npm/run-script.mjs priority:pr'
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

function resolveCompareviIssueBranchName({ issueNumber, title, forkRemote, branchPrefix = 'issue' }) {
  const slug = resolveCompareviIssueSlug(title);
  const remotePrefix = normalizeText(forkRemote) ? `${normalizeText(forkRemote).toLowerCase()}-` : '';
  return `${branchPrefix}/${remotePrefix}${issueNumber}-${slug}`;
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

function resolveForkRemoteForRepository(repository, upstreamRepository) {
  const normalizedRepository = normalizeText(repository);
  const normalizedUpstream = normalizeText(upstreamRepository) || COMPAREVI_UPSTREAM_REPOSITORY;
  if (!normalizedRepository || !normalizedUpstream) return null;
  if (normalizedRepository === normalizedUpstream) return 'upstream';

  const [upstreamOwner] = normalizedUpstream.split('/');
  const [repositoryOwner] = normalizedRepository.split('/');
  return repositoryOwner === upstreamOwner ? 'origin' : 'personal';
}

function buildSchedulerDecisionFromSnapshot({
  snapshot,
  upstreamRepository,
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

  const forkRemote = resolveForkRemoteForRepository(standingRepository, upstreamRepository);
  const laneId = [forkRemote, selectedIssue].filter(Boolean).join('-') || `issue-${selectedIssue}`;
  const branch = resolveCompareviIssueBranchName({
    issueNumber: selectedIssue,
    title: snapshot.title,
    forkRemote
  });
  const reason =
    Number.isInteger(snapshot.mirrorOf?.number) && snapshot.mirrorOf.number !== snapshot.number
      ? `standing mirror #${snapshot.number} routes to upstream issue #${snapshot.mirrorOf.number}`
      : `standing issue #${selectedIssue}`;

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
    artifacts: artifactPaths
  };
}

async function planCompareviRuntimeStep({ repoRoot, env, explicitStepOptions }) {
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
  const cachePath = path.join(repoRoot, PRIORITY_CACHE_FILENAME);
  const cacheSnapshot = await readJsonIfPresent(cachePath);
  if (cacheSnapshot) {
    return buildSchedulerDecisionFromSnapshot({
      snapshot: cacheSnapshot,
      upstreamRepository,
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
    upstreamRepository,
    source: 'comparevi-standing-priority-router',
    artifactPaths: {
      routerPath,
      issuePath
    }
  });
}

async function resolveCompareviTaskPacketSnapshot({ repoRoot, schedulerDecision }) {
  const artifactPaths = schedulerDecision?.artifacts ?? {};
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

async function buildCompareviTaskPacket({ repoRoot, schedulerDecision, preparedWorker, workerReady, workerBranch }) {
  const activeLane = schedulerDecision?.activeLane ?? null;
  const snapshot = await resolveCompareviTaskPacketSnapshot({ repoRoot, schedulerDecision });
  const issueNumber = activeLane?.issue;
  const issueTitle = normalizeText(snapshot?.title);
  const branchName = normalizeText(workerBranch?.branch) || normalizeText(activeLane?.branch);
  const objectiveSummary = Number.isInteger(issueNumber)
    ? `Advance issue #${issueNumber}${issueTitle ? `: ${issueTitle}` : ''}${branchName ? ` on ${branchName}` : ''}`
    : normalizeText(schedulerDecision?.reason) || 'No compare-vi lane selected.';

  return {
    source: 'comparevi-runtime',
    objective: {
      summary: objectiveSummary,
      source: issueTitle ? 'comparevi-issue-snapshot' : 'comparevi-runtime'
    },
    pullRequest: {
      url: normalizeText(activeLane?.prUrl) || null,
      status: normalizeText(activeLane?.prUrl) ? 'linked' : 'none'
    },
    checks: {
      status: activeLane?.blockerClass === 'ci' ? 'blocked' : normalizeText(activeLane?.prUrl) ? 'pending-or-unknown' : 'not-linked',
      blockerClass: normalizeText(activeLane?.blockerClass) || 'none'
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
        workerCheckoutPath:
          normalizeText(workerBranch?.checkoutPath) ||
          normalizeText(workerReady?.checkoutPath) ||
          normalizeText(preparedWorker?.checkoutPath) ||
          null
      }
    }
  };
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
  buildTaskPacket: (context) => buildCompareviTaskPacket(context)
});

export const compareviRuntimeTest = {
  activateCompareviWorkerLane,
  buildSchedulerDecisionFromSnapshot,
  buildCompareviTaskPacket,
  bootstrapCompareviWorkerCheckout,
  planCompareviRuntimeStep,
  prepareCompareviWorkerCheckout,
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

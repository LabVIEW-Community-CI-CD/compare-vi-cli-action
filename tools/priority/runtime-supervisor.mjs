#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
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
  TURN_SCHEMA,
  WORKER_CHECKOUT_SCHEMA,
  __test,
  createRuntimeAdapter,
  parseArgs
};

const COMPAREVI_UPSTREAM_REPOSITORY = 'LabVIEW-Community-CI-CD/compare-vi-cli-action';
const PRIORITY_CACHE_FILENAME = '.agent_priority_cache.json';
const PRIORITY_ISSUE_DIR = path.join('tests', 'results', '_agent', 'issue');

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
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
      forkRemote
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

export const compareviRuntimeAdapter = createRuntimeAdapter({
  name: 'comparevi',
  resolveRepoRoot: () => getRepoRoot(),
  resolveRepository: ({ options, env }) => String(options.repo || env.GITHUB_REPOSITORY || '').trim() || 'unknown/unknown',
  resolveOwner: ({ options }) => String(options.owner || '').trim() || defaultOwner(),
  acquireLease: (leaseOptions) => acquireWriterLease(leaseOptions),
  releaseLease: (leaseOptions) => releaseWriterLease(leaseOptions),
  planStep: (context) => planCompareviRuntimeStep(context),
  prepareWorker: (context) => prepareCompareviWorkerCheckout(context)
});

export const compareviRuntimeTest = {
  buildSchedulerDecisionFromSnapshot,
  planCompareviRuntimeStep,
  prepareCompareviWorkerCheckout,
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

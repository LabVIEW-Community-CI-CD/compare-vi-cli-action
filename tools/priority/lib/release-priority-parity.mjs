#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { createSnapshot, fetchIssue } from '../sync-standing-priority.mjs';
import { collectParity } from '../report-origin-upstream-parity.mjs';

const STANDING_PRIORITY_LABELS = new Set(['standing-priority', 'fork-standing-priority']);

function readJsonFile(repoRoot, relativePath, label) {
  const fullPath = path.join(repoRoot, relativePath);
  if (!existsSync(fullPath)) {
    throw new Error(`${label} is missing: ${relativePath}`);
  }

  try {
    return JSON.parse(readFileSync(fullPath, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON (${relativePath}): ${error.message}`);
  }
}

function normalizeLabels(labels) {
  if (!Array.isArray(labels)) return [];
  return labels
    .map((label) => {
      if (label == null) return null;
      return String(label).trim().toLowerCase();
    })
    .filter(Boolean);
}

function assertStandingPriorityLabels(labels, sourceLabel) {
  if (labels.some((label) => STANDING_PRIORITY_LABELS.has(label))) {
    return;
  }
  throw new Error(
    `${sourceLabel} must include one of: ${Array.from(STANDING_PRIORITY_LABELS).join(', ')}.`
  );
}

function parsePriorityIssueNumber(cache) {
  const number = Number(cache?.number);
  if (!Number.isInteger(number) || number <= 0) {
    throw new Error('Standing-priority cache is missing a valid issue number.');
  }
  return number;
}

export async function collectStandingPrioritySyncEvidence(
  repoRoot,
  {
    cacheRelativePath = '.agent_priority_cache.json',
    routerRelativePath = path.join('tests', 'results', '_agent', 'issue', 'router.json'),
    issueDirRelativePath = path.join('tests', 'results', '_agent', 'issue'),
    fetchIssueFn = fetchIssue,
    createSnapshotFn = createSnapshot
  } = {}
) {
  const cache = readJsonFile(repoRoot, cacheRelativePath, 'Standing-priority cache');
  const issueNumber = parsePriorityIssueNumber(cache);
  const cacheState = String(cache?.state ?? '').toUpperCase();
  if (cacheState !== 'OPEN') {
    throw new Error(`Standing-priority cache issue #${issueNumber} must be OPEN (actual: ${cache?.state ?? 'missing'}).`);
  }

  const cacheLabels = normalizeLabels(cache?.labels);
  assertStandingPriorityLabels(cacheLabels, `Standing-priority cache issue #${issueNumber}`);

  const issueDigest = String(cache?.issueDigest ?? '').trim();
  if (!issueDigest) {
    throw new Error(`Standing-priority cache issue #${issueNumber} is missing issueDigest.`);
  }

  const router = readJsonFile(repoRoot, routerRelativePath, 'Standing-priority router');
  if (Number(router?.issue) !== issueNumber) {
    throw new Error(
      `Standing-priority router issue mismatch: router=${router?.issue ?? 'missing'} cache=${issueNumber}.`
    );
  }

  const snapshotRelativePath = path.join(issueDirRelativePath, `${issueNumber}.json`);
  const snapshot = readJsonFile(repoRoot, snapshotRelativePath, 'Standing-priority snapshot');
  if (Number(snapshot?.number) !== issueNumber) {
    throw new Error(
      `Standing-priority snapshot issue mismatch: snapshot=${snapshot?.number ?? 'missing'} cache=${issueNumber}.`
    );
  }
  if (String(snapshot?.digest ?? '').trim() !== issueDigest) {
    throw new Error(
      `Standing-priority snapshot digest mismatch for issue #${issueNumber}; run node tools/npm/run-script.mjs priority:sync.`
    );
  }

  const repository = typeof cache?.repository === 'string' && cache.repository.trim() ? cache.repository.trim() : null;
  const liveIssue = await fetchIssueFn(issueNumber, repoRoot, repository);
  const liveSnapshot = createSnapshotFn(liveIssue);
  const liveState = String(liveSnapshot?.state ?? '').toUpperCase();
  if (liveState !== 'OPEN') {
    throw new Error(`Standing-priority issue #${issueNumber} must be OPEN before finalize (actual: ${liveSnapshot?.state ?? 'missing'}).`);
  }

  const liveLabels = normalizeLabels(liveSnapshot?.labels);
  assertStandingPriorityLabels(liveLabels, `Standing-priority issue #${issueNumber}`);

  if (String(liveSnapshot?.digest ?? '').trim() !== issueDigest) {
    throw new Error(
      `Standing-priority artifacts are stale for issue #${issueNumber}; run node tools/npm/run-script.mjs priority:sync before finalize.`
    );
  }

  return {
    issue: issueNumber,
    repository,
    digest: issueDigest,
    cachedAtUtc: cache?.cachedAtUtc ?? null,
    files: {
      cache: cacheRelativePath.replace(/\\/g, '/'),
      router: routerRelativePath.replace(/\\/g, '/'),
      snapshot: snapshotRelativePath.replace(/\\/g, '/')
    }
  };
}

export function collectOriginUpstreamParityEvidence(
  {
    baseRef = 'upstream/develop',
    headRef = 'origin/develop',
    tipDiffTarget = 0,
    collectParityFn = collectParity
  } = {}
) {
  const target = Number(tipDiffTarget);
  if (!Number.isInteger(target) || target < 0) {
    throw new Error(`Invalid parity tip-diff target: ${tipDiffTarget}`);
  }

  const parity = collectParityFn({
    baseRef,
    headRef,
    strict: true
  });

  if (!parity || parity.status !== 'ok') {
    throw new Error(`Unable to evaluate origin/upstream parity (${baseRef} vs ${headRef}).`);
  }

  const observedCount = Number(parity?.tipDiff?.fileCount ?? NaN);
  if (!Number.isInteger(observedCount) || observedCount !== target) {
    throw new Error(
      `Origin/upstream parity KPI unmet: tipDiff.fileCount=${parity?.tipDiff?.fileCount ?? 'unknown'} target=${target}.`
    );
  }

  return {
    status: parity.status,
    baseRef: parity.baseRef,
    headRef: parity.headRef,
    tipDiff: {
      fileCount: observedCount,
      target
    },
    treeParity: {
      status: parity?.treeParity?.status ?? null,
      equal: Boolean(parity?.treeParity?.equal)
    },
    historyParity: {
      status: parity?.historyParity?.status ?? null,
      equal: Boolean(parity?.historyParity?.equal),
      baseOnly: Number(parity?.historyParity?.baseOnly ?? 0),
      headOnly: Number(parity?.historyParity?.headOnly ?? 0)
    },
    recommendation: parity?.recommendation
      ? {
          code: parity.recommendation.code ?? null,
          summary: parity.recommendation.summary ?? null
        }
      : null
  };
}

export async function collectStandingPriorityParityGate(
  repoRoot,
  {
    baseRef = 'upstream/develop',
    headRef = 'origin/develop',
    tipDiffTarget = 0,
    fetchIssueFn = fetchIssue,
    createSnapshotFn = createSnapshot,
    collectParityFn = collectParity
  } = {}
) {
  const prioritySync = await collectStandingPrioritySyncEvidence(repoRoot, {
    fetchIssueFn,
    createSnapshotFn
  });
  const parity = collectOriginUpstreamParityEvidence({
    baseRef,
    headRef,
    tipDiffTarget,
    collectParityFn
  });

  return {
    skipped: false,
    standingPriority: prioritySync,
    parity
  };
}

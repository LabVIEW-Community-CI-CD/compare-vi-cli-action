#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import path from 'node:path';

function contextAliases(context) {
  const normalized = String(context ?? '').trim();
  if (!normalized) {
    return [];
  }
  const aliases = new Set([normalized.toLowerCase()]);
  const divider = ' / ';
  const idx = normalized.indexOf(divider);
  if (idx !== -1) {
    const suffix = normalized.slice(idx + divider.length).trim();
    if (suffix) {
      aliases.add(suffix.toLowerCase());
    }
  }
  return [...aliases];
}

function contextsMatch(requiredContext, actualContext) {
  const requiredAliases = contextAliases(requiredContext);
  const actualAliases = contextAliases(actualContext);
  return requiredAliases.some((alias) => actualAliases.includes(alias));
}

function scoreMatchingCheck(check) {
  const status = String(check?.status ?? '')
    .trim()
    .toUpperCase();
  const conclusion = String(check?.conclusion ?? '')
    .trim()
    .toUpperCase();

  if (status === 'COMPLETED' && conclusion === 'SUCCESS') {
    return 400;
  }
  if (status === 'COMPLETED' && conclusion && conclusion !== 'SUCCESS') {
    return 300;
  }
  if (status === 'IN_PROGRESS') {
    return 200;
  }
  if (status === 'QUEUED') {
    return 100;
  }
  return 0;
}

function selectBestMatchingCheck(requiredContext, checks = []) {
  const matches = (Array.isArray(checks) ? checks : []).filter((check) =>
    contextsMatch(requiredContext, check?.name)
  );
  if (matches.length === 0) {
    return null;
  }

  return matches
    .map((check, index) => ({
      check,
      index,
      score: scoreMatchingCheck(check)
    }))
    .sort((left, right) => {
      if (right.score !== left.score) {
        return right.score - left.score;
      }
      return left.index - right.index;
    })[0].check;
}

export function loadReleaseRequiredChecks(
  repoRoot,
  policyRelativePath = path.join('tools', 'policy', 'branch-required-checks.json')
) {
  const policyPath = path.join(repoRoot, policyRelativePath);
  let policy = null;
  try {
    policy = JSON.parse(readFileSync(policyPath, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to read required-check policy at ${policyPath}: ${error.message}`);
  }

  const required = policy?.branches?.['release/*'];
  if (!Array.isArray(required) || required.length === 0) {
    throw new Error(`Required-check policy is missing branches["release/*"] in ${policyPath}.`);
  }
  return [...new Set(required.map((item) => String(item ?? '').trim()).filter(Boolean))];
}

export function evaluateRequiredReleaseChecks(requiredChecks, statusCheckRollup = []) {
  const checks = Array.isArray(statusCheckRollup) ? statusCheckRollup : [];
  const missing = [];
  const unresolved = [];

  for (const required of requiredChecks) {
    const match = selectBestMatchingCheck(required, checks);
    if (!match) {
      missing.push(required);
      continue;
    }
    const status = String(match.status ?? '').toUpperCase();
    const conclusion = String(match.conclusion ?? '').toUpperCase();
    if (status !== 'COMPLETED' || conclusion !== 'SUCCESS') {
      unresolved.push({
        context: required,
        observedName: match.name ?? null,
        status: match.status ?? null,
        conclusion: match.conclusion ?? null
      });
    }
  }

  return { missing, unresolved };
}

export function assertRequiredReleaseChecksClean(requiredChecks, statusCheckRollup = []) {
  const evaluation = evaluateRequiredReleaseChecks(requiredChecks, statusCheckRollup);
  if (evaluation.missing.length === 0 && evaluation.unresolved.length === 0) {
    return evaluation;
  }

  const parts = [];
  if (evaluation.missing.length > 0) {
    parts.push(`missing contexts: ${evaluation.missing.join(', ')}`);
  }
  if (evaluation.unresolved.length > 0) {
    const details = evaluation.unresolved
      .map((entry) => `${entry.context} (${entry.status ?? 'unknown'}/${entry.conclusion ?? 'unknown'})`)
      .join(', ');
    parts.push(`unresolved contexts: ${details}`);
  }

  throw new Error(`Release PR required checks are not satisfied: ${parts.join('; ')}`);
}

const BLOCKING_RELEASE_MERGE_STATES = new Set(['DIRTY', 'BEHIND', 'UNKNOWN', 'UNSTABLE']);
const BLOCKING_RELEASE_MERGEABLE_STATES = new Set(['CONFLICTING', 'UNMERGEABLE']);

export function evaluateReleasePrMergeReadiness(prView = {}, { allowDirty = false } = {}) {
  const mergeStateStatus = String(prView?.mergeStateStatus ?? '')
    .trim()
    .toUpperCase();
  const mergeable = String(prView?.mergeable ?? '')
    .trim()
    .toUpperCase();

  if (allowDirty) {
    return {
      allowed: true,
      mergeStateStatus: mergeStateStatus || null,
      mergeable: mergeable || null,
      reason: 'allow-dirty-override'
    };
  }

  if (BLOCKING_RELEASE_MERGEABLE_STATES.has(mergeable)) {
    return {
      allowed: false,
      mergeStateStatus: mergeStateStatus || null,
      mergeable,
      reason: `mergeable=${mergeable}`
    };
  }

  if (BLOCKING_RELEASE_MERGE_STATES.has(mergeStateStatus)) {
    return {
      allowed: false,
      mergeStateStatus,
      mergeable: mergeable || null,
      reason: `mergeStateStatus=${mergeStateStatus}`
    };
  }

  return {
    allowed: true,
    mergeStateStatus: mergeStateStatus || null,
    mergeable: mergeable || null,
    reason: null
  };
}

export function assertReleasePrMergeReady(prView = {}, { allowDirty = false } = {}) {
  const evaluation = evaluateReleasePrMergeReadiness(prView, { allowDirty });
  if (evaluation.allowed) {
    return evaluation;
  }

  throw new Error(
    `Release PR merge state is not admissible (${evaluation.reason}). Resolve the release branch topology/check state or set RELEASE_FINALIZE_ALLOW_DIRTY=1.`
  );
}

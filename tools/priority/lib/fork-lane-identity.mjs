#!/usr/bin/env node

function normalizeText(value) {
  return String(value ?? '').trim();
}

function toPositiveInteger(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    return null;
  }
  return parsed;
}

export function normalizeMirrorOfPointer(rawMirrorOf) {
  if (!rawMirrorOf || typeof rawMirrorOf !== 'object') {
    return null;
  }

  const issueNumber = toPositiveInteger(rawMirrorOf.number);
  const repository = normalizeText(rawMirrorOf.repository) || null;
  const issueUrl = normalizeText(rawMirrorOf.url) || null;
  if (!issueNumber && !repository && !issueUrl) {
    return null;
  }

  return {
    repository,
    issueNumber,
    issueUrl
  };
}

export function buildForkLaneIdentity({
  branch = null,
  issueSource = null,
  issueNumber = null,
  issueUrl = null,
  localIssueNumber = null,
  localIssueUrl = null,
  mirrorOf = null,
  forkRemote = null,
  forkRepository = null,
  upstreamRepository = null,
  dispatchRepository = null
} = {}) {
  const canonicalMirror = normalizeMirrorOfPointer(mirrorOf);
  const canonicalIssueNumber = canonicalMirror?.issueNumber ?? toPositiveInteger(issueNumber);
  const canonicalIssueUrl = canonicalMirror?.issueUrl ?? (normalizeText(issueUrl) || null);
  const canonicalRepository =
    canonicalMirror?.repository ||
    normalizeText(upstreamRepository) ||
    normalizeText(dispatchRepository) ||
    null;

  const normalizedForkRemote = normalizeText(forkRemote) || null;
  const normalizedDispatchRepository = normalizeText(dispatchRepository) || null;
  const normalizedForkRepository =
    normalizeText(forkRepository) ||
    (
      normalizedDispatchRepository &&
      canonicalRepository &&
      normalizedDispatchRepository !== canonicalRepository
        ? normalizedDispatchRepository
        : null
    );
  const normalizedLocalIssueNumber = toPositiveInteger(localIssueNumber);
  const normalizedLocalIssueUrl = normalizeText(localIssueUrl) || null;

  const hasForkContext = Boolean(normalizedForkRemote || normalizedForkRepository);
  const hasForkIssue =
    Boolean(normalizedForkRepository) &&
    Boolean(normalizedLocalIssueNumber) &&
    normalizedLocalIssueNumber !== canonicalIssueNumber;

  return {
    kind: hasForkIssue
      ? 'fork-standing-mirror'
      : hasForkContext
        ? 'fork-plane-branch'
        : 'upstream-standing',
    branch: normalizeText(branch) || null,
    issueSource: normalizeText(issueSource) || null,
    forkContext: hasForkContext
      ? {
          remote: normalizedForkRemote,
          repository: normalizedForkRepository
        }
      : null,
    canonicalIssue: canonicalIssueNumber || canonicalRepository || canonicalIssueUrl
      ? {
          repository: canonicalRepository,
          issueNumber: canonicalIssueNumber,
          issueUrl: canonicalIssueUrl
        }
      : null,
    forkIssue: hasForkIssue
      ? {
          repository: normalizedForkRepository,
          issueNumber: normalizedLocalIssueNumber,
          issueUrl: normalizedLocalIssueUrl
        }
      : null,
    mirrorOf: canonicalMirror
  };
}


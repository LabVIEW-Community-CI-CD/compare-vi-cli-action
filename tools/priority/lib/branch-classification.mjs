#!/usr/bin/env node

import path from 'node:path';
import { readFileSync } from 'node:fs';

export const DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH = path.join('tools', 'policy', 'branch-classes.json');

export function normalizeBranchName(value) {
  const raw = String(value ?? '').trim();
  if (!raw) {
    return '';
  }
  const lowered = raw.toLowerCase();
  return lowered.startsWith('refs/heads/') ? lowered.slice('refs/heads/'.length) : lowered;
}

export function normalizeRepositoryRole(value) {
  const normalized = String(value ?? '').trim().toLowerCase();
  if (!normalized) {
    return '';
  }
  if (normalized !== 'upstream' && normalized !== 'fork') {
    throw new Error(`Unsupported repository role '${value}'. Expected upstream or fork.`);
  }
  return normalized;
}

export function normalizeRepositoryPlane(value) {
  const normalized = String(value ?? '').trim().toLowerCase();
  if (!normalized) {
    return '';
  }
  if (!['upstream', 'origin', 'personal', 'fork'].includes(normalized)) {
    throw new Error(`Unsupported repository plane '${value}'. Expected upstream, origin, personal, or fork.`);
  }
  return normalized;
}

function normalizeRepositorySlug(value) {
  return String(value ?? '').trim().toLowerCase();
}

function normalizeText(value) {
  return String(value ?? '').trim();
}

function escapeRegExp(value) {
  return String(value).replace(/[|\\{}()[\]^$+?.]/g, '\\$&');
}

export function branchPatternToRegExp(pattern) {
  const multiSentinel = '__DOUBLE_WILDCARD__';
  const singleSentinel = '__SINGLE_WILDCARD__';
  const normalized = String(pattern ?? '')
    .trim()
    .replace(/\*\*/g, multiSentinel)
    .replace(/\*/g, singleSentinel);
  const escaped = escapeRegExp(normalized);
  return new RegExp(
    `^${escaped
      .replace(new RegExp(multiSentinel, 'g'), '.*')
      .replace(new RegExp(singleSentinel, 'g'), '[^/]*')}$`,
    'i'
  );
}

export function matchBranchPattern(branch, pattern) {
  const normalizedBranch = normalizeBranchName(branch);
  const normalizedPattern = normalizeBranchName(pattern);
  if (!normalizedBranch || !normalizedPattern) {
    return false;
  }
  return branchPatternToRegExp(normalizedPattern).test(normalizedBranch);
}

function patternSpecificity(pattern) {
  const normalized = normalizeBranchName(pattern);
  const wildcardCount = (normalized.match(/\*/g) ?? []).length;
  return (normalized.length * 10) - wildcardCount;
}

export function loadBranchClassContract(
  repoRoot,
  {
    relativePath = DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH,
    readFileSyncFn = readFileSync
  } = {}
) {
  const contractPath = path.join(repoRoot, relativePath);
  const contract = JSON.parse(readFileSyncFn(contractPath, 'utf8'));
  if (contract?.schema !== 'branch-classes/v1') {
    throw new Error(`Unsupported branch class schema in ${contractPath}`);
  }
  if (!Array.isArray(contract.classes) || contract.classes.length === 0) {
    throw new Error(`Branch class contract in ${contractPath} does not define any classes.`);
  }
  if (!Array.isArray(contract.allowedTransitions) || contract.allowedTransitions.length === 0) {
    throw new Error(`Branch class contract in ${contractPath} does not define any transitions.`);
  }
  const normalizedUpstream = normalizeRepositorySlug(contract?.upstreamRepository);
  if (!normalizedUpstream) {
    throw new Error(
      `Branch class contract in ${contractPath} must define a non-empty upstreamRepository owner/repo slug.`
    );
  }
  if (!/^[^/]+\/[^/]+$/.test(normalizedUpstream)) {
    throw new Error(
      `Branch class contract in ${contractPath} has invalid upstreamRepository '${contract.upstreamRepository}'. Expected an owner/repo slug.`
    );
  }
  if (!Array.isArray(contract.repositoryPlanes) || contract.repositoryPlanes.length === 0) {
    throw new Error(`Branch class contract in ${contractPath} does not define any repositoryPlanes.`);
  }
  return contract;
}

export function resolveRepositoryPlane(repository, contract) {
  const normalizedRepository = normalizeRepositorySlug(repository);
  if (!normalizedRepository) {
    throw new Error('Repository slug is required to resolve branch plane.');
  }

  const upstreamRepository = normalizeRepositorySlug(contract?.upstreamRepository);
  if (normalizedRepository === upstreamRepository) {
    return 'upstream';
  }

  for (const plane of Array.isArray(contract?.repositoryPlanes) ? contract.repositoryPlanes : []) {
    const planeId = normalizeRepositoryPlane(plane?.id);
    const repositories = Array.isArray(plane?.repositories)
      ? plane.repositories.map((entry) => normalizeRepositorySlug(entry)).filter(Boolean)
      : [];
    if (repositories.includes(normalizedRepository)) {
      return planeId;
    }
  }

  return 'fork';
}

export function findRepositoryPlaneEntry(contract, planeOrRepository) {
  if (!contract || typeof contract !== 'object') {
    throw new Error('Branch class contract is required.');
  }

  const normalizedInput = String(planeOrRepository ?? '').trim().toLowerCase();
  if (normalizedInput.includes('/')) {
    const resolvedPlane = resolveRepositoryPlane(normalizedInput, contract);
    if (!resolvedPlane || resolvedPlane === 'fork') {
      return null;
    }
    return (Array.isArray(contract.repositoryPlanes) ? contract.repositoryPlanes : []).find(
      (entry) => normalizeRepositoryPlane(entry?.id) === resolvedPlane
    ) ?? null;
  }

  const normalizedPlane = normalizeRepositoryPlane(planeOrRepository);
  if (normalizedPlane !== 'fork') {
    return (Array.isArray(contract.repositoryPlanes) ? contract.repositoryPlanes : []).find(
      (entry) => normalizeRepositoryPlane(entry?.id) === normalizedPlane
    ) ?? null;
  }
  return null;
}

export function classifyPlaneTransition({
  fromPlane,
  toPlane,
  action,
  contract
}) {
  if (!contract || typeof contract !== 'object') {
    throw new Error('Branch class contract is required.');
  }
  const normalizedFrom = normalizeRepositoryPlane(fromPlane);
  const normalizedTo = normalizeRepositoryPlane(toPlane);
  const normalizedAction = String(action ?? '').trim();
  if (!normalizedAction) {
    throw new Error('Plane transition action is required.');
  }

  return (contract.planeTransitions || []).find((entry) => (
    normalizeRepositoryPlane(entry?.from) === normalizedFrom &&
    normalizeRepositoryPlane(entry?.to) === normalizedTo &&
    String(entry?.action ?? '').trim() === normalizedAction
  )) ?? null;
}

export function assertPlaneTransition({
  fromPlane,
  toPlane,
  action,
  contract
}) {
  const transition = classifyPlaneTransition({
    fromPlane,
    toPlane,
    action,
    contract
  });
  if (!transition) {
    throw new Error(
      `Plane transition ${normalizeRepositoryPlane(fromPlane)} --${String(action ?? '').trim()}--> ${normalizeRepositoryPlane(toPlane)} is not allowed by the branch class contract.`
    );
  }
  return transition;
}

export function resolveBranchPlaneTransition({
  branch,
  sourcePlane,
  targetRepository,
  contract,
  sourceRepository = null
}) {
  if (!contract || typeof contract !== 'object') {
    throw new Error('Branch class contract is required.');
  }

  const normalizedSourcePlane = normalizeRepositoryPlane(sourcePlane);
  const normalizedTargetRepository = normalizeRepositorySlug(targetRepository);
  if (!normalizedTargetRepository) {
    throw new Error('Target repository slug is required to resolve a branch plane transition.');
  }

  const targetPlane = resolveRepositoryPlane(normalizedTargetRepository, contract);
  if (normalizedSourcePlane === targetPlane) {
    return null;
  }

  const normalizedBranch = normalizeBranchName(branch);
  if (!normalizedBranch) {
    throw new Error(`Branch name is required to resolve plane transition ${normalizedSourcePlane}->${targetPlane}.`);
  }

  const resolvedSourceRepository =
    normalizeRepositorySlug(sourceRepository) ||
    normalizeRepositorySlug(
      normalizedSourcePlane === 'upstream'
        ? contract.upstreamRepository
        : findRepositoryPlaneEntry(contract, normalizedSourcePlane)?.repositories?.[0]
    ) ||
    null;
  const branchClassification = classifyBranch({
    branch: normalizedBranch,
    contract,
    repositoryRole: normalizedSourcePlane === 'upstream' ? 'upstream' : 'fork',
    repository: resolvedSourceRepository || normalizedTargetRepository
  });
  if (!branchClassification?.id) {
    throw new Error(
      `Unable to classify branch '${normalizedBranch}' for plane transition ${normalizedSourcePlane}->${targetPlane}.`
    );
  }

  const matches = (contract.planeTransitions || []).filter((entry) => (
    normalizeRepositoryPlane(entry?.from) === normalizedSourcePlane &&
    normalizeRepositoryPlane(entry?.to) === targetPlane &&
    normalizeText(entry?.branchClass) === branchClassification.id
  ));
  if (matches.length === 0) {
    throw new Error(
      `Plane transition ${normalizedSourcePlane}->${targetPlane} for branch class '${branchClassification.id}' is not allowed by the branch class contract.`
    );
  }
  if (matches.length > 1) {
    throw new Error(
      `Ambiguous plane transition ${normalizedSourcePlane}->${targetPlane} for branch class '${branchClassification.id}'.`
    );
  }

  const selected = matches[0];
  return {
    from: normalizedSourcePlane,
    to: targetPlane,
    action: normalizeText(selected.action),
    via: normalizeText(selected.via),
    branchClass: branchClassification.id,
    sourceRepository: resolvedSourceRepository,
    targetRepository: normalizedTargetRepository
  };
}

export function resolveLaneBranchPrefix({
  contract,
  repository = null,
  plane = null,
  fallbackPrefix = 'issue/'
}) {
  const planeEntry = findRepositoryPlaneEntry(contract, plane || repository);
  const configured = String(planeEntry?.laneBranchPrefix ?? '').trim();
  if (configured) {
    return configured.endsWith('/') || configured.endsWith('-') ? configured : `${configured}/`;
  }
  const normalizedFallback = String(fallbackPrefix ?? '').trim() || 'issue/';
  return normalizedFallback.endsWith('/') || normalizedFallback.endsWith('-')
    ? normalizedFallback
    : `${normalizedFallback}/`;
}

export function resolveRepositoryPlaneFromBranchName(branch, contract) {
  if (!contract || typeof contract !== 'object') {
    throw new Error('Branch class contract is required.');
  }

  const normalizedBranch = normalizeBranchName(branch);
  if (!normalizedBranch) {
    return null;
  }

  const matches = (Array.isArray(contract.repositoryPlanes) ? contract.repositoryPlanes : [])
    .map((entry) => ({
      plane: normalizeRepositoryPlane(entry?.id),
      prefix: normalizeBranchName(entry?.laneBranchPrefix)
    }))
    .filter((entry) => entry.prefix && normalizedBranch.startsWith(entry.prefix))
    .sort((left, right) => right.prefix.length - left.prefix.length);

  if (matches.length === 0) {
    return null;
  }

  if (matches.length > 1 && matches[0].prefix.length === matches[1].prefix.length) {
    throw new Error(`Ambiguous repository plane resolution for branch '${normalizedBranch}'.`);
  }

  return matches[0].plane;
}

export function resolveRepositoryRole(repository, contract) {
  return resolveRepositoryPlane(repository, contract) === 'upstream' ? 'upstream' : 'fork';
}

export function classifyBranch({
  branch,
  contract,
  repositoryRole = null,
  repository = null
}) {
  if (!contract || typeof contract !== 'object') {
    throw new Error('Branch class contract is required.');
  }
  const normalizedBranch = normalizeBranchName(branch);
  if (!normalizedBranch) {
    return null;
  }
  const role = repositoryRole
    ? normalizeRepositoryRole(repositoryRole)
    : resolveRepositoryRole(repository, contract);
  const repositoryPlane = repository ? resolveRepositoryPlane(repository, contract) : role;

  const matches = [];
  for (const entry of contract.classes) {
    const allowedRoles = Array.isArray(entry?.repositoryRoles)
      ? entry.repositoryRoles.map((value) => normalizeRepositoryRole(value))
      : [];
    if (!allowedRoles.includes(role)) {
      continue;
    }
    const branchPatterns = Array.isArray(entry?.branchPatterns) ? entry.branchPatterns : [];
    for (const pattern of branchPatterns) {
      if (matchBranchPattern(normalizedBranch, pattern)) {
        matches.push({
          classEntry: entry,
          pattern,
          specificity: patternSpecificity(pattern)
        });
      }
    }
  }

  if (matches.length === 0) {
    return null;
  }

  matches.sort((left, right) => right.specificity - left.specificity);
  if (matches.length > 1 && matches[0].specificity === matches[1].specificity) {
    throw new Error(`Ambiguous branch class resolution for '${normalizedBranch}' in role '${role}'.`);
  }

  const selected = matches[0];
  return {
    id: selected.classEntry.id,
    repositoryRole: role,
    repositoryPlane,
    branch: normalizedBranch,
    matchedPattern: selected.pattern,
    purpose: selected.classEntry.purpose,
    prSourceAllowed: Boolean(selected.classEntry.prSourceAllowed),
    prTargetAllowed: Boolean(selected.classEntry.prTargetAllowed),
    mergePolicy: selected.classEntry.mergePolicy
  };
}

export function findAllowedTransition({
  from,
  to,
  action,
  contract
}) {
  if (!contract || typeof contract !== 'object') {
    throw new Error('Branch class contract is required.');
  }
  return (contract.allowedTransitions || []).find(
    (entry) => entry?.from === from && entry?.to === to && entry?.action === action
  ) ?? null;
}

export function assertAllowedTransition({ from, to, action, contract }) {
  const transition = findAllowedTransition({ from, to, action, contract });
  if (!transition) {
    throw new Error(`Transition ${from} --${action}--> ${to} is not allowed by the branch class contract.`);
  }
  return transition;
}

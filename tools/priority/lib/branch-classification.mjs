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

function normalizeRepositorySlug(value) {
  return String(value ?? '').trim().toLowerCase();
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
  return contract;
}

export function resolveRepositoryRole(repository, contract) {
  const upstreamRepository = normalizeRepositorySlug(contract?.upstreamRepository);
  const normalizedRepository = normalizeRepositorySlug(repository);
  if (!normalizedRepository) {
    throw new Error('Repository slug is required to resolve branch role.');
  }
  return normalizedRepository === upstreamRepository ? 'upstream' : 'fork';
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

#!/usr/bin/env node

import { findRepositoryPlaneEntry, loadBranchClassContract } from './branch-classification.mjs';

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function normalizeLaneBranchPrefix(prefix) {
  const normalized = normalizeText(prefix);
  if (!normalized) {
    return '';
  }
  return normalized.endsWith('/') || normalized.endsWith('-') ? normalized : `${normalized}/`;
}

export function resolveRequiredLaneBranchPrefix({
  plane,
  repoRoot = process.cwd(),
  branchClassContract = null,
  loadBranchClassContractFn = loadBranchClassContract
}) {
  const normalizedPlane = normalizeText(plane).toLowerCase();
  if (!normalizedPlane) {
    throw new Error('Repository plane is required to resolve a runtime lane branch prefix.');
  }

  const contract = branchClassContract ?? loadBranchClassContractFn(repoRoot);
  const planeEntry = findRepositoryPlaneEntry(contract, normalizedPlane);
  if (!planeEntry) {
    throw new Error(`Branch class contract does not define repository plane '${normalizedPlane}' for runtime lane branches.`);
  }

  const laneBranchPrefix = normalizeLaneBranchPrefix(planeEntry.laneBranchPrefix);
  if (!laneBranchPrefix) {
    throw new Error(
      `Branch class contract repository plane '${normalizedPlane}' does not define a laneBranchPrefix for runtime lane branches.`
    );
  }

  return {
    contract,
    plane: normalizedPlane,
    laneBranchPrefix
  };
}

export function assertLaneBranchMatchesPlane({
  branch,
  plane,
  repoRoot = process.cwd(),
  branchClassContract = null,
  loadBranchClassContractFn = loadBranchClassContract
}) {
  const normalizedBranch = normalizeText(branch);
  if (!normalizedBranch) {
    throw new Error('Runtime lane branch is required.');
  }

  const { contract, laneBranchPrefix, plane: normalizedPlane } = resolveRequiredLaneBranchPrefix({
    plane,
    repoRoot,
    branchClassContract,
    loadBranchClassContractFn
  });

  if (!normalizedBranch.toLowerCase().startsWith(laneBranchPrefix.toLowerCase())) {
    throw new Error(
      `Runtime lane branch '${normalizedBranch}' does not match lane branch prefix '${laneBranchPrefix}' for plane '${normalizedPlane}'.`
    );
  }

  return {
    contract,
    branch: normalizedBranch,
    plane: normalizedPlane,
    laneBranchPrefix
  };
}

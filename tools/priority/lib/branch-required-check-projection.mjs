import { readFile } from 'node:fs/promises';

const defaultBranchRequiredChecksPath = new URL('../../policy/branch-required-checks.json', import.meta.url);

function hasOwnProperty(object, key) {
  return Object.prototype.hasOwnProperty.call(object ?? {}, key);
}

function normalizeCheckList(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return [...new Set(value.map((entry) => String(entry ?? '').trim()).filter(Boolean))];
}

function escapeRegex(value) {
  return value.replace(/[|\\{}()[\]^$+?.*]/g, '\\$&');
}

function matchesBranchPattern(pattern, branchName) {
  if (typeof pattern !== 'string' || typeof branchName !== 'string') {
    return false;
  }
  if (pattern === branchName) {
    return true;
  }
  const expression = `^${escapeRegex(pattern).replace(/\\\*/g, '.*')}$`;
  return new RegExp(expression).test(branchName);
}

function resolvePatternValue(mapping, key) {
  if (!mapping || typeof mapping !== 'object' || typeof key !== 'string' || key.trim().length === 0) {
    return null;
  }

  if (hasOwnProperty(mapping, key)) {
    return mapping[key];
  }

  for (const [pattern, value] of Object.entries(mapping)) {
    if (pattern === key) {
      return value;
    }
    if (matchesBranchPattern(pattern, key)) {
      return value;
    }
  }

  return null;
}

function normalizeBranchNameFromRef(refName) {
  if (typeof refName !== 'string') {
    return null;
  }
  const trimmed = refName.trim();
  const prefix = 'refs/heads/';
  if (!trimmed.startsWith(prefix)) {
    return null;
  }
  return trimmed.slice(prefix.length);
}

function resolveRulesetBranchName(expectations, rulesetKey) {
  const includes = Array.isArray(expectations?.includes)
    ? expectations.includes.map((entry) => normalizeBranchNameFromRef(entry)).filter(Boolean)
    : [];
  const uniqueBranches = [...new Set(includes)];
  if (uniqueBranches.length === 0) {
    return null;
  }
  if (uniqueBranches.length > 1) {
    throw new Error(
      `Ruleset '${rulesetKey}' includes multiple branch refs (${uniqueBranches.join(', ')}); ` +
      'required-status-check projection must remain single-branch.'
    );
  }
  return uniqueBranches[0];
}

export function resolveProjectedBranchClassId(branchPolicy, branchName, preferredBranchClassId = null) {
  const mappedBranchClassId = resolvePatternValue(branchPolicy?.branchClassBindings, branchName);
  if (preferredBranchClassId && mappedBranchClassId && preferredBranchClassId !== mappedBranchClassId) {
    throw new Error(
      `Branch '${branchName}' declares branch_class_id '${preferredBranchClassId}' but branch-required-checks ` +
      `maps it to '${mappedBranchClassId}'.`
    );
  }
  return preferredBranchClassId ?? mappedBranchClassId ?? null;
}

export function resolveProjectedRequiredStatusChecks(branchPolicy, branchName, options = {}) {
  const preferredBranchClassId = options.branchClassId ?? null;
  const explicitChecks = normalizeCheckList(resolvePatternValue(branchPolicy?.branches, branchName));
  if (explicitChecks.length > 0) {
    return explicitChecks;
  }

  const branchClassId = resolveProjectedBranchClassId(branchPolicy, branchName, preferredBranchClassId);
  if (!branchClassId) {
    return [];
  }

  return normalizeCheckList(resolvePatternValue(branchPolicy?.branchClassRequiredChecks, branchClassId));
}

function assertProjectedChecksMatch(explicitChecks, projectedChecks, surfaceLabel) {
  if (!Array.isArray(explicitChecks)) {
    return;
  }
  const normalizedExplicit = normalizeCheckList(explicitChecks).slice().sort();
  const normalizedProjected = normalizeCheckList(projectedChecks).slice().sort();
  if (normalizedExplicit.length !== normalizedProjected.length) {
    throw new Error(
      `${surfaceLabel} required_status_checks drift from branch-required-check projection ` +
      `(explicit ${normalizedExplicit.length}, projected ${normalizedProjected.length}).`
    );
  }
  for (let index = 0; index < normalizedExplicit.length; index += 1) {
    if (normalizedExplicit[index] !== normalizedProjected[index]) {
      throw new Error(
        `${surfaceLabel} required_status_checks drift from branch-required-check projection ` +
        `(explicit [${normalizedExplicit.join(', ')}], projected [${normalizedProjected.join(', ')}]).`
      );
    }
  }
}

export function projectManifestRequiredStatusChecks(manifest, branchPolicy, options = {}) {
  const strict = options.strict !== false;
  const projectedManifest = structuredClone(manifest);

  for (const [branchName, expectations] of Object.entries(projectedManifest?.branches ?? {})) {
    const projectedChecks = resolveProjectedRequiredStatusChecks(branchPolicy, branchName, {
      branchClassId: expectations?.branch_class_id ?? null
    });
    if (projectedChecks.length === 0) {
      if (Array.isArray(expectations?.required_status_checks)) {
        continue;
      }
      if (strict) {
        throw new Error(
          `Branch '${branchName}' is missing a branch-required-check projection and has no explicit ` +
          'required_status_checks fallback.'
        );
      }
      continue;
    }
    assertProjectedChecksMatch(expectations?.required_status_checks, projectedChecks, `branch '${branchName}'`);
    expectations.required_status_checks = projectedChecks;
  }

  for (const [rulesetKey, expectations] of Object.entries(projectedManifest?.rulesets ?? {})) {
    const branchName = resolveRulesetBranchName(expectations, rulesetKey);
    const projectedChecks = branchName
      ? resolveProjectedRequiredStatusChecks(branchPolicy, branchName, {
          branchClassId: expectations?.branch_class_id ?? null
        })
      : [];

    if (projectedChecks.length === 0) {
      if (Array.isArray(expectations?.required_status_checks)) {
        continue;
      }
      if (strict) {
        throw new Error(
          `Ruleset '${rulesetKey}' is missing a branch-required-check projection and has no explicit ` +
          'required_status_checks fallback.'
        );
      }
      continue;
    }
    assertProjectedChecksMatch(expectations?.required_status_checks, projectedChecks, `ruleset '${rulesetKey}'`);
    expectations.required_status_checks = projectedChecks;
  }

  return projectedManifest;
}

export async function loadBranchRequiredChecksPolicy(branchRequiredChecksPath = defaultBranchRequiredChecksPath) {
  const raw = await readFile(branchRequiredChecksPath, 'utf8');
  return JSON.parse(raw);
}

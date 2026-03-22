import fs from 'node:fs';
import path from 'node:path';

export const DEFAULT_STORAGE_ROOT_POLICY = Object.freeze({
  worktrees: {
    envVar: 'COMPAREVI_BURST_WORKTREE_ROOT',
    preferredRoots: ['E:\\comparevi-lanes']
  },
  artifacts: {
    envVar: 'COMPAREVI_BURST_ARTIFACT_ROOT',
    preferredRoots: ['E:\\comparevi-artifacts']
  }
});

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function uniqueStrings(values) {
  return [...new Set((Array.isArray(values) ? values : []).map((value) => normalizeText(value)).filter(Boolean))];
}

export function isPathWithin(parentPath, childPath) {
  const relativePath = path.relative(parentPath, childPath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

function isForeignWindowsAbsolutePath(candidatePath, platform = process.platform) {
  return platform !== 'win32' && path.win32.isAbsolute(normalizeText(candidatePath));
}

function resolveCandidatePath(repoRoot, candidatePath, { platform = process.platform } = {}) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    return null;
  }
  if (isForeignWindowsAbsolutePath(normalized, platform)) {
    return null;
  }
  return path.isAbsolute(normalized) ? path.resolve(normalized) : path.resolve(repoRoot, normalized);
}

function pathRootExists(targetPath, { platform = process.platform } = {}) {
  if (!targetPath || isForeignWindowsAbsolutePath(targetPath, platform)) {
    return false;
  }
  const rootPath = path.parse(path.resolve(targetPath)).root;
  return Boolean(rootPath) && fs.existsSync(rootPath);
}

function normalizeStorageRootEntry(value, fallback) {
  const source = value && typeof value === 'object' ? value : {};
  const preferredRoots = uniqueStrings(
    Array.isArray(source.preferredRoots) && source.preferredRoots.length > 0 ? source.preferredRoots : fallback.preferredRoots
  );
  return {
    envVar: normalizeText(source.envVar) || fallback.envVar,
    preferredRoots
  };
}

export function normalizeStorageRootsPolicy(value = {}) {
  const source = value && typeof value === 'object' ? value : {};
  return {
    worktrees: normalizeStorageRootEntry(source.worktrees, DEFAULT_STORAGE_ROOT_POLICY.worktrees),
    artifacts: normalizeStorageRootEntry(source.artifacts, DEFAULT_STORAGE_ROOT_POLICY.artifacts)
  };
}

export function loadStorageRootsPolicy(repoRoot, { policyPath = path.join('tools', 'priority', 'delivery-agent.policy.json') } = {}) {
  const resolvedPolicyPath = path.isAbsolute(policyPath) ? policyPath : path.resolve(repoRoot, policyPath);
  if (!fs.existsSync(resolvedPolicyPath)) {
    return normalizeStorageRootsPolicy();
  }
  try {
    const payload = JSON.parse(fs.readFileSync(resolvedPolicyPath, 'utf8'));
    return normalizeStorageRootsPolicy(payload?.storageRoots);
  } catch {
    return normalizeStorageRootsPolicy();
  }
}

function buildRootSelection({
  repoRoot,
  strategy,
  source,
  baseRoot,
  relativeRoot = null
}) {
  const resolvedBaseRoot = path.resolve(baseRoot);
  const normalizedRelativeRoot = normalizeText(relativeRoot) || null;
  return {
    strategy,
    source,
    baseRoot: resolvedBaseRoot,
    relativeRoot: normalizedRelativeRoot,
    usesExternalRoot: !isPathWithin(path.resolve(repoRoot), resolvedBaseRoot)
  };
}

export function sanitizeRelativeRoot(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return '';
  }
  const segments = path
    .normalize(normalized)
    .split(/[\\/]+/)
    .map((segment) => segment.trim())
    .filter((segment) => segment && segment !== '.' && segment !== '..');
  return segments.length > 0 ? path.join(...segments) : '';
}

export function resolveStorageBaseRoot({
  repoRoot,
  kind,
  policy,
  env = process.env,
  platform = process.platform
}) {
  const normalizedKind = normalizeText(kind);
  if (!['worktrees', 'artifacts'].includes(normalizedKind)) {
    throw new Error(`Unsupported storage root kind: ${kind}`);
  }
  const normalizedPolicy = normalizeStorageRootsPolicy(policy);
  const scope = normalizedPolicy[normalizedKind];
  const envValue = normalizeText(env?.[scope.envVar]);
  if (envValue) {
    const resolvedEnvRoot = resolveCandidatePath(repoRoot, envValue, { platform });
    if (resolvedEnvRoot && pathRootExists(resolvedEnvRoot, { platform })) {
      return buildRootSelection({
        repoRoot,
        strategy: 'environment',
        source: scope.envVar,
        baseRoot: resolvedEnvRoot
      });
    }
  }

  for (const [index, preferredRoot] of scope.preferredRoots.entries()) {
    const resolvedPreferredRoot = resolveCandidatePath(repoRoot, preferredRoot, { platform });
    if (resolvedPreferredRoot && pathRootExists(resolvedPreferredRoot, { platform })) {
      return buildRootSelection({
        repoRoot,
        strategy: 'policy-preferred-root',
        source: `delivery-agent.policy.json#storageRoots.${normalizedKind}.preferredRoots[${index}]`,
        baseRoot: resolvedPreferredRoot
      });
    }
  }

  return null;
}

export function resolveArtifactDestinationRoot({
  repoRoot,
  destinationRoot,
  destinationRootExplicit = false,
  policy,
  env = process.env,
  platform = process.platform
}) {
  const requestedRoot = normalizeText(destinationRoot);
  if (!requestedRoot) {
    throw new Error('Artifact destination root is required.');
  }

  if (destinationRootExplicit || path.isAbsolute(requestedRoot) || path.win32.isAbsolute(requestedRoot)) {
    const resolvedDestinationRoot = resolveCandidatePath(repoRoot, requestedRoot, { platform });
    if (!resolvedDestinationRoot) {
      throw new Error(`Artifact destination root is not valid on ${platform}: ${requestedRoot}`);
    }
    return {
      destinationRoot: resolvedDestinationRoot,
      destinationRootPolicy: buildRootSelection({
        repoRoot,
        strategy: 'explicit',
        source: 'explicit-destination-root',
        baseRoot: resolvedDestinationRoot
      })
    };
  }

  const selectedRoot = resolveStorageBaseRoot({
    repoRoot,
    kind: 'artifacts',
    policy,
    env,
    platform
  });
  if (!selectedRoot) {
    const relativeRoot = sanitizeRelativeRoot(requestedRoot);
    return {
      destinationRoot: resolveCandidatePath(repoRoot, requestedRoot, { platform }),
      destinationRootPolicy: buildRootSelection({
        repoRoot,
        strategy: 'repo-default',
        source: 'repo-default-artifact-root',
        baseRoot: repoRoot,
        relativeRoot
      })
    };
  }

  const relativeRoot = sanitizeRelativeRoot(requestedRoot);
  return {
    destinationRoot: relativeRoot ? path.join(selectedRoot.baseRoot, relativeRoot) : selectedRoot.baseRoot,
    destinationRootPolicy: {
      ...selectedRoot,
      relativeRoot: relativeRoot || null
    }
  };
}

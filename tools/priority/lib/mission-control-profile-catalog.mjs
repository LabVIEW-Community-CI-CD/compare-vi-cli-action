import fs from 'node:fs';
import path from 'node:path';

export const MISSION_CONTROL_PROFILE_CATALOG_SCHEMA = 'priority/mission-control-profile-catalog@v1';
export const DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH = path.join(
  'tools',
  'priority',
  '__fixtures__',
  'mission-control',
  'profile-catalog.json'
);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

export function normalizeMissionControlProfileCatalog(value) {
  const catalog = cloneJson(value);
  if (catalog?.schema !== MISSION_CONTROL_PROFILE_CATALOG_SCHEMA) {
    throw new Error(
      `Mission-control profile catalog schema must be '${MISSION_CONTROL_PROFILE_CATALOG_SCHEMA}'.`
    );
  }
  if (!Array.isArray(catalog.profiles) || catalog.profiles.length === 0) {
    throw new Error('Mission-control profile catalog must include one or more profiles.');
  }

  const tokenOwners = new Map();
  for (const profile of catalog.profiles) {
    const profileId = normalizeText(profile?.id);
    const triggerTokens = [profile?.trigger, ...(Array.isArray(profile?.aliases) ? profile.aliases : [])]
      .map((entry) => normalizeText(entry))
      .filter(Boolean);
    for (const token of triggerTokens) {
      const priorOwner = tokenOwners.get(token);
      if (priorOwner) {
        throw new Error(
          `Mission-control trigger token '${token}' is reused by '${profileId}' and '${priorOwner}'.`
        );
      }
      tokenOwners.set(token, profileId);
    }
  }

  return catalog;
}

export function loadMissionControlProfileCatalog(
  repoRoot = process.cwd(),
  relativePath = DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH
) {
  const resolvedPath = path.resolve(repoRoot, relativePath);
  const payload = JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
  return normalizeMissionControlProfileCatalog(payload);
}

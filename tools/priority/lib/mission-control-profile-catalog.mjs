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

const PROFILE_TRIGGER_PATTERN = /^MC(?:-[A-Z0-9]+)*$/;
const PROFILE_SPECS = new Map([
  ['autonomous-default', { trigger: 'MC', intent: 'continue-driving-autonomously', focus: 'standing-priority' }],
  ['finish-live-lane', { trigger: 'MC-LIVE', intent: 'finish-live-standing-lane', focus: 'standing-priority' }],
  ['stabilize-current-head-failure', { trigger: 'MC-RED', intent: 'stabilize-current-head-failure', focus: 'current-head-failure' }],
  ['restore-intake', { trigger: 'MC-INTAKE', intent: 'restore-intake', focus: 'queue-health' }],
  ['prepare-parked-lane', { trigger: 'MC-PARK', intent: 'prepare-parked-lane', focus: 'queue-health' }]
]);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function assertNonEmptyString(value, fieldName) {
  if (!normalizeText(value)) {
    throw new Error(`Mission-control profile catalog field '${fieldName}' must be a non-empty string.`);
  }
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

  const seenProfileIds = new Set();
  const tokenOwners = new Map();
  for (const profile of catalog.profiles) {
    const profileId = normalizeText(profile?.id);
    const profileSpec = PROFILE_SPECS.get(profileId);
    if (!profileSpec) {
      throw new Error(`Mission-control profile '${profileId}' is not a supported canonical profile id.`);
    }
    if (seenProfileIds.has(profileId)) {
      throw new Error(`Mission-control profile '${profileId}' is duplicated.`);
    }
    seenProfileIds.add(profileId);

    assertNonEmptyString(profile.summary, `${profileId}.summary`);
    assertNonEmptyString(profile.description, `${profileId}.description`);

    if (normalizeText(profile.trigger) !== profileSpec.trigger) {
      throw new Error(
        `Mission-control profile '${profileId}' must use trigger '${profileSpec.trigger}'.`
      );
    }
    if (!Array.isArray(profile.aliases)) {
      throw new Error(`Mission-control profile '${profileId}' must declare aliases as an array.`);
    }
    const aliasSet = new Set();
    const triggerTokens = [profile?.trigger, ...(Array.isArray(profile?.aliases) ? profile.aliases : [])]
      .map((entry) => normalizeText(entry))
      .filter(Boolean);
    for (const token of triggerTokens) {
      if (!PROFILE_TRIGGER_PATTERN.test(token)) {
        throw new Error(`Mission-control trigger token '${token}' is not a valid MC preset token.`);
      }
      if (token !== profile.trigger) {
        if (aliasSet.has(token)) {
          throw new Error(`Mission-control profile '${profileId}' repeats alias '${token}'.`);
        }
        aliasSet.add(token);
      }
      const priorOwner = tokenOwners.get(token);
      if (priorOwner) {
        throw new Error(
          `Mission-control trigger token '${token}' is reused by '${profileId}' and '${priorOwner}'.`
        );
      }
      tokenOwners.set(token, profileId);
    }

    if (!profile.operatorPreset || typeof profile.operatorPreset !== 'object') {
      throw new Error(`Mission-control profile '${profileId}' must declare an operatorPreset object.`);
    }
    if (normalizeText(profile.operatorPreset.intent) !== profileSpec.intent) {
      throw new Error(
        `Mission-control profile '${profileId}' must map to intent '${profileSpec.intent}'.`
      );
    }
    if (normalizeText(profile.operatorPreset.focus) !== profileSpec.focus) {
      throw new Error(
        `Mission-control profile '${profileId}' must map to focus '${profileSpec.focus}'.`
      );
    }
    if (!Array.isArray(profile.operatorPreset.overrides) || profile.operatorPreset.overrides.length !== 0) {
      throw new Error(`Mission-control profile '${profileId}' must keep operatorPreset.overrides empty.`);
    }
  }

  if (seenProfileIds.size !== PROFILE_SPECS.size) {
    throw new Error('Mission-control profile catalog must include every canonical mission-control profile exactly once.');
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

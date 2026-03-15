#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
  findMissionControlProfileTrigger,
  normalizeMissionControlProfileId,
  normalizeMissionControlTriggerToken,
} from './lib/mission-control-profile-catalog.mjs';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(SCRIPT_PATH);
export const DEFAULT_REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');
export const MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA = 'priority/mission-control-profile-resolution@v1';
export const DEFAULT_MISSION_CONTROL_PROFILE_RESOLUTION_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'mission-control',
  'mission-control-profile-resolution.json',
);
const AGENT_MISSION_CONTROL_RESULTS_ROOT = path.join('tests', 'results', '_agent', 'mission-control');

function printUsage(logFn = console.log) {
  logFn('Usage: node tools/priority/resolve-mission-control-profile.mjs [options]');
  logFn('');
  logFn('Resolve a mission-control trigger token through the checked-in profile catalog.');
  logFn('');
  logFn('Options:');
  logFn('  --trigger <token>    Trigger token or alias to resolve (for example: MC, MC-LIVE, MC-PARKED).');
  logFn('  --profile <id>       Expected canonical profile id. Fail closed when it contradicts the trigger.');
  logFn(`  --catalog <path>     Profile catalog path (default: ${DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH}).`);
  logFn(
    `  --report <path>      Output report path (default: ${DEFAULT_MISSION_CONTROL_PROFILE_RESOLUTION_REPORT_PATH}).`,
  );
  logFn('  -h, --help           Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function isAbsolutePathLike(value) {
  return path.isAbsolute(value) || path.win32.isAbsolute(value) || path.posix.isAbsolute(value);
}

function isDriveQualifiedPath(value) {
  return /^[A-Za-z]:/.test(value);
}

function normalizeComparablePath(filePath) {
  const normalized = path.normalize(filePath);
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized;
}

function resolveRepoRelativePath(repoRoot, candidatePath, { label = 'path', requiredRoot = '' } = {}) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    throw new Error(`${label} must be a non-empty repo-relative path.`);
  }
  const normalizedRepoRelativePath = normalized.replace(/\\/g, '/');
  if (isAbsolutePathLike(normalizedRepoRelativePath) || isDriveQualifiedPath(normalizedRepoRelativePath)) {
    throw new Error(`${label} must stay under the repository root: ${normalized}`);
  }
  const resolved = path.resolve(repoRoot, normalizedRepoRelativePath);
  const relativeToRepo = path.relative(repoRoot, resolved);
  if (!relativeToRepo || relativeToRepo.startsWith('..') || path.isAbsolute(relativeToRepo)) {
    throw new Error(`${label} escapes the repository root: ${normalized}`);
  }
  if (requiredRoot) {
    const requiredRootPath = path.resolve(repoRoot, requiredRoot);
    const relativeToRequiredRoot = path.relative(requiredRootPath, resolved);
    if (!relativeToRequiredRoot || relativeToRequiredRoot.startsWith('..') || path.isAbsolute(relativeToRequiredRoot)) {
      throw new Error(`${label} must stay under ${requiredRoot}: ${normalized}`);
    }
  }
  return resolved;
}

function toRepoRelativePath(repoRoot, absolutePath) {
  return path.relative(repoRoot, absolutePath).replace(/\\/g, '/');
}

function resolveCanonicalCatalogPath(repoRoot, catalogPath) {
  const resolvedCatalogPath = resolveRepoRelativePath(repoRoot, catalogPath, {
    label: 'Mission-control profile catalog path',
    requiredRoot: path.dirname(DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH),
  });
  const canonicalCatalogPath = path.resolve(repoRoot, DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH);
  if (normalizeComparablePath(resolvedCatalogPath) !== normalizeComparablePath(canonicalCatalogPath)) {
    throw new Error(
      `Mission-control profile catalog path must resolve to ${DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH}.`,
    );
  }
  return resolvedCatalogPath;
}

function resolveCanonicalReportPath(repoRoot, reportPath) {
  return resolveRepoRelativePath(repoRoot, reportPath, {
    label: 'Mission-control profile resolution report path',
    requiredRoot: AGENT_MISSION_CONTROL_RESULTS_ROOT,
  });
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    trigger: null,
    expectedProfileId: null,
    catalogPath: DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
    reportPath: DEFAULT_MISSION_CONTROL_PROFILE_RESOLUTION_REPORT_PATH,
  };
  const singletonOptions = new Set(['--trigger', '--profile', '--catalog', '--report']);
  const seenSingletonOptions = new Set();

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (token === '--trigger' || token === '--profile' || token === '--catalog' || token === '--report') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      if (singletonOptions.has(token)) {
        if (seenSingletonOptions.has(token)) {
          throw new Error(`Duplicate option is not allowed: ${token}.`);
        }
        seenSingletonOptions.add(token);
      }
      index += 1;
      if (token === '--trigger') options.trigger = normalizeText(next);
      if (token === '--profile') options.expectedProfileId = normalizeText(next);
      if (token === '--catalog') options.catalogPath = next;
      if (token === '--report') options.reportPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !options.trigger) {
    throw new Error('Trigger is required. Pass --trigger <token>.');
  }

  return options;
}

function writeJsonFile(filePath, payload, repoRoot = DEFAULT_REPO_ROOT) {
  const resolvedPath = path.resolve(repoRoot, filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function buildResolutionPayload(resolution) {
  if (!resolution) {
    return null;
  }
  return {
    token: resolution.token,
    matchedToken: resolution.matchedToken,
    selectionSource: resolution.matchedToken === resolution.canonicalTrigger ? 'canonical-trigger' : 'alias-trigger',
    profileId: resolution.profileId,
    canonicalTrigger: resolution.canonicalTrigger,
    aliases: [...resolution.aliases],
    operatorPreset: {
      intent: resolution.operatorPreset.intent,
      focus: resolution.operatorPreset.focus,
      overrides: [...resolution.operatorPreset.overrides],
    },
    summary: resolution.summary,
    description: resolution.description,
  };
}

export function assessMissionControlProfileResolution(
  {
    trigger,
    expectedProfileId = null,
    catalogPath = DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
  },
  {
    repoRoot = DEFAULT_REPO_ROOT,
  } = {},
) {
  const normalizedCatalogPath = toRepoRelativePath(repoRoot, resolveCanonicalCatalogPath(repoRoot, catalogPath));
  const requestedTrigger = normalizeText(trigger);
  const requestedProfileId = normalizeText(expectedProfileId);
  const checks = {
    triggerDefined: 'passed',
    expectedProfileDefined: requestedProfileId ? 'passed' : 'skipped',
    expectedProfileMatchesResolvedProfile: requestedProfileId ? 'passed' : 'skipped',
  };
  const issues = [];
  let normalizedTrigger = null;
  let normalizedExpectedProfileId = null;
  let resolution = null;

  try {
    normalizedTrigger = normalizeMissionControlTriggerToken(requestedTrigger, 'trigger');
  } catch {
    checks.triggerDefined = 'failed';
    checks.expectedProfileMatchesResolvedProfile = 'skipped';
    issues.push('invalid-trigger-token');
  }

  if (checks.triggerDefined === 'passed') {
    resolution = findMissionControlProfileTrigger(normalizedTrigger, {
      repoRoot,
      relativePath: normalizedCatalogPath,
    });
    if (!resolution) {
      checks.triggerDefined = 'failed';
      checks.expectedProfileMatchesResolvedProfile = 'skipped';
      issues.push('unknown-trigger');
    }
  }

  if (requestedProfileId) {
    try {
      normalizedExpectedProfileId = normalizeMissionControlProfileId(requestedProfileId, 'expectedProfileId');
    } catch {
      checks.expectedProfileDefined = 'failed';
      checks.expectedProfileMatchesResolvedProfile = 'skipped';
      issues.push('unknown-profile');
    }
  }

  if (
    resolution
    && normalizedExpectedProfileId
    && checks.expectedProfileDefined === 'passed'
    && resolution.profileId !== normalizedExpectedProfileId
  ) {
    checks.expectedProfileMatchesResolvedProfile = 'failed';
    issues.push('profile-trigger-mismatch');
  }

  const status = issues.length > 0 ? 'failed' : 'passed';

  return {
    schema: MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA,
    catalogPath: normalizedCatalogPath,
    request: {
      trigger: requestedTrigger,
      expectedProfileId: requestedProfileId,
    },
    checks,
    issueCount: issues.length,
    issues,
    status,
    resolution: buildResolutionPayload(resolution),
  };
}

export function resolveMissionControlProfileReport(
  {
    trigger,
    expectedProfileId = null,
    catalogPath = DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
  },
  {
    now = new Date(),
    repoRoot = DEFAULT_REPO_ROOT,
  } = {},
) {
  const report = assessMissionControlProfileResolution(
    {
      trigger,
      expectedProfileId,
      catalogPath,
    },
    {
      repoRoot,
    },
  );
  return {
    ...report,
    generatedAt: new Date(now).toISOString(),
  };
}

export function main(
  argv = process.argv,
  {
    now = new Date(),
    repoRoot = DEFAULT_REPO_ROOT,
    logFn = console.log,
    errorFn = console.error,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    printUsage(errorFn);
    return 1;
  }

  if (options.help) {
    printUsage(logFn);
    return 0;
  }

  try {
    const report = resolveMissionControlProfileReport(
      {
        trigger: options.trigger,
        expectedProfileId: options.expectedProfileId,
        catalogPath: options.catalogPath,
      },
      {
        now,
        repoRoot,
      },
    );
    const reportPath = writeJsonFile(resolveCanonicalReportPath(repoRoot, options.reportPath), report, repoRoot);
    logFn(`[mission-control:resolve] report: ${reportPath}`);
    logFn(
      `[mission-control:resolve] status=${report.status} trigger=${report.request.trigger ?? 'none'} profile=${report.resolution?.profileId ?? 'none'} issues=${report.issueCount}`,
    );
    return report.status === 'failed' ? 1 : 0;
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

export function isDirectExecution(argv = process.argv, metaUrl = import.meta.url) {
  const modulePath = path.resolve(fileURLToPath(metaUrl));
  const invokedPath = argv[1] ? path.resolve(argv[1]) : null;
  return Boolean(invokedPath && invokedPath === modulePath);
}

if (isDirectExecution(process.argv, import.meta.url)) {
  const exitCode = main(process.argv);
  process.exitCode = exitCode;
}

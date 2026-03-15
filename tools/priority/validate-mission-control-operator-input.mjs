#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(SCRIPT_PATH);
export const DEFAULT_REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');
export const MISSION_CONTROL_OPERATOR_INPUT_CATALOG_SCHEMA = 'priority/mission-control-operator-input-catalog@v1';
export const MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA = 'priority/mission-control-operator-input-validation@v1';
export const DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH = path.join(
  'tools',
  'priority',
  '__fixtures__',
  'mission-control',
  'operator-input-catalog.json',
);
export const DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'mission-control',
  'mission-control-operator-input-validation.json',
);
const AGENT_RESULTS_ROOT = path.join('tests', 'results', '_agent');

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
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

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJsonFile(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

function toRepoRelativePath(repoRoot, absolutePath) {
  return path.relative(repoRoot, absolutePath).replace(/\\/g, '/');
}

function resolveCanonicalCatalogPath(repoRoot, catalogPath) {
  const resolvedCatalogPath = resolveRepoRelativePath(repoRoot, catalogPath, {
    label: 'Mission-control operator input catalog path',
    requiredRoot: path.dirname(DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH),
  });
  const canonicalCatalogPath = path.resolve(repoRoot, DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH);
  if (normalizeComparablePath(resolvedCatalogPath) !== normalizeComparablePath(canonicalCatalogPath)) {
    throw new Error(
      `Mission-control operator input catalog path must resolve to ${DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH}.`,
    );
  }
  return resolvedCatalogPath;
}

function assertNonEmptyString(value, fieldName) {
  const normalized = normalizeText(value);
  if (!normalized) {
    throw new Error(`Mission-control operator input field '${fieldName}' must be a non-empty string.`);
  }
  return normalized;
}

function parseStandingIssue(value) {
  if (value === undefined) {
    return {
      number: null,
      issue: null,
      provided: false,
    };
  }
  if (typeof value === 'number') {
    if (Number.isInteger(value) && Number.isFinite(value) && value > 0) {
      return {
        number: value,
        issue: null,
        provided: true,
      };
    }
    return {
      number: null,
      issue: 'malformed-standing-issue',
      provided: true,
    };
  }
  if (value === null || normalizeText(value) === null) {
    return {
      number: null,
      issue: null,
      provided: false,
    };
  }
  const normalized = normalizeText(value);
  if (normalized === 'none') {
    return {
      number: null,
      issue: null,
      provided: true,
    };
  }
  if (!/^\d+$/.test(normalized)) {
    return {
      number: null,
      issue: 'malformed-standing-issue',
      provided: true,
    };
  }
  const parsed = Number.parseInt(normalized, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    return {
      number: null,
      issue: 'malformed-standing-issue',
      provided: true,
    };
  }
  return {
    number: parsed,
    issue: null,
    provided: true,
  };
}

function parseOverrideToken(token) {
  const normalized = normalizeText(token);
  if (!normalized) {
    return {
      key: null,
      valueToken: null,
      issue: 'malformed-override',
    };
  }
  const separatorIndex = normalized.indexOf('=');
  if (separatorIndex <= 0 || separatorIndex === normalized.length - 1) {
    return {
      key: null,
      valueToken: null,
      issue: 'malformed-override',
    };
  }
  return {
    key: normalized.slice(0, separatorIndex).trim(),
    valueToken: normalized.slice(separatorIndex + 1).trim(),
    issue: null,
  };
}

export function loadMissionControlOperatorInputCatalog(
  repoRoot = DEFAULT_REPO_ROOT,
  relativePath = DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH,
) {
  const resolvedPath = resolveRepoRelativePath(repoRoot, relativePath, {
    label: 'Mission-control operator input catalog path',
  });
  const catalog = cloneJson(readJsonFile(resolvedPath));

  if (catalog?.schema !== MISSION_CONTROL_OPERATOR_INPUT_CATALOG_SCHEMA) {
    throw new Error(
      `Mission-control operator input catalog schema must be '${MISSION_CONTROL_OPERATOR_INPUT_CATALOG_SCHEMA}'.`,
    );
  }
  if (!Array.isArray(catalog.intents) || catalog.intents.length === 0) {
    throw new Error('Mission-control operator input catalog must include one or more intents.');
  }
  if (!Array.isArray(catalog.focuses) || catalog.focuses.length === 0) {
    throw new Error('Mission-control operator input catalog must include one or more focuses.');
  }
  if (!Array.isArray(catalog.overrides) || catalog.overrides.length === 0) {
    throw new Error('Mission-control operator input catalog must include one or more overrides.');
  }

  const intents = new Map();
  const focuses = new Map();
  const overrides = new Map();

  for (const entry of catalog.intents) {
    const id = assertNonEmptyString(entry?.id, 'intents[].id');
    if (intents.has(id)) {
      throw new Error(`Mission-control operator input catalog duplicates intent '${id}'.`);
    }
    intents.set(id, {
      ...entry,
      id,
      allowedFocuses: Array.isArray(entry.allowedFocuses) ? [...entry.allowedFocuses] : [],
    });
  }

  for (const entry of catalog.focuses) {
    const id = assertNonEmptyString(entry?.id, 'focuses[].id');
    if (focuses.has(id)) {
      throw new Error(`Mission-control operator input catalog duplicates focus '${id}'.`);
    }
    focuses.set(id, {
      ...entry,
      id,
      standingPriorityRequired: entry.standingPriorityRequired === true,
    });
  }

  for (const entry of catalog.overrides) {
    const key = assertNonEmptyString(entry?.key, 'overrides[].key');
    if (overrides.has(key)) {
      throw new Error(`Mission-control operator input catalog duplicates override '${key}'.`);
    }
    overrides.set(key, {
      ...entry,
      key,
      valueType: assertNonEmptyString(entry.valueType, `overrides.${key}.valueType`),
      allowedValues: Array.isArray(entry.allowedValues) ? [...entry.allowedValues] : [],
    });
  }

  return {
    schema: catalog.schema,
    intents,
    focuses,
    overrides,
    catalog,
    resolvedPath,
  };
}

function normalizeOverrideValue(overrideDefinition, valueToken) {
  const normalized = assertNonEmptyString(valueToken, `overrides.${overrideDefinition.key}.value`);
  if (overrideDefinition.valueType === 'boolean') {
    if (normalized === 'true') {
      return true;
    }
    if (normalized === 'false') {
      return false;
    }
    throw new Error(
      `Override '${overrideDefinition.key}' must use a boolean value of 'true' or 'false'.`,
    );
  }
  if (overrideDefinition.valueType === 'enum') {
    if (!overrideDefinition.allowedValues.includes(normalized)) {
      throw new Error(
        `Override '${overrideDefinition.key}' must use one of: ${overrideDefinition.allowedValues.join(', ')}.`,
      );
    }
    return normalized;
  }
  throw new Error(`Override '${overrideDefinition.key}' uses unsupported valueType '${overrideDefinition.valueType}'.`);
}

function normalizeOverrides(overrideTokens, catalog) {
  const seenKeys = new Set();
  const normalizedOverrides = [];
  const issues = [];

  for (const token of overrideTokens) {
    const parsed = parseOverrideToken(token);
    if (parsed.issue) {
      issues.push(parsed.issue);
      normalizedOverrides.push({
        key: String(token),
        value: null,
        valid: false,
      });
      continue;
    }
    if (seenKeys.has(parsed.key)) {
      issues.push('duplicate-override-key');
      continue;
    }
    seenKeys.add(parsed.key);

    const definition = catalog.overrides.get(parsed.key) ?? null;
    if (!definition) {
      issues.push('unknown-override-key');
      normalizedOverrides.push({
        key: parsed.key,
        value: parsed.valueToken,
        valid: false,
      });
      continue;
    }

    try {
      const value = normalizeOverrideValue(definition, parsed.valueToken);
      normalizedOverrides.push({
        key: parsed.key,
        value,
        valid: true,
      });
    } catch (error) {
      issues.push('override-value-invalid');
      normalizedOverrides.push({
        key: parsed.key,
        value: parsed.valueToken,
        valid: false,
      });
    }
  }

  normalizedOverrides.sort((left, right) => left.key.localeCompare(right.key));
  return {
    overrides: normalizedOverrides,
    issues,
  };
}

export function assessMissionControlOperatorInput(
  {
    intent,
    focus,
    overrides = [],
    standingIssue = undefined,
  },
  {
    repoRoot = DEFAULT_REPO_ROOT,
    catalogPath = DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH,
    catalog = null,
  } = {},
) {
  const normalizedCatalogPath = catalog
    ? catalogPath
    : toRepoRelativePath(repoRoot, resolveCanonicalCatalogPath(repoRoot, catalogPath));
  const resolvedCatalog = catalog ?? loadMissionControlOperatorInputCatalog(repoRoot, normalizedCatalogPath);
  const normalizedIntent = assertNonEmptyString(intent, 'intent');
  const normalizedFocus = assertNonEmptyString(focus, 'focus');
  const parsedStandingIssue = parseStandingIssue(standingIssue);
  const normalizedStandingIssue = parsedStandingIssue.number;
  const normalizedOverrideResult = normalizeOverrides(overrides, resolvedCatalog);
  const intentDefinition = resolvedCatalog.intents.get(normalizedIntent) ?? null;
  const focusDefinition = resolvedCatalog.focuses.get(normalizedFocus) ?? null;
  const focusAllowedForIntent = intentDefinition ? intentDefinition.allowedFocuses.includes(normalizedFocus) : false;
  const standingPriorityRequired = focusDefinition?.standingPriorityRequired === true;
  const standingIssueArgumentProvided = standingPriorityRequired ? parsedStandingIssue.provided === true : true;
  const standingPrioritySatisfied = standingPriorityRequired ? normalizedStandingIssue !== null : true;

  const checks = {
    intentDefined: intentDefinition ? 'passed' : 'failed',
    focusDefined: focusDefinition ? 'passed' : 'failed',
    focusAllowedForIntent: intentDefinition && focusDefinition
      ? (focusAllowedForIntent ? 'passed' : 'failed')
      : 'skipped',
    overrideSyntaxValid: normalizedOverrideResult.issues.includes('malformed-override') ? 'failed' : 'passed',
    overridesKnown: normalizedOverrideResult.issues.includes('unknown-override-key') ? 'failed' : 'passed',
    overrideValuesValid: normalizedOverrideResult.issues.includes('override-value-invalid') ? 'failed' : 'passed',
    overrideKeysUnique: normalizedOverrideResult.issues.includes('duplicate-override-key') ? 'failed' : 'passed',
    standingIssueArgumentProvided: focusDefinition
      ? (standingIssueArgumentProvided ? 'passed' : 'failed')
      : 'skipped',
    standingIssueValueValid: parsedStandingIssue.issue ? 'failed' : 'passed',
    standingPrioritySatisfied: focusDefinition
      ? (!standingIssueArgumentProvided
        ? 'skipped'
        : (standingPrioritySatisfied ? 'passed' : 'downgraded'))
      : 'skipped',
  };

  const standingIssueStatus = standingPriorityRequired
    ? (!standingIssueArgumentProvided
      ? 'omitted'
      : (standingPrioritySatisfied ? 'present' : 'missing'))
    : 'not-required';

  const issues = [];
  if (checks.intentDefined === 'failed') {
    issues.push('unknown-intent');
  }
  if (checks.focusDefined === 'failed') {
    issues.push('unknown-focus');
  }
  if (checks.focusAllowedForIntent === 'failed') {
    issues.push('illegal-intent-focus-combination');
  }
  if (checks.overrideSyntaxValid === 'failed') {
    issues.push('malformed-override');
  }
  if (checks.overridesKnown === 'failed') {
    issues.push('unknown-override-key');
  }
  if (checks.overrideValuesValid === 'failed') {
    issues.push('override-value-invalid');
  }
  if (checks.overrideKeysUnique === 'failed') {
    issues.push('duplicate-override-key');
  }
  if (checks.standingIssueArgumentProvided === 'failed') {
    issues.push('standing-issue-omitted');
  }
  if (checks.standingIssueValueValid === 'failed') {
    issues.push('malformed-standing-issue');
  }
  if (checks.standingPrioritySatisfied === 'downgraded') {
    issues.push('standing-priority-missing');
  }

  const status = issues.some((issue) => issue !== 'standing-priority-missing')
    ? 'failed'
    : issues.includes('standing-priority-missing')
      ? 'downgraded'
      : 'passed';

  return {
    schema: MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_SCHEMA,
    catalogPath: toRepoRelativePath(repoRoot, resolvedCatalog.resolvedPath),
    operator: {
      intent: normalizedIntent,
      focus: normalizedFocus,
      overrides: normalizedOverrideResult.overrides.map((entry) => ({
        key: entry.key,
        value: entry.value,
      })),
    },
    standingIssue: {
      required: standingPriorityRequired,
      number: normalizedStandingIssue,
      status: standingIssueStatus,
    },
    checks,
    issueCount: issues.length,
    issues,
    status,
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    intent: null,
    focus: null,
    overrides: [],
    standingIssue: undefined,
    catalogPath: DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH,
    reportPath: DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_REPORT_PATH,
  };
  const singletonOptions = new Set([
    '--intent',
    '--focus',
    '--standing-issue',
    '--catalog',
    '--report',
  ]);
  const seenSingletonOptions = new Set();

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--intent'
      || token === '--focus'
      || token === '--override'
      || token === '--standing-issue'
      || token === '--catalog'
      || token === '--report'
    ) {
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
      if (token === '--intent') options.intent = next;
      if (token === '--focus') options.focus = next;
      if (token === '--override') options.overrides.push(next);
      if (token === '--standing-issue') options.standingIssue = next;
      if (token === '--catalog') options.catalogPath = next;
      if (token === '--report') options.reportPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !normalizeText(options.intent)) {
    throw new Error('Intent is required. Pass --intent <id>.');
  }
  if (!options.help && !normalizeText(options.focus)) {
    throw new Error('Focus is required. Pass --focus <id>.');
  }

  return options;
}

function printUsage(logFn = console.log) {
  logFn('Usage: node tools/priority/validate-mission-control-operator-input.mjs [options]');
  logFn('');
  logFn('Validate bounded mission-control operator inputs against the checked-in operator-input catalog.');
  logFn('');
  logFn('Options:');
  logFn('  --intent <id>           Operator intent id (required).');
  logFn('  --focus <id>            Operator focus id (required).');
  logFn('  --override <key=value>  Override entry. Repeat for multiple overrides.');
  logFn("  --standing-issue <n|none>  Standing issue number or 'none' for queue-empty contexts.");
  logFn(`  --catalog <path>        Operator-input catalog path (default: ${DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH}).`);
  logFn(`  --report <path>         Validation report path (default: ${DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_VALIDATION_REPORT_PATH}).`);
  logFn('  -h, --help              Show help.');
}

export function validateMissionControlOperatorInputReport(
  {
    intent,
    focus,
    overrides = [],
    standingIssue = undefined,
    catalogPath = DEFAULT_MISSION_CONTROL_OPERATOR_INPUT_CATALOG_PATH,
  },
  {
    now = new Date(),
    repoRoot = DEFAULT_REPO_ROOT,
  } = {},
) {
  const report = assessMissionControlOperatorInput(
    {
      intent,
      focus,
      overrides,
      standingIssue,
    },
    {
      repoRoot,
      catalogPath,
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
    const normalizedCatalogPath = toRepoRelativePath(repoRoot, resolveCanonicalCatalogPath(repoRoot, options.catalogPath));
    const report = validateMissionControlOperatorInputReport(
      {
        intent: options.intent,
        focus: options.focus,
        overrides: options.overrides,
        standingIssue: options.standingIssue,
        catalogPath: normalizedCatalogPath,
      },
      {
        now,
        repoRoot,
      },
    );
    const reportPath = writeJsonFile(
      resolveRepoRelativePath(repoRoot, options.reportPath, {
        label: 'Mission-control operator input validation report path',
        requiredRoot: AGENT_RESULTS_ROOT,
      }),
      report,
    );
    logFn(`[mission-control:operator-input] report: ${reportPath}`);
    logFn(
      `[mission-control:operator-input] status=${report.status} intent=${report.operator.intent} focus=${report.operator.focus} issues=${report.issueCount}`,
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
  process.exitCode = main(process.argv);
}

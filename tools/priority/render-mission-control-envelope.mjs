#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import {
  DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
  loadMissionControlProfileCatalog,
} from './lib/mission-control-profile-catalog.mjs';

export const MISSION_CONTROL_ENVELOPE_RENDER_SCHEMA = 'priority/mission-control-envelope-render@v1';
export const MISSION_CONTROL_ENVELOPE_SCHEMA = 'priority/mission-control-envelope@v1';
export const DEFAULT_MISSION_CONTROL_ENVELOPE_PATH = path.join(
  'tools',
  'priority',
  '__fixtures__',
  'mission-control',
  'mission-control-envelope.json',
);
export const DEFAULT_MISSION_CONTROL_ENVELOPE_SCHEMA_PATH = path.join(
  'docs',
  'schemas',
  'mission-control-envelope-v1.schema.json',
);
export const DEFAULT_MISSION_CONTROL_ENVELOPE_RENDER_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'mission-control',
  'mission-control-envelope-render.json',
);

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function readJsonFile(relativePath, repoRoot = process.cwd()) {
  const resolvedPath = path.resolve(repoRoot, relativePath);
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function writeJsonFile(relativePath, payload, repoRoot = process.cwd()) {
  const resolvedPath = path.resolve(repoRoot, relativePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function validateJsonAgainstSchema(payload, schemaPath, description, repoRoot = process.cwd()) {
  const schema = readJsonFile(schemaPath, repoRoot);
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  if (!validate(payload)) {
    throw new Error(
      `${description} failed schema validation against ${schemaPath}: ${JSON.stringify(validate.errors, null, 2)}`,
    );
  }
}

function assertExactObjectKeys(value, requiredKeys, fieldName) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`Mission-control envelope field '${fieldName}' must be an object.`);
  }
  const actualKeys = Object.keys(value).sort();
  const expectedKeys = [...requiredKeys].sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    throw new Error(
      `Mission-control envelope field '${fieldName}' must contain exactly: ${expectedKeys.join(', ')}.`,
    );
  }
}

function validateMissionControlEnvelopeBase(baseEnvelope, repoRoot = process.cwd()) {
  const contractEnvelope = readJsonFile(DEFAULT_MISSION_CONTROL_ENVELOPE_PATH, repoRoot);
  validateJsonAgainstSchema(
    contractEnvelope,
    DEFAULT_MISSION_CONTROL_ENVELOPE_SCHEMA_PATH,
    'Checked-in mission-control envelope',
    repoRoot,
  );
  validateJsonAgainstSchema(
    baseEnvelope,
    DEFAULT_MISSION_CONTROL_ENVELOPE_SCHEMA_PATH,
    'Mission-control envelope',
    repoRoot,
  );
  if (contractEnvelope?.schema !== MISSION_CONTROL_ENVELOPE_SCHEMA) {
    throw new Error(`Checked-in mission-control envelope schema must be '${MISSION_CONTROL_ENVELOPE_SCHEMA}'.`);
  }
  if (baseEnvelope?.schema !== MISSION_CONTROL_ENVELOPE_SCHEMA) {
    throw new Error(`Mission-control envelope schema must be '${MISSION_CONTROL_ENVELOPE_SCHEMA}'.`);
  }
  assertExactObjectKeys(baseEnvelope, ['schema', 'missionControl', 'operator'], 'root');
  assertExactObjectKeys(baseEnvelope.operator, ['intent', 'focus', 'overrides'], 'operator');
  if (!Array.isArray(baseEnvelope.operator.overrides)) {
    throw new Error(`Mission-control envelope field 'operator.overrides' must be an array.`);
  }
  if (JSON.stringify(baseEnvelope.missionControl) !== JSON.stringify(contractEnvelope.missionControl)) {
    throw new Error('Mission-control envelope base must keep the checked-in missionControl contract unchanged.');
  }
  return contractEnvelope;
}

function resolveTriggerProfile(catalog, triggerToken) {
  const normalizedTrigger = normalizeText(triggerToken);
  if (!normalizedTrigger) {
    throw new Error('Mission-control trigger is required.');
  }

  for (const profile of catalog.profiles) {
    if (profile.trigger === normalizedTrigger) {
      return {
        matchedToken: profile.trigger,
        profile,
      };
    }
    const matchedAlias = profile.aliases.find((alias) => alias === normalizedTrigger) ?? null;
    if (matchedAlias) {
      return {
        matchedToken: matchedAlias,
        profile,
      };
    }
  }

  throw new Error(`Mission-control trigger token '${normalizedTrigger}' is not defined in the profile catalog.`);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    trigger: null,
    catalogPath: DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
    envelopePath: DEFAULT_MISSION_CONTROL_ENVELOPE_PATH,
    reportPath: DEFAULT_MISSION_CONTROL_ENVELOPE_RENDER_REPORT_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (token === '--trigger' || token === '--catalog' || token === '--envelope' || token === '--report') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--trigger') options.trigger = normalizeText(next);
      if (token === '--catalog') options.catalogPath = next;
      if (token === '--envelope') options.envelopePath = next;
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

function printUsage() {
  console.log('Usage: node tools/priority/render-mission-control-envelope.mjs [options]');
  console.log('');
  console.log('Render a machine-readable mission-control envelope from a validated preset trigger.');
  console.log('');
  console.log('Options:');
  console.log('  --trigger <token>    Trigger token or alias to render (for example: MC, MC-LIVE, MC-PARKED).');
  console.log(`  --catalog <path>     Profile catalog path (default: ${DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH}).`);
  console.log(`  --envelope <path>    Base envelope path (default: ${DEFAULT_MISSION_CONTROL_ENVELOPE_PATH}).`);
  console.log(
    `  --report <path>      Output report path (default: ${DEFAULT_MISSION_CONTROL_ENVELOPE_RENDER_REPORT_PATH}).`,
  );
  console.log('  -h, --help           Show help.');
}

export function renderMissionControlEnvelopeReport(
  {
    trigger,
    catalogPath = DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
    envelopePath = DEFAULT_MISSION_CONTROL_ENVELOPE_PATH,
  },
  {
    now = new Date(),
    repoRoot = process.cwd(),
  } = {},
) {
  const catalog = loadMissionControlProfileCatalog(repoRoot, catalogPath);
  const baseEnvelope = readJsonFile(envelopePath, repoRoot);
  const contractEnvelope = validateMissionControlEnvelopeBase(baseEnvelope, repoRoot);

  const { matchedToken, profile } = resolveTriggerProfile(catalog, trigger);
  const renderedEnvelope = {
    schema: contractEnvelope.schema,
    missionControl: cloneJson(contractEnvelope.missionControl),
    operator: {
      intent: profile.operatorPreset.intent,
      focus: profile.operatorPreset.focus,
      overrides: cloneJson(profile.operatorPreset.overrides),
    },
  };
  validateJsonAgainstSchema(
    renderedEnvelope,
    DEFAULT_MISSION_CONTROL_ENVELOPE_SCHEMA_PATH,
    'Rendered mission-control envelope',
    repoRoot,
  );

  return {
    schema: MISSION_CONTROL_ENVELOPE_RENDER_SCHEMA,
    generatedAt: new Date(now).toISOString(),
    trigger: normalizeText(trigger),
    matchedToken,
    profileId: profile.id,
    canonicalTrigger: profile.trigger,
    catalogPath,
    envelopePath,
    profile: {
      id: profile.id,
      trigger: profile.trigger,
      aliases: cloneJson(profile.aliases),
      operatorPreset: cloneJson(profile.operatorPreset),
      summary: profile.summary,
      description: profile.description,
    },
    envelope: renderedEnvelope,
  };
}

export function main(
  argv = process.argv,
  {
    now = new Date(),
    repoRoot = process.cwd(),
    logFn = console.log,
    errorFn = console.error,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  try {
    const report = renderMissionControlEnvelopeReport(
      {
        trigger: options.trigger,
        catalogPath: options.catalogPath,
        envelopePath: options.envelopePath,
      },
      {
        now,
        repoRoot,
      },
    );
    const reportPath = writeJsonFile(options.reportPath, report, repoRoot);
    logFn(`[mission-control:render] report: ${reportPath}`);
    logFn(
      `[mission-control:render] trigger=${report.trigger} profile=${report.profileId} intent=${report.envelope.operator.intent} focus=${report.envelope.operator.focus}`,
    );
    return 0;
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

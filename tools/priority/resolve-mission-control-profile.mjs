#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
  resolveMissionControlProfileTrigger,
} from './lib/mission-control-profile-catalog.mjs';

export const MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA = 'priority/mission-control-profile-resolution@v1';
export const DEFAULT_MISSION_CONTROL_PROFILE_RESOLUTION_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'mission-control',
  'mission-control-profile-resolution.json',
);

function printUsage() {
  console.log('Usage: node tools/priority/resolve-mission-control-profile.mjs [options]');
  console.log('');
  console.log('Resolve a mission-control trigger token through the checked-in profile catalog.');
  console.log('');
  console.log('Options:');
  console.log('  --trigger <token>    Trigger token or alias to resolve (for example: MC, MC-LIVE, MC-PARKED).');
  console.log(`  --catalog <path>     Profile catalog path (default: ${DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH}).`);
  console.log(
    `  --report <path>      Output report path (default: ${DEFAULT_MISSION_CONTROL_PROFILE_RESOLUTION_REPORT_PATH}).`,
  );
  console.log('  -h, --help           Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    trigger: null,
    catalogPath: DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
    reportPath: DEFAULT_MISSION_CONTROL_PROFILE_RESOLUTION_REPORT_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (token === '--trigger' || token === '--catalog' || token === '--report') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--trigger') options.trigger = normalizeText(next);
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

function writeJsonFile(filePath, payload) {
  const resolvedPath = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

export function resolveMissionControlProfileReport(
  {
    trigger,
    catalogPath = DEFAULT_MISSION_CONTROL_PROFILE_CATALOG_PATH,
  },
  {
    now = new Date(),
    repoRoot = process.cwd(),
  } = {},
) {
  const resolution = resolveMissionControlProfileTrigger(trigger, {
    repoRoot,
    relativePath: catalogPath,
  });
  return {
    schema: MISSION_CONTROL_PROFILE_RESOLUTION_SCHEMA,
    generatedAt: new Date(now).toISOString(),
    trigger: resolution.token,
    catalogPath,
    resolution,
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
    const report = resolveMissionControlProfileReport(
      {
        trigger: options.trigger,
        catalogPath: options.catalogPath,
      },
      {
        now,
        repoRoot,
      },
    );
    const reportPath = writeJsonFile(options.reportPath, report);
    logFn(`[mission-control:resolve] report: ${reportPath}`);
    logFn(
      `[mission-control:resolve] trigger=${report.trigger} profile=${report.resolution.profileId} intent=${report.resolution.operatorPreset.intent} focus=${report.resolution.operatorPreset.focus}`,
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

#!/usr/bin/env node

import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/host-ram-budget@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'host-ram-budget.json');
export const DEFAULT_TARGET_PROFILE = 'ni-linux-flag-combination';
export const PROFILE_CATALOG = Object.freeze({
  light: Object.freeze({ perWorkerBytes: 768 * 1024 * 1024, maxParallelism: 8, laneClass: 'cpu-mixed' }),
  medium: Object.freeze({ perWorkerBytes: 1536 * 1024 * 1024, maxParallelism: 4, laneClass: 'mixed' }),
  heavy: Object.freeze({ perWorkerBytes: 3072 * 1024 * 1024, maxParallelism: 3, laneClass: 'ram-bound' }),
  'ni-linux-flag-combination': Object.freeze({ perWorkerBytes: 3072 * 1024 * 1024, maxParallelism: 3, laneClass: 'ram-bound' }),
  'windows-mirror-heavy': Object.freeze({ perWorkerBytes: 6144 * 1024 * 1024, maxParallelism: 2, laneClass: 'ram-bound' }),
});

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function asOptional(value) {
  const text = normalizeText(value);
  return text || null;
}

function parsePositiveInteger(value, flag) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`Invalid value for ${flag}: ${value}`);
  }
  return parsed;
}

function parseByteValue(value, flag) {
  const parsed = Number(String(value));
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`Invalid byte value for ${flag}: ${value}`);
  }
  return Math.trunc(parsed);
}

function ensureProfile(profileId) {
  const profile = PROFILE_CATALOG[profileId];
  if (!profile) {
    throw new Error(`Unknown --target-profile '${profileId}'.`);
  }
  return profile;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    outputPath: DEFAULT_OUTPUT_PATH,
    targetProfile: DEFAULT_TARGET_PROFILE,
    totalBytes: null,
    freeBytes: null,
    cpuParallelism: null,
    minimumParallelism: 1,
    help: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (
      token === '--output' ||
      token === '--target-profile' ||
      token === '--total-bytes' ||
      token === '--free-bytes' ||
      token === '--cpu-parallelism' ||
      token === '--minimum-parallelism'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--output') options.outputPath = next;
      if (token === '--target-profile') options.targetProfile = normalizeText(next);
      if (token === '--total-bytes') options.totalBytes = parseByteValue(next, token);
      if (token === '--free-bytes') options.freeBytes = parseByteValue(next, token);
      if (token === '--cpu-parallelism') options.cpuParallelism = parsePositiveInteger(next, token);
      if (token === '--minimum-parallelism') options.minimumParallelism = parsePositiveInteger(next, token);
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  ensureProfile(options.targetProfile);
  return options;
}

function detectHostResources({
  totalmemFn = os.totalmem,
  freememFn = os.freemem,
  availableParallelismFn = os.availableParallelism,
} = {}) {
  return {
    totalBytes: Math.trunc(totalmemFn()),
    freeBytes: Math.trunc(freememFn()),
    cpuParallelism: Math.max(1, Math.trunc(availableParallelismFn())),
    platform: process.platform,
    arch: process.arch,
    detectionSource: 'node-os',
  };
}

function buildProfileBudget({ profileId, profile, effectiveUsableBytes, cpuParallelism, minimumParallelism, degradedByPressure }) {
  const rawMemoryCeiling = Math.floor(effectiveUsableBytes / profile.perWorkerBytes);
  const floorApplied = rawMemoryCeiling < minimumParallelism;
  const memoryBoundCeiling = Math.max(minimumParallelism, rawMemoryCeiling);
  const cpuBoundCeiling = Math.max(minimumParallelism, cpuParallelism);
  const recommendedParallelism = Math.max(
    minimumParallelism,
    Math.min(profile.maxParallelism, memoryBoundCeiling, cpuBoundCeiling),
  );

  const reasons = [];
  if (degradedByPressure) reasons.push('free-memory-pressure');
  if (floorApplied) reasons.push('deterministic-floor');
  if (recommendedParallelism === profile.maxParallelism && recommendedParallelism < memoryBoundCeiling && recommendedParallelism < cpuBoundCeiling) {
    reasons.push('profile-max-cap');
  }
  if (recommendedParallelism === cpuBoundCeiling && cpuBoundCeiling <= memoryBoundCeiling && cpuBoundCeiling <= profile.maxParallelism) {
    reasons.push('cpu-cap');
  }
  if (recommendedParallelism === memoryBoundCeiling && memoryBoundCeiling <= cpuBoundCeiling && memoryBoundCeiling <= profile.maxParallelism) {
    reasons.push('memory-cap');
  }
  if (reasons.length === 0) {
    reasons.push('balanced');
  }

  return {
    id: profileId,
    laneClass: profile.laneClass,
    perWorkerBytes: profile.perWorkerBytes,
    maxParallelism: profile.maxParallelism,
    memoryBoundCeiling,
    cpuBoundCeiling,
    recommendedParallelism,
    floorApplied,
    degradedByPressure,
    reasons,
  };
}

export function buildHostRamBudgetReport(
  {
    targetProfile = DEFAULT_TARGET_PROFILE,
    minimumParallelism = 1,
    totalBytes = null,
    freeBytes = null,
    cpuParallelism = null,
    now = new Date(),
  },
  detectionOverrides = {},
) {
  const detected = detectHostResources(detectionOverrides);
  const total = totalBytes ?? detected.totalBytes;
  const free = freeBytes ?? detected.freeBytes;
  const cpu = cpuParallelism ?? detected.cpuParallelism;
  const systemReserveBytes = Math.max(2 * 1024 * 1024 * 1024, Math.floor(total * 0.25));
  const freeReserveBytes = Math.max(1 * 1024 * 1024 * 1024, Math.floor(total * 0.10));
  const usableByTotalBytes = Math.max(0, total - systemReserveBytes);
  const usableByFreeBytes = Math.max(0, free - freeReserveBytes);
  const effectiveUsableBytes = Math.max(
    0,
    Math.min(usableByTotalBytes, usableByFreeBytes),
  );
  const degradedByPressure = usableByFreeBytes < usableByTotalBytes;

  const profiles = Object.entries(PROFILE_CATALOG).map(([profileId, profile]) =>
    buildProfileBudget({
      profileId,
      profile,
      effectiveUsableBytes,
      cpuParallelism: cpu,
      minimumParallelism,
      degradedByPressure,
    }),
  );

  const selectedProfile = profiles.find((entry) => entry.id === targetProfile);
  if (!selectedProfile) {
    throw new Error(`Target profile not found in computed report: ${targetProfile}`);
  }

  return {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    host: {
      platform: detected.platform,
      arch: detected.arch,
      detectionSource: detected.detectionSource,
      totalBytes: total,
      freeBytes: free,
      cpuParallelism: cpu,
    },
    policy: {
      minimumParallelism,
      systemReserveBytes,
      freeReserveBytes,
      usableByTotalBytes,
      usableByFreeBytes,
      effectiveUsableBytes,
    },
    profiles,
    selectedProfile,
  };
}

async function writeReport(outputPath, report) {
  const resolved = path.resolve(process.cwd(), outputPath);
  await fs.mkdir(path.dirname(resolved), { recursive: true });
  await fs.writeFile(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

function printUsage() {
  console.log('Usage: node tools/priority/host-ram-budget.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --output <path>                Output report path (default: ${DEFAULT_OUTPUT_PATH})`);
  console.log(`  --target-profile <id>          Target profile id (default: ${DEFAULT_TARGET_PROFILE})`);
  console.log('  --total-bytes <n>              Override detected total host RAM.');
  console.log('  --free-bytes <n>               Override detected free host RAM.');
  console.log('  --cpu-parallelism <n>          Override detected CPU parallelism.');
  console.log('  --minimum-parallelism <n>      Deterministic floor (default: 1).');
  console.log('  -h, --help                     Show help.');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const report = buildHostRamBudgetReport(options);
  const reportPath = await writeReport(options.outputPath, report);
  console.log(`[host-ram-budget] report: ${reportPath}`);
  console.log(`[host-ram-budget] target=${report.selectedProfile.id} recommendedParallelism=${report.selectedProfile.recommendedParallelism}`);
  return 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).then(
    (exitCode) => process.exit(exitCode),
    (error) => {
      process.stderr.write(`${error?.message || String(error)}\n`);
      process.exit(1);
    },
  );
}

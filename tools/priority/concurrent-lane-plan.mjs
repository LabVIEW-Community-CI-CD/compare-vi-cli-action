#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const CONCURRENT_LANE_PLAN_SCHEMA = 'priority/concurrent-lane-plan@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'runtime', 'concurrent-lane-plan.json');
export const DEFAULT_HOST_PLANE_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'host-planes',
  'labview-2026-host-plane-report.json'
);
export const DEFAULT_HOST_RAM_BUDGET_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'host-ram-budget.json'
);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toOptionalText(value) {
  const normalized = normalizeText(value);
  return normalized || null;
}

function normalizeAvailability(value, fallback = 'available') {
  const normalized = normalizeText(value).toLowerCase();
  if (['available', 'disabled', 'unavailable'].includes(normalized)) {
    return normalized;
  }
  return fallback;
}

function normalizeShadowMode(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (['auto', 'disabled', 'prefer'].includes(normalized)) {
    return normalized;
  }
  return 'auto';
}

function normalizeDockerServerOs(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (normalized === 'linux' || normalized === 'windows') {
    return normalized;
  }
  return 'unknown';
}

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    outputPath: DEFAULT_OUTPUT_PATH,
    hostPlaneReportPath: DEFAULT_HOST_PLANE_REPORT_PATH,
    hostRamBudgetPath: DEFAULT_HOST_RAM_BUDGET_PATH,
    dockerRuntimeSnapshotPath: '',
    hostedLinux: 'available',
    hostedWindows: 'available',
    shadowMode: 'auto',
    help: false
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
      token === '--host-plane-report' ||
      token === '--host-ram-budget' ||
      token === '--docker-runtime-snapshot' ||
      token === '--hosted-linux' ||
      token === '--hosted-windows' ||
      token === '--shadow-mode'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--output') options.outputPath = next;
      if (token === '--host-plane-report') options.hostPlaneReportPath = next;
      if (token === '--host-ram-budget') options.hostRamBudgetPath = next;
      if (token === '--docker-runtime-snapshot') options.dockerRuntimeSnapshotPath = next;
      if (token === '--hosted-linux') options.hostedLinux = normalizeAvailability(next);
      if (token === '--hosted-windows') options.hostedWindows = normalizeAvailability(next);
      if (token === '--shadow-mode') options.shadowMode = normalizeShadowMode(next);
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function getPairSet(report, key) {
  const pairs = report?.executionPolicy?.[key]?.pairs;
  return Array.isArray(pairs) ? pairs : [];
}

function pairKey(left, right) {
  return [normalizeText(left), normalizeText(right)].sort().join('::');
}

function buildPairIndex(report) {
  const index = new Set();
  for (const pair of [...getPairSet(report, 'mutuallyExclusivePairs'), ...getPairSet(report, 'provenParallelPairs'), ...getPairSet(report, 'candidateParallelPairs')]) {
    const left = normalizeText(pair?.left);
    const right = normalizeText(pair?.right);
    if (!left || !right) {
      continue;
    }
    index.add(pairKey(left, right));
  }
  return index;
}

function resolveShadowPlanePolicy(report = null) {
  const policy = report?.policy?.hostNativeShadowPlane;
  if (!policy || typeof policy !== 'object') {
    return {
      plane: 'native-labview-2026-32',
      role: 'acceleration-surface',
      authoritative: false,
      executionMode: 'manual-opt-in',
      hostedCiAllowed: false,
      promotionPrerequisites: [
        'docker-desktop/linux-container-2026',
        'docker-desktop/windows-container-2026'
      ]
    };
  }

  return {
    plane: toOptionalText(policy.plane) ?? 'native-labview-2026-32',
    role: toOptionalText(policy.role) ?? 'acceleration-surface',
    authoritative: policy.authoritative === true,
    executionMode: toOptionalText(policy.executionMode) ?? 'manual-opt-in',
    hostedCiAllowed: policy.hostedCiAllowed === true,
    promotionPrerequisites: Array.isArray(policy.promotionPrerequisites)
      ? policy.promotionPrerequisites
          .map((entry) => toOptionalText(entry))
          .filter(Boolean)
      : []
  };
}

function resolveDockerObservation(snapshot = null) {
  const observed = snapshot?.observed && typeof snapshot.observed === 'object' ? snapshot.observed : {};
  return {
    dockerServerOs: normalizeDockerServerOs(observed.osType),
    dockerContext: toOptionalText(observed.context),
    observedDockerHost: toOptionalText(observed.dockerHost),
    snapshotStatus: toOptionalText(snapshot?.result?.status) ?? 'missing'
  };
}

function buildLane({
  id,
  laneClass,
  executionPlane,
  resourceGroup,
  availability,
  reasons,
  metadata = {}
}) {
  return {
    id,
    laneClass,
    executionPlane,
    resourceGroup,
    availability,
    reasons: [...reasons],
    metadata
  };
}

function buildBundle({ id, classification, laneIds, reasons }) {
  return {
    id,
    classification,
    laneIds: [...laneIds],
    reasons: [...reasons]
  };
}

export function buildConcurrentLanePlan({
  repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  hostPlaneReport = null,
  hostRamBudget = null,
  dockerRuntimeSnapshot = null,
  hostedLinux = 'available',
  hostedWindows = 'available',
  shadowMode = 'auto',
  now = new Date()
} = {}) {
  const pairIndex = buildPairIndex(hostPlaneReport);
  const dockerObservation = resolveDockerObservation(dockerRuntimeSnapshot);
  const shadowPolicy = resolveShadowPlanePolicy(hostPlaneReport);
  const nativeX32Status = normalizeText(hostPlaneReport?.native?.planes?.x32?.status).toLowerCase() || 'missing';
  const nativeParallelLabVIEWSupported = hostPlaneReport?.native?.parallelLabVIEWSupported === true;
  const hostRamRecommendedParallelism =
    Number(hostRamBudget?.selectedProfile?.recommendedParallelism ?? 0) || 0;
  const hostRamProfile = toOptionalText(hostRamBudget?.selectedProfile?.id);
  const hostedLaneIds = [];
  const localLaneIds = [];
  const bundles = [];
  const lanes = [];
  const observations = [];

  if (normalizeAvailability(hostedLinux) === 'available') {
    hostedLaneIds.push('hosted-linux-proof');
    lanes.push(
      buildLane({
        id: 'hosted-linux-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'available',
        reasons: ['hosted-runner-independent-from-local-host']
      })
    );
  } else {
    lanes.push(
      buildLane({
        id: 'hosted-linux-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'disabled',
        reasons: ['hosted-linux-disabled']
      })
    );
  }

  if (normalizeAvailability(hostedWindows) === 'available') {
    hostedLaneIds.push('hosted-windows-proof');
    lanes.push(
      buildLane({
        id: 'hosted-windows-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'available',
        reasons: ['hosted-runner-independent-from-local-host']
      })
    );
  } else {
    lanes.push(
      buildLane({
        id: 'hosted-windows-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'disabled',
        reasons: ['hosted-windows-disabled']
      })
    );
  }

  if (dockerObservation.dockerServerOs === 'linux') {
    localLaneIds.push('manual-linux-docker');
    lanes.push(
      buildLane({
        id: 'manual-linux-docker',
        laneClass: 'manual-docker',
        executionPlane: 'local',
        resourceGroup: 'local-docker-engine',
        availability: 'available',
        reasons: ['docker-engine-linux', 'local-manual-lane-available'],
        metadata: {
          dockerContext: dockerObservation.dockerContext,
          observedDockerHost: dockerObservation.observedDockerHost
        }
      })
    );
    lanes.push(
      buildLane({
        id: 'manual-windows-docker',
        laneClass: 'manual-docker',
        executionPlane: 'local',
        resourceGroup: 'local-docker-engine',
        availability: 'unavailable',
        reasons: ['docker-engine-not-windows']
      })
    );
  } else if (dockerObservation.dockerServerOs === 'windows') {
    localLaneIds.push('manual-windows-docker');
    lanes.push(
      buildLane({
        id: 'manual-linux-docker',
        laneClass: 'manual-docker',
        executionPlane: 'local',
        resourceGroup: 'local-docker-engine',
        availability: 'unavailable',
        reasons: ['docker-engine-not-linux']
      })
    );
    lanes.push(
      buildLane({
        id: 'manual-windows-docker',
        laneClass: 'manual-docker',
        executionPlane: 'local',
        resourceGroup: 'local-docker-engine',
        availability: 'available',
        reasons: ['docker-engine-windows', 'local-manual-lane-available'],
        metadata: {
          dockerContext: dockerObservation.dockerContext,
          observedDockerHost: dockerObservation.observedDockerHost
        }
      })
    );
  } else {
    lanes.push(
      buildLane({
        id: 'manual-linux-docker',
        laneClass: 'manual-docker',
        executionPlane: 'local',
        resourceGroup: 'local-docker-engine',
        availability: 'unavailable',
        reasons: ['docker-engine-unknown']
      })
    );
    lanes.push(
      buildLane({
        id: 'manual-windows-docker',
        laneClass: 'manual-docker',
        executionPlane: 'local',
        resourceGroup: 'local-docker-engine',
        availability: 'unavailable',
        reasons: ['docker-engine-unknown']
      })
    );
  }

  const shadowRequested = normalizeShadowMode(shadowMode);
  const shadowAllowed = shadowRequested !== 'disabled' && nativeX32Status === 'ready';
  const shadowAvailability = shadowAllowed ? 'available' : shadowRequested === 'disabled' ? 'disabled' : 'unavailable';
  const shadowReasons = [];
  if (shadowRequested === 'disabled') {
    shadowReasons.push('shadow-mode-disabled');
  } else if (nativeX32Status !== 'ready') {
    shadowReasons.push('native-32-plane-not-ready');
  } else if (hostedLaneIds.length > 0) {
    shadowReasons.push('hosted-lanes-can-run-while-shadow-plane-executes');
  } else {
    shadowReasons.push('shadow-plane-ready');
  }
  lanes.push(
    buildLane({
      id: 'host-native-32-shadow',
      laneClass: 'shadow-validation',
      executionPlane: 'local-shadow',
      resourceGroup: 'local-native-shadow',
      availability: shadowAvailability,
      reasons: shadowReasons,
      metadata: {
        recommendedParallelism: hostRamRecommendedParallelism || null,
        hostRamProfile,
        plane: shadowPolicy.plane,
        role: shadowPolicy.role,
        authoritative: shadowPolicy.authoritative,
        executionMode: shadowPolicy.executionMode,
        hostedCiAllowed: shadowPolicy.hostedCiAllowed,
        promotionPrerequisites: shadowPolicy.promotionPrerequisites
      }
    })
  );

  if (hostedLaneIds.length > 0 && localLaneIds.length > 0) {
    const manualLaneId = localLaneIds[0];
    bundles.push(
      buildBundle({
        id: `hosted-plus-${manualLaneId}`,
        classification: 'recommended',
        laneIds: [...hostedLaneIds, manualLaneId],
        reasons: [
          'hosted-lanes-do-not-consume-local-docker-engine',
          'current-docker-engine-supports-manual-lane'
        ]
      })
    );
  }

  if (hostedLaneIds.length > 0 && shadowAllowed) {
    bundles.push(
      buildBundle({
        id: 'hosted-plus-host-native-32-shadow',
        classification: shadowRequested === 'prefer' ? 'recommended' : 'fallback',
        laneIds: [...hostedLaneIds, 'host-native-32-shadow'],
        reasons: [
          'hosted-lanes-remain-independent-from-local-shadow-plane',
          nativeParallelLabVIEWSupported
            ? 'native-32-plane-proven-parallel-with-native-64'
            : 'native-32-plane-ready-for-shadow-work'
        ]
      })
    );
  }

  if (hostedLaneIds.length > 0) {
    bundles.push(
      buildBundle({
        id: 'hosted-only-proof',
        classification: bundles.length === 0 ? 'recommended' : 'fallback',
        laneIds: [...hostedLaneIds],
        reasons: ['hosted-lanes-keep-local-host-free-for-coding']
      })
    );
  }

  if (hostedLaneIds.length === 0 && localLaneIds.length > 0) {
    bundles.push(
      buildBundle({
        id: `manual-only-${localLaneIds[0]}`,
        classification: bundles.length === 0 ? 'recommended' : 'fallback',
        laneIds: [localLaneIds[0]],
        reasons: ['no-hosted-lanes-available']
      })
    );
  }

  if (hostedLaneIds.length === 0 && shadowAllowed) {
    bundles.push(
      buildBundle({
        id: 'shadow-only-host-native-32',
        classification: bundles.length === 0 ? 'recommended' : 'fallback',
        laneIds: ['host-native-32-shadow'],
        reasons: ['no-hosted-lanes-available', 'native-32-plane-ready']
      })
    );
  }

  if (pairIndex.has(pairKey('docker-desktop/linux-container-2026', 'docker-desktop/windows-container-2026'))) {
    observations.push('local-docker-linux-and-windows-remain-mutually-exclusive');
  }
  if (hostRamRecommendedParallelism > 0) {
    observations.push(`host-ram-budget-recommended-parallelism-${hostRamRecommendedParallelism}`);
  }
  if (shadowAllowed && localLaneIds.length > 0) {
    observations.push('shadow-lane-kept-out-of-local-docker-bundles-until-same-host-proof-exists');
  }
  if (!shadowPolicy.authoritative) {
    observations.push('host-native-32-shadow-remains-non-authoritative');
  }

  const recommendedBundle = bundles.find((entry) => entry.classification === 'recommended') ?? null;

  return {
    schema: CONCURRENT_LANE_PLAN_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    inputs: {
      hostedLinux: normalizeAvailability(hostedLinux),
      hostedWindows: normalizeAvailability(hostedWindows),
      shadowMode: shadowRequested
    },
    host: {
      dockerServerOs: dockerObservation.dockerServerOs,
      dockerContext: dockerObservation.dockerContext,
      observedDockerHost: dockerObservation.observedDockerHost,
      hostRamProfile,
      hostRamRecommendedParallelism: hostRamRecommendedParallelism || null,
      native32Status: nativeX32Status,
      nativeParallelLabVIEWSupported
    },
    lanes,
    bundles,
    recommendedBundle,
    observations,
    summary: {
      availableLaneCount: lanes.filter((entry) => entry.availability === 'available').length,
      hostedLaneCount: hostedLaneIds.length,
      localLaneCount: localLaneIds.length + (shadowAllowed ? 1 : 0),
      recommendedBundleId: recommendedBundle?.id ?? null
    }
  };
}

async function writeReport(outputPath, report) {
  const resolved = path.resolve(process.cwd(), outputPath);
  await fs.mkdir(path.dirname(resolved), { recursive: true });
  await fs.writeFile(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

function printUsage() {
  console.log('Usage: node tools/priority/concurrent-lane-plan.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --output <path>                  Output report path (default: ${DEFAULT_OUTPUT_PATH})`);
  console.log(`  --host-plane-report <path>       Host plane report path (default: ${DEFAULT_HOST_PLANE_REPORT_PATH})`);
  console.log(`  --host-ram-budget <path>         Host RAM budget path (default: ${DEFAULT_HOST_RAM_BUDGET_PATH})`);
  console.log('  --docker-runtime-snapshot <path> Optional docker-runtime-determinism receipt.');
  console.log('  --hosted-linux <state>           available|disabled (default: available)');
  console.log('  --hosted-windows <state>         available|disabled (default: available)');
  console.log('  --shadow-mode <mode>             auto|disabled|prefer (default: auto)');
  console.log('  -h, --help                       Show help.');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const hostPlaneReport = await readJsonIfPresent(path.resolve(process.cwd(), options.hostPlaneReportPath));
  const hostRamBudget = await readJsonIfPresent(path.resolve(process.cwd(), options.hostRamBudgetPath));
  const dockerRuntimeSnapshot = options.dockerRuntimeSnapshotPath
    ? await readJsonIfPresent(path.resolve(process.cwd(), options.dockerRuntimeSnapshotPath))
    : null;
  const report = buildConcurrentLanePlan({
    hostPlaneReport,
    hostRamBudget,
    dockerRuntimeSnapshot,
    hostedLinux: options.hostedLinux,
    hostedWindows: options.hostedWindows,
    shadowMode: options.shadowMode
  });
  const outputPath = await writeReport(options.outputPath, report);
  console.log(
    `[concurrent-lane-plan] report=${outputPath} recommended=${report.summary.recommendedBundleId ?? 'none'} available=${report.summary.availableLaneCount}`
  );
  if (report.recommendedBundle) {
    console.log(
      `[concurrent-lane-plan] bundle=${report.recommendedBundle.id} lanes=${report.recommendedBundle.laneIds.join(',')}`
    );
  }
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
    }
  );
}

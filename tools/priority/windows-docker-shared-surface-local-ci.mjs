#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import yaml from 'js-yaml';

import {
  buildWindowsPowerShellFileBridgeSpec,
  detectWindowsHostBridge,
  resolveRepoWindowsPath,
  runBridgeSpec,
} from './windows-host-bridge.mjs';

const repoRootDefault = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const defaultSkillRoot = path.join(process.env.HOME ?? '', '.codex', 'skills', 'repo-standards-review');
const fallbackSkillRoot = '/mnt/c/Users/sveld/.codex/skills/repo-standards-review';

const DEFAULT_SURFACE = path.join('tools', 'priority', 'windows-docker-shared-surface-audit-surface.yaml');
const DEFAULT_POLICY = path.join('tools', 'priority', 'windows-docker-shared-surface-autonomy-policy.json');
const DEFAULT_RESULTS_DIR = path.join('tests', 'results', '_agent', 'windows-docker-shared-surface', 'local-ci');
const DEFAULT_REPORT = path.join(DEFAULT_RESULTS_DIR, 'windows-docker-shared-surface-local-ci-report.json');
const DEFAULT_SUMMARY = path.join(DEFAULT_RESULTS_DIR, 'windows-docker-shared-surface-local-ci-summary.md');
const DEFAULT_NEXT = path.join(DEFAULT_RESULTS_DIR, 'windows-docker-shared-surface-next-requirement.json');
const DEFAULT_NEXT_STEP = path.join(DEFAULT_RESULTS_DIR, 'windows-docker-shared-surface-next-step.json');

const HELP = [
  'Usage: node tools/priority/windows-docker-shared-surface-local-ci.mjs [options]',
  '',
  'Options:',
  `  --repo-root <path>      (default: ${repoRootDefault})`,
  `  --skill-root <path>     (default: ${defaultSkillRoot} or ${fallbackSkillRoot})`,
  `  --surface <path>        (default: ${DEFAULT_SURFACE})`,
  `  --policy <path>         (default: ${DEFAULT_POLICY})`,
  `  --results-dir <path>    (default: ${DEFAULT_RESULTS_DIR})`,
  `  --output <path>         (default: ${DEFAULT_REPORT})`,
  `  --summary-output <path> (default: ${DEFAULT_SUMMARY})`,
  `  --next-output <path>    (default: ${DEFAULT_NEXT})`,
  `  --next-step-output <path> (default: ${DEFAULT_NEXT_STEP})`,
  '  --print-next            print the selected next requirement to stdout',
  '  --print-next-step       print the selected next step to stdout',
  '  --help, -h'
];

function parseArgs(argv = process.argv) {
  const options = {
    repoRoot: repoRootDefault,
    skillRoot: null,
    surfacePath: DEFAULT_SURFACE,
    policyPath: DEFAULT_POLICY,
    resultsDir: DEFAULT_RESULTS_DIR,
    outputPath: DEFAULT_REPORT,
    summaryPath: DEFAULT_SUMMARY,
    nextOutputPath: DEFAULT_NEXT,
    nextStepOutputPath: DEFAULT_NEXT_STEP,
    printNext: false,
    printNextStep: false,
    help: false
  };

  const args = argv.slice(2);
  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    const next = args[i + 1];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--print-next') {
      options.printNext = true;
      continue;
    }
    if (token === '--print-next-step') {
      options.printNextStep = true;
      continue;
    }
    if (['--repo-root', '--skill-root', '--surface', '--policy', '--results-dir', '--output', '--summary-output', '--next-output', '--next-step-output'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}`);
      }
      i += 1;
      if (token === '--repo-root') options.repoRoot = path.resolve(next);
      if (token === '--skill-root') options.skillRoot = path.resolve(next);
      if (token === '--surface') options.surfacePath = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--results-dir') options.resultsDir = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--summary-output') options.summaryPath = next;
      if (token === '--next-output') options.nextOutputPath = next;
      if (token === '--next-step-output') options.nextStepOutputPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  for (const line of HELP) console.log(line);
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function resolveSkillRoot(explicitRoot) {
  if (explicitRoot) return explicitRoot;
  const candidates = [];
  if (process.env.CODEX_HOME) {
    candidates.push(path.join(process.env.CODEX_HOME, 'skills', 'repo-standards-review'));
  }
  candidates.push(defaultSkillRoot, fallbackSkillRoot);
  for (const candidate of candidates) {
    if (await fileExists(candidate)) return candidate;
  }
  return defaultSkillRoot;
}

async function readYaml(filePath) {
  return yaml.load(await fs.readFile(filePath, 'utf8'));
}

async function ensureDir(filePath) {
  await fs.mkdir(filePath, { recursive: true });
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

function relativeFrom(repoRoot, filePath) {
  return path.relative(repoRoot, filePath).split(path.sep).join('/');
}

async function materializeAuditSurface(repoRoot, manifest, bundleRoot) {
  await ensureDir(bundleRoot);
  for (const relativePath of manifest.include) {
    const source = path.join(repoRoot, relativePath);
    const destination = path.join(bundleRoot, relativePath);
    await ensureDir(path.dirname(destination));
    await fs.copyFile(source, destination);
  }
}

function createRunScopedBundleRoot(resultsDir) {
  const runId = `run-${Date.now()}-${process.pid}-${Math.random().toString(16).slice(2, 8)}`;
  return path.join(resultsDir, 'surface-bundle', runId);
}

function runCommand(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: 'utf8',
    maxBuffer: 20 * 1024 * 1024
  });
  if (result.status !== 0) {
    throw new Error([`${command} ${args.join(' ')}`, result.stdout?.trim(), result.stderr?.trim()].filter(Boolean).join('\n'));
  }
  return result;
}

function parseCsv(input) {
  const rows = [];
  let current = '';
  let row = [];
  let inQuotes = false;

  for (let i = 0; i < input.length; i += 1) {
    const char = input[i];
    const next = input[i + 1];
    if (char === '"') {
      if (inQuotes && next === '"') {
        current += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (char === ',' && !inQuotes) {
      row.push(current);
      current = '';
      continue;
    }
    if ((char === '\n' || char === '\r') && !inQuotes) {
      if (char === '\r' && next === '\n') i += 1;
      row.push(current);
      current = '';
      if (row.some((value) => value.length > 0)) rows.push(row);
      row = [];
      continue;
    }
    current += char;
  }

  if (current.length > 0 || row.length > 0) {
    row.push(current);
    if (row.some((value) => value.length > 0)) rows.push(row);
  }

  if (rows.length === 0) return [];
  const [header, ...records] = rows;
  return records.map((values) => {
    const entry = {};
    for (let i = 0; i < header.length; i += 1) {
      entry[header[i]] = values[i] ?? '';
    }
    return entry;
  });
}

function parseRequirementNumber(reqId) {
  const match = /REQ-WDSS-(\d+)/.exec(reqId ?? '');
  return match ? Number.parseInt(match[1], 10) : Number.POSITIVE_INFINITY;
}

function determinePhase(reqNumber) {
  if (reqNumber <= 3) return 'foundation';
  return 'autonomy';
}

function splitField(value) {
  return String(value ?? '')
    .split(';')
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function isOperationalRef(ref) {
  return !String(ref).startsWith('docs/');
}

function collectWorktreeStatus(repoRoot) {
  const result = runCommand('git', ['status', '--short', '--branch'], { cwd: repoRoot });
  const lines = result.stdout.split(/\r?\n/).filter(Boolean);
  const branch = (lines.find((line) => line.startsWith('## ')) ?? '## detached').replace(/^##\s+/, '');
  const modifiedPaths = lines
    .filter((line) => !line.startsWith('## '))
    .map((line) => line.slice(3).trim())
    .filter(Boolean);
  return { branch, modifiedPaths };
}

function deriveWeakAreas(scorePayload) {
  return Object.entries(scorePayload.areas ?? {})
    .filter(([, details]) => Number(details.score ?? 0) < 3)
    .map(([area]) => area);
}

function scoreGap(row) {
  const reqNumber = parseRequirementNumber(row.ReqID);
  const phase = determinePhase(reqNumber);
  const priorityWeight = row.Priority === 'High' ? 200 : row.Priority === 'Medium' ? 100 : 50;
  const phaseWeight = phase === 'foundation' ? 300 : 180;
  const runtimeWeight = /(Invoke-PesterWindowsContainerSurfaceProbe|Test-WindowsNI2026q1HostPreflight|Run-NIWindowsContainerCompare|windows-docker-shared-surface-local-ci)/.test(row.CodeRef) ? 40 : 0;
  return 1000 + priorityWeight + phaseWeight + runtimeWeight - reqNumber;
}

function deriveSuggestedLoop(row) {
  const codeRefs = splitField(row.CodeRef);
  const actions = [];
  actions.push(`Start with ${row.TestID}: tighten shared Windows-surface proof coverage before spending GitHub CI.`);
  if (codeRefs.length > 0) {
    actions.push(`Edit the primary source targets first: ${codeRefs.slice(0, 3).join(', ')}.`);
  }
  actions.push('Re-run the shared-surface local CI and next-step entrypoints after the change.');
  return actions;
}

function buildRequirementEntry(row, overrides = {}) {
  const reqNumber = parseRequirementNumber(row.ReqID);
  const phase = determinePhase(reqNumber);
  return {
    req_id: row.ReqID,
    priority: row.Priority,
    status: overrides.status ?? row.Status,
    phase,
    score: scoreGap(row) + (overrides.scoreBoost ?? 0),
    why_now: overrides.why_now ?? `${row.ReqID} is an unresolved ${row.Priority} ${phase} shared-surface gap.`,
    requirement: row.Requirement,
    test_id: row.TestID,
    test_artifact: row.TestArtifact,
    code_refs: splitField(row.CodeRef),
    suggested_loop: overrides.suggested_loop ?? deriveSuggestedLoop(row),
    proof_check_id: overrides.proof_check_id ?? null
  };
}

function rankRequirementGaps(rows) {
  return rows
    .filter((row) => row.Status !== 'Implemented')
    .map((row) => buildRequirementEntry(row))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return parseRequirementNumber(a.req_id) - parseRequirementNumber(b.req_id);
    })
    .map((entry, index) => ({ rank: index + 1, ...entry }));
}

function rankProofRegressions(proofChecks, rows) {
  const byReqId = new Map(rows.map((row) => [row.ReqID, row]));
  return proofChecks
    .filter((check) => check.status === 'fail' && check.owner_requirement && byReqId.has(check.owner_requirement))
    .map((check) => {
      const row = byReqId.get(check.owner_requirement);
      return buildRequirementEntry(row, {
        status: 'Regression',
        scoreBoost: 5000,
        why_now: `${row.ReqID} regressed under the shared-surface proof check '${check.id}': ${check.summary}`,
        suggested_loop: [
          `Start with proof check ${check.id}: ${check.summary}`,
          ...deriveSuggestedLoop(row)
        ],
        proof_check_id: check.id
      });
    })
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return parseRequirementNumber(a.req_id) - parseRequirementNumber(b.req_id);
    });
}

function applyAutonomyPolicy(rankedRequirements, policy, modifiedPaths) {
  const modifiedSet = new Set(modifiedPaths);
  return rankedRequirements
    .map((item) => {
      const phasePolicy = policy.phase_guidance?.[item.phase] ?? {};
      const activeNow = item.code_refs.some((ref) => isOperationalRef(ref) && modifiedSet.has(ref));
      return {
        ...item,
        active_now: activeNow,
        mode: phasePolicy.mode ?? 'local-first',
        preferred_commands: phasePolicy.preferred_commands ?? [],
        stop_conditions: phasePolicy.stop_conditions ?? [],
        escalate_when: phasePolicy.escalate_when ?? []
      };
    })
    .sort((a, b) => {
      if (a.active_now !== b.active_now) return a.active_now ? -1 : 1;
      if (b.score !== a.score) return b.score - a.score;
      return parseRequirementNumber(a.req_id) - parseRequirementNumber(b.req_id);
    })
    .map((entry, index) => ({ ...entry, rank: index + 1 }));
}

function portablePath(pathValue) {
  return String(pathValue ?? '').replace(/\\/g, '/');
}

function getManagedRootRisks(pathValue) {
  const normalized = portablePath(pathValue);
  const risks = [];
  if (/(^|\/)OneDrive(?:\/|$|[\s-])/i.test(normalized)) {
    risks.push({
      id: 'onedrive-managed-root',
      message: 'Path appears to live under a OneDrive-managed root.'
    });
  }
  return risks;
}

async function writeJson(filePath, payload) {
  await ensureDir(path.dirname(filePath));
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), 'utf8');
}

async function validateJsonAgainstSchema(repoRoot, schemaRelativePath, payload, label) {
  const schemaPath = path.join(repoRoot, schemaRelativePath);
  const schema = await readJson(schemaPath);
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const ok = validate(payload);
  if (!ok) {
    const details = (validate.errors ?? []).map((entry) => `${entry.instancePath || '/'} ${entry.message}`).join('; ');
    throw new Error(`${label} schema validation failed: ${details}`);
  }
}

async function validateReportSchema(repoRoot, report) {
  await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'windows-docker-shared-surface-local-ci-report-v1.schema.json'), report, 'Windows Docker shared surface local CI report');
}

async function validateNextStepSchema(repoRoot, nextStep) {
  await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'windows-docker-shared-surface-next-step-v1.schema.json'), nextStep, 'Windows Docker shared surface next-step');
}

async function runPathHygieneProof(repoRoot, resultsDir) {
  const proofDir = path.join(resultsDir, 'path-hygiene');
  const receiptPath = path.join(proofDir, 'windows-docker-shared-surface-path-hygiene.json');
  await fs.rm(proofDir, { recursive: true, force: true });
  await ensureDir(proofDir);

  const evaluatedPaths = [
    { id: 'repo-root', path: repoRoot },
    { id: 'results-root', path: resultsDir }
  ];
  const findings = evaluatedPaths.flatMap((entry) =>
    getManagedRootRisks(entry.path).map((risk) => ({
      scope: entry.id,
      path: portablePath(entry.path),
      ...risk
    }))
  );

  const receipt = {
    schema: 'comparevi/windows-docker-shared-surface-path-hygiene@v1',
    generatedAt: new Date().toISOString(),
    status: findings.length > 0 ? 'unsafe-synced-root' : 'safe',
    findings,
    evaluatedPaths,
    recommendedCommands: findings.length > 0
      ? [
          'Move or clone the repo to a non-OneDrive local path before running Windows Docker proof.',
          'Set a safe local results root before running the shared Windows surface loop.',
          'npm run priority:windows-surface:local-ci'
        ]
      : []
  };
  await writeJson(receiptPath, receipt);

  if (findings.length > 0) {
    return {
      id: 'path-hygiene',
      owner_requirement: 'REQ-WDSS-003',
      status: 'advisory',
      blocking: false,
      summary: 'The shared Windows surface is currently rooted in a synchronized or externally managed path.',
      current_surface_status: receipt.status,
      current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
      reason: 'OneDrive-like managed roots can mutate artifacts during live Windows proof.',
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: receipt.recommendedCommands
    };
  }

  return {
    id: 'path-hygiene',
    owner_requirement: 'REQ-WDSS-003',
    status: 'pass',
    blocking: false,
    summary: 'The shared Windows surface packet is rooted in paths that do not appear OneDrive-managed.',
    current_surface_status: receipt.status,
    current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
    reason: 'No OneDrive-like managed roots were detected for the shared-surface loop.',
    receipt_path: relativeFrom(repoRoot, receiptPath),
    recommended_commands: []
  };
}

async function runWindowsSurfaceProof(repoRoot, resultsDir) {
  const proofDir = path.join(resultsDir, 'windows-surface');
  const receiptPath = path.join(proofDir, 'pester-windows-container-surface.json');
  await fs.rm(proofDir, { recursive: true, force: true });
  await ensureDir(proofDir);
  const recommendedCommands = [
    'npm run docker:ni:windows:bootstrap',
    'npm run compare:docker:ni:windows:probe',
    'npm run compare:docker:ni:windows'
  ];
  const bridge = detectWindowsHostBridge(repoRoot);

  let probeResult;
  if (process.platform === 'win32') {
    probeResult = spawnSync('pwsh', [
      '-NoLogo',
      '-NoProfile',
      '-File',
      'tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1',
      '-ResultsDir',
      proofDir
    ], {
      cwd: repoRoot,
      encoding: 'utf8',
      maxBuffer: 20 * 1024 * 1024
    });
  } else if (bridge.status === 'reachable') {
    const proofDirWindows = resolveRepoWindowsPath(proofDir);
    const bridgeSpec = buildWindowsPowerShellFileBridgeSpec({
      bridge,
      scriptRelativePath: path.join('tools', 'Invoke-PesterWindowsContainerSurfaceProbe.ps1'),
      scriptArgs: ['-ResultsDir', proofDirWindows]
    });
    probeResult = runBridgeSpec(bridgeSpec, { cwd: repoRoot });
  } else {
    return {
      id: 'windows-surface',
      owner_requirement: 'REQ-WDSS-001',
      status: 'advisory',
      blocking: false,
      summary: 'The shared Windows Docker surface is unavailable because no reachable Windows host bridge is available from the current coordinator.',
      current_surface_status: 'windows-host-bridge-unavailable',
      current_host_platform: bridge.current_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      bridge_mode: bridge.bridge_mode ?? 'none',
      reason: bridge.reason,
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: recommendedCommands
    };
  }

  if (probeResult.status !== 0) {
    return {
      id: 'windows-surface',
      owner_requirement: 'REQ-WDSS-001',
      status: 'fail',
      blocking: true,
      summary: 'The shared Windows surface probe failed before it could emit a bounded receipt.',
      current_surface_status: 'probe-failed',
      current_host_platform: bridge.current_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      bridge_mode: bridge.bridge_mode ?? (process.platform === 'win32' ? 'native-windows' : 'none'),
      reason: 'Invoke-PesterWindowsContainerSurfaceProbe.ps1 failed.',
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: recommendedCommands,
      details: [probeResult.stdout?.trim(), probeResult.stderr?.trim()].filter(Boolean)
    };
  }

  let receipt;
  try {
    receipt = await readJson(receiptPath);
  } catch (error) {
    return {
      id: 'windows-surface',
      owner_requirement: 'REQ-WDSS-001',
      status: 'fail',
      blocking: true,
      summary: 'The shared Windows surface probe completed without writing its receipt.',
      current_surface_status: 'missing-receipt',
      current_host_platform: bridge.current_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      bridge_mode: bridge.bridge_mode ?? (process.platform === 'win32' ? 'native-windows' : 'none'),
      reason: error instanceof Error ? error.message : String(error),
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: ['npm run tests:windows-surface:probe']
    };
  }

  const advisory = receipt.status !== 'ready';
  return {
    id: 'windows-surface',
    owner_requirement: 'REQ-WDSS-001',
    status: advisory ? 'advisory' : 'pass',
    blocking: false,
    summary: advisory
      ? `The shared Windows Docker surface is ${receipt.status}; additional host preparation is required before live proof.`
      : 'The shared Windows Docker surface is ready for live proof.',
    current_surface_status: receipt.status,
    current_host_platform: receipt.hostPlatform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
    coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
    bridge_mode: bridge.bridge_mode ?? (process.platform === 'win32' ? 'native-windows' : 'none'),
    reason: receipt.reason ?? 'unknown',
    receipt_path: relativeFrom(repoRoot, receiptPath),
    recommended_commands: receipt.recommendedCommands ?? recommendedCommands
  };
}

async function runWindowsHostPreflightProof(repoRoot, resultsDir) {
  const proofDir = path.join(resultsDir, 'host-preflight');
  const receiptPath = path.join(proofDir, 'windows-ni-2026q1-host-preflight.json');
  await fs.rm(proofDir, { recursive: true, force: true });
  await ensureDir(proofDir);
  const recommendedCommands = [
    'npm run docker:ni:windows:bootstrap',
    'npm run compare:docker:ni:windows:probe'
  ];
  const bridge = detectWindowsHostBridge(repoRoot);

  let preflightResult;
  if (process.platform === 'win32') {
    preflightResult = spawnSync('pwsh', [
      '-NoLogo',
      '-NoProfile',
      '-File',
      'tools/Test-WindowsNI2026q1HostPreflight.ps1',
      '-ResultsDir',
      proofDir,
      '-AllowUnavailable'
    ], {
      cwd: repoRoot,
      encoding: 'utf8',
      maxBuffer: 20 * 1024 * 1024
    });
  } else if (bridge.status === 'reachable') {
    const proofDirWindows = resolveRepoWindowsPath(proofDir);
    const bridgeSpec = buildWindowsPowerShellFileBridgeSpec({
      bridge,
      scriptRelativePath: path.join('tools', 'Test-WindowsNI2026q1HostPreflight.ps1'),
      scriptArgs: ['-ResultsDir', proofDirWindows, '-AllowUnavailable']
    });
    preflightResult = runBridgeSpec(bridgeSpec, { cwd: repoRoot });
  } else {
    return {
      id: 'windows-host-preflight',
      owner_requirement: 'REQ-WDSS-002',
      status: 'advisory',
      blocking: false,
      summary: 'Deterministic Windows host preflight is unavailable because no reachable Windows host bridge is available from the current coordinator.',
      current_surface_status: 'windows-host-bridge-unavailable',
      current_host_platform: bridge.current_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      bridge_mode: bridge.bridge_mode ?? 'none',
      reason: bridge.reason,
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: recommendedCommands
    };
  }

  if (preflightResult.status !== 0) {
    return {
      id: 'windows-host-preflight',
      owner_requirement: 'REQ-WDSS-002',
      status: 'fail',
      blocking: true,
      summary: 'The deterministic Windows host preflight failed before it could emit its bounded receipt.',
      current_surface_status: 'preflight-failed',
      current_host_platform: bridge.current_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      bridge_mode: bridge.bridge_mode ?? (process.platform === 'win32' ? 'native-windows' : 'none'),
      reason: 'Test-WindowsNI2026q1HostPreflight.ps1 failed.',
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: recommendedCommands,
      details: [preflightResult.stdout?.trim(), preflightResult.stderr?.trim()].filter(Boolean)
    };
  }

  let receipt;
  try {
    receipt = await readJson(receiptPath);
  } catch (error) {
    return {
      id: 'windows-host-preflight',
      owner_requirement: 'REQ-WDSS-002',
      status: 'fail',
      blocking: true,
      summary: 'Deterministic Windows host preflight completed without emitting its receipt.',
      current_surface_status: 'missing-receipt',
      current_host_platform: bridge.current_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
      bridge_mode: bridge.bridge_mode ?? (process.platform === 'win32' ? 'native-windows' : 'none'),
      reason: error instanceof Error ? error.message : String(error),
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: recommendedCommands
    };
  }

  const advisory = receipt.status !== 'ready';
  return {
    id: 'windows-host-preflight',
    owner_requirement: 'REQ-WDSS-002',
    status: advisory ? 'advisory' : 'pass',
    blocking: false,
    summary: advisory
      ? `Deterministic Windows host preflight is ${receipt.status}; additional host preparation is required before live proof.`
      : 'Deterministic Windows host preflight is ready for shared local proof.',
    current_surface_status: receipt.status,
    current_host_platform: 'Windows',
    coordinator_host_platform: bridge.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
    bridge_mode: bridge.bridge_mode ?? (process.platform === 'win32' ? 'native-windows' : 'none'),
    reason: receipt.failureMessage || receipt.failureClass || 'ready',
    receipt_path: relativeFrom(repoRoot, receiptPath),
    recommended_commands: recommendedCommands
  };
}

function deriveEscalations(proofChecks) {
  return proofChecks
    .filter((check) => check.status === 'advisory')
    .map((check) => {
      if (check.id === 'path-hygiene') {
        return {
          type: 'escalation',
          escalation_id: 'local-safe-root',
          governing_requirement: 'REQ-WDSS-003',
          blocked_requirement: 'REQ-WDSS-003',
          proof_check_id: check.id,
          status: 'required',
          mode: 'escalate',
          why_now: 'The shared Windows surface should not run from a OneDrive-like or externally managed root.',
          reason: check.reason,
          required_surface: 'local-safe-root',
          current_surface_status: check.current_surface_status ?? 'unknown',
          current_host_platform: check.current_host_platform ?? 'unknown',
          receipt_path: check.receipt_path ?? null,
          suggested_loop: [
            'Relocate the repo and results roots to a non-synchronized local path.',
            'Re-run the shared-surface local CI before choosing Windows live proof.',
            'Do not spend GitHub CI on a Windows surface rooted in a managed sync path.'
          ],
          recommended_commands: check.recommended_commands ?? [],
          stop_conditions: [
            'Stop once the path-hygiene receipt reaches status=safe.',
            'Stop if a different synchronized-root risk appears that requires broader path governance.'
          ]
        };
      }

      return {
        type: 'escalation',
        escalation_id: 'windows-docker-desktop-ni-image',
        governing_requirement: 'REQ-WDSS-005',
        blocked_requirement: 'REQ-WDSS-001',
        proof_check_id: check.id,
        status: 'required',
        mode: 'escalate',
        why_now: 'The next truthful shared-surface proof is unavailable from the current host.',
        reason: check.current_host_platform === 'Unix'
          ? 'Current host is not Windows, so the shared Windows Docker Desktop + NI image surface cannot be exercised here.'
          : `Shared Windows surface reported ${check.current_surface_status}; prepare the host before another live proof.`,
        required_surface: 'windows-docker-desktop-ni-image',
        current_surface_status: check.current_surface_status ?? 'unknown',
        current_host_platform: check.current_host_platform ?? 'unknown',
        receipt_path: check.receipt_path ?? null,
        suggested_loop: [
          'Move to a Windows host with Docker Desktop configured for Windows containers.',
          'Bootstrap or verify the pinned NI Windows image before running a live proof.',
          'Re-run the shared Windows-surface loop before choosing a hosted rerun.'
        ],
        recommended_commands: check.recommended_commands ?? [],
        stop_conditions: [
          'Stop once the shared Windows surface probe reaches status=ready.',
          'Stop if the probe exposes a new blocking host or image defect.'
        ]
      };
    });
}

function selectNextStep(nextRequirement, escalations) {
  if (nextRequirement) return { type: 'requirement', ...nextRequirement };
  return escalations[0] ?? null;
}

function buildSummary(report) {
  const lines = [
    '# Windows Docker Shared Surface Local CI',
    '',
    `- Overall: ${report.overall.status}`,
    `- Reason: ${report.overall.reason}`,
    `- Standards audit: ${report.standards_audit.status}`,
    `- Requirements: ${report.requirement_summary.implemented}/${report.requirement_summary.total} implemented`,
    `- Gaps: ${report.requirement_summary.gaps}`,
    `- Proof checks: ${report.proof_checks.blocking_failures} blocking, ${report.proof_checks.advisories} advisory`,
    ''
  ];

  if (report.next_step?.type === 'requirement' && report.next_requirement) {
    lines.push('## Next Step', '');
    lines.push('- Type: requirement');
    lines.push(`- ${report.next_requirement.req_id}`);
    lines.push(`- Why now: ${report.next_requirement.why_now}`);
    lines.push(`- Test: ${report.next_requirement.test_id}`);
    lines.push('');
  }

  if (report.next_step?.type === 'escalation') {
    lines.push('## Next Step', '');
    lines.push('- Type: escalation');
    lines.push(`- Escalation: ${report.next_step.escalation_id}`);
    lines.push(`- Governing requirement: ${report.next_step.governing_requirement}`);
    lines.push(`- Blocked requirement: ${report.next_step.blocked_requirement}`);
    lines.push(`- Required surface: ${report.next_step.required_surface}`);
    lines.push(`- Reason: ${report.next_step.reason}`);
    lines.push('');
  }

  if (report.proof_checks.checks.length > 0) {
    lines.push('## Proof Checks', '');
    for (const check of report.proof_checks.checks) {
      lines.push(`- ${check.id}: ${check.status}`);
      lines.push(`  ${check.summary}`);
    }
    lines.push('');
  }

  return `${lines.join('\n')}\n`;
}

export {
  applyAutonomyPolicy,
  deriveEscalations,
  determinePhase,
  parseCsv,
  parseRequirementNumber,
  rankProofRegressions,
  rankRequirementGaps,
  runPathHygieneProof,
  runWindowsHostPreflightProof,
  runWindowsSurfaceProof,
  selectNextStep
};

export async function runWindowsDockerSharedSurfaceLocalCi({
  repoRoot = repoRootDefault,
  skillRoot = null,
  surfacePath = DEFAULT_SURFACE,
  policyPath = DEFAULT_POLICY,
  resultsDir = DEFAULT_RESULTS_DIR,
  outputPath = DEFAULT_REPORT,
  summaryPath = DEFAULT_SUMMARY,
  nextOutputPath = DEFAULT_NEXT,
  nextStepOutputPath = DEFAULT_NEXT_STEP
} = {}) {
  const resolvedSkillRoot = await resolveSkillRoot(skillRoot);
  const resolved = {
    repoRoot,
    skillRoot: resolvedSkillRoot,
    surfacePath: path.join(repoRoot, surfacePath),
    policyPath: path.join(repoRoot, policyPath),
    resultsDir: path.join(repoRoot, resultsDir),
    outputPath: path.join(repoRoot, outputPath),
    summaryPath: path.join(repoRoot, summaryPath),
    nextOutputPath: path.join(repoRoot, nextOutputPath),
    nextStepOutputPath: path.join(repoRoot, nextStepOutputPath)
  };

  const manifest = await readYaml(resolved.surfacePath);
  const policy = await readJson(resolved.policyPath);
  const bundleRoot = createRunScopedBundleRoot(resolved.resultsDir);
  await ensureDir(resolved.resultsDir);
  await materializeAuditSurface(repoRoot, manifest, bundleRoot);

  const evidencePath = path.join(resolved.resultsDir, 'standards-evidence.json');
  const scorePath = path.join(resolved.resultsDir, 'standards-score.json');
  const rtmPath = path.join(repoRoot, 'docs', 'rtm-windows-docker-shared-surface.csv');
  const rtmRows = parseCsv(await fs.readFile(rtmPath, 'utf8'));

  const evidence = runCommand('python3', [
    path.join(resolvedSkillRoot, 'scripts', 'repo_evidence_scan.py'),
    bundleRoot,
    '--format',
    'json',
    '--profile',
    'quick-triage',
    '--max-examples',
    '2',
    '--max-evidence-per-rule',
    '2'
  ], { cwd: repoRoot }).stdout;
  await fs.writeFile(evidencePath, evidence, 'utf8');

  const score = runCommand('python3', [
    path.join(resolvedSkillRoot, 'scripts', 'score_assurance.py'),
    evidencePath,
    '--format',
    'json'
  ], { cwd: repoRoot }).stdout;
  await fs.writeFile(scorePath, score, 'utf8');

  const scorePayload = JSON.parse(score);
  const worktreeStatus = collectWorktreeStatus(repoRoot);
  const proofChecks = [
    await runPathHygieneProof(repoRoot, resolved.resultsDir),
    await runWindowsSurfaceProof(repoRoot, resolved.resultsDir),
    await runWindowsHostPreflightProof(repoRoot, resolved.resultsDir)
  ];
  const proofRegressions = rankProofRegressions(proofChecks, rtmRows);
  const rankedRequirementGaps = rankRequirementGaps(rtmRows);
  const regressionReqIds = new Set(proofRegressions.map((item) => item.req_id));
  const rankedRequirements = applyAutonomyPolicy([
    ...proofRegressions,
    ...rankedRequirementGaps.filter((item) => !regressionReqIds.has(item.req_id))
  ], policy, worktreeStatus.modifiedPaths);
  const escalations = deriveEscalations(proofChecks);
  const nextRequirement = rankedRequirements[0] ?? null;
  const nextStep = selectNextStep(nextRequirement, escalations);
  const implementedCount = rtmRows.filter((row) => row.Status === 'Implemented').length;
  const gapCount = rankedRequirements.length;
  const blockingProofFailures = proofChecks.filter((check) => check.blocking).length;
  const advisoryProofChecks = proofChecks.filter((check) => check.status === 'advisory').length;
  const overallStatus = gapCount === 0 && blockingProofFailures === 0
    ? (advisoryProofChecks > 0 ? 'pass-with-advisories' : 'pass')
    : 'pass-with-actions';
  const overallReason = nextStep?.type === 'escalation'
    ? `All tracked Windows shared-surface requirements are implemented locally, and the next step is escalation '${nextStep.escalation_id}' because additional preparation is required before the next truthful proof.`
    : gapCount === 0
      ? 'All tracked Windows shared-surface requirements are currently marked implemented.'
      : `The next recommended Windows shared-surface requirement is ${nextRequirement.req_id} because it is the highest-ranked unresolved shared-surface gap.`;

  const report = {
    schema_version: '1.0.0',
    generated_at: new Date().toISOString(),
    repo_root: repoRoot,
    audit_surface: {
      id: manifest.id,
      description: manifest.description,
      manifest_path: relativeFrom(repoRoot, resolved.surfacePath),
      bundle_root: relativeFrom(repoRoot, bundleRoot),
      included_paths: manifest.include
    },
    worktree_status: {
      branch: worktreeStatus.branch,
      modified_paths: worktreeStatus.modifiedPaths,
      active_requirement_refs: rankedRequirements.filter((item) => item.active_now).map((item) => item.req_id)
    },
    standards_audit: {
      status: deriveWeakAreas(scorePayload).length === 0 ? 'pass' : 'pass-with-actions',
      evidence_path: relativeFrom(repoRoot, evidencePath),
      score_path: relativeFrom(repoRoot, scorePath),
      weak_areas: deriveWeakAreas(scorePayload)
    },
    requirement_summary: {
      total: rtmRows.length,
      implemented: implementedCount,
      gaps: gapCount
    },
    proof_checks: {
      blocking_failures: blockingProofFailures,
      advisories: advisoryProofChecks,
      checks: proofChecks
    },
    ranked_requirements: rankedRequirements,
    escalations,
    next_requirement: nextRequirement,
    next_step: nextStep,
    overall: {
      status: overallStatus,
      reason: overallReason
    }
  };

  await validateReportSchema(repoRoot, report);
  await writeJson(resolved.outputPath, report);
  await writeJson(resolved.nextOutputPath, nextRequirement);
  await validateNextStepSchema(repoRoot, nextStep);
  await writeJson(resolved.nextStepOutputPath, nextStep);
  await fs.writeFile(resolved.summaryPath, buildSummary(report), 'utf8');

  return { report, paths: resolved };
}

async function main() {
  try {
    const options = parseArgs();
    if (options.help) {
      printHelp();
      return;
    }
    const { report } = await runWindowsDockerSharedSurfaceLocalCi(options);
    if (options.printNext && report.next_requirement) {
      console.log(JSON.stringify(report.next_requirement, null, 2));
      return;
    }
    if (options.printNextStep && report.next_step) {
      console.log(JSON.stringify(report.next_step, null, 2));
      return;
    }
    console.log(report.overall.reason);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}

const entryPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (entryPath && fileURLToPath(import.meta.url) === entryPath) {
  await main();
}

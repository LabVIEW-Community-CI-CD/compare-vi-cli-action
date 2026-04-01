#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runPesterServiceModelLocalCi } from './pester-service-model-local-ci.mjs';
import { runVIHistoryLocalCi } from './vi-history-local-ci.mjs';
import { runWindowsDockerSharedSurfaceLocalCi } from './windows-docker-shared-surface-local-ci.mjs';

const repoRootDefault = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const DEFAULT_RESULTS_DIR = path.join('tests', 'results', '_agent', 'local-proof-program', 'local-ci');
const DEFAULT_REPORT = path.join(DEFAULT_RESULTS_DIR, 'comparevi-local-program-ci-report.json');
const DEFAULT_SUMMARY = path.join(DEFAULT_RESULTS_DIR, 'comparevi-local-program-ci-summary.md');
const DEFAULT_NEXT_STEP = path.join(DEFAULT_RESULTS_DIR, 'comparevi-local-program-next-step.json');

const HELP = [
  'Usage: node tools/priority/comparevi-local-program-ci.mjs [options]',
  '',
  'Options:',
  `  --repo-root <path>       (default: ${repoRootDefault})`,
  `  --results-dir <path>     (default: ${DEFAULT_RESULTS_DIR})`,
  `  --output <path>          (default: ${DEFAULT_REPORT})`,
  `  --summary-output <path>  (default: ${DEFAULT_SUMMARY})`,
  `  --next-step-output <path> (default: ${DEFAULT_NEXT_STEP})`,
  '  --print-next-step        print the selected next step to stdout',
  '  --help, -h'
];

const PACKETS = Object.freeze([
  Object.freeze({
    id: 'pester-service-model',
    label: 'Pester Service Model',
    reportDir: path.join('tests', 'results', '_agent', 'pester-service-model', 'local-ci'),
    reportFile: 'pester-service-model-local-ci-report.json',
    nextStepFile: 'pester-service-model-next-step.json'
  }),
  Object.freeze({
    id: 'vi-history-local-proof',
    label: 'VI History Local Proof',
    reportDir: path.join('tests', 'results', '_agent', 'vi-history-local-proof', 'local-ci'),
    reportFile: 'vi-history-local-ci-report.json',
    nextStepFile: 'vi-history-local-next-step.json'
  }),
  Object.freeze({
    id: 'windows-docker-shared-surface',
    label: 'Windows Docker Shared Surface',
    reportDir: path.join('tests', 'results', '_agent', 'windows-docker-shared-surface', 'local-ci'),
    reportFile: 'windows-docker-shared-surface-local-ci-report.json',
    nextStepFile: 'windows-docker-shared-surface-next-step.json'
  })
]);

function parseArgs(argv = process.argv) {
  const options = {
    repoRoot: repoRootDefault,
    resultsDir: DEFAULT_RESULTS_DIR,
    outputPath: DEFAULT_REPORT,
    summaryPath: DEFAULT_SUMMARY,
    nextStepOutputPath: DEFAULT_NEXT_STEP,
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
    if (token === '--print-next-step') {
      options.printNextStep = true;
      continue;
    }
    if (['--repo-root', '--results-dir', '--output', '--summary-output', '--next-step-output'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}`);
      }
      i += 1;
      if (token === '--repo-root') options.repoRoot = path.resolve(next);
      if (token === '--results-dir') options.resultsDir = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--summary-output') options.summaryPath = next;
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

async function ensureDir(filePath) {
  await fs.mkdir(filePath, { recursive: true });
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

function relativeFrom(repoRoot, filePath) {
  return path.relative(repoRoot, filePath).split(path.sep).join('/');
}

async function writeJson(filePath, payload) {
  await ensureDir(path.dirname(filePath));
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), 'utf8');
}

function weightPriority(priority) {
  if (priority === 'High') return 300;
  if (priority === 'Medium') return 150;
  return 50;
}

function weightStatus(status) {
  if (status === 'Regression') return 1000;
  if (status === 'Gap') return 600;
  return 200;
}

function weightPhase(phase) {
  if (phase === 'foundation') return 250;
  if (phase === 'execution-governance') return 220;
  if (phase === 'promotion-governance') return 180;
  if (phase === 'evidence-governance') return 160;
  return 100;
}

function buildRequirementCandidate(packet, reportPath, nextStepPath, nextStep) {
  const sourceScore = Number.isFinite(Number(nextStep.score)) ? Number(nextStep.score) : 0;
  return {
    type: 'requirement',
    packet_id: packet.id,
    packet_label: packet.label,
    source_report_path: reportPath,
    source_next_step_path: nextStepPath,
    ...nextStep,
    program_score:
      (nextStep.active_now ? 10000 : 0) +
      weightStatus(nextStep.status) +
      weightPriority(nextStep.priority) +
      weightPhase(nextStep.phase) +
      sourceScore
  };
}

function rankProgramRequirements(requirements) {
  return [...requirements]
    .sort((left, right) => {
      if (right.program_score !== left.program_score) return right.program_score - left.program_score;
      if (left.packet_id !== right.packet_id) return left.packet_id.localeCompare(right.packet_id);
      return left.req_id.localeCompare(right.req_id);
    })
    .map((entry, index) => ({ ...entry, program_rank: index + 1 }));
}

function dedupeStrings(values) {
  const ordered = [];
  const seen = new Set();
  for (const value of values) {
    if (!value || seen.has(value)) continue;
    seen.add(value);
    ordered.push(value);
  }
  return ordered;
}

function mergeSharedSurfaceEscalations(escalations) {
  const groups = new Map();
  for (const escalation of escalations) {
    const key = escalation.required_surface;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(escalation);
  }

  return [...groups.entries()]
    .map(([requiredSurface, group]) => {
      const packetIds = group.map((entry) => entry.packet_id);
      const packetLabels = group.map((entry) => entry.packet_label);
      const hostPlatforms = dedupeStrings(group.map((entry) => entry.current_host_platform));
      const surfaceStatuses = dedupeStrings(group.map((entry) => entry.current_surface_status));
      const mergedWhyNow = group.length > 1
        ? `Multiple local proof packets require the shared ${requiredSurface} surface before the next truthful local proof.`
        : group[0].why_now;
      const mergedReason = hostPlatforms.length === 1 && hostPlatforms[0] === 'Unix'
        ? `Current host is not Windows, so the shared ${requiredSurface} surface cannot be satisfied here.`
        : dedupeStrings(group.map((entry) => entry.reason)).join(' ');
      return {
        type: 'escalation',
        escalation_id: requiredSurface,
        status: 'required',
        mode: 'escalate',
        why_now: mergedWhyNow,
        reason: mergedReason,
        required_surface: requiredSurface,
        current_surface_status: surfaceStatuses.length === 1 ? surfaceStatuses[0] : 'mixed',
        current_host_platform: hostPlatforms.length === 1 ? hostPlatforms[0] : 'mixed',
        packet_ids: packetIds,
        packet_labels: packetLabels,
        packet_count: group.length,
        governing_requirements: dedupeStrings(group.map((entry) => entry.governing_requirement)),
        blocked_requirements: dedupeStrings(group.map((entry) => entry.blocked_requirement)),
        proof_check_ids: dedupeStrings(group.map((entry) => entry.proof_check_id)),
        receipt_paths: dedupeStrings(group.map((entry) => entry.receipt_path)),
        source_next_step_paths: dedupeStrings(group.map((entry) => entry.source_next_step_path)),
        suggested_loop: dedupeStrings(group.flatMap((entry) => entry.suggested_loop ?? [])),
        recommended_commands: dedupeStrings(group.flatMap((entry) => entry.recommended_commands ?? [])),
        stop_conditions: dedupeStrings(group.flatMap((entry) => entry.stop_conditions ?? []))
      };
    })
    .sort((left, right) => {
      if (right.packet_count !== left.packet_count) return right.packet_count - left.packet_count;
      return left.required_surface.localeCompare(right.required_surface);
    });
}

function buildPostLocalPromotionEscalation(packets) {
  const packetIds = packets.map((packet) => packet.id);
  const packetLabels = packets.map((packet) => packet.label);
  return {
    type: 'escalation',
    escalation_id: 'post-local-promotion-proof',
    status: 'required',
    mode: 'promote',
    why_now: 'All tracked local proof packets are implemented locally, so the next truthful move is proof on an integration or hosted surface.',
    reason: 'Local packet requirements and local proof receipts are green. Further progress now needs integration-level proof of workflow routing, permissions, retained artifacts, and promotion behavior.',
    required_surface: 'integration-or-hosted-proof',
    current_surface_status: 'local-proof-complete',
    current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
    packet_count: packets.length,
    packet_ids: packetIds,
    packet_labels: packetLabels,
    governing_requirements: ['REQ-LPAP-003'],
    blocked_requirements: [],
    proof_check_ids: ['program-post-local-promotion'],
    receipt_paths: packets.map((packet) => packet.report_path),
    source_next_step_paths: packets.map((packet) => packet.next_step_path),
    suggested_loop: [
      'Prepare a minimal upstream slice from the locally passing worktree.',
      'Push that slice to an integration or proof branch.',
      'Run the relevant hosted or integration proof surface for the affected packets.',
      'If hosted proof exposes a new seam, reopen the owning packet locally and continue from the emitted receipt.'
    ],
    recommended_commands: [
      'git status --short',
      'git diff --stat',
      'gh pr status'
    ],
    stop_conditions: [
      'Stop when an integration or hosted proof receipt exists for the promoted slice.',
      'Stop when hosted proof reopens a local packet requirement or escalation.'
    ]
  };
}

function selectProgramNextStep(requirements, escalations, fallbackEscalation = null) {
  if (requirements.length > 0) return requirements[0];
  if (escalations.length > 0) return escalations[0];
  return fallbackEscalation;
}

async function validateSchema(schemaPath, payload, label) {
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

function buildSummary(report) {
  const lines = [
    '# CompareVI Local Program CI',
    '',
    `- Overall: ${report.overall.status}`,
    `- Reason: ${report.overall.reason}`,
    ''
  ];

  lines.push('## Packet Status', '');
  for (const packet of report.packets) {
    lines.push(`- ${packet.label}: ${packet.overall_status}`);
    lines.push(`  next step: ${packet.next_step_type ?? 'none'}`);
  }
  lines.push('');

  if (report.next_step?.type === 'requirement') {
    lines.push('## Next Step', '');
    lines.push(`- Type: requirement`);
    lines.push(`- Packet: ${report.next_step.packet_label}`);
    lines.push(`- Requirement: ${report.next_step.req_id}`);
    lines.push(`- Why now: ${report.next_step.why_now}`);
    lines.push(`- Test: ${report.next_step.test_id}`);
    lines.push(`- Source packet report: ${report.next_step.source_report_path}`);
    lines.push('');
  } else if (report.next_step?.type === 'escalation') {
    lines.push('## Next Step', '');
    lines.push(`- Type: escalation`);
    lines.push(`- Required surface: ${report.next_step.required_surface}`);
    lines.push(`- Packets: ${report.next_step.packet_labels.join(', ')}`);
    lines.push(`- Blocked requirements: ${report.next_step.blocked_requirements.join(', ')}`);
    lines.push(`- Reason: ${report.next_step.reason}`);
    lines.push('');
  }

  return `${lines.join('\n')}\n`;
}

export { buildRequirementCandidate, rankProgramRequirements, mergeSharedSurfaceEscalations, selectProgramNextStep };
export { buildPostLocalPromotionEscalation };

export async function runCompareviLocalProgramCi({
  repoRoot = repoRootDefault,
  resultsDir = DEFAULT_RESULTS_DIR,
  outputPath = DEFAULT_REPORT,
  summaryPath = DEFAULT_SUMMARY,
  nextStepOutputPath = DEFAULT_NEXT_STEP
} = {}) {
  const resolved = {
    repoRoot,
    resultsDir: path.join(repoRoot, resultsDir),
    outputPath: path.join(repoRoot, outputPath),
    summaryPath: path.join(repoRoot, summaryPath),
    nextStepOutputPath: path.join(repoRoot, nextStepOutputPath)
  };

  await ensureDir(resolved.resultsDir);

  const pester = await runPesterServiceModelLocalCi({ repoRoot });
  const viHistory = await runVIHistoryLocalCi({ repoRoot });
  const windowsSurface = await runWindowsDockerSharedSurfaceLocalCi({ repoRoot });
  const packetRuns = [
    { packet: PACKETS[0], result: pester },
    { packet: PACKETS[1], result: viHistory },
    { packet: PACKETS[2], result: windowsSurface }
  ];

  const packets = packetRuns.map(({ packet, result }) => ({
    id: packet.id,
    label: packet.label,
    report_path: relativeFrom(repoRoot, result.paths.outputPath),
    next_step_path: relativeFrom(repoRoot, result.paths.nextStepOutputPath),
    overall_status: result.report.overall.status,
    overall_reason: result.report.overall.reason,
    next_step_type: result.report.next_step?.type ?? null,
    next_requirement_id: result.report.next_requirement?.req_id ?? null,
    required_surface: result.report.next_step?.type === 'escalation' ? result.report.next_step.required_surface : null
  }));

  const requirementCandidates = packetRuns
    .filter(({ result }) => result.report.next_step?.type === 'requirement')
    .map(({ packet, result }) => buildRequirementCandidate(
      packet,
      relativeFrom(repoRoot, result.paths.outputPath),
      relativeFrom(repoRoot, result.paths.nextStepOutputPath),
      result.report.next_step
    ));

  const escalationCandidates = packetRuns
    .filter(({ result }) => result.report.next_step?.type === 'escalation')
    .map(({ packet, result }) => ({
      packet_id: packet.id,
      packet_label: packet.label,
      source_next_step_path: relativeFrom(repoRoot, result.paths.nextStepOutputPath),
      ...result.report.next_step
    }));

  const rankedRequirements = rankProgramRequirements(requirementCandidates);
  const escalations = mergeSharedSurfaceEscalations(escalationCandidates);
  const postLocalPromotionEscalation = buildPostLocalPromotionEscalation(packets);
  const nextStep = selectProgramNextStep(rankedRequirements, escalations, postLocalPromotionEscalation);

  let overallStatus = 'pass';
  let overallReason = 'The program selector did not emit a next step.';
  if (nextStep?.type === 'requirement') {
    overallStatus = 'pass-with-actions';
    overallReason = `The next local requirement is ${nextStep.req_id} from ${nextStep.packet_label}.`;
  } else if (nextStep?.type === 'escalation') {
    overallStatus = 'pass-with-escalation';
    overallReason = `All tracked packet-local requirements are implemented, and the next truthful step is the shared '${nextStep.required_surface}' surface for ${nextStep.packet_labels.join(', ')}.`;
  }

  const report = {
    schema_version: '1.0.0',
    generated_at: new Date().toISOString(),
    repo_root: repoRoot,
    packets,
    ranked_requirements: rankedRequirements,
    escalations,
    next_step: nextStep,
    overall: {
      status: overallStatus,
      reason: overallReason
    }
  };

  await validateSchema(
    path.join(repoRoot, 'docs', 'schemas', 'comparevi-local-program-ci-report-v1.schema.json'),
    report,
    'CompareVI local program CI report'
  );
  await validateSchema(
    path.join(repoRoot, 'docs', 'schemas', 'comparevi-local-program-next-step-v1.schema.json'),
    nextStep,
    'CompareVI local program next step'
  );

  await writeJson(resolved.outputPath, report);
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
    const { report } = await runCompareviLocalProgramCi(options);
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

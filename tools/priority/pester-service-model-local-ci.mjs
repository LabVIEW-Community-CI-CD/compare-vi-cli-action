#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import yaml from 'js-yaml';

import { runWindowsSurfaceProof as runSharedWindowsSurfaceProof } from './windows-docker-shared-surface-local-ci.mjs';

const repoRootDefault = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const defaultSkillRoot = path.join(process.env.HOME ?? '', '.codex', 'skills', 'repo-standards-review');
const fallbackSkillRoot = '/mnt/c/Users/sveld/.codex/skills/repo-standards-review';

const DEFAULT_SURFACE = path.join('tools', 'priority', 'pester-service-model-audit-surface.yaml');
const DEFAULT_POLICY = path.join('tools', 'priority', 'pester-service-model-autonomy-policy.json');
const DEFAULT_RESULTS_DIR = path.join('tests', 'results', '_agent', 'pester-service-model', 'local-ci');
const DEFAULT_REPORT = path.join(DEFAULT_RESULTS_DIR, 'pester-service-model-local-ci-report.json');
const DEFAULT_SUMMARY = path.join(DEFAULT_RESULTS_DIR, 'pester-service-model-local-ci-summary.md');
const DEFAULT_NEXT = path.join(DEFAULT_RESULTS_DIR, 'pester-service-model-next-requirement.json');
const DEFAULT_NEXT_STEP = path.join(DEFAULT_RESULTS_DIR, 'pester-service-model-next-step.json');

const HELP = [
  'Usage: node tools/priority/pester-service-model-local-ci.mjs [options]',
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
      if (!next || next.startsWith('-')) throw new Error(`Missing value for ${token}`);
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
  if (process.env.CODEX_HOME) candidates.push(path.join(process.env.CODEX_HOME, 'skills', 'repo-standards-review'));
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

async function validateReportSchema(repoRoot, report) {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'pester-service-model-local-ci-report-v1.schema.json');
  const schema = await readJson(schemaPath);
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const ok = validate(report);
  if (!ok) {
    const details = (validate.errors ?? []).map((entry) => `${entry.instancePath || '/'} ${entry.message}`).join('; ');
    throw new Error(`Local CI report schema validation failed: ${details}`);
  }
}

async function validateNextStepSchema(repoRoot, nextStep) {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'pester-service-model-next-step-v1.schema.json');
  const schema = await readJson(schemaPath);
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const ok = validate(nextStep);
  if (!ok) {
    const details = (validate.errors ?? []).map((entry) => `${entry.instancePath || '/'} ${entry.message}`).join('; ');
    throw new Error(`Next-step schema validation failed: ${details}`);
  }
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
  const match = /REQ-PSM-(\d+)/.exec(reqId ?? '');
  return match ? Number.parseInt(match[1], 10) : Number.POSITIVE_INFINITY;
}

function determinePhase(reqNumber) {
  if (reqNumber <= 11) return 'foundation';
  if (reqNumber <= 17) return 'execution-governance';
  if (reqNumber <= 19) return 'promotion-governance';
  if (reqNumber <= 21) return 'evidence-governance';
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

function deriveWeakAreas(scorePayload) {
  return Object.entries(scorePayload.areas ?? {})
    .filter(([, details]) => Number(details.score ?? 0) < 3)
    .map(([area]) => area);
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

function scoreGap(row) {
  const reqNumber = parseRequirementNumber(row.ReqID);
  const phase = determinePhase(reqNumber);
  const priorityWeight = row.Priority === 'High' ? 200 : row.Priority === 'Medium' ? 100 : 50;
  const phaseWeight = {
    foundation: 300,
    'execution-governance': 250,
    'promotion-governance': 160,
    'evidence-governance': 150,
    autonomy: 180
  }[phase] ?? 0;
  const runtimeRefWeight = /(Invoke-PesterTests\.ps1|pester-run\.yml|pester-evidence\.yml|Run-PesterExecutionOnly\.Local\.ps1|Invoke-PesterExecutionFinalize\.ps1|Invoke-PesterExecutionPostprocess\.ps1)/.test(row.CodeRef) ? 40 : 0;
  const localFirstWeight = /(local|execution|evidence|failure-detail|path-hygiene|telemetry)/i.test(row.Requirement) ? 25 : 0;
  const promotionPenalty = /(promotion|baseline)/i.test(row.Requirement) ? -40 : 0;
  return 1000 + priorityWeight + phaseWeight + runtimeRefWeight + localFirstWeight + promotionPenalty - reqNumber;
}

function deriveSuggestedLoop(row) {
  const codeRefs = splitField(row.CodeRef);
  const actions = [];
  actions.push(`Start with ${row.TestID}: add or tighten local coverage before widening CI.`);
  if (codeRefs.length > 0) {
    actions.push(`Edit the primary source targets first: ${codeRefs.slice(0, 3).join(', ')}.`);
  }
  if (/(Invoke-PesterTests\.ps1|Run-PesterExecutionOnly\.Local\.ps1|pester-run\.yml|pester-evidence\.yml)/.test(row.CodeRef)) {
    actions.push('Prove the change locally with the execution harness and packet contract tests before another GitHub run.');
  } else {
    actions.push('Re-run the local packet CI and contract tests after the change to refresh the ranked backlog.');
  }
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
    why_now: overrides.why_now ?? `${row.ReqID} is an unresolved ${row.Priority} ${phase} gap with concrete code refs and planned verification.`,
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
    .map((entry, index) => ({
      rank: index + 1,
      ...entry
    }));
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
        why_now: `${row.ReqID} regressed under the local proof check '${check.id}': ${check.summary}`,
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

function deriveEscalations(proofChecks) {
  return proofChecks
    .filter((check) => check.status === 'advisory' && check.id === 'windows-container-surface')
    .map((check) => ({
      type: 'escalation',
      escalation_id: 'windows-container-live-proof',
      governing_requirement: 'REQ-PSM-027',
      blocked_requirement: check.owner_requirement,
      proof_check_id: check.id,
      status: 'required',
      mode: 'escalate',
      why_now: `The next truthful local proof surface for ${check.owner_requirement} is unavailable from the current host.`,
      reason: check.surface_status === 'not-windows-host'
        ? 'Current host is not Windows, so the Docker Desktop + NI Windows image proof surface cannot be exercised here.'
        : `Windows-container surrogate reported ${check.surface_status}; the environment must be prepared before another hosted rerun.`,
      required_surface: 'windows-docker-desktop-ni-image',
      current_surface_status: check.surface_status ?? 'unknown',
      current_host_platform: check.host_platform ?? 'unknown',
      receipt_path: check.receipt_path ?? null,
      suggested_loop: [
        'Move to a Windows host with Docker Desktop configured for Windows containers.',
        'Bootstrap or verify the pinned NI Windows image before attempting another live proof.',
        'Re-run the bounded Windows-surface probe before choosing a hosted GitHub rerun.'
      ],
      recommended_commands: check.recommended_commands ?? [],
      stop_conditions: [
        'Stop once the Windows-container surface probe reports status=ready.',
        'Stop if the probe exposes a new blocking defect such as docker-engine-not-windows or ni-image-missing.'
      ]
    }));
}

function selectNextStep(nextRequirement, escalations) {
  if (nextRequirement) {
    return {
      type: 'requirement',
      ...nextRequirement
    };
  }
  return escalations[0] ?? null;
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
        why_now: activeNow
          ? `${item.req_id} is already active in the worktree and remains an unresolved ${item.priority} ${item.phase} gap.`
          : item.why_now,
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
    .map((entry, index) => ({
      ...entry,
      rank: index + 1
    }));
}

function buildSummary(report) {
  const lines = [
    '# Pester Service Model Local CI',
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
    lines.push(`- Type: requirement`);
    lines.push(`- ${report.next_requirement.req_id}`);
    lines.push(`- Phase: ${report.next_requirement.phase}`);
    lines.push(`- Why now: ${report.next_requirement.why_now}`);
    lines.push(`- Test: ${report.next_requirement.test_id}`);
    lines.push(`- Code refs: ${report.next_requirement.code_refs.join(', ') || '(none)'}`);
    lines.push(`- Mode: ${report.next_requirement.mode}`);
    lines.push(`- Active in worktree: ${report.next_requirement.active_now ? 'yes' : 'no'}`);
    lines.push('');
    lines.push('## Suggested Local Loop', '');
    for (const action of report.next_requirement.suggested_loop) {
      lines.push(`- ${action}`);
    }
    if (report.next_requirement.preferred_commands.length > 0) {
      lines.push('', '## Preferred Commands', '');
      for (const command of report.next_requirement.preferred_commands) {
        lines.push(`- \`${command}\``);
      }
    }
    if (report.next_requirement.stop_conditions.length > 0) {
      lines.push('', '## Stop Conditions', '');
      for (const item of report.next_requirement.stop_conditions) {
        lines.push(`- ${item}`);
      }
    }
    if (report.next_requirement.escalate_when.length > 0) {
      lines.push('', '## Escalate When', '');
      for (const item of report.next_requirement.escalate_when) {
        lines.push(`- ${item}`);
      }
    }
    lines.push('');
  }

  if (report.next_step?.type === 'escalation') {
    lines.push('## Next Step', '');
    lines.push(`- Type: escalation`);
    lines.push(`- Escalation: ${report.next_step.escalation_id}`);
    lines.push(`- Governing requirement: ${report.next_step.governing_requirement}`);
    lines.push(`- Blocked requirement: ${report.next_step.blocked_requirement}`);
    lines.push(`- Why now: ${report.next_step.why_now}`);
    lines.push(`- Reason: ${report.next_step.reason}`);
    lines.push(`- Required surface: ${report.next_step.required_surface}`);
    lines.push(`- Current surface status: ${report.next_step.current_surface_status}`);
    lines.push(`- Current host platform: ${report.next_step.current_host_platform}`);
    if (report.next_step.receipt_path) {
      lines.push(`- Receipt: ${report.next_step.receipt_path}`);
    }
    lines.push('');
    lines.push('## Suggested Escalation Loop', '');
    for (const action of report.next_step.suggested_loop) {
      lines.push(`- ${action}`);
    }
    if (report.next_step.recommended_commands.length > 0) {
      lines.push('', '## Recommended Commands', '');
      for (const command of report.next_step.recommended_commands) {
        lines.push(`- \`${command}\``);
      }
    }
    if (report.next_step.stop_conditions.length > 0) {
      lines.push('', '## Stop Conditions', '');
      for (const item of report.next_step.stop_conditions) {
        lines.push(`- ${item}`);
      }
    }
    lines.push('');
  }

  lines.push('## Ranked Requirement Backlog', '');
  for (const item of report.ranked_requirements.slice(0, 8)) {
    lines.push(`- ${item.rank}. ${item.req_id} [${item.priority}] phase=${item.phase} score=${item.score}`);
    lines.push(`  ${item.requirement}`);
  }

  if (report.proof_checks.checks.length > 0) {
    lines.push('', '## Proof Checks', '');
    for (const check of report.proof_checks.checks) {
      lines.push(`- ${check.id}: ${check.status}`);
      lines.push(`  ${check.summary}`);
    }
  }

  return `${lines.join('\n')}\n`;
}

async function writeJson(filePath, payload) {
  await ensureDir(path.dirname(filePath));
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), 'utf8');
}

async function runRepresentativeReplayProof(repoRoot, resultsDir) {
  const workspace = path.join(resultsDir, 'representative-replay');
  await fs.rm(workspace, { recursive: true, force: true });
  await ensureDir(workspace);

  const command = `& 'tools/Replay-PesterServiceModelArtifacts.Local.ps1' -RawArtifactDir 'tests/fixtures/pester-service-model/legacy-results-xml-truncated/raw' -ExecutionReceiptPath 'tests/fixtures/pester-service-model/legacy-results-xml-truncated/pester-run-receipt.json' -WorkspaceResultsDir '${workspace.replace(/'/g, "''")}'`;
  const result = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-Command', command], {
    cwd: repoRoot,
    encoding: 'utf8',
    maxBuffer: 20 * 1024 * 1024
  });

  const base = {
    id: 'representative-replay',
    owner_requirement: 'REQ-PSM-024',
    workspace: relativeFrom(repoRoot, workspace)
  };

  if (result.status !== 0) {
    return {
      ...base,
      status: 'fail',
      blocking: true,
      summary: 'Representative retained-artifact replay failed before producing normalized evidence outputs.',
      details: [result.stdout?.trim(), result.stderr?.trim()].filter(Boolean)
    };
  }

  const classificationPath = path.join(workspace, 'pester-evidence-classification.json');
  const operatorOutcomePath = path.join(workspace, 'pester-operator-outcome.json');
  const summaryPath = path.join(workspace, 'pester-summary.json');
  let classification;
  let operatorOutcome;
  let summary;
  try {
    classification = await readJson(classificationPath);
    operatorOutcome = await readJson(operatorOutcomePath);
    summary = await readJson(summaryPath);
  } catch (error) {
    return {
      ...base,
      status: 'fail',
      blocking: true,
      summary: 'Representative retained-artifact replay completed without emitting the expected normalized evidence files.',
      details: [error instanceof Error ? error.message : String(error)]
    };
  }
  const ok = classification.classification === 'results-xml-truncated'
    && operatorOutcome.nextActionId === 'inspect-results-xml-truncation'
    && summary.schemaVersion === '1.7.1';

  return {
    ...base,
    status: ok ? 'pass' : 'fail',
    blocking: !ok,
    summary: ok
      ? 'Representative retained-artifact replay normalized a schema-lite truncated-XML run into current evidence contracts.'
      : 'Representative retained-artifact replay completed but did not preserve the expected truncated-XML operator outcome contract.',
    classification: classification.classification,
    operator_next_action: operatorOutcome.nextActionId,
    summary_schema_version: summary.schemaVersion,
    output_paths: [
      relativeFrom(repoRoot, classificationPath),
      relativeFrom(repoRoot, operatorOutcomePath),
      relativeFrom(repoRoot, summaryPath)
    ]
  };
}

async function runWindowsContainerSurfaceProof(repoRoot, resultsDir) {
  const sharedProof = await runSharedWindowsSurfaceProof(repoRoot, resultsDir);
  return {
    id: 'windows-container-surface',
    owner_requirement: 'REQ-PSM-025',
    status: sharedProof.status,
    blocking: sharedProof.blocking,
    summary: sharedProof.status === 'pass'
      ? 'Windows-container surface is ready for local Docker Desktop + NI image proof.'
      : sharedProof.status === 'advisory'
        ? `Windows-container surface is ${sharedProof.current_surface_status}; use the recommended Docker Desktop + NI image commands when a live local proof is required.`
        : sharedProof.summary,
    surface_status: sharedProof.current_surface_status,
    host_platform: sharedProof.current_host_platform,
    coordinator_host_platform: sharedProof.coordinator_host_platform,
    bridge_mode: sharedProof.bridge_mode,
    reason: sharedProof.reason,
    receipt_path: sharedProof.receipt_path,
    recommended_commands: sharedProof.recommended_commands ?? [],
    details: sharedProof.details ?? []
  };
}

export { parseCsv, parseRequirementNumber, determinePhase, rankRequirementGaps, rankProofRegressions, deriveEscalations, selectNextStep, applyAutonomyPolicy };

export async function runPesterServiceModelLocalCi({
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
  const rtmPath = path.join(repoRoot, 'docs', 'rtm-pester-service-model.csv');
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
    await runRepresentativeReplayProof(repoRoot, resolved.resultsDir),
    await runWindowsContainerSurfaceProof(repoRoot, resolved.resultsDir)
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
  const blockingProof = proofChecks.find((check) => check.blocking) ?? null;
  const overallReason = blockingProof
    ? `The next recommended requirement is ${nextRequirement.req_id} because the local proof check '${blockingProof.id}' regressed against the current packet.`
    : gapCount === 0
      ? (nextStep?.type === 'escalation'
        ? `All tracked Pester service-model requirements are implemented locally, and the next step is escalation '${nextStep.escalation_id}' because the current host cannot satisfy the required proof surface.`
        : advisoryProofChecks > 0
        ? 'All tracked Pester service-model requirements are implemented, and the remaining local note is the current Windows-container surface advisory.'
        : 'All tracked Pester service-model requirements are currently marked implemented.')
      : `The next recommended requirement is ${nextRequirement.req_id} because it is the highest-ranked unresolved gap on the local packet under the autonomy policy.`;

  const report = {
    schema_version: '1.2.0',
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
    const { report } = await runPesterServiceModelLocalCi(options);
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

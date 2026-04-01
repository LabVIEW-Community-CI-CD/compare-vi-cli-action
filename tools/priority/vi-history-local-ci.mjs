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
  buildWindowsNodeBridgeSpec,
  detectWindowsHostBridge,
  runBridgeSpec,
} from './windows-host-bridge.mjs';
import { runWindowsSurfaceProof as runSharedWindowsDockerSurfaceProof } from './windows-docker-shared-surface-local-ci.mjs';

const repoRootDefault = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const defaultSkillRoot = path.join(process.env.HOME ?? '', '.codex', 'skills', 'repo-standards-review');
const fallbackSkillRoot = '/mnt/c/Users/sveld/.codex/skills/repo-standards-review';

const DEFAULT_SURFACE = path.join('tools', 'priority', 'vi-history-local-proof-audit-surface.yaml');
const DEFAULT_POLICY = path.join('tools', 'priority', 'vi-history-local-proof-autonomy-policy.json');
const DEFAULT_LIVE_CANDIDATE = path.join('tools', 'priority', 'vi-history-live-candidate.json');
const DEFAULT_RESULTS_DIR = path.join('tests', 'results', '_agent', 'vi-history-local-proof', 'local-ci');
const DEFAULT_REPORT = path.join(DEFAULT_RESULTS_DIR, 'vi-history-local-ci-report.json');
const DEFAULT_SUMMARY = path.join(DEFAULT_RESULTS_DIR, 'vi-history-local-ci-summary.md');
const DEFAULT_NEXT = path.join(DEFAULT_RESULTS_DIR, 'vi-history-local-next-requirement.json');
const DEFAULT_NEXT_STEP = path.join(DEFAULT_RESULTS_DIR, 'vi-history-local-next-step.json');

const HELP = [
  'Usage: node tools/priority/vi-history-local-ci.mjs [options]',
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

function dedupeOrdered(values) {
  const ordered = [];
  const seen = new Set();
  for (const value of values) {
    if (!value || seen.has(value)) continue;
    seen.add(value);
    ordered.push(value);
  }
  return ordered;
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
  const match = /REQ-VHLP-(\d+)/.exec(reqId ?? '');
  return match ? Number.parseInt(match[1], 10) : Number.POSITIVE_INFINITY;
}

function determinePhase(reqNumber) {
  if (reqNumber <= 4) return 'foundation';
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
  const runtimeWeight = /(windows-workflow-replay-lane|Invoke-VIHistoryLocalRefinement|Invoke-VIHistoryLocalOperatorSession|Write-VIHistoryWorkflowReadiness)/.test(row.CodeRef) ? 40 : 0;
  return 1000 + priorityWeight + phaseWeight + runtimeWeight - reqNumber;
}

function deriveSuggestedLoop(row) {
  const codeRefs = splitField(row.CodeRef);
  const actions = [];
  actions.push(`Start with ${row.TestID}: tighten local VI History proof coverage before spending GitHub CI.`);
  if (codeRefs.length > 0) {
    actions.push(`Edit the primary source targets first: ${codeRefs.slice(0, 3).join(', ')}.`);
  }
  actions.push('Re-run the local VI History CI and next-step entrypoints after the change.');
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
    why_now: overrides.why_now ?? `${row.ReqID} is an unresolved ${row.Priority} ${phase} VI History local-proof gap.`,
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
        why_now: `${row.ReqID} regressed under the VI History proof check '${check.id}': ${check.summary}`,
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
    .filter((check) => check.status === 'advisory' && (check.id === 'windows-workflow-replay' || check.id === 'live-history-candidate'))
    .map((check) => {
      if (check.id === 'live-history-candidate') {
        return {
          type: 'escalation',
          escalation_id: 'clone-backed-live-history-candidate',
          governing_requirement: 'REQ-VHLP-009',
          blocked_requirement: 'REQ-VHLP-008',
          proof_check_id: check.id,
          status: 'required',
          mode: 'escalate',
          why_now: 'The governed clone-backed VI History candidate is not ready for truthful local iteration yet.',
          reason: check.reason,
          required_surface: 'clone-backed-live-history-candidate',
          current_surface_status: check.current_surface_status ?? 'unknown',
          current_host_platform: check.current_host_platform ?? 'unknown',
          receipt_path: check.receipt_path ?? null,
          suggested_loop: [
            'Prepare the governed repository clone at the declared root or set the clone-root override environment variable.',
            'Verify the target VI path and its git history before choosing Windows replay or GitHub CI.',
            'Re-run the VI History local CI entrypoint once the candidate receipt reaches status=ready.'
          ],
          recommended_commands: check.recommended_commands ?? [],
          stop_conditions: [
            'Stop once vi-history-live-candidate-readiness.json reaches status=ready.',
            'Stop if the candidate repo exposes a different target path or history shape than the governed packet expects.'
          ]
        };
      }

      return {
        type: 'escalation',
        escalation_id: 'windows-docker-desktop-ni-image',
        governing_requirement: 'REQ-VHLP-006',
        blocked_requirement: check.owner_requirement,
        proof_check_id: check.id,
        status: 'required',
        mode: 'escalate',
        why_now: `The next truthful VI History proof surface for ${check.owner_requirement} is unavailable from the current host.`,
        reason: check.current_host_platform === 'Unix'
          ? 'Current host is not Windows, so the VI History Windows workflow replay lane cannot be exercised here.'
          : `VI History Windows workflow replay reported ${check.current_surface_status}; prepare the Windows Docker Desktop + NI image surface before another hosted rerun.`,
        required_surface: 'windows-docker-desktop-ni-image',
        current_surface_status: check.current_surface_status ?? 'unknown',
        current_host_platform: check.current_host_platform ?? 'unknown',
        receipt_path: check.receipt_path ?? null,
        suggested_loop: [
          'Move to a Windows host with Docker Desktop configured for Windows containers.',
          'Bootstrap or verify the pinned NI Windows image before running the VI History replay lane.',
          'Re-run the governed Windows workflow replay lane before choosing a hosted GitHub rerun.'
        ],
        recommended_commands: check.recommended_commands ?? [],
        stop_conditions: [
          'Stop once the VI History Windows workflow replay lane reaches status=passed.',
          'Stop if the replay lane exposes a new blocking Windows-host or image defect.'
        ]
      };
    });
}

function selectNextStep(nextRequirement, escalations) {
  if (nextRequirement) {
    return { type: 'requirement', ...nextRequirement };
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

function buildSummary(report) {
  const lines = [
    '# VI History Local CI',
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
    lines.push('');
  }

  if (report.next_step?.type === 'escalation') {
    lines.push('## Next Step', '');
    lines.push(`- Type: escalation`);
    lines.push(`- Escalation: ${report.next_step.escalation_id}`);
    lines.push(`- Governing requirement: ${report.next_step.governing_requirement}`);
    lines.push(`- Blocked requirement: ${report.next_step.blocked_requirement}`);
    lines.push(`- Reason: ${report.next_step.reason}`);
    lines.push(`- Required surface: ${report.next_step.required_surface}`);
    lines.push(`- Current host platform: ${report.next_step.current_host_platform}`);
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
  await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-local-ci-report-v1.schema.json'), report, 'VI History local CI report');
}

async function validateNextStepSchema(repoRoot, nextStep) {
  await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-local-next-step-v1.schema.json'), nextStep, 'VI History next-step');
}

async function loadLiveCandidate(repoRoot, candidatePath = DEFAULT_LIVE_CANDIDATE) {
  const resolvedPath = path.join(repoRoot, candidatePath);
  const candidate = await readJson(resolvedPath);
  await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-live-candidate-v1.schema.json'), candidate, 'VI History live candidate');
  return { candidate, resolvedPath };
}

async function runLiveHistoryCandidateProof(repoRoot, resultsDir, candidatePath = DEFAULT_LIVE_CANDIDATE) {
  const { candidate } = await loadLiveCandidate(repoRoot, candidatePath);
  const candidateDir = path.join(resultsDir, 'live-candidate');
  const receiptPath = path.join(candidateDir, 'vi-history-live-candidate-readiness.json');
  await fs.rm(candidateDir, { recursive: true, force: true });
  await ensureDir(candidateDir);

  const envCloneRoot = process.env[candidate.cloneRootEnvVar] ?? '';
  const cloneRootCandidates = dedupeOrdered([envCloneRoot, ...(candidate.preferredLocalCloneRoots ?? [])]);
  const resolvedCloneRoot = cloneRootCandidates.find((entry) => entry && spawnSync('git', ['-C', entry, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).status === 0) ?? null;

  const baseReceipt = {
    schema: 'vi-history/live-candidate-readiness@v1',
    generatedAt: new Date().toISOString(),
    candidateId: candidate.id,
    repoSlug: candidate.repoSlug,
    repoUrl: candidate.repoUrl,
    defaultBranch: candidate.defaultBranch,
    cloneRootEnvVar: candidate.cloneRootEnvVar,
    cloneRootCandidates,
    resolvedCloneRoot,
    targetViPath: candidate.targetViPath,
    historyExpectation: candidate.historyExpectation,
    recommendedCommands: []
  };

  if (!resolvedCloneRoot) {
    const preferredCloneRoot = candidate.preferredLocalCloneRoots?.[0] ?? '/tmp/labview-icon-editor';
    const receipt = {
      ...baseReceipt,
      status: 'missing-clone',
      reason: `No local clone for ${candidate.repoSlug} was found at the governed candidate roots.`,
      recommendedCommands: [
        `git clone ${candidate.repoUrl}.git ${preferredCloneRoot}`,
        `git -C ${preferredCloneRoot} switch ${candidate.defaultBranch}`,
        'npm run priority:vi-history:local-ci'
      ]
    };
    await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-live-candidate-readiness-v1.schema.json'), receipt, 'VI History live candidate readiness');
    await writeJson(receiptPath, receipt);
    return {
      id: 'live-history-candidate',
      owner_requirement: 'REQ-VHLP-009',
      status: 'advisory',
      blocking: false,
      summary: 'The governed clone-backed VI History candidate is not cloned locally yet.',
      current_surface_status: receipt.status,
      current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
      reason: receipt.reason,
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: receipt.recommendedCommands
    };
  }

  const targetAbsolutePath = path.join(resolvedCloneRoot, candidate.targetViPath);
  if (!(await fileExists(targetAbsolutePath))) {
    const receipt = {
      ...baseReceipt,
      status: 'missing-target',
      reason: `The governed target VI does not exist at ${candidate.targetViPath} inside ${resolvedCloneRoot}.`,
      recommendedCommands: [
        `git -C ${resolvedCloneRoot} switch ${candidate.defaultBranch}`,
        `find ${resolvedCloneRoot} -type f | rg "VIP_(Pre|Post)-.*Custom Action\\\\.vi$"`,
        'npm run priority:vi-history:local-ci'
      ]
    };
    await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-live-candidate-readiness-v1.schema.json'), receipt, 'VI History live candidate readiness');
    await writeJson(receiptPath, receipt);
    return {
      id: 'live-history-candidate',
      owner_requirement: 'REQ-VHLP-009',
      status: 'advisory',
      blocking: false,
      summary: 'The governed clone-backed VI History candidate is cloned, but the target VI path is missing.',
      current_surface_status: receipt.status,
      current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
      reason: receipt.reason,
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: receipt.recommendedCommands
    };
  }

  const historyResult = spawnSync('git', [
    '-C',
    resolvedCloneRoot,
    'log',
    '--follow',
    '--format=%H',
    '--',
    candidate.targetViPath
  ], {
    encoding: 'utf8',
    maxBuffer: 20 * 1024 * 1024
  });

  if (historyResult.status !== 0) {
    const receipt = {
      ...baseReceipt,
      status: 'git-failed',
      reason: `git history lookup failed for ${candidate.targetViPath}.`,
      recommendedCommands: [
        `git -C ${resolvedCloneRoot} status --short --branch`,
        `git -C ${resolvedCloneRoot} log --follow --oneline -- "${candidate.targetViPath}"`,
        'npm run priority:vi-history:local-ci'
      ],
      details: [historyResult.stdout?.trim(), historyResult.stderr?.trim()].filter(Boolean)
    };
    await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-live-candidate-readiness-v1.schema.json'), receipt, 'VI History live candidate readiness');
    await writeJson(receiptPath, receipt);
    return {
      id: 'live-history-candidate',
      owner_requirement: 'REQ-VHLP-009',
      status: 'fail',
      blocking: true,
      summary: 'git history lookup for the governed VI History candidate failed.',
      current_surface_status: receipt.status,
      current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
      reason: receipt.reason,
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: receipt.recommendedCommands,
      details: receipt.details
    };
  }

  const commitLines = historyResult.stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  if (commitLines.length < Number(candidate.historyExpectation?.minCommits ?? 1)) {
    const receipt = {
      ...baseReceipt,
      status: 'missing-history',
      reason: `The governed target VI does not expose the minimum required git history depth (${candidate.historyExpectation.minCommits} commits).`,
      history: {
        commitCount: commitLines.length,
        latestCommit: commitLines[0] ?? null
      },
      recommendedCommands: [
        `git -C ${resolvedCloneRoot} log --follow --oneline -- "${candidate.targetViPath}"`,
        'npm run priority:vi-history:local-ci'
      ]
    };
    await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-live-candidate-readiness-v1.schema.json'), receipt, 'VI History live candidate readiness');
    await writeJson(receiptPath, receipt);
    return {
      id: 'live-history-candidate',
      owner_requirement: 'REQ-VHLP-009',
      status: 'advisory',
      blocking: false,
      summary: 'The governed clone-backed VI History candidate does not expose enough git history yet.',
      current_surface_status: receipt.status,
      current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
      reason: receipt.reason,
      receipt_path: relativeFrom(repoRoot, receiptPath),
      recommended_commands: receipt.recommendedCommands
    };
  }

  const receipt = {
    ...baseReceipt,
    status: 'ready',
    reason: 'The governed live-history candidate is cloned, the target VI exists, and git history is available.',
    history: {
      commitCount: commitLines.length,
      latestCommit: commitLines[0] ?? null
    },
    recommendedCommands: [
      `git -C ${resolvedCloneRoot} log --follow --oneline -- "${candidate.targetViPath}"`,
      'npm run priority:workflow:replay:windows:vi-history'
    ]
  };
  await validateJsonAgainstSchema(repoRoot, path.join('docs', 'schemas', 'vi-history-live-candidate-readiness-v1.schema.json'), receipt, 'VI History live candidate readiness');
  await writeJson(receiptPath, receipt);
  return {
    id: 'live-history-candidate',
    owner_requirement: 'REQ-VHLP-009',
    status: 'pass',
    blocking: false,
    summary: 'The governed clone-backed VI History candidate is ready for local iteration.',
    current_surface_status: receipt.status,
    current_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
    reason: receipt.reason,
    receipt_path: relativeFrom(repoRoot, receiptPath),
    recommended_commands: receipt.recommendedCommands
  };
}

async function runSharedWindowsSurfaceProof(repoRoot, resultsDir) {
  const surfaceDir = path.join(resultsDir, 'windows-surface');
  const normalizedReceiptPath = path.join(surfaceDir, 'vi-history-windows-surface.json');
  await fs.rm(surfaceDir, { recursive: true, force: true });
  await ensureDir(surfaceDir);
  const surfaceProof = await runSharedWindowsDockerSurfaceProof(repoRoot, resultsDir);
  const normalizedReceipt = {
    schema: 'vi-history/windows-surface@v1',
    generatedAt: new Date().toISOString(),
    status: surfaceProof.current_surface_status,
    hostPlatform: surfaceProof.current_host_platform,
    coordinatorHostPlatform: surfaceProof.coordinator_host_platform ?? (process.platform === 'win32' ? 'Windows' : 'Unix'),
    bridgeMode: surfaceProof.bridge_mode ?? (process.platform === 'win32' ? 'native-windows' : 'none'),
    reason: surfaceProof.reason,
    recommendedCommands: surfaceProof.recommended_commands ?? [],
    sourceProbeReceiptPath: surfaceProof.receipt_path ?? null
  };
  await writeJson(normalizedReceiptPath, normalizedReceipt);

  return {
    id: 'windows-surface',
    owner_requirement: 'REQ-VHLP-006',
    status: surfaceProof.status,
    blocking: surfaceProof.blocking,
    summary: surfaceProof.status === 'advisory'
      ? `Shared Windows Docker Desktop + NI image surface is ${surfaceProof.current_surface_status}; use the recommended Windows commands before running VI History replay.`
      : surfaceProof.status === 'pass'
        ? 'Shared Windows Docker Desktop + NI image surface is ready for VI History workflow replay.'
        : surfaceProof.summary,
    current_surface_status: surfaceProof.current_surface_status,
    current_host_platform: surfaceProof.current_host_platform,
    coordinator_host_platform: surfaceProof.coordinator_host_platform,
    bridge_mode: surfaceProof.bridge_mode,
    reason: surfaceProof.reason,
    receipt_path: relativeFrom(repoRoot, normalizedReceiptPath),
    recommended_commands: normalizedReceipt.recommendedCommands,
    details: surfaceProof.details ?? []
  };
}

async function runWindowsWorkflowReplayProof(repoRoot, resultsDir) {
  const surfaceProof = await runSharedWindowsSurfaceProof(repoRoot, resultsDir);
  if (surfaceProof.status !== 'pass') {
    return {
      id: 'windows-workflow-replay',
      owner_requirement: 'REQ-VHLP-001',
      status: surfaceProof.status,
      blocking: surfaceProof.blocking,
      summary: surfaceProof.status === 'advisory'
        ? 'VI History Windows workflow replay is gated behind the shared Windows Docker Desktop + NI image surface.'
        : 'VI History Windows workflow replay cannot start because the shared Windows surface probe failed.',
      current_surface_status: surfaceProof.current_surface_status,
      current_host_platform: surfaceProof.current_host_platform,
      receipt_path: surfaceProof.receipt_path,
      reason: surfaceProof.reason,
      recommended_commands: surfaceProof.recommended_commands ?? []
    };
  }

  const receiptPath = path.join('tests', 'results', 'docker-tools-parity', 'workflow-replay', 'vi-history-scenarios-windows-receipt.json');
  const result = process.platform === 'win32'
    ? spawnSync('node', [
        'tools/priority/windows-workflow-replay-lane.mjs',
        '--mode',
        'vi-history-scenarios-windows',
        '--allow-unavailable'
      ], {
        cwd: repoRoot,
        encoding: 'utf8',
        maxBuffer: 20 * 1024 * 1024
      })
    : (() => {
        const bridge = detectWindowsHostBridge(repoRoot);
        if (bridge.status !== 'reachable') {
          throw new Error(bridge.reason);
        }
        const bridgeSpec = buildWindowsNodeBridgeSpec({
          bridge,
          scriptRelativePath: path.join('tools', 'priority', 'windows-workflow-replay-lane.mjs'),
          scriptArgs: ['--mode', 'vi-history-scenarios-windows', '--allow-unavailable']
        });
        return runBridgeSpec(bridgeSpec, { cwd: repoRoot, maxBuffer: 64 * 1024 * 1024 });
      })();

  const base = {
    id: 'windows-workflow-replay',
    owner_requirement: 'REQ-VHLP-001',
    receipt_path: receiptPath
  };

  let receipt;
  try {
    receipt = await readJson(path.join(repoRoot, receiptPath));
  } catch (error) {
    return {
      ...base,
      status: 'fail',
      blocking: true,
      summary: 'VI History Windows workflow replay did not emit its governed receipt.',
      details: [result.stdout?.trim(), result.stderr?.trim(), error instanceof Error ? error.message : String(error)].filter(Boolean)
    };
  }

  const receiptStatus = receipt?.result?.status ?? 'unknown';
  if (receiptStatus === 'passed') {
    return {
      ...base,
      status: 'pass',
      blocking: false,
      summary: 'VI History Windows workflow replay passed and emitted a workflow-grade receipt.',
      current_surface_status: receiptStatus,
      current_host_platform: 'Windows',
      coordinator_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
      bridge_mode: process.platform === 'win32' ? 'native-windows' : 'wsl-windows',
      recommended_commands: [
        'npm run priority:workflow:replay:windows:vi-history'
      ]
    };
  }
  if (receiptStatus === 'unavailable') {
    return {
      ...base,
      status: 'advisory',
      blocking: false,
      summary: 'VI History Windows workflow replay is unavailable from the current host; use the shared Windows Docker Desktop + NI image surface.',
      current_surface_status: receiptStatus,
      current_host_platform: 'Windows',
      coordinator_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
      bridge_mode: process.platform === 'win32' ? 'native-windows' : 'wsl-windows',
      recommended_commands: [
        'npm run docker:ni:windows:bootstrap',
        'npm run compare:docker:ni:windows:probe',
        'npm run priority:workflow:replay:windows:vi-history'
      ]
    };
  }
  return {
    ...base,
    status: 'fail',
    blocking: true,
    summary: 'VI History Windows workflow replay failed on the current packet.',
    current_surface_status: receiptStatus,
    current_host_platform: 'Windows',
    coordinator_host_platform: process.platform === 'win32' ? 'Windows' : 'Unix',
    bridge_mode: process.platform === 'win32' ? 'native-windows' : 'wsl-windows',
    details: [result.stdout?.trim(), result.stderr?.trim()].filter(Boolean)
  };
}

export { parseCsv, parseRequirementNumber, determinePhase, rankRequirementGaps, rankProofRegressions, deriveEscalations, selectNextStep, applyAutonomyPolicy, runLiveHistoryCandidateProof };

export async function runVIHistoryLocalCi({
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
  const rtmPath = path.join(repoRoot, 'docs', 'rtm-vi-history-local-proof.csv');
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
    await runLiveHistoryCandidateProof(repoRoot, resolved.resultsDir),
    await runWindowsWorkflowReplayProof(repoRoot, resolved.resultsDir)
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
    ? `All tracked VI History local-proof requirements are implemented locally, and the next step is escalation '${nextStep.escalation_id}' because additional preparation is required before the next truthful proof.`
    : gapCount === 0
      ? 'All tracked VI History local-proof requirements are currently marked implemented.'
      : `The next recommended VI History requirement is ${nextRequirement.req_id} because it is the highest-ranked unresolved local-proof gap.`;

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
    const { report } = await runVIHistoryLocalCi(options);
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

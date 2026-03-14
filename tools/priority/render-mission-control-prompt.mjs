#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(SCRIPT_PATH);
export const DEFAULT_REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');

export const MISSION_CONTROL_PROMPT_RENDER_SCHEMA = 'priority/mission-control-prompt-render@v1';
export const MISSION_CONTROL_ENVELOPE_SCHEMA = 'priority/mission-control-envelope@v1';
export const FIXTURE_MISSION_CONTROL_ENVELOPE_PATH = path.join(
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
export const DEFAULT_MISSION_CONTROL_PROMPT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'mission-control',
  'mission-control-prompt.txt',
);
export const DEFAULT_MISSION_CONTROL_PROMPT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'mission-control',
  'mission-control-prompt-render.json',
);

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function resolvePathFromBase(filePath, baseDir) {
  return path.resolve(baseDir, filePath);
}

function resolveSchemaPath(repoRoot = DEFAULT_REPO_ROOT) {
  return resolvePathFromBase(DEFAULT_MISSION_CONTROL_ENVELOPE_SCHEMA_PATH, repoRoot);
}

function resolveInputPath(filePath, { repoRoot = DEFAULT_REPO_ROOT, cwd = repoRoot, source = 'explicit' } = {}) {
  const baseDir = source === 'default' ? repoRoot : cwd;
  return resolvePathFromBase(filePath, baseDir);
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeFile(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, 'utf8');
  return filePath;
}

function validateMissionControlEnvelope(envelope, repoRoot = DEFAULT_REPO_ROOT) {
  const schema = readJsonFile(resolveSchemaPath(repoRoot));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  if (!validate(envelope)) {
    throw new Error(
      `Mission-control envelope failed schema validation against ${DEFAULT_MISSION_CONTROL_ENVELOPE_SCHEMA_PATH}: ${JSON.stringify(validate.errors, null, 2)}`,
    );
  }
  if (envelope?.schema !== MISSION_CONTROL_ENVELOPE_SCHEMA) {
    throw new Error(`Mission-control envelope schema must be '${MISSION_CONTROL_ENVELOPE_SCHEMA}'.`);
  }
}

function normalizePromptScalar(value, fieldName) {
  if (typeof value === 'string') {
    const raw = String(value);
    if (/[\r\n]/.test(raw)) {
      throw new Error(`Mission-control prompt field '${fieldName}' must not contain newlines.`);
    }
    const normalized = normalizeText(raw);
    if (!normalized) {
      throw new Error(`Mission-control prompt field '${fieldName}' must be non-empty single-line text.`);
    }
    return normalized;
  }
  if (typeof value === 'boolean' || typeof value === 'number') {
    return String(value);
  }
  throw new Error(`Mission-control prompt field '${fieldName}' must be a scalar value.`);
}

function formatOverride(override) {
  return `${normalizePromptScalar(override.key, 'operator.overrides[].key')}=${normalizePromptScalar(override.value, 'operator.overrides[].value')}`;
}

export function renderMissionControlPrompt(envelope, { repoRoot = DEFAULT_REPO_ROOT, validate = true } = {}) {
  if (validate) {
    validateMissionControlEnvelope(envelope, repoRoot);
  }
  const missionControl = envelope.missionControl;
  const operator = envelope.operator;
  const overrides = operator.overrides.length > 0
    ? operator.overrides.map((override) => `- ${formatOverride(override)}`)
    : ['- none'];

  const lines = [
    'Act as the autonomous mission control plane for `compare-vi-cli-action`.',
    '',
    'Mission control law:',
    `- profile: \`${normalizePromptScalar(missionControl.profile, 'missionControl.profile')}\``,
    `- mode: \`${normalizePromptScalar(missionControl.mode, 'missionControl.mode')}\``,
    `- standing source: \`${normalizePromptScalar(missionControl.standingPriority.source, 'missionControl.standingPriority.source')}\``,
    `- standing labels: upstream=\`${normalizePromptScalar(missionControl.standingPriority.upstreamLabel, 'missionControl.standingPriority.upstreamLabel')}\`, fork=\`${normalizePromptScalar(missionControl.standingPriority.forkLabel, 'missionControl.standingPriority.forkLabel')}\`, fallback=\`${normalizePromptScalar(missionControl.standingPriority.forkFallbackLabel, 'missionControl.standingPriority.forkFallbackLabel')}\``,
    `- queue-empty behavior: \`${normalizePromptScalar(missionControl.standingPriority.queueEmptyBehavior, 'missionControl.standingPriority.queueEmptyBehavior')}\``,
    `- branch creation gate: \`${normalizePromptScalar(missionControl.standingPriority.branchCreationGate, 'missionControl.standingPriority.branchCreationGate')}\``,
    `- live lane count: \`${normalizePromptScalar(missionControl.lanePolicy.liveLaneCount, 'missionControl.lanePolicy.liveLaneCount')}\``,
    `- max active coding lanes: \`${normalizePromptScalar(missionControl.lanePolicy.maxActiveCodingLanes, 'missionControl.lanePolicy.maxActiveCodingLanes')}\``,
    `- max parked lanes: \`${normalizePromptScalar(missionControl.lanePolicy.maxParkedLaneCount, 'missionControl.lanePolicy.maxParkedLaneCount')}\``,
    `- parked lane requires GitHub wait: \`${normalizePromptScalar(missionControl.lanePolicy.parkedLaneRequiresGithubWait, 'missionControl.lanePolicy.parkedLaneRequiresGithubWait')}\``,
    `- disjoint file scopes required: \`${normalizePromptScalar(missionControl.lanePolicy.requireDisjointFileScopes, 'missionControl.lanePolicy.requireDisjointFileScopes')}\``,
    `- third lane allowed: \`${normalizePromptScalar(missionControl.lanePolicy.allowThirdLane, 'missionControl.lanePolicy.allowThirdLane')}\``,
    `- merge authority: \`${normalizePromptScalar(missionControl.lanePolicy.mergeAuthority, 'missionControl.lanePolicy.mergeAuthority')}\``,
    `- clean worktrees required: \`${normalizePromptScalar(missionControl.worktreePolicy.cleanWorktreesRequired, 'missionControl.worktreePolicy.cleanWorktreesRequired')}\``,
    `- dirty root quarantined: \`${normalizePromptScalar(missionControl.worktreePolicy.dirtyRootQuarantined, 'missionControl.worktreePolicy.dirtyRootQuarantined')}\``,
    `- worktree base ref: \`${normalizePromptScalar(missionControl.worktreePolicy.worktreeBaseRef, 'missionControl.worktreePolicy.worktreeBaseRef')}\``,
    `- sync before/after merge: \`${normalizePromptScalar(missionControl.remoteSyncPolicy.syncBeforeAndAfterMerge, 'missionControl.remoteSyncPolicy.syncBeforeAndAfterMerge')}\``,
    `- develop parity remotes: \`${missionControl.remoteSyncPolicy.developParityRemotes.map((value) => normalizePromptScalar(value, 'missionControl.remoteSyncPolicy.developParityRemotes[]')).join('`, `')}\``,
    `- raw npm allowed: \`${normalizePromptScalar(missionControl.packageManagerPolicy.allowRawNpm, 'missionControl.packageManagerPolicy.allowRawNpm')}\``,
    `- allowed npm wrappers: \`${missionControl.packageManagerPolicy.allowedWrappers.map((value) => normalizePromptScalar(value, 'missionControl.packageManagerPolicy.allowedWrappers[]')).join('`, `')}\``,
    `- bootstrap helper: \`${normalizePromptScalar(missionControl.repoHelpers.bootstrap, 'missionControl.repoHelpers.bootstrap')}\``,
    `- project portfolio helper: \`${normalizePromptScalar(missionControl.repoHelpers.projectPortfolioCheck, 'missionControl.repoHelpers.projectPortfolioCheck')}\``,
    `- develop sync helper: \`${normalizePromptScalar(missionControl.repoHelpers.developSync, 'missionControl.repoHelpers.developSync')}\``,
    `- PR helper: \`${normalizePromptScalar(missionControl.repoHelpers.prCreate, 'missionControl.repoHelpers.prCreate')}\``,
    `- standing handoff helper: \`${normalizePromptScalar(missionControl.repoHelpers.standingHandoff, 'missionControl.repoHelpers.standingHandoff')}\``,
    `- epic-child link helper: \`${normalizePromptScalar(missionControl.repoHelpers.epicChildLink, 'missionControl.repoHelpers.epicChildLink')}\``,
    `- safe PR polling helper: \`${normalizePromptScalar(missionControl.repoHelpers.safePrCheckPolling, 'missionControl.repoHelpers.safePrCheckPolling')}\``,
    `- Copilot CLI usage mode: \`${normalizePromptScalar(missionControl.copilotCli.usageMode, 'missionControl.copilotCli.usageMode')}\``,
    `- Copilot CLI scope: \`${normalizePromptScalar(missionControl.copilotCli.scope, 'missionControl.copilotCli.scope')}\``,
    `- Copilot CLI purposes: \`${missionControl.copilotCli.purposes.map((value) => normalizePromptScalar(value, 'missionControl.copilotCli.purposes[]')).join('`, `')}\``,
    `- hosted replacement allowed: \`${normalizePromptScalar(missionControl.copilotCli.hostedReplacementAllowed, 'missionControl.copilotCli.hostedReplacementAllowed')}\``,
    `- merge green PR immediately: \`${normalizePromptScalar(missionControl.antiIdle.mergeGreenPrImmediately, 'missionControl.antiIdle.mergeGreenPrImmediately')}\``,
    `- create next child when only epics remain: \`${normalizePromptScalar(missionControl.antiIdle.createNextConcreteChildWhenOnlyEpicsRemain, 'missionControl.antiIdle.createNextConcreteChildWhenOnlyEpicsRemain')}\``,
    `- close completed epic when children done: \`${normalizePromptScalar(missionControl.antiIdle.closeCompletedEpicWhenChildrenDone, 'missionControl.antiIdle.closeCompletedEpicWhenChildrenDone')}\``,
    '',
    'Operator input:',
    `- intent: \`${normalizePromptScalar(operator.intent, 'operator.intent')}\``,
    `- focus: \`${normalizePromptScalar(operator.focus, 'operator.focus')}\``,
    '- overrides:',
    ...overrides,
    '',
    'Stop conditions:',
    ...missionControl.stopConditions.map((condition) => `- \`${normalizePromptScalar(condition, 'missionControl.stopConditions[]')}\``),
    '',
    'Do not stop merely because a task finished. Replace it with the next deterministic action and keep the control plane flowing.',
  ];

  return `${lines.join('\n')}\n`;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    envelopePath: null,
    envelopePathSource: null,
    promptPath: DEFAULT_MISSION_CONTROL_PROMPT_PATH,
    promptPathSource: 'default',
    reportPath: DEFAULT_MISSION_CONTROL_PROMPT_REPORT_PATH,
    reportPathSource: 'default',
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    const next = args[index + 1];
    if (token === '--envelope' || token === '--prompt' || token === '--report') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--envelope') {
        options.envelopePath = next;
        options.envelopePathSource = 'explicit';
      }
      if (token === '--prompt') {
        options.promptPath = next;
        options.promptPathSource = 'explicit';
      }
      if (token === '--report') {
        options.reportPath = next;
        options.reportPathSource = 'explicit';
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !normalizeText(options.envelopePath)) {
    throw new Error('Envelope path is required. Pass --envelope <path>.');
  }

  return options;
}

function printUsage(logFn = console.log) {
  logFn('Usage: node tools/priority/render-mission-control-prompt.mjs [options]');
  logFn('');
  logFn('Render a canonical operator prompt from a validated mission-control envelope.');
  logFn('');
  logFn('Options:');
  logFn('  --envelope <path>    Envelope path (required).');
  logFn(`  --prompt <path>      Prompt output path (default: ${DEFAULT_MISSION_CONTROL_PROMPT_PATH}).`);
  logFn(`  --report <path>      Report output path (default: ${DEFAULT_MISSION_CONTROL_PROMPT_REPORT_PATH}).`);
  logFn('  -h, --help           Show help.');
}

export function renderMissionControlPromptReport(
  {
    envelopePath,
    promptPath = DEFAULT_MISSION_CONTROL_PROMPT_PATH,
  },
  {
    repoRoot = DEFAULT_REPO_ROOT,
    cwd = repoRoot,
    envelopePathSource = 'explicit',
    promptPathSource = 'default',
  } = {},
) {
  if (!normalizeText(envelopePath)) {
    throw new Error('Envelope path is required. Pass --envelope <path>.');
  }
  const resolvedEnvelopePath = resolveInputPath(envelopePath, { repoRoot, cwd, source: envelopePathSource });
  const resolvedPromptPath = resolveInputPath(promptPath, { repoRoot, cwd, source: promptPathSource });
  const envelope = readJsonFile(resolvedEnvelopePath);
  validateMissionControlEnvelope(envelope, repoRoot);
  const promptText = renderMissionControlPrompt(envelope, { repoRoot, validate: false });
  const promptSha256 = createHash('sha256').update(promptText, 'utf8').digest('hex');
  const envelopeSha256 = createHash('sha256').update(JSON.stringify(envelope), 'utf8').digest('hex');

  return {
    schema: MISSION_CONTROL_PROMPT_RENDER_SCHEMA,
    envelopePath: resolvedEnvelopePath,
    envelopeSha256,
    promptPath: resolvedPromptPath,
    promptSha256,
    promptLineCount: promptText.trimEnd().split('\n').length,
    operator: {
      intent: envelope.operator.intent,
      focus: envelope.operator.focus,
      overrides: envelope.operator.overrides,
    },
    promptText,
  };
}

export function main(
  argv = process.argv,
  {
    repoRoot = DEFAULT_REPO_ROOT,
    cwd = process.cwd(),
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
    const report = renderMissionControlPromptReport(
      {
        envelopePath: options.envelopePath,
        promptPath: options.promptPath,
      },
      {
        repoRoot,
        cwd,
        envelopePathSource: options.envelopePathSource,
        promptPathSource: options.promptPathSource,
      },
    );
    const promptPath = writeFile(report.promptPath, report.promptText);
    const reportPath = writeFile(
      resolveInputPath(options.reportPath, { repoRoot, cwd, source: options.reportPathSource }),
      `${JSON.stringify(report, null, 2)}\n`,
    );
    logFn(`[mission-control:prompt] prompt: ${promptPath}`);
    logFn(`[mission-control:prompt] report: ${reportPath}`);
    logFn(
      `[mission-control:prompt] intent=${report.operator.intent} focus=${report.operator.focus} sha256=${report.promptSha256}`,
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

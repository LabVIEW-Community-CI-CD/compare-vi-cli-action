#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'human-go-no-go-decision@v1';
export const EVENT_SCHEMA = 'human-go-no-go-event@v1';
export const DEFAULT_SCHEMA_VERSION = '1.0.0';
export const DEFAULT_WORKFLOW_NAME = 'Human Go/No-Go Feedback';
export const DEFAULT_WORKFLOW_PATH = '.github/workflows/human-go-no-go-feedback.yml';
export const DEFAULT_ARTIFACT_NAME = 'human-go-no-go-decision';
export const DEFAULT_DECISION_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'human-go-no-go-decision.json',
);
export const DEFAULT_EVENTS_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'human-go-no-go-events.ndjson',
);

function printUsage() {
  console.log('Usage: node tools/priority/human-go-no-go-feedback.mjs [options]');
  console.log('');
  console.log('Write a deterministic manual go/no-go decision receipt and event stream.');
  console.log('');
  console.log('Options:');
  console.log('  --decision <go|nogo>              Required human decision.');
  console.log('  --feedback <text>                 Required human feedback.');
  console.log('  --context <text>                  Required target context (branch, issue lane, or queue lane).');
  console.log('  --repository <owner/repo>         Target repository (default: GITHUB_REPOSITORY or git remotes).');
  console.log('  --ref <ref>                       Target ref (default: --context).');
  console.log('  --run-id <id>                     Target workflow run id.');
  console.log('  --issue-url <url>                 Linked issue URL.');
  console.log('  --pull-request-url <url>          Linked pull request URL.');
  console.log('  --evidence-url <url>              Linked evidence URL.');
  console.log('  --recorded-by <login>             Human actor recording the decision.');
  console.log('  --transcribed-for <login>         Optional actor the decision was transcribed for.');
  console.log('  --recommended-action <value>      continue | revise | pause (default: decision-derived).');
  console.log('  --seed <text>                     Optional next-iteration seed.');
  console.log(`  --artifact-name <name>            Artifact name (default: ${DEFAULT_ARTIFACT_NAME}).`);
  console.log(`  --decision-out <path>             Decision JSON path (default: ${DEFAULT_DECISION_PATH}).`);
  console.log(`  --events-out <path>               Event stream path (default: ${DEFAULT_EVENTS_PATH}).`);
  console.log('  --step-summary <path>             Optional GitHub step summary path.');
  console.log('  --generated-at <iso>              Fixed timestamp for deterministic tests.');
  console.log('  -h, --help                        Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeLower(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function normalizeUri(value, optionName) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  try {
    return new URL(normalized).toString();
  } catch {
    throw new Error(`${optionName} must be a valid absolute URI.`);
  }
}

function normalizeIso(value, optionName) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = new Date(normalized);
  if (Number.isNaN(parsed.valueOf())) {
    throw new Error(`${optionName} must be a valid ISO-8601 date-time.`);
  }
  return parsed.toISOString();
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  return normalizeRepository(repoPath);
}

function normalizeRepository(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const segments = normalized.split('/').map((segment) => segment.trim());
  if (segments.length !== 2 || segments.some((segment) => segment.length === 0)) {
    throw new Error(`Repository must use the form <owner>/<repo>; received '${value}'.`);
  }
  return `${segments[0]}/${segments[1]}`;
}

function resolveRepositoryFromGitConfig(repoRoot) {
  const configPath = path.join(repoRoot, '.git', 'config');
  if (!fs.existsSync(configPath)) {
    return null;
  }
  const config = fs.readFileSync(configPath, 'utf8');
  for (const remoteName of ['upstream', 'origin']) {
    const escaped = remoteName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const sectionMatch = config.match(
      new RegExp(`\\[remote\\s+"${escaped}"\\]([\\s\\S]*?)(?:\\n\\[|$)`, 'i'),
    );
    const section = sectionMatch?.[1];
    if (!section) {
      continue;
    }
    const urlMatch = section.match(/^\s*url\s*=\s*(.+)$/im);
    const repository = parseRemoteUrl(urlMatch?.[1]?.trim());
    if (repository) {
      return repository;
    }
  }
  return null;
}

function resolveRepository(value, environment, repoRoot) {
  return (
    normalizeRepository(value) ??
    normalizeRepository(environment.GITHUB_REPOSITORY) ??
    resolveRepositoryFromGitConfig(repoRoot) ??
    null
  );
}

function defaultRecommendedAction(decision) {
  return decision === 'go' ? 'continue' : 'revise';
}

function ensureChoice(value, optionName, allowed) {
  const normalized = normalizeLower(value);
  if (!normalized || !allowed.includes(normalized)) {
    throw new Error(`${optionName} must be one of: ${allowed.join(', ')}.`);
  }
  return normalized;
}

function writeJsonFile(filePath, payload) {
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function appendNdjsonLine(filePath, payload) {
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.appendFileSync(resolved, `${JSON.stringify(payload)}\n`, 'utf8');
  return resolved;
}

function appendStepSummary(stepSummaryPath, payload) {
  if (!stepSummaryPath) {
    return;
  }
  const lines = [
    '### Human Go/No-Go Decision',
    '',
    `- decision: \`${payload.decision.value}\``,
    `- recommended_action: \`${payload.nextIteration.recommendedAction}\``,
    `- context: \`${payload.target.context}\``,
    `- ref: \`${payload.target.ref}\``,
    `- artifact: \`${payload.artifacts.artifactName}\``,
    '',
    `Feedback: ${payload.decision.feedback}`,
  ];
  const resolved = path.resolve(process.cwd(), stepSummaryPath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${lines.join('\n')}\n`, { encoding: 'utf8', flag: 'a' });
}

export function parseArgs(argv = process.argv, environment = process.env, repoRoot = process.cwd()) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repository: resolveRepository(null, environment, repoRoot),
    context: null,
    ref: null,
    runId: normalizeText(environment.GITHUB_RUN_ID),
    issueUrl: null,
    pullRequestUrl: null,
    decision: null,
    feedback: null,
    recordedBy: normalizeText(environment.GITHUB_ACTOR),
    transcribedFor: null,
    evidenceUrl: null,
    recommendedAction: null,
    seed: null,
    artifactName: DEFAULT_ARTIFACT_NAME,
    decisionPath: DEFAULT_DECISION_PATH,
    eventsPath: DEFAULT_EVENTS_PATH,
    stepSummaryPath: normalizeText(environment.GITHUB_STEP_SUMMARY),
    generatedAt: null,
    workflowName: DEFAULT_WORKFLOW_NAME,
    workflowPath: DEFAULT_WORKFLOW_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--repository' ||
      token === '--context' ||
      token === '--ref' ||
      token === '--run-id' ||
      token === '--issue-url' ||
      token === '--pull-request-url' ||
      token === '--decision' ||
      token === '--feedback' ||
      token === '--recorded-by' ||
      token === '--transcribed-for' ||
      token === '--evidence-url' ||
      token === '--recommended-action' ||
      token === '--seed' ||
      token === '--artifact-name' ||
      token === '--decision-out' ||
      token === '--events-out' ||
      token === '--step-summary' ||
      token === '--generated-at'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repository') options.repository = resolveRepository(next, environment, repoRoot);
      if (token === '--context') options.context = normalizeText(next);
      if (token === '--ref') options.ref = normalizeText(next);
      if (token === '--run-id') options.runId = normalizeText(next);
      if (token === '--issue-url') options.issueUrl = normalizeUri(next, '--issue-url');
      if (token === '--pull-request-url') options.pullRequestUrl = normalizeUri(next, '--pull-request-url');
      if (token === '--decision') options.decision = ensureChoice(next, '--decision', ['go', 'nogo']);
      if (token === '--feedback') options.feedback = normalizeText(next);
      if (token === '--recorded-by') options.recordedBy = normalizeText(next);
      if (token === '--transcribed-for') options.transcribedFor = normalizeText(next);
      if (token === '--evidence-url') options.evidenceUrl = normalizeUri(next, '--evidence-url');
      if (token === '--recommended-action') {
        options.recommendedAction = ensureChoice(next, '--recommended-action', ['continue', 'revise', 'pause']);
      }
      if (token === '--seed') options.seed = normalizeText(next);
      if (token === '--artifact-name') options.artifactName = normalizeText(next);
      if (token === '--decision-out') options.decisionPath = next;
      if (token === '--events-out') options.eventsPath = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
      if (token === '--generated-at') options.generatedAt = normalizeIso(next, '--generated-at');
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.repository) {
      throw new Error('Repository is required. Pass --repository <owner/repo> or set GITHUB_REPOSITORY.');
    }
    if (!options.context) {
      throw new Error('--context is required.');
    }
    if (!options.feedback) {
      throw new Error('--feedback is required.');
    }
    if (!options.decision) {
      throw new Error('--decision is required.');
    }
    options.ref ??= options.context;
    options.recommendedAction ??= defaultRecommendedAction(options.decision);
    if (!options.artifactName) {
      throw new Error('--artifact-name must not be empty.');
    }
  }

  return options;
}

function buildRunUrl(repository, runId, environment) {
  const normalizedRunId = normalizeText(runId);
  if (!normalizedRunId) {
    return null;
  }
  const serverUrl = normalizeText(environment.GITHUB_SERVER_URL) ?? 'https://github.com';
  return `${serverUrl}/${repository}/actions/runs/${normalizedRunId}`;
}

export function buildHumanGoNoGoDecisionPayload(options, environment = process.env, now = new Date()) {
  const generatedAt = options.generatedAt ?? now.toISOString();
  const decisionPath = options.decisionPath.replace(/\\/g, '/');
  const eventsPath = options.eventsPath ? options.eventsPath.replace(/\\/g, '/') : null;

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: DEFAULT_SCHEMA_VERSION,
    generatedAt,
    workflow: {
      name: options.workflowName,
      path: options.workflowPath,
    },
    target: {
      repository: options.repository,
      context: options.context,
      ref: options.ref,
      runId: normalizeText(options.runId),
      issueUrl: options.issueUrl,
      pullRequestUrl: options.pullRequestUrl,
    },
    decision: {
      value: options.decision,
      feedback: options.feedback,
      recordedBy: normalizeText(options.recordedBy),
      transcribedFor: normalizeText(options.transcribedFor),
    },
    links: {
      runUrl: buildRunUrl(options.repository, options.runId, environment),
      evidenceUrl: options.evidenceUrl,
    },
    artifacts: {
      artifactName: options.artifactName,
      decisionPath,
      eventsPath,
    },
    nextIteration: {
      recommendedAction: options.recommendedAction,
      seed: normalizeText(options.seed),
    },
  };
}

function buildEventPayload(payload) {
  return {
    schema: EVENT_SCHEMA,
    generatedAt: payload.generatedAt,
    event: 'recorded',
    workflow: payload.workflow.name,
    decision: payload.decision.value,
    recommendedAction: payload.nextIteration.recommendedAction,
    target: {
      repository: payload.target.repository,
      context: payload.target.context,
      ref: payload.target.ref,
      runId: payload.target.runId,
    },
    decisionPath: payload.artifacts.decisionPath,
  };
}

export async function runHumanGoNoGoFeedback({
  argv = process.argv,
  environment = process.env,
  repoRoot = process.cwd(),
  now = new Date(),
  writeJsonFn = writeJsonFile,
  appendNdjsonFn = appendNdjsonLine,
  appendStepSummaryFn = appendStepSummary,
} = {}) {
  const options = parseArgs(argv, environment, repoRoot);
  if (options.help) {
    printUsage();
    return {
      exitCode: 0,
      payload: null,
      event: null,
      decisionPath: null,
      eventsPath: null,
    };
  }

  const payload = buildHumanGoNoGoDecisionPayload(options, environment, now);
  const event = buildEventPayload(payload);
  const decisionPath = writeJsonFn(options.decisionPath, payload);
  const eventsPath = appendNdjsonFn(options.eventsPath, event);
  appendStepSummaryFn(options.stepSummaryPath, payload);

  return {
    exitCode: 0,
    payload,
    event,
    decisionPath,
    eventsPath,
  };
}

export async function main(argv = process.argv) {
  try {
    const result = await runHumanGoNoGoFeedback({ argv });
    if (result.payload) {
      console.log(`[human-go-no-go-feedback] decision: ${result.decisionPath}`);
      console.log(`[human-go-no-go-feedback] events: ${result.eventsPath}`);
      console.log(
        `[human-go-no-go-feedback] decision=${result.payload.decision.value} recommendedAction=${result.payload.nextIteration.recommendedAction}`,
      );
    }
    return result.exitCode;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main().then((exitCode) => {
    process.exit(exitCode);
  });
}

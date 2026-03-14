#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { downloadNamedArtifacts } from './lib/run-artifact-download.mjs';

export const REPORT_SCHEMA = 'human-go-no-go-latest@v1';
export const DEFAULT_SCHEMA_VERSION = '1.0.0';
export const DEFAULT_WORKFLOW_NAME = 'Human Go/No-Go Feedback';
export const DEFAULT_WORKFLOW_PATH = '.github/workflows/human-go-no-go-feedback.yml';
export const DEFAULT_ARTIFACT_NAME = 'human-go-no-go-decision';
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'human-go-no-go-latest.json',
);
export const DEFAULT_DESTINATION_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'latest-human-go-no-go',
);
export const DEFAULT_DOWNLOAD_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'human-go-no-go-latest-download.json',
);
export const DECISION_SCHEMA_PATH = path.join(
  'docs',
  'schemas',
  'human-go-no-go-decision-v1.schema.json',
);
const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;

function printUsage() {
  console.log('Usage: node tools/priority/human-go-no-go-latest.mjs [options]');
  console.log('');
  console.log('Resolve the latest human go/no-go decision through the workflow artifact path.');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>              Target repository (default: GITHUB_REPOSITORY or git remotes).');
  console.log(`  --workflow <path>                Workflow identifier (default: ${DEFAULT_WORKFLOW_PATH}).`);
  console.log(`  --artifact <name>                Artifact name (default: ${DEFAULT_ARTIFACT_NAME}).`);
  console.log('  --run-id <id>                    Explicit workflow run id to resolve.');
  console.log('  --ref <branch>                   Optional head branch filter when selecting the latest run.');
  console.log('  --fail-on-nogo                   Exit non-zero when the resolved decision is nogo.');
  console.log(`  --destination-root <path>        Download destination root (default: ${DEFAULT_DESTINATION_ROOT}).`);
  console.log(`  --download-report <path>         Artifact download report path (default: ${DEFAULT_DOWNLOAD_REPORT_PATH}).`);
  console.log(`  --out <path>                     Summary report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  -h, --help                       Show help.');
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

function normalizeInteger(value) {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value;
  }
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = Number.parseInt(normalized, 10);
  return Number.isInteger(parsed) ? parsed : null;
}

function normalizeIso(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = new Date(normalized);
  if (Number.isNaN(parsed.valueOf())) {
    return null;
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

function writeJsonFile(filePath, payload) {
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function runProcess(command, args) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES,
  });
  return {
    status: typeof result.status === 'number' ? result.status : null,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function runGhJson(args) {
  const result = runProcess('gh', args);
  if (result.error || result.status !== 0) {
    const message =
      normalizeText(result.stderr) ??
      normalizeText(result.stdout) ??
      (result.error instanceof Error ? result.error.message : String(result.error));
    throw new Error(message ?? `gh ${args.join(' ')} failed.`);
  }
  return JSON.parse(result.stdout ?? 'null');
}

function sortRunsNewestFirst(runs) {
  return [...(Array.isArray(runs) ? runs : [])].sort(
    (left, right) =>
      new Date(right?.updatedAt ?? right?.updated_at ?? right?.createdAt ?? right?.created_at ?? 0).valueOf() -
      new Date(left?.updatedAt ?? left?.updated_at ?? left?.createdAt ?? left?.created_at ?? 0).valueOf(),
  );
}

function listRelativeFiles(rootPath) {
  if (!fs.existsSync(rootPath)) {
    return [];
  }
  const files = [];
  const walk = (currentPath) => {
    for (const entry of fs.readdirSync(currentPath, { withFileTypes: true })) {
      const fullPath = path.join(currentPath, entry.name);
      if (entry.isDirectory()) {
        walk(fullPath);
        continue;
      }
      if (entry.isFile()) {
        files.push(path.relative(rootPath, fullPath));
      }
    }
  };
  walk(rootPath);
  return files.sort((left, right) => left.localeCompare(right));
}

function findDecisionFile(rootPath) {
  for (const relativePath of listRelativeFiles(rootPath)) {
    if (path.basename(relativePath).toLowerCase() === 'human-go-no-go-decision.json') {
      return path.join(rootPath, relativePath);
    }
  }
  return null;
}

function loadDecisionSchema(repoRoot) {
  const schemaPath = path.join(repoRoot, DECISION_SCHEMA_PATH);
  if (!fs.existsSync(schemaPath)) {
    throw new Error(`Decision schema not found: ${schemaPath}`);
  }
  return JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
}

function validateDecisionPayload(payload, repoRoot) {
  const schema = loadDecisionSchema(repoRoot);
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  if (!validate(payload)) {
    throw new Error(`Decision payload failed schema validation: ${JSON.stringify(validate.errors, null, 2)}`);
  }
}

export function parseArgs(argv = process.argv, environment = process.env, repoRoot = process.cwd()) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: normalizeRepository(environment.GITHUB_REPOSITORY) ?? resolveRepositoryFromGitConfig(repoRoot),
    workflow: DEFAULT_WORKFLOW_PATH,
    artifactName: DEFAULT_ARTIFACT_NAME,
    runId: null,
    ref: null,
    failOnNogo: false,
    destinationRoot: DEFAULT_DESTINATION_ROOT,
    downloadReportPath: DEFAULT_DOWNLOAD_REPORT_PATH,
    reportPath: DEFAULT_REPORT_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--fail-on-nogo') {
      options.failOnNogo = true;
      continue;
    }
    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--workflow' ||
      token === '--artifact' ||
      token === '--run-id' ||
      token === '--ref' ||
      token === '--destination-root' ||
      token === '--download-report' ||
      token === '--out'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeRepository(next);
      if (token === '--workflow') options.workflow = next;
      if (token === '--artifact') options.artifactName = normalizeText(next);
      if (token === '--run-id') options.runId = normalizeText(next);
      if (token === '--ref') options.ref = normalizeText(next);
      if (token === '--destination-root') options.destinationRoot = next;
      if (token === '--download-report') options.downloadReportPath = next;
      if (token === '--out') options.reportPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.repo) {
      throw new Error('Repository is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
    }
    if (!options.workflow) {
      throw new Error('--workflow must not be empty.');
    }
    if (!options.artifactName) {
      throw new Error('--artifact must not be empty.');
    }
  }

  return options;
}

function normalizeRunPayload(run) {
  return {
    id: normalizeInteger(run?.databaseId ?? run?.id),
    workflowName: normalizeText(run?.workflowName ?? run?.name) ?? DEFAULT_WORKFLOW_NAME,
    displayTitle: normalizeText(run?.displayTitle ?? run?.display_title),
    url: normalizeText(run?.url ?? run?.html_url),
    headBranch: normalizeText(run?.headBranch ?? run?.head_branch),
    headSha: normalizeText(run?.headSha ?? run?.head_sha),
    event: normalizeText(run?.event),
    status: normalizeLower(run?.status),
    conclusion: normalizeLower(run?.conclusion),
    createdAt: normalizeIso(run?.createdAt ?? run?.created_at),
    updatedAt: normalizeIso(run?.updatedAt ?? run?.updated_at),
  };
}

function selectLatestRun(runs, ref) {
  const normalizedRef = normalizeText(ref);
  const candidates = sortRunsNewestFirst(runs)
    .map(normalizeRunPayload)
    .filter((run) => run.status === 'completed' && run.conclusion === 'success');
  const filtered = normalizedRef ? candidates.filter((run) => run.headBranch === normalizedRef) : candidates;
  return filtered[0] ?? null;
}

function resolveLatestRun(repository, workflow, ref, runGhJsonFn) {
  const payload = runGhJsonFn([
    'run',
    'list',
    '--repo',
    repository,
    '--workflow',
    workflow,
    '--limit',
    '20',
    '--json',
    'databaseId,name,displayTitle,url,headBranch,headSha,event,status,conclusion,createdAt,updatedAt',
  ]);
  const run = selectLatestRun(payload, ref);
  if (!run) {
    const refText = normalizeText(ref);
    throw new Error(
      refText
        ? `No successful ${workflow} runs found for ref '${refText}' in ${repository}.`
        : `No successful ${workflow} runs found in ${repository}.`,
    );
  }
  return run;
}

function resolveExplicitRun(repository, runId, runGhJsonFn) {
  const payload = runGhJsonFn(['api', `repos/${repository}/actions/runs/${runId}`]);
  return normalizeRunPayload(payload);
}

export async function runHumanGoNoGoLatest({
  argv = process.argv,
  environment = process.env,
  repoRoot = process.cwd(),
  now = new Date(),
  runGhJsonFn = runGhJson,
  downloadArtifactsFn = downloadNamedArtifacts,
  writeJsonFn = writeJsonFile,
} = {}) {
  const options = parseArgs(argv, environment, repoRoot);
  if (options.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  const selectedRun = options.runId
    ? resolveExplicitRun(options.repo, options.runId, runGhJsonFn)
    : resolveLatestRun(options.repo, options.workflow, options.ref, runGhJsonFn);

  const downloadResult = downloadArtifactsFn({
    repository: options.repo,
    runId: String(selectedRun.id),
    artifactNames: [options.artifactName],
    destinationRoot: options.destinationRoot,
    reportPath: options.downloadReportPath,
    now,
  });
  if (downloadResult.report.status !== 'pass') {
    throw new Error(downloadResult.report.errors?.[0] ?? 'Artifact download failed.');
  }

  const downloadEntry = downloadResult.report.downloads.find((entry) => entry.name === options.artifactName);
  const artifactRoot = downloadEntry?.destination ? path.resolve(process.cwd(), downloadEntry.destination) : null;
  if (!artifactRoot) {
    throw new Error(`Artifact destination for '${options.artifactName}' was not recorded.`);
  }

  const decisionPath = findDecisionFile(artifactRoot);
  if (!decisionPath) {
    throw new Error(`Decision file human-go-no-go-decision.json was not found under ${artifactRoot}.`);
  }

  const decisionPayload = JSON.parse(fs.readFileSync(decisionPath, 'utf8'));
  validateDecisionPayload(decisionPayload, repoRoot);

  const blocking = decisionPayload?.decision?.value === 'nogo';
  const report = {
    schema: REPORT_SCHEMA,
    schemaVersion: DEFAULT_SCHEMA_VERSION,
    generatedAt: new Date(now).toISOString(),
    status: 'pass',
    repository: options.repo,
    workflow: {
      name: DEFAULT_WORKFLOW_NAME,
      path: DEFAULT_WORKFLOW_PATH,
    },
    selection: {
      mode: options.runId ? 'explicit-run' : 'latest-successful-run',
      ref: normalizeText(options.ref),
      failOnNogo: options.failOnNogo,
    },
    sourceRun: selectedRun,
    artifact: {
      name: options.artifactName,
      destinationRoot: artifactRoot,
      decisionPath,
      downloadReportPath: path.resolve(process.cwd(), options.downloadReportPath),
    },
    latestDecision: {
      value: decisionPayload.decision.value,
      feedback: decisionPayload.decision.feedback,
      recordedBy: decisionPayload.decision.recordedBy,
      transcribedFor: decisionPayload.decision.transcribedFor,
      recommendedAction: decisionPayload.nextIteration.recommendedAction,
      seed: decisionPayload.nextIteration.seed,
      generatedAt: decisionPayload.generatedAt,
      issueUrl: decisionPayload.target.issueUrl,
      pullRequestUrl: decisionPayload.target.pullRequestUrl,
      runUrl: decisionPayload.links.runUrl,
      decisionPath: decisionPayload.artifacts.decisionPath,
      eventsPath: decisionPayload.artifacts.eventsPath,
      blocking,
    },
    decisionReceipt: decisionPayload,
  };

  const reportPath = writeJsonFn(options.reportPath, report);
  const exitCode = options.failOnNogo && blocking ? 2 : 0;
  return { exitCode, report, reportPath };
}

export async function main(argv = process.argv) {
  try {
    const result = await runHumanGoNoGoLatest({ argv });
    if (result.report) {
      console.log(`[human-go-no-go-latest] report: ${result.reportPath}`);
      console.log(
        `[human-go-no-go-latest] decision=${result.report.latestDecision.value} run=${result.report.sourceRun.id} blocking=${result.report.latestDecision.blocking}`,
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
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

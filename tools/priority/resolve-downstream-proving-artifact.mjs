#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { downloadNamedArtifacts } from './lib/run-artifact-download.mjs';

export const REPORT_SCHEMA = 'priority/downstream-proving-selection@v1';
export const DEFAULT_WORKFLOW = 'downstream-promotion.yml';
export const DEFAULT_BRANCH = 'develop';
export const DEFAULT_ARTIFACT_PREFIX = 'downstream-promotion-';
export const DEFAULT_DESTINATION_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'downstream-proving-artifacts'
);
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'downstream-proving-selection.json'
);
const WORKFLOW_RUNS_PAGE_SIZE = 20;
const WORKFLOW_RUNS_MAX_PAGES = 5;

function normalizeText(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeLower(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function normalizeInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) ? parsed : null;
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function printUsage(log = console.log) {
  [
    'Usage: node tools/priority/resolve-downstream-proving-artifact.mjs [options]',
    '',
    'Options:',
    '  --repo <owner/repo>              Repository slug (default: GITHUB_REPOSITORY).',
    `  --workflow <file>               Workflow file (default: ${DEFAULT_WORKFLOW}).`,
    `  --branch <name>                 Workflow run branch filter (default: ${DEFAULT_BRANCH}).`,
    '  --expected-source-sha <sha>     Required source commit sha to match in the scorecard provenance.',
    `  --artifact-prefix <prefix>      Artifact prefix (default: ${DEFAULT_ARTIFACT_PREFIX}).`,
    `  --destination-root <path>       Destination root (default: ${DEFAULT_DESTINATION_ROOT}).`,
    `  --output <path>                 Selection report path (default: ${DEFAULT_REPORT_PATH}).`,
    '  -h, --help                      Show help.'
  ].forEach((line) => log(line));
}

export function parseArgs(argv = process.argv, env = process.env) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: normalizeText(env.GITHUB_REPOSITORY),
    workflow: DEFAULT_WORKFLOW,
    branch: DEFAULT_BRANCH,
    expectedSourceSha: null,
    artifactPrefix: DEFAULT_ARTIFACT_PREFIX,
    destinationRoot: DEFAULT_DESTINATION_ROOT,
    outputPath: DEFAULT_REPORT_PATH
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--workflow' ||
      token === '--branch' ||
      token === '--expected-source-sha' ||
      token === '--artifact-prefix' ||
      token === '--destination-root' ||
      token === '--output'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeText(next);
      if (token === '--workflow') options.workflow = normalizeText(next);
      if (token === '--branch') options.branch = normalizeText(next);
      if (token === '--expected-source-sha') options.expectedSourceSha = normalizeText(next);
      if (token === '--artifact-prefix') options.artifactPrefix = normalizeText(next);
      if (token === '--destination-root') options.destinationRoot = next;
      if (token === '--output') options.outputPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.repo || !options.repo.includes('/')) {
      throw new Error('Repository is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
    }
    if (!options.workflow) {
      throw new Error('--workflow must not be empty.');
    }
    if (!options.expectedSourceSha) {
      throw new Error('--expected-source-sha must not be empty.');
    }
    if (!options.artifactPrefix) {
      throw new Error('--artifact-prefix must not be empty.');
    }
  }

  return options;
}

export function buildWorkflowRunsApiPath(repository, workflow, { page = 1, branch = null, status = 'success' } = {}) {
  const encodedRepository = repository.split('/').map((segment) => encodeURIComponent(segment)).join('/');
  const encodedWorkflow = encodeURIComponent(workflow);
  const query = new URLSearchParams();
  query.set('per_page', String(WORKFLOW_RUNS_PAGE_SIZE));
  query.set('page', String(page));
  if (branch) {
    query.set('branch', branch);
  }
  if (status) {
    query.set('status', status);
  }
  return `repos/${encodedRepository}/actions/workflows/${encodedWorkflow}/runs?${query.toString()}`;
}

function normalizeRunPayload(run) {
  return {
    id: normalizeInteger(run?.id ?? run?.database_id ?? run?.databaseId),
    name: normalizeText(run?.name ?? run?.workflowName),
    url: normalizeText(run?.html_url ?? run?.url),
    headBranch: normalizeText(run?.head_branch ?? run?.headBranch),
    headSha: normalizeText(run?.head_sha ?? run?.headSha),
    status: normalizeLower(run?.status),
    conclusion: normalizeLower(run?.conclusion),
    createdAt: normalizeText(run?.created_at ?? run?.createdAt),
    updatedAt: normalizeText(run?.updated_at ?? run?.updatedAt)
  };
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
      } else if (entry.isFile()) {
        files.push(path.relative(rootPath, fullPath));
      }
    }
  };
  walk(rootPath);
  return files.sort((left, right) => left.localeCompare(right));
}

function findArtifactFile(rootPath, fileName) {
  const normalizedFileName = String(fileName).toLowerCase();
  for (const relativePath of listRelativeFiles(rootPath)) {
    if (path.basename(relativePath).toLowerCase() === normalizedFileName) {
      return path.join(rootPath, relativePath);
    }
  }
  return null;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function classifyScorecard(scorecard, expectedSourceSha) {
  const schema = normalizeText(scorecard?.schema);
  const summaryStatus = normalizeLower(scorecard?.summary?.status);
  const sourceCommitSha = normalizeText(scorecard?.summary?.provenance?.sourceCommitSha);
  const targetBranch = normalizeText(scorecard?.gates?.manifestReport?.targetBranch);
  const manifestStatus = normalizeLower(scorecard?.gates?.manifestReport?.status);
  const blockerCount = normalizeInteger(scorecard?.summary?.blockerCount);
  const downstreamRepository = normalizeText(scorecard?.gates?.feedbackReport?.downstreamRepository);
  const matchedExpectedSourceSha = sourceCommitSha === normalizeText(expectedSourceSha);
  const pass =
    schema === 'priority/downstream-promotion-scorecard@v1' &&
    summaryStatus === 'pass' &&
    manifestStatus === 'pass' &&
    targetBranch === 'downstream/develop' &&
    matchedExpectedSourceSha;

  return {
    status: pass ? 'pass' : 'fail',
    schema,
    summaryStatus,
    sourceCommitSha,
    matchedExpectedSourceSha,
    targetBranch,
    manifestStatus,
    blockerCount,
    downstreamRepository
  };
}

function buildGitHubOutputs(result) {
  return [
    ['downstream_proving_selection_status', result.status],
    ['downstream_proving_selection_report', result.reportPath],
    ['downstream_proving_scorecard_path', result.selected?.scorecardPath ?? ''],
    ['downstream_proving_run_id', result.selected?.run?.id != null ? String(result.selected.run.id) : ''],
    ['downstream_proving_artifact_name', result.selected?.artifactName ?? '']
  ];
}

function appendOptionalProjection(filePath, content) {
  const normalizedPath = normalizeText(filePath);
  if (!normalizedPath) {
    return;
  }
  const resolvedPath = path.resolve(process.cwd(), normalizedPath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.appendFileSync(resolvedPath, content, 'utf8');
}

function writeGitHubOutputs(pairs, env = process.env) {
  if (!normalizeText(env.GITHUB_OUTPUT)) {
    return;
  }
  appendOptionalProjection(
    env.GITHUB_OUTPUT,
    `${pairs.map(([key, value]) => `${key}=${value ?? ''}`).join('\n')}\n`
  );
}

function buildSelectionReport({ options, candidates, selected, now = new Date() }) {
  return {
    schema: REPORT_SCHEMA,
    generatedAt: new Date(now).toISOString(),
    repository: options.repo,
    workflow: options.workflow,
    branch: options.branch,
    expectedSourceSha: options.expectedSourceSha,
    artifactPrefix: options.artifactPrefix,
    status: selected ? 'pass' : 'fail',
    selected,
    candidates
  };
}

export async function runResolveDownstreamProvingArtifact(
  rawOptions = {},
  {
    now = new Date(),
    runGhJsonFn,
    downloadNamedArtifactsFn = downloadNamedArtifacts
  } = {}
) {
  const options = {
    ...rawOptions,
    workflow: normalizeText(rawOptions.workflow) || DEFAULT_WORKFLOW,
    branch: normalizeText(rawOptions.branch) || DEFAULT_BRANCH,
    artifactPrefix: normalizeText(rawOptions.artifactPrefix) || DEFAULT_ARTIFACT_PREFIX,
    destinationRoot: rawOptions.destinationRoot || DEFAULT_DESTINATION_ROOT,
    outputPath: rawOptions.outputPath || DEFAULT_REPORT_PATH
  };

  if (typeof runGhJsonFn !== 'function') {
    throw new Error('runGhJsonFn is required.');
  }

  const candidates = [];
  let selected = null;

  for (let page = 1; page <= WORKFLOW_RUNS_MAX_PAGES; page += 1) {
    const payload = await runGhJsonFn([
      'api',
      buildWorkflowRunsApiPath(options.repo, options.workflow, {
        page,
        branch: options.branch,
        status: 'success'
      })
    ]);
    const runs = Array.isArray(payload?.workflow_runs) ? payload.workflow_runs : [];

    for (const rawRun of runs) {
      const run = normalizeRunPayload(rawRun);
      if (!run.id) {
        continue;
      }
      const artifactName = `${options.artifactPrefix}${run.id}`;
      const candidateRoot = path.join(options.destinationRoot, String(run.id));
      const downloadReportPath = path.join(candidateRoot, 'download-report.json');
      const downloadResult = await downloadNamedArtifactsFn({
        repository: options.repo,
        runId: String(run.id),
        artifactNames: [artifactName],
        destinationRoot: candidateRoot,
        reportPath: downloadReportPath
      });
      const scorecardPath = findArtifactFile(candidateRoot, 'downstream-develop-promotion-scorecard.json');
      let scorecard = null;
      let scorecardGate = null;
      let scorecardError = null;
      if (scorecardPath) {
        try {
          scorecard = readJson(scorecardPath);
          scorecardGate = classifyScorecard(scorecard, options.expectedSourceSha);
        } catch (error) {
          scorecardError = error instanceof Error ? error.message : String(error);
        }
      }

      const candidate = {
        run,
        artifactName,
        downloadStatus: downloadResult.report.status,
        downloadReportPath: downloadResult.reportPath,
        scorecardPath: scorecardPath ? path.resolve(scorecardPath) : null,
        scorecardStatus: scorecardGate?.status ?? 'missing',
        scorecard: scorecardGate,
        scorecardError
      };
      candidates.push(candidate);

      if (
        downloadResult.report.status === 'pass' &&
        scorecardGate?.status === 'pass'
      ) {
        selected = candidate;
        break;
      }
    }

    if (selected || runs.length < WORKFLOW_RUNS_PAGE_SIZE) {
      break;
    }
  }

  const report = buildSelectionReport({ options, candidates, selected, now });
  const reportPath = writeJson(options.outputPath, report);
  writeGitHubOutputs(buildGitHubOutputs({ ...report, reportPath }));
  return { status: report.status, report, reportPath, selected };
}

async function defaultRunGhJson(args) {
  const { spawnSync } = await import('node:child_process');
  const result = spawnSync('gh', args, {
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.error || result.status !== 0) {
    const message = normalizeText(result.stderr) || normalizeText(result.stdout) || result.error?.message || `gh ${args.join(' ')} failed`;
    throw new Error(message);
  }
  return JSON.parse(result.stdout || 'null');
}

export async function main(argv = process.argv, env = process.env) {
  let options;
  try {
    options = parseArgs(argv, env);
  } catch (error) {
    console.error(error.message || String(error));
    printUsage(console.error);
    return 1;
  }
  if (options.help) {
    printUsage();
    return 0;
  }

  const result = await runResolveDownstreamProvingArtifact(options, {
    runGhJsonFn: defaultRunGhJson
  });
  console.log(
    `[downstream-proving-selection] report: ${result.reportPath} (status=${result.status}, run=${result.selected?.run?.id ?? 'none'})`
  );
  return result.status === 'pass' ? 0 : 1;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv, process.env).then((code) => {
    process.exitCode = code;
  }).catch((error) => {
    console.error(error.stack || error.message || String(error));
    process.exitCode = 1;
  });
}

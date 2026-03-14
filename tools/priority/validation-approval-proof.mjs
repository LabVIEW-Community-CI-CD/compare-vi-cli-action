#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { runValidationApprovalBroker } from './validation-approval-broker.mjs';
import { downloadNamedArtifacts } from './lib/run-artifact-download.mjs';

export const REPORT_SCHEMA = 'validation-approval-proof@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'validation-approval-policy.json');
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'approvals',
  'validation-approval-proof.json',
);
export const DEFAULT_ARTIFACTS_DIR = path.join(
  'tests',
  'results',
  '_agent',
  'approvals',
  'proof',
);
export const DEFAULT_ENVIRONMENT = 'validation';
export const DEFAULT_MAX_DEPLOYMENTS = 8;
export const DEFAULT_MIN_SAMPLES = 4;
export const DEFAULT_LOOKBACK_DAYS = 7;

const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const SIGNAL_COLLECTOR_PATH = path.join('dist', 'tools', 'priority', 'copilot-review-signal.js');
const DEPLOYMENT_DETERMINISM_ARTIFACT_NAME = 'validate-deployment-determinism';

function printUsage() {
  console.log('Usage: node tools/priority/validation-approval-proof.mjs [options]');
  console.log('');
  console.log('Replay a recent validation approval window against the broker to prove apply-mode safety.');
  console.log('');
  console.log('Options:');
  console.log(`  --repo <owner/repo>       Target repository (default: GITHUB_REPOSITORY or git remotes).`);
  console.log(`  --environment <name>      Deployment environment to evaluate (default: ${DEFAULT_ENVIRONMENT}).`);
  console.log(`  --policy <path>           Approval policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --max-deployments <n>     Maximum deployment samples to evaluate (default: ${DEFAULT_MAX_DEPLOYMENTS}).`);
  console.log(`  --min-samples <n>         Minimum evaluated samples required for a passing proof (default: ${DEFAULT_MIN_SAMPLES}).`);
  console.log(`  --lookback-days <n>       Only consider deployments created within this many days (default: ${DEFAULT_LOOKBACK_DAYS}).`);
  console.log(`  --artifacts-dir <path>    Directory for staged replay artifacts (default: ${DEFAULT_ARTIFACTS_DIR}).`);
  console.log(`  --report <path>           Output report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --strict                  Fail when proof criteria are not met (default: true).');
  console.log('  --no-strict               Emit warn status without a non-zero exit code.');
  console.log('  --step-summary <path>     Optional GitHub step summary path.');
  console.log('  -h, --help                Show help.');
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

function normalizeSha(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function uniqueStrings(values) {
  return [...new Set((Array.isArray(values) ? values : []).filter(Boolean).map((entry) => String(entry)))];
}

function parseRepoSlug(repo) {
  const normalized = normalizeText(repo);
  if (!normalized) {
    throw new Error(`Invalid repository slug '${repo}'. Expected <owner>/<repo>.`);
  }
  const segments = normalized.split('/').map((segment) => segment.trim());
  if (segments.length !== 2 || segments.some((segment) => segment.length === 0)) {
    throw new Error(`Invalid repository slug '${repo}'. Expected <owner>/<repo>.`);
  }
  return { owner: segments[0], repo: segments[1] };
}

function normalizeRepositorySlug(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  parseRepoSlug(normalized);
  return normalized;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: null,
    environment: DEFAULT_ENVIRONMENT,
    policyPath: DEFAULT_POLICY_PATH,
    maxDeployments: DEFAULT_MAX_DEPLOYMENTS,
    minSamples: DEFAULT_MIN_SAMPLES,
    lookbackDays: DEFAULT_LOOKBACK_DAYS,
    artifactsDir: DEFAULT_ARTIFACTS_DIR,
    reportPath: DEFAULT_REPORT_PATH,
    strict: true,
    stepSummaryPath: null,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--strict') {
      options.strict = true;
      continue;
    }
    if (token === '--no-strict') {
      options.strict = false;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--environment' ||
      token === '--policy' ||
      token === '--max-deployments' ||
      token === '--min-samples' ||
      token === '--lookback-days' ||
      token === '--artifacts-dir' ||
      token === '--report' ||
      token === '--step-summary'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeRepositorySlug(next);
      if (token === '--environment') options.environment = normalizeLower(next) ?? DEFAULT_ENVIRONMENT;
      if (token === '--policy') options.policyPath = next;
      if (token === '--max-deployments') options.maxDeployments = normalizeInteger(next);
      if (token === '--min-samples') options.minSamples = normalizeInteger(next);
      if (token === '--lookback-days') options.lookbackDays = normalizeInteger(next);
      if (token === '--artifacts-dir') options.artifactsDir = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!Number.isInteger(options.maxDeployments) || options.maxDeployments <= 0) {
      throw new Error('--max-deployments must be a positive integer.');
    }
    if (!Number.isInteger(options.minSamples) || options.minSamples <= 0) {
      throw new Error('--min-samples must be a positive integer.');
    }
    if (!Number.isInteger(options.lookbackDays) || options.lookbackDays < 0) {
      throw new Error('--lookback-days must be a non-negative integer.');
    }
  }

  return options;
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  return normalizeRepositorySlug(repoPath);
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
    const parsed = parseRemoteUrl(urlMatch?.[1]?.trim());
    if (parsed) {
      return parsed;
    }
  }
  return null;
}

function resolveRepository(options, repoRoot, environment = process.env) {
  if (options.repo) {
    return options.repo;
  }
  const fromEnv = normalizeRepositorySlug(environment.GITHUB_REPOSITORY);
  if (fromEnv) {
    return fromEnv;
  }
  const fromGit = resolveRepositoryFromGitConfig(repoRoot);
  if (fromGit) {
    return fromGit;
  }
  throw new Error('Repository is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
}

function runGhJson(args) {
  const result = spawnSync('gh', args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES,
  });

  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run gh ${args.join(' ')}: ${message}`);
  }
  const status = result.status ?? 0;
  if (status !== 0) {
    const stderr = normalizeText(result.stderr);
    const stdout = normalizeText(result.stdout);
    const parts = [`gh ${args.join(' ')} failed with exit code ${status}.`];
    if (stderr) parts.push(stderr);
    if (stdout) parts.push(stdout);
    throw new Error(parts.join(' '));
  }
  try {
    return JSON.parse(result.stdout ?? '');
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to parse JSON from gh ${args.join(' ')}: ${message}`);
  }
}

function runProcess(command, args) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES,
  });

  return {
    status: result.status ?? 0,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function writeJsonFile(filePath, payload) {
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function readJsonFile(filePath) {
  const resolved = path.resolve(process.cwd(), filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`JSON file not found: ${resolved}`);
  }
  return JSON.parse(fs.readFileSync(resolved, 'utf8'));
}

function sortStatusesByCreatedAt(statuses) {
  return [...(Array.isArray(statuses) ? statuses : [])].sort((left, right) =>
    new Date(left?.created_at ?? left?.createdAt ?? 0).valueOf() -
    new Date(right?.created_at ?? right?.createdAt ?? 0).valueOf(),
  );
}

function parseRunIdFromUrl(url) {
  const normalized = normalizeText(url);
  if (!normalized) {
    return null;
  }
  const match = normalized.match(/\/actions\/runs\/(?<runId>\d+)/i);
  if (!match?.groups?.runId) {
    return null;
  }
  return normalizeInteger(match.groups.runId);
}

function summarizeDeploymentStatuses(deployment, statuses) {
  const orderedStatuses = sortStatusesByCreatedAt(statuses);
  const states = orderedStatuses.map((entry) => normalizeLower(entry?.state)).filter(Boolean);
  const latest = orderedStatuses.length > 0 ? orderedStatuses[orderedStatuses.length - 1] : null;
  const latestState = normalizeLower(latest?.state);
  const waitedForApproval = states.includes('waiting');
  const actualApproved = waitedForApproval && states.includes('success');
  const runIds = uniqueStrings(
    orderedStatuses
      .map((entry) =>
        normalizeInteger(entry?.runId ?? parseRunIdFromUrl(entry?.log_url ?? entry?.logUrl ?? entry?.target_url)),
      )
      .filter((entry) => entry !== null)
      .map((entry) => String(entry)),
  );

  return {
    latestState,
    waitedForApproval,
    actualApproved,
    statusCount: orderedStatuses.length,
    createdAt: normalizeIso(deployment?.created_at),
    latestStatusAt: normalizeIso(latest?.created_at ?? latest?.createdAt),
    runId: runIds.length > 0 ? normalizeInteger(runIds[runIds.length - 1]) : null,
    runIds,
    statuses: orderedStatuses.map((entry) => ({
      id: normalizeInteger(entry?.id),
      state: normalizeLower(entry?.state),
      createdAt: normalizeIso(entry?.created_at ?? entry?.createdAt),
      updatedAt: normalizeIso(entry?.updated_at ?? entry?.updatedAt),
      logUrl: normalizeText(entry?.log_url ?? entry?.logUrl ?? entry?.target_url),
      runId: normalizeInteger(entry?.runId ?? parseRunIdFromUrl(entry?.log_url ?? entry?.logUrl ?? entry?.target_url)),
    })),
  };
}

function normalizeRunPayload(run) {
  return {
    id: normalizeInteger(run?.id),
    name: normalizeText(run?.name),
    path: normalizeText(run?.path),
    htmlUrl: normalizeText(run?.html_url ?? run?.htmlUrl),
    headBranch: normalizeText(run?.head_branch ?? run?.headBranch),
    headSha: normalizeSha(run?.head_sha ?? run?.headSha),
    event: normalizeText(run?.event),
    status: normalizeLower(run?.status) ?? 'unknown',
    conclusion: normalizeLower(run?.conclusion),
    displayTitle: normalizeText(run?.display_title ?? run?.displayTitle),
    createdAt: normalizeIso(run?.created_at ?? run?.createdAt),
    updatedAt: normalizeIso(run?.updated_at ?? run?.updatedAt),
  };
}

function normalizePullSummary(pull) {
  return {
    number: normalizeInteger(pull?.number),
    url: normalizeText(pull?.html_url ?? pull?.url),
    state: normalizeLower(pull?.state),
    mergedAt: normalizeIso(pull?.merged_at ?? pull?.mergedAt),
    headRefName: normalizeText(pull?.head?.ref ?? pull?.headRefName),
    headRefOid: normalizeSha(pull?.head?.sha ?? pull?.headRefOid),
    baseRefName: normalizeText(pull?.base?.ref ?? pull?.baseRefName),
  };
}

function pickPullRequestForRun(run, pulls) {
  const candidates = (Array.isArray(pulls) ? pulls : []).map(normalizePullSummary);
  if (candidates.length === 0) {
    return null;
  }
  const headShaMatch = candidates.find((entry) => entry.headRefOid && entry.headRefOid === run.headSha);
  if (headShaMatch) {
    return headShaMatch;
  }
  const headRefMatch = candidates.find((entry) => entry.headRefName && entry.headRefName === run.headBranch);
  if (headRefMatch) {
    return headRefMatch;
  }
  return candidates[0];
}

function resolvePullRequestForRun(repository, run, runGhJsonFn) {
  if (!run?.headSha) {
    return null;
  }

  const pullsByCommit = runGhJsonFn([
    'api',
    '-H',
    'Accept: application/vnd.github+json',
    `repos/${repository}/commits/${run.headSha}/pulls`,
  ]);
  const matchedByCommit = pickPullRequestForRun(run, pullsByCommit);
  if (matchedByCommit) {
    return matchedByCommit;
  }

  if (!run.headBranch || run.headBranch.startsWith('gh-readonly-queue/')) {
    return null;
  }

  const pullsByBranch = runGhJsonFn([
    'pr',
    'list',
    '--repo',
    repository,
    '--search',
    `head:${run.headBranch}`,
    '--state',
    'all',
    '--json',
    'number,url,headRefName,headRefOid,state,mergedAt,baseRefName',
  ]);
  return pickPullRequestForRun(run, pullsByBranch);
}

function fetchPullContext(repository, prNumber, runGhJsonFn) {
  return runGhJsonFn([
    'pr',
    'view',
    String(prNumber),
    '--repo',
    repository,
    '--json',
    'number,url,isDraft,headRefOid,headRefName,baseRefName,headRepositoryOwner,isCrossRepository,mergeStateStatus,statusCheckRollup',
  ]);
}

function defaultRunSignalCollector({ repository, prNumber, outPath }) {
  const collectorPath = path.resolve(process.cwd(), SIGNAL_COLLECTOR_PATH);
  if (!fs.existsSync(collectorPath)) {
    throw new Error(
      `Signal collector build output is missing at ${collectorPath}. Run 'node tools/npm/run-script.mjs build' first.`,
    );
  }
  const result = runProcess(process.execPath, [
    collectorPath,
    '--repo',
    repository,
    '--pr',
    String(prNumber),
    '--out',
    outPath,
  ]);
  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run Copilot review signal collector: ${message}`);
  }
  if (result.status !== 0) {
    throw new Error(
      `Copilot review signal collector failed for PR #${prNumber}: ${normalizeText(result.stderr) ?? normalizeText(result.stdout) ?? 'unknown error'}`,
    );
  }
}

function defaultDownloadArtifact({ repository, runId, artifactName, destination }) {
  const downloadResult = downloadNamedArtifacts({
    repository,
    runId: String(runId),
    artifactNames: [artifactName],
    destinationRoot: destination,
    reportPath: null,
  });
  if (downloadResult.report.discovery.status !== 'pass') {
    throw new Error(downloadResult.report.discovery.errorMessage ?? `Failed to discover artifacts for run ${runId}.`);
  }
  const entry = downloadResult.report.downloads[0];
  if (!entry || entry.status !== 'downloaded') {
    throw new Error(entry?.errorMessage ?? `Failed to download artifact ${artifactName} from run ${runId}.`);
  }
  return true;
}

function findFirstJsonFile(directory) {
  if (!fs.existsSync(directory)) {
    return null;
  }
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const nested = findFirstJsonFile(fullPath);
      if (nested) {
        return nested;
      }
      continue;
    }
    if (entry.isFile() && entry.name.toLowerCase().endsWith('.json')) {
      return fullPath;
    }
  }
  return null;
}

function loadDeploymentDeterminismArtifact({
  repository,
  runId,
  deploymentSummary,
  environment,
  sampleDir,
  downloadArtifactFn,
}) {
  const destination = path.join(sampleDir, 'deployment-determinism');
  fs.mkdirSync(destination, { recursive: true });
  try {
    const downloaded = downloadArtifactFn({
      repository,
      runId,
      artifactName: DEPLOYMENT_DETERMINISM_ARTIFACT_NAME,
      destination,
    });
    if (downloaded) {
      const artifactPath = findFirstJsonFile(destination);
      if (artifactPath) {
        return {
          source: 'artifact',
          artifactPath,
          payload: readJsonFile(artifactPath),
        };
      }
    }
  } catch (error) {
    return {
      source: 'fallback',
      artifactPath: writeJsonFile(
        path.join(sampleDir, 'deployment-determinism', 'validation-deployment-determinism.json'),
        {
          schema: 'priority/deployment-determinism@v1',
          generatedAt: new Date().toISOString(),
          repository,
          environment,
          runId: String(runId),
          result: 'error',
          issues: [error instanceof Error ? error.message : String(error)],
          summary: {
            deploymentCount: 1,
            scopedCount: 1,
            runLinkedCount: deploymentSummary.runIds.length,
          },
        },
      ),
      payload: {
        schema: 'priority/deployment-determinism@v1',
        repository,
        environment,
        runId: String(runId),
        result: 'error',
        issues: [error instanceof Error ? error.message : String(error)],
      },
    };
  }

  const fallbackPayload = {
    schema: 'priority/deployment-determinism@v1',
    generatedAt: new Date().toISOString(),
    repository,
    environment,
    runId: String(runId),
    result: 'error',
    issues: ['validate-deployment-determinism-artifact-unavailable'],
    summary: {
      deploymentCount: 1,
      scopedCount: 1,
      runLinkedCount: deploymentSummary.runIds.length,
    },
  };
  return {
    source: 'fallback',
    artifactPath: writeJsonFile(
      path.join(sampleDir, 'deployment-determinism', 'validation-deployment-determinism.json'),
      fallbackPayload,
    ),
    payload: fallbackPayload,
  };
}

function buildReplayAttestation({
  repository,
  pull,
  signalPath,
  signal,
  deploymentDeterminismArtifactPath,
  deploymentDeterminism,
  run,
}) {
  const unresolvedThreadCount = normalizeInteger(signal?.summary?.unresolvedThreadCount) ?? 0;
  const actionableCommentCount = normalizeInteger(signal?.summary?.actionableCommentCount) ?? 0;
  const staleReviewCount = normalizeInteger(signal?.summary?.staleReviewCount) ?? 0;
  const latestReviewId = normalizeText(signal?.latestCopilotReview?.id) ?? 'replay-missing-review';
  const validateRunPassed = normalizeLower(run?.conclusion) === 'success';
  const determinismPassed = normalizeLower(deploymentDeterminism?.result) === 'pass';

  return {
    schema: 'validation-agent-attestation@v1',
    schemaVersion: '1.0.0',
    generatedAt: new Date().toISOString(),
    repository,
    pullRequest: {
      number: normalizeInteger(pull?.number),
      url: normalizeText(pull?.url),
      headSha: normalizeSha(pull?.headRefOid),
    },
    copilotReview: {
      id: latestReviewId,
      url: normalizeText(signal?.latestCopilotReview?.url),
      submittedAt: normalizeIso(signal?.latestCopilotReview?.submittedAt),
      state: normalizeText(signal?.latestCopilotReview?.state),
      isCurrentHead:
        typeof signal?.latestCopilotReview?.isCurrentHead === 'boolean'
          ? signal.latestCopilotReview.isCurrentHead
          : null,
    },
    reviewSignal: {
      artifactPath: signalPath,
      status: normalizeText(signal?.status),
      reviewState: normalizeText(signal?.reviewState),
      unresolvedThreadCount,
      actionableCommentCount,
      staleReviewCount,
    },
    dispositions: {
      // Historical replay is intentionally conservative: if the source review signal
      // still shows actionable material, the broker must block rather than infer
      // dispositions that were not preserved in artifacts.
      threads: [],
      comments: [],
    },
    validationEvidence: {
      summary: `Historical validation replay from workflow run ${run.id ?? 'unknown'}.`,
      commands: [
        {
          command: `gh run view ${run.id ?? 'unknown'} --repo ${repository}`,
          status: validateRunPassed ? 'passed' : 'failed',
          exitCode: null,
          details: `Validate workflow conclusion=${run.conclusion ?? run.status ?? 'unknown'}.`,
          artifactPath: null,
        },
        {
          command: `node tools/npm/run-script.mjs priority:artifact:download -- --repo ${repository} --run-id ${run.id ?? 'unknown'} --artifact ${DEPLOYMENT_DETERMINISM_ARTIFACT_NAME}`,
          status: determinismPassed ? 'passed' : 'failed',
          exitCode: null,
          details: `Deployment determinism result=${normalizeText(deploymentDeterminism?.result) ?? 'unknown'}.`,
          artifactPath: deploymentDeterminismArtifactPath,
        },
      ],
      checks: [
        {
          name: 'validate-run-conclusion',
          status: validateRunPassed ? 'passed' : 'failed',
          details: `Run conclusion=${run.conclusion ?? 'unknown'}`,
        },
        {
          name: 'deployment-determinism',
          status: determinismPassed ? 'passed' : 'failed',
          details: `Determinism result=${normalizeText(deploymentDeterminism?.result) ?? 'unknown'}`,
        },
      ],
      artifacts: uniqueStrings([signalPath, deploymentDeterminismArtifactPath].filter(Boolean)),
      notes: ['historical-replay-derived-attestation'],
    },
    commentPost: {
      requested: false,
      posted: false,
      actorLogin: null,
      postedAt: null,
    },
    source: {
      signalPath,
      dispositionsPath: 'replay:derived-empty-dispositions',
      validationEvidencePath: 'replay:derived-validation-evidence',
    },
  };
}

function compareDecisionToOutcome(actualApproved, brokerReady) {
  if (brokerReady && actualApproved) {
    return 'match-ready';
  }
  if (!brokerReady && !actualApproved) {
    return 'match-not-ready';
  }
  if (brokerReady && !actualApproved) {
    return 'false-ready';
  }
  return 'false-blocked';
}

function appendStepSummary(stepSummaryPath, report) {
  if (!stepSummaryPath) {
    return;
  }
  const lines = [
    '### Validation Approval Proof',
    '',
    `- status: \`${report.status}\``,
    `- strict: \`${report.strict}\``,
    `- repository: \`${report.inputs.repository}\``,
    `- environment: \`${report.inputs.environment}\``,
    `- evaluated_samples: \`${report.summary.samplesEvaluated}\``,
    `- false_ready: \`${report.summary.falseReadyCount}\``,
    `- false_blocked: \`${report.summary.falseBlockedCount}\``,
    `- policy_flip_recommended: \`${report.verdict.policyFlipRecommended}\``,
    '',
    `Summary: ${report.verdict.summary}`,
  ];

  if (report.verdict.reasons.length > 0) {
    lines.push('', 'Reasons:');
    for (const reason of report.verdict.reasons) {
      lines.push(`- ${reason}`);
    }
  }

  const resolved = path.resolve(process.cwd(), stepSummaryPath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${lines.join('\n')}\n`, { encoding: 'utf8', flag: 'a' });
}

export async function runValidationApprovalProof({
  argv = process.argv,
  now = new Date(),
  repoRoot = process.cwd(),
  runGhJsonFn = runGhJson,
  runSignalCollectorFn = defaultRunSignalCollector,
  downloadArtifactFn = defaultDownloadArtifact,
  runBrokerFn = runValidationApprovalBroker,
  writeJsonFn = writeJsonFile,
  appendStepSummaryFn = appendStepSummary,
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  const repository = resolveRepository(options, repoRoot);
  const environment = normalizeLower(options.environment) ?? DEFAULT_ENVIRONMENT;
  const nowIso = now.toISOString();
  const lookbackThreshold = new Date(now.valueOf() - options.lookbackDays * 24 * 60 * 60 * 1000);
  const artifactsRoot = path.resolve(process.cwd(), options.artifactsDir);
  const reportPath = path.resolve(process.cwd(), options.reportPath);
  const policyPath = path.resolve(process.cwd(), options.policyPath);

  const deployments = runGhJsonFn([
    'api',
    `repos/${repository}/deployments?environment=${encodeURIComponent(environment)}&per_page=100`,
  ]);

  const sortedDeployments = [...(Array.isArray(deployments) ? deployments : [])]
    .filter((entry) => {
      const createdAt = normalizeIso(entry?.created_at);
      if (!createdAt) {
        return false;
      }
      return new Date(createdAt).valueOf() >= lookbackThreshold.valueOf();
    })
    .sort((left, right) => new Date(right.created_at).valueOf() - new Date(left.created_at).valueOf());

  const samples = [];
  const skipped = [];
  const errors = [];

  for (const deployment of sortedDeployments) {
    if (samples.length >= options.maxDeployments) {
      break;
    }

    const deploymentId = normalizeInteger(deployment?.id);
    const deploymentSha = normalizeSha(deployment?.sha);
    const statuses = runGhJsonFn([
      'api',
      `repos/${repository}/deployments/${deploymentId}/statuses`,
    ]);
    const deploymentSummary = summarizeDeploymentStatuses(deployment, statuses);
    if (!deploymentSummary.waitedForApproval) {
      skipped.push({
        deploymentId,
        reason: 'deployment-never-entered-waiting-state',
        ref: normalizeText(deployment?.ref),
        sha: deploymentSha,
      });
      continue;
    }
    if (!deploymentSummary.runId) {
      skipped.push({
        deploymentId,
        reason: 'deployment-run-id-unavailable',
        ref: normalizeText(deployment?.ref),
        sha: deploymentSha,
      });
      continue;
    }

    const run = normalizeRunPayload(
      runGhJsonFn(['api', `repos/${repository}/actions/runs/${deploymentSummary.runId}`]),
    );
    const pullSummary = resolvePullRequestForRun(repository, run, runGhJsonFn);
    if (!pullSummary?.number) {
      skipped.push({
        deploymentId,
        runId: run.id,
        reason: 'pull-request-unavailable',
        ref: normalizeText(deployment?.ref),
        sha: deploymentSha,
      });
      continue;
    }

    const sampleDir = path.join(artifactsRoot, String(deploymentId));
    fs.mkdirSync(sampleDir, { recursive: true });

    try {
      const signalPath = path.join(sampleDir, 'copilot-review-signal.json');
      runSignalCollectorFn({
        repository,
        prNumber: pullSummary.number,
        outPath: signalPath,
      });
      const signal = readJsonFile(signalPath);

      const pullPath = writeJsonFn(
        path.join(sampleDir, 'pull-context.json'),
        fetchPullContext(repository, pullSummary.number, runGhJsonFn),
      );
      const deploymentArtifact = loadDeploymentDeterminismArtifact({
        repository,
        runId: deploymentSummary.runId,
        deploymentSummary,
        environment,
        sampleDir,
        downloadArtifactFn,
      });
      const deploymentDeterminism = deploymentArtifact.payload;
      const attestationPath = writeJsonFn(
        path.join(sampleDir, 'validation-agent-attestation.json'),
        buildReplayAttestation({
          repository,
          pull: pullSummary,
          signalPath,
          signal,
          deploymentDeterminismArtifactPath: deploymentArtifact.artifactPath,
          deploymentDeterminism,
          run,
        }),
      );
      const decisionPath = path.join(sampleDir, 'validation-approval-decision.json');
      const eventsPath = path.join(sampleDir, 'validation-approval-events.ndjson');
      const brokerResult = await runBrokerFn({
        argv: [
          'node',
          'validation-approval-broker.mjs',
          '--repo',
          repository,
          '--pr',
          String(pullSummary.number),
          '--policy',
          policyPath,
          '--signal',
          signalPath,
          '--attestation',
          attestationPath,
          '--deployment-determinism',
          deploymentArtifact.artifactPath,
          '--pull-file',
          pullPath,
          '--out',
          decisionPath,
          '--events-out',
          eventsPath,
          '--environment',
          environment,
        ],
        now,
      });
      const comparison = compareDecisionToOutcome(
        deploymentSummary.actualApproved,
        brokerResult.report?.decision?.ready === true,
      );

      samples.push({
        deploymentId,
        runId: run.id,
        runUrl: run.htmlUrl,
        pullRequestNumber: pullSummary.number,
        pullRequestUrl: pullSummary.url,
        ref: normalizeText(deployment?.ref),
        sha: deploymentSha,
        createdAt: deploymentSummary.createdAt,
        latestStatusAt: deploymentSummary.latestStatusAt,
        finalState: deploymentSummary.latestState,
        waitedForApproval: deploymentSummary.waitedForApproval,
        actualDecision: deploymentSummary.actualApproved ? 'approved' : 'not-approved',
        brokerState: normalizeLower(brokerResult.report?.decision?.state) ?? 'error',
        brokerReady: brokerResult.report?.decision?.ready === true,
        comparison,
        reasons: uniqueStrings(brokerResult.report?.decision?.reasons ?? []),
        notes: uniqueStrings(brokerResult.report?.decision?.notes ?? []),
        reviewSignal: {
          status: normalizeText(signal?.status),
          reviewState: normalizeText(signal?.reviewState),
          hasCurrentHeadReview: signal?.signals?.hasCurrentHeadReview === true,
          actionableCommentCount: normalizeInteger(signal?.summary?.actionableCommentCount) ?? 0,
          unresolvedThreadCount: normalizeInteger(signal?.summary?.unresolvedThreadCount) ?? 0,
          staleReviewCount: normalizeInteger(signal?.summary?.staleReviewCount) ?? 0,
        },
        deploymentDeterminism: {
          source: deploymentArtifact.source,
          result: normalizeText(deploymentDeterminism?.result),
          issueCount: Array.isArray(deploymentDeterminism?.issues) ? deploymentDeterminism.issues.length : 0,
          artifactPath: deploymentArtifact.artifactPath,
        },
        artifacts: {
          sampleDir,
          signalPath,
          pullPath,
          attestationPath,
          decisionPath: path.resolve(process.cwd(), decisionPath),
          eventsPath: path.resolve(process.cwd(), eventsPath),
          deploymentDeterminismPath: deploymentArtifact.artifactPath,
        },
      });
    } catch (error) {
      errors.push({
        deploymentId,
        runId: run.id,
        pullRequestNumber: pullSummary.number,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const falseReadyCount = samples.filter((entry) => entry.comparison === 'false-ready').length;
  const falseBlockedCount = samples.filter((entry) => entry.comparison === 'false-blocked').length;
  const readyCount = samples.filter((entry) => entry.brokerReady).length;
  const approvedCount = samples.filter((entry) => entry.actualDecision === 'approved').length;
  const passing = falseReadyCount === 0 && samples.length >= options.minSamples && errors.length === 0;
  const verdictReasons = [];
  if (samples.length < options.minSamples) {
    verdictReasons.push('insufficient-samples');
  }
  if (falseReadyCount > 0) {
    verdictReasons.push('false-ready-observed');
  }
  if (errors.length > 0) {
    verdictReasons.push('sample-errors-present');
  }
  if (verdictReasons.length === 0) {
    verdictReasons.push('zero-false-ready-window');
  }

  const evaluatedTimes = samples
    .flatMap((entry) => [entry.createdAt, entry.latestStatusAt])
    .filter(Boolean)
    .sort((left, right) => new Date(left).valueOf() - new Date(right).valueOf());

  const report = {
    schema: REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: nowIso,
    status: passing ? 'pass' : options.strict ? 'fail' : 'warn',
    strict: options.strict,
    inputs: {
      repository,
      environment,
      policyPath,
      maxDeployments: options.maxDeployments,
      minSamples: options.minSamples,
      lookbackDays: options.lookbackDays,
      artifactsDir: artifactsRoot,
      reportPath,
    },
    proofWindow: {
      startedAt: evaluatedTimes.length > 0 ? evaluatedTimes[0] : null,
      endedAt: evaluatedTimes.length > 0 ? evaluatedTimes[evaluatedTimes.length - 1] : null,
    },
    summary: {
      deploymentsFetched: sortedDeployments.length,
      samplesEvaluated: samples.length,
      skippedCount: skipped.length,
      errorCount: errors.length,
      readyCount,
      approvedCount,
      falseReadyCount,
      falseBlockedCount,
    },
    verdict: {
      policyFlipRecommended: passing,
      reasons: verdictReasons,
      summary: passing
        ? 'Replay window observed zero false-ready outcomes; validation can graduate out of shadow mode.'
        : `Replay window did not satisfy apply-mode proof: ${verdictReasons.join(', ')}`,
    },
    samples,
    skipped,
    errors,
  };

  const persistedReportPath = writeJsonFn(reportPath, report);
  appendStepSummaryFn(options.stepSummaryPath, report);
  return {
    exitCode: report.status === 'fail' ? 1 : 0,
    report,
    reportPath: persistedReportPath,
  };
}

export async function main(argv = process.argv) {
  try {
    const result = await runValidationApprovalProof({ argv });
    if (result.report) {
      console.log(`[validation-approval-proof] report: ${result.reportPath}`);
      console.log(
        `[validation-approval-proof] status=${result.report.status} samples=${result.report.summary.samplesEvaluated} falseReady=${result.report.summary.falseReadyCount} falseBlocked=${result.report.summary.falseBlockedCount}`,
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

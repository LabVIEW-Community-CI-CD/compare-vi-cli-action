#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'deployments',
  'validation-deployment-determinism.json'
);

const ACTIVE_DEPLOYMENT_STATES = new Set(['queued', 'pending', 'in_progress', 'success']);

function printUsage() {
  console.log('Usage: node tools/priority/assert-validation-deployment-determinism.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>       Target repository (default: GITHUB_REPOSITORY).');
  console.log('  --environment <name>      Deployment environment (default: validation).');
  console.log('  --run-id <id>             Workflow run id (default: GITHUB_RUN_ID).');
  console.log('  --sha <sha>               Optional SHA filter (default: unset).');
  console.log(`  --report <path>           Report JSON path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --max-deployments <n>     Number of deployments to scan (default: 30).');
  console.log('  --max-statuses <n>        Number of statuses to scan per deployment (default: 20).');
  console.log('  --retry-attempts <n>      Poll attempts before failing (default: 6).');
  console.log('  --retry-delay-ms <n>      Delay between retries in milliseconds (default: 5000).');
  console.log('  -h, --help                Show usage.');
}

function parsePositiveInteger(value, { label }) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`Invalid ${label} value '${value}'.`);
  }
  return parsed;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: process.env.GITHUB_REPOSITORY ?? '',
    environment: 'validation',
    runId: process.env.GITHUB_RUN_ID ?? '',
    sha: '',
    reportPath: DEFAULT_REPORT_PATH,
    maxDeployments: 30,
    maxStatuses: 20,
    retryAttempts: 6,
    retryDelayMs: 5000
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--help' || arg === '-h') {
      printUsage();
      process.exit(0);
    }

    if (
      arg === '--repo' ||
      arg === '--environment' ||
      arg === '--run-id' ||
      arg === '--sha' ||
      arg === '--report' ||
      arg === '--max-deployments' ||
      arg === '--max-statuses' ||
      arg === '--retry-attempts' ||
      arg === '--retry-delay-ms'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;

      if (arg === '--repo') {
        options.repo = String(next).trim();
      } else if (arg === '--environment') {
        options.environment = String(next).trim();
      } else if (arg === '--run-id') {
        options.runId = String(next).trim();
      } else if (arg === '--sha') {
        options.sha = String(next).trim();
      } else if (arg === '--report') {
        options.reportPath = next;
      } else if (arg === '--max-deployments') {
        options.maxDeployments = parsePositiveInteger(next, { label: '--max-deployments' });
      } else if (arg === '--max-statuses') {
        options.maxStatuses = parsePositiveInteger(next, { label: '--max-statuses' });
      } else if (arg === '--retry-attempts') {
        options.retryAttempts = parsePositiveInteger(next, { label: '--retry-attempts' });
      } else if (arg === '--retry-delay-ms') {
        options.retryDelayMs = parsePositiveInteger(next, { label: '--retry-delay-ms' });
      }
      continue;
    }

    throw new Error(`Unknown option: ${arg}`);
  }

  if (!options.repo || !options.repo.includes('/')) {
    throw new Error('Repository is required (owner/repo). Pass --repo or set GITHUB_REPOSITORY.');
  }
  if (!options.environment) {
    throw new Error('Environment is required. Pass --environment.');
  }
  if (!options.runId) {
    throw new Error('Run id is required. Pass --run-id or set GITHUB_RUN_ID.');
  }

  return options;
}

function normalizeIso(value) {
  if (!value) {
    return null;
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) {
    return null;
  }
  return parsed.toISOString();
}

function normalizeSha(value) {
  return String(value ?? '').trim().toLowerCase();
}

function statusSortDescending(left, right) {
  const leftTime = Date.parse(left?.created_at ?? left?.createdAt ?? 0) || 0;
  const rightTime = Date.parse(right?.created_at ?? right?.createdAt ?? 0) || 0;
  if (leftTime !== rightTime) {
    return rightTime - leftTime;
  }
  return (Number(right?.id) || 0) - (Number(left?.id) || 0);
}

function deploymentSortDescending(left, right) {
  const leftTime = Date.parse(left?.createdAt ?? 0) || 0;
  const rightTime = Date.parse(right?.createdAt ?? 0) || 0;
  if (leftTime !== rightTime) {
    return rightTime - leftTime;
  }
  return (Number(right?.id) || 0) - (Number(left?.id) || 0);
}

export function parseRunIdFromUrl(url) {
  if (!url || typeof url !== 'string') {
    return null;
  }
  const match = url.match(/\/actions\/runs\/(?<runId>\d+)/i);
  if (!match?.groups?.runId) {
    return null;
  }
  return match.groups.runId;
}

export function buildDeploymentEntries(deployments = [], statusesByDeployment = {}) {
  const entries = [];
  for (const deployment of deployments) {
    const id = Number(deployment?.id);
    if (!Number.isInteger(id) || id <= 0) {
      continue;
    }
    const statusesRaw = statusesByDeployment[id] ?? [];
    const statuses = [...statusesRaw]
      .sort(statusSortDescending)
      .map((status) => {
        const state = String(status?.state ?? '').toLowerCase();
        const logUrl = status?.log_url ?? status?.target_url ?? '';
        const runId = parseRunIdFromUrl(logUrl);
        return {
          id: Number(status?.id) || null,
          state,
          createdAt: normalizeIso(status?.created_at ?? status?.createdAt),
          updatedAt: normalizeIso(status?.updated_at ?? status?.updatedAt),
          logUrl,
          runId
        };
      });

    const runIds = [...new Set(statuses.map((status) => status.runId).filter(Boolean))].sort();
    const latest = statuses[0] ?? null;
    entries.push({
      id,
      sha: normalizeSha(deployment?.sha),
      ref: deployment?.ref ?? null,
      createdAt: normalizeIso(deployment?.created_at ?? deployment?.createdAt),
      updatedAt: normalizeIso(deployment?.updated_at ?? deployment?.updatedAt),
      latestState: latest?.state ?? null,
      latestStatusAt: latest?.createdAt ?? null,
      latestRunId: latest?.runId ?? null,
      runIds,
      statusCount: statuses.length,
      statuses
    });
  }

  entries.sort(deploymentSortDescending);
  return entries;
}

export function evaluateDeploymentDeterminism(entries = [], { runId, sha = '' } = {}) {
  const targetRunId = String(runId ?? '').trim();
  const targetSha = normalizeSha(sha);
  const scopedEntries = targetSha ? entries.filter((entry) => entry.sha === targetSha) : [...entries];
  const issues = [];

  const entryOwnedByRun = (entry) =>
    Boolean(entry && (entry.latestRunId === targetRunId || entry.runIds.includes(targetRunId)));
  const hasRunOwnedActiveStatus = (entry) =>
    Boolean(
      entry?.statuses?.some(
        (status) => status.runId === targetRunId && ACTIVE_DEPLOYMENT_STATES.has(String(status.state ?? '').toLowerCase())
      )
    );

  if (scopedEntries.length === 0) {
    issues.push(targetSha ? `no-deployments-for-sha:${targetSha}` : 'no-deployments-found');
  }

  const runEntries = scopedEntries.filter(
    (entry) => entry.latestRunId === targetRunId || entry.runIds.includes(targetRunId)
  );
  if (runEntries.length === 0) {
    issues.push(`no-deployment-linked-to-run:${targetRunId}`);
  }

  const latestRunEntry = [...runEntries].sort(deploymentSortDescending)[0] ?? null;
  const latestScoped = [...scopedEntries].sort(deploymentSortDescending)[0] ?? null;
  if (latestScoped && !entryOwnedByRun(latestScoped)) {
    issues.push(`latest-deployment-owned-by-other-run:${latestScoped.latestRunId ?? 'unknown'}:deployment:${latestScoped.id}`);
  }

  const latestRunState = String(latestRunEntry?.latestState ?? '').toLowerCase();
  const latestRunHasOwnedActiveStatus = hasRunOwnedActiveStatus(latestRunEntry);
  const latestRunTerminalInactive = latestRunState === 'inactive' && latestRunHasOwnedActiveStatus;
  if (latestRunEntry && !ACTIVE_DEPLOYMENT_STATES.has(latestRunState) && !latestRunTerminalInactive) {
    issues.push(
      `current-run-latest-state-not-active:${latestRunEntry.latestState ?? 'unknown'}:deployment:${latestRunEntry.id}`
    );
  }

  const activeEntries = scopedEntries.filter((entry) =>
    ACTIVE_DEPLOYMENT_STATES.has(String(entry.latestState ?? '').toLowerCase())
  );
  const latestActive = [...activeEntries].sort(deploymentSortDescending)[0] ?? null;
  if (!latestActive) {
    if (!latestRunTerminalInactive) {
      issues.push('no-active-deployment-found');
    }
  } else if (!entryOwnedByRun(latestActive)) {
    issues.push(`latest-active-owned-by-other-run:${latestActive.latestRunId ?? 'unknown'}:deployment:${latestActive.id}`);
  }

  return {
    ok: issues.length === 0,
    issues,
    scopedCount: scopedEntries.length,
    runLinkedCount: runEntries.length,
    latestScoped,
    latestRunEntry,
    latestActive
  };
}

function runGhJson(args, { cwd = process.cwd() } = {}) {
  const result = spawnSync('gh', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    throw new Error(`gh ${args.join(' ')} failed: ${(result.stderr || result.stdout || '').trim()}`);
  }
  const output = (result.stdout || '').trim();
  if (!output) {
    return null;
  }
  return JSON.parse(output);
}

function shouldRetryEvaluation(evaluation) {
  if (!evaluation || evaluation.ok) {
    return false;
  }
  return evaluation.issues.some((issue) =>
    issue === 'no-deployments-found' ||
    issue === 'no-active-deployment-found' ||
    issue.startsWith('no-deployments-for-sha:') ||
    issue.startsWith('no-deployment-linked-to-run:') ||
    issue.startsWith('latest-deployment-owned-by-other-run:') ||
    issue.startsWith('latest-active-owned-by-other-run:') ||
    issue.startsWith('current-run-latest-state-not-active:')
  );
}

function sleep(delayMs) {
  return new Promise((resolve) => setTimeout(resolve, delayMs));
}

function collectDeterminismState({ options, cwd, runGhJsonFn }) {
  const deployments = runGhJsonFn(
    [
      'api',
      `repos/${options.repo}/deployments?environment=${encodeURIComponent(options.environment)}&per_page=${options.maxDeployments}`
    ],
    { cwd }
  );

  const statusesByDeployment = {};
  for (const deployment of deployments ?? []) {
    const deploymentId = Number(deployment?.id);
    if (!Number.isInteger(deploymentId) || deploymentId <= 0) {
      continue;
    }
    const statuses = runGhJsonFn(
      ['api', `repos/${options.repo}/deployments/${deploymentId}/statuses?per_page=${options.maxStatuses}`],
      { cwd }
    );
    statusesByDeployment[deploymentId] = Array.isArray(statuses) ? statuses : [];
  }

  const entries = buildDeploymentEntries(deployments ?? [], statusesByDeployment);
  const evaluation = evaluateDeploymentDeterminism(entries, {
    runId: options.runId,
    sha: options.sha
  });
  return { entries, evaluation };
}

async function writeReport(reportPath, report) {
  const resolved = path.resolve(reportPath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runAssertValidationDeploymentDeterminism({
  argv = process.argv,
  cwd = process.cwd(),
  runGhJsonFn = runGhJson
} = {}) {
  const options = parseArgs(argv);
  let entries = [];
  let evaluation = {
    ok: false,
    issues: ['not-evaluated'],
    scopedCount: 0,
    runLinkedCount: 0,
    latestScoped: null,
    latestRunEntry: null,
    latestActive: null
  };
  const attempts = [];
  for (let attempt = 1; attempt <= options.retryAttempts; attempt += 1) {
    const state = collectDeterminismState({ options, cwd, runGhJsonFn });
    entries = state.entries;
    evaluation = state.evaluation;
    attempts.push({
      attempt,
      evaluatedAt: new Date().toISOString(),
      ok: evaluation.ok,
      issues: [...evaluation.issues],
      deploymentCount: entries.length,
      scopedCount: evaluation.scopedCount,
      runLinkedCount: evaluation.runLinkedCount,
      latestScopedDeploymentId: evaluation.latestScoped?.id ?? null,
      latestRunDeploymentId: evaluation.latestRunEntry?.id ?? null,
      latestActiveDeploymentId: evaluation.latestActive?.id ?? null
    });
    if (evaluation.ok) {
      break;
    }
    if (attempt < options.retryAttempts && shouldRetryEvaluation(evaluation)) {
      await sleep(options.retryDelayMs);
      continue;
    }
    break;
  }

  const report = {
    schema: 'priority/deployment-determinism@v1',
    generatedAt: new Date().toISOString(),
    repository: options.repo,
    environment: options.environment,
    runId: options.runId,
    sha: options.sha || null,
    result: evaluation.ok ? 'pass' : 'fail',
    summary: {
      deploymentCount: entries.length,
      scopedCount: evaluation.scopedCount,
      runLinkedCount: evaluation.runLinkedCount,
      attempts: attempts.length,
      latestScopedDeploymentId: evaluation.latestScoped?.id ?? null,
      latestRunDeploymentId: evaluation.latestRunEntry?.id ?? null,
      latestActiveDeploymentId: evaluation.latestActive?.id ?? null
    },
    attempts,
    issues: evaluation.issues,
    latestScoped: evaluation.latestScoped,
    latestRunEntry: evaluation.latestRunEntry,
    latestActive: evaluation.latestActive
  };

  const resolvedReportPath = await writeReport(options.reportPath, report);
  console.log(`[deployment-determinism] report: ${resolvedReportPath}`);
  if (!evaluation.ok) {
    throw new Error(
      `Deployment determinism assertion failed (${options.environment}, run ${options.runId}): ${evaluation.issues.join(
        ', '
      )}`
    );
  }
  console.log(
    `[deployment-determinism] PASS environment=${options.environment} run=${options.runId} sha=${options.sha || '(any)'}`
  );
  return { report, reportPath: resolvedReportPath };
}

const directExecution = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (directExecution) {
  runAssertValidationDeploymentDeterminism().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

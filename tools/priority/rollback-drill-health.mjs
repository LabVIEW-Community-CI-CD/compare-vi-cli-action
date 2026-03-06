#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ensureGhCli, resolveUpstream } from './lib/remote-utils.mjs';
import {
  DEFAULT_RELEASE_ROLLBACK_POLICY_PATH,
  loadReleaseRollbackPolicy
} from './lib/release-rollback-policy.mjs';

export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'rollback-drill-health.json'
);

const USAGE_LINES = [
  'Usage: node tools/priority/rollback-drill-health.mjs [options]',
  '',
  'Evaluate rollback drill workflow health and hard-fail when promotion should pause.',
  '',
  'Options:',
  '  --repo <owner/repo>              Repository slug (default: upstream/GITHUB_REPOSITORY).',
  `  --policy <path>                  Rollback policy path (default: ${DEFAULT_RELEASE_ROLLBACK_POLICY_PATH}).`,
  `  --report <path>                  Report path (default: ${DEFAULT_REPORT_PATH}).`,
  '  --workflow <file|id>             Workflow file/id override.',
  '  --branch <name>                  Branch filter override.',
  '  --lookback-runs <n>              Lookback runs override.',
  '  --min-success-rate <0-1>         Minimum success rate override.',
  '  --max-hours-since-success <n>    Max hours since latest successful drill.',
  '  -h, --help                       Show this message and exit.'
];

function printUsage() {
  for (const line of USAGE_LINES) {
    console.log(line);
  }
}

function truncate(text, maxLength = 800) {
  const raw = String(text || '').trim();
  if (raw.length <= maxLength) {
    return raw;
  }
  return `${raw.slice(0, maxLength)}...`;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    policyPath: DEFAULT_RELEASE_ROLLBACK_POLICY_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    workflow: null,
    branch: null,
    lookbackRuns: null,
    minSuccessRate: null,
    maxHoursSinceSuccess: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (
      token === '--repo' ||
      token === '--policy' ||
      token === '--report' ||
      token === '--workflow' ||
      token === '--branch' ||
      token === '--lookback-runs' ||
      token === '--min-success-rate' ||
      token === '--max-hours-since-success'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = String(next).trim();
      if (token === '--policy') options.policyPath = String(next).trim();
      if (token === '--report') options.reportPath = String(next).trim();
      if (token === '--workflow') options.workflow = String(next).trim();
      if (token === '--branch') options.branch = String(next).trim();
      if (token === '--lookback-runs') {
        const parsed = Number.parseInt(String(next), 10);
        if (!Number.isFinite(parsed) || parsed < 1) {
          throw new Error(`Invalid value for --lookback-runs: ${next}`);
        }
        options.lookbackRuns = parsed;
      }
      if (token === '--min-success-rate') {
        const parsed = Number(String(next));
        if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
          throw new Error(`Invalid value for --min-success-rate: ${next}`);
        }
        options.minSuccessRate = parsed;
      }
      if (token === '--max-hours-since-success') {
        const parsed = Number.parseInt(String(next), 10);
        if (!Number.isFinite(parsed) || parsed < 1) {
          throw new Error(`Invalid value for --max-hours-since-success: ${next}`);
        }
        options.maxHoursSinceSuccess = parsed;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function resolveRepositorySlug(explicitRepo, repoRoot = process.cwd()) {
  if (explicitRepo && explicitRepo.includes('/')) {
    return explicitRepo;
  }
  const envRepo = String(process.env.GITHUB_REPOSITORY || '').trim();
  if (envRepo && envRepo.includes('/')) {
    return envRepo;
  }
  const upstream = resolveUpstream(repoRoot);
  return `${upstream.owner}/${upstream.repo}`;
}

function runGhApiJson(repoRoot, args) {
  const result = spawnSync('gh', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const detail = truncate(result.stderr || result.stdout || '');
    throw new Error(`gh ${args.join(' ')} failed: ${detail || `exit-${result.status}`}`);
  }
  try {
    return JSON.parse(result.stdout || 'null');
  } catch (error) {
    throw new Error(`Failed to parse gh JSON output: ${error.message}`);
  }
}

function normalizeRunRecord(raw) {
  const source = raw && typeof raw === 'object' ? raw : {};
  return {
    id: source.id ?? null,
    runNumber: source.run_number ?? source.runNumber ?? null,
    status: source.status ?? null,
    conclusion: source.conclusion ?? null,
    event: source.event ?? null,
    createdAt: source.created_at ?? source.createdAt ?? null,
    updatedAt: source.updated_at ?? source.updatedAt ?? null,
    url: source.html_url ?? source.url ?? null
  };
}

function hoursBetween(now, then) {
  if (!then) {
    return null;
  }
  const thenMs = Date.parse(then);
  if (!Number.isFinite(thenMs)) {
    return null;
  }
  return (now.getTime() - thenMs) / (1000 * 60 * 60);
}

export function evaluateDrillHealth(runs, thresholds, now = new Date()) {
  const normalized = (Array.isArray(runs) ? runs : [])
    .map((entry) => normalizeRunRecord(entry))
    .sort((left, right) => {
      const leftMs = left.createdAt ? Date.parse(left.createdAt) : 0;
      const rightMs = right.createdAt ? Date.parse(right.createdAt) : 0;
      return rightMs - leftMs;
    });

  const totalRuns = normalized.length;
  const successful = normalized.filter((run) => run.conclusion === 'success');
  const successCount = successful.length;
  const successRate = totalRuns === 0 ? 0 : successCount / totalRuns;
  const latestSuccess = successful[0] || null;
  const hoursSinceLatestSuccess = latestSuccess ? hoursBetween(now, latestSuccess.createdAt) : null;

  const failures = [];
  if (totalRuns === 0) {
    failures.push({
      code: 'missing-drill-history',
      message: 'No completed rollback drill runs found in configured lookback window.'
    });
  }
  if (successRate < thresholds.minimumSuccessRate) {
    failures.push({
      code: 'success-rate-below-threshold',
      message: `Success rate ${successRate.toFixed(2)} is below threshold ${thresholds.minimumSuccessRate.toFixed(2)}.`
    });
  }
  if (hoursSinceLatestSuccess == null || hoursSinceLatestSuccess > thresholds.maxHoursSinceSuccess) {
    failures.push({
      code: 'latest-success-stale',
      message:
        hoursSinceLatestSuccess == null
          ? 'No successful rollback drill run was found.'
          : `Latest successful drill age ${hoursSinceLatestSuccess.toFixed(2)}h exceeds threshold ${thresholds.maxHoursSinceSuccess}h.`
    });
  }

  const status = failures.length === 0 ? 'pass' : 'fail';
  return {
    status,
    failures,
    summary: {
      totalRuns,
      successCount,
      successRate,
      latestSuccessId: latestSuccess?.id ?? null,
      latestSuccessCreatedAt: latestSuccess?.createdAt ?? null,
      hoursSinceLatestSuccess
    },
    runs: normalized
  };
}

function writeJsonReport(reportPath, report) {
  const resolved = path.resolve(reportPath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

function appendStepSummary(report, reportPath) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (!summaryPath) {
    return;
  }
  const lines = [
    '### Rollback Drill Health',
    `- Status: \`${report.summary.status}\``,
    `- Pause promotion: \`${report.summary.pausePromotion}\``,
    `- Success rate: \`${report.summary.successRate.toFixed(2)}\` (threshold \`${report.thresholds.minimumSuccessRate.toFixed(2)}\`)`,
    `- Latest success age (h): \`${report.summary.hoursSinceLatestSuccess == null ? 'n/a' : report.summary.hoursSinceLatestSuccess.toFixed(2)}\``,
    `- Max success age (h): \`${report.thresholds.maxHoursSinceSuccess}\``,
    `- Report: \`${reportPath}\``
  ];
  if (report.failures.length > 0) {
    lines.push('', '| Code | Message |', '| --- | --- |');
    for (const failure of report.failures) {
      lines.push(`| \`${failure.code}\` | ${failure.message.replace(/\|/g, '\\|')} |`);
    }
  }
  fs.appendFileSync(summaryPath, `${lines.join('\n')}\n`, 'utf8');
}

export async function runDrillHealth(options, dependencies = {}) {
  const repoRoot = dependencies.repoRoot || process.cwd();
  const policy = dependencies.policy || loadReleaseRollbackPolicy(options.policyPath);
  const repository = resolveRepositorySlug(options.repo, repoRoot);
  const workflow = options.workflow || policy.drill.workflow;
  const branch = options.branch || policy.drill.branch;
  const lookbackRuns = options.lookbackRuns ?? policy.drill.lookbackRuns;
  const minimumSuccessRate = options.minSuccessRate ?? policy.drill.minimumSuccessRate;
  const maxHoursSinceSuccess = options.maxHoursSinceSuccess ?? policy.drill.maxHoursSinceSuccess;
  const now = dependencies.now instanceof Date ? dependencies.now : new Date();

  const query = `repos/${repository}/actions/workflows/${encodeURIComponent(workflow)}/runs?status=completed&branch=${encodeURIComponent(branch)}&per_page=${lookbackRuns}`;
  const fetcher =
    dependencies.fetchWorkflowRuns ||
    (() => runGhApiJson(repoRoot, ['api', '-H', 'Accept: application/vnd.github+json', query]));
  const preFailures = [];
  let runs = [];
  try {
    const payload = fetcher();
    runs = Array.isArray(payload?.workflow_runs) ? payload.workflow_runs : [];
  } catch (error) {
    preFailures.push({
      code: 'workflow-query-failed',
      message: error?.message || String(error)
    });
  }

  const evaluation = evaluateDrillHealth(runs, { minimumSuccessRate, maxHoursSinceSuccess }, now);
  const combinedFailures = [...preFailures, ...evaluation.failures];
  const status = combinedFailures.length === 0 ? 'pass' : 'fail';

  return {
    schema: 'release/rollback-drill-health@v1',
    generatedAt: now.toISOString(),
    repository,
    workflow,
    branch,
    thresholds: {
      lookbackRuns,
      minimumSuccessRate,
      maxHoursSinceSuccess
    },
    summary: {
      status,
      pausePromotion: status !== 'pass',
      totalRuns: evaluation.summary.totalRuns,
      successCount: evaluation.summary.successCount,
      successRate: evaluation.summary.successRate,
      latestSuccessId: evaluation.summary.latestSuccessId,
      latestSuccessCreatedAt: evaluation.summary.latestSuccessCreatedAt,
      hoursSinceLatestSuccess: evaluation.summary.hoursSinceLatestSuccess
    },
    failures: combinedFailures,
    runs: evaluation.runs
  };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  ensureGhCli();
  const report = await runDrillHealth(options);
  const outputPath = writeJsonReport(options.reportPath, report);
  appendStepSummary(report, options.reportPath);
  console.log(
    `[rollback-drill-health] wrote ${outputPath} (status=${report.summary.status}, pause=${report.summary.pausePromotion})`
  );
  return report.summary.status === 'pass' ? 0 : 1;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) {
        process.exitCode = code;
      }
    })
    .catch((error) => {
      const message = error?.stack || error?.message || String(error);
      let reportPath = DEFAULT_REPORT_PATH;
      try {
        const parsed = parseArgs(process.argv);
        reportPath = parsed.reportPath || reportPath;
      } catch {
        // ignore parse fallback
      }
      const fallback = {
        schema: 'release/rollback-drill-health@v1',
        generatedAt: new Date().toISOString(),
        failures: [{ code: 'execution-error', message }],
        summary: {
          status: 'fail',
          pausePromotion: true,
          totalRuns: 0,
          successCount: 0,
          successRate: 0,
          latestSuccessId: null,
          latestSuccessCreatedAt: null,
          hoursSinceLatestSuccess: null
        }
      };
      try {
        writeJsonReport(reportPath, fallback);
      } catch {
        // ignore write fallback errors
      }
      console.error(message);
      process.exitCode = 1;
    });
}

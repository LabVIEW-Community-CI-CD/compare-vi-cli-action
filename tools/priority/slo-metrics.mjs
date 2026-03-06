#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_WORKFLOWS = [
  'release.yml',
  'publish-tools-image.yml',
  'publish-shared-package.yml',
  'monthly-stability-release.yml',
  'promotion-contract.yml'
];

export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'slo', 'slo-metrics.json');

function printUsage() {
  console.log('Usage: node tools/priority/slo-metrics.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>                Target repository (default: env/remotes).');
  console.log('  --workflow <id>                    Workflow file/id to include (repeatable).');
  console.log(`  --output <path>                    Output JSON path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --lookback-days <n>                Lookback window in days (default: 45).');
  console.log('  --max-runs <n>                     Max completed runs fetched per workflow (default: 100).');
  console.log('  --threshold-failure-rate <0..1>    Failure-rate breach threshold (default: 0.3).');
  console.log('  --threshold-skip-rate <0..1>       Skip-rate breach threshold (default: 1).');
  console.log('  --threshold-mttr-hours <n>         MTTR breach threshold in hours (default: 24).');
  console.log('  --threshold-stale-hours <n>        Stale-budget breach threshold in hours (default: 1080).');
  console.log('  --threshold-gate-regressions <n>   Gate-regression breach threshold (default: 3).');
  console.log('  --route-on-breach                  Create/update SLO breach issue when breached.');
  console.log('  --route-labels <a,b,c>             Labels for routed issue (default: slo,ci,governance).');
  console.log('  --route-title-prefix <text>        Routed issue title prefix (default: [SLO] Breach detected).');
  console.log('  -h, --help                         Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    workflows: [],
    outputPath: DEFAULT_OUTPUT_PATH,
    lookbackDays: 45,
    maxRuns: 100,
    thresholdFailureRate: 0.3,
    thresholdSkipRate: 1,
    thresholdMttrHours: 24,
    thresholdStaleHours: 1080,
    thresholdGateRegressions: 3,
    routeOnBreach: false,
    routeLabels: ['slo', 'ci', 'governance'],
    routeTitlePrefix: '[SLO] Breach detected',
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (token === '--route-on-breach') {
      options.routeOnBreach = true;
      continue;
    }

    if (token === '--repo' || token === '--workflow' || token === '--output' || token === '--route-title-prefix') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') {
        options.repo = next;
      } else if (token === '--workflow') {
        options.workflows.push(next);
      } else if (token === '--output') {
        options.outputPath = next;
      } else {
        options.routeTitlePrefix = next;
      }
      continue;
    }

    if (
      token === '--lookback-days' ||
      token === '--max-runs' ||
      token === '--threshold-mttr-hours' ||
      token === '--threshold-stale-hours' ||
      token === '--threshold-gate-regressions'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      const parsed = Number.parseInt(next, 10);
      if (!Number.isFinite(parsed) || parsed < 0) {
        throw new Error(`Invalid value for ${token}: ${next}`);
      }
      if (token === '--lookback-days') options.lookbackDays = parsed;
      if (token === '--max-runs') options.maxRuns = parsed;
      if (token === '--threshold-mttr-hours') options.thresholdMttrHours = parsed;
      if (token === '--threshold-stale-hours') options.thresholdStaleHours = parsed;
      if (token === '--threshold-gate-regressions') options.thresholdGateRegressions = parsed;
      continue;
    }

    if (token === '--threshold-failure-rate' || token === '--threshold-skip-rate') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      const parsed = Number.parseFloat(next);
      if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
        throw new Error(`Invalid value for ${token}: ${next}`);
      }
      if (token === '--threshold-failure-rate') {
        options.thresholdFailureRate = parsed;
      } else {
        options.thresholdSkipRate = parsed;
      }
      continue;
    }

    if (token === '--route-labels') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      options.routeLabels = next
        .split(',')
        .map((entry) => entry.trim())
        .filter(Boolean);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.workflows.length === 0) {
    options.workflows = [...DEFAULT_WORKFLOWS];
  }
  return options;
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = url.match(/:(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const httpsMatch = url.match(/github\.com\/(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, rawRepo] = repoPath.split('/');
  if (!owner || !rawRepo) return null;
  const repo = rawRepo.endsWith('.git') ? rawRepo.slice(0, -4) : rawRepo;
  return `${owner}/${repo}`;
}

function resolveRepositorySlug(explicitRepo) {
  if (explicitRepo) return explicitRepo;
  const envRepo = process.env.GITHUB_REPOSITORY?.trim();
  if (envRepo && envRepo.includes('/')) return envRepo;
  for (const remoteName of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remoteName}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString()
        .trim();
      const parsed = parseRemoteUrl(raw);
      if (parsed) return parsed;
    } catch {
      // ignore missing remote
    }
  }
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

function resolveToken() {
  for (const value of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    if (value && value.trim()) {
      return value.trim();
    }
  }

  for (const candidate of [process.env.GH_TOKEN_FILE, process.platform === 'win32' ? 'C:\\github_token.txt' : null]) {
    if (!candidate) continue;
    if (!fs.existsSync(candidate)) continue;
    const value = fs.readFileSync(candidate, 'utf8').trim();
    if (value) return value;
  }

  throw new Error('GitHub token not found. Set GH_TOKEN/GITHUB_TOKEN (or GH_TOKEN_FILE).');
}

async function requestJson(url, token, method = 'GET', body = null) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'priority-slo-metrics',
      'X-GitHub-Api-Version': '2022-11-28'
    },
    body: body ? JSON.stringify(body) : undefined
  });

  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(`GitHub API ${method} ${url} failed (${response.status}): ${text}`);
  }
  return payload;
}

function classifyConclusion(conclusion) {
  if (conclusion === 'success') return 'success';
  if (conclusion === 'neutral' || conclusion === 'skipped') return 'skipped';
  if (!conclusion) return 'ignored';
  return 'failure';
}

function percentile(values, p) {
  if (!Array.isArray(values) || values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.max(0, Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p)));
  return sorted[idx];
}

function average(values) {
  if (!Array.isArray(values) || values.length === 0) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

export function summarizeWorkflowRuns(runs, now = new Date()) {
  const normalized = (runs || [])
    .map((run) => {
      const createdMs = Date.parse(run.created_at || run.createdAt || '');
      const updatedMs = Date.parse(run.updated_at || run.updatedAt || run.created_at || '');
      const outcome = classifyConclusion(run.conclusion || null);
      const durationSeconds =
        Number.isFinite(createdMs) && Number.isFinite(updatedMs) && updatedMs >= createdMs
          ? (updatedMs - createdMs) / 1000
          : null;
      return {
        createdMs,
        updatedMs,
        outcome,
        durationSeconds
      };
    })
    .filter((entry) => Number.isFinite(entry.createdMs))
    .sort((a, b) => a.createdMs - b.createdMs);

  const considered = normalized.filter((entry) => entry.outcome !== 'ignored');
  const successes = considered.filter((entry) => entry.outcome === 'success');
  const failures = considered.filter((entry) => entry.outcome === 'failure');
  const skipped = considered.filter((entry) => entry.outcome === 'skipped');
  const effectiveRuns = considered.filter((entry) => entry.outcome !== 'skipped');
  const successDurations = successes
    .map((entry) => entry.durationSeconds)
    .filter((value) => Number.isFinite(value) && value >= 0);

  let incidentStartMs = null;
  const mttrDurations = [];
  for (const entry of considered) {
    if (entry.outcome === 'failure' && incidentStartMs == null) {
      incidentStartMs = Number.isFinite(entry.updatedMs) ? entry.updatedMs : entry.createdMs;
      continue;
    }
    if (entry.outcome === 'success' && incidentStartMs != null) {
      const resolvedMs = Number.isFinite(entry.updatedMs) ? entry.updatedMs : entry.createdMs;
      if (resolvedMs >= incidentStartMs) {
        mttrDurations.push((resolvedMs - incidentStartMs) / 1000);
      }
      incidentStartMs = null;
    }
  }

  const lastSuccessMs = successes.length > 0 ? successes[successes.length - 1].updatedMs : null;
  const staleHours =
    Number.isFinite(lastSuccessMs) && Number.isFinite(now.getTime())
      ? (now.getTime() - lastSuccessMs) / (1000 * 60 * 60)
      : null;

  return {
    totals: {
      totalRuns: effectiveRuns.length,
      observedRuns: considered.length,
      successRuns: successes.length,
      failedRuns: failures.length,
      skippedRuns: skipped.length,
      gateRegressions: failures.length
    },
    metrics: {
      failureRate: effectiveRuns.length > 0 ? failures.length / effectiveRuns.length : 0,
      skipRate: considered.length > 0 ? skipped.length / considered.length : 0,
      leadTimeP50Seconds: percentile(successDurations, 0.5),
      leadTimeP95Seconds: percentile(successDurations, 0.95),
      mttrSeconds: average(mttrDurations),
      staleHours,
      unresolvedIncident: incidentStartMs != null
    }
  };
}

export function evaluateBreaches(summary, thresholds) {
  const breaches = [];
  if (summary.metrics.failureRate > thresholds.failureRate) {
    breaches.push({
      code: 'failure-rate',
      message: `failureRate ${summary.metrics.failureRate.toFixed(3)} exceeds threshold ${thresholds.failureRate}`
    });
  }
  if (summary.metrics.skipRate > thresholds.skipRate) {
    breaches.push({
      code: 'skip-rate',
      message: `skipRate ${summary.metrics.skipRate.toFixed(3)} exceeds threshold ${thresholds.skipRate}`
    });
  }
  if (
    Number.isFinite(summary.metrics.mttrSeconds) &&
    summary.metrics.mttrSeconds > thresholds.mttrHours * 3600
  ) {
    breaches.push({
      code: 'mttr',
      message: `mttrHours ${(summary.metrics.mttrSeconds / 3600).toFixed(2)} exceeds threshold ${thresholds.mttrHours}`
    });
  }
  if (
    Number.isFinite(summary.metrics.staleHours) &&
    summary.metrics.staleHours > thresholds.staleHours
  ) {
    breaches.push({
      code: 'stale-budget',
      message: `staleHours ${summary.metrics.staleHours.toFixed(2)} exceeds threshold ${thresholds.staleHours}`
    });
  }
  if (summary.totals.gateRegressions > thresholds.gateRegressions) {
    breaches.push({
      code: 'gate-regressions',
      message: `gateRegressions ${summary.totals.gateRegressions} exceeds threshold ${thresholds.gateRegressions}`
    });
  }
  return breaches;
}

function appendStepSummary(lines) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (!summaryPath) return;
  fs.appendFileSync(summaryPath, `${lines.join('\n')}\n`, 'utf8');
}

function formatNumber(value, digits = 2) {
  if (!Number.isFinite(value)) return 'n/a';
  return value.toFixed(digits);
}

function renderBreachIssueBody(payload) {
  const lines = [
    '## SLO Breach Detected',
    '',
    `- Repository: \`${payload.repository}\``,
    `- Generated at: \`${payload.generatedAt}\``,
    `- Failure rate: \`${formatNumber(payload.summary.metrics.failureRate, 3)}\``,
    `- Skip rate: \`${formatNumber(payload.summary.metrics.skipRate, 3)}\``,
    `- MTTR hours: \`${formatNumber(payload.summary.metrics.mttrSeconds / 3600, 2)}\``,
    `- Stale hours: \`${formatNumber(payload.summary.metrics.staleHours, 2)}\``,
    `- Gate regressions: \`${payload.summary.totals.gateRegressions}\``,
    '',
    '### Breaches'
  ];
  for (const breach of payload.breaches) {
    lines.push(`- ${breach.code}: ${breach.message}`);
  }
  lines.push('', '### Workflow metrics');
  for (const workflow of payload.workflowSummaries) {
    lines.push(
      `- \`${workflow.workflow}\`: failureRate=${formatNumber(workflow.summary.metrics.failureRate, 3)}, skipRate=${formatNumber(
        workflow.summary.metrics.skipRate,
        3
      )}, mttrHours=${formatNumber(
        workflow.summary.metrics.mttrSeconds / 3600,
        2
      )}, staleHours=${formatNumber(workflow.summary.metrics.staleHours, 2)}, total=${workflow.summary.totals.totalRuns}`
    );
  }
  return `${lines.join('\n')}\n`;
}

async function routeBreachIssue(repo, token, payload, options) {
  if (!options.routeOnBreach || payload.breaches.length === 0) {
    return { action: 'none' };
  }

  try {
    const labels = options.routeLabels;
    const listUrl = `https://api.github.com/repos/${repo}/issues?state=open&per_page=100&labels=${encodeURIComponent(labels.join(','))}`;
    const issues = await requestJson(listUrl, token, 'GET');
    const titlePrefix = options.routeTitlePrefix;
    const existing = Array.isArray(issues)
      ? issues.find((issue) => issue?.title?.startsWith(titlePrefix))
      : null;
    const body = renderBreachIssueBody(payload);

    if (existing?.number) {
      await requestJson(
        `https://api.github.com/repos/${repo}/issues/${existing.number}/comments`,
        token,
        'POST',
        { body }
      );
      return { action: 'comment', issueNumber: existing.number };
    }

    const created = await requestJson(
      `https://api.github.com/repos/${repo}/issues`,
      token,
      'POST',
      {
        title: `${titlePrefix} (${payload.generatedAt.slice(0, 10)})`,
        body,
        labels
      }
    );
    return { action: 'create', issueNumber: created?.number ?? null };
  } catch (error) {
    return { action: 'error', message: error?.message || String(error) };
  }
}

async function fetchWorkflowRuns(repo, workflowId, token, options) {
  const perPage = Math.max(1, Math.min(options.maxRuns, 100));
  const url = `https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(workflowId)}/runs?status=completed&per_page=${perPage}`;
  const payload = await requestJson(url, token, 'GET');
  const runs = Array.isArray(payload?.workflow_runs) ? payload.workflow_runs : [];
  const cutoffMs = Date.now() - options.lookbackDays * 24 * 60 * 60 * 1000;
  return runs.filter((run) => {
    const createdMs = Date.parse(run.created_at || '');
    if (!Number.isFinite(createdMs)) return false;
    return createdMs >= cutoffMs;
  });
}

export function buildSloSummary(workflowSummaries) {
  const allRuns = workflowSummaries.flatMap((entry) => {
    const summary = entry.summary;
    return {
      total: summary.totals.totalRuns,
      observed: summary.totals.observedRuns,
      success: summary.totals.successRuns,
      failed: summary.totals.failedRuns,
      skipped: summary.totals.skippedRuns,
      gateRegressions: summary.totals.gateRegressions,
      leadTimeP50Seconds: summary.metrics.leadTimeP50Seconds,
      leadTimeP95Seconds: summary.metrics.leadTimeP95Seconds,
      mttrSeconds: summary.metrics.mttrSeconds,
      staleHours: summary.metrics.staleHours,
      skipRate: summary.metrics.skipRate
    };
  });

  const totals = {
    totalRuns: allRuns.reduce((sum, item) => sum + item.total, 0),
    observedRuns: allRuns.reduce((sum, item) => sum + item.observed, 0),
    successRuns: allRuns.reduce((sum, item) => sum + item.success, 0),
    failedRuns: allRuns.reduce((sum, item) => sum + item.failed, 0),
    skippedRuns: allRuns.reduce((sum, item) => sum + item.skipped, 0),
    gateRegressions: allRuns.reduce((sum, item) => sum + item.gateRegressions, 0)
  };

  const failureRate = totals.totalRuns > 0 ? totals.failedRuns / totals.totalRuns : 0;
  const skipRate = totals.observedRuns > 0 ? totals.skippedRuns / totals.observedRuns : 0;
  const leadTimeP50Seconds = percentile(
    allRuns.map((item) => item.leadTimeP50Seconds).filter((value) => Number.isFinite(value)),
    0.5
  );
  const leadTimeP95Seconds = percentile(
    allRuns.map((item) => item.leadTimeP95Seconds).filter((value) => Number.isFinite(value)),
    0.95
  );
  const mttrSeconds = average(allRuns.map((item) => item.mttrSeconds).filter((value) => Number.isFinite(value)));
  const staleHours = (() => {
    const values = allRuns.map((item) => item.staleHours).filter((value) => Number.isFinite(value));
    if (values.length === 0) return null;
    return Math.max(...values);
  })();

  return {
    totals,
    metrics: {
      failureRate,
      skipRate,
      leadTimeP50Seconds,
      leadTimeP95Seconds,
      mttrSeconds,
      staleHours
    }
  };
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const repository = resolveRepositorySlug(options.repo);
  const token = resolveToken();
  const now = new Date();

  const workflowSummaries = [];
  for (const workflow of options.workflows) {
    const runs = await fetchWorkflowRuns(repository, workflow, token, options);
    const summary = summarizeWorkflowRuns(runs, now);
    workflowSummaries.push({ workflow, summary, runCount: runs.length });
  }

  const summary = buildSloSummary(workflowSummaries);
  const thresholds = {
    failureRate: options.thresholdFailureRate,
    skipRate: options.thresholdSkipRate,
    mttrHours: options.thresholdMttrHours,
    staleHours: options.thresholdStaleHours,
    gateRegressions: options.thresholdGateRegressions
  };
  const breaches = evaluateBreaches(summary, thresholds);

  const payload = {
    schema: 'priority/slo-metrics@v1',
    generatedAt: now.toISOString(),
    repository,
    lookbackDays: options.lookbackDays,
    thresholds,
    workflowSummaries,
    summary,
    breaches
  };

  payload.route = await routeBreachIssue(repository, token, payload, options);
  const outputPath = writeJson(options.outputPath, payload);

  const lines = [
    '### SLO Metrics',
    `- Repository: \`${repository}\``,
    `- Workflows: ${options.workflows.map((entry) => `\`${entry}\``).join(', ')}`,
    `- Failure rate: \`${formatNumber(summary.metrics.failureRate, 3)}\``,
    `- Skip rate: \`${formatNumber(summary.metrics.skipRate, 3)}\``,
    `- Lead time p50 (s): \`${formatNumber(summary.metrics.leadTimeP50Seconds, 2)}\``,
    `- MTTR (hours): \`${formatNumber(summary.metrics.mttrSeconds / 3600, 2)}\``,
    `- Stale hours (max): \`${formatNumber(summary.metrics.staleHours, 2)}\``,
    `- Gate regressions: \`${summary.totals.gateRegressions}\``,
    `- Breaches: \`${breaches.length}\``,
    `- Route action: \`${payload.route?.action || 'none'}\``,
    `- Artifact: \`${options.outputPath}\``
  ];
  appendStepSummary(lines);
  console.log(`[slo-metrics] wrote ${outputPath} (breaches=${breaches.length}, route=${payload.route?.action || 'none'})`);
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) process.exitCode = code;
    })
    .catch((error) => {
      console.error(error?.stack ?? error?.message ?? String(error));
      process.exitCode = 1;
    });
}

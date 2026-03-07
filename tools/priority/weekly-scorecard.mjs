#!/usr/bin/env node

import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/weekly-scorecard@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'slo', 'weekly-scorecard.json');
export const DEFAULT_REMEDIATION_REPORT_PATH = path.join('tests', 'results', '_agent', 'slo', 'remediation-slo-report.json');
export const DEFAULT_CANARY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'canary',
  'canary-replay-conformance-report.json'
);

function printUsage() {
  console.log('Usage: node tools/priority/weekly-scorecard.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --output <path>              Weekly scorecard output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log(`  --remediation-report <path>  Remediation SLO report path (default: ${DEFAULT_REMEDIATION_REPORT_PATH}).`);
  console.log(`  --canary-report <path>       Canary replay report path (default: ${DEFAULT_CANARY_REPORT_PATH}).`);
  console.log('  --mode <weekly|gameday>      Scorecard mode (default: weekly).');
  console.log('  --require-canary             Fail scorecard when canary report is missing/non-pass.');
  console.log('  --route-on-persistent-breach Upsert governance incident issue when breach is persistent.');
  console.log('  --issue-title-prefix <text>  Incident issue title prefix (default: [Governance] Weekly scorecard breach).');
  console.log('  --issue-labels <a,b,c>       Incident issue labels (default: governance,slo,canary).');
  console.log('  --repo <owner/repo>          Repository slug (default: GITHUB_REPOSITORY/upstream/origin remote).');
  console.log('  -h, --help                   Show this help text and exit.');
}

function normalizeText(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text ? text : null;
}

function normalizeLabels(value) {
  return String(value ?? '')
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);
}

export function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) return null;
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return `${owner}/${repo}`;
}

export function resolveRepositorySlug(repoRoot, explicitRepo, environment = process.env) {
  const explicit = normalizeText(explicitRepo);
  if (explicit && explicit.includes('/')) return explicit;
  const envRepo = normalizeText(environment.GITHUB_REPOSITORY);
  if (envRepo && envRepo.includes('/')) return envRepo;

  for (const remoteName of ['upstream', 'origin']) {
    const result = spawnSync('git', ['config', '--get', `remote.${remoteName}.url`], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    if (result.status !== 0) continue;
    const parsed = parseRemoteUrl(result.stdout.trim());
    if (parsed) return parsed;
  }

  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    outputPath: DEFAULT_OUTPUT_PATH,
    remediationReportPath: DEFAULT_REMEDIATION_REPORT_PATH,
    canaryReportPath: DEFAULT_CANARY_REPORT_PATH,
    mode: 'weekly',
    requireCanary: false,
    routeOnPersistentBreach: false,
    issueTitlePrefix: '[Governance] Weekly scorecard breach',
    issueLabels: ['governance', 'slo', 'canary'],
    repo: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--require-canary') {
      options.requireCanary = true;
      continue;
    }
    if (token === '--route-on-persistent-breach') {
      options.routeOnPersistentBreach = true;
      continue;
    }

    if (
      token === '--output' ||
      token === '--remediation-report' ||
      token === '--canary-report' ||
      token === '--mode' ||
      token === '--issue-title-prefix' ||
      token === '--issue-labels' ||
      token === '--repo'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--output') options.outputPath = next;
      if (token === '--remediation-report') options.remediationReportPath = next;
      if (token === '--canary-report') options.canaryReportPath = next;
      if (token === '--mode') options.mode = next.trim().toLowerCase();
      if (token === '--issue-title-prefix') options.issueTitlePrefix = next;
      if (token === '--issue-labels') options.issueLabels = normalizeLabels(next);
      if (token === '--repo') options.repo = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!['weekly', 'gameday'].includes(options.mode)) {
    throw new Error(`Invalid --mode '${options.mode}'. Expected weekly or gameday.`);
  }
  return options;
}

async function readJsonOptional(filePath) {
  const resolved = path.resolve(filePath);
  if (!existsSync(resolved)) {
    return {
      exists: false,
      path: resolved,
      payload: null,
      error: null
    };
  }

  try {
    const raw = await readFile(resolved, 'utf8');
    return {
      exists: true,
      path: resolved,
      payload: JSON.parse(raw),
      error: null
    };
  } catch (error) {
    return {
      exists: true,
      path: resolved,
      payload: null,
      error: error?.message ?? String(error)
    };
  }
}

function resolveStatus(payload, fallback = 'fail') {
  const status = normalizeText(payload?.summary?.status) ?? normalizeText(payload?.status);
  if (!status) return fallback;
  const normalized = status.toLowerCase();
  if (normalized === 'pass' || normalized === 'warn' || normalized === 'fail') {
    return normalized;
  }
  return fallback;
}

function severityRank(status) {
  if (status === 'fail') return 2;
  if (status === 'warn') return 1;
  return 0;
}

async function resolveToken() {
  for (const candidate of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    const token = normalizeText(candidate);
    if (token) return token;
  }

  const files = [process.env.GH_TOKEN_FILE];
  if (process.platform === 'win32') {
    files.push('C:\\github_token.txt');
  }

  for (const filePath of files) {
    if (!filePath) continue;
    try {
      await access(filePath);
      const token = normalizeText(await readFile(filePath, 'utf8'));
      if (token) return token;
    } catch {
      // ignore
    }
  }

  return null;
}

async function requestGitHubJson(url, token, method = 'GET', body = null) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'priority-weekly-scorecard'
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

function buildIncidentBody({ report, mode }) {
  const lines = [
    '## Governance Scorecard Incident',
    '',
    `- Mode: \`${mode}\``,
    `- Generated at: \`${report.generatedAt}\``,
    `- Status: \`${report.summary.status}\``,
    `- Persistent breach: \`${report.summary.persistentBreach}\``,
    '',
    '### Components',
    `- remediation: \`${report.components.remediation.status}\``,
    `- canary: \`${report.components.canary.status}\``,
    '',
    '### Breaches',
    ...report.summary.breaches.map((entry) => `- ${entry.key}: ${entry.status}`)
  ];
  return `${lines.join('\n')}\n`;
}

async function upsertGovernanceIssue({ repository, token, report, titlePrefix, labels, mode }) {
  const encodedLabels = encodeURIComponent(labels.join(','));
  const listUrl = `https://api.github.com/repos/${repository}/issues?state=open&labels=${encodedLabels}&per_page=100`;
  const issues = await requestGitHubJson(listUrl, token, 'GET');
  const existing = Array.isArray(issues)
    ? issues.find((issue) => String(issue?.title ?? '').startsWith(titlePrefix))
    : null;

  const body = buildIncidentBody({ report, mode });
  if (existing?.number) {
    await requestGitHubJson(
      `https://api.github.com/repos/${repository}/issues/${existing.number}/comments`,
      token,
      'POST',
      { body }
    );
    return {
      action: 'comment',
      issueNumber: existing.number,
      issueUrl: existing.html_url ?? null,
      error: null
    };
  }

  const created = await requestGitHubJson(
    `https://api.github.com/repos/${repository}/issues`,
    token,
    'POST',
    {
      title: `${titlePrefix} (${report.generatedAt.slice(0, 10)})`,
      body,
      labels
    }
  );

  return {
    action: 'create',
    issueNumber: created?.number ?? null,
    issueUrl: created?.html_url ?? null,
    error: null
  };
}

async function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runWeeklyScorecard(options = {}) {
  const repoRoot = options.repoRoot ?? process.cwd();
  const args = options.args ?? parseArgs();
  const now = options.now ?? new Date();
  const environment = options.environment ?? process.env;
  const readJsonOptionalFn = options.readJsonOptionalFn ?? readJsonOptional;
  const writeJsonFn = options.writeJsonFn ?? writeJson;
  const routeIssueFn = options.routeIssueFn ?? upsertGovernanceIssue;

  const repository = resolveRepositorySlug(repoRoot, args.repo, environment);
  const previousEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.outputPath));
  const remediationEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.remediationReportPath));
  const canaryEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.canaryReportPath));

  const remediationStatus =
    remediationEnvelope.exists && !remediationEnvelope.error && remediationEnvelope.payload
      ? resolveStatus(remediationEnvelope.payload)
      : 'fail';

  let canaryStatus = 'n/a';
  const canaryAvailable = canaryEnvelope.exists && !canaryEnvelope.error && Boolean(canaryEnvelope.payload);
  if (canaryAvailable) {
    canaryStatus = resolveStatus(canaryEnvelope.payload);
  } else if (args.requireCanary) {
    canaryStatus = 'fail';
  }

  const statuses = [remediationStatus];
  if (canaryStatus !== 'n/a') {
    statuses.push(canaryStatus);
  }
  const overallStatus = statuses.sort((left, right) => severityRank(right) - severityRank(left))[0] ?? 'pass';

  const breaches = [];
  if (remediationStatus !== 'pass') {
    breaches.push({ key: 'remediation', status: remediationStatus });
  }
  if (canaryStatus === 'warn' || canaryStatus === 'fail') {
    breaches.push({ key: 'canary', status: canaryStatus });
  }
  if (args.requireCanary && !canaryAvailable) {
    breaches.push({ key: 'canary-missing', status: 'fail' });
  }

  const previousStatus = resolveStatus(previousEnvelope.payload, 'pass');
  const firstBreach = previousStatus === 'pass' && overallStatus !== 'pass';
  const persistentBreach = previousStatus !== 'pass' && overallStatus !== 'pass';

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    mode: args.mode,
    requireCanary: args.requireCanary,
    inputs: {
      outputPath: args.outputPath,
      remediationReportPath: args.remediationReportPath,
      canaryReportPath: args.canaryReportPath
    },
    components: {
      remediation: {
        status: remediationStatus,
        exists: remediationEnvelope.exists,
        error: remediationEnvelope.error
      },
      canary: {
        status: canaryStatus,
        exists: canaryEnvelope.exists,
        error: canaryEnvelope.error,
        required: args.requireCanary
      }
    },
    summary: {
      status: overallStatus,
      breachCount: breaches.length,
      breaches,
      previousStatus,
      firstBreach,
      persistentBreach
    },
    routing: {
      enabled: args.routeOnPersistentBreach,
      action: 'none',
      issueNumber: null,
      issueUrl: null,
      error: null
    }
  };

  if (args.routeOnPersistentBreach && persistentBreach) {
    const token = normalizeText(options.githubToken ?? (await resolveToken()));
    if (!token) {
      report.routing.action = 'skip-no-token';
      report.routing.error = 'GitHub token unavailable for issue upsert.';
    } else {
      try {
        const routed = await routeIssueFn({
          repository,
          token,
          report,
          titlePrefix: args.issueTitlePrefix,
          labels: args.issueLabels,
          mode: args.mode
        });
        report.routing.action = routed.action;
        report.routing.issueNumber = routed.issueNumber ?? null;
        report.routing.issueUrl = routed.issueUrl ?? null;
        report.routing.error = routed.error ?? null;
      } catch (error) {
        report.routing.action = 'error';
        report.routing.error = error?.message ?? String(error);
      }
    }
  }

  const reportPath = await writeJsonFn(args.outputPath, report);
  return {
    report,
    reportPath,
    exitCode: 0
  };
}

export async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const { report, reportPath } = await runWeeklyScorecard({ args });
  console.log(
    `[weekly-scorecard] report: ${reportPath} status=${report.summary.status} persistent=${report.summary.persistentBreach} route=${report.routing.action}`
  );
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((exitCode) => {
      if (exitCode !== 0) {
        process.exitCode = exitCode;
      }
    })
    .catch((error) => {
      console.error(error?.stack ?? error?.message ?? String(error));
      process.exitCode = 1;
    });
}
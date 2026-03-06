#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'onboarding',
  'downstream-onboarding-success.json'
);

function printUsage() {
  console.log('Usage: node tools/priority/downstream-onboarding-success.mjs --report <path> [options]');
  console.log('');
  console.log('Options:');
  console.log('  --report <path>                 Input onboarding report path (repeatable).');
  console.log(`  --output <path>                 Output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --parent-issue <n>              Parent issue number for traceability.');
  console.log('  --create-hardening-issues       Create hardening issues from aggregated backlog.');
  console.log('  --issue-repo <owner/repo>       Repository where hardening issues are created (default: env/remotes).');
  console.log('  --issue-labels <a,b,c>          Labels for hardening issues (default: program,enhancement).');
  console.log('  --issue-prefix <text>           Prefix used in hardening issue titles (default: [onboarding-hardening]).');
  console.log('  --fail-on-incomplete            Exit non-zero when aggregated summary status is fail.');
  console.log('  -h, --help                      Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    reportPaths: [],
    outputPath: DEFAULT_OUTPUT_PATH,
    parentIssue: null,
    createHardeningIssues: false,
    issueRepo: null,
    issueLabels: ['program', 'enhancement'],
    issuePrefix: '[onboarding-hardening]',
    failOnIncomplete: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--create-hardening-issues') {
      options.createHardeningIssues = true;
      continue;
    }
    if (token === '--fail-on-incomplete') {
      options.failOnIncomplete = true;
      continue;
    }

    if (token === '--report' || token === '--output' || token === '--issue-repo' || token === '--issue-prefix') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--report') options.reportPaths.push(next);
      if (token === '--output') options.outputPath = next;
      if (token === '--issue-repo') options.issueRepo = next;
      if (token === '--issue-prefix') options.issuePrefix = next;
      continue;
    }

    if (token === '--parent-issue') {
      if (!next || next.startsWith('-')) {
        throw new Error('Missing value for --parent-issue.');
      }
      index += 1;
      const parsed = Number.parseInt(next, 10);
      if (!Number.isFinite(parsed) || parsed < 1) {
        throw new Error(`Invalid --parent-issue value: ${next}`);
      }
      options.parentIssue = parsed;
      continue;
    }

    if (token === '--issue-labels') {
      if (!next || next.startsWith('-')) {
        throw new Error('Missing value for --issue-labels.');
      }
      index += 1;
      options.issueLabels = next
        .split(',')
        .map((entry) => entry.trim())
        .filter(Boolean);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && options.reportPaths.length === 0) {
    throw new Error('At least one --report <path> is required.');
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

function normalizeRepositorySlug(slug) {
  const trimmed = String(slug || '').trim();
  if (!trimmed.includes('/')) {
    throw new Error(`Invalid repository slug: ${slug}`);
  }
  const [owner, repo] = trimmed.split('/', 2);
  if (!owner || !repo) {
    throw new Error(`Invalid repository slug: ${slug}`);
  }
  return `${owner}/${repo}`;
}

function resolveRepositorySlug(explicitRepo) {
  if (explicitRepo) return normalizeRepositorySlug(explicitRepo);
  const envRepo = process.env.GITHUB_REPOSITORY?.trim();
  if (envRepo && envRepo.includes('/')) return normalizeRepositorySlug(envRepo);
  for (const remoteName of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remoteName}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString()
        .trim();
      const parsed = parseRemoteUrl(raw);
      if (parsed) return normalizeRepositorySlug(parsed);
    } catch {
      // ignore missing remote
    }
  }
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --issue-repo.');
}

function resolveToken() {
  for (const value of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    if (value && value.trim()) return value.trim();
  }
  for (const candidate of [process.env.GH_TOKEN_FILE, process.platform === 'win32' ? 'C:\\github_token.txt' : null]) {
    if (!candidate || !fs.existsSync(candidate)) continue;
    const value = fs.readFileSync(candidate, 'utf8').trim();
    if (value) return value;
  }
  throw new Error('GitHub token not found. Set GH_TOKEN/GITHUB_TOKEN (or GH_TOKEN_FILE).');
}

async function requestGithub(url, token, method = 'GET', body = null) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'priority-downstream-onboarding-success',
      'X-GitHub-Api-Version': '2022-11-28'
    },
    body: body ? JSON.stringify(body) : undefined
  });

  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = null;
    }
  }

  return {
    ok: response.ok,
    status: response.status,
    payload,
    text
  };
}

function readJson(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    throw new Error(`Report file not found: ${resolvedPath}`);
  }
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function toSeverityRank(severity) {
  if (severity === 'P1') return 1;
  if (severity === 'P2') return 2;
  return 3;
}

function round(value, digits = 3) {
  if (!Number.isFinite(value)) return null;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function average(values) {
  if (!Array.isArray(values) || values.length === 0) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

export function aggregateReports(reportsWithPaths) {
  const reports = reportsWithPaths.map((entry) => entry.report);
  const reportRows = reportsWithPaths.map((entry) => ({
    repository: String(entry.report?.downstreamRepository || '').trim(),
    status: String(entry.report?.summary?.status || 'fail').toLowerCase(),
    path: entry.path,
    leadTimeHours: Number.isFinite(entry.report?.metrics?.onboardingLeadTimeHours)
      ? entry.report.metrics.onboardingLeadTimeHours
      : null,
    frictionScore: Number.isFinite(entry.report?.metrics?.frictionScore) ? entry.report.metrics.frictionScore : null
  }));

  const repositoriesPassing = reportRows.filter((entry) => entry.status === 'pass').length;
  const repositoriesWarning = reportRows.filter((entry) => entry.status === 'warn').length;
  const repositoriesFailing = reportRows.filter((entry) => entry.status === 'fail').length;
  const status = repositoriesFailing > 0 ? 'fail' : repositoriesWarning > 0 ? 'warn' : 'pass';

  const leadTimes = reportRows
    .map((entry) => entry.leadTimeHours)
    .filter((value) => Number.isFinite(value));
  const averageLeadTimeHours = round(average(leadTimes));

  const totalBlockers = reports.reduce(
    (sum, report) => sum + (Number.isFinite(report?.metrics?.requiredFailures) ? report.metrics.requiredFailures : 0),
    0
  );
  const totalWarnings = reports.reduce(
    (sum, report) => sum + (Number.isFinite(report?.metrics?.warningCount) ? report.metrics.warningCount : 0),
    0
  );

  const deltas = reports.map((report) => {
    const checklist = Array.isArray(report?.checklist) ? report.checklist : [];
    const required = checklist.filter((entry) => entry.required);
    const passCount = checklist.filter((entry) => entry.status === 'pass').length;
    const requiredPassCount = required.filter((entry) => entry.status === 'pass').length;
    const blockers = Number.isFinite(report?.metrics?.requiredFailures) ? report.metrics.requiredFailures : 0;
    const warnings = Number.isFinite(report?.metrics?.warningCount) ? report.metrics.warningCount : 0;
    return {
      repository: String(report?.downstreamRepository || '').trim(),
      checklistPassRate: checklist.length > 0 ? round(passCount / checklist.length, 4) : 0,
      requiredCompletionRate: required.length > 0 ? round(requiredPassCount / required.length, 4) : 0,
      blockers,
      warnings,
      frictionScore: Number.isFinite(report?.metrics?.frictionScore) ? report.metrics.frictionScore : 0
    };
  });

  const painPointMap = new Map();
  const backlogMap = new Map();
  for (const report of reports) {
    const repo = String(report?.downstreamRepository || '').trim();
    const backlog = Array.isArray(report?.hardeningBacklog) ? report.hardeningBacklog : [];
    for (const entry of backlog) {
      const key = String(entry.key || '').trim() || 'unknown';
      if (!painPointMap.has(key)) {
        painPointMap.set(key, {
          key,
          severity: entry.severity || 'P3',
          count: 0,
          repositories: new Set(),
          exampleReason: entry.reason || ''
        });
      }
      const point = painPointMap.get(key);
      point.count += 1;
      if (repo) point.repositories.add(repo);
      if (!point.exampleReason && entry.reason) {
        point.exampleReason = entry.reason;
      }
      if (toSeverityRank(entry.severity) < toSeverityRank(point.severity)) {
        point.severity = entry.severity;
      }

      const backlogKey = `${repo}::${key}`;
      if (!backlogMap.has(backlogKey)) {
        backlogMap.set(backlogKey, {
          key,
          title: String(entry.title || key),
          severity: entry.severity || 'P3',
          status: entry.status || 'warn',
          reason: String(entry.reason || ''),
          recommendation: String(entry.recommendation || ''),
          repositories: repo ? [repo] : []
        });
      }
    }
  }

  const painPoints = [...painPointMap.values()]
    .map((entry) => ({
      key: entry.key,
      severity: entry.severity,
      count: entry.count,
      repositories: [...entry.repositories].sort((a, b) => a.localeCompare(b)),
      exampleReason: entry.exampleReason || ''
    }))
    .sort((left, right) => {
      if (right.count !== left.count) return right.count - left.count;
      const severityDiff = toSeverityRank(left.severity) - toSeverityRank(right.severity);
      if (severityDiff !== 0) return severityDiff;
      return left.key.localeCompare(right.key);
    });

  const hardeningBacklog = [...backlogMap.values()].sort((left, right) => {
    const severityDiff = toSeverityRank(left.severity) - toSeverityRank(right.severity);
    if (severityDiff !== 0) return severityDiff;
    return left.key.localeCompare(right.key);
  });

  return {
    reports: reportRows,
    summary: {
      status,
      repositoriesEvaluated: reportRows.length,
      repositoriesPassing,
      repositoriesWarning,
      repositoriesFailing,
      averageLeadTimeHours,
      totalBlockers,
      totalWarnings
    },
    deltas,
    painPoints,
    hardeningBacklog
  };
}

function buildIssueBody(entry, output, parentIssue) {
  const repoList = entry.repositories.map((repo) => `- \`${repo}\``);
  const lines = [
    `<!-- downstream-onboarding-success:${entry.repositories.join(',')}:${entry.key} -->`,
    '## Downstream Onboarding Hardening',
    '',
    `- Checklist key: \`${entry.key}\``,
    `- Severity: \`${entry.severity}\``,
    `- Status: \`${entry.status}\``,
    `- Reason: \`${entry.reason}\``,
    ''
  ];
  if (entry.recommendation) {
    lines.push('### Recommendation', '', entry.recommendation, '');
  }
  if (repoList.length > 0) {
    lines.push('### Impacted repositories', '', ...repoList, '');
  }
  lines.push(
    '### Evidence',
    '',
    `- Success report generated at \`${output.generatedAt}\``,
    `- Aggregated report status: \`${output.summary.status}\``
  );
  if (parentIssue) {
    lines.push(`- Parent issue: #${parentIssue}`);
  }
  return `${lines.join('\n')}\n`;
}

async function createHardeningIssues(output, options, token) {
  if (!options.createHardeningIssues || output.hardeningBacklog.length === 0) {
    return [];
  }

  const issueRepo = normalizeRepositorySlug(options.issueRepo);
  const listResponse = await requestGithub(
    `https://api.github.com/repos/${issueRepo}/issues?state=open&per_page=100`,
    token,
    'GET'
  );
  const openIssues = listResponse.ok && Array.isArray(listResponse.payload) ? listResponse.payload : [];

  const results = [];
  for (const entry of output.hardeningBacklog) {
    const title = `${options.issuePrefix} ${entry.title}`;
    const marker = `<!-- downstream-onboarding-success:${entry.repositories.join(',')}:${entry.key} -->`;
    const existing = openIssues.find((issue) => issue?.body?.includes(marker) || issue?.title === title);
    if (existing?.number) {
      results.push({
        action: 'existing',
        key: entry.key,
        number: existing.number,
        url: existing.html_url ?? null
      });
      continue;
    }

    const payload = {
      title,
      body: buildIssueBody(entry, output, options.parentIssue),
      labels: options.issueLabels
    };
    let created = await requestGithub(`https://api.github.com/repos/${issueRepo}/issues`, token, 'POST', payload);
    if (!created.ok && options.issueLabels.length > 0) {
      created = await requestGithub(
        `https://api.github.com/repos/${issueRepo}/issues`,
        token,
        'POST',
        {
          title,
          body: buildIssueBody(entry, output, options.parentIssue)
        }
      );
    }
    if (!created.ok) {
      results.push({
        action: 'error',
        key: entry.key,
        status: created.status,
        message: created.text || 'issue-create-failed'
      });
      continue;
    }
    results.push({
      action: 'created',
      key: entry.key,
      number: created.payload?.number ?? null,
      url: created.payload?.html_url ?? null
    });
  }
  return results;
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function appendStepSummary(output, outputPath) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (!summaryPath) return;
  const lines = [
    '### Downstream Onboarding Success',
    `- Aggregated status: \`${output.summary.status}\``,
    `- Repositories evaluated: \`${output.summary.repositoriesEvaluated}\``,
    `- Repositories passing: \`${output.summary.repositoriesPassing}\``,
    `- Repositories warning: \`${output.summary.repositoriesWarning}\``,
    `- Repositories failing: \`${output.summary.repositoriesFailing}\``,
    `- Total blockers: \`${output.summary.totalBlockers}\``,
    `- Total warnings: \`${output.summary.totalWarnings}\``,
    `- Pain points: \`${output.painPoints.length}\``,
    `- Hardening backlog: \`${output.hardeningBacklog.length}\``,
    `- Artifact: \`${outputPath}\``
  ];
  fs.appendFileSync(summaryPath, `${lines.join('\n')}\n`, 'utf8');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const reportsWithPaths = options.reportPaths.map((reportPath) => ({
    path: path.resolve(reportPath),
    report: readJson(reportPath)
  }));
  const aggregated = aggregateReports(reportsWithPaths);
  const generatedAt = new Date().toISOString();
  const output = {
    schema: 'priority/downstream-onboarding-success@v1',
    generatedAt,
    parentIssue: options.parentIssue ?? null,
    reports: aggregated.reports,
    summary: aggregated.summary,
    deltas: aggregated.deltas,
    painPoints: aggregated.painPoints,
    hardeningBacklog: aggregated.hardeningBacklog,
    hardeningIssues: []
  };

  if (options.createHardeningIssues) {
    const issueRepo = resolveRepositorySlug(options.issueRepo);
    const token = resolveToken();
    output.hardeningIssues = await createHardeningIssues(
      output,
      {
        ...options,
        issueRepo
      },
      token
    );
  }

  const resolvedOutputPath = writeJson(options.outputPath, output);
  appendStepSummary(output, options.outputPath);
  console.log(
    `[downstream-onboarding-success] wrote ${resolvedOutputPath} (status=${output.summary.status}, painPoints=${output.painPoints.length})`
  );
  return options.failOnIncomplete && output.summary.status === 'fail' ? 1 : 0;
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

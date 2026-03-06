#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const MS_DAY = 24 * 60 * 60 * 1000;
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'security', 'security-intake-report.json');
export const DEFAULT_LOOKBACK_DAYS = 45;
export const DEFAULT_MAX_PAGES = 10;
export const DEFAULT_ROUTE_TITLE_PREFIX = '[Security Intake] Vulnerability remediation required';
export const DEFAULT_ROUTE_LABELS = ['security', 'ci', 'governance', 'supply-chain'];
export const DEFAULT_THRESHOLDS = Object.freeze({
  openCriticalMax: 0,
  openHighMax: 0,
  openModerateMax: 5,
  staleOpenDays: 30,
  staleOpenCountMax: 0,
  mttrDaysMax: 30
});

const HELP = [
  'Usage: node tools/priority/security-intake.mjs [options]',
  '',
  'Options:',
  '  --repo <owner/repo>',
  `  --output <path>                     (default: ${DEFAULT_OUTPUT_PATH})`,
  `  --lookback-days <n>                 (default: ${DEFAULT_LOOKBACK_DAYS})`,
  `  --max-pages <n>                     (default: ${DEFAULT_MAX_PAGES})`,
  `  --threshold-open-critical <n>       (default: ${DEFAULT_THRESHOLDS.openCriticalMax})`,
  `  --threshold-open-high <n>           (default: ${DEFAULT_THRESHOLDS.openHighMax})`,
  `  --threshold-open-moderate <n>       (default: ${DEFAULT_THRESHOLDS.openModerateMax})`,
  `  --threshold-stale-days <n>          (default: ${DEFAULT_THRESHOLDS.staleOpenDays})`,
  `  --threshold-stale-count <n>         (default: ${DEFAULT_THRESHOLDS.staleOpenCountMax})`,
  `  --threshold-mttr-days <n>           (default: ${DEFAULT_THRESHOLDS.mttrDaysMax})`,
  '  --route-on-breach',
  `  --route-title-prefix <text>         (default: ${DEFAULT_ROUTE_TITLE_PREFIX})`,
  `  --route-labels <a,b,c>              (default: ${DEFAULT_ROUTE_LABELS.join(',')})`,
  '  --fail-on-breach',
  '  --fail-on-skip',
  '  --override-owner <login>',
  '  --override-reason <text>',
  '  --override-expires-at <iso8601>',
  '  --override-ticket <id/url>',
  '  -h, --help'
];

function printHelp(log = console.log) {
  for (const line of HELP) log(line);
}

function asOptional(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized || null;
}

function parseIntFlag(value, flag) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed) || parsed < 0) throw new Error(`Invalid value for ${flag}: ${value}`);
  return parsed;
}

function normalizeLabels(raw) {
  if (!raw) return [...DEFAULT_ROUTE_LABELS];
  const labels = String(raw).split(',').map((it) => it.trim()).filter(Boolean);
  return labels.length ? labels : [...DEFAULT_ROUTE_LABELS];
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    lookbackDays: DEFAULT_LOOKBACK_DAYS,
    maxPages: DEFAULT_MAX_PAGES,
    thresholds: { ...DEFAULT_THRESHOLDS },
    routeOnBreach: false,
    routeTitlePrefix: DEFAULT_ROUTE_TITLE_PREFIX,
    routeLabels: [...DEFAULT_ROUTE_LABELS],
    failOnBreach: false,
    failOnSkip: false,
    overrideOwner: null,
    overrideReason: null,
    overrideExpiresAt: null,
    overrideTicket: null,
    help: false
  };

  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    const next = args[i + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--route-on-breach') {
      options.routeOnBreach = true;
      continue;
    }
    if (token === '--fail-on-breach') {
      options.failOnBreach = true;
      continue;
    }
    if (token === '--fail-on-skip') {
      options.failOnSkip = true;
      continue;
    }

    const stringFlags = new Set([
      '--repo',
      '--output',
      '--route-title-prefix',
      '--route-labels',
      '--override-owner',
      '--override-reason',
      '--override-expires-at',
      '--override-ticket'
    ]);
    if (stringFlags.has(token)) {
      if (!next || next.startsWith('-')) throw new Error(`Missing value for ${token}.`);
      i += 1;
      if (token === '--repo') options.repo = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--route-title-prefix') options.routeTitlePrefix = next;
      if (token === '--route-labels') options.routeLabels = normalizeLabels(next);
      if (token === '--override-owner') options.overrideOwner = asOptional(next);
      if (token === '--override-reason') options.overrideReason = asOptional(next);
      if (token === '--override-expires-at') options.overrideExpiresAt = asOptional(next);
      if (token === '--override-ticket') options.overrideTicket = asOptional(next);
      continue;
    }

    const intFlags = new Set([
      '--lookback-days',
      '--max-pages',
      '--threshold-open-critical',
      '--threshold-open-high',
      '--threshold-open-moderate',
      '--threshold-stale-days',
      '--threshold-stale-count',
      '--threshold-mttr-days'
    ]);
    if (intFlags.has(token)) {
      if (!next || next.startsWith('-')) throw new Error(`Missing value for ${token}.`);
      i += 1;
      const parsed = parseIntFlag(next, token);
      if (token === '--lookback-days') options.lookbackDays = parsed;
      if (token === '--max-pages') options.maxPages = parsed;
      if (token === '--threshold-open-critical') options.thresholds.openCriticalMax = parsed;
      if (token === '--threshold-open-high') options.thresholds.openHighMax = parsed;
      if (token === '--threshold-open-moderate') options.thresholds.openModerateMax = parsed;
      if (token === '--threshold-stale-days') options.thresholds.staleOpenDays = parsed;
      if (token === '--threshold-stale-count') options.thresholds.staleOpenCountMax = parsed;
      if (token === '--threshold-mttr-days') options.thresholds.mttrDaysMax = parsed;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) return null;
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

export function resolveRepositorySlug(explicitRepo) {
  if (asOptional(explicitRepo)?.includes('/')) return String(explicitRepo).trim();
  if (asOptional(process.env.GITHUB_REPOSITORY)?.includes('/')) return process.env.GITHUB_REPOSITORY.trim();
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remote}.url`, { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
      const slug = parseRemoteUrl(raw);
      if (slug) return slug;
    } catch {}
  }
  throw new Error('Unable to resolve repository slug. Pass --repo or set GITHUB_REPOSITORY.');
}

export function resolveToken() {
  for (const candidate of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    const value = asOptional(candidate);
    if (value) return value;
  }
  for (const candidate of [asOptional(process.env.GH_TOKEN_FILE), process.platform === 'win32' ? 'C:\\github_token.txt' : null]) {
    if (!candidate || !fs.existsSync(candidate)) continue;
    const value = asOptional(fs.readFileSync(candidate, 'utf8'));
    if (value) return value;
  }
  throw new Error('GitHub token not found. Set GH_TOKEN/GITHUB_TOKEN (or GH_TOKEN_FILE).');
}

function parseDate(value) {
  const parsed = Date.parse(String(value || ''));
  return Number.isFinite(parsed) ? parsed : null;
}

function round(value) {
  if (!Number.isFinite(value)) return null;
  return Math.round(value * 100) / 100;
}

function severity(raw) {
  const normalized = String(raw || '').toLowerCase().trim();
  return ['critical', 'high', 'moderate', 'low'].includes(normalized) ? normalized : 'unknown';
}

function average(values) {
  if (!values.length) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function percentile(values, ratio) {
  if (!values.length) return null;
  const sorted = [...values].sort((l, r) => l - r);
  return sorted[Math.max(0, Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * ratio)))];
}

export function normalizeDependabotAlert(alert, now = new Date()) {
  const createdAt = alert?.created_at || null;
  const resolvedAt = alert?.fixed_at || alert?.dismissed_at || alert?.auto_dismissed_at || null;
  const createdMs = parseDate(createdAt);
  const resolvedMs = parseDate(resolvedAt);
  const nowMs = now.getTime();
  return {
    number: Number.isInteger(alert?.number) ? alert.number : null,
    state: String(alert?.state || 'unknown').toLowerCase(),
    severity: severity(alert?.security_advisory?.severity),
    packageName: asOptional(alert?.dependency?.package?.name),
    ecosystem: asOptional(alert?.dependency?.package?.ecosystem),
    manifestPath: asOptional(alert?.dependency?.manifest_path),
    createdAt,
    resolvedAt,
    ageDays: createdMs != null && nowMs >= createdMs ? round((nowMs - createdMs) / MS_DAY) : null,
    mttrDays: createdMs != null && resolvedMs != null && resolvedMs >= createdMs ? round((resolvedMs - createdMs) / MS_DAY) : null,
    url: alert?.html_url || null
  };
}

export async function requestGitHubJson(url, { token, method = 'GET', body = null, fetchImpl = globalThis.fetch } = {}) {
  if (!token) throw new Error('GitHub token is required for API requests.');
  if (typeof fetchImpl !== 'function') throw new Error('Fetch API is unavailable.');
  const response = await fetchImpl(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'priority-security-intake',
      'X-GitHub-Api-Version': '2022-11-28'
    },
    body: body ? JSON.stringify(body) : undefined
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const error = new Error(`GitHub API ${method} ${url} failed (${response.status}).`);
    error.status = response.status;
    error.url = url;
    throw error;
  }
  return payload;
}

export async function listDependabotAlerts({ repo, token, state, maxPages = DEFAULT_MAX_PAGES, perPage = 100, fetchImpl = globalThis.fetch }) {
  const alerts = [];
  for (let page = 1; page <= maxPages; page += 1) {
    const url = `https://api.github.com/repos/${repo}/dependabot/alerts?state=${encodeURIComponent(state)}&per_page=${perPage}&page=${page}`;
    const payload = await requestGitHubJson(url, { token, fetchImpl });
    if (!Array.isArray(payload)) throw new Error(`Unexpected Dependabot response for state=${state}.`);
    alerts.push(...payload);
    if (payload.length < perPage) break;
  }
  return alerts;
}

export function summarizeDependabotAlerts({ openAlerts = [], resolvedAlerts = [], thresholds = DEFAULT_THRESHOLDS, lookbackDays = DEFAULT_LOOKBACK_DAYS, now = new Date() } = {}) {
  const bySeverity = { critical: 0, high: 0, moderate: 0, low: 0, unknown: 0 };
  for (const alert of openAlerts) bySeverity[severity(alert.severity)] += 1;
  const stale = openAlerts.filter((alert) => Number.isFinite(alert.ageDays) && alert.ageDays > thresholds.staleOpenDays);
  const oldest = openAlerts.reduce((max, alert) => (Number.isFinite(alert.ageDays) ? Math.max(max, alert.ageDays) : max), 0);
  const cutoff = now.getTime() - lookbackDays * MS_DAY;
  const resolvedInWindow = resolvedAlerts.filter((alert) => {
    const resolvedMs = parseDate(alert.resolvedAt);
    return resolvedMs != null && resolvedMs >= cutoff;
  });
  const mttrDays = resolvedInWindow.map((alert) => alert.mttrDays).filter((value) => Number.isFinite(value));
  return {
    open: {
      total: openAlerts.length,
      bySeverity,
      oldestOpenDays: round(oldest),
      staleDaysThreshold: thresholds.staleOpenDays,
      staleCount: stale.length,
      staleAlertNumbers: stale.map((alert) => alert.number).filter((value) => Number.isInteger(value)).sort((l, r) => l - r)
    },
    resolved: {
      lookbackDays,
      total: resolvedInWindow.length,
      mttrDays: {
        average: round(average(mttrDays)),
        p50: round(percentile(mttrDays, 0.5)),
        p90: round(percentile(mttrDays, 0.9)),
        max: round(mttrDays.length ? Math.max(...mttrDays) : null)
      }
    }
  };
}

export function evaluateSecurityBreaches(summary, thresholds = DEFAULT_THRESHOLDS) {
  const breaches = [];
  const maybeAdd = (code, actual, threshold, label) => {
    if (actual > threshold) breaches.push({ code, actual, threshold, message: `${label} ${actual} exceeds threshold ${threshold}` });
  };
  maybeAdd('open-critical', summary?.open?.bySeverity?.critical ?? 0, thresholds.openCriticalMax, 'openCritical');
  maybeAdd('open-high', summary?.open?.bySeverity?.high ?? 0, thresholds.openHighMax, 'openHigh');
  maybeAdd('open-moderate', summary?.open?.bySeverity?.moderate ?? 0, thresholds.openModerateMax, 'openModerate');
  maybeAdd('stale-open-count', summary?.open?.staleCount ?? 0, thresholds.staleOpenCountMax, 'staleOpenCount');
  const mttrAverage = summary?.resolved?.mttrDays?.average;
  if (Number.isFinite(mttrAverage) && mttrAverage > thresholds.mttrDaysMax) {
    breaches.push({ code: 'mttr-days', actual: mttrAverage, threshold: thresholds.mttrDaysMax, message: `mttrDays ${mttrAverage} exceeds threshold ${thresholds.mttrDaysMax}` });
  }
  return breaches.sort((l, r) => l.code.localeCompare(r.code));
}

export function evaluateOverride(options = {}, now = new Date()) {
  const owner = asOptional(options.overrideOwner);
  const reason = asOptional(options.overrideReason);
  const expiresAt = asOptional(options.overrideExpiresAt);
  const ticket = asOptional(options.overrideTicket);
  const provided = Boolean(owner || reason || expiresAt || ticket);
  if (!provided) return { provided: false, active: false, owner: null, reason: null, expiresAt: null, ticket: null, validationErrors: [] };
  const errors = [];
  if (!owner) errors.push('owner-missing');
  if (!reason) errors.push('reason-missing');
  if (!expiresAt) errors.push('expires-at-missing');
  const expiresMs = parseDate(expiresAt);
  if (expiresAt && expiresMs == null) errors.push('expires-at-invalid');
  if (expiresMs != null && expiresMs <= now.getTime()) errors.push('expires-at-not-future');
  return { provided: true, active: errors.length === 0, owner, reason, expiresAt, ticket, validationErrors: errors };
}

export function buildRemediationCandidates(openAlerts = []) {
  const rank = { unknown: 0, low: 1, moderate: 2, high: 3, critical: 4 };
  return [...openAlerts]
    .filter((alert) => rank[severity(alert.severity)] >= 2)
    .sort((l, r) => (rank[severity(r.severity)] - rank[severity(l.severity)]) || ((r.ageDays || -1) - (l.ageDays || -1)) || ((l.number || 9e9) - (r.number || 9e9)))
    .map((alert) => ({
      number: alert.number,
      severity: alert.severity,
      packageName: alert.packageName,
      ecosystem: alert.ecosystem,
      manifestPath: alert.manifestPath,
      ageDays: alert.ageDays,
      url: alert.url
    }));
}

function writeJson(filePath, payload) {
  const absolute = path.resolve(filePath);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  fs.writeFileSync(absolute, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return absolute;
}

function toError(error, code) {
  const entry = { code, message: String(error?.message || error || 'unknown') };
  if (Number.isFinite(error?.status)) entry.status = error.status;
  if (error?.url) entry.url = String(error.url);
  return entry;
}

function isAuthError(error) {
  return [401, 403, 404].includes(Number(error?.status));
}

export async function upsertRemediationIssue({ repo, token, report, titlePrefix = DEFAULT_ROUTE_TITLE_PREFIX, labels = DEFAULT_ROUTE_LABELS, fetchImpl = globalThis.fetch }) {
  const routeLabels = normalizeLabels(labels.join(','));
  const listUrl = `https://api.github.com/repos/${repo}/issues?state=open&labels=${encodeURIComponent(routeLabels.join(','))}&per_page=100`;
  const openIssues = await requestGitHubJson(listUrl, { token, fetchImpl });
  const existing = Array.isArray(openIssues) ? openIssues.find((issue) => String(issue.title || '').trim() === titlePrefix) : null;
  const bodyLines = [
    '## Security intake breach',
    '',
    `Generated: ${report.generatedAt}`,
    `Repository: ${report.repository}`,
    '',
    '### Breaches',
    ...(report.breaches.length ? report.breaches.map((item) => `- ${item.code}: ${item.message}`) : ['- none']),
    '',
    `Open total: ${report.summary.open.total}`,
    `Critical: ${report.summary.open.bySeverity.critical}`,
    `High: ${report.summary.open.bySeverity.high}`,
    `Moderate: ${report.summary.open.bySeverity.moderate}`,
    `Stale>${report.summary.open.staleDaysThreshold}d: ${report.summary.open.staleCount}`,
    '',
    'Artifact: `tests/results/_agent/security/security-intake-report.json`'
  ];
  const body = bodyLines.join('\n');
  if (existing) {
    const updated = await requestGitHubJson(`https://api.github.com/repos/${repo}/issues/${existing.number}`, {
      token,
      method: 'PATCH',
      body: { title: titlePrefix, body, labels: routeLabels },
      fetchImpl
    });
    return { action: 'updated', issueNumber: updated?.number || existing.number, issueUrl: updated?.html_url || existing.html_url || null, title: titlePrefix, labels: routeLabels };
  }
  const created = await requestGitHubJson(`https://api.github.com/repos/${repo}/issues`, {
    token,
    method: 'POST',
    body: { title: titlePrefix, body, labels: routeLabels },
    fetchImpl
  });
  return { action: 'created', issueNumber: created?.number || null, issueUrl: created?.html_url || null, title: titlePrefix, labels: routeLabels };
}

export async function runSecurityIntake(rawOptions = {}, deps = {}) {
  const now = deps.now instanceof Date ? deps.now : new Date();
  const options = {
    repo: asOptional(rawOptions.repo),
    outputPath: rawOptions.outputPath || DEFAULT_OUTPUT_PATH,
    lookbackDays: Number.isFinite(rawOptions.lookbackDays) ? rawOptions.lookbackDays : DEFAULT_LOOKBACK_DAYS,
    maxPages: Number.isFinite(rawOptions.maxPages) ? rawOptions.maxPages : DEFAULT_MAX_PAGES,
    routeOnBreach: Boolean(rawOptions.routeOnBreach),
    routeTitlePrefix: rawOptions.routeTitlePrefix || DEFAULT_ROUTE_TITLE_PREFIX,
    failOnBreach: Boolean(rawOptions.failOnBreach),
    failOnSkip: Boolean(rawOptions.failOnSkip),
    overrideOwner: asOptional(rawOptions.overrideOwner),
    overrideReason: asOptional(rawOptions.overrideReason),
    overrideExpiresAt: asOptional(rawOptions.overrideExpiresAt),
    overrideTicket: asOptional(rawOptions.overrideTicket),
    thresholds: { ...DEFAULT_THRESHOLDS, ...(rawOptions.thresholds || {}) },
    routeLabels: normalizeLabels((rawOptions.routeLabels || DEFAULT_ROUTE_LABELS).join(','))
  };
  const resolveRepo = deps.resolveRepositorySlugFn || resolveRepositorySlug;
  const resolveAuth = deps.resolveTokenFn || resolveToken;
  const listAlerts = deps.listDependabotAlertsFn || listDependabotAlerts;
  const routeIssue = deps.upsertRemediationIssueFn || upsertRemediationIssue;
  const writeReport = deps.writeJsonFn || writeJson;
  const repository = resolveRepo(options.repo);
  const override = evaluateOverride(options, now);
  const base = {
    schema: 'priority/security-intake@v1',
    generatedAt: now.toISOString(),
    repository,
    flags: {
      routeOnBreach: Boolean(options.routeOnBreach),
      failOnBreach: Boolean(options.failOnBreach),
      failOnSkip: Boolean(options.failOnSkip),
      lookbackDays: options.lookbackDays,
      maxPages: options.maxPages
    },
    thresholds: { ...options.thresholds },
    override,
    source: { dependabot: { sampledStates: ['open', 'fixed', 'dismissed', 'auto_dismissed'], openCount: 0, resolvedCount: 0 } },
    summary: {
      open: { total: 0, bySeverity: { critical: 0, high: 0, moderate: 0, low: 0, unknown: 0 }, oldestOpenDays: 0, staleDaysThreshold: options.thresholds.staleOpenDays, staleCount: 0, staleAlertNumbers: [] },
      resolved: { lookbackDays: options.lookbackDays, total: 0, mttrDays: { average: null, p50: null, p90: null, max: null } }
    },
    breaches: [],
    remediation: { candidateCount: 0, candidates: [] },
    route: { action: 'none', issueNumber: null, issueUrl: null, title: options.routeTitlePrefix, labels: options.routeLabels },
    status: 'pass',
    errors: []
  };

  let token;
  try {
    token = resolveAuth();
  } catch (error) {
    const report = { ...base, status: 'skip', errors: [toError(error, 'token-unavailable')] };
    const reportPath = writeReport(options.outputPath, report);
    console.log(`[security-intake] report: ${reportPath}`);
    return { exitCode: options.failOnSkip ? 1 : 0, report };
  }

  try {
    const fetchImpl = deps.fetchImpl;
    const openRaw = await listAlerts({ repo: repository, token, state: 'open', maxPages: options.maxPages, fetchImpl });
    const fixedRaw = await listAlerts({ repo: repository, token, state: 'fixed', maxPages: options.maxPages, fetchImpl });
    const dismissedRaw = await listAlerts({ repo: repository, token, state: 'dismissed', maxPages: options.maxPages, fetchImpl });
    const autoDismissedRaw = await listAlerts({ repo: repository, token, state: 'auto_dismissed', maxPages: options.maxPages, fetchImpl });
    const openAlerts = openRaw.map((item) => normalizeDependabotAlert(item, now));
    const resolvedAlerts = [...fixedRaw, ...dismissedRaw, ...autoDismissedRaw].map((item) => normalizeDependabotAlert(item, now));
    const summary = summarizeDependabotAlerts({
      openAlerts,
      resolvedAlerts,
      thresholds: options.thresholds,
      lookbackDays: options.lookbackDays,
      now
    });
    const breaches = evaluateSecurityBreaches(summary, options.thresholds);
    const candidates = buildRemediationCandidates(openAlerts);
    const report = {
      ...base,
      source: { dependabot: { sampledStates: ['open', 'fixed', 'dismissed', 'auto_dismissed'], openCount: openAlerts.length, resolvedCount: resolvedAlerts.length } },
      summary,
      breaches,
      remediation: { candidateCount: candidates.length, candidates }
    };

    if (options.routeOnBreach && breaches.length) {
      const routed = await routeIssue({
        repo: repository,
        token,
        report,
        titlePrefix: options.routeTitlePrefix,
        labels: options.routeLabels,
        fetchImpl: deps.fetchImpl
      });
      report.route = {
        action: routed.action || 'none',
        issueNumber: Number.isFinite(routed.issueNumber) ? routed.issueNumber : null,
        issueUrl: routed.issueUrl || null,
        title: routed.title || options.routeTitlePrefix,
        labels: Array.isArray(routed.labels) ? routed.labels : options.routeLabels
      };
    }

    let exitCode = 0;
    if (breaches.length) {
      if (override.active) report.status = 'overridden';
      else if (options.failOnBreach) {
        report.status = 'breach';
        exitCode = 2;
      } else {
        report.status = 'breach';
      }
    }
    const reportPath = writeReport(options.outputPath, report);
    console.log(`[security-intake] report: ${reportPath}`);
    if (report.route.action !== 'none') {
      console.log(`[security-intake] remediation issue ${report.route.action}: #${report.route.issueNumber ?? '?'} ${report.route.issueUrl ?? ''}`.trim());
    }
    if (exitCode) console.error(`Security intake breach detected (${repository}): ${breaches.map((item) => item.code).join(', ')}`);
    return { exitCode, report };
  } catch (error) {
    const skip = isAuthError(error);
    const report = { ...base, status: skip ? 'skip' : 'error', errors: [toError(error, skip ? 'auth-or-permission-unavailable' : 'intake-failure')] };
    const reportPath = writeReport(options.outputPath, report);
    console.log(`[security-intake] report: ${reportPath}`);
    return { exitCode: skip ? (options.failOnSkip ? 1 : 0) : 1, report };
  }
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv);
  } catch (error) {
    console.error(error.message || String(error));
    printHelp(console.error);
    process.exitCode = 1;
    return;
  }
  if (options.help) {
    printHelp();
    return;
  }
  const result = await runSecurityIntake(options);
  process.exitCode = result.exitCode;
}

const ENTRY_FILE = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === ENTRY_FILE) {
  main().catch((error) => {
    console.error(error.stack || error.message || String(error));
    process.exitCode = 1;
  });
}

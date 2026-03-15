#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { ProxyAgent } from 'undici';
import { resolveActiveForkRemoteName } from './lib/remote-utils.mjs';

const USER_AGENT = 'compare-vi-cli-action/priority-sync';
const PROXY_AGENT_CACHE = new Map();
let GH_AUTH_TOKEN_CACHE;
let WARNED_NO_GITHUB_TOKEN_FOR_REST = false;
const DEFAULT_STANDING_PRIORITY_LABEL = 'standing-priority';
const FORK_STANDING_PRIORITY_LABEL = 'fork-standing-priority';
const MODULE_FILE_PATH = fileURLToPath(import.meta.url);
const MODULE_REPO_ROOT = path.resolve(path.dirname(MODULE_FILE_PATH), '../..');
const NO_STANDING_REPORT_FILENAME = 'no-standing-priority.json';
const MULTIPLE_STANDING_REPORT_FILENAME = 'multiple-standing-priority.json';
const AUTO_SELECT_EXCLUDED_LABELS = new Set(['duplicate', 'invalid', 'wontfix']);

const CLI_USAGE_LINES = [
  'Usage: node tools/priority/sync-standing-priority.mjs [options]',
  '',
  'Options:',
  '  --fail-on-missing   Exit non-zero when no standing-priority issue is found.',
  '  --fail-on-multiple  Exit non-zero when multiple open standing-priority issues are found.',
  '  --auto-select-next  When no standing issue exists, auto-label the next open issue as standing-priority.',
  '  --materialize-cache Persist .agent_priority_cache.json even when absent.',
  '  -h, --help          Show this help text and exit.'
];

export function parseCliArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    failOnMissing: false,
    failOnMultiple: false,
    autoSelectNext: false,
    materializeCache: false,
    help: false
  };

  for (const arg of args) {
    if (arg === '--fail-on-missing') {
      options.failOnMissing = true;
      continue;
    }
    if (arg === '--fail-on-multiple') {
      options.failOnMultiple = true;
      continue;
    }
    if (arg === '--auto-select-next') {
      options.autoSelectNext = true;
      continue;
    }
    if (arg === '--materialize-cache') {
      options.materializeCache = true;
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return options;
}

function printCliUsage(log = console.log) {
  for (const line of CLI_USAGE_LINES) {
    log(line);
  }
}

function normalizeStandingPriorityLabels(values) {
  const seen = new Set();
  const labels = [];
  for (const value of values || []) {
    if (value == null) continue;
    const label = String(value).trim().toLowerCase();
    if (!label || seen.has(label)) continue;
    seen.add(label);
    labels.push(label);
  }
  return labels;
}

function formatStandingPriorityLabels(labels) {
  return (labels || []).map((label) => `\`${label}\``).join(', ');
}

function normalizeBooleanValue(value) {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value !== 'string') {
    return false;
  }
  const normalized = value.trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on';
}

function parsePriorityOrdinal(title) {
  const match = String(title || '').match(/\[\s*p(?<priority>\d+)\s*\]/i);
  if (!match?.groups?.priority) {
    return 9;
  }
  const parsed = Number.parseInt(match.groups.priority, 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return 9;
  }
  return parsed;
}

function isEpicTitle(title) {
  return /^\s*epic\s*:/i.test(String(title || ''));
}

function hasChildTracksSection(body) {
  return /(^|\n)##\s*child\s*tracks\b/i.test(String(body || ''));
}

function isCadenceAlertIssue(title, body) {
  return (
    /^\s*\[cadence\]\b/i.test(String(title || '')) ||
    /<!--\s*cadence-check:/i.test(String(body || ''))
  );
}

function hasCompareviWorkflowScopeSignal(title, body) {
  const titleText = String(title || '');
  const bodyText = String(body || '');
  const combinedText = `${titleText}\n${bodyText}`;

  const hasCompareviSignal = /comparevi-history|compare-vi-cli-action/i.test(combinedText);
  const hasRolloutActionSignal = /\b(land|add|route|wire|enable|validate|prove|dispatch|capture|confirm|reconcile|rebase|review)\b/i.test(
    combinedText
  );
  const hasDiagnosticsSignal = /\bdiagnostics\b|diagnostics workflows?|workflow shape|workflow files|reviewer-facing diagnostics/i.test(
    combinedText
  );
  const hasReleaseSignal = /released refs?|released comparevi-history|released compare-vi-cli-action/i.test(combinedText);
  const hasTopologySignal = /fork-ready|fork-safe|downstream forks?|upstream-aligned|canonical upstream|pr head repo\/ref dynamically|fork-authored pr/i.test(
    combinedText
  );
  const hasTrackerSignal = /(?:Parent epic:|epic)\s*#930|comparevi-history#23/i.test(combinedText);
  const hasDemoMaintenanceSignal =
    /\b(readme|release notes|icon editor assets?|asset work|asset refresh|editor development|screenshot context)\b/i.test(
      combinedText
    ) ||
    /\b(?:refresh|update|maint(?:ain|enance)|cleanup)\b.*\b(?:docs|documentation)\b|\b(?:docs|documentation)\b.*\b(?:refresh|update|maint(?:ain|enance)|cleanup)\b/i.test(
      combinedText
    );

  if (hasDemoMaintenanceSignal) {
    return false;
  }

  const rolloutSignalCount = [hasRolloutActionSignal, hasDiagnosticsSignal, hasReleaseSignal, hasTopologySignal, hasTrackerSignal]
    .filter(Boolean)
    .length;
  return hasCompareviSignal && rolloutSignalCount >= 3 && (hasTopologySignal || hasTrackerSignal);
}

function isOutOfScopeStandingCandidate(title, body) {
  const text = `${String(title || '')}\n${String(body || '')}`;
  if (!/labview-icon-editor-demo|labview icon editor demo|icon[- ]editor demo/i.test(text)) {
    return false;
  }

  if (hasCompareviWorkflowScopeSignal(title, body)) {
    return false;
  }

  return true;
}

function normalizeCommentBodies(comments) {
  if (!Array.isArray(comments)) {
    return [];
  }
  return comments
    .map((entry) => {
      if (typeof entry === 'string') {
        return entry.trim();
      }
      return typeof entry?.body === 'string' ? entry.body.trim() : '';
    })
    .filter(Boolean);
}

function splitStandingClauses(value) {
  return String(value || '')
    .split(/[\n.;]+/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function hasAffirmativeExternalBlockClause(value) {
  return splitStandingClauses(value).some((clause) => {
    if (!/\bcomparevi-history#23\b/i.test(clause)) {
      return false;
    }
    const hasAffirmativeBlockSignal =
      /\bexternally blocked on\b/i.test(clause) ||
      /\bblocked by\b/i.test(clause) ||
      /\bprimary downstream blocker\b/i.test(clause);
    if (!hasAffirmativeBlockSignal) {
      return false;
    }
    const hasNegatedOrHistoricalSignal =
      /\b(?:no longer|not|never|previously|formerly)\s+(?:externally blocked on|blocked by)\b/i.test(clause) ||
      /\b(?:was|were)\s+(?:externally blocked on|blocked by)\b/i.test(clause) ||
      /\b(?:no longer|not|never|previously|formerly)\b[^]{0,40}\bprimary downstream blocker\b/i.test(clause) ||
      /\b(?:was|were)\b[^]{0,40}\bprimary downstream blocker\b/i.test(clause);
    return !hasNegatedOrHistoricalSignal;
  });
}

function mayNeedBlockedStandingHydration(title, body) {
  return /\bcomparevi-history#23\b/i.test(`${String(title || '')}\n${String(body || '')}`);
}

function isBlockedStandingCandidate(title, body, comments = []) {
  const bodyText = `${String(title || '')}\n${String(body || '')}`;
  const commentBodies = normalizeCommentBodies(comments);
  const commentText = commentBodies.join('\n');
  const hasExternalDependency = /comparevi-history#23/i.test(`${bodyText}\n${commentText}`);
  if (!hasExternalDependency) {
    return false;
  }

  const hasBodyLevelExternalBlock = hasAffirmativeExternalBlockClause(bodyText);
  const hasCommentLevelStandingDemotion = commentBodies.some(
    (comment) =>
      /\bcomparevi-history#23\b/i.test(comment) &&
      (/\bstanding-priority moved away\b/i.test(comment) || /\bno longer the top actionable coding lane\b/i.test(comment))
  );

  return hasBodyLevelExternalBlock || hasCommentLevelStandingDemotion;
}

function parseDateMs(value) {
  if (!value) {
    return Number.POSITIVE_INFINITY;
  }
  const parsed = Date.parse(String(value));
  return Number.isFinite(parsed) ? parsed : Number.POSITIVE_INFINITY;
}

function normalizeOpenIssueCandidate(entry) {
  if (!entry) {
    return null;
  }
  const number = Number(entry.number);
  if (!Number.isInteger(number) || number <= 0) {
    return null;
  }

  const labels = normalizeList((entry.labels || []).map((label) => label?.name || label));
  const excluded = labels.some((label) => AUTO_SELECT_EXCLUDED_LABELS.has(String(label).toLowerCase()));

  const title = typeof entry.title === 'string' ? entry.title.trim() : '';
  const body = typeof entry.body === 'string' ? entry.body : '';
  const commentBodies = normalizeCommentBodies(
    Array.isArray(entry.commentBodies) ? entry.commentBodies : entry.comments
  );
  return {
    number,
    title,
    labels,
    body,
    commentBodies,
    createdAt: entry.createdAt || entry.created_at || null,
    updatedAt: entry.updatedAt || entry.updated_at || null,
    url: entry.html_url || entry.url || null,
    priority: parsePriorityOrdinal(title),
    excluded,
    epic: isEpicTitle(title),
    umbrella: hasChildTracksSection(body),
    cadence: isCadenceAlertIssue(title, body),
    outOfScope: isOutOfScopeStandingCandidate(title, body),
    blocked: isBlockedStandingCandidate(title, body, commentBodies)
  };
}

function hasOnlyIneligibleOpenIssues(entries = []) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return false;
  }

  let sawCandidate = false;
  const onlyIneligibleCandidates = entries.every((entry) => {
    const normalized = normalizeOpenIssueCandidate(entry);
    if (!normalized) {
      return false;
    }
    sawCandidate = true;
    return normalized.outOfScope || (!normalized.excluded && normalized.blocked);
  });

  return sawCandidate && onlyIneligibleCandidates;
}

export function selectAutoStandingPriorityCandidate(entries = [], options = {}) {
  const excludedIssueNumbers = new Set(
    Array.isArray(options.excludeIssueNumbers)
      ? options.excludeIssueNumbers
          .map((value) => Number(value))
          .filter((value) => Number.isInteger(value) && value > 0)
      : []
  );
  const normalized = entries
    .map((entry) => normalizeOpenIssueCandidate(entry))
    .filter((entry) => entry && !entry.excluded && !excludedIssueNumbers.has(entry.number) && !entry.outOfScope && !entry.blocked);
  if (normalized.length === 0) {
    return null;
  }

  const nonCadence = normalized.filter((entry) => !entry.cadence);
  const cadencePool = nonCadence.length > 0 ? nonCadence : normalized;
  const nonEpic = cadencePool.filter((entry) => !entry.epic);
  const nonUmbrella = nonEpic.filter((entry) => !entry.umbrella);
  const nonProgram = nonUmbrella.filter((entry) => !entry.labels.includes('program'));
  const pool =
    nonProgram.length > 0
      ? nonProgram
      : nonUmbrella.length > 0
        ? nonUmbrella
        : nonEpic.length > 0
          ? nonEpic
          : normalized;

  pool.sort((left, right) => {
    if (left.priority !== right.priority) {
      return left.priority - right.priority;
    }
    const leftCreated = parseDateMs(left.createdAt);
    const rightCreated = parseDateMs(right.createdAt);
    if (leftCreated !== rightCreated) {
      return leftCreated - rightCreated;
    }
    const leftUpdated = parseDateMs(left.updatedAt);
    const rightUpdated = parseDateMs(right.updatedAt);
    if (leftUpdated !== rightUpdated) {
      return leftUpdated - rightUpdated;
    }
    return left.number - right.number;
  });

  return pool[0];
}

export async function selectAutoStandingPriorityCandidateForRepo(
  repoRoot,
  slug,
  entries = [],
  options = {}
) {
  const excludedIssueNumbers = new Set(
    Array.isArray(options.excludeIssueNumbers)
      ? options.excludeIssueNumbers
          .map((value) => Number(value))
          .filter((value) => Number.isInteger(value) && value > 0)
      : []
  );
  const candidateEntries = Array.isArray(entries)
    ? entries.filter((entry) => !excludedIssueNumbers.has(Number(entry?.number)))
    : [];
  const enrichedIssues = await enrichOpenIssuesForStandingSelection(repoRoot, slug, candidateEntries, options);
  return selectAutoStandingPriorityCandidate(enrichedIssues, options);
}

function toUrl(input) {
  if (!input) return null;
  if (input instanceof URL) return input;
  try {
    return new URL(String(input));
  } catch {
    return null;
  }
}

function defaultPortForProtocol(protocol) {
  if (protocol === 'http:') return '80';
  if (protocol === 'https:') return '443';
  return '';
}

function parseNoProxyList(value) {
  if (!value) return [];
  return value
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => entry.toLowerCase());
}

function extractHostAndPort(pattern) {
  if (!pattern) return { host: '', port: null };
  let host = pattern;
  let port = null;

  if (host.startsWith('[')) {
    const closing = host.indexOf(']');
    if (closing !== -1) {
      const remainder = host.slice(closing + 1);
      if (remainder.startsWith(':')) {
        port = remainder.slice(1);
      }
      host = host.slice(1, closing);
    }
  } else {
    const parts = host.split(':');
    if (parts.length === 2) {
      host = parts[0];
      port = parts[1];
    }
  }

  return { host: host.toLowerCase(), port: port ? port.trim() : null };
}

export function shouldBypassProxy(target) {
  const url = toUrl(target);
  if (!url) return false;

  const rawNoProxy = process.env.NO_PROXY || process.env.no_proxy;
  const entries = parseNoProxyList(rawNoProxy);
  if (entries.length === 0) return false;

  let hostname = url.hostname.toLowerCase();
  if (hostname.startsWith('[') && hostname.endsWith(']')) {
    hostname = hostname.slice(1, -1);
  }
  const port = url.port || defaultPortForProtocol(url.protocol);

  for (const entry of entries) {
    if (entry === '*') {
      return true;
    }

    const { host: patternHost, port: patternPort } = extractHostAndPort(entry);
    if (!patternHost) continue;

    if (patternPort && patternPort !== port) {
      continue;
    }

    if (patternHost.startsWith('.')) {
      const suffix = patternHost.slice(1);
      if (!suffix) continue;
      if (hostname === suffix || hostname.endsWith(`.${suffix}`)) {
        return true;
      }
      continue;
    }

    if (hostname === patternHost) {
      return true;
    }

    if (hostname.endsWith(`.${patternHost}`)) {
      return true;
    }
  }

  return false;
}

export function resolveProxyUrl(target) {
  const url = toUrl(target);
  if (!url) return null;
  if (shouldBypassProxy(url)) return null;

  const protocol = url.protocol;
  const candidates =
    protocol === 'http:'
      ? ['HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy']
      : protocol === 'https:'
        ? ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy']
        : ['ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy'];

  for (const key of candidates) {
    const value = process.env[key];
    if (value && value.trim()) {
      return value.trim();
    }
  }

  return null;
}

function getProxyDispatcher(target) {
  const proxyUrl = resolveProxyUrl(target);
  if (!proxyUrl) return null;
  if (!PROXY_AGENT_CACHE.has(proxyUrl)) {
    PROXY_AGENT_CACHE.set(proxyUrl, new ProxyAgent(proxyUrl));
  }
  return PROXY_AGENT_CACHE.get(proxyUrl);
}

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', shell: false, ...opts });
}

function ensureCommand(result, cmd) {
  if (result?.error?.code === 'ENOENT') {
    const err = new Error(`Command not found: ${cmd}`);
    err.code = 'ENOENT';
    throw err;
  }
  return result;
}

function formatCommandFailure(command, args, result, cwd = process.cwd()) {
  const parts = [`${command} ${args.join(' ')} failed`];
  if (Number.isInteger(result?.status)) {
    parts.push(`status=${result.status}`);
  }
  if (result?.error?.code) {
    parts.push(`error=${result.error.code}`);
  }
  const stderr = (result?.stderr || '').trim();
  if (stderr) {
    parts.push(`stderr=${stderr}`);
  }
  parts.push(`cwd=${cwd}`);
  return parts.join(' ');
}

function hasRepoMarkers(candidateRoot) {
  if (!candidateRoot) {
    return false;
  }
  return fs.existsSync(path.join(candidateRoot, '.git')) || fs.existsSync(path.join(candidateRoot, 'package.json'));
}

function resolveGitDir(repoRoot) {
  const dotGitPath = path.join(repoRoot, '.git');
  try {
    const stats = fs.statSync(dotGitPath);
    if (stats.isDirectory()) {
      return dotGitPath;
    }
    if (stats.isFile()) {
      const marker = fs.readFileSync(dotGitPath, 'utf8');
      const match = marker.match(/^gitdir:\s*(.+)$/im);
      if (match?.[1]) {
        return path.resolve(repoRoot, match[1].trim());
      }
    }
  } catch {}
  return null;
}

function readGitConfigText(repoRoot) {
  const gitDir = resolveGitDir(repoRoot);
  if (!gitDir) {
    return null;
  }
  const configPath = path.join(gitDir, 'config');
  try {
    return fs.readFileSync(configPath, 'utf8');
  } catch {
    return null;
  }
}

function parseGitConfigRemotes(configText) {
  if (!configText) {
    return {};
  }

  const remotes = {};
  let currentRemote = null;
  for (const rawLine of String(configText).split(/\r?\n/)) {
    const line = rawLine.trim();
    const remoteMatch = line.match(/^\[remote\s+"([^"]+)"\]$/i);
    if (remoteMatch) {
      currentRemote = remoteMatch[1];
      if (!remotes[currentRemote]) {
        remotes[currentRemote] = {};
      }
      continue;
    }

    if (line.startsWith('[')) {
      currentRemote = null;
      continue;
    }

    if (!currentRemote) {
      continue;
    }

    const kv = line.match(/^([A-Za-z][A-Za-z0-9_.-]*)\s*=\s*(.+)$/);
    if (!kv) {
      continue;
    }

    remotes[currentRemote][kv[1].toLowerCase()] = kv[2].trim();
  }

  return remotes;
}

function resolveGitRemoteUrl(repoRoot, remoteName) {
  const configText = readGitConfigText(repoRoot);
  if (configText != null) {
    const remotes = parseGitConfigRemotes(configText);
    const remote = remotes?.[remoteName];
    const configUrl = remote?.url;
    return configUrl || null;
  }

  const remote = sh('git', ['config', '--get', `remote.${remoteName}.url`]);
  if (remote.status === 0) {
    const value = String(remote.stdout || '').trim();
    if (value) {
      return value;
    }
  }
  return null;
}

export function gitRoot(options = {}) {
  const commandRunner = options.commandRunner ?? sh;
  const cwd = options.cwd ?? process.cwd();
  const fallbackRoot = options.fallbackRoot ?? MODULE_REPO_ROOT;
  const warn = options.warn ?? ((message) => console.warn(message));

  const result = commandRunner('git', ['rev-parse', '--show-toplevel'], { cwd });
  if (result?.status === 0) {
    const root = String(result.stdout || '').trim();
    if (root) {
      return root;
    }
  }

  if (hasRepoMarkers(fallbackRoot)) {
    warn(`[priority] ${formatCommandFailure('git', ['rev-parse', '--show-toplevel'], result, cwd)}; using module fallback ${fallbackRoot}`);
    return fallbackRoot;
  }

  throw new Error(formatCommandFailure('git', ['rev-parse', '--show-toplevel'], result, cwd));
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

export function shouldWriteJsonFile(file, nextObject) {
  const currentObject = readJson(file);
  if (currentObject == null) {
    return true;
  }
  return !isDeepStrictEqual(currentObject, nextObject);
}

export function writeJson(file, obj, options = {}) {
  const force = Boolean(options.force);
  if (!force && !shouldWriteJsonFile(file, obj)) {
    return false;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n', 'utf8');
  return true;
}

function loadSnapshot(repoRoot, number) {
  if (!number) return null;
  const snapshotPath = path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'issue',
    `${number}.json`
  );
  return readJson(snapshotPath);
}

export function hashObject(value) {
  const payload = typeof value === 'string' ? value : JSON.stringify(value);
  return crypto.createHash('sha256').update(payload).digest('hex');
}

function normalizeList(values) {
  const seen = new Set();
  const normalized = [];
  for (const value of values || []) {
    if (value == null) continue;
    const text = String(value).trim();
    if (!text) continue;
    const key = text.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    normalized.push(key);
  }
  return normalized.sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
}

function summarizeStatusCheckRollup(rollup) {
  if (!Array.isArray(rollup)) return null;
  return rollup
    .filter(Boolean)
    .map((check) => ({
      name: check.name ?? null,
      status: check.status ?? null,
      conclusion: check.conclusion ?? null,
      url: check.detailsUrl ?? null
    }));
}

export function createSnapshot(issue) {
  const labels = normalizeList(issue.labels);
  const assignees = normalizeList(issue.assignees);
  const milestone = issue.milestone != null ? String(issue.milestone) : null;
  const commentCount = issue.commentCount != null ? Number(issue.commentCount) : null;
  const bodyDigest = issue.body ? hashObject(String(issue.body)) : null;
  const mirrorOf = parseUpstreamIssuePointerFromBody(issue.body);
  const digestInput = {
    number: issue.number,
    title: issue.title ?? null,
    state: issue.state ?? null,
    updatedAt: issue.updatedAt ?? null,
    labels,
    assignees,
    milestone: milestone ? milestone.toLowerCase() : null,
    commentCount,
    mirrorOf
  };
  const digest = hashObject(digestInput);
  return {
    schema: 'standing-priority/issue@v1',
    number: issue.number,
    title: issue.title ?? null,
    state: issue.state ?? null,
    updatedAt: issue.updatedAt ?? null,
    url: issue.url ?? null,
    labels,
    assignees,
    milestone,
    commentCount,
    bodyDigest,
    mirrorOf,
    digest
  };
}

export function collectReleaseArtifacts(repoRoot) {
  const dir = path.join(repoRoot, 'tests', 'results', '_agent', 'release');
  if (!fs.existsSync(dir)) return [];

  const artifacts = [];
  for (const entry of fs.readdirSync(dir)) {
    if (!entry.endsWith('.json')) continue;
    if (entry.includes('-dryrun')) continue;

    const filePath = path.join(dir, entry);
    try {
      const raw = fs.readFileSync(filePath, 'utf8');
      const data = JSON.parse(raw);
      const match = entry.match(/release-(.+)-(branch|finalize)\.json$/);
      const tag = data.version ?? data.tag ?? (match ? match[1] : null);
      const kind = match ? match[2] : data.schema?.includes('finalize') ? 'finalize' : 'branch';
      const timestamp = data.completedAt ?? data.createdAt ?? null;
      const pullRequestData = data.pullRequest ?? null;
      artifacts.push({
        file: path.relative(repoRoot, filePath).replace(/\\/g, '/'),
        tag,
        kind,
        branch: data.branch ?? data.releaseBranch ?? null,
        releaseCommit: data.releaseCommit ?? null,
        mainCommit: data.mainCommit ?? null,
        developCommit: data.developCommit ?? null,
        timestamp,
        pullRequest: pullRequestData
          ? {
              number: pullRequestData.number ?? null,
              url: pullRequestData.url ?? null,
              mergeStateStatus: pullRequestData.mergeStateStatus ?? null,
              checks:
                pullRequestData.checks ?? summarizeStatusCheckRollup(pullRequestData.statusCheckRollup ?? [])
            }
          : {
              number: data.pullRequestNumber ?? null,
              url: data.pullRequestUrl ?? null,
              mergeStateStatus: data.mergeStateStatus ?? null,
              checks: summarizeStatusCheckRollup(data.statusCheckRollup ?? [])
            }
      });
    } catch (err) {
      console.warn(`[priority] failed to parse release artifact ${entry}: ${err.message}`);
    }
  }

  artifacts.sort((a, b) => ((b.timestamp || '').localeCompare(a.timestamp || '')));
  return artifacts;
}

export function loadRoutingPolicy(repoRoot) {
  const policyPath = path.join(repoRoot, 'tools', 'policy', 'priority-label-routing.json');
  if (!fs.existsSync(policyPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  } catch (err) {
    console.warn(`[priority] Failed to parse priority-label-routing.json: ${err.message}`);
    return null;
  }
}

export function buildRouter(issue, policy) {
  const actionsMap = new Map();
  const addAction = (action) => {
    if (!action || !action.key) return;
    const key = action.key;
    const normalized = {
      key,
      priority: Number.isFinite(action.priority) ? action.priority : 50,
      scripts: Array.isArray(action.scripts) ? Array.from(new Set(action.scripts.filter(Boolean))) : [],
      rationale: action.rationale || action.reason || null
    };
    if (actionsMap.has(key)) {
      const existing = actionsMap.get(key);
      existing.priority = Math.min(existing.priority, normalized.priority);
      existing.scripts = Array.from(new Set([...existing.scripts, ...normalized.scripts]));
      if (!existing.rationale && normalized.rationale) existing.rationale = normalized.rationale;
    } else {
      actionsMap.set(key, normalized);
    }
  };

  addAction({ key: 'hooks:pre-commit', priority: 10, scripts: ['node tools/npm/run-script.mjs hooks:pre-commit'], rationale: 'baseline hook gate' });
  addAction({ key: 'hooks:multi', priority: 11, scripts: ['node tools/npm/run-script.mjs hooks:multi', 'node tools/npm/run-script.mjs hooks:schema'], rationale: 'ensure parity across planes' });
  addAction({ key: 'validate:dispatch', priority: 95, scripts: ['node tools/npm/run-script.mjs priority:validate'], rationale: 'dispatch Validate via upstream guard' });

  const labelSet = new Set((issue.labels || []).map((l) => (l || '').toLowerCase()));
  const policyEntries = Array.isArray(policy?.labels) ? policy.labels : [];
  let policyHits = 0;
  for (const entry of policyEntries) {
    if (!entry?.name || !Array.isArray(entry.actions)) continue;
    if (!labelSet.has(String(entry.name).toLowerCase())) continue;
    for (const action of entry.actions) {
      addAction(action);
    }
    policyHits += 1;
  }

  if (policyHits === 0) {
    if (labelSet.has('docs') || labelSet.has('documentation')) {
      addAction({ key: 'docs:lint', priority: 20, scripts: ['node tools/npm/run-script.mjs lint:md:changed'], rationale: 'docs label present' });
    }
    if (labelSet.has('ci')) {
      addAction({ key: 'ci:parity', priority: 30, scripts: ['node tools/npm/run-script.mjs hooks:multi', 'node tools/npm/run-script.mjs hooks:schema'], rationale: 'ci label present' });
    }
    if (labelSet.has('release')) {
      addAction({ key: 'release:prep', priority: 40, scripts: ['pwsh -File tools/Branch-Orchestrator.ps1 -DryRun'], rationale: 'release label present' });
    }
  }

  const releaseArtifacts = Array.isArray(issue.releaseArtifacts) ? issue.releaseArtifacts : [];
  if (labelSet.has('release')) {
    const hasBranchMetadata = releaseArtifacts.some((artifact) => artifact.kind === 'branch');
    if (!hasBranchMetadata) {
      addAction({
        key: 'release:branch',
        priority: 38,
        scripts: ['pwsh -Command "Write-Host Run node tools/npm/run-script.mjs release:branch -- <version>"'],
        rationale: 'release label present but no release branch metadata detected'
      });
    }
  }
  if (releaseArtifacts.length > 0) {
    const latestBranch = releaseArtifacts.find((artifact) => artifact.kind === 'branch');
    if (latestBranch) {
      const matchingFinalize = releaseArtifacts.find(
        (artifact) => artifact.kind === 'finalize' && artifact.tag === latestBranch.tag
      );
      if (!matchingFinalize) {
        addAction({
          key: 'release:finalize',
          priority: 35,
          scripts: [`node tools/npm/run-script.mjs release:finalize -- ${latestBranch.tag}`],
          rationale: `release ${latestBranch.tag} ready for finalize`
        });
      }
    }
  }

  addAction({ key: 'validate:lint', priority: 90, scripts: ['pwsh -File tools/PrePush-Checks.ps1'], rationale: 'baseline validation' });

  const actions = Array.from(actionsMap.values()).sort((a, b) => (a.priority ?? 50) - (b.priority ?? 50) || a.key.localeCompare(b.key));
  return {
    schema: 'agent/priority-router@v1',
    issue: issue.number,
    updatedAt: issue.updatedAt ?? null,
    actions
  };
}

export function parseGitRemoteUrl(remoteUrl) {
  if (!remoteUrl) return null;
  const trimmed = String(remoteUrl).trim();
  if (!trimmed) return null;

  const sanitized = trimmed.replace(/^git\+/i, '');

  const withoutGitSuffix = (slug) => slug.replace(/\.git$/i, '');

  const sshMatch = sanitized.match(/^git@[^:]+:(.+)$/i);
  if (sshMatch) {
    return withoutGitSuffix(sshMatch[1]);
  }

  try {
    const parsed = new URL(sanitized);
    if (parsed.hostname && parsed.pathname) {
      const slug = parsed.pathname.replace(/^\/+/, '');
      if (slug) return withoutGitSuffix(slug);
    }
  } catch {
    // Not a standard URL; fall back to simple heuristics below.
  }

  if (/^[^\/]+\/[\w.-]+$/i.test(trimmed)) {
    return withoutGitSuffix(trimmed);
  }

  return null;
}

function parseGitHubIssueUrlSlug(issueUrl) {
  if (!issueUrl) {
    return null;
  }

  try {
    const parsed = new URL(String(issueUrl));
    if (!parsed.hostname.toLowerCase().endsWith('github.com')) {
      return null;
    }

    const segments = parsed.pathname.split('/').filter(Boolean);
    if (segments.length < 4) {
      return null;
    }

    if (segments[2] !== 'issues') {
      return null;
    }

    return `${segments[0]}/${segments[1]}`;
  } catch {
    return null;
  }
}

export function parseUpstreamIssuePointerFromBody(body) {
  const match = String(body || '').match(
    /<!--\s*upstream-issue-url:\s*(https:\/\/github\.com\/(?<slug>[^/\s]+\/[^/\s]+)\/issues\/(?<number>\d+))\s*-->/i
  );
  if (!match?.groups?.slug || !match?.groups?.number) {
    return null;
  }
  const number = Number(match.groups.number);
  if (!Number.isInteger(number) || number <= 0) {
    return null;
  }
  return {
    repository: match.groups.slug,
    number,
    url: match[1]
  };
}

export function resolveRepositorySlug(repoRoot, env = process.env) {
  if (env.GITHUB_REPOSITORY) {
    const slug = env.GITHUB_REPOSITORY.trim();
    if (slug) return slug;
  }

  for (const remoteName of [resolveActiveForkRemoteName(env), 'origin', 'personal']) {
    const remoteUrl = resolveGitRemoteUrl(repoRoot, remoteName);
    if (remoteUrl) {
      const slug = parseGitRemoteUrl(remoteUrl);
      if (slug) return slug;
    }
  }

  const packagePath = path.join(repoRoot, 'package.json');
  try {
    const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
    const repository = pkg?.repository;
    const candidates = [];
    if (typeof repository === 'string') {
      candidates.push(repository);
    } else if (repository && typeof repository === 'object') {
      if (repository.url) candidates.push(repository.url);
      if (repository.path) candidates.push(repository.path);
      if (repository.directory) candidates.push(repository.directory);
    }
    for (const candidate of candidates) {
      const slug = parseGitRemoteUrl(candidate);
      if (slug) return slug;
    }
  } catch {}

  return null;
}

function normalizeRepositorySlug(slug) {
  return typeof slug === 'string' ? slug.trim().toLowerCase() : '';
}

function resolveConfiguredUpstreamRepositorySlug(env = process.env) {
  const candidates = [
    env.AGENT_PRIORITY_UPSTREAM_REPOSITORY,
    env.AGENT_UPSTREAM_REPOSITORY
  ];
  for (const candidate of candidates) {
    const parsed = parseGitRemoteUrl(candidate);
    if (parsed) {
      return parsed;
    }
  }
  return null;
}

export function resolveUpstreamRepositorySlug(repoRoot, slug, env = process.env) {
  const resolvedSlug = slug || resolveRepositorySlug(repoRoot, env);
  const normalizedResolvedSlug = normalizeRepositorySlug(resolvedSlug);

  const configuredUpstream = resolveConfiguredUpstreamRepositorySlug(env);
  if (configuredUpstream) {
    if (normalizeRepositorySlug(configuredUpstream) === normalizedResolvedSlug) {
      return null;
    }
    return configuredUpstream;
  }

  const upstreamUrl = resolveGitRemoteUrl(repoRoot, 'upstream');
  const upstreamSlug = parseGitRemoteUrl(upstreamUrl);
  if (upstreamSlug && normalizeRepositorySlug(upstreamSlug) !== normalizedResolvedSlug) {
    return upstreamSlug;
  }

  return null;
}

export function resolveStandingPriorityLabels(repoRoot, slug, env = process.env) {
  const explicit = env.AGENT_STANDING_PRIORITY_LABELS || env.AGENT_PRIORITY_LABELS;
  const explicitLabels = normalizeStandingPriorityLabels(
    explicit
      ? String(explicit)
          .split(',')
          .map((label) => label.trim())
      : []
  );
  if (explicitLabels.length > 0) {
    return explicitLabels;
  }

  const resolvedSlug = slug || resolveRepositorySlug(repoRoot, env);
  const upstreamSlug = resolveUpstreamRepositorySlug(repoRoot, resolvedSlug, env);
  if (
    upstreamSlug &&
    normalizeRepositorySlug(upstreamSlug) !== normalizeRepositorySlug(resolvedSlug)
  ) {
    return [FORK_STANDING_PRIORITY_LABEL, DEFAULT_STANDING_PRIORITY_LABEL];
  }

  return [DEFAULT_STANDING_PRIORITY_LABEL];
}

function normalizeTokenValue(value) {
  const normalized = typeof value === 'string' ? value.trim() : '';
  return normalized || null;
}

function resolveGitHubTokenViaGh() {
  if (GH_AUTH_TOKEN_CACHE !== undefined) {
    return GH_AUTH_TOKEN_CACHE;
  }

  try {
    const auth = ensureCommand(sh('gh', ['auth', 'token']), 'gh');
    if (auth.status === 0) {
      GH_AUTH_TOKEN_CACHE = normalizeTokenValue(auth.stdout);
      return GH_AUTH_TOKEN_CACHE;
    }
    GH_AUTH_TOKEN_CACHE = null;
    return null;
  } catch {
    GH_AUTH_TOKEN_CACHE = null;
    return null;
  }
}

export function resolveGitHubToken(options = {}) {
  const env = options.env ?? process.env;
  const tokenFromEnv = normalizeTokenValue(env.GH_TOKEN) || normalizeTokenValue(env.GITHUB_TOKEN);
  if (tokenFromEnv) {
    return tokenFromEnv;
  }

  if (typeof options.authTokenProvider === 'function') {
    return normalizeTokenValue(options.authTokenProvider());
  }

  return resolveGitHubTokenViaGh();
}

export function warnNoGitHubTokenForRestOnce() {
  if (WARNED_NO_GITHUB_TOKEN_FOR_REST) return;
  WARNED_NO_GITHUB_TOKEN_FOR_REST = true;
  console.warn('[priority] No GitHub token available for REST fallback; attempting unauthenticated request');
}

export function resetPrioritySyncTokenStateForTests() {
  GH_AUTH_TOKEN_CACHE = undefined;
  WARNED_NO_GITHUB_TOKEN_FOR_REST = false;
}

async function requestGitHubJson(url, token, options = {}) {
  const method = (options.method || 'GET').toUpperCase();
  const body = options.body;
  const extraHeaders = options.headers || {};
  const headers = {
    'User-Agent': USER_AGENT,
    Accept: 'application/vnd.github+json',
    ...extraHeaders
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined && !headers['Content-Type']) {
    headers['Content-Type'] = 'application/json';
  }

  if (typeof fetch !== 'function') {
    throw new Error('Global fetch API unavailable in this Node.js runtime');
  }

  const dispatcher = getProxyDispatcher(url);
  const requestOptions = dispatcher ? { method, headers, dispatcher } : { method, headers };
  if (body !== undefined) {
    requestOptions.body = typeof body === 'string' ? body : JSON.stringify(body);
  }
  const response = await fetch(url, requestOptions);
  if (!response.ok) {
    const body = await response.text();
    const details = body?.trim() ? `: ${body.trim()}` : '';
    throw new Error(`GitHub API responded with ${response.status} ${response.statusText}${details}`);
  }
  const text = await response.text();
  if (!text.trim()) {
    return null;
  }
  return JSON.parse(text);
}

async function requestGitHubJsonPages(url, token, { perPage = 100, maxPages = 100 } = {}) {
  const rows = [];
  for (let page = 1; page <= maxPages; page += 1) {
    const pageUrl = new URL(url);
    pageUrl.searchParams.set('per_page', String(perPage));
    pageUrl.searchParams.set('page', String(page));
    const data = await requestGitHubJson(pageUrl.toString(), token);
    if (!Array.isArray(data) || data.length === 0) {
      break;
    }
    rows.push(...data);
    if (data.length < perPage) {
      break;
    }
  }
  return rows;
}

async function fetchStandingPriorityNumberViaRest(repoRoot, slug, standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL]) {
  const resolvedSlug = slug ?? resolveRepositorySlug(repoRoot);
  if (!resolvedSlug) {
    console.warn('[priority] Unable to resolve repository slug for REST fallback');
    return { status: 'error', error: 'repository slug unavailable' };
  }

  const token = resolveGitHubToken();
  if (!token) {
    warnNoGitHubTokenForRestOnce();
  }

  const errors = [];
  for (const label of standingPriorityLabels) {
    const url = new URL(`https://api.github.com/repos/${resolvedSlug}/issues`);
    url.searchParams.set('labels', label);
    url.searchParams.set('state', 'open');
    url.searchParams.set('per_page', '25');
    url.searchParams.set('sort', 'updated');
    url.searchParams.set('direction', 'desc');

    try {
      const data = await requestGitHubJson(url.toString(), token);
      if (Array.isArray(data)) {
        if (data.length > 1) {
          const ids = data.map((item) => item?.number).filter(Boolean);
          console.warn(
            `[priority] Multiple open items carry label '${label}' (candidates: ${ids.join(', ')}) – selecting the most recently updated entry.`
          );
        }
        const first = data.find((item) => item?.number != null);
        if (first) return { status: 'found', number: Number(first.number), label, repoSlug: resolvedSlug };
        continue;
      }
      if (data?.number != null) {
        return { status: 'found', number: Number(data.number), label, repoSlug: resolvedSlug };
      }
    } catch (err) {
      errors.push(`${label}: ${err.message}`);
    }
  }

  if (errors.length > 0) {
    const message = errors.join(' | ');
    console.warn(`[priority] REST fallback failed: ${message}`);
    return { status: 'error', error: message };
  }

  return { status: 'empty' };
}

function createNoStandingPriorityError(message, standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL]) {
  const labelText = formatStandingPriorityLabels(standingPriorityLabels);
  const err = new Error(message || `No open issue found with labels: ${labelText}.`);
  err.code = 'NO_STANDING_PRIORITY';
  return err;
}

function createMultipleStandingPriorityError(message, standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL], issueNumbers = []) {
  const labelText = formatStandingPriorityLabels(standingPriorityLabels);
  const issueList = (issueNumbers || []).map((value) => Number(value)).filter((value) => Number.isInteger(value) && value > 0);
  const suffix = issueList.length > 0 ? ` Candidates: ${issueList.join(', ')}.` : '';
  const err = new Error(message || `Multiple open issues found with labels: ${labelText}.${suffix}`);
  err.code = 'MULTIPLE_STANDING_PRIORITY';
  err.issueNumbers = issueList;
  return err;
}

function isNoStandingOutcome(outcome) {
  return outcome?.status === 'empty';
}

function isUnavailableOutcome(outcome) {
  return !outcome || outcome.status === 'error' || outcome.status === 'unavailable';
}

export function isStandingPriorityCacheCandidate(cache, standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL]) {
  if (!cache || cache.number == null) return false;
  const labels = normalizeList(cache.labels || []);
  const requiredLabels = normalizeStandingPriorityLabels(standingPriorityLabels);
  const state = String(cache.state || '').trim().toUpperCase();
  return state === 'OPEN' && requiredLabels.some((label) => labels.includes(label));
}

export function resolveStandingPriorityFromSources({
  ghOutcome,
  restOutcome,
  cache,
  standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL]
}) {
  if (isNoStandingOutcome(ghOutcome) || isNoStandingOutcome(restOutcome)) {
    throw createNoStandingPriorityError(undefined, standingPriorityLabels);
  }

  if (isStandingPriorityCacheCandidate(cache, standingPriorityLabels)) {
    return Number(cache.number);
  }

  const reasons = [];
  if (!isUnavailableOutcome(ghOutcome)) {
    reasons.push(`gh status=${ghOutcome.status}`);
  } else if (ghOutcome?.error) {
    reasons.push(`gh: ${ghOutcome.error}`);
  }
  if (!isUnavailableOutcome(restOutcome)) {
    reasons.push(`rest status=${restOutcome.status}`);
  } else if (restOutcome?.error) {
    reasons.push(`rest: ${restOutcome.error}`);
  }
  if (cache?.number != null) {
    reasons.push(`cache invalid (must be OPEN and include one of: ${standingPriorityLabels.join(', ')})`);
  }

  throw new Error(
    `Unable to resolve standing-priority issue number${
      reasons.length > 0 ? ` (${reasons.join('; ')})` : ''
    }`
  );
}

async function fetchIssueViaRest(repoRoot, number, slug) {
  const resolvedSlug = slug ?? resolveRepositorySlug(repoRoot);
  if (!resolvedSlug) {
    console.warn('[priority] Unable to resolve repository slug for REST fallback');
    return null;
  }

  const token = resolveGitHubToken();
  if (!token) {
    warnNoGitHubTokenForRestOnce();
  }

  try {
    const data = await requestGitHubJson(`https://api.github.com/repos/${resolvedSlug}/issues/${number}`, token);
    if (Number(data?.comments) > 0 && typeof data?.comments_url === 'string' && data.comments_url.trim()) {
      try {
        const comments = await requestGitHubJsonPages(data.comments_url, token, { perPage: 100 });
        if (Array.isArray(comments)) {
          return {
            ...data,
            comments
          };
        }
      } catch (err) {
        console.warn(`[priority] REST comment hydration failed: ${err.message}`);
      }
    }
    return data;
  } catch (err) {
    console.warn(`[priority] REST fallback failed: ${err.message}`);
    return null;
  }
}

function didReportNoStandingPriority(result) {
  return isNoStandingOutcome(result?.ghOutcome) || isNoStandingOutcome(result?.restOutcome);
}

function defaultRunGhStandingPriorityList({ slug, label }) {
  const ghArgs = ['issue', 'list', '--label', label, '--state', 'open', '--limit', '1', '--json', 'number'];
  if (slug) {
    ghArgs.push('--repo', slug);
  }
  return ensureCommand(sh('gh', ghArgs), 'gh');
}

function defaultRunStandingPriorityRestLookup({ repoRoot, slug, standingPriorityLabels }) {
  return fetchStandingPriorityNumberViaRest(repoRoot, slug, standingPriorityLabels);
}

function defaultRunGhStandingPriorityListAll({ slug, label }) {
  const ghArgs = ['issue', 'list', '--label', label, '--state', 'open', '--limit', '100', '--json', 'number'];
  if (slug) {
    ghArgs.push('--repo', slug);
  }
  return ensureCommand(sh('gh', ghArgs), 'gh');
}

async function defaultRunStandingPriorityRestListAll({ repoRoot, slug, standingPriorityLabels }) {
  const resolvedSlug = slug ?? resolveRepositorySlug(repoRoot);
  if (!resolvedSlug) {
    return { status: 'error', error: 'repository slug unavailable', numbers: [] };
  }

  const token = resolveGitHubToken();
  if (!token) {
    warnNoGitHubTokenForRestOnce();
    return {
      status: 'error',
      error: 'Authorization unavailable (set GH_TOKEN/GITHUB_TOKEN for REST fallback).',
      numbers: []
    };
  }

  const numbers = new Set();
  const errors = [];
  for (const label of standingPriorityLabels) {
    const url = `https://api.github.com/repos/${resolvedSlug}/issues?state=open&labels=${encodeURIComponent(label)}&per_page=100`;
    try {
      const rows = await requestGitHubJson(url, token);
      const list = Array.isArray(rows) ? rows : [];
      for (const item of list) {
        if (item?.pull_request) {
          continue;
        }
        const number = Number(item?.number);
        if (Number.isInteger(number) && number > 0) {
          numbers.add(number);
        }
      }
    } catch (err) {
      errors.push(`${label}: ${err.message}`);
    }
  }

  if (errors.length > 0) {
    return { status: 'error', error: errors.join(' | '), numbers: [] };
  }

  return {
    status: 'found',
    numbers: Array.from(numbers).sort((left, right) => left - right)
  };
}

function defaultRunGhOpenIssueList({ slug }) {
  const ghArgs = ['issue', 'list', '--state', 'open', '--limit', '100', '--json', 'number,title,body,labels,createdAt,updatedAt,url'];
  if (slug) {
    ghArgs.push('--repo', slug);
  }
  return ensureCommand(sh('gh', ghArgs), 'gh');
}

async function defaultRunRestOpenIssueList({ repoRoot, slug }) {
  const resolvedSlug = slug ?? resolveRepositorySlug(repoRoot);
  if (!resolvedSlug) {
    return { status: 'error', error: 'repository slug unavailable', issues: [] };
  }

  const token = resolveGitHubToken();
  if (!token) {
    warnNoGitHubTokenForRestOnce();
  }

  try {
    const url = `https://api.github.com/repos/${resolvedSlug}/issues?state=open&per_page=100`;
    const data = await requestGitHubJson(url, token);
    const rows = Array.isArray(data) ? data.filter((entry) => !entry?.pull_request) : [];
    return { status: 'found', source: 'rest', issues: rows };
  } catch (error) {
    return { status: 'error', source: 'rest', error: error?.message || String(error), issues: [] };
  }
}

function defaultRunGhAddStandingPriorityLabel({ slug, issueNumber }) {
  const ghArgs = ['issue', 'edit', String(issueNumber), '--add-label', DEFAULT_STANDING_PRIORITY_LABEL];
  if (slug) {
    ghArgs.push('--repo', slug);
  }
  return ensureCommand(sh('gh', ghArgs), 'gh');
}

async function defaultRunRestAddStandingPriorityLabel({ repoRoot, slug, issueNumber }) {
  const resolvedSlug = slug ?? resolveRepositorySlug(repoRoot);
  if (!resolvedSlug) {
    return { status: 'error', source: 'rest', error: 'repository slug unavailable' };
  }

  const token = resolveGitHubToken();
  if (!token) {
    warnNoGitHubTokenForRestOnce();
    return { status: 'error', source: 'rest', error: 'Authorization unavailable for REST label mutation.' };
  }

  try {
    const url = `https://api.github.com/repos/${resolvedSlug}/issues/${Number(issueNumber)}/labels`;
    await requestGitHubJson(url, token, {
      method: 'POST',
      body: { labels: [DEFAULT_STANDING_PRIORITY_LABEL] }
    });
    return { status: 'found', source: 'rest' };
  } catch (error) {
    return { status: 'error', source: 'rest', error: error?.message || String(error) };
  }
}

async function listOpenIssuesForRepo(
  repoRoot,
  slug,
  options = {}
) {
  const runGhList = options.runGhList ?? defaultRunGhOpenIssueList;
  const runRestList = options.runRestList ?? defaultRunRestOpenIssueList;
  const warn = options.warn ?? ((message) => console.warn(message));

  try {
    const ghResult = await runGhList({ repoRoot, slug });
    if (ghResult?.status !== 0) {
      throw new Error(ghResult?.stderr?.trim() || `gh exited with status ${ghResult?.status}`);
    }
    const parsed = ghResult.stdout?.trim() ? JSON.parse(ghResult.stdout) : [];
    const rows = Array.isArray(parsed) ? parsed : [];
    return { status: 'found', source: 'gh', issues: rows };
  } catch (error) {
    if (error?.code === 'ENOENT') {
      warn('[priority] gh CLI not found; using REST fallback for open issue listing');
    } else {
      warn(`[priority] gh open issue listing failed: ${error?.message || error}`);
    }
  }

  return runRestList({ repoRoot, slug });
}

async function enrichOpenIssuesForStandingSelection(repoRoot, slug, issues = [], options = {}) {
  const hasExplicitFetchIssueDetailsFn = typeof options.fetchIssueDetailsFn === 'function';
  const fetchIssueDetailsFn =
    options.fetchIssueDetailsFn ??
    ((issueNumber, detailOptions = {}) => fetchIssue(issueNumber, repoRoot, slug, detailOptions));
  const warn = options.warn ?? ((message) => console.warn(message));
  if (!Array.isArray(issues) || issues.length === 0) {
    return [];
  }

  const detailOptions = {
    ghIssueFetcher: options.ghIssueFetcher,
    restIssueFetcher: options.restIssueFetcher
  };

  return Promise.all(
    issues.map(async (entry) => {
      const normalized = normalizeOpenIssueCandidate(entry);
      if (
        !normalized ||
        normalized.excluded ||
        normalized.outOfScope ||
        normalized.blocked ||
        normalized.commentBodies.length > 0 ||
        (!hasCompareviWorkflowScopeSignal(normalized.title, normalized.body) &&
          !mayNeedBlockedStandingHydration(normalized.title, normalized.body))
      ) {
        return entry;
      }

      const issueNumber = Number(entry?.number);
      if (!Number.isInteger(issueNumber) || issueNumber <= 0) {
        return entry;
      }

      try {
        const detail = await fetchIssueDetailsFn(issueNumber, detailOptions);
        if (!detail) {
          throw new Error(`Standing candidate detail fetch returned no result for #${issueNumber}.`);
        }
        const mergedTitle = detail.title ?? entry.title;
        const mergedBody = detail.body ?? entry.body;
        const detailCommentBodies = normalizeCommentBodies(detail.commentBodies ?? detail.comments);
        const detailCommentCount = Math.max(
          Array.isArray(detail.comments) ? detail.comments.length : 0,
          Array.isArray(detail.commentBodies) ? detail.commentBodies.length : 0,
          Number.isFinite(Number(detail.commentCount)) ? Number(detail.commentCount) : 0,
          typeof detail.comments === 'number' ? Number(detail.comments) : 0
        );
        if (
          hasCompareviWorkflowScopeSignal(mergedTitle, mergedBody) &&
          Number.isFinite(detailCommentCount) &&
          detailCommentCount > 0 &&
          detailCommentBodies.length === 0
        ) {
          throw new Error(`Standing candidate detail fetch did not hydrate comment bodies for #${issueNumber}.`);
        }
        return {
          ...entry,
          title: mergedTitle,
          body: mergedBody,
          comments: detailCommentBodies,
          commentBodies: detailCommentBodies
        };
      } catch (error) {
        warn(`[priority] standing candidate detail fetch failed for #${issueNumber}: ${error?.message || error}`);
        throw error;
      }
    })
  );
}

export async function classifyNoStandingPriorityCondition(
  repoRoot,
  slug,
  standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL],
  options = {}
) {
  const env = options.env ?? process.env;
  const targetSlug = options.targetSlug ?? resolveAutoSelectRepositorySlug(repoRoot, slug, env);
  if (!targetSlug) {
    return {
      status: 'error',
      reason: 'unknown',
      repository: null,
      openIssueCount: null,
      message: 'repository slug unavailable for open issue classification'
    };
  }

  const openIssues = await listOpenIssuesForRepo(repoRoot, targetSlug, options);
  if (openIssues?.status !== 'found') {
    return {
      status: 'error',
      reason: 'unknown',
      repository: targetSlug,
      openIssueCount: null,
      message: openIssues?.error || 'unable to list open issues'
    };
  }

  const openIssueCount = Array.isArray(openIssues.issues) ? openIssues.issues.length : 0;
  if (openIssueCount === 0) {
    return {
      status: 'classified',
      reason: 'queue-empty',
      repository: targetSlug,
      openIssueCount,
      message: `No open issues remain in ${targetSlug}; the standing-priority queue is empty.`
    };
  }

  const enrichedIssues = await enrichOpenIssuesForStandingSelection(repoRoot, targetSlug, openIssues.issues || [], options);
  if (hasOnlyIneligibleOpenIssues(enrichedIssues)) {
    return {
      status: 'classified',
      reason: 'queue-empty',
      repository: targetSlug,
      openIssueCount,
      message:
        `No eligible in-scope open issues remain in ${targetSlug}; ` +
        'the standing-priority queue is empty.'
    };
  }

  return {
    status: 'classified',
    reason: 'label-missing',
    repository: targetSlug,
    openIssueCount,
    message:
      `${targetSlug} has ${openIssueCount} open issue${openIssueCount === 1 ? '' : 's'}, ` +
      `but none carry the checked standing-priority labels (${formatStandingPriorityLabels(standingPriorityLabels)}).`
  };
}

async function addStandingPriorityLabelToIssue(
  repoRoot,
  slug,
  issueNumber,
  options = {}
) {
  const runGhAddLabel = options.runGhAddLabel ?? defaultRunGhAddStandingPriorityLabel;
  const runRestAddLabel = options.runRestAddLabel ?? defaultRunRestAddStandingPriorityLabel;
  const warn = options.warn ?? ((message) => console.warn(message));

  try {
    const ghResult = await runGhAddLabel({ repoRoot, slug, issueNumber });
    if (ghResult?.status !== 0) {
      throw new Error(ghResult?.stderr?.trim() || `gh exited with status ${ghResult?.status}`);
    }
    return { status: 'found', source: 'gh' };
  } catch (error) {
    if (error?.code === 'ENOENT') {
      warn('[priority] gh CLI not found; using REST fallback for standing-priority label assignment');
    } else {
      warn(`[priority] gh label assignment failed: ${error?.message || error}`);
    }
  }

  return runRestAddLabel({ repoRoot, slug, issueNumber });
}

function resolveAutoSelectRepositorySlug(repoRoot, slug, env = process.env) {
  const explicit = parseGitRemoteUrl(env.AGENT_PRIORITY_AUTO_SELECT_REPOSITORY);
  if (explicit) {
    return explicit;
  }
  return (
    resolveUpstreamRepositorySlug(repoRoot, slug, env) ||
    slug ||
    resolveRepositorySlug(repoRoot)
  );
}

export async function autoSelectStandingPriorityIssue(
  repoRoot,
  slug,
  options = {}
) {
  const warn = options.warn ?? ((message) => console.warn(message));
  const env = options.env ?? process.env;
  const targetSlug = options.targetSlug ?? resolveAutoSelectRepositorySlug(repoRoot, slug, env);
  if (!targetSlug) {
    return { status: 'error', error: 'repository slug unavailable for auto-select', repoSlug: null };
  }

  const openIssues = await listOpenIssuesForRepo(repoRoot, targetSlug, options);
  if (openIssues?.status !== 'found') {
    return {
      status: 'error',
      error: openIssues?.error || 'unable to list open issues',
      source: openIssues?.source || null,
      repoSlug: targetSlug
    };
  }

  const selected = await selectAutoStandingPriorityCandidateForRepo(
    repoRoot,
    targetSlug,
    openIssues.issues || [],
    options
  );
  if (!selected) {
    return {
      status: 'empty',
      source: openIssues.source || null,
      repoSlug: targetSlug,
      openIssueCount: Array.isArray(openIssues.issues) ? openIssues.issues.length : 0
    };
  }

  const labelResult = await addStandingPriorityLabelToIssue(repoRoot, targetSlug, selected.number, options);
  if (labelResult?.status !== 'found') {
    return {
      status: 'error',
      error: labelResult?.error || 'failed to assign standing-priority label',
      source: labelResult?.source || null,
      repoSlug: targetSlug,
      selected
    };
  }

  warn(
    `[priority] Auto-selected standing issue #${selected.number} in ${targetSlug} (source=${openIssues.source || 'unknown'}).`
  );
  return {
    status: 'selected',
    source: `${openIssues.source || 'unknown'}+${labelResult.source || 'unknown'}`,
    repoSlug: targetSlug,
    issue: selected
  };
}

async function listStandingPriorityIssueNumbersForRepo(
  repoRoot,
  slug,
  standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL],
  options = {}
) {
  const runGhListAll = options.runGhListAll ?? defaultRunGhStandingPriorityListAll;
  const runRestListAll = options.runRestListAll ?? defaultRunStandingPriorityRestListAll;
  const warn = options.warn ?? ((message) => console.warn(message));

  try {
    const numbers = new Set();
    for (const label of standingPriorityLabels) {
      const query = await runGhListAll({ repoRoot, slug, label });
      if (query?.status !== 0) {
        throw new Error(query?.stderr?.trim() || `gh exited with status ${query?.status}`);
      }
      const parsed = query.stdout?.trim() ? JSON.parse(query.stdout) : [];
      const rows = Array.isArray(parsed) ? parsed : [];
      for (const item of rows) {
        const number = Number(item?.number);
        if (Number.isInteger(number) && number > 0) {
          numbers.add(number);
        }
      }
    }
    return {
      status: 'found',
      source: 'gh',
      numbers: Array.from(numbers).sort((left, right) => left - right)
    };
  } catch (err) {
    if (err?.code === 'ENOENT') {
      warn('[priority] gh CLI not found; using REST fallback for standing-priority lane checks');
    } else {
      warn(`[priority] gh standing-priority lane check failed: ${err?.message || err}`);
    }
  }

  const restOutcome = await runRestListAll({ repoRoot, slug, standingPriorityLabels });
  if (restOutcome?.status === 'found') {
    return {
      status: 'found',
      source: 'rest',
      numbers: Array.isArray(restOutcome.numbers) ? restOutcome.numbers : []
    };
  }

  return {
    status: 'error',
    source: 'rest',
    error: restOutcome?.error || 'standing-priority lane check failed',
    numbers: []
  };
}

export async function resolveStandingPriorityForRepo(
  repoRoot,
  slug,
  standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL],
  options = {}
) {
  const runGhList = options.runGhList ?? defaultRunGhStandingPriorityList;
  const runRestLookup = options.runRestLookup ?? defaultRunStandingPriorityRestLookup;
  const warn = options.warn ?? ((message) => console.warn(message));

  let ghOutcome = { status: 'error', error: 'unknown' };
  try {
    let ghHasEmpty = false;
    const ghErrors = [];
    for (const label of standingPriorityLabels) {
      const query = await runGhList({ repoRoot, slug, label });
      if (query?.status === 0) {
        const parsed = query.stdout?.trim() ? JSON.parse(query.stdout) : [];
        const first = Array.isArray(parsed) ? parsed[0] : parsed;
        if (first?.number) {
          return {
            found: { number: Number(first.number), label, repoSlug: slug || null, source: 'gh' },
            ghOutcome: { status: 'found', label },
            restOutcome: { status: 'unavailable', error: 'not-used' },
            repoSlug: slug || null
          };
        }
        ghHasEmpty = true;
      } else {
        ghErrors.push(`${label}: ${query?.stderr?.trim() || `gh exited with status ${query?.status}`}`);
      }
    }
    if (ghHasEmpty) {
      ghOutcome = { status: 'empty' };
    } else {
      ghOutcome = {
        status: 'error',
        error: ghErrors.join(' | ') || 'gh issue list failed'
      };
    }
  } catch (err) {
    if (err?.code === 'ENOENT') {
      warn('[priority] gh CLI not found; falling back to REST/cache standing-priority lookups');
      ghOutcome = { status: 'unavailable', error: err.message || 'gh CLI unavailable' };
    } else {
      ghOutcome = { status: 'error', error: err?.message || 'gh issue list failed' };
    }
  }

  const restOutcome = await runRestLookup({ repoRoot, slug, standingPriorityLabels });
  if (restOutcome?.status === 'found') {
    return {
      found: {
        number: restOutcome.number,
        label: restOutcome.label,
        repoSlug: restOutcome.repoSlug || slug || null,
        source: 'rest'
      },
      ghOutcome,
      restOutcome,
      repoSlug: restOutcome.repoSlug || slug || null
    };
  }

  return {
    found: null,
    ghOutcome,
    restOutcome,
    repoSlug: slug || null
  };
}

export async function resolveStandingPriorityLookupPlan({
  repoRoot,
  slug,
  standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL],
  resolveForRepo = resolveStandingPriorityForRepo,
  resolveUpstreamSlug = resolveUpstreamRepositorySlug,
  warn = (message) => console.warn(message)
}) {
  const primary = await resolveForRepo(repoRoot, slug, standingPriorityLabels);
  if (primary.found) {
    return {
      found: primary.found,
      cacheSource: primary,
      cacheLabels: standingPriorityLabels,
      cacheRepoSlug: primary.repoSlug || slug || null
    };
  }

  const resolvedSlug = slug || resolveRepositorySlug(repoRoot);
  const upstreamSlug = resolveUpstreamSlug(repoRoot, resolvedSlug);
  const shouldCheckUpstream = Boolean(
    upstreamSlug &&
      normalizeRepositorySlug(upstreamSlug) !== normalizeRepositorySlug(resolvedSlug)
  );

  let cacheSource = primary;
  let cacheLabels = standingPriorityLabels;
  let cacheRepoSlug = primary.repoSlug || resolvedSlug || null;

  if (shouldCheckUpstream) {
    if (upstreamSlug && normalizeRepositorySlug(upstreamSlug) !== normalizeRepositorySlug(resolvedSlug)) {
      if (didReportNoStandingPriority(primary)) {
        const primaryTarget = resolvedSlug || 'current repository';
        warn(`[priority] No standing-priority issue found in ${primaryTarget}; checking upstream ${upstreamSlug}.`);
      }

      const upstreamAttempt = await resolveForRepo(repoRoot, upstreamSlug, [DEFAULT_STANDING_PRIORITY_LABEL]);
      if (upstreamAttempt.found) {
        return {
          found: upstreamAttempt.found,
          cacheSource: upstreamAttempt,
          cacheLabels: [DEFAULT_STANDING_PRIORITY_LABEL],
          cacheRepoSlug: upstreamAttempt.repoSlug || upstreamSlug
        };
      }

      if (didReportNoStandingPriority(primary) && didReportNoStandingPriority(upstreamAttempt)) {
        throw createNoStandingPriorityError(
          `No open issue found in ${resolvedSlug} with labels: ${formatStandingPriorityLabels(standingPriorityLabels)}; upstream ${upstreamSlug} also has no open issues with labels: ${formatStandingPriorityLabels([DEFAULT_STANDING_PRIORITY_LABEL])}.`,
          [DEFAULT_STANDING_PRIORITY_LABEL]
        );
      }

      if (didReportNoStandingPriority(primary)) {
        cacheSource = upstreamAttempt;
        cacheLabels = [DEFAULT_STANDING_PRIORITY_LABEL];
        cacheRepoSlug = upstreamAttempt.repoSlug || upstreamSlug;
      }
    }
  }

  return {
    found: null,
    cacheSource,
    cacheLabels,
    cacheRepoSlug
  };
}
async function resolveStandingPriorityNumber(repoRoot, slug, standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL]) {
  const override = process.env.AGENT_PRIORITY_OVERRIDE;
  if (override) {
    try {
      if (override.trim().startsWith('{')) {
        const obj = JSON.parse(override);
        if (obj.number) {
          return {
            number: Number(obj.number),
            repoSlug: obj.repo ? String(obj.repo) : slug || null,
            label: obj.label || null,
            source: 'override'
          };
        }
      } else {
        const head = override.split('|')[0].trim();
        if (head) {
          return {
            number: Number(head),
            repoSlug: slug || null,
            label: null,
            source: 'override'
          };
        }
      }
    } catch {}
  }

  const lookupPlan = await resolveStandingPriorityLookupPlan({
    repoRoot,
    slug,
    standingPriorityLabels
  });
  if (lookupPlan.found) {
    return lookupPlan.found;
  }

  const { cacheSource, cacheLabels, cacheRepoSlug } = lookupPlan;

  const cache = readJson(path.join(repoRoot, '.agent_priority_cache.json'));
  const cacheRepositorySlug =
    (typeof cache?.repository === 'string' && cache.repository.trim() ? cache.repository.trim() : null) ||
    parseGitHubIssueUrlSlug(cache?.url);
  const number = resolveStandingPriorityFromSources({
    ghOutcome: cacheSource.ghOutcome,
    restOutcome: cacheSource.restOutcome,
    cache,
    standingPriorityLabels: cacheLabels
  });

  return {
    number,
    repoSlug: cacheRepositorySlug || cacheRepoSlug,
    label: null,
    source: 'cache'
  };
}

function normalizeIssueResult(result) {
  if (!result) return null;
  const labels = normalizeList((result.labels || []).map((l) => l.name || l));
  const assignees = normalizeList((result.assignees || []).map((a) => a.login || a));
  const milestone = result.milestone ? (result.milestone.title || result.milestone) : null;
  const commentBodies = normalizeCommentBodies(result.commentBodies ?? result.comments);
  const comments = Array.isArray(result.comments)
    ? result.comments.length
    : Array.isArray(result.commentBodies)
      ? result.commentBodies.length
    : typeof result.comments === 'number'
      ? result.comments
      : null;

  return {
    number: result.number,
    title: result.title || null,
    state: result.state || null,
    updatedAt: result.updatedAt || result.updated_at || null,
    url: result.html_url || result.url || null,
    labels,
    assignees,
    milestone,
    commentCount: comments,
    commentBodies,
    body: result.body || null
  };
}

function defaultGhIssueFetcher({ args }) {
  const response = ensureCommand(sh('gh', args), 'gh');
  if (response.status !== 0) {
    const err = new Error(response.stderr?.trim() || `gh exited with status ${response.status}`);
    err.code = response.error?.code || null;
    err.status = response.status;
    err.stdout = response.stdout;
    err.stderr = response.stderr;
    throw err;
  }

  if (!response.stdout?.trim()) {
    return null;
  }

  return JSON.parse(response.stdout);
}

async function defaultRestIssueFetcher({ repoRoot, number, slug }) {
  return fetchIssueViaRest(repoRoot, number, slug);
}

export async function fetchIssue(number, repoRoot, slug, options = {}) {
  const ghIssueFetcher = options.ghIssueFetcher ?? defaultGhIssueFetcher;
  const restIssueFetcher = options.restIssueFetcher ?? defaultRestIssueFetcher;

  let result = null;
  let ghMissing = false;
  let ghErrorMessage = null;

  const attemptGh = async (args) => {
    try {
      return await ghIssueFetcher({ number, repoRoot, slug, args });
    } catch (err) {
      if (err?.code === 'ENOENT') {
        ghMissing = true;
      }
      ghErrorMessage = err?.message || ghErrorMessage;
      return null;
    }
  };

  const targetSlug =
    (typeof slug === 'string' && slug.trim() ? slug.trim() : null) ||
    (typeof process.env.GITHUB_REPOSITORY === 'string' && process.env.GITHUB_REPOSITORY.trim()
      ? process.env.GITHUB_REPOSITORY.trim()
      : null);
  const viewArgs = ['issue', 'view', String(number), '--json', 'number,title,state,updatedAt,url,labels,assignees,milestone,comments,body'];
  if (targetSlug) {
    viewArgs.push('--repo', targetSlug);
  }

  if (targetSlug) {
    const fetchArgs = [
      'api',
      `repos/${targetSlug}/issues/${number}`,
      '--jq',
      `. | {number,title,state,updatedAt:.updated_at,html_url:.html_url,url:.url,labels,assignees,milestone,comments,body}`
    ];
    result = await attemptGh(fetchArgs);
  }

  if (
    result &&
    !Array.isArray(result.comments) &&
    !Array.isArray(result.commentBodies) &&
    Number(result.comments) > 0
  ) {
    const commentDetail = await attemptGh(viewArgs);
    if (commentDetail) {
      result = {
        ...result,
        ...commentDetail,
        comments: commentDetail.comments ?? result.comments
      };
    } else {
      const restHydratedResult = await restIssueFetcher({ repoRoot, number, slug: targetSlug || slug || null });
      if (restHydratedResult) {
        result = restHydratedResult;
      }
    }
  }

  if (!result) {
    result = await attemptGh(viewArgs);
  }

  if (!result) {
    const restResult = await restIssueFetcher({ repoRoot, number, slug: targetSlug || slug || null });
    if (restResult) {
      result = restResult;
    }
  }

  if (!result) {
    const messageParts = [`Failed to fetch issue #${number} via gh CLI`];
    const details = ghMissing ? 'gh CLI not found' : ghErrorMessage;
    if (details) {
      messageParts.push(`(${details})`);
    }
    throw new Error(messageParts.join(' '));
  }

  return normalizeIssueResult(result);
}

function stepSummaryAppend(lines) {
  const file = process.env.GITHUB_STEP_SUMMARY;
  if (!file) return;
  fs.appendFileSync(file, lines.join('\n') + '\n');
}

export function buildNoStandingPriorityReport({
  message,
  labels,
  repository,
  failOnMissing,
  reason = 'label-missing',
  openIssueCount = null,
  generatedAt = new Date().toISOString()
}) {
  return {
    schema: 'standing-priority/no-standing@v1',
    generatedAt,
    repository: repository || null,
    labels: normalizeStandingPriorityLabels(labels),
    message,
    reason,
    openIssueCount: Number.isInteger(openIssueCount) && openIssueCount >= 0 ? openIssueCount : null,
    failOnMissing: Boolean(failOnMissing)
  };
}

function writeNoStandingPriorityReport(resultsDir, report) {
  const reportPath = path.join(resultsDir, NO_STANDING_REPORT_FILENAME);
  writeJson(reportPath, report);
}

export function buildMultipleStandingPriorityReport({
  message,
  labels,
  repository,
  issueNumbers,
  failOnMultiple,
  generatedAt = new Date().toISOString()
}) {
  const numbers = Array.isArray(issueNumbers)
    ? issueNumbers.map((value) => Number(value)).filter((value) => Number.isInteger(value) && value > 0)
    : [];
  return {
    schema: 'standing-priority/multiple-standing@v1',
    generatedAt,
    repository: repository || null,
    labels: normalizeStandingPriorityLabels(labels),
    issueNumbers: numbers,
    message,
    failOnMultiple: Boolean(failOnMultiple)
  };
}

function writeMultipleStandingPriorityReport(resultsDir, report) {
  const reportPath = path.join(resultsDir, MULTIPLE_STANDING_REPORT_FILENAME);
  writeJson(reportPath, report);
}

export function buildNoStandingPriorityState(
  cache,
  message,
  clearedAt = new Date().toISOString(),
  standingPriorityLabels = [DEFAULT_STANDING_PRIORITY_LABEL],
  reason = 'label-missing',
  openIssueCount = null
) {
  const clearedRouter = {
    schema: 'agent/priority-router@v1',
    issue: null,
    updatedAt: clearedAt,
    actions: []
  };
  const clearedCache = {
    ...cache,
    number: null,
    title: null,
    url: null,
    state: 'NONE',
    labels: [],
    assignees: [],
    milestone: null,
    commentCount: null,
    lastSeenUpdatedAt: null,
    issueDigest: null,
    bodyDigest: null,
    mirrorOf: null,
    cachedAtUtc: clearedAt,
    lastFetchSource: 'none',
    lastFetchError: message,
    noStandingReason: reason,
    noStandingOpenIssueCount: Number.isInteger(openIssueCount) && openIssueCount >= 0 ? openIssueCount : null
  };
  const summaryLines = [
    '### Standing Priority Snapshot',
    `- Issue: none found (labels checked: ${formatStandingPriorityLabels(standingPriorityLabels)})`,
    `- Reason: ${reason}`,
    `- Open issues in target repo: ${
      Number.isInteger(openIssueCount) && openIssueCount >= 0 ? openIssueCount : 'unknown'
    }`,
    `- Status: ${message}`,
    '- Top actions: n/a'
  ];
  const result = {
    snapshot: null,
    router: clearedRouter,
    fetchSource: 'none',
    fetchError: message,
    noStandingReason: reason,
    openIssueCount: Number.isInteger(openIssueCount) && openIssueCount >= 0 ? openIssueCount : null
  };

  return { clearedRouter, clearedCache, summaryLines, result };
}

export function computeNextPriorityCacheState({
  cache,
  number,
  issueRepoSlug,
  snapshot,
  fetchSource,
  fetchError,
  cachedAtUtc = new Date().toISOString()
}) {
  return {
    ...cache,
    number,
    repository: issueRepoSlug || cache.repository || null,
    title: snapshot.title || cache.title || null,
    url: snapshot.url || cache.url || null,
    state: snapshot.state || cache.state || null,
    labels: Array.isArray(snapshot.labels) ? snapshot.labels : cache.labels || [],
    assignees: Array.isArray(snapshot.assignees) ? snapshot.assignees : cache.assignees || [],
    milestone: snapshot.milestone ?? cache.milestone ?? null,
    commentCount: snapshot.commentCount ?? cache.commentCount ?? null,
    lastSeenUpdatedAt: snapshot.updatedAt || cache.lastSeenUpdatedAt || null,
    issueDigest: snapshot.digest,
    bodyDigest: snapshot.bodyDigest ?? cache.bodyDigest ?? null,
    mirrorOf: snapshot.mirrorOf ?? cache.mirrorOf ?? null,
    cachedAtUtc,
    lastFetchSource: fetchSource,
    lastFetchError: fetchError
  };
}
export async function main(options = {}) {
  const failOnMissing = Boolean(options.failOnMissing);
  const failOnMultiple = Boolean(options.failOnMultiple);
  const materializeCache =
    Boolean(options.materializeCache) ||
    normalizeBooleanValue((options.env || process.env).AGENT_PRIORITY_MATERIALIZE_CACHE);
  const autoSelectNext =
    Boolean(options.autoSelectNext) ||
    normalizeBooleanValue((options.env || process.env).AGENT_PRIORITY_AUTO_SELECT_NEXT);
  const repoRoot = gitRoot();
  const slug = resolveRepositorySlug(repoRoot, options.env || process.env);
  const standingPriorityLabels = resolveStandingPriorityLabels(repoRoot, slug);
  const cachePath = path.join(repoRoot, '.agent_priority_cache.json');
  const hasCacheFile = fs.existsSync(cachePath);
  const cache = readJson(cachePath) || {};
  const resultsDir = path.join(repoRoot, 'tests', 'results', '_agent', 'issue');
  fs.mkdirSync(resultsDir, { recursive: true });

  let standingPriority;
  try {
    standingPriority = await resolveStandingPriorityNumber(repoRoot, slug, standingPriorityLabels);
  } catch (err) {
    if (err?.code === 'NO_STANDING_PRIORITY') {
      let noStandingMessage = err.message;
      let noStandingReason = 'label-missing';
      let noStandingOpenIssueCount = null;
      const noStandingClassification = await classifyNoStandingPriorityCondition(
        repoRoot,
        slug,
        standingPriorityLabels,
        options
      );
      if (noStandingClassification?.status === 'classified') {
        noStandingMessage = noStandingClassification.message;
        noStandingReason = noStandingClassification.reason;
        noStandingOpenIssueCount = noStandingClassification.openIssueCount;
      }
      if (autoSelectNext) {
        if (noStandingReason !== 'queue-empty') {
          const autoSelect = await autoSelectStandingPriorityIssue(repoRoot, slug, {
            env: options.env || process.env
          });
          if (autoSelect.status === 'selected' && autoSelect.issue?.number) {
            standingPriority = {
              number: autoSelect.issue.number,
              repoSlug: autoSelect.repoSlug || slug || null,
              label: DEFAULT_STANDING_PRIORITY_LABEL,
              source: 'auto-select'
            };
          } else if (autoSelect.status === 'empty') {
            const autoSelectOpenIssueCount =
              Number.isInteger(autoSelect.openIssueCount) && autoSelect.openIssueCount >= 0
                ? autoSelect.openIssueCount
                : null;
            if (autoSelectOpenIssueCount === 0) {
              noStandingReason = 'queue-empty';
              noStandingOpenIssueCount = 0;
              noStandingMessage = `No open issues remain in ${autoSelect.repoSlug || slug || 'current repository'}; the standing-priority queue is empty.`;
            } else {
              noStandingOpenIssueCount = autoSelectOpenIssueCount;
              noStandingMessage = `${noStandingMessage} Auto-select found no eligible in-scope issue.`;
            }
          } else if (autoSelect.status === 'error' && autoSelect.error) {
            noStandingMessage = `${noStandingMessage} Auto-select failed: ${autoSelect.error}`;
          }
        }
      }

      if (standingPriority) {
        console.log(
          `[priority] Standing issue auto-selected: #${standingPriority.number}${
            standingPriority.repoSlug ? ` (${standingPriority.repoSlug})` : ''
          }`
        );
      } else {
        const { clearedRouter, clearedCache, summaryLines, result } = buildNoStandingPriorityState(
          cache,
          noStandingMessage,
          undefined,
          standingPriorityLabels,
          noStandingReason,
          noStandingOpenIssueCount
        );
        writeJson(path.join(resultsDir, 'router.json'), clearedRouter);

        if (
          shouldPersistCacheUpdate(cache, clearedCache, {
            hasCacheFile,
            materializeCache
          })
        ) {
          writeJson(cachePath, clearedCache);
        }

        writeNoStandingPriorityReport(
          resultsDir,
          buildNoStandingPriorityReport({
            message: noStandingMessage,
            labels: standingPriorityLabels,
            repository: slug,
            reason: noStandingReason,
            openIssueCount: noStandingOpenIssueCount,
            failOnMissing
          })
        );
        const multipleReportPath = path.join(resultsDir, MULTIPLE_STANDING_REPORT_FILENAME);
        if (fs.existsSync(multipleReportPath)) {
          fs.unlinkSync(multipleReportPath);
        }

        stepSummaryAppend(summaryLines);
        console.log(`[priority] ${noStandingMessage}`);
        if (failOnMissing && noStandingReason !== 'queue-empty') {
          const strictErr = new Error(noStandingMessage);
          strictErr.code = 'NO_STANDING_PRIORITY';
          throw strictErr;
        }
        return result;
      }
    }
    if (shouldRethrowStandingPriorityError(err, standingPriority)) {
      throw err;
    }
  }
  const number = standingPriority.number;
  const issueRepoSlug = standingPriority.repoSlug || slug || null;
  console.log(`[priority] Standing issue: #${number}${issueRepoSlug ? ` (${issueRepoSlug})` : ''}`);

  if (failOnMultiple) {
    const normalizedIssueRepoSlug = normalizeRepositorySlug(issueRepoSlug);
    const normalizedCurrentSlug = normalizeRepositorySlug(slug);
    const laneLabels =
      normalizedIssueRepoSlug && normalizedCurrentSlug && normalizedIssueRepoSlug !== normalizedCurrentSlug
        ? [DEFAULT_STANDING_PRIORITY_LABEL]
        : standingPriorityLabels;
    const laneState = await listStandingPriorityIssueNumbersForRepo(repoRoot, issueRepoSlug, laneLabels);
    if (laneState.status !== 'found') {
      throw new Error(
        `Unable to verify standing-priority lane uniqueness for ${
          issueRepoSlug || 'current repository'
        }: ${laneState.error || 'unknown error'}`
      );
    }
    const issueNumbers = Array.isArray(laneState.numbers) ? laneState.numbers : [];
    if (issueNumbers.length === 0) {
      const laneErr = createNoStandingPriorityError(undefined, laneLabels);
      if (shouldContinueAfterAutoSelectLaneEmpty(standingPriority, issueNumbers)) {
        console.warn(
          `[priority] ${laneErr.message} Auto-select selected #${number}; continuing with resolved standing issue.`
        );
      } else {
        throw laneErr;
      }
    }
    if (issueNumbers.length > 1) {
      const message = `Multiple open issues found with labels ${formatStandingPriorityLabels(
        laneLabels
      )} in ${issueRepoSlug || 'current repository'}: ${issueNumbers.join(', ')}.`;
      writeMultipleStandingPriorityReport(
        resultsDir,
        buildMultipleStandingPriorityReport({
          message,
          labels: laneLabels,
          repository: issueRepoSlug || slug || null,
          issueNumbers,
          failOnMultiple
        })
      );
      throw createMultipleStandingPriorityError(message, laneLabels, issueNumbers);
    }
    if (issueNumbers.length > 0 && issueNumbers[0] !== number) {
      throw new Error(
        `Standing-priority lane mismatch: resolved issue #${number} but unique open standing issue is #${issueNumbers[0]}.`
      );
    }
  }

  let issue;
  let fetchSource = 'live';
  let fetchError = null;
  try {
    issue = await fetchIssue(number, repoRoot, issueRepoSlug);
  } catch (err) {
    console.warn(`[priority] Fetch failed: ${err.message}`);
    fetchSource = 'cache';
    fetchError = err?.message || null;
    if (cache.number !== number) throw err;
    const fallbackSnapshot = loadSnapshot(repoRoot, number) || {};
    issue = {
      number: cache.number,
      title: cache.title || fallbackSnapshot.title || null,
      state: cache.state || fallbackSnapshot.state || 'unknown',
      updatedAt: cache.lastSeenUpdatedAt || fallbackSnapshot.updatedAt || null,
      url: cache.url || fallbackSnapshot.url || null,
      labels: cache.labels || fallbackSnapshot.labels || [],
      assignees: cache.assignees || fallbackSnapshot.assignees || [],
      milestone: cache.milestone || fallbackSnapshot.milestone || null,
      commentCount: cache.commentCount ?? fallbackSnapshot.commentCount ?? null,
      body: null
    };
  }

  const snapshot = createSnapshot(issue);
  const releaseArtifacts = collectReleaseArtifacts(repoRoot);
  if (releaseArtifacts.length > 0) {
    snapshot.releaseArtifacts = releaseArtifacts;
  }

  writeJson(path.join(resultsDir, `${number}.json`), snapshot);
  fs.writeFileSync(path.join(resultsDir, `${number}.digest`), snapshot.digest + '\n', 'utf8');

  const policy = loadRoutingPolicy(repoRoot);
  const router = buildRouter(snapshot, policy);
  writeJson(path.join(resultsDir, 'router.json'), router);
  const noStandingReportPath = path.join(resultsDir, NO_STANDING_REPORT_FILENAME);
  if (fs.existsSync(noStandingReportPath)) {
    fs.unlinkSync(noStandingReportPath);
  }
  const multipleReportPath = path.join(resultsDir, MULTIPLE_STANDING_REPORT_FILENAME);
  if (fs.existsSync(multipleReportPath)) {
    fs.unlinkSync(multipleReportPath);
  }

  const newCache = computeNextPriorityCacheState({
    cache,
    number,
    issueRepoSlug,
    snapshot,
    fetchSource,
    fetchError
  });
  if (
    shouldPersistCacheUpdate(cache, newCache, {
      hasCacheFile,
      materializeCache
    })
  ) {
    writeJson(cachePath, newCache);
  }

  const topActions = router.actions.slice(0, 3).map((a) => a.key).join(', ') || 'n/a';
  const sourceLine =
    fetchSource === 'live'
      ? '- Source: live fetch'
      : `- Source: cache fallback${fetchError ? ` (${fetchError})` : ''}`;
  const summaryLines = [
    '### Standing Priority Snapshot',
    `- Issue: #${snapshot.number} - ${snapshot.title || '(no title)'}`,
    `- State: ${snapshot.state || 'n/a'}  Updated: ${snapshot.updatedAt || 'n/a'}`,
    `- Digest: \`${snapshot.digest}\``,
    `- Labels: ${(snapshot.labels || []).join(', ') || 'none'}`,
    `- Top actions: ${topActions}`,
    sourceLine
  ];

  if (releaseArtifacts.length > 0) {
    const latest = releaseArtifacts.find((artifact) => artifact.kind === 'finalize') ?? releaseArtifacts[0];
    const versionLabel = latest?.tag ?? 'n/a';
    const timestamp = latest?.timestamp ?? 'n/a';
    summaryLines.splice(4, 0, `- Latest release: ${versionLabel} (${latest?.kind || 'branch'}, ${timestamp})`);
  }
  stepSummaryAppend(summaryLines);

  return { snapshot, router, fetchSource, fetchError };
}

export function shouldWriteCache(previousCache, nextCache) {
  if (!previousCache || typeof previousCache !== 'object') {
    return true;
  }

  const normalizedNext = { ...nextCache };
  if ('cachedAtUtc' in previousCache) {
    normalizedNext.cachedAtUtc = previousCache.cachedAtUtc;
  } else {
    delete normalizedNext.cachedAtUtc;
  }

  return !isDeepStrictEqual(previousCache, normalizedNext);
}

export function shouldPersistCacheUpdate(
  previousCache,
  nextCache,
  { hasCacheFile = false, materializeCache = false } = {}
) {
  if (!hasCacheFile && !materializeCache) {
    return false;
  }
  return shouldWriteCache(previousCache, nextCache);
}

export async function closeProxyAgents() {
  const closeOps = [];
  for (const agent of PROXY_AGENT_CACHE.values()) {
    if (!agent || typeof agent.close !== 'function') continue;
    try {
      const result = agent.close();
      if (result && typeof result.then === 'function') {
        closeOps.push(result);
      }
    } catch {}
  }
  PROXY_AGENT_CACHE.clear();
  if (closeOps.length > 0) {
    await Promise.allSettled(closeOps);
  }
}

export function shouldRethrowStandingPriorityError(err, standingPriority) {
  if (!err) return false;
  if (err?.code === 'NO_STANDING_PRIORITY' && standingPriority) {
    return false;
  }
  return true;
}

export function shouldContinueAfterAutoSelectLaneEmpty(standingPriority, issueNumbers = []) {
  return Boolean(
    standingPriority?.source === 'auto-select' &&
      Array.isArray(issueNumbers) &&
      issueNumbers.length === 0
  );
}

export function determinePrioritySyncExitCode(err, { failOnMissing = false, failOnMultiple = false } = {}) {
  if (!err) return 0;
  if (err?.code === 'NO_STANDING_PRIORITY') {
    return failOnMissing ? 1 : 0;
  }
  if (err?.code === 'MULTIPLE_STANDING_PRIORITY') {
    return failOnMultiple ? 1 : 0;
  }
  return 1;
}

export async function runCli({ argv = process.argv } = {}) {
  const options = parseCliArgs(argv);
  if (options.help) {
    printCliUsage();
    return 0;
  }

  let exitCode = 0;
  try {
    await main(options);
  } catch (err) {
    exitCode = determinePrioritySyncExitCode(err, options);
    if (exitCode === 0) {
      console.warn('[priority] ' + err.message);
    } else {
      console.error('[priority] ' + err.message);
    }
  } finally {
    await closeProxyAgents();
  }
  return exitCode;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  (async () => {
    const exitCode = await runCli({ argv: process.argv });
    process.exitCode = exitCode;
  })();
}

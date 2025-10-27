#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { ProxyAgent } from 'undici';

const USER_AGENT = 'compare-vi-cli-action/priority-sync';
const PROXY_AGENT_CACHE = new Map();

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

function gitRoot() {
  const r = sh('git', ['rev-parse', '--show-toplevel']);
  if (r.status !== 0) throw new Error('git rev-parse failed');
  return r.stdout.trim();
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n', 'utf8');
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
  const digestInput = {
    number: issue.number,
    title: issue.title ?? null,
    state: issue.state ?? null,
    updatedAt: issue.updatedAt ?? null,
    labels,
    assignees,
    milestone: milestone ? milestone.toLowerCase() : null,
    commentCount
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
        scripts: ['pwsh -Command "Write-Host Run npm run release:branch -- <version>"'],
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

function resolveRepositorySlug(repoRoot) {
  if (process.env.GITHUB_REPOSITORY) {
    const slug = process.env.GITHUB_REPOSITORY.trim();
    if (slug) return slug;
  }

  const remote = sh('git', ['config', '--get', 'remote.origin.url']);
  if (remote.status === 0) {
    const slug = parseGitRemoteUrl(remote.stdout);
    if (slug) return slug;
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

function resolveGitHubToken() {
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  return token ? token.trim() : null;
}

async function requestGitHubJson(url, token) {
  const headers = {
    'User-Agent': USER_AGENT,
    Accept: 'application/vnd.github+json'
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  if (typeof fetch !== 'function') {
    throw new Error('Global fetch API unavailable in this Node.js runtime');
  }

  const dispatcher = getProxyDispatcher(url);
  const response = await fetch(url, dispatcher ? { headers, dispatcher } : { headers });
  if (!response.ok) {
    const body = await response.text();
    const details = body?.trim() ? `: ${body.trim()}` : '';
    throw new Error(`GitHub API responded with ${response.status} ${response.statusText}${details}`);
  }
  return response.json();
}

async function fetchStandingPriorityNumberViaRest(repoRoot, slug) {
  const resolvedSlug = slug ?? resolveRepositorySlug(repoRoot);
  if (!resolvedSlug) {
    console.warn('[priority] Unable to resolve repository slug for REST fallback');
    return null;
  }

  const token = resolveGitHubToken();
  if (!token) {
    console.warn('[priority] No GitHub token available for REST fallback; attempting unauthenticated request');
  }

    const url = new URL(`https://api.github.com/repos/${resolvedSlug}/issues`);
    url.searchParams.set('labels', 'standing-priority');
    url.searchParams.set('state', 'open');
    url.searchParams.set('per_page', '25');
    url.searchParams.set('sort', 'updated');
    url.searchParams.set('direction', 'desc');

  try {
    const data = await requestGitHubJson(url.toString(), token);
      if (Array.isArray(data)) {
        if (data.length > 1) {
          const ids = data.map((item) => item?.number).filter(Boolean);
          console.warn(`[priority] Multiple open items carry the standing-priority label (candidates: ${ids.join(', ')}) – selecting the most recently updated entry.`);
        }
        const first = data.find((item) => item?.number != null);
        if (first) return Number(first.number);
      } else if (data?.number != null) {
        return Number(data.number);
      }
  } catch (err) {
    console.warn(`[priority] REST fallback failed: ${err.message}`);
  }

  return null;
}

async function fetchIssueViaRest(repoRoot, number, slug) {
  const resolvedSlug = slug ?? resolveRepositorySlug(repoRoot);
  if (!resolvedSlug) {
    console.warn('[priority] Unable to resolve repository slug for REST fallback');
    return null;
  }

  const token = resolveGitHubToken();
  if (!token) {
    console.warn('[priority] No GitHub token available for REST fallback; attempting unauthenticated request');
  }

  try {
    const data = await requestGitHubJson(`https://api.github.com/repos/${resolvedSlug}/issues/${number}`, token);
    return data;
  } catch (err) {
    console.warn(`[priority] REST fallback failed: ${err.message}`);
    return null;
  }
}

async function resolveStandingPriorityNumber(repoRoot, slug) {
  const override = process.env.AGENT_PRIORITY_OVERRIDE;
  if (override) {
    try {
      if (override.trim().startsWith('{')) {
        const obj = JSON.parse(override);
        if (obj.number) return Number(obj.number);
      } else {
        const head = override.split('|')[0].trim();
        if (head) return Number(head);
      }
    } catch {}
  }

  let ghMissing = false;
  let ghErrorMessage = null;
  try {
    const query = ensureCommand(
      sh('gh', ['issue', 'list', '--label', 'standing-priority', '--state', 'open', '--limit', '1', '--json', 'number']),
      'gh'
    );
    if (query.status === 0 && query.stdout.trim()) {
      const parsed = JSON.parse(query.stdout);
      const first = Array.isArray(parsed) ? parsed[0] : parsed;
      if (first?.number) return Number(first.number);
    }
    if (query.status !== 0) {
      ghErrorMessage = query.stderr?.trim() || `gh exited with status ${query.status}`;
    }
  } catch (err) {
    if (err?.code === 'ENOENT') {
      console.warn('[priority] gh CLI not found; falling back to cached standing-priority issue number');
      ghMissing = true;
    }
    ghErrorMessage = err?.message || ghErrorMessage;
  }

  const restNumber = await fetchStandingPriorityNumberViaRest(repoRoot, slug);
  if (restNumber != null) return restNumber;

  const cache = readJson(path.join(repoRoot, '.agent_priority_cache.json'));
  if (cache?.number != null) return Number(cache.number);
  const reason = ghMissing ? 'gh CLI unavailable' : ghErrorMessage;
  throw new Error(`Unable to resolve standing-priority issue number${reason ? ` (${reason})` : ''}`);
}

function normalizeIssueResult(result) {
  if (!result) return null;
  const labels = normalizeList((result.labels || []).map((l) => l.name || l));
  const assignees = normalizeList((result.assignees || []).map((a) => a.login || a));
  const milestone = result.milestone ? (result.milestone.title || result.milestone) : null;
  const comments = Array.isArray(result.comments)
    ? result.comments.length
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
    body: result.body || null
  };
}

async function fetchIssue(number, repoRoot, slug) {
  let result = null;
  let lastGhResult = null;
  let ghMissing = false;
  let ghErrorMessage = null;

  const attemptGh = (args) => {
    try {
      const response = ensureCommand(sh('gh', args), 'gh');
      lastGhResult = response;
      if (response.status === 0 && response.stdout.trim()) {
        return JSON.parse(response.stdout);
      }
      if (response.status !== 0) {
        ghErrorMessage = response.stderr?.trim() || `gh exited with status ${response.status}`;
      }
    } catch (err) {
      if (err?.code === 'ENOENT') {
        ghMissing = true;
        ghErrorMessage = err.message;
      } else {
        ghErrorMessage = err?.message || ghErrorMessage;
      }
    }
    return null;
  };

  if (process.env.GITHUB_REPOSITORY) {
    const fetchArgs = [
      'api',
      `repos/${process.env.GITHUB_REPOSITORY}/issues/${number}`,
      '--jq',
      `. | {number,title,state,updatedAt,html_url:.html_url,url:.url,labels,assignees,milestone,comments,body}`
    ];
    result = attemptGh(fetchArgs);
  }

  if (!result) {
    const fields = ['number', 'title', 'state', 'updatedAt', 'url', 'labels', 'assignees', 'milestone', 'comments', 'body'];
    result = attemptGh(['issue', 'view', String(number), '--json', fields.join(',')]);
  }

  if (!result) {
    const restResult = await fetchIssueViaRest(repoRoot, number, slug);
    if (restResult) {
      result = restResult;
    }
  }

  if (!result) {
    const messageParts = [`Failed to fetch issue #${number} via gh CLI`];
    const details = ghMissing
      ? 'gh CLI not found'
      : ghErrorMessage || [lastGhResult?.stderr, lastGhResult?.stdout].find((part) => part && part.trim());
    if (details) messageParts.push(`(${details})`);
    throw new Error(messageParts.join(' '));
  }

  return normalizeIssueResult(result);
}

function stepSummaryAppend(lines) {
  const file = process.env.GITHUB_STEP_SUMMARY;
  if (!file) return;
  fs.appendFileSync(file, lines.join('\n') + '\n');
}

export async function main() {
  const repoRoot = gitRoot();
  const slug = resolveRepositorySlug(repoRoot);
  const cachePath = path.join(repoRoot, '.agent_priority_cache.json');
  const cache = readJson(cachePath) || {};
  const resultsDir = path.join(repoRoot, 'tests', 'results', '_agent', 'issue');
  fs.mkdirSync(resultsDir, { recursive: true });

  const number = await resolveStandingPriorityNumber(repoRoot, slug);
  console.log(`[priority] Standing issue: #${number}`);

  let issue;
  let fetchSource = 'live';
  let fetchError = null;
  try {
    issue = await fetchIssue(number, repoRoot, slug);
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

  const newCache = {
    ...cache,
    number,
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
    cachedAtUtc: new Date().toISOString(),
    lastFetchSource: fetchSource,
    lastFetchError: fetchError
  };
  if (shouldWriteCache(cache, newCache)) {
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

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  (async () => {
    try {
      await main();
    } catch (err) {
      console.error('[priority] ' + err.message);
      process.exit(1);
    }
  })();
}


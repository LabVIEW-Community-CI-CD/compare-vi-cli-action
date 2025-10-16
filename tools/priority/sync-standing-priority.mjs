#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

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
  return Array.from(new Set((values || []).filter(Boolean))).sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
}

export function createSnapshot(issue) {
  const labels = normalizeList(issue.labels).map((l) => l.toLowerCase());
  const assignees = normalizeList(issue.assignees).map((a) => a.toLowerCase());
  const milestone = issue.milestone != null ? String(issue.milestone) : null;
  const commentCount = issue.commentCount != null ? Number(issue.commentCount) : null;
  const bodyDigest = issue.body ? hashObject(String(issue.body)) : null;
  const digestInput = {
    number: issue.number,
    title: issue.title ?? null,
    state: issue.state ?? null,
    updatedAt: issue.updatedAt ?? null,
    labels: labels.map(l => l.toLowerCase()),
    assignees: assignees.map(a => a.toLowerCase()),
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

  addAction({ key: 'hooks:pre-commit', priority: 10, scripts: ['npm run hooks:pre-commit'], rationale: 'baseline hook gate' });
  addAction({ key: 'hooks:multi', priority: 11, scripts: ['npm run hooks:multi', 'npm run hooks:schema'], rationale: 'ensure parity across planes' });

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
      addAction({ key: 'docs:lint', priority: 20, scripts: ['npm run lint:md:changed'], rationale: 'docs label present' });
    }
    if (labelSet.has('ci')) {
      addAction({ key: 'ci:parity', priority: 30, scripts: ['npm run hooks:multi', 'npm run hooks:schema'], rationale: 'ci label present' });
    }
    if (labelSet.has('release')) {
      addAction({ key: 'release:prep', priority: 40, scripts: ['pwsh -File tools/Branch-Orchestrator.ps1 -DryRun'], rationale: 'release label present' });
    }
  }

  if (actionsMap.size < 3) {
    addAction({ key: 'validate:lint', priority: 90, scripts: ['pwsh -File tools/PrePush-Checks.ps1'], rationale: 'baseline validation' });
  }

  const actions = Array.from(actionsMap.values()).sort((a, b) => (a.priority ?? 50) - (b.priority ?? 50) || a.key.localeCompare(b.key));
  return {
    schema: 'agent/priority-router@v1',
    issue: issue.number,
    updatedAt: issue.updatedAt ?? null,
    actions
  };
}

function resolveStandingPriorityNumber(repoRoot) {
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
  } catch (err) {
    if (err?.code === 'ENOENT') {
      console.warn('[priority] gh CLI not found; falling back to cached standing-priority issue number');
    }
  }

  const cache = readJson(path.join(repoRoot, '.agent_priority_cache.json'));
  if (cache?.number != null) return Number(cache.number);
  throw new Error('Unable to resolve standing-priority issue number');
}

function fetchIssue(number) {
  let result = null;
  let lastGhResult = null;
  if (process.env.GITHUB_REPOSITORY) {
    const fetchArgs = ['api', `repos/${process.env.GITHUB_REPOSITORY}/issues/${number}`, '--jq', `. | {number,title,state,updatedAt,html_url:.html_url,url:.url,labels,assignees,milestone,comments,body}`];
    const r = ensureCommand(sh('gh', fetchArgs), 'gh');
    lastGhResult = r;
    if (r.status === 0 && r.stdout.trim()) {
      result = JSON.parse(r.stdout);
    }
  }
  if (!result) {
    const fields = ['number','title','state','updatedAt','url','labels','assignees','milestone','comments','body'];
    const r2 = ensureCommand(sh('gh', ['issue', 'view', String(number), '--json', fields.join(',')]), 'gh');
    lastGhResult = r2;
    if (r2.status === 0 && r2.stdout.trim()) {
      result = JSON.parse(r2.stdout);
    }
  }
  if (!result) {
    const messageParts = [`Failed to fetch issue #${number} via gh CLI`];
    const details = [lastGhResult?.stderr, lastGhResult?.stdout].find((part) => part && part.trim());
    if (details) messageParts.push(`(${details.trim()})`);
    throw new Error(messageParts.join(' '));
  }

  const labels = normalizeList((result.labels || []).map((l) => l.name || l));
  const assignees = normalizeList((result.assignees || []).map((a) => a.login || a));
  const milestone = result.milestone ? (result.milestone.title || result.milestone) : null;
  const comments = Array.isArray(result.comments) ? result.comments.length : (typeof result.comments === 'number' ? result.comments : null);

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

function stepSummaryAppend(lines) {
  const file = process.env.GITHUB_STEP_SUMMARY;
  if (!file) return;
  fs.appendFileSync(file, lines.join('\n') + '\n');
}

export function main() {
  const repoRoot = gitRoot();
  const cachePath = path.join(repoRoot, '.agent_priority_cache.json');
  const cache = readJson(cachePath) || {};
  const resultsDir = path.join(repoRoot, 'tests', 'results', '_agent', 'issue');
  fs.mkdirSync(resultsDir, { recursive: true });

  const number = resolveStandingPriorityNumber(repoRoot);
  console.log(`[priority] Standing issue: #${number}`);

  let issue;
  let fetchSource = 'live';
  let fetchError = null;
  try {
    issue = fetchIssue(number);
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
  writeJson(cachePath, newCache);

  const topActions = router.actions.slice(0, 3).map((a) => a.key).join(', ') || 'n/a';
  const sourceLine =
    fetchSource === 'live'
      ? '- Source: live fetch'
      : `- Source: cache fallback${fetchError ? ` (${fetchError})` : ''}`;
  const summaryLines = [
    '### Standing Priority Snapshot',
    `- Issue: #${snapshot.number} — ${snapshot.title || '(no title)'}`,
    `- State: ${snapshot.state || 'n/a'}  Updated: ${snapshot.updatedAt || 'n/a'}`,
    `- Digest: \`${snapshot.digest}\``,
    `- Labels: ${(snapshot.labels || []).join(', ') || 'none'}`,
    `- Top actions: ${topActions}`,
    sourceLine
  ];
  stepSummaryAppend(summaryLines);

  return { snapshot, router, fetchSource, fetchError };
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    main();
  } catch (err) {
    console.error('[priority] ' + err.message);
    process.exit(1);
  }
}

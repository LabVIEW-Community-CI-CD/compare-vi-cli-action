#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const ISSUE_ROUTING_REPORT_SCHEMA = 'priority/issue-routing-report@v1';
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'ops', 'issue-routing-report.json');
export const FINGERPRINT_MARKER_PREFIX = 'priority-fingerprint:';
export const DEFAULT_API_VERSION = '2022-11-28';
const VALID_ACTION_TYPES = new Set(['open-issue', 'update-issue', 'comment', 'pause-queue', 'noop']);
const VALID_PRIORITIES = new Set(['P0', 'P1', 'P2']);

function printUsage() {
  console.log('Usage: node tools/priority/issue-router.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --decision <path>        Policy decision report path (required).');
  console.log('  --event <path>           Optional event override path.');
  console.log(`  --report <path>          Routing report output path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --repo <owner/repo>      Optional repository slug override.');
  console.log('  --dry-run                Evaluate and emit report without writes (default).');
  console.log('  --apply                  Apply writes (create/update/comment/reopen).');
  console.log('  -h, --help               Show help and exit.');
}

function normalizeText(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized || null;
}

function normalizeLower(value) {
  const text = normalizeText(value);
  return text ? text.toLowerCase() : null;
}

function normalizePriority(value) {
  const normalized = normalizeText(value)?.toUpperCase() ?? 'P2';
  return VALID_PRIORITIES.has(normalized) ? normalized : 'P2';
}

export function normalizeLabels(values) {
  const normalized = [];
  for (const value of Array.isArray(values) ? values : []) {
    const label = normalizeLower(value);
    if (!label) continue;
    normalized.push(label);
  }
  return [...new Set(normalized)].sort((left, right) => left.localeCompare(right));
}

function writeJson(filePath, payload) {
  const absolute = path.resolve(filePath);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  fs.writeFileSync(absolute, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return absolute;
}

function stableSortObject(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => stableSortObject(entry));
  }
  if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    const output = {};
    for (const key of Object.keys(value).sort((left, right) => left.localeCompare(right))) {
      output[key] = stableSortObject(value[key]);
    }
    return output;
  }
  return value;
}

function hashValue(value) {
  const hash = createHash('sha256');
  hash.update(JSON.stringify(stableSortObject(value)));
  return hash.digest('hex');
}

function asError(error, code) {
  const entry = {
    code,
    message: String(error?.message || error || 'unknown')
  };
  if (Number.isFinite(error?.status)) {
    entry.status = error.status;
  }
  if (error?.url) {
    entry.url = String(error.url);
  }
  return entry;
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
  const explicit = normalizeText(explicitRepo);
  if (explicit && explicit.includes('/')) {
    return explicit;
  }
  const envRepo = normalizeText(process.env.GITHUB_REPOSITORY);
  if (envRepo && envRepo.includes('/')) {
    return envRepo;
  }
  for (const remoteName of ['upstream', 'origin']) {
    try {
      const remoteUrl = execSync(`git config --get remote.${remoteName}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString()
        .trim();
      const slug = parseRemoteUrl(remoteUrl);
      if (slug) return slug;
    } catch {}
  }
  throw new Error('Unable to resolve repository slug. Pass --repo or set GITHUB_REPOSITORY.');
}

export function resolveToken() {
  for (const candidate of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    const token = normalizeText(candidate);
    if (token) return token;
  }
  for (const candidate of [normalizeText(process.env.GH_TOKEN_FILE), process.platform === 'win32' ? 'C:\\github_token.txt' : null]) {
    if (!candidate || !fs.existsSync(candidate)) continue;
    const token = normalizeText(fs.readFileSync(candidate, 'utf8'));
    if (token) return token;
  }
  throw new Error('GitHub token not found. Set GH_TOKEN/GITHUB_TOKEN (or GH_TOKEN_FILE).');
}

async function readJsonFile(filePath) {
  const absolute = path.resolve(filePath);
  if (!fs.existsSync(absolute)) {
    throw new Error(`File not found: ${absolute}`);
  }
  try {
    return JSON.parse(await fs.promises.readFile(absolute, 'utf8'));
  } catch (error) {
    throw new Error(`Invalid JSON in ${absolute}: ${error.message}`);
  }
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    decisionPath: null,
    eventPath: null,
    reportPath: DEFAULT_REPORT_PATH,
    repo: null,
    dryRun: true,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (token === '--apply') {
      options.dryRun = false;
      continue;
    }
    if (token === '--decision' || token === '--event' || token === '--report' || token === '--repo') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--decision') options.decisionPath = next;
      if (token === '--event') options.eventPath = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--repo') options.repo = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !options.decisionPath) {
    throw new Error('Missing required --decision <path> option.');
  }
  return options;
}

function normalizeIncidentEvent(payload = {}) {
  const sourceType = normalizeLower(payload.sourceType) ?? 'incident-event';
  const incidentClass = normalizeLower(payload.incidentClass ?? payload.class ?? payload.type) ?? 'incident-unknown';
  const severity = normalizeLower(payload.severity) ?? 'medium';
  const branch = normalizeLower(payload.branch);
  const sha = normalizeLower(payload.sha);
  const signature = normalizeText(payload.signature) ?? incidentClass;
  const fingerprint = normalizeText(payload.fingerprint);
  return {
    schema: normalizeText(payload.schema),
    sourceType,
    incidentClass,
    severity,
    branch,
    sha,
    signature,
    repository: normalizeText(payload.repository),
    fingerprint,
    suggestedLabels: normalizeLabels(payload.suggestedLabels ?? payload.labels),
    metadata: payload.metadata && typeof payload.metadata === 'object' ? stableSortObject(payload.metadata) : {}
  };
}

function normalizeDecision(decision = {}) {
  const type = normalizeLower(decision.type) ?? 'noop';
  if (!VALID_ACTION_TYPES.has(type)) {
    throw new Error(`Invalid decision action type '${decision.type}'.`);
  }
  return {
    type,
    priority: normalizePriority(decision.priority),
    labels: normalizeLabels(decision.labels),
    owner: normalizeText(decision.owner),
    titlePrefix: normalizeText(decision.titlePrefix) ?? '[Ops Signal]',
    reason: normalizeText(decision.reason) ?? 'unspecified'
  };
}

function normalizeIssue(issue = {}) {
  return {
    number: Number.isInteger(issue.number) ? issue.number : Number(issue.number) || null,
    state: normalizeLower(issue.state) ?? 'unknown',
    title: normalizeText(issue.title) ?? '',
    body: normalizeText(issue.body) ?? '',
    labels: normalizeLabels((issue.labels || []).map((label) => label?.name ?? label)),
    createdAt: normalizeText(issue.created_at) ?? normalizeText(issue.createdAt),
    updatedAt: normalizeText(issue.updated_at) ?? normalizeText(issue.updatedAt),
    url: normalizeText(issue.html_url) ?? normalizeText(issue.url)
  };
}

function parseDateMs(value) {
  const parsed = Date.parse(String(value || ''));
  return Number.isFinite(parsed) ? parsed : Number.POSITIVE_INFINITY;
}

export function selectCanonicalIssue(issues = []) {
  const normalized = issues
    .map((issue) => normalizeIssue(issue))
    .filter((issue) => Number.isInteger(issue.number) && issue.number > 0);
  if (normalized.length === 0) return null;
  normalized.sort((left, right) => {
    const leftState = left.state === 'open' ? 0 : 1;
    const rightState = right.state === 'open' ? 0 : 1;
    if (leftState !== rightState) return leftState - rightState;
    const leftCreated = parseDateMs(left.createdAt);
    const rightCreated = parseDateMs(right.createdAt);
    if (leftCreated !== rightCreated) return leftCreated - rightCreated;
    return left.number - right.number;
  });
  return normalized[0];
}

export function computeLabelDiff(desired, observed) {
  const desiredLabels = normalizeLabels(desired);
  const observedLabels = normalizeLabels(observed);
  const desiredSet = new Set(desiredLabels);
  const observedSet = new Set(observedLabels);
  const added = desiredLabels.filter((label) => !observedSet.has(label));
  const removed = observedLabels.filter((label) => !desiredSet.has(label));
  const unchanged = desiredLabels.filter((label) => observedSet.has(label));
  return {
    desired: desiredLabels,
    observed: observedLabels,
    added,
    removed,
    unchanged,
    exactMatch: added.length === 0 && removed.length === 0
  };
}

export function buildRouteTitle({ event, decision }) {
  const summary = [decision.titlePrefix, event.incidentClass].filter(Boolean).join(' ');
  const branchSuffix = event.branch ? ` @ ${event.branch}` : '';
  return `[${decision.priority}] ${summary}${branchSuffix}`.trim();
}

function buildFingerprintMarker(fingerprint) {
  return `${FINGERPRINT_MARKER_PREFIX}${fingerprint}`;
}

export function buildIssueBody({ now, event, decision, ruleId, reportPath, marker }) {
  const lines = [
    '## Routed Incident',
    '',
    `Generated: ${now.toISOString()}`,
    `Source Type: ${event.sourceType}`,
    `Incident Class: ${event.incidentClass}`,
    `Severity: ${event.severity}`,
    `Fingerprint: ${event.fingerprint}`,
    `Signature: ${event.signature}`,
    `Branch: ${event.branch ?? 'n/a'}`,
    `SHA: ${event.sha ?? 'n/a'}`,
    `Decision Action: ${decision.type}`,
    `Decision Priority: ${decision.priority}`,
    `Decision Reason: ${decision.reason}`,
    `Decision Rule: ${ruleId ?? 'default'}`,
    '',
    'Suggested labels:',
    ...(event.suggestedLabels.length ? event.suggestedLabels.map((label) => `- ${label}`) : ['- none']),
    '',
    `Router report path: \`${reportPath}\``,
    '',
    `<!-- ${marker} -->`
  ];
  return lines.join('\n');
}

function buildCommentBody({ now, event, decision, ruleId, marker }) {
  return [
    'Routing update:',
    `- Generated: ${now.toISOString()}`,
    `- Action: ${decision.type}`,
    `- Priority: ${decision.priority}`,
    `- Rule: ${ruleId ?? 'default'}`,
    `- Severity: ${event.severity}`,
    `- Branch: ${event.branch ?? 'n/a'}`,
    '',
    `<!-- ${marker}:comment -->`
  ].join('\n');
}

export async function requestGitHubJson(url, { token, method = 'GET', body = null, fetchImpl = globalThis.fetch } = {}) {
  if (!token) throw new Error('GitHub token is required for API requests.');
  if (typeof fetchImpl !== 'function') throw new Error('Fetch API is unavailable.');
  const response = await fetchImpl(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'priority-issue-router',
      'X-GitHub-Api-Version': DEFAULT_API_VERSION
    },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!response.ok) {
    const error = new Error(`GitHub API ${method} ${url} failed (${response.status})`);
    error.status = response.status;
    error.url = url;
    try {
      error.payload = await response.json();
    } catch {}
    throw error;
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function searchIssueNumbersByMarker({ repo, token, marker, requestJson }) {
  const query = `repo:${repo} is:issue in:body "${marker}"`;
  const url = `https://api.github.com/search/issues?q=${encodeURIComponent(query)}&per_page=100`;
  const payload = await requestJson(url, { token });
  const numbers = [];
  for (const item of Array.isArray(payload?.items) ? payload.items : []) {
    const number = Number(item?.number);
    if (!Number.isInteger(number) || number <= 0) continue;
    numbers.push(number);
  }
  return [...new Set(numbers)].sort((left, right) => left - right);
}

async function getIssueByNumber({ repo, token, issueNumber, requestJson }) {
  const url = `https://api.github.com/repos/${repo}/issues/${issueNumber}`;
  const payload = await requestJson(url, { token });
  return normalizeIssue(payload);
}

function needsIssuePatch(currentIssue, desired) {
  const labelsEqual =
    currentIssue.labels.length === desired.labels.length &&
    currentIssue.labels.every((label, index) => label === desired.labels[index]);
  return currentIssue.title !== desired.title || currentIssue.body !== desired.body || !labelsEqual;
}

export async function runIssueRouter(rawOptions = {}, deps = {}) {
  const parsed = rawOptions.argv ? parseArgs(rawOptions.argv) : {
    decisionPath: rawOptions.decisionPath,
    eventPath: rawOptions.eventPath ?? null,
    reportPath: rawOptions.reportPath || DEFAULT_REPORT_PATH,
    repo: rawOptions.repo ?? null,
    dryRun: rawOptions.dryRun !== false,
    help: false
  };
  const now = deps.now instanceof Date ? deps.now : new Date();
  const readJson = deps.readJsonFileFn || readJsonFile;
  const writeReport = deps.writeJsonFn || writeJson;
  const resolveRepo = deps.resolveRepositorySlugFn || resolveRepositorySlug;
  const resolveAuth = deps.resolveTokenFn || resolveToken;
  const requestJson = deps.requestGitHubJsonFn || requestGitHubJson;
  const report = {
    schema: ISSUE_ROUTING_REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: 'fail',
    flags: {
      dryRun: Boolean(parsed.dryRun),
      apply: !parsed.dryRun,
      eventOverride: Boolean(parsed.eventPath),
      repoOverride: Boolean(parsed.repo)
    },
    inputs: {
      decisionPath: parsed.decisionPath ?? null,
      eventPath: parsed.eventPath ?? null,
      reportPath: parsed.reportPath ?? DEFAULT_REPORT_PATH,
      repo: parsed.repo ?? null
    },
    policyDecision: {
      schema: null,
      selectedRuleId: null,
      actionType: null,
      priority: null,
      reason: null
    },
    event: null,
    route: {
      fingerprint: null,
      marker: null,
      title: null,
      dedupe: {
        strategy: 'github-search-body-marker',
        candidateCount: 0,
        candidateIssueNumbers: [],
        canonicalIssueNumber: null,
        canonicalIssueState: null
      },
      labels: {
        desired: [],
        observed: [],
        added: [],
        removed: [],
        unchanged: [],
        exactMatch: false
      },
      idempotence: {
        matchedExisting: false,
        noOp: false,
        bodyDigest: null,
        writeActions: []
      },
      operation: {
        action: 'none',
        issueNumber: null,
        issueUrl: null,
        wrote: false
      }
    },
    errors: []
  };

  try {
    const decisionPayload = await readJson(parsed.decisionPath);
    const eventPayload = parsed.eventPath ? await readJson(parsed.eventPath) : decisionPayload?.event;
    const event = normalizeIncidentEvent(eventPayload || {});
    if (!event.fingerprint) {
      throw new Error('Event fingerprint is required for deterministic issue routing.');
    }
    const decision = normalizeDecision(decisionPayload?.decision ?? {});
    const selectedRuleId = normalizeText(decisionPayload?.evaluation?.selectedRuleId);
    const repository = resolveRepo(parsed.repo || event.repository);
    const marker = buildFingerprintMarker(event.fingerprint);
    const desiredLabels = normalizeLabels([...decision.labels, ...event.suggestedLabels]);
    const title = buildRouteTitle({ event, decision });
    const body = buildIssueBody({
      now,
      event,
      decision,
      ruleId: selectedRuleId,
      reportPath: parsed.reportPath,
      marker
    });

    report.policyDecision = {
      schema: normalizeText(decisionPayload?.schema),
      selectedRuleId,
      actionType: decision.type,
      priority: decision.priority,
      reason: decision.reason
    };
    report.inputs.repo = repository;
    report.event = {
      fingerprint: event.fingerprint,
      sourceType: event.sourceType,
      incidentClass: event.incidentClass,
      severity: event.severity,
      branch: event.branch,
      sha: event.sha,
      signature: event.signature
    };
    report.route.fingerprint = event.fingerprint;
    report.route.marker = marker;
    report.route.title = title;
    report.route.idempotence.bodyDigest = hashValue({ title, body, desiredLabels });

    if (decision.type === 'noop' || decision.type === 'pause-queue') {
      report.route.operation = {
        action: 'noop',
        issueNumber: null,
        issueUrl: null,
        wrote: false
      };
      report.route.idempotence.noOp = true;
      report.status = 'pass';
      const reportPath = writeReport(parsed.reportPath, report);
      return { exitCode: 0, report, reportPath };
    }

    const token = resolveAuth();
    const candidateNumbers = await searchIssueNumbersByMarker({
      repo: repository,
      token,
      marker,
      requestJson
    });
    const candidateIssues = [];
    for (const issueNumber of candidateNumbers) {
      candidateIssues.push(
        await getIssueByNumber({
          repo: repository,
          token,
          issueNumber,
          requestJson
        })
      );
    }
    const canonicalIssue = selectCanonicalIssue(candidateIssues);
    const labelDiff = computeLabelDiff(
      desiredLabels,
      canonicalIssue?.labels ?? []
    );
    report.route.dedupe = {
      strategy: 'github-search-body-marker',
      candidateCount: candidateNumbers.length,
      candidateIssueNumbers: candidateNumbers,
      canonicalIssueNumber: canonicalIssue?.number ?? null,
      canonicalIssueState: canonicalIssue?.state ?? null
    };
    report.route.labels = labelDiff;
    report.route.idempotence.matchedExisting = Boolean(canonicalIssue);

    const desiredIssue = {
      title,
      body,
      labels: desiredLabels
    };
    const writeActions = [];

    if (parsed.dryRun) {
      let action = 'would-noop';
      if (!canonicalIssue && (decision.type === 'open-issue' || decision.type === 'update-issue')) {
        action = 'would-create';
      } else if (canonicalIssue) {
        const patchNeeded = decision.type !== 'comment' && needsIssuePatch(canonicalIssue, desiredIssue);
        if (canonicalIssue.state !== 'open' && decision.type !== 'comment') {
          action = patchNeeded ? 'would-reopen-update' : 'would-reopen';
        } else if (decision.type === 'comment') {
          action = 'would-comment';
        } else if (patchNeeded) {
          action = 'would-update';
        }
      }
      report.route.operation = {
        action,
        issueNumber: canonicalIssue?.number ?? null,
        issueUrl: canonicalIssue?.url ?? null,
        wrote: false
      };
      report.route.idempotence.writeActions = writeActions;
      report.route.idempotence.noOp = action === 'would-noop';
      report.status = 'pass';
      const reportPath = writeReport(parsed.reportPath, report);
      return { exitCode: 0, report, reportPath };
    }

    let activeIssue = canonicalIssue;
    if (!activeIssue && (decision.type === 'open-issue' || decision.type === 'update-issue')) {
      const created = await requestJson(`https://api.github.com/repos/${repository}/issues`, {
        token,
        method: 'POST',
        body: desiredIssue
      });
      activeIssue = normalizeIssue(created);
      writeActions.push('create');
    }

    if (activeIssue?.state !== 'open' && (decision.type === 'open-issue' || decision.type === 'update-issue' || decision.type === 'comment')) {
      const reopened = await requestJson(`https://api.github.com/repos/${repository}/issues/${activeIssue.number}`, {
        token,
        method: 'PATCH',
        body: { state: 'open' }
      });
      activeIssue = normalizeIssue(reopened);
      writeActions.push('reopen');
    }

    if (activeIssue && (decision.type === 'open-issue' || decision.type === 'update-issue')) {
      if (needsIssuePatch(activeIssue, desiredIssue)) {
        const updated = await requestJson(`https://api.github.com/repos/${repository}/issues/${activeIssue.number}`, {
          token,
          method: 'PATCH',
          body: desiredIssue
        });
        activeIssue = normalizeIssue(updated);
        writeActions.push('update');
      }
    }

    if (activeIssue && decision.type === 'comment') {
      const commentBody = buildCommentBody({
        now,
        event,
        decision,
        ruleId: selectedRuleId,
        marker
      });
      await requestJson(`https://api.github.com/repos/${repository}/issues/${activeIssue.number}/comments`, {
        token,
        method: 'POST',
        body: { body: commentBody }
      });
      writeActions.push('comment');
    }

    const action =
      writeActions.length === 0
        ? 'noop'
        : writeActions.join('-');

    report.route.operation = {
      action,
      issueNumber: activeIssue?.number ?? null,
      issueUrl: activeIssue?.url ?? null,
      wrote: writeActions.length > 0
    };
    report.route.idempotence.writeActions = writeActions;
    report.route.idempotence.noOp = writeActions.length === 0;
    report.status = 'pass';
    const reportPath = writeReport(parsed.reportPath, report);
    return { exitCode: 0, report, reportPath };
  } catch (error) {
    report.status = 'fail';
    report.errors.push(asError(error, 'issue-routing-failed'));
    const reportPath = writeReport(parsed.reportPath, report);
    return { exitCode: 1, report, reportPath };
  }
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const result = await runIssueRouter({ argv });
  console.log(`[issue-router] report: ${result.reportPath}`);
  if (result.report.status !== 'pass') {
    console.error(`[issue-router] ${result.report.errors.map((entry) => entry.code).join(', ')}`);
  } else {
    console.log(
      `[issue-router] action=${result.report.route.operation.action} issue=${result.report.route.operation.issueNumber ?? 'none'} candidates=${result.report.route.dedupe.candidateCount}`
    );
  }
  return result.exitCode;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then(
    (exitCode) => {
      if (exitCode) process.exit(exitCode);
    },
    (error) => {
      console.error(`[issue-router] ${error.message}`);
      process.exit(1);
    }
  );
}

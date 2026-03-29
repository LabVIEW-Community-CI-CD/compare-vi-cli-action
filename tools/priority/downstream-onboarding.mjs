#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'downstream-onboarding-checklist.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'onboarding',
  'downstream-onboarding.json'
);

const STABLE_SEMVER_TAG_REGEX = /^v\d+\.\d+\.\d+$/;
const RC_SEMVER_TAG_REGEX = /^v\d+\.\d+\.\d+-rc\.\d+$/i;
const FULL_COMMIT_SHA_REGEX = /^[0-9a-f]{40}$/i;
const SHORT_COMMIT_SHA_REGEX = /^[0-9a-f]{7,39}$/i;

function printUsage() {
  console.log('Usage: node tools/priority/downstream-onboarding.mjs --repo <owner/repo> [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>             Downstream repository to evaluate (required).');
  console.log('  --upstream-repo <owner/repo>    Upstream repository (default: env/remotes).');
  console.log('  --action-repo <owner/repo>      Action repository slug (default: upstream repo).');
  console.log('  --branch <name>                 Branch to inspect in downstream repo (default: repo default branch).');
  console.log('  --started-at <ISO-8601>         Optional onboarding start timestamp for lead-time metrics.');
  console.log('  --lookback-runs <n>             Max completed runs fetched per candidate workflow (default: 30).');
  console.log(`  --policy <path>                 Checklist policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --output <path>                 Output JSON path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --parent-issue <n>              Parent tracking issue number (default: none).');
  console.log('  --create-hardening-issues       Create follow-up issues for failed/warn checklist items.');
  console.log('  --issue-repo <owner/repo>       Repository where hardening issues are created (default: upstream repo).');
  console.log('  --issue-labels <a,b,c>          Labels for hardening issues (default: program,enhancement).');
  console.log('  --issue-prefix <text>           Prefix used in hardening issue titles (default: [onboarding]).');
  console.log('  --fail-on-gap                   Exit non-zero when required checklist items fail.');
  console.log('  -h, --help                      Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    downstreamRepo: null,
    upstreamRepo: null,
    actionRepo: null,
    targetBranch: null,
    startedAt: null,
    lookbackRuns: 30,
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    parentIssue: null,
    createHardeningIssues: false,
    issueRepo: null,
    issueLabels: ['program', 'enhancement'],
    issuePrefix: '[onboarding]',
    failOnGap: false,
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

    if (token === '--fail-on-gap') {
      options.failOnGap = true;
      continue;
    }

    if (
      token === '--repo' ||
      token === '--upstream-repo' ||
      token === '--action-repo' ||
      token === '--branch' ||
      token === '--started-at' ||
      token === '--policy' ||
      token === '--output' ||
      token === '--issue-repo' ||
      token === '--issue-prefix'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.downstreamRepo = next;
      if (token === '--upstream-repo') options.upstreamRepo = next;
      if (token === '--action-repo') options.actionRepo = next;
      if (token === '--branch') options.targetBranch = next;
      if (token === '--started-at') options.startedAt = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--issue-repo') options.issueRepo = next;
      if (token === '--issue-prefix') options.issuePrefix = next;
      continue;
    }

    if (token === '--lookback-runs' || token === '--parent-issue') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      const parsed = Number.parseInt(next, 10);
      if (!Number.isFinite(parsed) || parsed < 1) {
        throw new Error(`Invalid value for ${token}: ${next}`);
      }
      if (token === '--lookback-runs') options.lookbackRuns = parsed;
      if (token === '--parent-issue') options.parentIssue = parsed;
      continue;
    }

    if (token === '--issue-labels') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
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

  if (options.startedAt) {
    const startedMs = Date.parse(options.startedAt);
    if (!Number.isFinite(startedMs)) {
      throw new Error(`Invalid --started-at value: ${options.startedAt}`);
    }
  }

  if (!options.help && !options.downstreamRepo) {
    throw new Error('Missing required option: --repo <owner/repo>.');
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

export function resolveRepositorySlug(explicitRepo) {
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
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --upstream-repo.');
}

export function resolveBranchResolution({
  requestedBranchOverride,
  repositoryDefaultBranch,
  fallbackBranch = 'develop'
} = {}) {
  const normalizedRequestedBranch = requestedBranchOverride ? String(requestedBranchOverride).trim() : null;
  const normalizedRepositoryDefaultBranch = repositoryDefaultBranch ? String(repositoryDefaultBranch).trim() : null;
  const normalizedFallbackBranch = fallbackBranch ? String(fallbackBranch).trim() : 'develop';

  const evaluatedBranch =
    normalizedRequestedBranch || normalizedRepositoryDefaultBranch || normalizedFallbackBranch;
  const source = normalizedRequestedBranch
    ? 'explicit-override'
    : normalizedRepositoryDefaultBranch
      ? 'live-repository-default-branch'
      : 'fallback-default-branch';

  return {
    requestedBranchOverride: normalizedRequestedBranch,
    repositoryDefaultBranch: normalizedRepositoryDefaultBranch,
    evaluatedBranch,
    source
  };
}

export function resolveToken() {
  for (const value of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    if (value && value.trim()) {
      return value.trim();
    }
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
      'User-Agent': 'priority-downstream-onboarding',
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

function encodeRepoPath(pathValue) {
  return String(pathValue || '')
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Policy file not found: ${filePath}`);
  }
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

export function normalizePolicy(policy) {
  if (!policy || typeof policy !== 'object') {
    throw new Error('Onboarding policy is missing or invalid.');
  }

  const checklist = Array.isArray(policy.checklist) ? policy.checklist : [];
  if (checklist.length === 0) {
    throw new Error('Onboarding policy has no checklist entries.');
  }

  return {
    schema: String(policy.schema || ''),
    requiredEnvironments: Array.isArray(policy.requiredEnvironments)
      ? policy.requiredEnvironments.map((entry) => String(entry).trim()).filter(Boolean)
      : [],
    requiredBranchChecks: Array.isArray(policy.requiredBranchChecks)
      ? policy.requiredBranchChecks.map((entry) => String(entry).trim()).filter(Boolean)
      : [],
    checklist: checklist.map((entry) => ({
      id: String(entry.id || '').trim(),
      description: String(entry.description || '').trim(),
      required: entry.required !== false,
      severity: ['P1', 'P2', 'P3'].includes(String(entry.severity || '').toUpperCase())
        ? String(entry.severity).toUpperCase()
        : entry.required === false
          ? 'P2'
          : 'P1',
      recommendation: String(entry.recommendation || '').trim()
    }))
  };
}

async function fetchRepositoryMetadata(repo, token) {
  const result = await requestGithub(`https://api.github.com/repos/${repo}`, token, 'GET');
  if (!result.ok) {
    throw new Error(`Failed to query repository ${repo} (${result.status}).`);
  }
  return result.payload;
}

async function fetchWorkflowEntries(repo, branch, token) {
  const url = `https://api.github.com/repos/${repo}/contents/.github/workflows?ref=${encodeURIComponent(branch)}`;
  const result = await requestGithub(url, token, 'GET');
  if (!result.ok) {
    if (result.status === 404) {
      return [];
    }
    throw new Error(`Failed to query workflow directory (${repo}@${branch}, status=${result.status}).`);
  }
  const entries = Array.isArray(result.payload) ? result.payload : [];
  return entries.filter((entry) => entry.type === 'file' && /\.(?:ya?ml)$/i.test(entry.name || ''));
}

async function fetchWorkflowContent(repo, workflowPath, branch, token) {
  const encodedPath = encodeRepoPath(workflowPath);
  const url = `https://api.github.com/repos/${repo}/contents/${encodedPath}?ref=${encodeURIComponent(branch)}`;
  const result = await requestGithub(url, token, 'GET');
  if (!result.ok) {
    return null;
  }
  if (typeof result.payload?.content === 'string') {
    return Buffer.from(result.payload.content, 'base64').toString('utf8');
  }
  return null;
}

export function extractActionReferencesFromWorkflow(content, workflowPath, actionRepo) {
  const references = [];
  const normalizedActionRepo = String(actionRepo || '').toLowerCase();
  const lines = String(content || '').split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const match = line.match(/^\s*(?:-\s*)?uses\s*:\s*['"]?([^'"#\s]+)['"]?(?:\s+#.*)?\s*$/i);
    if (!match) continue;
    const usesToken = match[1];
    const separator = usesToken.indexOf('@');
    if (separator < 0) continue;
    const repoSlug = usesToken.slice(0, separator);
    const ref = usesToken.slice(separator + 1);
    if (repoSlug.toLowerCase() !== normalizedActionRepo) continue;
    references.push({
      workflowPath,
      lineNumber: index + 1,
      uses: usesToken,
      ref
    });
  }
  return references;
}

export function classifyActionReference(ref) {
  const normalized = String(ref || '').trim();
  if (!normalized) {
    return {
      ref: normalized,
      kind: 'missing',
      immutable: false,
      certifiedCandidate: false
    };
  }
  if (FULL_COMMIT_SHA_REGEX.test(normalized)) {
    return {
      ref: normalized,
      kind: 'commit-sha',
      immutable: true,
      certifiedCandidate: true
    };
  }
  if (SHORT_COMMIT_SHA_REGEX.test(normalized)) {
    return {
      ref: normalized,
      kind: 'short-sha',
      immutable: false,
      certifiedCandidate: false
    };
  }
  if (STABLE_SEMVER_TAG_REGEX.test(normalized)) {
    return {
      ref: normalized,
      kind: 'stable-tag',
      immutable: true,
      certifiedCandidate: true
    };
  }
  if (RC_SEMVER_TAG_REGEX.test(normalized)) {
    return {
      ref: normalized,
      kind: 'rc-tag',
      immutable: true,
      certifiedCandidate: false
    };
  }
  if (/^v\d+$/.test(normalized) || /^v\d+\.\d+$/.test(normalized)) {
    return {
      ref: normalized,
      kind: 'floating-tag',
      immutable: false,
      certifiedCandidate: false
    };
  }
  return {
    ref: normalized,
    kind: 'other',
    immutable: false,
    certifiedCandidate: false
  };
}

async function verifyActionReference(actionRepo, ref, token) {
  const classification = classifyActionReference(ref);
  if (classification.kind === 'missing') {
    return {
      ...classification,
      exists: false,
      certified: false,
      reason: 'missing-ref'
    };
  }
  if (classification.kind === 'commit-sha' || classification.kind === 'short-sha') {
    const response = await requestGithub(
      `https://api.github.com/repos/${actionRepo}/commits/${encodeURIComponent(ref)}`,
      token,
      'GET'
    );
    return {
      ...classification,
      exists: response.ok,
      certified: response.ok && classification.kind === 'commit-sha',
      reason: response.ok ? (classification.kind === 'commit-sha' ? 'commit-exists' : 'short-sha-not-immutable') : 'commit-not-found'
    };
  }
  const tagResponse = await requestGithub(
    `https://api.github.com/repos/${actionRepo}/git/ref/tags/${encodeURIComponent(ref)}`,
    token,
    'GET'
  );
  if (!tagResponse.ok) {
    return {
      ...classification,
      exists: false,
      certified: false,
      reason: 'tag-not-found'
    };
  }
  if (classification.kind === 'stable-tag') {
    return {
      ...classification,
      exists: true,
      certified: true,
      reason: 'stable-tag-verified'
    };
  }
  if (classification.kind === 'rc-tag') {
    return {
      ...classification,
      exists: true,
      certified: false,
      reason: 'rc-tag-not-certified'
    };
  }
  return {
    ...classification,
    exists: true,
    certified: false,
    reason: 'floating-or-unknown-tag'
  };
}

async function fetchWorkflowRuns(repo, workflowPath, branch, lookbackRuns, token) {
  const perPage = Math.max(1, Math.min(lookbackRuns, 100));
  const url = `https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(
    workflowPath
  )}/runs?status=completed&branch=${encodeURIComponent(branch)}&per_page=${perPage}`;
  const response = await requestGithub(url, token, 'GET');
  if (!response.ok) {
    return [];
  }
  const runs = Array.isArray(response.payload?.workflow_runs) ? response.payload.workflow_runs : [];
  return runs.map((run) => ({
    id: run.id ?? null,
    workflowPath,
    status: run.status ?? null,
    conclusion: run.conclusion ?? null,
    createdAt: run.created_at ?? null,
    updatedAt: run.updated_at ?? null,
    url: run.html_url ?? null
  }));
}

async function fetchEnvironmentStatus(repo, token, requiredEnvironments) {
  const response = await requestGithub(
    `https://api.github.com/repos/${repo}/environments?per_page=100`,
    token,
    'GET'
  );
  if (!response.ok) {
    return {
      observable: false,
      error: `environments-api-${response.status}`,
      configured: [],
      missing: [...requiredEnvironments]
    };
  }

  const configured = Array.isArray(response.payload?.environments)
    ? response.payload.environments
      .map((entry) => String(entry.name || '').trim())
      .filter(Boolean)
    : [];
  const configuredSet = new Set(configured.map((entry) => entry.toLowerCase()));
  const missing = requiredEnvironments.filter((entry) => !configuredSet.has(entry.toLowerCase()));
  return {
    observable: true,
    error: null,
    configured,
    missing
  };
}

async function fetchBranchProtectionStatus(repo, branch, token, requiredChecks) {
  const response = await requestGithub(
    `https://api.github.com/repos/${repo}/branches/${encodeURIComponent(branch)}/protection`,
    token,
    'GET'
  );
  if (!response.ok) {
    return {
      observable: false,
      error: `branch-protection-api-${response.status}`,
      contexts: [],
      missingChecks: [...requiredChecks]
    };
  }
  const contexts = Array.isArray(response.payload?.required_status_checks?.contexts)
    ? response.payload.required_status_checks.contexts
      .map((entry) => String(entry).trim())
      .filter(Boolean)
    : [];
  const contextSet = new Set(contexts.map((entry) => entry.toLowerCase()));
  const missingChecks = requiredChecks.filter((entry) => !contextSet.has(entry.toLowerCase()));
  return {
    observable: true,
    error: null,
    contexts,
    missingChecks
  };
}

function defaultChecklistEntry(policy, id) {
  const fromPolicy = policy.checklist.find((entry) => entry.id === id);
  if (fromPolicy) return fromPolicy;
  return {
    id,
    description: id,
    required: false,
    severity: 'P3',
    recommendation: ''
  };
}

function createChecklistRecord(policy, id, status, reason, evidence = {}) {
  const base = defaultChecklistEntry(policy, id);
  return {
    ...base,
    status,
    reason,
    evidence
  };
}

export function evaluateChecklist(policy, context) {
  const checklist = [];
  checklist.push(
    createChecklistRecord(
      policy,
      'repository-accessible',
      context.repository?.ok ? 'pass' : 'fail',
      context.repository?.ok ? 'repository-visible' : context.repository?.error || 'repository-unavailable',
      {
        defaultBranch: context.repository?.defaultBranch ?? null,
        evaluatedBranch: context.repository?.evaluatedBranch ?? null,
        branchResolutionSource: context.repository?.branchResolutionSource ?? null,
        htmlUrl: context.repository?.htmlUrl ?? null
      }
    )
  );

  checklist.push(
    createChecklistRecord(
      policy,
      'workflow-reference-present',
      context.references.length > 0 ? 'pass' : 'fail',
      context.references.length > 0 ? 'action-reference-discovered' : 'no-workflow-reference-found',
      {
        workflowPaths: [...new Set(context.references.map((entry) => entry.workflowPath))]
      }
    )
  );

  const certifiedReferences = context.referenceVerifications.filter((entry) => entry.verified.certified);
  checklist.push(
    createChecklistRecord(
      policy,
      'certified-reference-pinned',
      certifiedReferences.length > 0 ? 'pass' : 'fail',
      certifiedReferences.length > 0
        ? 'certified-reference-verified'
        : context.references.length === 0
          ? 'no-reference-to-certify'
          : 'no-certified-immutable-reference',
      {
        references: context.referenceVerifications.map((entry) => ({
          workflowPath: entry.reference.workflowPath,
          ref: entry.reference.ref,
          classification: entry.verified.kind,
          reason: entry.verified.reason
        }))
      }
    )
  );

  checklist.push(
    createChecklistRecord(
      policy,
      'successful-consumption-run',
      context.successfulRuns.length > 0 ? 'pass' : 'fail',
      context.successfulRuns.length > 0 ? 'successful-run-observed' : 'no-successful-run-observed',
      {
        successfulRunCount: context.successfulRuns.length,
        firstSuccessfulRunAt: context.firstSuccessfulRunAt,
        workflowPaths: [...new Set(context.successfulRuns.map((entry) => entry.workflowPath))]
      }
    )
  );

  checklist.push(
    createChecklistRecord(
      policy,
      'protected-environments-configured',
      context.environments.observable
        ? context.environments.missing.length === 0
          ? 'pass'
          : 'warn'
        : 'warn',
      context.environments.observable
        ? context.environments.missing.length === 0
          ? 'required-environments-present'
          : 'required-environments-missing'
        : context.environments.error || 'environment-visibility-unavailable',
      {
        required: policy.requiredEnvironments,
        configured: context.environments.configured,
        missing: context.environments.missing
      }
    )
  );

  checklist.push(
    createChecklistRecord(
      policy,
      'required-checks-visible',
      context.branchProtection.observable
        ? context.branchProtection.missingChecks.length === 0
          ? 'pass'
          : 'warn'
        : 'warn',
      context.branchProtection.observable
        ? context.branchProtection.missingChecks.length === 0
          ? 'required-checks-present'
          : 'required-checks-missing'
        : context.branchProtection.error || 'branch-protection-unavailable',
      {
        required: policy.requiredBranchChecks,
        configured: context.branchProtection.contexts,
        missing: context.branchProtection.missingChecks
      }
    )
  );

  return checklist;
}

export function summarizeChecklist(checklist) {
  const passCount = checklist.filter((entry) => entry.status === 'pass').length;
  const warnCount = checklist.filter((entry) => entry.status === 'warn').length;
  const failCount = checklist.filter((entry) => entry.status === 'fail').length;
  const requiredFailCount = checklist.filter((entry) => entry.required && entry.status === 'fail').length;
  const status = requiredFailCount > 0 ? 'fail' : warnCount > 0 ? 'warn' : 'pass';
  return {
    status,
    totalChecklist: checklist.length,
    passCount,
    warnCount,
    failCount,
    requiredFailCount
  };
}

function severityRank(severity) {
  if (severity === 'P1') return 1;
  if (severity === 'P2') return 2;
  return 3;
}

export function buildHardeningBacklog(checklist, downstreamRepo) {
  return checklist
    .filter((entry) => entry.status !== 'pass')
    .map((entry) => ({
      key: entry.id,
      title: `Resolve ${entry.id} for ${downstreamRepo}`,
      severity: entry.severity,
      status: entry.status,
      reason: entry.reason,
      recommendation: entry.recommendation
    }))
    .sort((left, right) => {
      const severityDiff = severityRank(left.severity) - severityRank(right.severity);
      if (severityDiff !== 0) return severityDiff;
      return left.key.localeCompare(right.key);
    });
}

export function computeRunAttemptsUntilGreen(runs, startedAt = null) {
  const startedMs = startedAt ? Date.parse(startedAt) : null;
  const ordered = [...(runs || [])]
    .filter((entry) => Number.isFinite(Date.parse(entry.createdAt || '')))
    .sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt));

  const filtered = Number.isFinite(startedMs)
    ? ordered.filter((entry) => Date.parse(entry.createdAt) >= startedMs)
    : ordered;
  if (filtered.length === 0) {
    return {
      attempts: null,
      firstSuccess: null
    };
  }

  const firstSuccessIndex = filtered.findIndex((entry) => String(entry.conclusion || '').toLowerCase() === 'success');
  if (firstSuccessIndex < 0) {
    return {
      attempts: filtered.length,
      firstSuccess: null
    };
  }

  return {
    attempts: firstSuccessIndex + 1,
    firstSuccess: filtered[firstSuccessIndex]
  };
}

export function computeOnboardingMetrics({ startedAt, allRuns, summary }) {
  const runProgress = computeRunAttemptsUntilGreen(allRuns, startedAt);
  const firstSuccessAt = runProgress.firstSuccess?.updatedAt || runProgress.firstSuccess?.createdAt || null;
  const startedMs = startedAt ? Date.parse(startedAt) : null;
  const firstSuccessMs = firstSuccessAt ? Date.parse(firstSuccessAt) : null;
  const onboardingLeadTimeHours =
    Number.isFinite(startedMs) && Number.isFinite(firstSuccessMs) && firstSuccessMs >= startedMs
      ? Math.round(((firstSuccessMs - startedMs) / (60 * 60 * 1000)) * 1000) / 1000
      : null;
  const requiredFailures = summary.requiredFailCount;
  const warningCount = summary.warnCount;
  const attemptsPenalty = Number.isFinite(runProgress.attempts) ? Math.max(0, runProgress.attempts - 1) : 0;
  const frictionScore = requiredFailures * 3 + warningCount + attemptsPenalty;
  return {
    startedAt: startedAt ?? null,
    firstSuccessfulConsumptionAt: firstSuccessAt,
    onboardingLeadTimeHours,
    runAttemptsUntilGreen: runProgress.attempts,
    requiredFailures,
    warningCount,
    frictionScore
  };
}

function appendStepSummary(report, outputPath) {
  const stepSummaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (!stepSummaryPath) return;

  const lines = [
    '### Downstream Onboarding',
    `- Downstream repository: \`${report.downstreamRepository}\``,
    `- Action repository: \`${report.actionRepository}\``,
    `- Target branch: \`${report.targetBranch}\``,
    `- Checklist status: \`${report.summary.status}\``,
    `- Required failures: \`${report.summary.requiredFailCount}\``,
    `- Warning count: \`${report.summary.warnCount}\``,
    `- Friction score: \`${report.metrics.frictionScore}\``,
    `- Hardening backlog: \`${report.hardeningBacklog.length}\``,
    `- Artifact: \`${outputPath}\``,
    '',
    '| Checklist item | Status | Required | Reason |',
    '| --- | --- | --- | --- |'
  ];
  for (const entry of report.checklist) {
    lines.push(`| \`${entry.id}\` | \`${entry.status}\` | \`${entry.required}\` | \`${entry.reason}\` |`);
  }
  fs.appendFileSync(stepSummaryPath, `${lines.join('\n')}\n`, 'utf8');
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

export function buildInfrastructureFailureReport({
  options,
  policy,
  generatedAt,
  upstreamRepository,
  actionRepository,
  downstreamRepository,
  error,
  stage = 'runtime'
}) {
  const branchResolution = resolveBranchResolution({
    requestedBranchOverride: options.targetBranch,
    repositoryDefaultBranch: null
  });
  const repositoryContext = {
    ok: false,
    error: error?.message || String(error),
    defaultBranch: branchResolution.repositoryDefaultBranch,
    evaluatedBranch: branchResolution.evaluatedBranch,
    branchResolutionSource: branchResolution.source,
    htmlUrl: null
  };
  const environments = {
    observable: false,
    error: 'not-evaluated',
    configured: [],
    missing: [...policy.requiredEnvironments]
  };
  const branchProtection = {
    observable: false,
    error: 'not-evaluated',
    contexts: [],
    missingChecks: [...policy.requiredBranchChecks]
  };
  const checklist = evaluateChecklist(policy, {
    repository: repositoryContext,
    references: [],
    referenceVerifications: [],
    successfulRuns: [],
    firstSuccessfulRunAt: null,
    environments,
    branchProtection
  });
  const summary = summarizeChecklist(checklist);
  const metrics = computeOnboardingMetrics({
    startedAt: options.startedAt,
    allRuns: [],
    summary
  });

  return {
    schema: 'priority/downstream-onboarding-report@v1',
    generatedAt,
    upstreamRepository,
    actionRepository,
    downstreamRepository,
    targetBranch: branchResolution.evaluatedBranch,
    branchResolution,
    pilot: {
      startedAt: options.startedAt ?? null,
      parentIssue: options.parentIssue ?? null
    },
    repository: repositoryContext,
    workflowDiscovery: {
      scannedWorkflowCount: 0,
      referencedWorkflowCount: 0
    },
    workflowReferences: [],
    runs: {
      total: 0,
      successful: 0,
      firstSuccessfulRunAt: null
    },
    environments,
    branchProtection,
    checklist,
    metrics,
    summary,
    hardeningBacklog: buildHardeningBacklog(checklist, downstreamRepository),
    hardeningIssues: [],
    infrastructureFailure: {
      stage,
      message: error?.message || String(error),
      stack: error?.stack || null
    }
  };
}

export function tryWriteInfrastructureFailureReport(options, error) {
  try {
    const generatedAt = new Date().toISOString();
    const policy = normalizePolicy(readJson(path.resolve(options.policyPath)));
    const upstreamRepository = resolveRepositorySlug(options.upstreamRepo);
    const actionRepository = normalizeRepositorySlug(options.actionRepo || upstreamRepository);
    const downstreamRepository = normalizeRepositorySlug(options.downstreamRepo);
    const report = buildInfrastructureFailureReport({
      options,
      policy,
      generatedAt,
      upstreamRepository,
      actionRepository,
      downstreamRepository,
      error
    });
    const resolvedOutputPath = writeJson(options.outputPath, report);
    appendStepSummary(report, options.outputPath);
    return {
      ok: true,
      outputPath: resolvedOutputPath,
      report
    };
  } catch (writeError) {
    return {
      ok: false,
      error: writeError
    };
  }
}

function buildHardeningIssueBody(entry, report, parentIssue) {
  const lines = [
    `<!-- downstream-onboarding:${report.downstreamRepository}:${entry.key} -->`,
    '## Downstream Onboarding Hardening',
    '',
    `- Downstream repository: \`${report.downstreamRepository}\``,
    `- Action repository: \`${report.actionRepository}\``,
    `- Checklist item: \`${entry.key}\``,
    `- Severity: \`${entry.severity}\``,
    `- Status: \`${entry.status}\``,
    `- Reason: \`${entry.reason}\``,
    ''
  ];
  if (entry.recommendation) {
    lines.push('### Recommendation', '', entry.recommendation, '');
  }
  lines.push('### Evidence', '', `- Onboarding report generated at \`${report.generatedAt}\``);
  if (parentIssue) {
    lines.push(`- Parent issue: #${parentIssue}`);
  }
  return `${lines.join('\n')}\n`;
}

async function createHardeningIssues(report, options, token) {
  if (!options.createHardeningIssues || report.hardeningBacklog.length === 0) {
    return [];
  }

  const issueRepo = normalizeRepositorySlug(options.issueRepo || report.upstreamRepository);
  const listResponse = await requestGithub(`https://api.github.com/repos/${issueRepo}/issues?state=open&per_page=100`, token, 'GET');
  const openIssues = listResponse.ok && Array.isArray(listResponse.payload) ? listResponse.payload : [];

  const results = [];
  for (const entry of report.hardeningBacklog) {
    const title = `${options.issuePrefix} ${entry.title}`;
    const marker = `<!-- downstream-onboarding:${report.downstreamRepository}:${entry.key} -->`;
    const existing = openIssues.find((issue) => issue?.body?.includes(marker) || issue?.title === title);
    if (existing?.number) {
      results.push({
        action: 'existing',
        key: entry.key,
        severity: entry.severity,
        number: existing.number,
        url: existing.html_url ?? null
      });
      continue;
    }

    const createBody = {
      title,
      body: buildHardeningIssueBody(entry, report, options.parentIssue),
      labels: options.issueLabels
    };
    let created = await requestGithub(`https://api.github.com/repos/${issueRepo}/issues`, token, 'POST', createBody);
    if (!created.ok && options.issueLabels.length > 0) {
      created = await requestGithub(
        `https://api.github.com/repos/${issueRepo}/issues`,
        token,
        'POST',
        {
          title,
          body: buildHardeningIssueBody(entry, report, options.parentIssue)
        }
      );
    }
    if (!created.ok) {
      results.push({
        action: 'error',
        key: entry.key,
        severity: entry.severity,
        status: created.status,
        message: created.text || 'issue-create-failed'
      });
      continue;
    }
    results.push({
      action: 'created',
      key: entry.key,
      severity: entry.severity,
      number: created.payload?.number ?? null,
      url: created.payload?.html_url ?? null
    });
  }
  return results;
}

function earliestSuccessRun(runs) {
  return [...(runs || [])]
    .filter((entry) => String(entry.conclusion || '').toLowerCase() === 'success')
    .sort((a, b) => Date.parse(a.createdAt || '') - Date.parse(b.createdAt || ''))[0] ?? null;
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  try {
    const upstreamRepository = resolveRepositorySlug(options.upstreamRepo);
    const actionRepository = normalizeRepositorySlug(options.actionRepo || upstreamRepository);
    const downstreamRepository = normalizeRepositorySlug(options.downstreamRepo);
    const issueRepository = normalizeRepositorySlug(options.issueRepo || upstreamRepository);
    const token = resolveToken();
    const generatedAt = new Date().toISOString();
    const policy = normalizePolicy(readJson(path.resolve(options.policyPath)));

    const repositoryContext = {
      ok: false,
      error: null,
      defaultBranch: null,
      evaluatedBranch: null,
      branchResolutionSource: null,
      htmlUrl: null
    };

    let workflowEntries = [];
    const references = [];
    const referenceVerifications = [];
    const workflowRuns = [];
    let environments = {
      observable: false,
      error: 'not-evaluated',
      configured: [],
      missing: [...policy.requiredEnvironments]
    };
    let branchProtection = {
      observable: false,
      error: 'not-evaluated',
      contexts: [],
      missingChecks: [...policy.requiredBranchChecks]
    };

    const repoMetadata = await fetchRepositoryMetadata(downstreamRepository, token);
    const branchResolution = resolveBranchResolution({
      requestedBranchOverride: options.targetBranch,
      repositoryDefaultBranch: repoMetadata?.default_branch || null
    });
    repositoryContext.ok = true;
    repositoryContext.defaultBranch = branchResolution.repositoryDefaultBranch;
    repositoryContext.evaluatedBranch = branchResolution.evaluatedBranch;
    repositoryContext.branchResolutionSource = branchResolution.source;
    repositoryContext.htmlUrl = repoMetadata?.html_url || null;
    repositoryContext.private = repoMetadata?.private === true;

    workflowEntries = await fetchWorkflowEntries(downstreamRepository, branchResolution.evaluatedBranch, token);
    for (const entry of workflowEntries) {
      const content = await fetchWorkflowContent(
        downstreamRepository,
        entry.path,
        branchResolution.evaluatedBranch,
        token
      );
      if (!content) continue;
      const discovered = extractActionReferencesFromWorkflow(content, entry.path, actionRepository);
      references.push(...discovered);
    }

    for (const reference of references) {
      const verified = await verifyActionReference(actionRepository, reference.ref, token);
      referenceVerifications.push({ reference, verified });
    }

    for (const workflowPath of [...new Set(references.map((entry) => entry.workflowPath))]) {
      const runs = await fetchWorkflowRuns(
        downstreamRepository,
        workflowPath,
        branchResolution.evaluatedBranch,
        options.lookbackRuns,
        token
      );
      workflowRuns.push(...runs);
    }

    environments = await fetchEnvironmentStatus(downstreamRepository, token, policy.requiredEnvironments);
    branchProtection = await fetchBranchProtectionStatus(
      downstreamRepository,
      branchResolution.evaluatedBranch,
      token,
      policy.requiredBranchChecks
    );
    const successfulRuns = workflowRuns.filter((entry) => String(entry.conclusion || '').toLowerCase() === 'success');
    const firstSuccessfulRun = earliestSuccessRun(successfulRuns);
    const checklist = evaluateChecklist(policy, {
      repository: repositoryContext,
      references,
      referenceVerifications,
      successfulRuns,
      firstSuccessfulRunAt: firstSuccessfulRun?.updatedAt || firstSuccessfulRun?.createdAt || null,
      environments,
      branchProtection
    });
    const summary = summarizeChecklist(checklist);
    const hardeningBacklog = buildHardeningBacklog(checklist, downstreamRepository);
    const metrics = computeOnboardingMetrics({
      startedAt: options.startedAt,
      allRuns: workflowRuns,
      summary
    });

    const report = {
      schema: 'priority/downstream-onboarding-report@v1',
      generatedAt,
      upstreamRepository,
      actionRepository,
      downstreamRepository,
      targetBranch: branchResolution.evaluatedBranch,
      branchResolution,
      pilot: {
        startedAt: options.startedAt ?? null,
        parentIssue: options.parentIssue ?? null
      },
      repository: repositoryContext,
      workflowDiscovery: {
        scannedWorkflowCount: workflowEntries.length,
        referencedWorkflowCount: [...new Set(references.map((entry) => entry.workflowPath))].length
      },
      workflowReferences: referenceVerifications.map((entry) => ({
        workflowPath: entry.reference.workflowPath,
        lineNumber: entry.reference.lineNumber,
        ref: entry.reference.ref,
        verified: entry.verified
      })),
      runs: {
        total: workflowRuns.length,
        successful: successfulRuns.length,
        firstSuccessfulRunAt: firstSuccessfulRun?.updatedAt || firstSuccessfulRun?.createdAt || null
      },
      environments,
      branchProtection,
      checklist,
      metrics,
      summary,
      hardeningBacklog,
      hardeningIssues: []
    };

    report.hardeningIssues = await createHardeningIssues(
      report,
      {
        ...options,
        issueRepo: issueRepository
      },
      token
    );

    const resolvedOutputPath = writeJson(options.outputPath, report);
    appendStepSummary(report, options.outputPath);
    console.log(
      `[downstream-onboarding] wrote ${resolvedOutputPath} (status=${summary.status}, backlog=${hardeningBacklog.length})`
    );
    return options.failOnGap && summary.requiredFailCount > 0 ? 1 : 0;
  } catch (error) {
    const failureReport = tryWriteInfrastructureFailureReport(options, error);
    if (failureReport.ok) {
      console.error(
        `[downstream-onboarding] wrote infrastructure-failure report ${failureReport.outputPath} before exiting`
      );
    }
    console.error(error?.stack ?? error?.message ?? String(error));
    return 1;
  }
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

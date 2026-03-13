#!/usr/bin/env node

import { readFile, access, writeFile, mkdir } from 'node:fs/promises';
import { execSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const manifestPath = new URL('./policy.json', import.meta.url);

function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    apply: false,
    help: false,
    debug: false,
    report: null,
    failOnSkip: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--apply') {
      options.apply = true;
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    if (arg === '--debug') {
      options.debug = true;
      continue;
    }
    if (arg === '--report') {
      const reportPath = args[index + 1];
      if (!reportPath || reportPath.startsWith('-')) {
        throw new Error('Missing value for --report.');
      }
      options.report = reportPath;
      index += 1;
      continue;
    }
    if (arg === '--fail-on-skip') {
      options.failOnSkip = true;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return options;
}

async function writeReportIfRequested(reportPath, report, logFn = console.log) {
  if (!reportPath) {
    return;
  }

  const resolvedPath = path.resolve(reportPath);
  await mkdir(path.dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  logFn(`[policy] report written: ${resolvedPath}`);
}

async function loadManifest() {
  const raw = await readFile(manifestPath, 'utf8');
  return JSON.parse(raw);
}

function isNotFoundError(error) {
  if (!error) {
    return false;
  }
  const message = typeof error.message === 'string' ? error.message : String(error);
  return message.includes('404');
}

async function detectForkRun(env = process.env) {
  if (env.GITHUB_EVENT_NAME !== 'pull_request') {
    return false;
  }
  const eventPath = env.GITHUB_EVENT_PATH;
  if (!eventPath) {
    return false;
  }
  try {
    const raw = await readFile(eventPath, 'utf8');
    const data = JSON.parse(raw);
    return Boolean(data?.pull_request?.head?.repo?.fork);
  } catch {
    return false;
  }
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = url.match(/:(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const httpsMatch = url.match(/github\.com\/(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) {
    return null;
  }
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return { owner, repo };
}

function isBranchPattern(branch) {
  return /[*?[\]]/.test(branch);
}

function normalizeHeadRefToBranchName(value) {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  const prefix = 'refs/heads/';
  if (!trimmed.startsWith(prefix)) {
    return null;
  }
  const branch = trimmed.slice(prefix.length);
  if (!branch || isBranchPattern(branch)) {
    return null;
  }
  return branch;
}

function deriveQueueManagedBranches(manifest) {
  const branches = new Set();
  for (const expectations of Object.values(manifest?.rulesets ?? {})) {
    if (!isQueueManagedRulesetExpectation(expectations)) {
      continue;
    }
    for (const include of expectations.includes ?? []) {
      const branch = normalizeHeadRefToBranchName(include);
      if (branch) {
        branches.add(branch);
      }
    }
  }
  return branches;
}

function isQueueManagedRulesetExpectation(expectations) {
  return Boolean(expectations) && expectations.merge_queue !== null && expectations.merge_queue !== undefined;
}

function deriveActiveQueueManagedBranches(manifest, portabilityProfile) {
  if (portabilityProfile?.queueManagedRulesetsPortable === false) {
    return new Set();
  }
  return deriveQueueManagedBranches(manifest);
}

function normalizePortabilityReason(reason, fallback = null) {
  if (reason === null || reason === undefined) {
    return fallback;
  }
  const normalized = String(reason).trim();
  return normalized.length > 0 ? normalized : fallback;
}

function resolveManifestPortabilityOverride(manifest, repositorySlug) {
  const normalizedRepositorySlug = String(repositorySlug ?? '').trim().toLowerCase();
  const repoProfileEntry = Object.entries(manifest?.repoProfiles ?? {}).find(
    ([slug]) => String(slug ?? '').trim().toLowerCase() === normalizedRepositorySlug
  );
  const repoProfile = repoProfileEntry?.[1];
  if (!repoProfile || typeof repoProfile !== 'object') {
    return null;
  }

  const mode = String(repoProfile.rulesetMode ?? '').trim();
  if (mode === 'throughput-fork-relaxed') {
    return {
      queueManagedRulesetsPortable: false,
      detectedBy: 'repo-profile',
      reason: normalizePortabilityReason(repoProfile.reason, `repo-profile:${normalizedRepositorySlug}`)
    };
  }
  if (mode === 'standard') {
    return {
      queueManagedRulesetsPortable: true,
      detectedBy: 'repo-profile',
      reason: normalizePortabilityReason(repoProfile.reason, null)
    };
  }
  if (mode.length === 0) {
    return null;
  }
  throw new Error(
    `Invalid repo portability profile for ${repositorySlug}: unsupported rulesetMode '${mode}'.`
  );
}

function buildRulesetPortabilityProfile(_repoData, overrides = {}) {
  const queueManagedRulesetsPortable =
    overrides.queueManagedRulesetsPortable ?? true;
  const rulesetMode = queueManagedRulesetsPortable ? 'standard' : 'throughput-fork-relaxed';
  const detectedBy =
    overrides.detectedBy ??
    'default';
  const reason =
    normalizePortabilityReason(
      overrides.reason,
      null
    );

  return {
    rulesetMode,
    queueManagedRulesetsPortable,
    detectedBy,
    reason
  };
}

function shouldIgnoreRulesetEntry(entry, portabilityProfile) {
  return portabilityProfile?.queueManagedRulesetsPortable === false &&
    isQueueManagedRulesetExpectation(entry?.expectations);
}

function isMergeQueueRulesetUnsupportedError(error) {
  if (!error) {
    return false;
  }
  const message = typeof error.message === 'string' ? error.message : String(error);
  return /422/.test(message) && /Invalid rule ['"]merge_queue['"]/.test(message);
}

function getRepoFromEnv(env = process.env, execSyncFn = execSync) {
  const envRepo = env.GITHUB_REPOSITORY;
  if (envRepo && envRepo.includes('/')) {
    const [owner, repo] = envRepo.split('/');
    return { owner, repo };
  }

  try {
    const remoteNames = ['upstream', 'origin'];
    for (const remoteName of remoteNames) {
      try {
        const url = execSyncFn(`git config --get remote.${remoteName}.url`, {
          stdio: ['ignore', 'pipe', 'ignore']
        })
          .toString()
          .trim();
        const parsed = parseRemoteUrl(url);
        if (parsed) {
          return parsed;
        }
      } catch {
        // ignore missing remote
      }
    }
  } catch (error) {
    throw new Error(`Failed to determine repository. Hint: set GITHUB_REPOSITORY. ${error.message}`);
  }

  throw new Error('Unable to determine repository owner/name. Set GITHUB_REPOSITORY or define an upstream remote.');
}

async function resolveToken(env = process.env, { readFileFn = readFile, accessFn = access, logFn = console.log } = {}) {
  const candidates = await resolveTokenCandidates(env, { readFileFn, accessFn });
  if (candidates.length === 0) {
    return null;
  }
  logFn(`[policy] auth source: ${candidates[0].source}`);
  return candidates[0];
}

async function resolveTokenCandidates(
  env = process.env,
  { readFileFn = readFile, accessFn = access } = {}
) {
  const candidates = [];
  const seen = new Set();
  const addCandidate = (tokenValue, source) => {
    if (!tokenValue || !tokenValue.trim()) {
      return;
    }
    const token = tokenValue.trim();
    const key = `${source}:${token}`;
    if (seen.has(key)) {
      return;
    }
    candidates.push({ token, source });
    seen.add(key);
  };

  addCandidate(env.GH_TOKEN, 'GH_TOKEN');
  addCandidate(env.GITHUB_TOKEN, 'GITHUB_TOKEN');
  addCandidate(env.GH_ENTERPRISE_TOKEN, 'GH_ENTERPRISE_TOKEN');

  const fileCandidates = [env.GH_TOKEN_FILE];
  if (process.platform === 'win32') {
    fileCandidates.push('C:\\github_token.txt');
  }

  for (const candidate of fileCandidates) {
    if (!candidate) {
      continue;
    }
    try {
      await accessFn(candidate);
      const fileToken = (await readFileFn(candidate, 'utf8')).trim();
      addCandidate(fileToken, `file:${candidate}`);
    } catch {
      // ignore missing/invalid file
    }
  }

  return candidates;
}

function isUnauthorizedAuthError(error) {
  if (!error) {
    return false;
  }
  const message = typeof error.message === 'string' ? error.message : String(error);
  return /401/.test(message) && /unauthorized/i.test(message);
}

function createAuthUnavailableError(operationName, attemptedSources = [], reason = '') {
  const chain = attemptedSources.length > 0 ? attemptedSources.join(' -> ') : 'unknown';
  const suffix = reason && reason.trim() ? ` ${reason.trim()}` : '';
  const error = new Error(`${operationName} authorization unavailable after sources: ${chain}.${suffix}`);
  error.code = 'POLICY_AUTH_UNAVAILABLE';
  error.attemptedSources = attemptedSources;
  return error;
}

async function requestJson(url, token, { method = 'GET', body, fetchFn } = {}) {
  const fetchImpl = fetchFn ?? globalThis.fetch;
  if (typeof fetchImpl !== 'function') {
    throw new Error('Global fetch is not available; provide fetchFn.');
  }
  const headers = {
    Authorization: `Bearer ${token}`,
    'User-Agent': 'priority-policy-check',
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28'
  };
  let payload = body;
  if (body && typeof body !== 'string') {
    payload = JSON.stringify(body);
  }
  if (payload) {
    headers['Content-Type'] = 'application/json';
  }

  const response = await fetchImpl(url, {
    method,
    headers,
    body: payload
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`GitHub API request failed: ${response.status} ${response.statusText} -> ${text}`);
  }

  if (response.status === 204) {
    return null;
  }

  return response.json();
}

async function fetchJson(url, token, fetchFn) {
  return requestJson(url, token, { fetchFn });
}

function normalizeRulesetListResponse(response) {
  if (Array.isArray(response)) {
    return response;
  }
  if (Array.isArray(response?.rulesets)) {
    return response.rulesets;
  }
  if (Array.isArray(response?.items)) {
    return response.items;
  }
  return [];
}

function normalizeRulesetIncludes(values = []) {
  return [...new Set(
    (Array.isArray(values) ? values : [])
      .map((value) => (typeof value === 'string' ? value.trim() : ''))
      .filter(Boolean)
  )].sort();
}

function rulesetIncludesMatch(expectations, actual) {
  if (!Array.isArray(expectations?.includes)) {
    return true;
  }

  const expectedIncludes = normalizeRulesetIncludes(expectations.includes);
  const actualIncludes = normalizeRulesetIncludes(actual?.conditions?.ref_name?.include ?? []);
  return JSON.stringify(expectedIncludes) === JSON.stringify(actualIncludes);
}

function rulesetIdentityMatches(expectations, actual) {
  if (!actual || typeof actual !== 'object') {
    return false;
  }

  if (expectations?.name && actual.name !== expectations.name) {
    return false;
  }

  if (expectations?.target && actual.target !== expectations.target) {
    return false;
  }

  return rulesetIncludesMatch(expectations, actual);
}

function rulesetSummaryMatches(expectations, actual) {
  if (!actual || typeof actual !== 'object') {
    return false;
  }

  if (expectations?.name && actual.name !== expectations.name) {
    return false;
  }

  if (expectations?.target && actual.target !== expectations.target) {
    return false;
  }

  return true;
}

function selectRulesetIdentityCandidate(expectations, candidates = []) {
  const matchingCandidates = (Array.isArray(candidates) ? candidates : []).filter((candidate) =>
    rulesetSummaryMatches(expectations, candidate)
  );
  if (matchingCandidates.length === 0) {
    return { match: null, resolution: 'missing', error: null };
  }

  const exactMatches = matchingCandidates.filter((candidate) => rulesetIdentityMatches(expectations, candidate));
  if (exactMatches.length === 1) {
    return { match: exactMatches[0], resolution: 'exact', error: null };
  }
  if (exactMatches.length > 1) {
    return {
      match: null,
      resolution: 'ambiguous',
      error: new Error(
        `multiple rulesets matched stable identity exactly (${exactMatches
          .map((candidate) => candidate?.id ?? 'unknown')
          .join(', ')})`
      )
    };
  }

  if (matchingCandidates.length === 1) {
    return { match: matchingCandidates[0], resolution: 'summary', error: null };
  }

  const includeSummary = Array.isArray(expectations?.includes)
    ? normalizeRulesetIncludes(expectations.includes).join(', ') || '(empty)'
    : '(unspecified)';
  return {
    match: null,
    resolution: 'ambiguous',
    error: new Error(
      `multiple rulesets matched stable identity by name/target and includes ${includeSummary} did not disambiguate`
    )
  };
}

async function listRulesets(repoUrl, token, fetchFn) {
  const response = await fetchJson(`${repoUrl}/rulesets`, token, fetchFn);
  return normalizeRulesetListResponse(response);
}

function compareRepoSettings(expected, actual) {
  const diffs = [];
  for (const [key, value] of Object.entries(expected)) {
    if (actual[key] !== value) {
      diffs.push(`repo.${key}: expected ${value}, actual ${actual[key]}`);
    }
  }
  return diffs;
}

const BRANCH_PROTECTION_BOOLEAN_SETTINGS = [
  'enforce_admins',
  'required_linear_history',
  'allow_force_pushes',
  'allow_deletions',
  'block_creations',
  'required_conversation_resolution',
  'lock_branch',
  'allow_fork_syncing'
];

const BRANCH_PROTECTION_NULLABLE_SETTINGS = ['required_pull_request_reviews', 'restrictions'];

function hasOwnProperty(object, key) {
  return Object.prototype.hasOwnProperty.call(object ?? {}, key);
}

function normalizeNullableSetting(value) {
  return value ?? null;
}

function stringifyForDiff(value) {
  if (value === null || value === undefined) {
    return String(value);
  }
  if (typeof value === 'object') {
    return JSON.stringify(value);
  }
  return String(value);
}

function compareBranchBooleanSetting(branch, setting, expectedValue, actualProtection) {
  if (expectedValue === undefined) {
    return null;
  }
  const normalizedExpected = Boolean(expectedValue);
  const normalizedActual = resolveEnabledFlag(actualProtection?.[setting], false);
  if (normalizedExpected === normalizedActual) {
    return null;
  }
  return `branch ${branch}: ${setting} expected ${normalizedExpected}, actual ${normalizedActual}`;
}

function compareBranchNullableSetting(branch, setting, expectedValue, actualProtection) {
  if (expectedValue === undefined) {
    return null;
  }
  const actualValue = normalizeNullableSetting(actualProtection?.[setting]);
  if (expectedValue === null) {
    if (actualValue === null) {
      return null;
    }
    return `branch ${branch}: ${setting} expected null, actual ${stringifyForDiff(actualValue)}`;
  }

  if (actualValue === null) {
    return `branch ${branch}: ${setting} expected ${stringifyForDiff(expectedValue)}, actual null`;
  }

  const expectedJson = JSON.stringify(expectedValue);
  const actualJson = JSON.stringify(actualValue);
  if (expectedJson === actualJson) {
    return null;
  }
  return `branch ${branch}: ${setting} mismatch (expected ${expectedJson}, actual ${actualJson})`;
}

function compareBranchSettings(branch, expected, actualProtection, options = {}) {
  if (!actualProtection) {
    return [`branch ${branch}: protection settings not found`];
  }

  const skipRequiredStatusChecks = options.skipRequiredStatusChecks === true;
  const diffs = [];

  if (!skipRequiredStatusChecks && expected.required_status_checks_strict !== undefined) {
    const actualStrict = actualProtection.required_status_checks?.strict ?? true;
    if (actualStrict !== Boolean(expected.required_status_checks_strict)) {
      diffs.push(
        `branch ${branch}: required_status_checks.strict expected ${Boolean(expected.required_status_checks_strict)}, actual ${actualStrict}`
      );
    }
  }

  if (!skipRequiredStatusChecks && Array.isArray(expected.required_status_checks)) {
    const actualChecks =
      actualProtection.required_status_checks?.checks?.map((check) => check.context).filter(Boolean) ?? [];
    const normalizedExpected = [...new Set(expected.required_status_checks)].sort();
    const normalizedActual = [...new Set(actualChecks)].sort();

    const missing = normalizedExpected.filter((context) => !normalizedActual.includes(context));
    const extra = normalizedActual.filter((context) => !normalizedExpected.includes(context));

    if (missing.length > 0 || extra.length > 0) {
      const parts = [];
      if (missing.length > 0) {
        parts.push(`missing [${missing.join(', ')}]`);
      }
      if (extra.length > 0) {
        parts.push(`unexpected [${extra.join(', ')}]`);
      }
      diffs.push(`branch ${branch}: required_status_checks mismatch (${parts.join('; ')})`);
    }
  }

  for (const setting of BRANCH_PROTECTION_BOOLEAN_SETTINGS) {
    const diff = compareBranchBooleanSetting(
      branch,
      setting,
      expected[setting],
      actualProtection
    );
    if (diff) {
      diffs.push(diff);
    }
  }

  for (const setting of BRANCH_PROTECTION_NULLABLE_SETTINGS) {
    const diff = compareBranchNullableSetting(
      branch,
      setting,
      expected[setting],
      actualProtection
    );
    if (diff) {
      diffs.push(diff);
    }
  }

  return diffs;
}

function compareSets(expectedArr = [], actualArr = []) {
  const expected = [...new Set(expectedArr)];
  const actual = [...new Set(actualArr)];
  const missing = expected.filter((value) => !actual.includes(value));
  const extra = actual.filter((value) => !expected.includes(value));
  return { missing, extra };
}

function findRule(rules = [], type) {
  if (!Array.isArray(rules)) {
    return null;
  }
  return rules.find((rule) => rule?.type === type) ?? null;
}

function compareMergeQueue(expected, actualRule) {
  const diffs = [];
  if (!expected) {
    if (actualRule) {
      diffs.push('merge_queue: unexpected merge queue rule present');
    }
    return diffs;
  }

  if (!actualRule) {
    diffs.push('merge_queue: rule missing');
    return diffs;
  }

  const parameters = actualRule.parameters ?? {};
  for (const [key, value] of Object.entries(expected)) {
    if (parameters[key] !== value) {
      diffs.push(`merge_queue.${key}: expected ${value}, actual ${parameters[key]}`);
    }
  }

  return diffs;
}

function compareRulesetStatusChecks(expected = [], actualRule) {
  if (!expected || expected.length === 0) {
    return [];
  }
  if (!actualRule) {
    return ['required_status_checks: rule missing'];
  }

  const actualContexts =
    actualRule.parameters?.required_status_checks?.map((check) => check.context).filter(Boolean) ?? [];
  const { missing, extra } = compareSets(expected, actualContexts);
  const diffs = [];
  if (missing.length > 0) {
    diffs.push(`required_status_checks: missing [${missing.join(', ')}]`);
  }
  if (extra.length > 0) {
    diffs.push(`required_status_checks: unexpected [${extra.join(', ')}]`);
  }
  return diffs;
}

function comparePullRequestRule(expected, actualRule) {
  if (!expected) {
    return [];
  }
  if (!actualRule) {
    return ['pull_request: rule missing'];
  }

  const diffs = [];
  const parameters = actualRule.parameters ?? {};
  for (const [key, value] of Object.entries(expected)) {
    if (key === 'allowed_merge_methods') {
      const actualMethods = Array.isArray(parameters.allowed_merge_methods)
        ? parameters.allowed_merge_methods
        : [];
      const { missing, extra } = compareSets(value, actualMethods);
      if (missing.length > 0) {
        diffs.push(`pull_request.allowed_merge_methods: missing [${missing.join(', ')}]`);
      }
      if (extra.length > 0) {
        diffs.push(`pull_request.allowed_merge_methods: unexpected [${extra.join(', ')}]`);
      }
      continue;
    }
    if (parameters[key] !== value) {
      diffs.push(`pull_request.${key}: expected ${value}, actual ${parameters[key]}`);
    }
  }
  return diffs;
}

function normalizeOptionalRuleExpectation(expected) {
  if (expected === undefined) {
    return { mode: 'ignore', parameters: null };
  }
  if (expected === null || expected === false) {
    return { mode: 'absent', parameters: null };
  }
  if (expected === true) {
    return { mode: 'present', parameters: {} };
  }
  if (typeof expected !== 'object' || Array.isArray(expected)) {
    return { mode: 'present', parameters: {} };
  }

  const enabled = hasOwnProperty(expected, 'enabled') ? Boolean(expected.enabled) : true;
  if (!enabled) {
    return { mode: 'absent', parameters: null };
  }

  const rawParams =
    expected.parameters && typeof expected.parameters === 'object' && !Array.isArray(expected.parameters)
      ? expected.parameters
      : expected;
  const params = { ...rawParams };
  delete params.enabled;
  delete params.parameters;
  return { mode: 'present', parameters: params };
}

function compareOptionalParameterizedRule(type, expected, actualRule) {
  const normalized = normalizeOptionalRuleExpectation(expected);
  if (normalized.mode === 'ignore') {
    return [];
  }
  if (normalized.mode === 'absent') {
    return actualRule ? [`${type}: unexpected rule present`] : [];
  }
  if (!actualRule) {
    return [`${type}: rule missing`];
  }

  const expectedParameters = normalized.parameters ?? {};
  const actualParameters = actualRule.parameters ?? {};
  const diffs = [];
  for (const [key, value] of Object.entries(expectedParameters)) {
    const actualValue = actualParameters[key];
    const expectedJson = JSON.stringify(value);
    const actualJson = JSON.stringify(actualValue);
    if (expectedJson !== actualJson) {
      diffs.push(`${type}.${key}: expected ${stringifyForDiff(value)}, actual ${stringifyForDiff(actualValue)}`);
    }
  }
  return diffs;
}

function compareRulesetIncludes(expected = [], actual = []) {
  const { missing, extra } = compareSets(expected, actual);
  const diffs = [];
  if (missing.length > 0) {
    diffs.push(`conditions.ref_name.include: missing [${missing.join(', ')}]`);
  }
  if (extra.length > 0) {
    diffs.push(`conditions.ref_name.include: unexpected [${extra.join(', ')}]`);
  }
  return diffs;
}

function prefixRulesetDiffs(id, diffs = []) {
  return (Array.isArray(diffs) ? diffs : []).map((diff) =>
    typeof diff === 'string' && diff.startsWith('ruleset ') ? diff : `ruleset ${id}: ${diff}`
  );
}

function compareRuleset(id, expected, actual) {
  if (!actual) {
    return [`ruleset ${id}: not found`];
  }
  const diffs = [];

  if (expected.name && actual.name !== expected.name) {
    diffs.push(`ruleset ${id}: name mismatch (expected ${expected.name}, actual ${actual.name})`);
  }

  if (expected.target && actual.target !== expected.target) {
    diffs.push(`ruleset ${id}: target mismatch (expected ${expected.target}, actual ${actual.target})`);
  }

  if (Array.isArray(expected.includes)) {
    const actualIncludes = actual.conditions?.ref_name?.include ?? [];
    diffs.push(
      ...compareRulesetIncludes(expected.includes, Array.isArray(actualIncludes) ? actualIncludes : [])
    );
  }

  const rules = actual.rules ?? [];

  if (expected.required_linear_history) {
    const linearRule = findRule(rules, 'required_linear_history');
    if (!linearRule) {
      diffs.push('required_linear_history: rule missing');
    }
  }

  const mergeQueueRule = findRule(rules, 'merge_queue');
  diffs.push(...compareMergeQueue(expected.merge_queue, mergeQueueRule));

  const statusRule = findRule(rules, 'required_status_checks');
  diffs.push(...compareRulesetStatusChecks(expected.required_status_checks, statusRule));

  const prRule = findRule(rules, 'pull_request');
  diffs.push(...comparePullRequestRule(expected.pull_request, prRule));

  const codeQualityRule = findRule(rules, 'code_quality');
  diffs.push(...compareOptionalParameterizedRule('code_quality', expected.code_quality, codeQualityRule));

  const codeScanningRule = findRule(rules, 'code_scanning');
  diffs.push(...compareOptionalParameterizedRule('code_scanning', expected.code_scanning, codeScanningRule));

  const copilotCodeReviewRule = findRule(rules, 'copilot_code_review');
  diffs.push(
    ...compareOptionalParameterizedRule(
      'copilot_code_review',
      expected.copilot_code_review,
      copilotCodeReviewRule
    )
  );

  return diffs;
}

function resolveEnabledFlag(value, fallback = false) {
  if (typeof value === 'boolean') {
    return value;
  }
  if (value && typeof value.enabled === 'boolean') {
    return Boolean(value.enabled);
  }
  return Boolean(fallback);
}

function normalizeActualRequiredStatusChecks(actual) {
  const explicitChecks = actual?.required_status_checks?.checks?.map((check) => check?.context).filter(Boolean);
  if (Array.isArray(explicitChecks) && explicitChecks.length > 0) {
    return explicitChecks;
  }
  return Array.isArray(actual?.required_status_checks?.contexts)
    ? actual.required_status_checks.contexts.filter(Boolean)
    : [];
}

function buildBranchProtectionPayload(expected, actual, options = {}) {
  const skipRequiredStatusChecks = options.skipRequiredStatusChecks === true;
  const expectedChecks = skipRequiredStatusChecks
    ? normalizeActualRequiredStatusChecks(actual)
    : (Array.isArray(expected.required_status_checks) ? expected.required_status_checks : []);
  const strictSetting = skipRequiredStatusChecks
    ? actual?.required_status_checks?.strict ?? true
    : (hasOwnProperty(expected, 'required_status_checks_strict')
        ? Boolean(expected.required_status_checks_strict)
        : actual?.required_status_checks?.strict ?? true);
  const enforceAdmins = hasOwnProperty(expected, 'enforce_admins')
    ? Boolean(expected.enforce_admins)
    : resolveEnabledFlag(actual?.enforce_admins, false);
  const requiredPullRequestReviews = hasOwnProperty(expected, 'required_pull_request_reviews')
    ? expected.required_pull_request_reviews
    : normalizeNullableSetting(actual?.required_pull_request_reviews);
  const restrictions = hasOwnProperty(expected, 'restrictions')
    ? expected.restrictions
    : normalizeNullableSetting(actual?.restrictions);
  const requiredLinearHistory = hasOwnProperty(expected, 'required_linear_history')
    ? Boolean(expected.required_linear_history)
    : resolveEnabledFlag(actual?.required_linear_history, false);
  const allowForcePushes = hasOwnProperty(expected, 'allow_force_pushes')
    ? Boolean(expected.allow_force_pushes)
    : resolveEnabledFlag(actual?.allow_force_pushes, false);
  const allowDeletions = hasOwnProperty(expected, 'allow_deletions')
    ? Boolean(expected.allow_deletions)
    : resolveEnabledFlag(actual?.allow_deletions, false);
  const blockCreations = hasOwnProperty(expected, 'block_creations')
    ? Boolean(expected.block_creations)
    : resolveEnabledFlag(actual?.block_creations, false);
  const requiredConversationResolution = hasOwnProperty(expected, 'required_conversation_resolution')
    ? Boolean(expected.required_conversation_resolution)
    : resolveEnabledFlag(actual?.required_conversation_resolution, false);
  const lockBranch = hasOwnProperty(expected, 'lock_branch')
    ? Boolean(expected.lock_branch)
    : resolveEnabledFlag(actual?.lock_branch, false);
  const allowForkSyncing = hasOwnProperty(expected, 'allow_fork_syncing')
    ? Boolean(expected.allow_fork_syncing)
    : resolveEnabledFlag(actual?.allow_fork_syncing, false);

  const payload = {
    required_status_checks: {
      strict: strictSetting,
      contexts: expectedChecks
    },
    enforce_admins: enforceAdmins,
    required_pull_request_reviews: requiredPullRequestReviews,
    restrictions,
    required_linear_history: requiredLinearHistory,
    allow_force_pushes: allowForcePushes,
    allow_deletions: allowDeletions,
    block_creations: blockCreations,
    required_conversation_resolution: requiredConversationResolution,
    lock_branch: lockBranch,
    allow_fork_syncing: allowForkSyncing
  };

  return payload;
}

function sanitizeBypassActors(actors) {
  if (!Array.isArray(actors)) {
    return [];
  }
  return actors.map((actor) => ({
    actor_id: actor.actor_id ?? null,
    actor_type: actor.actor_type ?? null,
    bypass_mode: actor.bypass_mode ?? 'always'
  }));
}

function ensureRule(rules, type) {
  const idx = rules.findIndex((rule) => rule?.type === type);
  if (idx === -1) {
    const rule = { type, parameters: {} };
    rules.push(rule);
    return rule;
  }
  if (!rules[idx].parameters || typeof rules[idx].parameters !== 'object') {
    rules[idx].parameters = {};
  }
  return rules[idx];
}

function updateMergeQueueRule(rules, expected) {
  const idx = rules.findIndex((rule) => rule?.type === 'merge_queue');
  if (!expected) {
    if (idx !== -1) {
      rules.splice(idx, 1);
    }
    return;
  }
  const rule = ensureRule(rules, 'merge_queue');
  rule.parameters = {
    ...(rule.parameters ?? {}),
    ...expected
  };
}

function updateStatusRule(rules, expected, actualRule) {
  if (!expected || expected.length === 0) {
    return;
  }
  const rule = ensureRule(rules, 'required_status_checks');
  const existingMap = new Map(
    (actualRule?.parameters?.required_status_checks ?? []).map((check) => [
      check.context,
      check.integration_id ?? null
    ])
  );
  rule.parameters = {
    strict_required_status_checks_policy:
      actualRule?.parameters?.strict_required_status_checks_policy ?? true,
    do_not_enforce_on_create: actualRule?.parameters?.do_not_enforce_on_create ?? false,
    required_status_checks: expected.map((context) => {
      const integrationId = existingMap.get(context);
      if (integrationId === null || integrationId === undefined) {
        return { context };
      }
      return {
        context,
        integration_id: integrationId
      };
    })
  };
}

function updatePullRequestRule(rules, expected, actualRule) {
  if (!expected) {
    return;
  }
  const rule = ensureRule(rules, 'pull_request');
  const parameters = { ...(actualRule?.parameters ?? {}) };
  const keys = [
    'required_approving_review_count',
    'dismiss_stale_reviews_on_push',
    'require_code_owner_review',
    'require_last_push_approval',
    'required_review_thread_resolution'
  ];
  for (const key of keys) {
    if (expected[key] !== undefined) {
      parameters[key] = expected[key];
    }
  }
  if (Array.isArray(expected.allowed_merge_methods)) {
    parameters.allowed_merge_methods = [...expected.allowed_merge_methods];
  }
  rule.parameters = parameters;
}

function updateOptionalParameterizedRule(rules, type, expected, actualRule) {
  const normalized = normalizeOptionalRuleExpectation(expected);
  if (normalized.mode === 'ignore') {
    return;
  }
  const idx = rules.findIndex((rule) => rule?.type === type);
  if (normalized.mode === 'absent') {
    if (idx !== -1) {
      rules.splice(idx, 1);
    }
    return;
  }

  const rule = idx === -1 ? ensureRule(rules, type) : ensureRule(rules, type);
  const expectedParameters = normalized.parameters ?? {};
  const hasExpectedParameters = Object.keys(expectedParameters).length > 0;
  rule.parameters = hasExpectedParameters
    ? {
        ...(actualRule?.parameters ?? rule.parameters ?? {}),
        ...structuredClone(expectedParameters)
      }
    : (actualRule?.parameters ?? rule.parameters ?? {});
}

function buildRulesetPayload(expectations, actual = null) {
  const updated = {
    name: actual?.name ?? expectations.name ?? 'ruleset',
    target: actual?.target ?? expectations.target ?? 'branch',
    enforcement: actual?.enforcement ?? 'active',
    conditions: structuredClone(actual?.conditions ?? {}),
    bypass_actors: sanitizeBypassActors(actual?.bypass_actors),
    rules: structuredClone(actual?.rules ?? [])
  };

  if (Array.isArray(expectations.includes)) {
    if (!updated.conditions.ref_name) {
      updated.conditions.ref_name = { include: [], exclude: [] };
    }
    updated.conditions.ref_name.include = expectations.includes;
  }

  const existingQueueRule = updated.rules.find((rule) => rule?.type === 'merge_queue');
  updateMergeQueueRule(updated.rules, expectations.merge_queue, existingQueueRule);

  const hasLinearRuleIndex = updated.rules.findIndex((rule) => rule?.type === 'required_linear_history');
  if (expectations.required_linear_history) {
    if (hasLinearRuleIndex === -1) {
      updated.rules.push({ type: 'required_linear_history' });
    }
  } else if (hasLinearRuleIndex !== -1) {
    updated.rules.splice(hasLinearRuleIndex, 1);
  }

  const existingStatusRule = updated.rules.find((rule) => rule?.type === 'required_status_checks');
  updateStatusRule(
    updated.rules,
    expectations.required_status_checks ?? [],
    existingStatusRule
  );

  const existingPullRequestRule = updated.rules.find((rule) => rule?.type === 'pull_request');
  updatePullRequestRule(updated.rules, expectations.pull_request, existingPullRequestRule);

  const existingCodeQualityRule = updated.rules.find((rule) => rule?.type === 'code_quality');
  updateOptionalParameterizedRule(updated.rules, 'code_quality', expectations.code_quality, existingCodeQualityRule);

  const existingCodeScanningRule = updated.rules.find((rule) => rule?.type === 'code_scanning');
  updateOptionalParameterizedRule(updated.rules, 'code_scanning', expectations.code_scanning, existingCodeScanningRule);

  const existingCopilotCodeReviewRule = updated.rules.find((rule) => rule?.type === 'copilot_code_review');
  updateOptionalParameterizedRule(
    updated.rules,
    'copilot_code_review',
    expectations.copilot_code_review,
    existingCopilotCodeReviewRule
  );

  return {
    name: updated.name,
    target: updated.target,
    enforcement: updated.enforcement,
    conditions: updated.conditions,
    bypass_actors: updated.bypass_actors,
    rules: updated.rules
  };
}

async function applyBranchProtection(repoUrl, token, branch, expected, actual, fetchFn, logFn = console.log, options = {}) {
  const protectionUrl = `${repoUrl}/branches/${encodeURIComponent(branch)}/protection`;
  const payload = buildBranchProtectionPayload(expected, actual, {
    skipRequiredStatusChecks: options.skipRequiredStatusChecks === true
  });
  await requestJson(protectionUrl, token, { method: 'PUT', body: payload, fetchFn });
  logFn(`[policy] branch ${branch}: applied protection settings.`);
}

async function applyRuleset(repoUrl, token, id, expectations, actual, fetchFn, logFn = console.log) {
  const rulesetUrl = `${repoUrl}/rulesets/${id}`;
  const payload = buildRulesetPayload(expectations, actual);
  await requestJson(rulesetUrl, token, { method: 'PUT', body: payload, fetchFn });
  logFn(`[policy] ruleset ${id}: applied configuration.`);
}

async function createRuleset(repoUrl, token, expectations, fetchFn, logFn = console.log) {
  const rulesetUrl = `${repoUrl}/rulesets`;
  const payload = buildRulesetPayload(expectations);
  const created = await requestJson(rulesetUrl, token, { method: 'POST', body: payload, fetchFn });
  const suffix = created?.id ? ` as ${created.id}` : '';
  logFn(`[policy] ruleset ${expectations?.name ?? 'unknown'}: created${suffix}.`);
  return created;
}

async function collectState(manifest, repoUrl, token, fetchFn, logFn = console.log) {
  const repoData = await fetchJson(repoUrl, token, fetchFn);

  const branchStates = [];
  for (const [branch, expectations] of Object.entries(manifest.branches ?? {})) {
    const state = { branch, expectations, protection: null, error: null, skipReason: null };
    if (isBranchPattern(branch)) {
      state.skipReason = 'pattern';
      branchStates.push(state);
      continue;
    }
    try {
      const protectionUrl = `${repoUrl}/branches/${encodeURIComponent(branch)}/protection`;
      state.protection = await fetchJson(protectionUrl, token, fetchFn);
    } catch (error) {
      state.error = error;
    }
    branchStates.push(state);
  }

  const rulesetStates = [];
  let rulesetListPromise = null;
  const loadRulesets = async () => {
    if (!rulesetListPromise) {
      rulesetListPromise = listRulesets(repoUrl, token, fetchFn);
    }
    return rulesetListPromise;
  };
  for (const [rulesetId, expectations] of Object.entries(manifest.rulesets ?? {})) {
    const numericId = Number(rulesetId);
    const state = {
      id: numericId,
      expectations,
      ruleset: null,
      error: null,
      resolvedId: Number.isNaN(numericId) ? null : numericId,
      resolvedBy: 'id'
    };
    if (Number.isNaN(numericId)) {
      state.error = new Error('invalid id');
      rulesetStates.push(state);
      continue;
    }
    try {
      const rulesetUrl = `${repoUrl}/rulesets/${numericId}`;
      state.ruleset = await fetchJson(rulesetUrl, token, fetchFn);
    } catch (error) {
      if (isNotFoundError(error)) {
        try {
          const rulesets = await loadRulesets();
          const detailedMatches = [];
          for (const candidate of rulesets) {
            if (!rulesetSummaryMatches(expectations, candidate)) {
              continue;
            }
            const detailedRuleset = candidate.id
              ? await fetchJson(`${repoUrl}/rulesets/${candidate.id}`, token, fetchFn)
              : candidate;
            detailedMatches.push(detailedRuleset);
          }
          const selection = selectRulesetIdentityCandidate(expectations, detailedMatches);
          const matchedRuleset = selection.match;
          if (matchedRuleset) {
            state.resolvedId = matchedRuleset.id ?? numericId;
            state.resolvedBy = 'identity';
            if (matchedRuleset.id && matchedRuleset.id !== numericId) {
              const driftNote =
                selection.resolution === 'summary'
                  ? ' via name/target; include drift will be corrected during apply.'
                  : '.';
              logFn(`[policy] ruleset ${numericId}: resolved by stable identity to ${matchedRuleset.id}${driftNote}`);
            }
            state.ruleset = matchedRuleset;
          } else if (selection.error) {
            state.error = selection.error;
          } else {
            state.error = error;
          }
        } catch (lookupError) {
          state.error = lookupError;
        }
      } else {
        state.error = error;
      }
    }
    rulesetStates.push(state);
  }

  return { repoData, branchStates, rulesetStates };
}

async function refreshBranchStates(branchStates, repoUrl, token, fetchFn) {
  const refreshed = [];
  for (const entry of branchStates) {
    const state = {
      branch: entry.branch,
      expectations: entry.expectations,
      protection: null,
      error: null,
      skipReason: entry.skipReason ?? null
    };
    if (state.skipReason === 'pattern') {
      refreshed.push(state);
      continue;
    }
    try {
      const protectionUrl = `${repoUrl}/branches/${encodeURIComponent(entry.branch)}/protection`;
      state.protection = await fetchJson(protectionUrl, token, fetchFn);
    } catch (branchError) {
      state.error = branchError;
    }
    refreshed.push(state);
  }
  return refreshed;
}

function mergeBranchStatesByName(branchStates, refreshedBranchStates) {
  const replacements = new Map(refreshedBranchStates.map((entry) => [entry.branch, entry]));
  return branchStates.map((entry) => replacements.get(entry.branch) ?? entry);
}

function evaluateDiffs(manifest, state, options = {}) {
  const repoDiffs = compareRepoSettings(manifest.repo ?? {}, state.repoData ?? {});
  const queueManagedBranches =
    options.queueManagedBranches instanceof Set
      ? options.queueManagedBranches
      : deriveQueueManagedBranches(manifest);
  const ignoreRulesetDiffs = options.ignoreRulesetDiffs === true;
  const ignoreRulesetEntryFn =
    typeof options.ignoreRulesetEntryFn === 'function' ? options.ignoreRulesetEntryFn : () => false;

  const branchDiffs = [];
  for (const entry of state.branchStates) {
    if (entry.skipReason === 'pattern') {
      continue;
    }
    if (entry.error) {
      branchDiffs.push(`branch ${entry.branch}: failed to load protection -> ${entry.error.message}`);
      continue;
    }
    branchDiffs.push(
      ...compareBranchSettings(entry.branch, entry.expectations, entry.protection, {
        skipRequiredStatusChecks: queueManagedBranches.has(entry.branch)
      })
    );
  }

  const rulesetDiffs = [];
  if (!ignoreRulesetDiffs) {
    for (const entry of state.rulesetStates) {
      if (ignoreRulesetEntryFn(entry)) {
        continue;
      }
      if (entry.error) {
        rulesetDiffs.push(
          `ruleset ${entry.id}: failed to load -> ${entry.error.message}`
        );
        continue;
      }
      rulesetDiffs.push(
        ...prefixRulesetDiffs(
          entry.resolvedId ?? entry.id,
          compareRuleset(entry.resolvedId ?? entry.id, entry.expectations, entry.ruleset)
        )
      );
    }
  }

  return { repoDiffs, branchDiffs, rulesetDiffs };
}

function collectBranchStatesNeedingUpdates(branchStates, queueManagedBranches) {
  return branchStates.filter((entry) => {
    if (entry.skipReason === 'pattern') {
      return false;
    }
    if (entry.error) {
      return isNotFoundError(entry.error);
    }
    const diffs = compareBranchSettings(
      entry.branch,
      entry.expectations,
      entry.protection,
      {
        skipRequiredStatusChecks: queueManagedBranches.has(entry.branch)
      }
    );
    return diffs.length > 0;
  });
}

export async function run({
  argv = process.argv,
  env = process.env,
  fetchFn = globalThis.fetch,
  execSyncFn = execSync,
  log = console.log,
  error = console.error,
  manifestOverride = null
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    log('Usage: node tools/priority/check-policy.mjs [--apply] [--debug] [--report <path>] [--fail-on-skip]');
    return 0;
  }

  const report = {
    schema: 'priority/policy-report@v1',
    schemaVersion: '1.0.0',
    generatedAt: new Date().toISOString(),
    apply: options.apply,
    repository: null,
    authSource: null,
    forkRun: false,
    portability: {
      rulesetMode: 'standard',
      queueManagedRulesetsPortable: true,
      detectedBy: 'default',
      reason: null
    },
    result: 'unknown',
    skippedReason: null,
    summary: {
      repoDiffCount: 0,
      branchDiffCount: 0,
      rulesetDiffCount: 0,
      totalDiffCount: 0
    },
    diffs: {
      repo: [],
      branch: [],
      ruleset: []
    },
    applied: {
      branches: [],
      rulesets: []
    },
    errors: []
  };

  const applyDiffsToReport = (diffs) => {
    report.diffs.repo = [...diffs.repoDiffs];
    report.diffs.branch = [...diffs.branchDiffs];
    report.diffs.ruleset = [...diffs.rulesetDiffs];
    report.summary = {
      repoDiffCount: report.diffs.repo.length,
      branchDiffCount: report.diffs.branch.length,
      rulesetDiffCount: report.diffs.ruleset.length,
      totalDiffCount: report.diffs.repo.length + report.diffs.branch.length + report.diffs.ruleset.length
    };
  };

  const finalize = async ({ code, result, skippedReason = null }) => {
    report.result = result;
    report.skippedReason = skippedReason;
    await writeReportIfRequested(options.report, report, log);
    return code;
  };

  const finalizeSkip = async (message) => {
    if (options.failOnSkip) {
      const strictMessage = `${message} Strict mode enabled (--fail-on-skip), failing.`;
      error(strictMessage);
      return finalize({
        code: 1,
        result: 'fail',
        skippedReason: strictMessage
      });
    }

    log(message);
    return finalize({
      code: 0,
      result: 'skipped',
      skippedReason: message
    });
  };

  try {
    const dbg = options.debug ? (...args) => log('[policy][debug]', ...args) : () => {};

    const manifest = manifestOverride ?? await loadManifest();
    const forkRun = await detectForkRun(env);
    report.forkRun = forkRun;
    const tokenCandidates = await resolveTokenCandidates(env);
    if (tokenCandidates.length === 0) {
      throw new Error('GitHub token not found. Set GITHUB_TOKEN, GH_TOKEN, or GH_TOKEN_FILE.');
    }
    let activeTokenIndex = 0;
    let activeTokenResult = tokenCandidates[activeTokenIndex];
    report.authSource = activeTokenResult.source;
    log(`[policy] auth source: ${activeTokenResult.source}`);

    const invokeWithAuthFallback = async (operationName, operationFn) => {
      const attemptedSources = [activeTokenResult.source];
      try {
        return await operationFn(activeTokenResult.token);
      } catch (initialError) {
        if (!isUnauthorizedAuthError(initialError)) {
          throw initialError;
        }

        const fallback = tokenCandidates.find(
          (candidate, index) => index > activeTokenIndex && candidate.token !== activeTokenResult.token
        );
        if (!fallback) {
          throw createAuthUnavailableError(
            operationName,
            attemptedSources,
            `No fallback token available. Last error: ${initialError.message}`
          );
        }

        log(`[policy] auth fallback: ${activeTokenResult.source} -> ${fallback.source} (401 Unauthorized)`);
        activeTokenIndex = tokenCandidates.indexOf(fallback);
        activeTokenResult = fallback;
        report.authSource = activeTokenResult.source;
        attemptedSources.push(activeTokenResult.source);

        try {
          return await operationFn(activeTokenResult.token);
        } catch (fallbackError) {
          if (isUnauthorizedAuthError(fallbackError)) {
            throw createAuthUnavailableError(
              operationName,
              attemptedSources,
              `Last error: ${fallbackError.message}`
            );
          }
          throw fallbackError;
        }
      }
    };

    const { owner, repo } = getRepoFromEnv(env, execSyncFn);
    report.repository = `${owner}/${repo}`;
    dbg(`Resolved repository ${owner}/${repo}`);
    if (activeTokenResult?.source) {
      dbg(`Token source ${activeTokenResult.source}`);
    }
    const repoUrl = `https://api.github.com/repos/${owner}/${repo}`;

    let initialState;
    try {
      initialState = await invokeWithAuthFallback('collectState', (token) =>
        collectState(manifest, repoUrl, token, fetchFn, log)
      );
    } catch (authError) {
      if (!options.apply && authError?.code === 'POLICY_AUTH_UNAVAILABLE') {
        const attempted = Array.isArray(authError.attemptedSources) && authError.attemptedSources.length > 0
          ? authError.attemptedSources.join(' -> ')
          : 'unknown';
        const message = `[policy] Authorization unavailable for policy check (attempted: ${attempted}); skipping non-apply validation. Upstream status "Policy Guard (Upstream) / policy-guard" remains authoritative.`;
        return finalizeSkip(message);
      }
      throw authError;
    }
    if (options.debug) {
      const repoKeys = initialState.repoData ? Object.keys(initialState.repoData) : [];
      dbg(`Repo response keys: ${repoKeys.length ? repoKeys.join(', ') : '(none)'}`);
      for (const entry of initialState.branchStates) {
        if (entry.error) {
          dbg(`Branch ${entry.branch} protection fetch error: ${entry.error.message}`);
        } else {
          const protection = entry.protection ?? {};
          dbg(`Branch ${entry.branch} protection keys: ${Object.keys(protection).join(', ') || '(none)'}`);
        }
      }
      for (const entry of initialState.rulesetStates) {
        if (entry.error) {
          dbg(`Ruleset ${entry.id} fetch error: ${entry.error.message}`);
        } else {
          const rule = entry.ruleset ?? {};
          dbg(
            `Ruleset ${entry.id} keys: ${Object.keys(rule).join(', ') || '(none)'} ` +
            `(resolvedId=${entry.resolvedId ?? 'n/a'}, via=${entry.resolvedBy})`
          );
        }
      }
    }

    const repositorySlug = `${owner}/${repo}`;
    const manifestPortabilityOverride = resolveManifestPortabilityOverride(manifest, repositorySlug);
    if (
      manifestPortabilityOverride?.queueManagedRulesetsPortable === false &&
      initialState.repoData?.fork !== true
    ) {
      throw new Error(
        `Invalid repo portability profile for ${repositorySlug}: throughput-fork-relaxed requires a fork repository.`
      );
    }
    let portabilityProfile = buildRulesetPortabilityProfile(initialState.repoData, manifestPortabilityOverride ?? {});
    report.portability = portabilityProfile;
    if (portabilityProfile.queueManagedRulesetsPortable === false && manifestPortabilityOverride) {
      log(
        `[policy] Portability profile override detected for ${report.repository}; queue-managed fork-local ruleset enforcement is relaxed for this repository.`
      );
    } else if (portabilityProfile.queueManagedRulesetsPortable === false) {
      log('[policy] Queue-managed fork-local ruleset enforcement is relaxed for this repository.');
    }

    let queueManagedBranches = deriveActiveQueueManagedBranches(manifest, portabilityProfile);
    const initialDiffs = evaluateDiffs(manifest, initialState, {
      queueManagedBranches,
      ignoreRulesetEntryFn: (entry) => shouldIgnoreRulesetEntry(entry, portabilityProfile)
    });
    applyDiffsToReport(initialDiffs);

    const allDiffs = [
      ...initialDiffs.repoDiffs,
      ...initialDiffs.branchDiffs,
      ...initialDiffs.rulesetDiffs
    ];

    const missingRepoFields = initialDiffs.repoDiffs.filter((diff) => diff.includes('actual undefined'));
    const repoFieldsAllMissing =
      initialDiffs.repoDiffs.length > 0 && missingRepoFields.length === initialDiffs.repoDiffs.length;
    const hasAdminPermission = initialState.repoData?.permissions?.admin === true;

    if (!options.apply && repoFieldsAllMissing && (!hasAdminPermission || forkRun)) {
      const message = '[policy] Repository settings unavailable with current token; skipping policy check (admin permissions required). Upstream status "Policy Guard (Upstream) / policy-guard" will enforce branch protection.';
      return finalizeSkip(message);
    }

    if (options.apply) {
      const applyBranchUpdates = async (branchStates) => {
        for (const entry of branchStates) {
          const skipRequiredStatusChecks = queueManagedBranches.has(entry.branch);
          await invokeWithAuthFallback(`applyBranchProtection(${entry.branch})`, (token) =>
            applyBranchProtection(
              repoUrl,
              token,
              entry.branch,
              entry.expectations,
              entry.protection,
              fetchFn,
              log,
              { skipRequiredStatusChecks }
            )
          );
          if (!report.applied.branches.includes(entry.branch)) {
            report.applied.branches.push(entry.branch);
          }
        }
      };
      let branchStatesForApply = initialState.branchStates;

      for (const entry of initialState.rulesetStates) {
        if (shouldIgnoreRulesetEntry(entry, portabilityProfile)) {
          continue;
        }

        const needsUpdate = entry.error
          ? isNotFoundError(entry.error)
          : compareRuleset(entry.resolvedId ?? entry.id, entry.expectations, entry.ruleset).length > 0;
        if (!needsUpdate) {
          continue;
        }

        try {
          if (entry.error && isNotFoundError(entry.error)) {
            const created = await invokeWithAuthFallback(`createRuleset(${entry.id})`, (token) =>
              createRuleset(repoUrl, token, entry.expectations, fetchFn, log)
            );
            report.applied.rulesets.push(created?.id ?? entry.id);
            continue;
          }

          const appliedRulesetId = entry.resolvedId ?? entry.id;
          await invokeWithAuthFallback(`applyRuleset(${appliedRulesetId})`, (token) =>
            applyRuleset(
              repoUrl,
              token,
              appliedRulesetId,
              entry.expectations,
              entry.ruleset,
              fetchFn,
              log
            )
          );
          report.applied.rulesets.push(appliedRulesetId);
        } catch (rulesetError) {
          if (
            initialState.repoData?.fork === true &&
            isQueueManagedRulesetExpectation(entry.expectations) &&
            isMergeQueueRulesetUnsupportedError(rulesetError)
          ) {
            const previouslyQueueManagedBranches = new Set(queueManagedBranches);
            portabilityProfile = buildRulesetPortabilityProfile(initialState.repoData, {
              queueManagedRulesetsPortable: false,
              detectedBy: 'api-rejection',
              reason: `ruleset ${entry.id}: merge_queue unsupported`
            });
            report.portability = portabilityProfile;
            queueManagedBranches = deriveActiveQueueManagedBranches(manifest, portabilityProfile);
            log(
              `[policy] Fork ruleset portability downgrade detected for ${report.repository}: merge_queue rules are unsupported on this fork. Continuing with non-queue ruleset enforcement only.`
            );
            const refreshedBranchStates = await invokeWithAuthFallback(
              'refreshBranchStates(portability-downgrade)',
              (token) =>
                refreshBranchStates(
                  branchStatesForApply.filter((branchState) => previouslyQueueManagedBranches.has(branchState.branch)),
                  repoUrl,
                  token,
                  fetchFn
                )
            );
            branchStatesForApply = mergeBranchStatesByName(
              branchStatesForApply,
              refreshedBranchStates
            );
            continue;
          }
          throw rulesetError;
        }
      }

      await applyBranchUpdates(collectBranchStatesNeedingUpdates(branchStatesForApply, queueManagedBranches));

      const postState = await invokeWithAuthFallback('collectState(post-apply)', (token) =>
        collectState(manifest, repoUrl, token, fetchFn, log)
      );
      const postDiffs = evaluateDiffs(manifest, postState, {
        queueManagedBranches,
        ignoreRulesetEntryFn: (entry) => shouldIgnoreRulesetEntry(entry, portabilityProfile)
      });
      applyDiffsToReport(postDiffs);
      const remainingDiffs = [
        ...postDiffs.repoDiffs,
        ...postDiffs.branchDiffs,
        ...postDiffs.rulesetDiffs
      ];

      if (remainingDiffs.length > 0) {
        error('Merge policy mismatches detected after apply:');
        for (const diff of remainingDiffs) {
          error(` - ${diff}`);
        }
        return finalize({ code: 1, result: 'fail' });
      }

      log('Merge policy apply completed successfully.');
      return finalize({ code: 0, result: 'applied' });
    }

    if (allDiffs.length > 0) {
      if (missingRepoFields.length > 0 && !options.debug) {
        error(
          '[policy] Repository settings were returned as undefined. Ensure the provided token has admin access to the repository or rerun with --debug for more details.'
        );
      }
      error('Merge policy mismatches detected:');
      for (const diff of allDiffs) {
        error(` - ${diff}`);
      }
      return finalize({ code: 1, result: 'fail' });
    }

    log('Merge policy check passed.');
    return finalize({ code: 0, result: 'pass' });
  } catch (errObj) {
    report.result = report.result === 'unknown' ? 'error' : report.result;
    report.errors.push(errObj?.message ?? String(errObj));
    await writeReportIfRequested(options.report, report, log);
    throw errObj;
  }
}

export const __test = Object.freeze({
  compareBranchSettings,
  compareBranchBooleanSetting,
  compareBranchNullableSetting,
  buildBranchProtectionPayload,
  buildRulesetPayload,
  resolveEnabledFlag,
  compareOptionalParameterizedRule,
  normalizeOptionalRuleExpectation,
  normalizeRulesetListResponse,
  normalizeRulesetIncludes,
  mergeBranchStatesByName,
  prefixRulesetDiffs,
  rulesetIncludesMatch,
  rulesetIdentityMatches,
  selectRulesetIdentityCandidate
});

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  run()
    .then((code) => {
      if (code !== 0) {
        process.exitCode = code;
      }
    })
    .catch((err) => {
      console.error(`Policy check failed: ${err.stack ?? err.message}`);
      process.exitCode = 1;
    });
}

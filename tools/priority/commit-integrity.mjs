#!/usr/bin/env node

import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import { execSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'commit-integrity',
  'commit-integrity-report.json'
);
const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'commit-integrity-policy.json');
const DEFAULT_POLICY_CHECKS = Object.freeze({
  requireAuthorAttribution: true,
  requireCommitterAttribution: true,
  requireKnownReasonForUnverified: true,
  requireUniqueShas: true,
  requireNonEmptyHeadline: true,
  maxHeadlineLength: 120,
  requireSignatureMaterialForVerified: false,
  requireRequiredTrailer: false,
  requiredTrailerRules: Object.freeze([])
});

function extractCommitTrailers(message) {
  const normalizedMessage = normalizeOptionalString(message) ?? '';
  if (!normalizedMessage) {
    return [];
  }
  const lines = normalizedMessage.split(/\r?\n/);
  if (lines.length < 2) {
    return [];
  }

  let index = lines.length - 1;
  while (index >= 0 && !lines[index].trim()) {
    index -= 1;
  }
  if (index < 0) {
    return [];
  }

  const trailers = [];
  while (index >= 0 && lines[index].trim()) {
    const line = lines[index].trim();
    const match = line.match(/^([A-Za-z0-9-]+):\s*(.+)$/);
    if (!match) {
      return [];
    }
    trailers.unshift({
      key: match[1],
      value: match[2].trim()
    });
    index -= 1;
  }

  if (trailers.length === 0) {
    return [];
  }
  // Require the trailer block to be separated from body/headline by a blank line.
  if (index < 0 || lines[index].trim() !== '') {
    return [];
  }
  return trailers;
}

function printUsage() {
  console.log('Usage: node tools/priority/commit-integrity.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>    Target repository (default: GITHUB_REPOSITORY or git remote).');
  console.log('  --pr <number>          Pull request number to evaluate.');
  console.log('  --base-sha <sha>       Base SHA for compare mode.');
  console.log('  --head-sha <sha>       Head SHA for compare mode.');
  console.log(`  --policy <path>        Policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --report <path>        Report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --observe-only         Do not fail the process when violations are present.');
  console.log('  -h, --help             Show usage.');
}

function parsePositiveInteger(value, { label }) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`Invalid ${label} value '${value}'. Expected a positive integer.`);
  }
  return parsed;
}

function normalizeSha(value) {
  const normalized = String(value ?? '')
    .trim()
    .toLowerCase();
  return normalized || null;
}

function normalizeOptionalString(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized || null;
}

function firstLine(value) {
  const normalized = normalizeOptionalString(value) ?? '';
  if (!normalized) {
    return '';
  }
  const idx = normalized.indexOf('\n');
  if (idx === -1) {
    return normalized;
  }
  return normalized.slice(0, idx).trim();
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = url.match(/:(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const httpsMatch = url.match(/github\.com\/(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) {
    return null;
  }
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return { owner, repo };
}

function resolveRepoFromGit(execSyncFn = execSync) {
  for (const remoteName of ['upstream', 'origin']) {
    try {
      const remoteUrl = execSyncFn(`git config --get remote.${remoteName}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString()
        .trim();
      const parsed = parseRemoteUrl(remoteUrl);
      if (parsed) {
        return `${parsed.owner}/${parsed.repo}`;
      }
    } catch {
      // ignore missing remote
    }
  }
  return '';
}

function resolveRepository(options, env = process.env, execSyncFn = execSync) {
  const fromArgs = normalizeOptionalString(options.repo);
  if (fromArgs) {
    if (!fromArgs.includes('/')) {
      throw new Error(`Invalid --repo value '${fromArgs}'. Expected owner/repo.`);
    }
    return fromArgs;
  }

  const fromEnv = normalizeOptionalString(env.GITHUB_REPOSITORY);
  if (fromEnv && fromEnv.includes('/')) {
    return fromEnv;
  }

  const fromGit = resolveRepoFromGit(execSyncFn);
  if (fromGit) {
    return fromGit;
  }

  throw new Error('Unable to determine repository. Pass --repo or set GITHUB_REPOSITORY.');
}

async function resolveToken(env = process.env, { readFileFn = readFile, accessFn = access } = {}) {
  const envCandidates = [env.GH_TOKEN, env.GITHUB_TOKEN, env.GH_ENTERPRISE_TOKEN];
  for (const candidate of envCandidates) {
    const token = normalizeOptionalString(candidate);
    if (token) {
      return token;
    }
  }

  const fileCandidates = [env.GH_TOKEN_FILE];
  if (process.platform === 'win32') {
    fileCandidates.push('C:\\github_token.txt');
  }
  for (const filePath of fileCandidates) {
    const normalizedPath = normalizeOptionalString(filePath);
    if (!normalizedPath) {
      continue;
    }
    try {
      await accessFn(normalizedPath);
      const token = normalizeOptionalString(await readFileFn(normalizedPath, 'utf8'));
      if (token) {
        return token;
      }
    } catch {
      // ignore file read failures
    }
  }

  throw new Error('GitHub token not found. Set GITHUB_TOKEN, GH_TOKEN, or GH_TOKEN_FILE.');
}

async function loadEventPayload(env = process.env, { readFileFn = readFile } = {}) {
  const eventPath = normalizeOptionalString(env.GITHUB_EVENT_PATH);
  if (!eventPath) {
    return null;
  }
  try {
    const raw = await readFileFn(eventPath, 'utf8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function resolveScope(options, env = process.env, eventPayload = null) {
  if (options.pr !== null) {
    return {
      mode: 'pull_request',
      pullRequest: options.pr,
      baseSha: null,
      headSha: null
    };
  }

  if (options.baseSha && options.headSha) {
    return {
      mode: 'compare',
      pullRequest: null,
      baseSha: options.baseSha,
      headSha: options.headSha
    };
  }

  if (env.GITHUB_EVENT_NAME === 'pull_request') {
    const prNumber = Number(eventPayload?.pull_request?.number);
    if (Number.isInteger(prNumber) && prNumber > 0) {
      return {
        mode: 'pull_request',
        pullRequest: prNumber,
        baseSha: null,
        headSha: null
      };
    }
  }

  if (env.GITHUB_EVENT_NAME === 'merge_group') {
    const baseSha = normalizeSha(eventPayload?.merge_group?.base_sha);
    const headSha = normalizeSha(eventPayload?.merge_group?.head_sha);
    if (baseSha && headSha) {
      return {
        mode: 'compare',
        pullRequest: null,
        baseSha,
        headSha
      };
    }
  }

  throw new Error(
    'Unable to resolve commit scope. Provide --pr <number> or --base-sha/--head-sha (required for workflow_dispatch).'
  );
}

function compileRegexList(values, { label }) {
  const compiled = [];
  for (const value of Array.isArray(values) ? values : []) {
    const pattern = normalizeOptionalString(value);
    if (!pattern) {
      continue;
    }
    try {
      compiled.push(new RegExp(pattern, 'i'));
    } catch (error) {
      throw new Error(`Invalid ${label} regex '${pattern}': ${error.message}`);
    }
  }
  return compiled;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: '',
    pr: null,
    baseSha: null,
    headSha: null,
    policyPath: DEFAULT_POLICY_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    observeOnly: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--help' || arg === '-h') {
      printUsage();
      process.exit(0);
    }
    if (arg === '--observe-only') {
      options.observeOnly = true;
      continue;
    }
    if (arg === '--repo' || arg === '--pr' || arg === '--base-sha' || arg === '--head-sha' || arg === '--policy' || arg === '--report') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--repo') {
        options.repo = String(next).trim();
      } else if (arg === '--pr') {
        options.pr = parsePositiveInteger(next, { label: '--pr' });
      } else if (arg === '--base-sha') {
        options.baseSha = normalizeSha(next);
      } else if (arg === '--head-sha') {
        options.headSha = normalizeSha(next);
      } else if (arg === '--policy') {
        options.policyPath = next;
      } else if (arg === '--report') {
        options.reportPath = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  if ((options.baseSha && !options.headSha) || (!options.baseSha && options.headSha)) {
    throw new Error('Both --base-sha and --head-sha are required for compare mode.');
  }

  return options;
}

export function classifySourceKind(commit, sourceResolution) {
  const authorLogin = normalizeOptionalString(commit.authorLogin);
  const committerLogin = normalizeOptionalString(commit.committerLogin);
  const authorEmail = normalizeOptionalString(commit.authorEmail);
  const committerEmail = normalizeOptionalString(commit.committerEmail);

  for (const regex of sourceResolution.botLoginRegexes) {
    if ((authorLogin && regex.test(authorLogin)) || (committerLogin && regex.test(committerLogin))) {
      return 'bot';
    }
  }
  for (const regex of sourceResolution.botEmailRegexes) {
    if ((authorEmail && regex.test(authorEmail)) || (committerEmail && regex.test(committerEmail))) {
      return 'bot';
    }
  }

  return 'human';
}

export function normalizeCommitRecord(rawRecord, sourceResolution) {
  const sha = normalizeSha(rawRecord?.sha);
  if (!sha) {
    return null;
  }

  const commit = rawRecord?.commit ?? {};
  const fullMessage = normalizeOptionalString(commit?.message) ?? '';
  const verification = commit?.verification ?? {};
  const verificationReason = normalizeOptionalString(verification?.reason) ?? 'unknown';
  const normalized = {
    sha,
    url: normalizeOptionalString(rawRecord?.html_url),
    messageHeadline: firstLine(fullMessage),
    trailers: extractCommitTrailers(fullMessage),
    verified: verification?.verified === true,
    verificationReason,
    verificationSignaturePresent: Boolean(normalizeOptionalString(verification?.signature)),
    verificationPayloadPresent: Boolean(normalizeOptionalString(verification?.payload)),
    authorLogin: normalizeOptionalString(rawRecord?.author?.login),
    committerLogin: normalizeOptionalString(rawRecord?.committer?.login),
    authorEmail: normalizeOptionalString(commit?.author?.email),
    committerEmail: normalizeOptionalString(commit?.committer?.email)
  };
  normalized.sourceKind = classifySourceKind(normalized, sourceResolution);
  return normalized;
}

function commitSort(left, right) {
  if (left.sha !== right.sha) {
    return left.sha.localeCompare(right.sha);
  }
  const leftUrl = left.url ?? '';
  const rightUrl = right.url ?? '';
  if (leftUrl !== rightUrl) {
    return leftUrl.localeCompare(rightUrl);
  }
  return (left.messageHeadline ?? '').localeCompare(right.messageHeadline ?? '');
}

export function normalizeCommitRecords(rawRecords, sourceResolution) {
  const normalized = [];
  for (const rawRecord of Array.isArray(rawRecords) ? rawRecords : []) {
    const record = normalizeCommitRecord(rawRecord, sourceResolution);
    if (!record) {
      continue;
    }
    normalized.push(record);
  }
  normalized.sort(commitSort);
  return normalized;
}

function normalizeChecks(checks = {}) {
  const rawMaxHeadlineLength = Number(checks.maxHeadlineLength);
  const normalizedMaxHeadlineLength =
    Number.isInteger(rawMaxHeadlineLength) && rawMaxHeadlineLength > 0
      ? rawMaxHeadlineLength
      : DEFAULT_POLICY_CHECKS.maxHeadlineLength;

  const normalizedRequiredTrailerRules = [];
  for (const [index, rawRule] of (Array.isArray(checks.requiredTrailerRules) ? checks.requiredTrailerRules : []).entries()) {
    const key = normalizeOptionalString(rawRule?.key);
    const valuePattern = normalizeOptionalString(rawRule?.valuePattern);
    if (!key || !valuePattern) {
      continue;
    }
    try {
      normalizedRequiredTrailerRules.push({
        key,
        keyLower: key.toLowerCase(),
        valuePattern,
        valueRegex: new RegExp(valuePattern)
      });
    } catch (error) {
      throw new Error(`Invalid trailer rule at index ${index}: ${error.message}`);
    }
  }

  return {
    requireAuthorAttribution:
      checks.requireAuthorAttribution !== undefined
        ? Boolean(checks.requireAuthorAttribution)
        : DEFAULT_POLICY_CHECKS.requireAuthorAttribution,
    requireCommitterAttribution:
      checks.requireCommitterAttribution !== undefined
        ? Boolean(checks.requireCommitterAttribution)
        : DEFAULT_POLICY_CHECKS.requireCommitterAttribution,
    requireKnownReasonForUnverified:
      checks.requireKnownReasonForUnverified !== undefined
        ? Boolean(checks.requireKnownReasonForUnverified)
        : DEFAULT_POLICY_CHECKS.requireKnownReasonForUnverified,
    requireUniqueShas:
      checks.requireUniqueShas !== undefined
        ? Boolean(checks.requireUniqueShas)
        : DEFAULT_POLICY_CHECKS.requireUniqueShas,
    requireNonEmptyHeadline:
      checks.requireNonEmptyHeadline !== undefined
        ? Boolean(checks.requireNonEmptyHeadline)
        : DEFAULT_POLICY_CHECKS.requireNonEmptyHeadline,
    maxHeadlineLength: normalizedMaxHeadlineLength,
    requireSignatureMaterialForVerified:
      checks.requireSignatureMaterialForVerified !== undefined
        ? Boolean(checks.requireSignatureMaterialForVerified)
        : DEFAULT_POLICY_CHECKS.requireSignatureMaterialForVerified,
    requireRequiredTrailer:
      checks.requireRequiredTrailer !== undefined
        ? Boolean(checks.requireRequiredTrailer)
        : DEFAULT_POLICY_CHECKS.requireRequiredTrailer,
    requiredTrailerRules:
      normalizedRequiredTrailerRules.length > 0
        ? normalizedRequiredTrailerRules
        : DEFAULT_POLICY_CHECKS.requiredTrailerRules
  };
}

function hasAuthorAttribution(commit) {
  return Boolean(commit.authorLogin || commit.authorEmail);
}

function hasCommitterAttribution(commit) {
  return Boolean(commit.committerLogin || commit.committerEmail);
}

function addViolation(violations, commit, category, reason) {
  violations.push({
    category,
    sha: commit.sha,
    reason,
    messageHeadline: commit.messageHeadline,
    sourceKind: commit.sourceKind,
    authorLogin: commit.authorLogin,
    committerLogin: commit.committerLogin
  });
}

function evaluateRequiredTrailer(commit, requiredTrailerRules) {
  const trailers = Array.isArray(commit?.trailers) ? commit.trailers : [];
  if (!Array.isArray(requiredTrailerRules) || requiredTrailerRules.length === 0) {
    return {
      passed: false,
      category: 'required-trailer-rules-empty',
      reason: 'required trailer rules are empty'
    };
  }

  for (const rule of requiredTrailerRules) {
    const matchingKey = trailers.filter((entry) => String(entry?.key || '').toLowerCase() === rule.keyLower);
    if (matchingKey.some((entry) => rule.valueRegex.test(String(entry.value ?? '')))) {
      return {
        passed: true,
        category: null,
        reason: null
      };
    }
  }

  const hasRequiredKey = trailers.some((entry) =>
    requiredTrailerRules.some((rule) => String(entry?.key || '').toLowerCase() === rule.keyLower)
  );
  if (hasRequiredKey) {
    return {
      passed: false,
      category: 'invalid-required-trailer-format',
      reason: 'required trailer present but value does not match policy'
    };
  }
  return {
    passed: false,
    category: 'missing-required-trailer',
    reason: 'required trailer not found'
  };
}

export function evaluateCommitIntegrity(commits, { checks = {} } = {}) {
  const list = Array.isArray(commits) ? commits : [];
  const effectiveChecks = normalizeChecks(checks);
  const issues = [];
  const violations = [];
  const checkResults = [];
  const duplicateShas = new Set();
  const seenShas = new Set();

  if (effectiveChecks.requireUniqueShas) {
    for (const commit of list) {
      if (seenShas.has(commit.sha)) {
        duplicateShas.add(commit.sha);
      } else {
        seenShas.add(commit.sha);
      }
    }
    for (const duplicateSha of duplicateShas) {
      const example = list.find((commit) => commit.sha === duplicateSha);
      addViolation(violations, example ?? { sha: duplicateSha }, 'duplicate-commit-sha', 'duplicate commit SHA in scope');
    }
  }

  if (effectiveChecks.requireRequiredTrailer && effectiveChecks.requiredTrailerRules.length === 0) {
    issues.push('required-trailer-rules-empty');
  }

  for (const commit of list) {
    if (effectiveChecks.requireNonEmptyHeadline && !commit.messageHeadline) {
      addViolation(violations, commit, 'empty-headline', 'commit headline is empty');
    }
    if (effectiveChecks.maxHeadlineLength > 0 && (commit.messageHeadline?.length ?? 0) > effectiveChecks.maxHeadlineLength) {
      addViolation(
        violations,
        commit,
        'headline-too-long',
        `commit headline exceeds ${effectiveChecks.maxHeadlineLength} characters`
      );
    }
    if (
      effectiveChecks.requireSignatureMaterialForVerified &&
      commit.verified &&
      (!commit.verificationSignaturePresent || !commit.verificationPayloadPresent)
    ) {
      addViolation(violations, commit, 'missing-signature-material', 'verified commit missing signature or payload');
    }
    if (!commit.verified) {
      addViolation(violations, commit, 'unverified-commit', commit.verificationReason);
      if (effectiveChecks.requireKnownReasonForUnverified && commit.verificationReason === 'unknown') {
        addViolation(violations, commit, 'unknown-unverified-reason', 'unknown verification reason');
      }
    }
    if (effectiveChecks.requireAuthorAttribution && !hasAuthorAttribution(commit)) {
      addViolation(violations, commit, 'missing-author-attribution', 'author login/email missing');
    }
    if (effectiveChecks.requireCommitterAttribution && !hasCommitterAttribution(commit)) {
      addViolation(violations, commit, 'missing-committer-attribution', 'committer login/email missing');
    }
    if (effectiveChecks.requireRequiredTrailer && effectiveChecks.requiredTrailerRules.length > 0) {
      const trailerEvaluation = evaluateRequiredTrailer(commit, effectiveChecks.requiredTrailerRules);
      if (!trailerEvaluation.passed) {
        addViolation(violations, commit, trailerEvaluation.category, trailerEvaluation.reason);
      }
    }
  }

  if (list.length === 0) {
    issues.push('no-commits-found');
  }

  checkResults.push({
    name: 'unverified-commit',
    enabled: true,
    passed: !violations.some((violation) => violation.category === 'unverified-commit'),
    failureCount: violations.filter((violation) => violation.category === 'unverified-commit').length
  });
  checkResults.push({
    name: 'unknown-unverified-reason',
    enabled: effectiveChecks.requireKnownReasonForUnverified,
    passed:
      !effectiveChecks.requireKnownReasonForUnverified ||
      !violations.some((violation) => violation.category === 'unknown-unverified-reason'),
    failureCount: violations.filter((violation) => violation.category === 'unknown-unverified-reason').length
  });
  checkResults.push({
    name: 'author-attribution',
    enabled: effectiveChecks.requireAuthorAttribution,
    passed:
      !effectiveChecks.requireAuthorAttribution ||
      !violations.some((violation) => violation.category === 'missing-author-attribution'),
    failureCount: violations.filter((violation) => violation.category === 'missing-author-attribution').length
  });
  checkResults.push({
    name: 'committer-attribution',
    enabled: effectiveChecks.requireCommitterAttribution,
    passed:
      !effectiveChecks.requireCommitterAttribution ||
      !violations.some((violation) => violation.category === 'missing-committer-attribution'),
    failureCount: violations.filter((violation) => violation.category === 'missing-committer-attribution').length
  });
  checkResults.push({
    name: 'duplicate-commit-sha',
    enabled: effectiveChecks.requireUniqueShas,
    passed:
      !effectiveChecks.requireUniqueShas ||
      !violations.some((violation) => violation.category === 'duplicate-commit-sha'),
    failureCount: violations.filter((violation) => violation.category === 'duplicate-commit-sha').length
  });
  checkResults.push({
    name: 'empty-headline',
    enabled: effectiveChecks.requireNonEmptyHeadline,
    passed:
      !effectiveChecks.requireNonEmptyHeadline ||
      !violations.some((violation) => violation.category === 'empty-headline'),
    failureCount: violations.filter((violation) => violation.category === 'empty-headline').length
  });
  checkResults.push({
    name: 'headline-too-long',
    enabled: effectiveChecks.maxHeadlineLength > 0,
    passed:
      effectiveChecks.maxHeadlineLength <= 0 ||
      !violations.some((violation) => violation.category === 'headline-too-long'),
    failureCount: violations.filter((violation) => violation.category === 'headline-too-long').length
  });
  checkResults.push({
    name: 'missing-signature-material',
    enabled: effectiveChecks.requireSignatureMaterialForVerified,
    passed:
      !effectiveChecks.requireSignatureMaterialForVerified ||
      !violations.some((violation) => violation.category === 'missing-signature-material'),
    failureCount: violations.filter((violation) => violation.category === 'missing-signature-material').length
  });
  checkResults.push({
    name: 'required-trailer',
    enabled: effectiveChecks.requireRequiredTrailer,
    passed:
      !effectiveChecks.requireRequiredTrailer ||
      (
        !violations.some(
          (violation) =>
            violation.category === 'missing-required-trailer' ||
            violation.category === 'invalid-required-trailer-format'
        ) && !issues.includes('required-trailer-rules-empty')
      ),
    failureCount:
      violations.filter(
        (violation) =>
          violation.category === 'missing-required-trailer' ||
          violation.category === 'invalid-required-trailer-format'
      ).length + (issues.includes('required-trailer-rules-empty') ? 1 : 0)
  });

  const summary = {
    commitCount: list.length,
    verifiedCount: list.filter((commit) => commit.verified).length,
    unverifiedCount: list.filter((commit) => !commit.verified).length,
    violationCount: violations.length,
    deterministicOrder: 'sha-asc'
  };

  return {
    result: issues.length === 0 && violations.length === 0 ? 'pass' : 'fail',
    issues,
    checks: checkResults,
    violations,
    summary
  };
}

function createHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'User-Agent': 'commit-integrity-check',
    'X-GitHub-Api-Version': '2022-11-28'
  };
}

async function requestJson(url, token, { fetchFn = globalThis.fetch } = {}) {
  if (typeof fetchFn !== 'function') {
    throw new Error('Global fetch is unavailable.');
  }
  const response = await fetchFn(url, {
    method: 'GET',
    headers: createHeaders(token)
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`GitHub API request failed: ${response.status} ${response.statusText} -> ${text}`);
  }
  return response.json();
}

async function listPullRequestCommits(repo, pullRequest, token, { fetchFn = globalThis.fetch } = {}) {
  const commits = [];
  for (let page = 1; page <= 20; page += 1) {
    const url = `https://api.github.com/repos/${repo}/pulls/${pullRequest}/commits?per_page=100&page=${page}`;
    const payload = await requestJson(url, token, { fetchFn });
    const pageItems = Array.isArray(payload) ? payload : [];
    if (pageItems.length === 0) {
      break;
    }
    commits.push(...pageItems);
    if (pageItems.length < 100) {
      break;
    }
  }
  return commits;
}

async function listCompareCommits(repo, baseSha, headSha, token, { fetchFn = globalThis.fetch } = {}) {
  const url = `https://api.github.com/repos/${repo}/compare/${baseSha}...${headSha}`;
  const payload = await requestJson(url, token, { fetchFn });
  return Array.isArray(payload?.commits) ? payload.commits : [];
}

async function loadPolicy(policyPath) {
  const resolved = path.resolve(policyPath);
  const raw = await readFile(resolved, 'utf8');
  const parsed = JSON.parse(raw);

  const sourceResolution = parsed?.source_resolution ?? {};
  const checkSettings = parsed?.checks ?? {};
  const trailerContract = parsed?.trailer_contract ?? {};
  const requiredAnyTrailers = Array.isArray(trailerContract.required_any)
    ? trailerContract.required_any.map((entry) => ({
      key: entry?.key,
      valuePattern: entry?.value_pattern
    }))
    : [];
  const policy = {
    path: resolved,
    schema: normalizeOptionalString(parsed?.schema) ?? 'commit-integrity-policy/v1',
    failOnUnverified: parsed?.verification?.fail_on_unverified !== false,
    checks: normalizeChecks({
      requireAuthorAttribution: checkSettings.require_author_attribution,
      requireCommitterAttribution: checkSettings.require_committer_attribution,
      requireKnownReasonForUnverified: checkSettings.require_non_unknown_reason_for_unverified,
      requireUniqueShas: checkSettings.require_unique_shas,
      requireNonEmptyHeadline: checkSettings.require_non_empty_headline,
      maxHeadlineLength: checkSettings.max_headline_length,
      requireSignatureMaterialForVerified: checkSettings.require_signature_material_for_verified,
      requireRequiredTrailer: checkSettings.require_required_trailer,
      requiredTrailerRules: requiredAnyTrailers
    }),
    sourceResolution: {
      botLoginRegexes: compileRegexList(sourceResolution.bot_login_patterns, {
        label: 'source_resolution.bot_login_patterns'
      }),
      botEmailRegexes: compileRegexList(sourceResolution.bot_email_patterns, {
        label: 'source_resolution.bot_email_patterns'
      })
    }
  };
  return policy;
}

async function writeReport(reportPath, report) {
  const resolvedPath = path.resolve(reportPath);
  await mkdir(path.dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function buildReport({
  repository,
  scope,
  policy,
  observeOnly,
  commits,
  evaluation,
  errors = [],
  generatedAt = new Date().toISOString()
}) {
  const blocking = !observeOnly && policy.failOnUnverified;
  const shouldFailProcess = blocking && evaluation.result === 'fail';
  return {
    schema: 'commit-integrity/report@v1',
    schemaVersion: '1.0.0',
    generatedAt,
    repository,
    scope: {
      mode: scope.mode,
      pullRequest: scope.pullRequest ?? null,
      baseSha: scope.baseSha ?? null,
      headSha: scope.headSha ?? null
    },
    policy: {
      schema: policy.schema,
      path: policy.path,
      failOnUnverified: policy.failOnUnverified,
      checks: {
        requireAuthorAttribution: policy.checks.requireAuthorAttribution,
        requireCommitterAttribution: policy.checks.requireCommitterAttribution,
        requireKnownReasonForUnverified: policy.checks.requireKnownReasonForUnverified,
        requireUniqueShas: policy.checks.requireUniqueShas,
        requireNonEmptyHeadline: policy.checks.requireNonEmptyHeadline,
        maxHeadlineLength: policy.checks.maxHeadlineLength,
        requireSignatureMaterialForVerified: policy.checks.requireSignatureMaterialForVerified,
        requireRequiredTrailer: policy.checks.requireRequiredTrailer
      },
      sourceResolution: {
        botLoginPatternCount: policy.sourceResolution.botLoginRegexes.length,
        botEmailPatternCount: policy.sourceResolution.botEmailRegexes.length
      },
      trailerContract: {
        requiredAny: policy.checks.requiredTrailerRules.map((rule) => ({
          key: rule.key,
          valuePattern: rule.valuePattern
        }))
      }
    },
    enforcement: {
      observeOnly,
      blocking
    },
    checks: evaluation.checks,
    summary: evaluation.summary,
    commits,
    violations: evaluation.violations,
    issues: evaluation.issues,
    result: evaluation.result,
    errors: Array.isArray(errors) ? errors : [],
    exitCode: shouldFailProcess ? 1 : 0
  };
}

export async function runCommitIntegrity({
  argv = process.argv,
  env = process.env,
  fetchFn = globalThis.fetch,
  readFileFn = readFile,
  accessFn = access,
  execSyncFn = execSync,
  log = console.log,
  warn = console.warn
} = {}) {
  let options = {
    reportPath: DEFAULT_REPORT_PATH
  };
  let report = null;

  try {
    options = parseArgs(argv);
    const repository = resolveRepository(options, env, execSyncFn);
    const eventPayload = await loadEventPayload(env, { readFileFn });
    const scope = resolveScope(options, env, eventPayload);
    const token = await resolveToken(env, { readFileFn, accessFn });
    const policy = await loadPolicy(options.policyPath);

    const rawCommits =
      scope.mode === 'pull_request'
        ? await listPullRequestCommits(repository, scope.pullRequest, token, { fetchFn })
        : await listCompareCommits(repository, scope.baseSha, scope.headSha, token, { fetchFn });
    const commits = normalizeCommitRecords(rawCommits, policy.sourceResolution);
    const evaluation = evaluateCommitIntegrity(commits, {
      checks: policy.checks
    });

    report = buildReport({
      repository,
      scope,
      policy,
      observeOnly: options.observeOnly,
      commits,
      evaluation
    });

    const resolvedReportPath = await writeReport(options.reportPath, report);
    log(`[commit-integrity] report: ${resolvedReportPath}`);
    if (report.result === 'fail' && report.exitCode === 1) {
      throw new Error(
        `Commit integrity validation failed: ${report.violations.length} violation(s), ${report.issues.length} issue(s).`
      );
    }
    if (report.result === 'fail' && options.observeOnly) {
      warn(
        `[commit-integrity] observe-only mode: ${report.violations.length} violation(s), ${report.issues.length} issue(s).`
      );
    } else {
      log(
        `[commit-integrity] PASS commits=${report.summary.commitCount} verified=${report.summary.verifiedCount} unverified=${report.summary.unverifiedCount}`
      );
    }
    return report.exitCode;
  } catch (error) {
    if (!report) {
      report = {
        schema: 'commit-integrity/report@v1',
        schemaVersion: '1.0.0',
        generatedAt: new Date().toISOString(),
        repository: normalizeOptionalString(env.GITHUB_REPOSITORY),
        scope: {
          mode: 'unknown',
          pullRequest: null,
          baseSha: null,
          headSha: null
        },
      policy: {
        schema: 'commit-integrity-policy/v1',
        path: path.resolve(options.policyPath ?? DEFAULT_POLICY_PATH),
        failOnUnverified: true,
        checks: {
            requireAuthorAttribution: DEFAULT_POLICY_CHECKS.requireAuthorAttribution,
            requireCommitterAttribution: DEFAULT_POLICY_CHECKS.requireCommitterAttribution,
          requireKnownReasonForUnverified: DEFAULT_POLICY_CHECKS.requireKnownReasonForUnverified,
          requireUniqueShas: DEFAULT_POLICY_CHECKS.requireUniqueShas,
          requireNonEmptyHeadline: DEFAULT_POLICY_CHECKS.requireNonEmptyHeadline,
          maxHeadlineLength: DEFAULT_POLICY_CHECKS.maxHeadlineLength,
          requireSignatureMaterialForVerified: DEFAULT_POLICY_CHECKS.requireSignatureMaterialForVerified,
          requireRequiredTrailer: DEFAULT_POLICY_CHECKS.requireRequiredTrailer
        },
        sourceResolution: {
          botLoginPatternCount: 0,
          botEmailPatternCount: 0
        },
        trailerContract: {
          requiredAny: []
        }
      },
        enforcement: {
          observeOnly: Boolean(options.observeOnly),
          blocking: true
        },
        checks: [],
        summary: {
          commitCount: 0,
          verifiedCount: 0,
          unverifiedCount: 0,
          violationCount: 0,
          deterministicOrder: 'sha-asc'
        },
        commits: [],
        violations: [],
        issues: ['runtime-error'],
        result: 'fail',
        errors: [],
        exitCode: 1
      };
    }
    report.errors = [...(Array.isArray(report.errors) ? report.errors : []), error.message ?? String(error)];
    report.result = 'fail';
    report.exitCode = 1;
    await writeReport(options.reportPath ?? DEFAULT_REPORT_PATH, report);
    throw error;
  }
}

export const __test = Object.freeze({
  resolveScope,
  classifySourceKind,
  normalizeCommitRecord,
  normalizeCommitRecords,
  evaluateCommitIntegrity,
  buildReport
});

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  runCommitIntegrity()
    .then((exitCode) => {
      if (exitCode !== 0) {
        process.exitCode = exitCode;
      }
    })
    .catch((error) => {
      console.error(error.message || error);
      process.exitCode = 1;
    });
}

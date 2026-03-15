#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { downloadNamedArtifacts } from './lib/run-artifact-download.mjs';
import {
  loadBranchRequiredChecksPolicy,
  resolveProjectedRequiredStatusChecks,
} from './lib/branch-required-check-projection.mjs';

export const REPORT_SCHEMA = 'session-index-v2-promotion-decision@v1';
export const DEFAULT_SCHEMA_VERSION = '1.0.0';
export const DEFAULT_WORKFLOW = 'validate.yml';
export const DEFAULT_ARTIFACT_NAME = 'validate-session-index-v2-contract';
export const DEFAULT_BRANCH = 'develop';
export const DEFAULT_REQUIRED_CHECK = 'session-index-v2-contract';
export const DEFAULT_ENFORCE_VARIABLE = 'SESSION_INDEX_V2_CONTRACT_ENFORCE';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'branch-required-checks.json');
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'session-index-v2',
  'session-index-v2-promotion-decision.json',
);
export const DEFAULT_DOWNLOAD_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'session-index-v2',
  'session-index-v2-promotion-decision-download.json',
);
export const DEFAULT_DESTINATION_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'session-index-v2',
  'promotion-decision-artifacts',
);
export const CONTRACT_SCHEMA_PATH = path.join('docs', 'schemas', 'session-index-v2-contract-v1.schema.json');
export const DISPOSITION_SCHEMA_PATH = path.join(
  'docs',
  'schemas',
  'session-index-v2-disposition-summary-v1.schema.json',
);
export const CUTOVER_SCHEMA_PATH = path.join(
  'docs',
  'schemas',
  'session-index-v2-cutover-readiness-v1.schema.json',
);
const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const WORKFLOW_RUNS_PAGE_SIZE = 100;
const WORKFLOW_RUNS_MAX_PAGES = 10;

function printUsage() {
  console.log('Usage: node tools/priority/session-index-v2-promotion-decision.mjs [options]');
  console.log('');
  console.log('Resolve the current session-index-v2 promotion decision from live Validate artifacts and repo policy.');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>            Target repository (default: GITHUB_REPOSITORY or git remotes).');
  console.log(`  --workflow <id>                Workflow identifier (default: ${DEFAULT_WORKFLOW}).`);
  console.log(`  --artifact <name>              Artifact name (default: ${DEFAULT_ARTIFACT_NAME}).`);
  console.log('  --run-id <id>                  Explicit workflow run id to inspect.');
  console.log(`  --branch <name>                Branch filter for latest-run selection (default: ${DEFAULT_BRANCH}).`);
  console.log(`  --required-check <name>        Required-check context to evaluate (default: ${DEFAULT_REQUIRED_CHECK}).`);
  console.log(`  --enforce-variable <name>      Repository variable to inspect (default: ${DEFAULT_ENFORCE_VARIABLE}).`);
  console.log(`  --policy <path>                Branch-required-check policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --destination-root <path>      Artifact download root (default: ${DEFAULT_DESTINATION_ROOT}).`);
  console.log(`  --download-report <path>       Artifact download report path (default: ${DEFAULT_DOWNLOAD_REPORT_PATH}).`);
  console.log(`  --out <path>                   Output report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  -h, --help                     Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeLower(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function normalizeInteger(value) {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value;
  }
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = Number.parseInt(normalized, 10);
  return Number.isInteger(parsed) ? parsed : null;
}

function normalizeIso(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = new Date(normalized);
  if (Number.isNaN(parsed.valueOf())) {
    return null;
  }
  return parsed.toISOString();
}

function normalizeBooleanString(value) {
  const normalized = normalizeLower(value);
  if (!normalized) {
    return null;
  }
  if (normalized === 'true') {
    return true;
  }
  if (normalized === 'false') {
    return false;
  }
  return null;
}

function normalizeRepository(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const segments = normalized.split('/').map((segment) => segment.trim());
  if (segments.length !== 2 || segments.some((segment) => segment.length === 0)) {
    throw new Error(`Repository must use the form <owner>/<repo>; received '${value}'.`);
  }
  return `${segments[0]}/${segments[1]}`;
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  return normalizeRepository(repoPath);
}

function resolveRepositoryFromGitConfig(repoRoot) {
  const configPaths = resolveGitConfigPaths(repoRoot);
  for (const configPath of configPaths) {
    const config = fs.readFileSync(configPath, 'utf8');
    for (const remoteName of ['upstream', 'origin']) {
      const escaped = remoteName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const sectionMatch = config.match(
        new RegExp(`\\[remote\\s+"${escaped}"\\]([\\s\\S]*?)(?:\\n\\[|$)`, 'i'),
      );
      const section = sectionMatch?.[1];
      if (!section) {
        continue;
      }
      const urlMatch = section.match(/^\s*url\s*=\s*(.+)$/im);
      const repository = parseRemoteUrl(urlMatch?.[1]?.trim());
      if (repository) {
        return repository;
      }
    }
  }
  return null;
}

function resolveGitConfigPaths(repoRoot) {
  const dotGitPath = path.join(repoRoot, '.git');
  if (!fs.existsSync(dotGitPath)) {
    return [];
  }
  const stat = fs.statSync(dotGitPath);
  if (stat.isDirectory()) {
    const configPath = path.join(dotGitPath, 'config');
    return fs.existsSync(configPath) ? [configPath] : [];
  }
  const dotGitContent = fs.readFileSync(dotGitPath, 'utf8');
  const gitDirMatch = dotGitContent.match(/^gitdir:\s*(.+)$/im);
  if (!gitDirMatch) {
    return [];
  }
  const gitDir = path.resolve(repoRoot, gitDirMatch[1].trim());
  const configPaths = [];
  const commonDirFile = path.join(gitDir, 'commondir');
  if (fs.existsSync(commonDirFile)) {
    const commonDir = path.resolve(gitDir, fs.readFileSync(commonDirFile, 'utf8').trim());
    const commonConfigPath = path.join(commonDir, 'config');
    if (fs.existsSync(commonConfigPath)) {
      configPaths.push(commonConfigPath);
    }
  }
  const gitDirConfigPath = path.join(gitDir, 'config');
  if (fs.existsSync(gitDirConfigPath)) {
    configPaths.push(gitDirConfigPath);
  }
  return configPaths;
}

function resolveRepoPath(repoRoot, filePath) {
  if (path.isAbsolute(filePath)) {
    return filePath;
  }
  return path.resolve(repoRoot, filePath);
}

function writeJsonFile(filePath, payload, repoRoot = process.cwd()) {
  const resolved = resolveRepoPath(repoRoot, filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function runProcess(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? process.cwd(),
    encoding: 'utf8',
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES,
    env: options.env ?? process.env,
  });
  return {
    status: typeof result.status === 'number' ? result.status : null,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function runGhJson(args, options = {}) {
  const result = runProcess('gh', args, options);
  if (result.error || result.status !== 0) {
    const message =
      normalizeText(result.stderr) ??
      normalizeText(result.stdout) ??
      (result.error instanceof Error ? result.error.message : String(result.error));
    throw new Error(message ?? `gh ${args.join(' ')} failed.`);
  }
  return JSON.parse(result.stdout ?? 'null');
}

function getSchemaValidator(repoRoot) {
  const ajv = new Ajv2020({ allErrors: true, strict: false, $data: true });
  addFormats(ajv);
  const contractSchema = JSON.parse(fs.readFileSync(path.join(repoRoot, CONTRACT_SCHEMA_PATH), 'utf8'));
  const dispositionSchema = JSON.parse(fs.readFileSync(path.join(repoRoot, DISPOSITION_SCHEMA_PATH), 'utf8'));
  const cutoverSchema = JSON.parse(fs.readFileSync(path.join(repoRoot, CUTOVER_SCHEMA_PATH), 'utf8'));
  return {
    validateContract: ajv.compile(contractSchema),
    validateDisposition: ajv.compile(dispositionSchema),
    validateCutover: ajv.compile(cutoverSchema),
  };
}

function listRelativeFiles(rootPath) {
  if (!fs.existsSync(rootPath)) {
    return [];
  }
  const files = [];
  const walk = (currentPath) => {
    for (const entry of fs.readdirSync(currentPath, { withFileTypes: true })) {
      const fullPath = path.join(currentPath, entry.name);
      if (entry.isDirectory()) {
        walk(fullPath);
        continue;
      }
      if (entry.isFile()) {
        files.push(path.relative(rootPath, fullPath));
      }
    }
  };
  walk(rootPath);
  return files.sort((left, right) => left.localeCompare(right));
}

function findArtifactFile(rootPath, expectedName, candidateFiles = null) {
  const lowerName = expectedName.toLowerCase();
  const relativeFiles = Array.isArray(candidateFiles)
    ? candidateFiles.map((entry) => normalizeText(entry)).filter(Boolean)
    : listRelativeFiles(rootPath);
  for (const relativePath of relativeFiles) {
    if (path.basename(relativePath).toLowerCase() === lowerName) {
      const resolved = path.join(rootPath, relativePath);
      if (fs.existsSync(resolved)) {
        return resolved;
      }
    }
  }
  return null;
}

function contextAliases(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return [];
  }
  const aliases = new Set([normalized]);
  if (normalized.includes(' / ')) {
    const parts = normalized.split(' / ').map((segment) => segment.trim()).filter(Boolean);
    if (parts.length > 1) {
      aliases.add(parts[parts.length - 1]);
    }
  }
  return [...aliases];
}

function hasContextMatch(expectedContext, actualContexts) {
  const expectedAliases = contextAliases(expectedContext);
  const actualAliasSet = new Set(
    (Array.isArray(actualContexts) ? actualContexts : []).flatMap((entry) => contextAliases(entry)).map((entry) => entry.toLowerCase()),
  );
  return expectedAliases.some((alias) => actualAliasSet.has(alias.toLowerCase()));
}

function normalizeRunPayload(run) {
  return {
    id: normalizeInteger(run?.databaseId ?? run?.id),
    workflowName: normalizeText(run?.workflowName ?? run?.name),
    displayTitle: normalizeText(run?.displayTitle ?? run?.display_title),
    url: normalizeText(run?.url ?? run?.html_url),
    headBranch: normalizeText(run?.headBranch ?? run?.head_branch),
    headSha: normalizeText(run?.headSha ?? run?.head_sha),
    event: normalizeText(run?.event),
    status: normalizeLower(run?.status),
    conclusion: normalizeLower(run?.conclusion),
    createdAt: normalizeIso(run?.createdAt ?? run?.created_at),
    updatedAt: normalizeIso(run?.updatedAt ?? run?.updated_at),
  };
}

function matchesTargetBranch(headBranch, targetBranch) {
  const normalizedHeadBranch = normalizeText(headBranch);
  const normalizedTargetBranch = normalizeText(targetBranch);
  if (!normalizedTargetBranch) {
    return true;
  }
  if (!normalizedHeadBranch) {
    return false;
  }
  return normalizedHeadBranch === normalizedTargetBranch;
}

function selectLatestCompletedRun(runs, branch) {
  const normalizedBranch = normalizeText(branch);
  return [...(Array.isArray(runs) ? runs : [])]
    .map(normalizeRunPayload)
    .filter((run) => run.status === 'completed')
    .filter((run) => matchesTargetBranch(run.headBranch, normalizedBranch))
    .sort((left, right) => {
      const leftTimestamp = new Date(left.updatedAt ?? left.createdAt ?? 0).valueOf();
      const rightTimestamp = new Date(right.updatedAt ?? right.createdAt ?? 0).valueOf();
      if (rightTimestamp !== leftTimestamp) {
        return rightTimestamp - leftTimestamp;
      }
      return (right.id ?? 0) - (left.id ?? 0);
    })[0] ?? null;
}

function buildWorkflowRunsApiPath(repository, workflow, { page, branch = null, event = null, status = 'completed' } = {}) {
  const encodedWorkflow = encodeURIComponent(workflow);
  const query = new URLSearchParams();
  query.set('per_page', String(WORKFLOW_RUNS_PAGE_SIZE));
  query.set('page', String(page));
  if (status) {
    query.set('status', status);
  }
  if (branch) {
    query.set('branch', branch);
  }
  if (event) {
    query.set('event', event);
  }
  return `repos/${repository}/actions/workflows/${encodedWorkflow}/runs?${query.toString()}`;
}

async function defaultGetBranchHeadSha({
  repository,
  branch,
  runGhJsonFn = runGhJson,
}) {
  const branchSegment = encodeURIComponent(branch);
  const payload = runGhJsonFn(['api', `repos/${repository}/branches/${branchSegment}`]);
  const sha = normalizeText(payload?.commit?.sha);
  if (!sha) {
    throw new Error(`Branch head SHA could not be resolved for ${repository}@${branch}.`);
  }
  return sha;
}

function parseRepoSlug(repository) {
  const normalized = normalizeRepository(repository);
  const [owner, repo] = normalized.split('/');
  return { owner, repo };
}

function loadJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}
function validateEvidencePayloads(repoRoot, payloads) {
  const { validateContract, validateDisposition, validateCutover } = getSchemaValidator(repoRoot);
  const errors = [];
  if (!validateContract(payloads.contract)) {
    errors.push(`Contract schema validation failed: ${JSON.stringify(validateContract.errors, null, 2)}`);
  }
  if (!validateDisposition(payloads.disposition)) {
    errors.push(`Disposition schema validation failed: ${JSON.stringify(validateDisposition.errors, null, 2)}`);
  }
  if (!validateCutover(payloads.cutover)) {
    errors.push(`Cutover schema validation failed: ${JSON.stringify(validateCutover.errors, null, 2)}`);
  }
  errors.push(...validateEvidenceConsistency(payloads));
  return errors;
}

function validateEvidenceConsistency(payloads) {
  const errors = [];
  const contractPromotionReady = Boolean(payloads.contract?.burnIn?.promotionReady);
  const contractStatus = normalizeLower(payloads.contract?.status);
  const dispositionPromotionReady = Boolean(payloads.disposition?.promotionReady);
  const dispositionStatus = normalizeLower(payloads.disposition?.status);
  const dispositionValue = normalizeText(payloads.disposition?.disposition);
  const cutoverPromotionReady = Boolean(payloads.cutover?.promotionGate?.promotionReady);
  const cutoverContractStatus = normalizeLower(payloads.cutover?.promotionGate?.contractStatus);
  const cutoverDisposition = normalizeText(payloads.cutover?.promotionGate?.disposition);

  if (dispositionPromotionReady !== contractPromotionReady) {
    errors.push('Disposition promotionReady does not match contract burn-in promotionReady.');
  }
  if (contractStatus && dispositionStatus && contractStatus !== dispositionStatus) {
    errors.push('Disposition status does not match contract status.');
  }
  if (contractPromotionReady && dispositionValue !== 'promotion-ready') {
    errors.push('Disposition summary does not report promotion-ready while contract burn-in is promotion-ready.');
  }
  if (!contractPromotionReady && dispositionValue === 'promotion-ready') {
    errors.push('Disposition summary reports promotion-ready before contract burn-in is ready.');
  }
  if (cutoverPromotionReady !== contractPromotionReady) {
    errors.push('Cutover promotionGate.promotionReady does not match contract burn-in promotionReady.');
  }
  if (contractStatus && cutoverContractStatus && contractStatus !== cutoverContractStatus) {
    errors.push('Cutover promotionGate.contractStatus does not match contract status.');
  }
  if (dispositionValue && cutoverDisposition && dispositionValue !== cutoverDisposition) {
    errors.push('Cutover promotionGate.disposition does not match disposition summary.');
  }
  return errors;
}

function classifyEvidenceFailure(downloadReport) {
  const firstFailureClass =
    downloadReport?.downloads?.find((entry) => entry.failureClass)?.failureClass ??
    downloadReport?.discovery?.failureClass ??
    null;
  if (firstFailureClass === 'artifact-not-found' || firstFailureClass === 'artifact-expired') {
    return 'missing';
  }
  return 'invalid';
}

async function defaultGetBranchProtection({
  repository,
  branch,
  repoRoot,
  runGhJsonFn = runGhJson,
}) {
  const { owner, repo } = parseRepoSlug(repository);
  const branchSegment = encodeURIComponent(branch);
  const notes = [];
  const contexts = new Set();
  let branchProtectionUnavailable = false;
  let branchProtectionError = false;
  let rulesetError = false;

  try {
    const payload = runGhJsonFn(['api', `repos/${owner}/${repo}/branches/${branchSegment}/protection`]);
    const branchProtectionContexts = Array.isArray(payload?.required_status_checks?.checks)
      ? payload.required_status_checks.checks.map((entry) => normalizeText(entry?.context)).filter(Boolean)
      : Array.isArray(payload?.required_status_checks?.contexts)
        ? payload.required_status_checks.contexts.map((entry) => normalizeText(entry)).filter(Boolean)
        : [];
    for (const context of branchProtectionContexts) {
      contexts.add(context);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (String(message).includes('404')) {
      branchProtectionUnavailable = true;
      notes.push('Branch protection required status checks not configured for this branch.');
    } else {
      branchProtectionError = true;
      notes.push(message);
    }
  }

  try {
    const policyPath = path.join(repoRoot, 'tools', 'priority', 'policy.json');
    if (fs.existsSync(policyPath)) {
      const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
      const refName = `refs/heads/${branch}`;
      const expectedRulesets = Object.values(policy?.rulesets ?? {})
        .filter((entry) => Array.isArray(entry?.includes))
        .filter((entry) => entry.includes.some((pattern) => matchesRulesetRef(pattern, refName)));
      if (expectedRulesets.length > 0) {
        const liveRulesets = [];
        for (let page = 1; page <= WORKFLOW_RUNS_MAX_PAGES; page += 1) {
          const pagePayload = runGhJsonFn(['api', `repos/${owner}/${repo}/rulesets?per_page=100&page=${page}`]);
          const pageRulesets = Array.isArray(pagePayload) ? pagePayload : [];
          liveRulesets.push(...pageRulesets);
          if (pageRulesets.length < 100) {
            break;
          }
        }
        for (const expectedRuleset of expectedRulesets) {
          const liveSummary = (Array.isArray(liveRulesets) ? liveRulesets : []).find((candidate) =>
            normalizeText(candidate?.name) === normalizeText(expectedRuleset?.name),
          );
          if (!liveSummary?.id) {
            notes.push(`Live ruleset '${expectedRuleset?.name ?? 'unknown'}' was not found.`);
            continue;
          }
          const liveRuleset = runGhJsonFn(['api', `repos/${owner}/${repo}/rulesets/${liveSummary.id}`]);
          for (const context of extractRulesetStatusChecks(liveRuleset)) {
            contexts.add(context);
          }
        }
      }
    }
  } catch (error) {
    rulesetError = true;
    notes.push(error instanceof Error ? error.message : String(error));
  }

  if (branchProtectionError || rulesetError) {
    return {
      status: 'error',
      contexts: [...contexts],
      notes,
    };
  }
  if (contexts.size > 0) {
    return {
      status: 'available',
      contexts: [...contexts],
      notes,
    };
  }
  return {
    status: branchProtectionUnavailable ? 'unavailable' : 'available',
    contexts: [],
    notes,
  };
}

async function defaultGetRepositoryVariable({
  repository,
  variableName,
  runGhJsonFn = runGhJson,
}) {
  try {
    const payload = runGhJsonFn(['api', `repos/${repository}/actions/variables/${variableName}`]);
    const rawValue = normalizeText(payload?.value);
    return {
      status: 'set',
      name: variableName,
      value: rawValue,
      enabled: normalizeBooleanString(rawValue) === true,
      errorMessage: null,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (String(message).includes('404')) {
      return {
        status: 'unset',
        name: variableName,
        value: null,
        enabled: false,
        errorMessage: null,
      };
    }
    return {
      status: 'error',
      name: variableName,
      value: null,
      enabled: false,
      errorMessage: message,
    };
  }
}

function summarizeEvidence(evidence) {
  return {
    status: evidence.status,
    contract: {
      path: evidence.contract.path,
      status: evidence.contract.payload?.status ?? null,
      payload: evidence.contract.payload,
      promotionReady: Boolean(evidence.contract.payload?.burnIn?.promotionReady),
      consecutiveSuccess: normalizeInteger(evidence.contract.payload?.burnIn?.consecutiveSuccess),
      threshold: normalizeInteger(evidence.contract.payload?.burnIn?.threshold),
    },
    disposition: {
      path: evidence.disposition.path,
      status: evidence.disposition.payload?.status ?? null,
      payload: evidence.disposition.payload,
      disposition: evidence.disposition.payload?.disposition ?? null,
    },
    cutover: {
      path: evidence.cutover.path,
      status: evidence.cutover.payload?.status ?? null,
      payload: evidence.cutover.payload,
      cutoverReady: Boolean(evidence.cutover.payload?.cutoverReady),
      remainingChecklistCount: normalizeInteger(evidence.cutover.payload?.deprecationChecklist?.remainingCount),
    },
    errors: evidence.errors.slice(),
  };
}

function extractRulesetStatusChecks(ruleset) {
  const rules = Array.isArray(ruleset?.rules) ? ruleset.rules : [];
  const statusRule = rules.find((rule) => normalizeText(rule?.type) === 'required_status_checks');
  const entries = statusRule?.parameters?.required_status_checks;
  if (!Array.isArray(entries)) {
    return [];
  }
  return entries.map((entry) => normalizeText(entry?.context)).filter(Boolean);
}

function matchesRulesetRef(pattern, refName) {
  const normalizedPattern = normalizeText(pattern);
  const normalizedRef = normalizeText(refName);
  if (!normalizedPattern || !normalizedRef) {
    return false;
  }
  const escaped = normalizedPattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
  return new RegExp(`^${escaped}$`).test(normalizedRef);
}

function loadPriorityPolicyRequiredChecks(repoRoot, branch) {
  const policyPath = path.join(repoRoot, 'tools', 'priority', 'policy.json');
  if (!fs.existsSync(policyPath)) {
    return {
      status: 'missing',
      source: null,
      contexts: [],
    };
  }
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const exactBranchEntry = policy?.branches?.[branch];
  if (Array.isArray(exactBranchEntry?.required_status_checks)) {
    return {
      status: 'available',
      source: `branches.${branch}`,
      contexts: exactBranchEntry.required_status_checks.slice(),
    };
  }
  const refName = `refs/heads/${branch}`;
  const matchedContexts = new Set();
  let matchedSource = null;
  for (const [rulesetKey, ruleset] of Object.entries(policy?.rulesets ?? {})) {
    if (!Array.isArray(ruleset?.includes)) {
      continue;
    }
    if (!ruleset.includes.some((pattern) => matchesRulesetRef(pattern, refName))) {
      continue;
    }
    if (Array.isArray(ruleset?.required_status_checks)) {
      matchedSource ??= `rulesets.${rulesetKey}`;
      for (const context of ruleset.required_status_checks) {
        const normalized = normalizeText(context);
        if (normalized) {
          matchedContexts.add(normalized);
        }
      }
    }
  }
  if (matchedContexts.size > 0) {
    return {
      status: 'available',
      source: matchedSource,
      contexts: [...matchedContexts],
    };
  }
  return {
    status: 'missing',
    source: null,
    contexts: [],
  };
}

function normalizeContextList(contexts) {
  return [...new Set((Array.isArray(contexts) ? contexts : []).map((entry) => normalizeText(entry)).filter(Boolean))].sort((left, right) =>
    left.localeCompare(right),
  );
}

function evaluatePromotionDecision({ evidence, policy, requiredCheckName }) {
  const reasons = [];
  const variableQueryFailed = policy.variable.status === 'error';
  const variableEnabled = policy.variable.enabled === true;
  const policyHasCheck = policy.requiredCheckPolicy.hasCheck === true;
  const branchProtectionAvailable = policy.branchProtection.status === 'available';
  const branchProtectionHasCheck = policy.branchProtection.hasCheck === true;
  const branchProtectionQueryFailed = policy.branchProtection.status === 'error';
  const partialConfig = variableEnabled || policyHasCheck || branchProtectionHasCheck;

  if (evidence.status === 'missing') {
    if (variableQueryFailed) {
      reasons.push(`Repository variable query failed: ${policy.variable.errorMessage}`);
    }
    if (branchProtectionQueryFailed || policy.branchProtection.status === 'unavailable') {
      reasons.push(...policy.branchProtection.notes);
    }
    reasons.push(...evidence.errors.slice());
    if (variableQueryFailed || branchProtectionQueryFailed || partialConfig) {
      return {
        status: 'fail',
        state: 'promotion-config-drift',
        summary: 'Promotion configuration is enabled or unreadable while current evidence is missing.',
        reasons,
      };
    }
    return {
      status: 'warn',
      state: 'missing-evidence',
      summary: 'Live promotion evidence is incomplete, so promotion cannot be evaluated yet.',
      reasons,
    };
  }

  if (evidence.status === 'invalid') {
    return {
      status: 'fail',
      state: 'invalid-evidence',
      summary: 'Promotion evidence is contradictory or unreadable and must be corrected before cutover.',
      reasons: evidence.errors.slice(),
    };
  }

  const promotionReady = Boolean(evidence.contract.payload?.burnIn?.promotionReady);
  const dispositionPromotionReady = Boolean(evidence.disposition.payload?.promotionReady);
  const cutoverReady = Boolean(evidence.cutover.payload?.cutoverReady);
  const contractStatus = normalizeLower(evidence.contract.payload?.status);
  const dispositionStatus = normalizeLower(evidence.disposition.payload?.status);

  if (!promotionReady) {
    reasons.push(
      `Burn-in evidence is not promotion-ready (${evidence.contract.payload?.burnIn?.consecutiveSuccess ?? 0}/${evidence.contract.payload?.burnIn?.threshold ?? 0} consecutive successful runs).`,
    );
  }
  if (!cutoverReady) {
    reasons.push(...(Array.isArray(evidence.cutover.payload?.reasons) ? evidence.cutover.payload.reasons : []));
  }
  if (contractStatus !== 'pass') {
    reasons.push(`Contract status is '${contractStatus ?? 'unknown'}'.`);
  }
  if (dispositionStatus !== 'pass') {
    reasons.push(`Disposition status is '${dispositionStatus ?? 'unknown'}'.`);
  }
  if (dispositionPromotionReady !== promotionReady) {
    reasons.push('Disposition promotionReady does not match contract burn-in promotionReady.');
  }
  if (variableQueryFailed) {
    reasons.push(`Repository variable query failed: ${policy.variable.errorMessage}`);
  }
  if (branchProtectionQueryFailed) {
    reasons.push(...policy.branchProtection.notes);
  }
  if (policy.branchProtection.status === 'unavailable') {
    reasons.push(...policy.branchProtection.notes);
  }

  const evidenceReady = promotionReady && dispositionPromotionReady && cutoverReady && contractStatus === 'pass' && dispositionStatus === 'pass';
  if (variableQueryFailed || branchProtectionQueryFailed) {
    return {
      status: 'fail',
      state: 'promotion-config-drift',
      summary: 'Live promotion configuration could not be read deterministically.',
      reasons,
    };
  }

  if (partialConfig) {
    if (!evidenceReady) {
      return {
        status: 'fail',
        state: 'promotion-config-drift',
        summary: 'Promotion configuration is ahead of the live evidence.',
        reasons,
      };
    }
    if (!variableEnabled || !policyHasCheck || !branchProtectionAvailable || !branchProtectionHasCheck) {
      if (!variableEnabled) {
        reasons.push(`Repository variable ${policy.variable.name} is not enabled.`);
      }
      if (!policyHasCheck) {
        reasons.push(`Required-check policy does not include '${requiredCheckName}' for ${policy.requiredCheckPolicy.branch}.`);
      }
      if (!branchProtectionAvailable) {
        reasons.push('Live branch protection is not configured for this branch.');
      } else if (!branchProtectionHasCheck) {
        reasons.push(`Live branch protection does not include '${requiredCheckName}'.`);
      }
      return {
        status: 'fail',
        state: 'promotion-config-drift',
        summary: 'Promotion configuration is only partially applied.',
        reasons,
      };
    }
    return {
      status: 'pass',
      state: 'already-enforced',
      summary: 'The promotion gate is already enforced in repository configuration.',
      reasons,
    };
  }

  if (evidenceReady) {
    return {
      status: 'pass',
      state: 'ready-to-promote',
      summary: 'Burn-in and cutover evidence are ready, and the repo has not enforced the gate yet.',
      reasons,
    };
  }

  return {
    status: 'warn',
    state: 'hold-burn-in',
    summary: 'Burn-in should continue until the promotion gate and cutover evidence are ready.',
    reasons,
  };
}

export function parseArgs(argv = process.argv, environment = process.env, repoRoot = process.cwd()) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: normalizeRepository(environment.GITHUB_REPOSITORY) ?? resolveRepositoryFromGitConfig(repoRoot),
    workflow: DEFAULT_WORKFLOW,
    artifactName: DEFAULT_ARTIFACT_NAME,
    runId: null,
    branch: DEFAULT_BRANCH,
    requiredCheckName: DEFAULT_REQUIRED_CHECK,
    enforceVariableName: DEFAULT_ENFORCE_VARIABLE,
    policyPath: DEFAULT_POLICY_PATH,
    destinationRoot: DEFAULT_DESTINATION_ROOT,
    downloadReportPath: DEFAULT_DOWNLOAD_REPORT_PATH,
    reportPath: DEFAULT_REPORT_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--workflow' ||
      token === '--artifact' ||
      token === '--run-id' ||
      token === '--branch' ||
      token === '--required-check' ||
      token === '--enforce-variable' ||
      token === '--policy' ||
      token === '--destination-root' ||
      token === '--download-report' ||
      token === '--out'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeRepository(next);
      if (token === '--workflow') options.workflow = next;
      if (token === '--artifact') options.artifactName = normalizeText(next);
      if (token === '--run-id') options.runId = normalizeText(next);
      if (token === '--branch') options.branch = normalizeText(next);
      if (token === '--required-check') options.requiredCheckName = normalizeText(next);
      if (token === '--enforce-variable') options.enforceVariableName = normalizeText(next);
      if (token === '--policy') options.policyPath = next;
      if (token === '--destination-root') options.destinationRoot = next;
      if (token === '--download-report') options.downloadReportPath = next;
      if (token === '--out') options.reportPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.repo) {
      throw new Error('Repository is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
    }
    if (!options.artifactName) {
      throw new Error('--artifact must not be empty.');
    }
    if (!options.branch) {
      throw new Error('--branch must not be empty.');
    }
    if (!options.requiredCheckName) {
      throw new Error('--required-check must not be empty.');
    }
    if (!options.enforceVariableName) {
      throw new Error('--enforce-variable must not be empty.');
    }
  }

  return options;
}

async function resolveSelectedRun(options, runGhJsonFn, getBranchHeadShaFn = defaultGetBranchHeadSha) {
  if (options.runId) {
    try {
      const payload = runGhJsonFn(['api', `repos/${options.repo}/actions/runs/${options.runId}`]);
      const run = normalizeRunPayload(payload);
      const workflowPath = normalizeText(payload?.path);
      const expectedWorkflow = normalizeText(options.workflow);
      const expectedWorkflowStem = expectedWorkflow ? path.basename(expectedWorkflow, path.extname(expectedWorkflow)).toLowerCase() : null;
      const workflowName = normalizeLower(payload?.name ?? payload?.workflowName);
      const workflowMatches =
        !expectedWorkflow ||
        workflowPath?.includes(`/${expectedWorkflow}@`) ||
        workflowPath?.endsWith(`/${expectedWorkflow}`) ||
        workflowName === normalizeLower(expectedWorkflow) ||
        workflowName === expectedWorkflowStem;
      const branchMatches = matchesTargetBranch(run.headBranch, options.branch);
      const statusMatches = run.status === 'completed';
      const branchHeadSha = await getBranchHeadShaFn({
        repository: options.repo,
        branch: options.branch,
        runGhJsonFn,
      });
      const currentHeadMatches = normalizeText(run.headSha) === branchHeadSha;
      if (!workflowMatches || !branchMatches || !statusMatches || !currentHeadMatches) {
        const mismatchReasons = [];
        if (!workflowMatches) {
          mismatchReasons.push(`workflow '${payload?.path ?? payload?.name ?? 'unknown'}' does not match ${options.workflow}`);
        }
        if (!branchMatches) {
          mismatchReasons.push(`head branch '${run.headBranch ?? 'unknown'}' does not match ${options.branch}`);
        }
        if (!statusMatches) {
          mismatchReasons.push(`run status '${run.status ?? 'unknown'}' is not completed`);
        }
        if (!currentHeadMatches) {
          mismatchReasons.push(`head SHA '${run.headSha ?? 'unknown'}' does not match current branch head '${branchHeadSha}'`);
        }
        return {
          status: 'fail',
          selectionMode: 'explicit-run',
          failureClass: 'run-mismatch',
          errorMessage: `Explicit run ${options.runId} is not valid for this promotion decision: ${mismatchReasons.join('; ')}.`,
          run,
        };
      }
      return {
        status: 'pass',
        selectionMode: 'explicit-run',
        failureClass: null,
        errorMessage: null,
        run,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        status: 'fail',
        selectionMode: 'explicit-run',
        failureClass: String(message).includes('404') ? 'run-not-found' : 'run-resolution-failed',
        errorMessage: message,
        run: null,
      };
    }
  }

  try {
    const branchHeadSha = await getBranchHeadShaFn({
      repository: options.repo,
      branch: options.branch,
      runGhJsonFn,
    });
    const collectedRuns = [];
    const seenRunIds = new Set();
    const queryPlans = [{ branch: options.branch, event: null }];
    for (const queryPlan of queryPlans) {
      for (let page = 1; page <= WORKFLOW_RUNS_MAX_PAGES; page += 1) {
        const payload = runGhJsonFn([
          'api',
          buildWorkflowRunsApiPath(options.repo, options.workflow, {
            page,
            branch: queryPlan.branch,
            event: queryPlan.event,
          }),
        ]);
        const workflowRuns = Array.isArray(payload?.workflow_runs) ? payload.workflow_runs : [];
        for (const run of workflowRuns) {
          const runId = normalizeInteger(run?.databaseId ?? run?.id);
          if (runId !== null) {
            if (seenRunIds.has(runId)) {
              continue;
            }
            seenRunIds.add(runId);
          }
          collectedRuns.push(run);
        }
        if (workflowRuns.length < WORKFLOW_RUNS_PAGE_SIZE) {
          break;
        }
      }
    }
    const run = selectLatestCompletedRun(
      collectedRuns.filter((candidate) => normalizeText(candidate?.headSha ?? candidate?.head_sha) === branchHeadSha),
      options.branch,
    );
    if (!run) {
      return {
        status: 'fail',
        selectionMode: 'latest-completed-run',
        failureClass: 'run-not-found',
        errorMessage: `No completed ${options.workflow} runs found for branch '${options.branch}' at head '${branchHeadSha}' in ${options.repo} after scanning ${WORKFLOW_RUNS_PAGE_SIZE * WORKFLOW_RUNS_MAX_PAGES} runs.`,
        run: null,
      };
    }
    return {
      status: 'pass',
      selectionMode: 'latest-completed-run',
      failureClass: null,
      errorMessage: null,
      run,
    };
  } catch (error) {
    return {
      status: 'fail',
      selectionMode: 'latest-completed-run',
      failureClass: 'run-resolution-failed',
      errorMessage: error instanceof Error ? error.message : String(error),
      run: null,
    };
  }
}

function buildBaseReport(options, now, selectedRun, repoRoot) {
  return {
    schema: REPORT_SCHEMA,
    schemaVersion: DEFAULT_SCHEMA_VERSION,
    generatedAt: new Date(now).toISOString(),
    status: 'warn',
    repository: options.repo,
    workflow: {
      id: options.workflow,
      branch: options.branch,
    },
    selection: {
      mode: selectedRun.selectionMode,
      runId: options.runId,
      status: selectedRun.status,
      failureClass: selectedRun.failureClass,
      errorMessage: selectedRun.errorMessage,
    },
    sourceRun: selectedRun.run,
    artifact: {
      name: options.artifactName,
      destinationRoot: resolveRepoPath(repoRoot, options.destinationRoot),
      downloadReportPath: resolveRepoPath(repoRoot, options.downloadReportPath),
      bundleRoot: null,
      files: [],
    },
    evidence: {
      status: 'missing',
      contract: { path: null, status: null, payload: null },
      disposition: { path: null, status: null, payload: null },
      cutover: { path: null, status: null, payload: null },
      errors: [],
    },
    policy: {
      variable: {
        name: options.enforceVariableName,
        status: 'unset',
        value: null,
        enabled: false,
        errorMessage: null,
      },
      requiredCheckPolicy: {
        path: options.policyPath,
        branch: options.branch,
        checkName: options.requiredCheckName,
        contexts: [],
        hasCheck: false,
      },
      branchProtection: {
        status: 'unavailable',
        contexts: [],
        hasCheck: false,
        notes: [],
      },
    },
    decision: {
      state: 'missing-evidence',
      summary: 'Promotion evidence has not been resolved yet.',
      reasons: [],
    },
  };
}

export async function runSessionIndexV2PromotionDecision({
  argv = process.argv,
  env = process.env,
  now = new Date(),
  repoRoot = process.cwd(),
  runGhJsonFn = runGhJson,
  getBranchHeadShaFn = defaultGetBranchHeadSha,
  downloadArtifactsFn = downloadNamedArtifacts,
  getBranchProtectionFn = defaultGetBranchProtection,
  getRepositoryVariableFn = defaultGetRepositoryVariable,
  writeJsonFn = writeJsonFile,
} = {}) {
  const options = parseArgs(argv, env, repoRoot);
  if (options.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  const selectedRun = await resolveSelectedRun(options, runGhJsonFn, getBranchHeadShaFn);
  const report = buildBaseReport(options, now, selectedRun, repoRoot);
  const writeReportFn = (filePath, payload) => writeJsonFn(filePath, payload, repoRoot);
  try {
    const policy = await loadBranchRequiredChecksPolicy(path.resolve(repoRoot, options.policyPath));
    const projectedChecks = resolveProjectedRequiredStatusChecks(policy, options.branch);
    const canonicalPolicyPath = resolveRepoPath(repoRoot, DEFAULT_POLICY_PATH);
    const resolvedRequestedPolicyPath = resolveRepoPath(repoRoot, options.policyPath);
    if (resolvedRequestedPolicyPath === canonicalPolicyPath) {
      const priorityPolicyChecks = loadPriorityPolicyRequiredChecks(repoRoot, options.branch);
      const normalizedProjectedChecks = normalizeContextList(projectedChecks);
      const normalizedPriorityPolicyChecks = normalizeContextList(priorityPolicyChecks.contexts);
      if (
        priorityPolicyChecks.status === 'available' &&
        JSON.stringify(normalizedProjectedChecks) !== JSON.stringify(normalizedPriorityPolicyChecks)
      ) {
        report.decision = {
          status: 'fail',
          state: 'promotion-config-drift',
          summary: 'Checked-in required-check policy surfaces disagree for this branch.',
          reasons: [
            `tools/policy/branch-required-checks.json resolved [${normalizedProjectedChecks.join(', ')}] for ${options.branch}.`,
            `tools/priority/policy.json resolved [${normalizedPriorityPolicyChecks.join(', ')}] from ${priorityPolicyChecks.source}.`,
          ],
        };
        report.status = report.decision.status;
        const reportPath = await writeReportFn(options.reportPath, report);
        return { exitCode: 1, report, reportPath };
      }
    }
    report.policy.requiredCheckPolicy.contexts = projectedChecks.slice();
    report.policy.requiredCheckPolicy.hasCheck = hasContextMatch(options.requiredCheckName, projectedChecks);

    report.policy.variable = await getRepositoryVariableFn({
      repository: options.repo,
      variableName: options.enforceVariableName,
      runGhJsonFn,
    });

    report.policy.branchProtection = await getBranchProtectionFn({
      repository: options.repo,
      branch: options.branch,
      repoRoot,
      env,
      runGhJsonFn,
    });
    report.policy.branchProtection.hasCheck = hasContextMatch(
      options.requiredCheckName,
      report.policy.branchProtection.contexts,
    );

    if (selectedRun.status !== 'pass' || !selectedRun.run?.id) {
      report.evidence.status = selectedRun.failureClass === 'run-not-found' ? 'missing' : 'invalid';
      report.evidence.errors.push(selectedRun.errorMessage ?? 'Failed to resolve a workflow run.');
      report.decision = evaluatePromotionDecision({
        evidence: report.evidence,
        policy: report.policy,
        requiredCheckName: options.requiredCheckName,
      });
      report.status = report.decision.status;
      const reportPath = await writeReportFn(options.reportPath, report);
      return { exitCode: report.status === 'fail' ? 1 : 0, report, reportPath };
    }

    const downloadDestinationRoot = path.join(options.destinationRoot, String(selectedRun.run.id));
    const resolvedDownloadDestinationRoot = resolveRepoPath(repoRoot, downloadDestinationRoot);
    fs.rmSync(resolvedDownloadDestinationRoot, { recursive: true, force: true });
    report.artifact.destinationRoot = resolvedDownloadDestinationRoot;

    const downloadResult = await downloadArtifactsFn({
      repository: options.repo,
      runId: String(selectedRun.run.id),
      artifactNames: [options.artifactName],
      destinationRoot: resolvedDownloadDestinationRoot,
      reportPath: resolveRepoPath(repoRoot, options.downloadReportPath),
      now,
    });
    report.artifact.downloadReportPath = resolveRepoPath(repoRoot, downloadResult.reportPath ?? options.downloadReportPath);

    const downloadEntry = Array.isArray(downloadResult.report?.downloads)
      ? downloadResult.report.downloads.find((entry) => entry.name === options.artifactName) ?? null
      : null;
    const downloadedFiles = Array.isArray(downloadEntry?.files)
      ? downloadEntry.files.map((entry) => normalizeText(entry)).filter(Boolean)
      : [];
    if (downloadEntry?.destination) {
      report.artifact.bundleRoot = resolveRepoPath(repoRoot, downloadEntry.destination);
      report.artifact.files = downloadedFiles.slice();
    }

    if (downloadResult.report?.status !== 'pass' || !report.artifact.bundleRoot) {
      report.evidence.status = classifyEvidenceFailure(downloadResult.report);
      report.evidence.errors.push(...(downloadResult.report?.errors ?? []));
      report.decision = evaluatePromotionDecision({
        evidence: report.evidence,
        policy: report.policy,
        requiredCheckName: options.requiredCheckName,
      });
      report.status = report.decision.status;
      const reportPath = await writeReportFn(options.reportPath, report);
      return { exitCode: report.status === 'fail' ? 1 : 0, report, reportPath };
    }

    const contractPath = findArtifactFile(report.artifact.bundleRoot, 'session-index-v2-contract.json', downloadedFiles);
    const dispositionPath = findArtifactFile(report.artifact.bundleRoot, 'session-index-v2-disposition.json', downloadedFiles);
    const cutoverPath = findArtifactFile(report.artifact.bundleRoot, 'session-index-v2-cutover-readiness.json', downloadedFiles);
    report.evidence.contract.path = contractPath;
    report.evidence.disposition.path = dispositionPath;
    report.evidence.cutover.path = cutoverPath;

    if (downloadedFiles.length === 0) {
      report.evidence.status = 'invalid';
      report.evidence.errors.push('Artifact download report did not enumerate the files downloaded for the selected run.');
    }

    if (!contractPath || !dispositionPath || !cutoverPath) {
      if (report.evidence.status !== 'invalid') {
        report.evidence.status = 'missing';
      }
      if (!contractPath) report.evidence.errors.push('Contract report is missing from the artifact bundle.');
      if (!dispositionPath) report.evidence.errors.push('Disposition report is missing from the artifact bundle.');
      if (!cutoverPath) report.evidence.errors.push('Cutover readiness report is missing from the artifact bundle.');
    } else {
      try {
        report.evidence.contract.payload = loadJsonFile(contractPath);
        report.evidence.disposition.payload = loadJsonFile(dispositionPath);
        report.evidence.cutover.payload = loadJsonFile(cutoverPath);
        const validationErrors = validateEvidencePayloads(repoRoot, {
          contract: report.evidence.contract.payload,
          disposition: report.evidence.disposition.payload,
          cutover: report.evidence.cutover.payload,
        });
        if (validationErrors.length > 0) {
          report.evidence.status = 'invalid';
          report.evidence.errors.push(...validationErrors);
        } else {
          report.evidence.status = 'complete';
        }
      } catch (error) {
        report.evidence.status = 'invalid';
        report.evidence.errors.push(error instanceof Error ? error.message : String(error));
      }
    }

    report.evidence = summarizeEvidence(report.evidence);

    report.decision = evaluatePromotionDecision({
      evidence: report.evidence,
      policy: report.policy,
      requiredCheckName: options.requiredCheckName,
    });
    report.status = report.decision.status;
  } catch (error) {
    report.decision = {
      status: 'fail',
      state: 'promotion-config-drift',
      summary: 'Promotion configuration or evidence could not be resolved deterministically.',
      reasons: [error instanceof Error ? error.message : String(error)],
    };
    report.status = report.decision.status;
  }

  const reportPath = await writeReportFn(options.reportPath, report);
  return {
    exitCode: report.status === 'fail' ? 1 : 0,
    report,
    reportPath,
  };
}

export async function main(argv = process.argv, dependencies = {}) {
  const logFn = dependencies.logFn ?? console.log;
  const errorFn = dependencies.errorFn ?? console.error;
  try {
    const result = await runSessionIndexV2PromotionDecision({
      argv,
      env: dependencies.env ?? process.env,
      now: dependencies.now ?? new Date(),
      repoRoot: dependencies.repoRoot ?? process.cwd(),
      runGhJsonFn: dependencies.runGhJsonFn ?? runGhJson,
      getBranchHeadShaFn: dependencies.getBranchHeadShaFn ?? defaultGetBranchHeadSha,
      downloadArtifactsFn: dependencies.downloadArtifactsFn ?? downloadNamedArtifacts,
      getBranchProtectionFn: dependencies.getBranchProtectionFn ?? defaultGetBranchProtection,
      getRepositoryVariableFn: dependencies.getRepositoryVariableFn ?? defaultGetRepositoryVariable,
      writeJsonFn: dependencies.writeJsonFn ?? writeJsonFile,
    });
    if (result.report) {
      logFn(`[session-index-v2-promotion-decision] report: ${result.reportPath}`);
      logFn(
        `[session-index-v2-promotion-decision] state=${result.report.decision.state} status=${result.report.status} run=${result.report.sourceRun?.id ?? 'none'}`,
      );
    }
    return result.exitCode;
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

const moduleSelfPath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === moduleSelfPath) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

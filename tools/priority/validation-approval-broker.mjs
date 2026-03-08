#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const VALIDATION_APPROVAL_DECISION_SCHEMA = 'validation-approval-decision@v1';
export const VALIDATION_APPROVAL_POLICY_SCHEMA = 'validation-approval-policy/v1';
export const RUNTIME_EVENT_SCHEMA = 'comparevi/runtime-event/v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'validation-approval-policy.json');
export const DEFAULT_REQUIRED_CHECKS_POLICY_PATH = path.join(
  'tools',
  'policy',
  'branch-required-checks.json',
);
export const DEFAULT_SIGNAL_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'reviews',
  'copilot-review-signal.json',
);
export const DEFAULT_ATTESTATION_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'reviews',
  'validation-agent-attestation.json',
);
export const DEFAULT_DEPLOYMENT_DETERMINISM_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'deployments',
  'validation-deployment-determinism.json',
);
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'approvals',
  'validation-approval-decision.json',
);
export const DEFAULT_EVENTS_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'approvals',
  'validation-approval-events.ndjson',
);

const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const BUILTIN_FAIL_CLOSED_POLICY_PATH = 'builtin:validation-approval-policy';
const BUILTIN_FAIL_CLOSED_POLICY = Object.freeze({
  schema: VALIDATION_APPROVAL_POLICY_SCHEMA,
  schemaVersion: '1.0.0',
  environment: 'validation',
  shadowMode: true,
  allowedBaseRefs: ['develop'],
  trust: {
    requireRepositoryMatch: true,
    allowCrossRepository: false,
    allowedHeadOwners: [],
  },
  providers: {
    requireReviewSignal: true,
    requireAgentAttestation: true,
    requireDeploymentDeterminism: true,
    requireRequiredChecks: true,
  },
  attestation: {
    requireValidationEvidencePass: true,
    requireDispositionsForActionableComments: true,
    requireDispositionsForUnresolvedThreads: true,
  },
});

function printUsage() {
  const lines = [
    'Usage: node tools/priority/validation-approval-broker.mjs [options]',
    '',
    'Shadow-mode broker for validation approval readiness. This command never performs approval side effects.',
    '',
    'Options:',
    `  --policy <path>                 Approval policy JSON path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --required-checks-policy <path> Branch required-checks policy JSON path (default: ${DEFAULT_REQUIRED_CHECKS_POLICY_PATH}).`,
    `  --signal <path>                 Copilot review signal JSON path (default: ${DEFAULT_SIGNAL_PATH}).`,
    `  --attestation <path>            Validation agent attestation JSON path (default: ${DEFAULT_ATTESTATION_PATH}).`,
    `  --deployment-determinism <path> Deployment determinism JSON path (default: ${DEFAULT_DEPLOYMENT_DETERMINISM_PATH}).`,
    '  --repo <owner/repo>             Target repository. Defaults to GITHUB_REPOSITORY.',
    '  --pr <number>                   Pull request number. Required unless --pull-file is supplied.',
    '  --pull-file <path>              Offline pull context JSON path.',
    '  --environment <name>            Target environment name (default: validation).',
    `  --out <path>                    Decision JSON output path (default: ${DEFAULT_REPORT_PATH}).`,
    `  --events-out <path>             NDJSON event stream output path (default: ${DEFAULT_EVENTS_PATH}).`,
    '  --step-summary <path>           Optional GitHub step summary path.',
    '  -h, --help                      Show help.',
  ];

  for (const line of lines) {
    console.log(line);
  }
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeSha(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
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

function normalizeBoolean(value) {
  if (typeof value === 'boolean') {
    return value;
  }
  const normalized = normalizeText(value)?.toLowerCase();
  if (normalized === 'true') return true;
  if (normalized === 'false') return false;
  return null;
}

function normalizeOwner(value) {
  if (typeof value === 'string') {
    return value.trim().toLowerCase();
  }
  if (value && typeof value === 'object' && typeof value.login === 'string') {
    return value.login.trim().toLowerCase();
  }
  return '';
}

function normalizeBaseRef(value) {
  const normalized = normalizeText(value)?.toLowerCase() ?? '';
  return normalized.startsWith('refs/heads/')
    ? normalized.slice('refs/heads/'.length)
    : normalized;
}

function normalizeRepositorySlug(value) {
  if (typeof value === 'string') {
    const normalized = normalizeText(value)?.toLowerCase() ?? null;
    if (!normalized) {
      return null;
    }
    parseRepoSlug(normalized);
    return normalized;
  }
  if (value && typeof value === 'object') {
    if (typeof value.nameWithOwner === 'string') {
      return normalizeRepositorySlug(value.nameWithOwner);
    }
    if (typeof value.owner?.login === 'string' && typeof value.name === 'string') {
      return normalizeRepositorySlug(`${value.owner.login}/${value.name}`);
    }
  }
  return null;
}

function uniqueStrings(values) {
  return [...new Set(values.filter(Boolean))];
}

function parseRepoSlug(repo) {
  const normalized = normalizeText(repo);
  if (!normalized) {
    throw new Error(`Invalid repository slug '${repo}'. Expected <owner>/<repo>.`);
  }
  const segments = normalized.split('/').map((segment) => segment.trim());
  if (segments.length !== 2 || segments.some((segment) => segment.length === 0)) {
    throw new Error(`Invalid repository slug '${repo}'. Expected <owner>/<repo>.`);
  }
  return { owner: segments[0], repo: segments[1] };
}

function readJsonFile(filePath) {
  const resolved = path.resolve(process.cwd(), filePath);
  if (!existsSync(resolved)) {
    throw new Error(`JSON file not found: ${resolved}`);
  }
  return JSON.parse(readFileSync(resolved, 'utf8'));
}

async function writeJsonFile(filePath, payload) {
  const resolved = path.resolve(process.cwd(), filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

async function writeNdjsonFile(filePath, records) {
  const resolved = path.resolve(process.cwd(), filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  const lines = (Array.isArray(records) ? records : []).map((record) => JSON.stringify(record));
  await writeFile(resolved, `${lines.join('\n')}${lines.length > 0 ? '\n' : ''}`, 'utf8');
  return resolved;
}

function runGhJson(args) {
  const result = spawnSync('gh', args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES,
  });

  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run gh ${args.join(' ')}: ${message}`);
  }

  const status = result.status ?? 0;
  if (status !== 0) {
    const stderr = normalizeText(result.stderr);
    const stdout = normalizeText(result.stdout);
    const parts = [`gh ${args.join(' ')} failed with exit code ${status}.`];
    if (stderr) parts.push(stderr);
    if (stdout) parts.push(stdout);
    throw new Error(parts.join(' '));
  }

  try {
    return JSON.parse(result.stdout ?? '');
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to parse JSON from gh ${args.join(' ')}: ${message}`);
  }
}

function resolveRepository(options, environment = process.env) {
  const explicit = normalizeText(options.repo);
  if (explicit) {
    parseRepoSlug(explicit);
    return explicit;
  }

  const fromEnv = normalizeText(environment.GITHUB_REPOSITORY);
  if (fromEnv) {
    parseRepoSlug(fromEnv);
    return fromEnv;
  }

  throw new Error('Repository is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
}

function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    policyPath: DEFAULT_POLICY_PATH,
    requiredChecksPolicyPath: DEFAULT_REQUIRED_CHECKS_POLICY_PATH,
    signalPath: DEFAULT_SIGNAL_PATH,
    attestationPath: DEFAULT_ATTESTATION_PATH,
    deploymentDeterminismPath: DEFAULT_DEPLOYMENT_DETERMINISM_PATH,
    repo: null,
    prNumber: null,
    pullFile: null,
    environment: 'validation',
    outPath: DEFAULT_REPORT_PATH,
    eventsOutPath: DEFAULT_EVENTS_PATH,
    stepSummaryPath: null,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--policy' ||
      token === '--required-checks-policy' ||
      token === '--signal' ||
      token === '--attestation' ||
      token === '--deployment-determinism' ||
      token === '--repo' ||
      token === '--pr' ||
      token === '--pull-file' ||
      token === '--environment' ||
      token === '--out' ||
      token === '--events-out' ||
      token === '--step-summary'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--policy') options.policyPath = next;
      if (token === '--required-checks-policy') options.requiredChecksPolicyPath = next;
      if (token === '--signal') options.signalPath = next;
      if (token === '--attestation') options.attestationPath = next;
      if (token === '--deployment-determinism') options.deploymentDeterminismPath = next;
      if (token === '--repo') options.repo = normalizeText(next);
      if (token === '--pr') options.prNumber = normalizeInteger(next);
      if (token === '--pull-file') options.pullFile = next;
      if (token === '--environment') options.environment = normalizeText(next) ?? 'validation';
      if (token === '--out') options.outPath = next;
      if (token === '--events-out') options.eventsOutPath = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !options.pullFile && options.prNumber === null) {
    throw new Error('Pull request number is required. Pass --pr <number> or --pull-file <path>.');
  }

  return options;
}

function createRuntimeEvent(now, phase, level, message, data = {}) {
  return {
    schema: RUNTIME_EVENT_SCHEMA,
    tsUtc: now.toISOString(),
    source: 'validation-approval-broker',
    phase,
    level,
    message,
    data,
  };
}

function normalizePolicy(policy, policyPath) {
  if (policy?.schema !== VALIDATION_APPROVAL_POLICY_SCHEMA) {
    throw new Error(
      `Unexpected validation approval policy schema '${String(policy?.schema ?? 'unknown')}'.`,
    );
  }

  const allowedBaseRefs = uniqueStrings(
    (Array.isArray(policy.allowedBaseRefs) ? policy.allowedBaseRefs : [])
      .map((entry) => normalizeBaseRef(entry))
      .filter(Boolean),
  );

  if (allowedBaseRefs.length === 0) {
    throw new Error('Validation approval policy must declare at least one allowedBaseRefs entry.');
  }

  return {
    schema: VALIDATION_APPROVAL_POLICY_SCHEMA,
    schemaVersion: normalizeText(policy.schemaVersion) ?? '1.0.0',
    path: policyPath,
    environment: normalizeText(policy.environment) ?? 'validation',
    shadowMode: policy.shadowMode !== false,
    allowedBaseRefs,
    trust: {
      requireRepositoryMatch: policy?.trust?.requireRepositoryMatch !== false,
      allowCrossRepository: policy?.trust?.allowCrossRepository === true,
      allowedHeadOwners: uniqueStrings(
        (Array.isArray(policy?.trust?.allowedHeadOwners) ? policy.trust.allowedHeadOwners : [])
          .map((entry) => normalizeOwner(entry))
          .filter(Boolean),
      ),
    },
    providers: {
      requireReviewSignal: policy?.providers?.requireReviewSignal !== false,
      requireAgentAttestation: policy?.providers?.requireAgentAttestation !== false,
      requireDeploymentDeterminism: policy?.providers?.requireDeploymentDeterminism !== false,
      requireRequiredChecks: policy?.providers?.requireRequiredChecks !== false,
    },
    attestation: {
      requireValidationEvidencePass:
        policy?.attestation?.requireValidationEvidencePass !== false,
      requireDispositionsForActionableComments:
        policy?.attestation?.requireDispositionsForActionableComments !== false,
      requireDispositionsForUnresolvedThreads:
        policy?.attestation?.requireDispositionsForUnresolvedThreads !== false,
    },
  };
}

function getBuiltinFailClosedPolicy(policyPath = BUILTIN_FAIL_CLOSED_POLICY_PATH) {
  return normalizePolicy(BUILTIN_FAIL_CLOSED_POLICY, policyPath);
}

function normalizePullContext(raw, repository) {
  return {
    repository,
    number: normalizeInteger(raw?.number),
    url: normalizeText(raw?.url),
    isDraft: normalizeBoolean(raw?.isDraft ?? raw?.draft) ?? false,
    headSha: normalizeSha(raw?.headRefOid ?? raw?.headSha ?? raw?.head?.sha),
    headRefName: normalizeText(raw?.headRefName ?? raw?.head?.ref),
    baseRefName: normalizeBaseRef(raw?.baseRefName ?? raw?.base?.ref),
    headRepositoryOwner:
      normalizeOwner(raw?.headRepositoryOwner) ||
      normalizeOwner(raw?.head?.repo?.owner) ||
      normalizeOwner(raw?.headRepoOwner),
    headRepository:
      normalizeRepositorySlug(raw?.headRepository) ||
      normalizeRepositorySlug(raw?.head?.repo) ||
      normalizeRepositorySlug(raw?.headRepositoryNameWithOwner),
    isCrossRepository: normalizeBoolean(raw?.isCrossRepository) ?? false,
    mergeStateStatus: normalizeText(raw?.mergeStateStatus),
    statusCheckRollup: Array.isArray(raw?.statusCheckRollup) ? raw.statusCheckRollup : [],
  };
}

function loadPullContext(options, repository, readJsonFn = readJsonFile) {
  if (options.pullFile) {
    return normalizePullContext(readJsonFn(options.pullFile), repository);
  }

  const payload = runGhJson([
    'pr',
    'view',
    String(options.prNumber),
    '--repo',
    repository,
    '--json',
    'number,url,isDraft,headRefOid,headRefName,baseRefName,headRepositoryOwner,isCrossRepository,mergeStateStatus,statusCheckRollup',
  ]);
  return normalizePullContext(payload, repository);
}

function summarizeReviewSignal(signal, signalPath) {
  if (signal?.schema !== 'priority/copilot-review-signal@v1') {
    throw new Error(`Unexpected review signal schema '${String(signal?.schema ?? 'unknown')}'.`);
  }

  return {
    path: signalPath,
    available: true,
    status: normalizeText(signal.status) ?? 'unknown',
    reviewState: normalizeText(signal.reviewState) ?? 'unknown',
    headSha: normalizeSha(signal.pullRequest?.headSha),
    pullRequestNumber: normalizeInteger(signal.pullRequest?.number),
    hasCurrentHeadReview: signal?.signals?.hasCurrentHeadReview === true,
    actionableCommentCount: normalizeInteger(signal.summary?.actionableCommentCount) ?? 0,
    unresolvedThreadCount: normalizeInteger(signal.summary?.unresolvedThreadCount) ?? 0,
    staleReviewCount: normalizeInteger(signal.summary?.staleReviewCount) ?? 0,
    errorCount: Array.isArray(signal.errors) ? signal.errors.length : 0,
  };
}

function summarizeAttestation(attestation, attestationPath) {
  if (attestation?.schema !== 'validation-agent-attestation@v1') {
    throw new Error(
      `Unexpected validation attestation schema '${String(attestation?.schema ?? 'unknown')}'.`,
    );
  }

  const threadDispositions = Array.isArray(attestation.dispositions?.threads)
    ? attestation.dispositions.threads
    : [];
  const commentDispositions = Array.isArray(attestation.dispositions?.comments)
    ? attestation.dispositions.comments
    : [];
  const commandFailures = Array.isArray(attestation.validationEvidence?.commands)
    ? attestation.validationEvidence.commands.filter(
        (entry) => normalizeText(entry?.status)?.toLowerCase() === 'failed',
      )
    : [];
  const checkFailures = Array.isArray(attestation.validationEvidence?.checks)
    ? attestation.validationEvidence.checks.filter(
        (entry) => normalizeText(entry?.status)?.toLowerCase() === 'failed',
      )
    : [];

  return {
    path: attestationPath,
    available: true,
    repository: normalizeText(attestation.repository),
    pullRequestNumber: normalizeInteger(attestation.pullRequest?.number),
    headSha: normalizeSha(attestation.pullRequest?.headSha),
    reviewSignalActionableCommentCount:
      normalizeInteger(attestation.reviewSignal?.actionableCommentCount) ?? 0,
    reviewSignalUnresolvedThreadCount:
      normalizeInteger(attestation.reviewSignal?.unresolvedThreadCount) ?? 0,
    threadDispositionCount: threadDispositions.length,
    commentDispositionCount: commentDispositions.length,
    failedEvidenceCount: commandFailures.length + checkFailures.length,
    commandFailureCount: commandFailures.length,
    checkFailureCount: checkFailures.length,
  };
}

function summarizeDeploymentDeterminism(report, reportPath) {
  if (report?.schema !== 'priority/deployment-determinism@v1') {
    throw new Error(
      `Unexpected deployment determinism schema '${String(report?.schema ?? 'unknown')}'.`,
    );
  }

  return {
    path: reportPath,
    available: true,
    environment: normalizeText(report.environment),
    result: normalizeText(report.result) ?? 'unknown',
    issueCount: Array.isArray(report.issues) ? report.issues.length : 0,
    issues: Array.isArray(report.issues) ? report.issues.map((entry) => String(entry)) : [],
    runId: normalizeText(report.runId),
  };
}

function matchBranchPattern(pattern, baseRef) {
  const normalizedPattern = normalizeBaseRef(pattern);
  const normalizedBaseRef = normalizeBaseRef(baseRef);
  if (!normalizedPattern || !normalizedBaseRef) {
    return false;
  }
  if (!normalizedPattern.includes('*')) {
    return normalizedPattern === normalizedBaseRef;
  }
  if (normalizedPattern.endsWith('/*')) {
    const prefix = normalizedPattern.slice(0, -1);
    return normalizedBaseRef.startsWith(prefix);
  }
  return false;
}

function resolveRequiredChecks(branchPolicy, baseRef) {
  const branches = branchPolicy?.branches ?? {};
  const normalizedBaseRef = normalizeBaseRef(baseRef);
  if (!normalizedBaseRef) {
    return [];
  }

  for (const [pattern, values] of Object.entries(branches)) {
    if (matchBranchPattern(pattern, normalizedBaseRef)) {
      return uniqueStrings(
        (Array.isArray(values) ? values : [])
          .map((entry) => normalizeText(entry))
          .filter(Boolean),
      );
    }
  }

  return [];
}

function checkRollupToMap(rollup = []) {
  const states = new Map();
  for (const entry of rollup) {
    if (!entry || typeof entry !== 'object') {
      continue;
    }

    const typeName = normalizeText(entry.__typename);
    if (typeName === 'StatusContext' || entry.context) {
      const context = normalizeText(entry.context);
      if (!context) {
        continue;
      }
      const state = normalizeText(entry.state)?.toUpperCase() ?? '';
      const previous = states.get(context) ?? { success: false, failure: false };
      previous.success = previous.success || state === 'SUCCESS';
      previous.failure = previous.failure || (state !== '' && state !== 'SUCCESS');
      states.set(context, previous);
      continue;
    }

    const context = normalizeText(entry.name);
    if (!context) {
      continue;
    }
    const status = normalizeText(entry.status)?.toUpperCase() ?? '';
    const conclusion = normalizeText(entry.conclusion)?.toUpperCase() ?? '';
    const isSuccess = status === 'COMPLETED' && conclusion === 'SUCCESS';
    const isFailure =
      status !== 'COMPLETED' ||
      (conclusion !== '' &&
        conclusion !== 'SUCCESS' &&
        conclusion !== 'NEUTRAL' &&
        conclusion !== 'SKIPPED');
    const previous = states.get(context) ?? { success: false, failure: false };
    previous.success = previous.success || isSuccess;
    previous.failure = previous.failure || isFailure;
    states.set(context, previous);
  }
  return states;
}

function evaluateRequiredChecks(requiredChecks, statusCheckRollup) {
  const required = Array.isArray(requiredChecks) ? requiredChecks : [];
  const states = checkRollupToMap(statusCheckRollup);
  const missing = [];
  const failing = [];

  for (const context of required) {
    const entry = states.get(context);
    if (!entry) {
      missing.push(context);
      continue;
    }
    if (!entry.success || entry.failure) {
      failing.push(context);
    }
  }

  return {
    required,
    missing,
    failing,
    ready: missing.length === 0 && failing.length === 0,
  };
}

function evaluateTrustContext(policy, repository, pull) {
  const denialReasons = [];
  const normalizedRepository = normalizeRepositorySlug(repository);
  const { owner } = parseRepoSlug(repository);
  const headOwner = normalizeOwner(pull.headRepositoryOwner);
  const baseRefAllowed = policy.allowedBaseRefs.includes(normalizeBaseRef(pull.baseRefName));

  if (!baseRefAllowed) {
    denialReasons.push('unsupported-base-ref');
  }
  if (
    policy.trust.requireRepositoryMatch &&
    normalizeRepositorySlug(pull.headRepository) &&
    pull.headRepository !== normalizedRepository
  ) {
    denialReasons.push('repository-mismatch');
  }
  if (pull.isCrossRepository && !policy.trust.allowCrossRepository) {
    denialReasons.push('cross-repository-disallowed');
  }
  if (
    policy.trust.allowedHeadOwners.length > 0 &&
    !policy.trust.allowedHeadOwners.includes(headOwner)
  ) {
    denialReasons.push(headOwner ? 'untrusted-head-owner' : 'unknown-head-owner');
  }

  return {
    trusted: denialReasons.length === 0,
    repository,
    targetOwner: owner.toLowerCase(),
    baseRef: normalizeBaseRef(pull.baseRefName),
    headOwner: headOwner || null,
    isCrossRepository: pull.isCrossRepository === true,
    denialReasons,
  };
}

function summarizeRequiredChecks(branchPolicyPath, requiredChecksEvaluation, pull) {
  return {
    policyPath: branchPolicyPath,
    baseRef: normalizeBaseRef(pull.baseRefName),
    mergeStateStatus: normalizeText(pull.mergeStateStatus) ?? 'unknown',
    required: requiredChecksEvaluation.required,
    missing: requiredChecksEvaluation.missing,
    failing: requiredChecksEvaluation.failing,
    ready: requiredChecksEvaluation.ready,
  };
}

function evaluateDecision({
  policy,
  pull,
  reviewSignal,
  attestation,
  deploymentDeterminism,
  trustContext,
  requiredChecks,
  providerErrors,
}) {
  const blockers = [];
  const denials = [...trustContext.denialReasons];
  const notes = [];

  for (const providerError of providerErrors) {
    blockers.push(providerError.code);
    notes.push(providerError.message);
  }

  if (policy.providers.requireReviewSignal) {
    if (!reviewSignal.available) {
      blockers.push('review-signal-unavailable');
    } else {
      if (
        reviewSignal.status !== 'pass' ||
        reviewSignal.reviewState === 'error' ||
        reviewSignal.errorCount > 0
      ) {
        blockers.push('review-signal-invalid');
      }
      if (!reviewSignal.hasCurrentHeadReview) {
        blockers.push('current-head-review-missing');
      }
      if (reviewSignal.staleReviewCount > 0) {
        blockers.push('stale-review-present');
      }
      if (reviewSignal.actionableCommentCount > 0) {
        blockers.push('actionable-comments-present');
      }
    }
  }

  if (policy.providers.requireAgentAttestation) {
    if (!attestation.available) {
      blockers.push('agent-attestation-unavailable');
    } else {
      if (attestation.pullRequestNumber !== null && pull.number !== null && attestation.pullRequestNumber !== pull.number) {
        blockers.push('attestation-pr-mismatch');
      }
      if (attestation.headSha && pull.headSha && attestation.headSha !== pull.headSha) {
        blockers.push('attestation-head-mismatch');
      }
      if (
        reviewSignal.available &&
        attestation.reviewSignalActionableCommentCount !== reviewSignal.actionableCommentCount
      ) {
        blockers.push('attestation-actionable-comment-count-mismatch');
      }
      if (
        reviewSignal.available &&
        attestation.reviewSignalUnresolvedThreadCount !== reviewSignal.unresolvedThreadCount
      ) {
        blockers.push('attestation-unresolved-thread-count-mismatch');
      }
      if (
        policy.attestation.requireValidationEvidencePass &&
        attestation.failedEvidenceCount > 0
      ) {
        blockers.push('attestation-validation-evidence-failed');
      }
      if (
        policy.attestation.requireDispositionsForActionableComments &&
        attestation.commentDispositionCount < attestation.reviewSignalActionableCommentCount
      ) {
        blockers.push('attestation-comment-dispositions-incomplete');
      }
      if (
        policy.attestation.requireDispositionsForUnresolvedThreads &&
        attestation.threadDispositionCount < attestation.reviewSignalUnresolvedThreadCount
      ) {
        blockers.push('attestation-thread-dispositions-incomplete');
      }
    }
  }

  if (policy.providers.requireDeploymentDeterminism) {
    if (!deploymentDeterminism.available) {
      blockers.push('deployment-determinism-unavailable');
    } else {
      if (
        normalizeText(policy.environment) !== normalizeText(deploymentDeterminism.environment)
      ) {
        blockers.push('deployment-environment-mismatch');
      }
      if (deploymentDeterminism.result !== 'pass' || deploymentDeterminism.issueCount > 0) {
        blockers.push('deployment-determinism-failed');
      }
    }
  }

  if (policy.providers.requireRequiredChecks) {
    if (!requiredChecks.available) {
      blockers.push('required-checks-unavailable');
    } else {
      if (requiredChecks.required.length === 0) {
        blockers.push('required-check-policy-missing-for-base-ref');
      }
      if (!requiredChecks.ready) {
        blockers.push('required-checks-not-ready');
      }
    }
  }

  const state = denials.length > 0 ? 'denied' : blockers.length > 0 ? 'blocked' : 'ready';
  const reasons =
    state === 'denied'
      ? denials
      : state === 'blocked'
        ? blockers
        : ['approval-ready-shadow-mode'];

  return {
    state,
    ready: state === 'ready',
    blockers: uniqueStrings(blockers),
    denials: uniqueStrings(denials),
    reasons: uniqueStrings(reasons),
    notes: uniqueStrings(notes),
    summary:
      state === 'ready'
        ? 'All required broker inputs are trusted and ready. Shadow mode only; no approval was performed.'
        : state === 'denied'
          ? `Approval denied by trust policy: ${uniqueStrings(reasons).join(', ')}`
          : `Approval blocked: ${uniqueStrings(reasons).join(', ')}`,
  };
}

function appendStepSummary(stepSummaryPath, report) {
  if (!stepSummaryPath) {
    return Promise.resolve();
  }

  const lines = [
    '### Validation Approval Broker',
    '',
    `- decision: \`${report.decision.state}\``,
    `- shadow_mode: \`${report.policy.shadowMode}\``,
    `- repository: \`${report.repository}\``,
    `- environment: \`${report.environment}\``,
    `- pull_request: \`#${report.pullRequest.number ?? 'unknown'}\``,
    `- head_sha: \`${report.pullRequest.headSha ?? 'unknown'}\``,
    `- current_head_review: \`${report.providers.reviewSignal.hasCurrentHeadReview}\``,
    `- required_checks_ready: \`${report.providers.requiredChecks.ready}\``,
    `- deployment_determinism: \`${report.providers.deploymentDeterminism.result}\``,
    '',
    `Summary: ${report.decision.summary}`,
  ];

  if (report.decision.reasons.length > 0) {
    lines.push('', 'Reasons:');
    for (const reason of report.decision.reasons) {
      lines.push(`- ${reason}`);
    }
  }

  const resolved = path.resolve(process.cwd(), stepSummaryPath);
  return mkdir(path.dirname(resolved), { recursive: true }).then(() =>
    writeFile(resolved, `${lines.join('\n')}\n`, { encoding: 'utf8', flag: 'a' }),
  );
}

function buildReport({
  now,
  repository,
  environment,
  policy,
  pull,
  reviewSignal,
  attestation,
  deploymentDeterminism,
  trustContext,
  requiredChecks,
  decision,
  outPath,
  eventsOutPath,
}) {
  return {
    schema: VALIDATION_APPROVAL_DECISION_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: decision.ready ? 'pass' : 'fail',
    mode: 'evaluate',
    repository,
    environment,
    pullRequest: {
      number: pull.number,
      url: pull.url,
      isDraft: pull.isDraft,
      headSha: pull.headSha,
      headRefName: pull.headRefName,
      baseRefName: pull.baseRefName,
      headRepositoryOwner: pull.headRepositoryOwner || null,
      isCrossRepository: pull.isCrossRepository,
      mergeStateStatus: pull.mergeStateStatus,
    },
    policy: {
      schema: policy.schema,
      schemaVersion: policy.schemaVersion,
      path: policy.path,
      shadowMode: policy.shadowMode,
      allowedBaseRefs: policy.allowedBaseRefs,
      trust: {
        requireRepositoryMatch: policy.trust.requireRepositoryMatch,
        allowCrossRepository: policy.trust.allowCrossRepository,
        allowedHeadOwners: policy.trust.allowedHeadOwners,
      },
      providers: policy.providers,
      attestation: policy.attestation,
    },
    providers: {
      reviewSignal,
      agentAttestation: attestation,
      deploymentDeterminism,
      trustContext,
      requiredChecks,
    },
    decision,
    artifacts: {
      decisionPath: outPath,
      eventsPath: eventsOutPath,
    },
  };
}

function buildFailureReport(options, now, message) {
  return {
    schema: VALIDATION_APPROVAL_DECISION_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: 'fail',
    mode: 'evaluate',
    repository: normalizeText(options.repo),
    environment: normalizeText(options.environment) ?? 'validation',
    pullRequest: {
      number: options.prNumber,
      url: null,
      isDraft: null,
      headSha: null,
      headRefName: null,
      baseRefName: null,
      headRepositoryOwner: null,
      isCrossRepository: null,
      mergeStateStatus: null,
    },
    policy: {
      schema: null,
      schemaVersion: null,
      path: options.policyPath,
      shadowMode: true,
      allowedBaseRefs: [],
      trust: {
        requireRepositoryMatch: true,
        allowCrossRepository: false,
        allowedHeadOwners: [],
      },
      providers: {
        requireReviewSignal: true,
        requireAgentAttestation: true,
        requireDeploymentDeterminism: true,
        requireRequiredChecks: true,
      },
      attestation: {
        requireValidationEvidencePass: true,
        requireDispositionsForActionableComments: true,
        requireDispositionsForUnresolvedThreads: true,
      },
    },
    providers: {
      reviewSignal: {
        path: options.signalPath,
        available: false,
        status: 'error',
        reviewState: 'error',
        headSha: null,
        pullRequestNumber: null,
        hasCurrentHeadReview: false,
        actionableCommentCount: 0,
        unresolvedThreadCount: 0,
        staleReviewCount: 0,
        errorCount: 1,
      },
      agentAttestation: {
        path: options.attestationPath,
        available: false,
        repository: null,
        pullRequestNumber: null,
        headSha: null,
        reviewSignalActionableCommentCount: 0,
        reviewSignalUnresolvedThreadCount: 0,
        threadDispositionCount: 0,
        commentDispositionCount: 0,
        failedEvidenceCount: 0,
        commandFailureCount: 0,
        checkFailureCount: 0,
      },
      deploymentDeterminism: {
        path: options.deploymentDeterminismPath,
        available: false,
        environment: null,
        result: 'error',
        issueCount: 0,
        issues: [],
        runId: null,
      },
      trustContext: {
        trusted: false,
        repository: normalizeText(options.repo),
        targetOwner: null,
        baseRef: null,
        headOwner: null,
        isCrossRepository: null,
        denialReasons: [],
      },
      requiredChecks: {
        policyPath: options.requiredChecksPolicyPath,
        baseRef: null,
        mergeStateStatus: 'unknown',
        required: [],
        missing: [],
        failing: [],
        ready: false,
        available: false,
      },
    },
    decision: {
      state: 'blocked',
      ready: false,
      blockers: ['broker-runtime-error'],
      denials: [],
      reasons: ['broker-runtime-error'],
      notes: [message],
      summary: message,
    },
    artifacts: {
      decisionPath: options.outPath,
      eventsPath: options.eventsOutPath,
    },
  };
}

function summarizeProviderAvailability(record, providerPath) {
  return {
    path: providerPath,
    available: false,
    status: 'error',
    reviewState: 'error',
    headSha: null,
    pullRequestNumber: null,
    hasCurrentHeadReview: false,
    actionableCommentCount: 0,
    unresolvedThreadCount: 0,
    staleReviewCount: 0,
    errorCount: 1,
    error: record.message,
  };
}

export async function runValidationApprovalBroker({
  argv = process.argv,
  now = new Date(),
  readJsonFn = readJsonFile,
  loadPullFn = loadPullContext,
  writeReportFn = writeJsonFile,
  writeEventsFn = writeNdjsonFile,
  appendStepSummaryFn = appendStepSummary,
} = {}) {
  const events = [];
  let options = null;
  try {
    options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return { exitCode: 0, report: null, reportPath: null, eventsPath: null };
    }

    const repository = resolveRepository(options);
    const providerErrors = [];
    events.push(
      createRuntimeEvent(now, 'lifecycle', 'info', 'Starting validation approval broker evaluation.', {
        repository,
        environment: options.environment,
        pr: options.prNumber,
      }),
    );

    let policy = null;
    try {
      policy = normalizePolicy(readJsonFn(options.policyPath), options.policyPath);
      events.push(
        createRuntimeEvent(now, 'load', 'info', 'Loaded approval policy.', {
          path: options.policyPath,
          allowedBaseRefs: policy.allowedBaseRefs,
        }),
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      providerErrors.push({ code: 'policy-unavailable', message });
      events.push(
        createRuntimeEvent(now, 'load', 'error', 'Failed to load approval policy.', {
          path: options.policyPath,
          error: message,
        }),
      );

      const policyPathMatchesDefault =
        path.resolve(process.cwd(), options.policyPath) ===
        path.resolve(process.cwd(), DEFAULT_POLICY_PATH);
      if (!policyPathMatchesDefault) {
        try {
          policy = normalizePolicy(readJsonFn(DEFAULT_POLICY_PATH), DEFAULT_POLICY_PATH);
          events.push(
            createRuntimeEvent(now, 'load', 'warning', 'Loaded default approval policy fallback.', {
              path: DEFAULT_POLICY_PATH,
              requestedPath: options.policyPath,
            }),
          );
        } catch (fallbackError) {
          const fallbackMessage =
            fallbackError instanceof Error ? fallbackError.message : String(fallbackError);
          providerErrors.push({ code: 'default-policy-unavailable', message: fallbackMessage });
          events.push(
            createRuntimeEvent(
              now,
              'load',
              'error',
              'Failed to load default approval policy fallback.',
              {
                path: DEFAULT_POLICY_PATH,
                requestedPath: options.policyPath,
                error: fallbackMessage,
              },
            ),
          );
        }
      }

      if (!policy) {
        policy = getBuiltinFailClosedPolicy();
        events.push(
          createRuntimeEvent(
            now,
            'load',
            'warning',
            'Using built-in fail-closed approval policy fallback.',
            {
              path: BUILTIN_FAIL_CLOSED_POLICY_PATH,
              requestedPath: options.policyPath,
            },
          ),
        );
      }
    }

    let branchRequiredChecksPolicy = null;
    try {
      branchRequiredChecksPolicy = readJsonFn(options.requiredChecksPolicyPath);
      events.push(
        createRuntimeEvent(now, 'load', 'info', 'Loaded branch required-checks policy.', {
          path: options.requiredChecksPolicyPath,
        }),
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      providerErrors.push({ code: 'required-checks-policy-unavailable', message });
      events.push(
        createRuntimeEvent(
          now,
          'load',
          'error',
          'Failed to load branch required-checks policy.',
          {
            path: options.requiredChecksPolicyPath,
            error: message,
          },
        ),
      );
      branchRequiredChecksPolicy = { branches: {} };
    }

    const pull = (() => {
      try {
        const loaded = loadPullFn(options, repository, readJsonFn);
        loaded.repository = repository;
        events.push(
          createRuntimeEvent(now, 'load', 'info', 'Loaded pull request context.', {
            baseRef: loaded.baseRefName,
            headSha: loaded.headSha,
            headOwner: loaded.headRepositoryOwner,
            isCrossRepository: loaded.isCrossRepository,
          }),
        );
        return loaded;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        providerErrors.push({ code: 'pull-context-unavailable', message });
        events.push(
          createRuntimeEvent(now, 'load', 'error', 'Failed to load pull request context.', {
            error: message,
          }),
        );
        return normalizePullContext({}, repository);
      }
    })();

    const reviewSignal = (() => {
      try {
        const loaded = summarizeReviewSignal(readJsonFn(options.signalPath), options.signalPath);
        events.push(
          createRuntimeEvent(now, 'load', 'info', 'Loaded Copilot review signal.', {
            path: options.signalPath,
            currentHeadReview: loaded.hasCurrentHeadReview,
            actionableCommentCount: loaded.actionableCommentCount,
          }),
        );
        return loaded;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        providerErrors.push({ code: 'review-signal-unavailable', message });
        events.push(
          createRuntimeEvent(now, 'load', 'error', 'Failed to load Copilot review signal.', {
            path: options.signalPath,
            error: message,
          }),
        );
        return summarizeProviderAvailability({ message }, options.signalPath);
      }
    })();

    const attestation = (() => {
      try {
        const loaded = summarizeAttestation(readJsonFn(options.attestationPath), options.attestationPath);
        events.push(
          createRuntimeEvent(now, 'load', 'info', 'Loaded validation agent attestation.', {
            path: options.attestationPath,
            threadDispositionCount: loaded.threadDispositionCount,
            commentDispositionCount: loaded.commentDispositionCount,
            failedEvidenceCount: loaded.failedEvidenceCount,
          }),
        );
        return loaded;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        providerErrors.push({ code: 'agent-attestation-unavailable', message });
        events.push(
          createRuntimeEvent(
            now,
            'load',
            'error',
            'Failed to load validation agent attestation.',
            {
              path: options.attestationPath,
              error: message,
            },
          ),
        );
        return {
          path: options.attestationPath,
          available: false,
          repository: null,
          pullRequestNumber: null,
          headSha: null,
          reviewSignalActionableCommentCount: 0,
          reviewSignalUnresolvedThreadCount: 0,
          threadDispositionCount: 0,
          commentDispositionCount: 0,
          failedEvidenceCount: 0,
          commandFailureCount: 0,
          checkFailureCount: 0,
        };
      }
    })();

    const deploymentDeterminism = (() => {
      try {
        const loaded = summarizeDeploymentDeterminism(
          readJsonFn(options.deploymentDeterminismPath),
          options.deploymentDeterminismPath,
        );
        events.push(
          createRuntimeEvent(now, 'load', 'info', 'Loaded deployment determinism report.', {
            path: options.deploymentDeterminismPath,
            result: loaded.result,
            issueCount: loaded.issueCount,
          }),
        );
        return loaded;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        providerErrors.push({ code: 'deployment-determinism-unavailable', message });
        events.push(
          createRuntimeEvent(
            now,
            'load',
            'error',
            'Failed to load deployment determinism report.',
            {
              path: options.deploymentDeterminismPath,
              error: message,
            },
          ),
        );
        return {
          path: options.deploymentDeterminismPath,
          available: false,
          environment: null,
          result: 'error',
          issueCount: 0,
          issues: [],
          runId: null,
        };
      }
    })();

    const trustContext = evaluateTrustContext(policy, repository, pull);
    const requiredChecksEvaluation = evaluateRequiredChecks(
      resolveRequiredChecks(branchRequiredChecksPolicy, pull.baseRefName),
      pull.statusCheckRollup,
    );
    const requiredChecks = {
      ...summarizeRequiredChecks(options.requiredChecksPolicyPath, requiredChecksEvaluation, pull),
      available: !providerErrors.some((entry) => entry.code === 'required-checks-policy-unavailable'),
    };
    const decision = evaluateDecision({
      policy,
      pull,
      reviewSignal,
      attestation,
      deploymentDeterminism,
      trustContext,
      requiredChecks,
      providerErrors,
    });

    events.push(
      createRuntimeEvent(
        now,
        'decision',
        decision.ready ? 'info' : decision.state === 'denied' ? 'error' : 'warning',
        'Completed validation approval broker evaluation.',
        {
          decision: decision.state,
          reasons: decision.reasons,
          blockedCount: decision.blockers.length,
          deniedCount: decision.denials.length,
        },
      ),
    );

    const report = buildReport({
      now,
      repository,
      environment: options.environment,
      policy,
      pull,
      reviewSignal,
      attestation,
      deploymentDeterminism,
      trustContext,
      requiredChecks,
      decision,
      outPath: options.outPath,
      eventsOutPath: options.eventsOutPath,
    });

    const [reportPath, eventsPath] = await Promise.all([
      writeReportFn(options.outPath, report),
      writeEventsFn(options.eventsOutPath, events),
      appendStepSummaryFn(options.stepSummaryPath, report),
    ]);

    console.log(`[validation-approval-broker] report: ${reportPath}`);
    console.log(`[validation-approval-broker] events: ${eventsPath}`);
    console.log(
      `[validation-approval-broker] decision=${report.decision.state} reasons=${report.decision.reasons.join(',') || 'none'}`,
    );

    return {
      exitCode: report.decision.ready ? 0 : 1,
      report,
      reportPath,
      eventsPath,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const failureOptions = options ?? {
      policyPath: DEFAULT_POLICY_PATH,
      requiredChecksPolicyPath: DEFAULT_REQUIRED_CHECKS_POLICY_PATH,
      signalPath: DEFAULT_SIGNAL_PATH,
      attestationPath: DEFAULT_ATTESTATION_PATH,
      deploymentDeterminismPath: DEFAULT_DEPLOYMENT_DETERMINISM_PATH,
      repo: null,
      prNumber: null,
      environment: 'validation',
      outPath: DEFAULT_REPORT_PATH,
      eventsOutPath: DEFAULT_EVENTS_PATH,
      stepSummaryPath: null,
    };
    const failureEvents = [
      createRuntimeEvent(
        now,
        'decision',
        'error',
        'Validation approval broker failed before evaluation completed.',
        { error: message },
      ),
    ];
    const report = buildFailureReport(failureOptions, now, message);
    const [reportPath, eventsPath] = await Promise.all([
      writeReportFn(failureOptions.outPath, report),
      writeEventsFn(failureOptions.eventsOutPath, failureEvents),
      appendStepSummaryFn(failureOptions.stepSummaryPath, report),
    ]);
    console.error(message);
    return {
      exitCode: 1,
      report,
      reportPath,
      eventsPath,
    };
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  runValidationApprovalBroker().then((result) => {
    process.exit(result.exitCode);
  });
}

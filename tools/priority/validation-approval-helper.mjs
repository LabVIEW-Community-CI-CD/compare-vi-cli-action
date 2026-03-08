#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const VALIDATION_APPROVAL_HELPER_SCHEMA = 'validation-approval-helper@v1';
export const VALIDATION_APPROVAL_DECISION_SCHEMA = 'validation-approval-decision@v1';
export const DEFAULT_DECISION_OUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'approvals',
  'validation-approval-decision.json',
);
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'approvals',
  'validation-approval-helper.json',
);
export const DEFAULT_ENVIRONMENT = 'validation';

const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const NODE_JSON_MAX_BUFFER_BYTES = 16 * 1024 * 1024;
const BLOCKED_ENVIRONMENT_KEYWORDS = ['production', 'release', 'publish'];

function environmentAllowed(environmentName) {
  const normalized = normalizeText(environmentName)?.toLowerCase();
  if (!normalized) {
    return false;
  }
  if (normalized !== DEFAULT_ENVIRONMENT) {
    return false;
  }
  return !isBlockedEnvironmentName(normalized);
}

function printUsage() {
  const lines = [
    'Usage: node tools/priority/validation-approval-helper.mjs [options]',
    '',
    'Evaluates or consumes a validation approval broker decision for a specific workflow run and optionally approves the pending validation deployment.',
    '',
    'Options:',
    '  --repo <owner/repo>             Target repository (default: GITHUB_REPOSITORY).',
    '  --run-id <id>                   Target workflow run id that is waiting on approval.',
    `  --environment <name>            Target environment (default: ${DEFAULT_ENVIRONMENT}).`,
    '  --pr <number>                   Pull request number (required for broker evaluation without --pull-file).',
    '  --decision <path>               Existing broker decision JSON to consume.',
    '  --signal <path>                 Copilot review signal JSON path for broker evaluation.',
    '  --attestation <path>            Validation agent attestation JSON path for broker evaluation.',
    '  --deployment-determinism <path> Deployment determinism JSON path for broker evaluation.',
    '  --pull-file <path>              Offline pull context JSON path for broker evaluation.',
    '  --policy <path>                 Optional broker policy path override.',
    '  --required-checks-policy <path> Optional broker required-checks policy override.',
    '  --decision-out <path>           Normalized broker decision output path.',
    `                                 (default: ${DEFAULT_DECISION_OUT_PATH}).`,
    `  --out <path>                    Helper report JSON output path (default: ${DEFAULT_REPORT_PATH}).`,
    '  --comment <text>                Approval review comment.',
    '  --approve                       Approve the pending validation deployment when ready.',
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

function normalizeSha(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function normalizeRepositorySlug(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const segments = normalized.split('/').map((segment) => segment.trim());
  if (segments.length !== 2 || segments.some((segment) => segment.length === 0)) {
    throw new Error(`Invalid repository slug '${value}'. Expected <owner>/<repo>.`);
  }
  return `${segments[0]}/${segments[1]}`;
}

function uniqueStrings(values) {
  return [...new Set((Array.isArray(values) ? values : []).filter(Boolean).map((entry) => String(entry)))];
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

function appendStepSummary(stepSummaryPath, report) {
  if (!stepSummaryPath) {
    return Promise.resolve();
  }

  const lines = [
    '### Validation Approval Helper',
    '',
    `- repository: \`${report.repository}\``,
    `- target_run: \`${report.targetRun.id ?? 'unknown'}\``,
    `- broker_mode: \`${report.source.mode}\``,
    `- environment: \`${report.environment.requested}\``,
    `- pull_request: \`#${report.pullRequest.number ?? 'unknown'}\``,
    `- decision_state: \`${report.decision.state}\``,
    `- approval_requested: \`${report.approval.requested}\``,
    `- approval_state: \`${report.approval.state}\``,
    '',
    `Summary: ${report.summary}`,
  ];

  if (report.reasons.length > 0) {
    lines.push('', 'Reasons:');
    for (const reason of report.reasons) {
      lines.push(`- ${reason}`);
    }
  }

  if (report.environment.matchedEnvironmentNames.length > 0) {
    lines.push('', `Matched environments: ${report.environment.matchedEnvironmentNames.join(', ')}`);
  }

  const resolved = path.resolve(process.cwd(), stepSummaryPath);
  return mkdir(path.dirname(resolved), { recursive: true }).then(() =>
    writeFile(resolved, `${lines.join('\n')}\n`, { encoding: 'utf8', flag: 'a' }),
  );
}

function resolveRepository(options, environment = process.env) {
  const explicit = normalizeText(options.repo);
  if (explicit) {
    return normalizeRepositorySlug(explicit);
  }

  const fromEnv = normalizeText(environment.GITHUB_REPOSITORY);
  if (fromEnv) {
    return normalizeRepositorySlug(fromEnv);
  }

  throw new Error('Repository is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: null,
    runId: null,
    environment: DEFAULT_ENVIRONMENT,
    prNumber: null,
    decisionPath: null,
    signalPath: null,
    attestationPath: null,
    deploymentDeterminismPath: null,
    pullFile: null,
    policyPath: null,
    requiredChecksPolicyPath: null,
    decisionOutPath: DEFAULT_DECISION_OUT_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    comment: 'Brokered validation approval granted by validation-approval-helper.',
    approve: false,
    stepSummaryPath: null,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--approve') {
      options.approve = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--run-id' ||
      token === '--environment' ||
      token === '--pr' ||
      token === '--decision' ||
      token === '--signal' ||
      token === '--attestation' ||
      token === '--deployment-determinism' ||
      token === '--pull-file' ||
      token === '--policy' ||
      token === '--required-checks-policy' ||
      token === '--decision-out' ||
      token === '--out' ||
      token === '--comment' ||
      token === '--step-summary'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = next;
      if (token === '--run-id') options.runId = normalizeInteger(next);
      if (token === '--environment') options.environment = normalizeText(next) ?? DEFAULT_ENVIRONMENT;
      if (token === '--pr') options.prNumber = normalizeInteger(next);
      if (token === '--decision') options.decisionPath = next;
      if (token === '--signal') options.signalPath = next;
      if (token === '--attestation') options.attestationPath = next;
      if (token === '--deployment-determinism') options.deploymentDeterminismPath = next;
      if (token === '--pull-file') options.pullFile = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--required-checks-policy') options.requiredChecksPolicyPath = next;
      if (token === '--decision-out') options.decisionOutPath = next;
      if (token === '--out') options.reportPath = next;
      if (token === '--comment') options.comment = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && options.runId === null) {
    throw new Error('Workflow run id is required. Pass --run-id <id>.');
  }

  if (
    !options.help &&
    !options.decisionPath &&
    options.prNumber === null &&
    !options.pullFile
  ) {
    throw new Error(
      'Broker evaluation requires --decision or one of --pr / --pull-file.',
    );
  }

  return options;
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

function runBrokerSubprocess(args) {
  const result = spawnSync(process.execPath, args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: NODE_JSON_MAX_BUFFER_BYTES,
  });

  return {
    status: result.status ?? 0,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function normalizeRunContext(run) {
  return {
    id: normalizeInteger(run?.id),
    name: normalizeText(run?.name),
    workflowPath: normalizeText(run?.path),
    htmlUrl: normalizeText(run?.html_url ?? run?.htmlUrl),
    headBranch: normalizeText(run?.head_branch ?? run?.headBranch),
    headSha: normalizeSha(run?.head_sha ?? run?.headSha),
    status: normalizeText(run?.status) ?? 'unknown',
    conclusion: normalizeText(run?.conclusion),
  };
}

function normalizePendingDeployment(entry) {
  const environment = entry?.environment ?? {};
  const environmentId =
    normalizeInteger(environment?.id) ??
    normalizeInteger(entry?.environment_id ?? entry?.environmentId);
  const environmentName =
    normalizeText(environment?.name) ??
    normalizeText(entry?.environment_name ?? entry?.environmentName);
  return {
    environmentId,
    environmentName: environmentName ? environmentName.toLowerCase() : null,
    currentUserCanApprove: normalizeBoolean(
      entry?.current_user_can_approve ?? entry?.currentUserCanApprove,
    ),
    waitTimer: normalizeInteger(entry?.wait_timer ?? entry?.waitTimer),
  };
}

function normalizePullContext(raw) {
  return {
    number: normalizeInteger(raw?.number),
    url: normalizeText(raw?.url),
    state: normalizeText(raw?.state),
    isDraft: normalizeBoolean(raw?.isDraft ?? raw?.draft) ?? false,
    headSha: normalizeSha(raw?.headRefOid ?? raw?.headSha ?? raw?.head?.sha),
    headRefName: normalizeText(raw?.headRefName ?? raw?.head?.ref),
    baseRefName: normalizeText(raw?.baseRefName ?? raw?.base?.ref),
    headRepositoryOwner:
      normalizeText(raw?.headRepositoryOwner?.login ?? raw?.headRepositoryOwner) ?? null,
    headRepositoryName:
      normalizeText(raw?.headRepository?.name ?? raw?.headRepositoryName) ?? null,
    isCrossRepository: normalizeBoolean(raw?.isCrossRepository) ?? false,
  };
}

function normalizeDecision(raw, decisionPath) {
  if (raw?.schema !== VALIDATION_APPROVAL_DECISION_SCHEMA) {
    throw new Error(
      `Unexpected validation approval decision schema '${String(raw?.schema ?? 'unknown')}'.`,
    );
  }

  return {
    raw,
    path: decisionPath,
    state: normalizeText(raw?.decision?.state) ?? 'unknown',
    ready: raw?.decision?.ready === true,
    reasons: uniqueStrings(raw?.decision?.reasons),
    summary: normalizeText(raw?.decision?.summary) ?? 'Decision summary unavailable.',
    repository: normalizeRepositorySlug(raw?.repository),
    environment: normalizeText(raw?.environment)?.toLowerCase() ?? null,
    pullRequestNumber: normalizeInteger(raw?.pullRequest?.number),
    pullRequestUrl: normalizeText(raw?.pullRequest?.url),
    headSha: normalizeSha(raw?.pullRequest?.headSha),
    trustTrusted: raw?.providers?.trustContext?.trusted === true,
    policy: {
      allowedBaseRefs: uniqueStrings(raw?.policy?.allowedBaseRefs).map((entry) => String(entry).toLowerCase()),
      trust: {
        requireRepositoryMatch: raw?.policy?.trust?.requireRepositoryMatch !== false,
        allowCrossRepository: raw?.policy?.trust?.allowCrossRepository === true,
        allowedHeadOwners: uniqueStrings(raw?.policy?.trust?.allowedHeadOwners).map((entry) =>
          String(entry).toLowerCase(),
        ),
      },
    },
    hasCurrentHeadReview: raw?.providers?.reviewSignal?.hasCurrentHeadReview === true,
    staleReviewCount: normalizeInteger(raw?.providers?.reviewSignal?.staleReviewCount) ?? 0,
    actionableCommentCount:
      normalizeInteger(raw?.providers?.reviewSignal?.actionableCommentCount) ?? 0,
    unresolvedThreadCount:
      normalizeInteger(raw?.providers?.reviewSignal?.unresolvedThreadCount) ?? 0,
    requiredChecksReady: raw?.providers?.requiredChecks?.ready === true,
  };
}

function resolveApprovalComment(comment, decision) {
  const explicit = normalizeText(comment);
  if (explicit) {
    return explicit;
  }
  const summary = normalizeText(decision?.summary);
  if (summary) {
    return `Validation approval broker ready: ${summary}`;
  }
  return 'Brokered validation approval granted by validation-approval-helper.';
}

function isBlockedEnvironmentName(environmentName) {
  const normalized = normalizeText(environmentName)?.toLowerCase();
  if (!normalized) {
    return false;
  }
  return BLOCKED_ENVIRONMENT_KEYWORDS.some((keyword) => normalized.includes(keyword));
}

function resolvePendingValidationDeployments(entries, requestedEnvironment) {
  const normalizedRequested = normalizeText(requestedEnvironment)?.toLowerCase() ?? DEFAULT_ENVIRONMENT;
  const pendingEntries = (Array.isArray(entries) ? entries : []).map(normalizePendingDeployment);
  const matching = pendingEntries.filter((entry) => entry.environmentName === normalizedRequested);
  return {
    requestedEnvironment: normalizedRequested,
    pendingEntries,
    matching,
    matchingEnvironmentIds: uniqueStrings(
      matching
        .map((entry) => entry.environmentId)
        .filter((entry) => Number.isInteger(Number(entry))),
    ).map((entry) => Number(entry)),
    matchingEnvironmentNames: uniqueStrings(matching.map((entry) => entry.environmentName)),
  };
}

function buildFailureReport(options, now, errorMessage) {
  const isEnvironmentError = /validation environment/i.test(errorMessage);
  const reason = isEnvironmentError ? 'environment-not-allowed' : 'helper-runtime-error';
  const decisionState = isEnvironmentError ? 'denied' : 'error';
  return {
    schema: VALIDATION_APPROVAL_HELPER_SCHEMA,
    generatedAt: now.toISOString(),
    status: 'fail',
    repository: normalizeText(options.repo),
    source: {
      mode: options.decisionPath ? 'consume' : 'evaluate',
      decisionPath: normalizeText(options.decisionPath),
      decisionOutPath: options.decisionOutPath,
      brokerExitCode: null,
    },
    targetRun: {
      id: options.runId,
      name: null,
      workflowPath: null,
      htmlUrl: null,
      headBranch: null,
      headSha: null,
      status: 'unknown',
      conclusion: null,
    },
    environment: {
      requested: normalizeText(options.environment)?.toLowerCase() ?? DEFAULT_ENVIRONMENT,
      matchedEnvironmentIds: [],
      matchedEnvironmentNames: [],
      currentUserCanApprove: null,
    },
    pullRequest: {
      number: options.prNumber,
      url: null,
      state: null,
      isDraft: false,
      headSha: null,
      headRefName: null,
    },
    decision: {
      path: normalizeText(options.decisionPath) ?? options.decisionOutPath,
      state: decisionState,
      ready: false,
      reasons: [reason],
      summary: errorMessage,
      repository: normalizeText(options.repo),
      environment: normalizeText(options.environment)?.toLowerCase() ?? DEFAULT_ENVIRONMENT,
      pullRequestNumber: options.prNumber,
      pullRequestUrl: null,
      headSha: null,
      trustTrusted: false,
      hasCurrentHeadReview: false,
      staleReviewCount: 0,
      actionableCommentCount: 0,
      unresolvedThreadCount: 0,
      requiredChecksReady: false,
    },
    reasons: [reason],
    summary: errorMessage,
    approval: {
      requested: options.approve === true,
      performed: false,
      state: 'error',
      comment: normalizeText(options.comment),
      environmentIds: [],
    },
  };
}

function evaluateLiveTrustContext(policy, repository, pullRequest) {
  const denialReasons = [];
  const normalizedRepository = normalizeRepositorySlug(repository).toLowerCase();
  const allowedBaseRefs = Array.isArray(policy?.allowedBaseRefs) ? policy.allowedBaseRefs : [];
  const allowedHeadOwners = Array.isArray(policy?.trust?.allowedHeadOwners)
    ? policy.trust.allowedHeadOwners
    : [];
  const baseRef = normalizeText(pullRequest.baseRefName)?.toLowerCase();
  const headOwner = normalizeText(pullRequest.headRepositoryOwner)?.toLowerCase();
  const headRepositoryName = normalizeText(pullRequest.headRepositoryName);
  const headRepositorySlug =
    headOwner && headRepositoryName
      ? normalizeRepositorySlug(`${headOwner}/${headRepositoryName}`).toLowerCase()
      : null;

  if (allowedBaseRefs.length > 0 && (!baseRef || !allowedBaseRefs.includes(baseRef))) {
    denialReasons.push('unsupported-base-ref');
  }
  if (policy?.trust?.requireRepositoryMatch !== false && headRepositorySlug && headRepositorySlug !== normalizedRepository) {
    denialReasons.push('repository-mismatch');
  }
  if (pullRequest.isCrossRepository && policy?.trust?.allowCrossRepository !== true) {
    denialReasons.push('cross-repository-disallowed');
  }
  if (allowedHeadOwners.length > 0 && (!headOwner || !allowedHeadOwners.includes(headOwner))) {
    denialReasons.push(headOwner ? 'untrusted-head-owner' : 'unknown-head-owner');
  }

  return {
    trusted: denialReasons.length === 0,
    denialReasons: uniqueStrings(denialReasons),
  };
}

function buildReport({
  now,
  repository,
  sourceMode,
  decisionPath,
  decisionOutPath,
  brokerExitCode,
  targetRun,
  pending,
  pullRequest,
  decision,
  evaluationState,
  approvalRequested,
  approvalPerformed,
  approvalState,
  approvalComment,
}) {
  return {
    schema: VALIDATION_APPROVAL_HELPER_SCHEMA,
    generatedAt: now.toISOString(),
    status: evaluationState === 'ready' && (!approvalRequested || approvalPerformed) ? 'pass' : 'fail',
    repository,
    source: {
      mode: sourceMode,
      decisionPath,
      decisionOutPath,
      brokerExitCode,
    },
    targetRun,
    environment: {
      requested: pending.requestedEnvironment,
      matchedEnvironmentIds: pending.matchingEnvironmentIds,
      matchedEnvironmentNames: pending.matchingEnvironmentNames,
      currentUserCanApprove:
        pending.matching.length > 0
          ? pending.matching.every((entry) => entry.currentUserCanApprove === true)
          : null,
    },
    pullRequest,
    decision,
    reasons: evaluationState === 'denied' ? decision.reasons : uniqueStrings(decision.reasons),
    summary: decision.summary,
    approval: {
      requested: approvalRequested,
      performed: approvalPerformed,
      state: approvalState,
      comment: approvalComment,
      environmentIds: pending.matchingEnvironmentIds,
    },
  };
}

function evaluateHelperState({
  repository,
  requestedEnvironment,
  targetRun,
  pending,
  pullRequest,
  decision,
  approvalRequested,
}) {
  const denials = [];
  const blockers = [];
  const normalizedRequestedEnvironment =
    normalizeText(requestedEnvironment)?.toLowerCase() ?? DEFAULT_ENVIRONMENT;

  if (normalizedRequestedEnvironment !== DEFAULT_ENVIRONMENT || isBlockedEnvironmentName(normalizedRequestedEnvironment)) {
    denials.push('environment-not-allowed');
  }
  if (decision.repository !== normalizeRepositorySlug(repository)) {
    denials.push('decision-repository-mismatch');
  }
  if (decision.environment !== normalizedRequestedEnvironment) {
    denials.push('decision-environment-mismatch');
  }
  const liveTrust = evaluateLiveTrustContext(decision.policy, repository, pullRequest);
  if (!decision.trustTrusted || !liveTrust.trusted) {
    denials.push('untrusted-context');
    denials.push(...liveTrust.denialReasons);
  }
  if (decision.state === 'denied') {
    denials.push(...decision.reasons);
  }

  if (decision.state === 'blocked') {
    blockers.push(...decision.reasons);
  }
  if (decision.state !== 'ready' && decision.state !== 'blocked' && decision.state !== 'denied') {
    blockers.push(`broker-decision-${decision.state}`);
  }
  if (!decision.hasCurrentHeadReview || decision.staleReviewCount > 0) {
    blockers.push('stale-review-context');
  }
  if (decision.pullRequestNumber === null) {
    blockers.push('pull-request-number-unavailable');
  }
  if (pullRequest.number !== null && decision.pullRequestNumber !== null && pullRequest.number !== decision.pullRequestNumber) {
    blockers.push('pull-request-number-mismatch');
  }
  if (pullRequest.state && pullRequest.state.toUpperCase() !== 'OPEN') {
    blockers.push('pull-request-not-open');
  }
  if (pullRequest.isDraft) {
    blockers.push('pull-request-draft');
  }
  if (targetRun.headSha && decision.headSha && targetRun.headSha !== decision.headSha) {
    blockers.push('run-head-mismatch');
  }
  if (targetRun.headBranch && pullRequest.headRefName && targetRun.headBranch !== pullRequest.headRefName) {
    blockers.push('run-head-branch-mismatch');
  }
  if (pullRequest.headSha && decision.headSha && pullRequest.headSha !== decision.headSha) {
    blockers.push('pull-request-head-mismatch');
  }
  if (pending.matchingEnvironmentIds.length === 0) {
    blockers.push('pending-validation-deployment-missing');
  }
  if (
    pending.matching.some(
      (entry) => entry.environmentName !== DEFAULT_ENVIRONMENT || isBlockedEnvironmentName(entry.environmentName),
    )
  ) {
    denials.push('matched-environment-not-allowed');
  }
  if (approvalRequested && pending.matching.some((entry) => entry.currentUserCanApprove === false)) {
    blockers.push('token-cannot-approve-validation');
  }

  const state = denials.length > 0 ? 'denied' : blockers.length > 0 ? 'blocked' : 'ready';
  const reasons = state === 'denied' ? uniqueStrings(denials) : state === 'blocked' ? uniqueStrings(blockers) : ['approval-ready'];
  const summary =
    state === 'ready'
      ? 'Validation approval helper confirmed a ready broker decision for the target run.'
      : state === 'denied'
        ? `Validation approval denied: ${reasons.join(', ')}`
        : `Validation approval blocked: ${reasons.join(', ')}`;

  return { state, reasons, summary };
}

function fetchTargetRun(repository, runId, runGhJsonFn) {
  return normalizeRunContext(
    runGhJsonFn(['api', `repos/${repository}/actions/runs/${runId}`]),
  );
}

function fetchPendingDeployments(repository, runId, requestedEnvironment, runGhJsonFn) {
  return resolvePendingValidationDeployments(
    runGhJsonFn(['api', `repos/${repository}/actions/runs/${runId}/pending_deployments`]),
    requestedEnvironment,
  );
}

function fetchPullRequest(repository, prNumber, runGhJsonFn) {
  if (prNumber === null) {
    return normalizePullContext(null);
  }
  const payload = runGhJsonFn([
    'pr',
    'view',
    String(prNumber),
    '--repo',
    repository,
    '--json',
    'number,url,state,isDraft,headRefOid,headRefName,baseRefName,headRepository,headRepositoryOwner,isCrossRepository',
  ]);
  return normalizePullContext(payload);
}

function approvePendingDeployment(repository, runId, environmentIds, comment, runGhJsonFn) {
  const args = [
    'api',
    `repos/${repository}/actions/runs/${runId}/pending_deployments`,
    '--method',
    'POST',
    '-f',
    'state=approved',
    '-f',
    `comment=${comment}`,
  ];
  for (const environmentId of environmentIds) {
    args.push('-f', `environment_ids[]=${environmentId}`);
  }
  return runGhJsonFn(args);
}

async function loadOrEvaluateDecision({
  options,
  repository,
  runBrokerFn,
  readJsonFn,
  writeJsonFn,
}) {
  if (options.decisionPath) {
    const decisionPayload = readJsonFn(options.decisionPath);
    const resolvedPath = await writeJsonFn(options.decisionOutPath, decisionPayload);
    return {
      sourceMode: 'consume',
      brokerExitCode: null,
      decisionPath: resolvedPath,
      decision: normalizeDecision(decisionPayload, resolvedPath),
    };
  }

  const brokerArgs = ['tools/priority/validation-approval-broker.mjs', '--repo', repository];
  if (options.prNumber !== null) {
    brokerArgs.push('--pr', String(options.prNumber));
  }
  if (options.signalPath) {
    brokerArgs.push('--signal', options.signalPath);
  }
  if (options.attestationPath) {
    brokerArgs.push('--attestation', options.attestationPath);
  }
  if (options.deploymentDeterminismPath) {
    brokerArgs.push('--deployment-determinism', options.deploymentDeterminismPath);
  }
  if (options.pullFile) {
    brokerArgs.push('--pull-file', options.pullFile);
  }
  if (options.policyPath) {
    brokerArgs.push('--policy', options.policyPath);
  }
  if (options.requiredChecksPolicyPath) {
    brokerArgs.push('--required-checks-policy', options.requiredChecksPolicyPath);
  }
  brokerArgs.push(
    '--environment',
    options.environment,
    '--out',
    options.decisionOutPath,
  );

  const brokerResult = runBrokerFn(brokerArgs);
  if (brokerResult.error) {
    const message = brokerResult.error instanceof Error ? brokerResult.error.message : String(brokerResult.error);
    throw new Error(`Failed to invoke validation approval broker: ${message}`);
  }
  const decisionPayload = readJsonFn(options.decisionOutPath);
  return {
    sourceMode: 'evaluate',
    brokerExitCode: brokerResult.status ?? null,
    decisionPath: path.resolve(process.cwd(), options.decisionOutPath),
    decision: normalizeDecision(decisionPayload, path.resolve(process.cwd(), options.decisionOutPath)),
  };
}

export async function runValidationApprovalHelper({
  argv = process.argv,
  now = new Date(),
  readJsonFn = readJsonFile,
  writeJsonFn = writeJsonFile,
  runGhJsonFn = runGhJson,
  runBrokerFn = runBrokerSubprocess,
  appendStepSummaryFn = appendStepSummary,
} = {}) {
  let options = null;
  try {
    options = parseArgs(argv);
    if (options.help) {
      printUsage();
      return { exitCode: 0, report: null, reportPath: null, decisionPath: null };
    }
    if (!environmentAllowed(options.environment)) {
      throw new Error('Validation approval helper only supports the validation environment.');
    }

    const repository = resolveRepository(options);
    const decisionResult = await loadOrEvaluateDecision({
      options,
      repository,
      runBrokerFn,
      readJsonFn,
      writeJsonFn,
    });
    const targetRun = fetchTargetRun(repository, options.runId, runGhJsonFn);
    const pending = fetchPendingDeployments(repository, options.runId, options.environment, runGhJsonFn);
    const resolvedPrNumber = options.prNumber ?? decisionResult.decision.pullRequestNumber;
    const pullRequest = fetchPullRequest(repository, resolvedPrNumber, runGhJsonFn);
    const evaluation = evaluateHelperState({
      repository,
      requestedEnvironment: options.environment,
      targetRun,
      pending,
      pullRequest,
      decision: decisionResult.decision,
      approvalRequested: options.approve === true,
    });

    const approvalComment = resolveApprovalComment(options.comment, decisionResult.decision);
    let approvalPerformed = false;
    let approvalState = options.approve ? 'blocked' : 'not-requested';
    if (options.approve && evaluation.state === 'ready') {
      approvePendingDeployment(
        repository,
        options.runId,
        pending.matchingEnvironmentIds,
        approvalComment,
        runGhJsonFn,
      );
      approvalPerformed = true;
      approvalState = 'approved';
    } else if (!options.approve && evaluation.state === 'ready') {
      approvalState = 'ready-dry-run';
    }

    const report = buildReport({
      now,
      repository,
      sourceMode: decisionResult.sourceMode,
      decisionPath: decisionResult.decisionPath,
      decisionOutPath: path.resolve(process.cwd(), options.decisionOutPath),
      brokerExitCode: decisionResult.brokerExitCode,
      targetRun,
      pending,
      pullRequest: {
        number: pullRequest.number,
        url: pullRequest.url ?? decisionResult.decision.pullRequestUrl,
        state: pullRequest.state,
        isDraft: pullRequest.isDraft,
        headSha: pullRequest.headSha,
        headRefName: pullRequest.headRefName,
      },
      decision: {
        path: decisionResult.decision.path,
        state: evaluation.state === 'ready' ? decisionResult.decision.state : evaluation.state,
        ready: evaluation.state === 'ready',
        reasons: evaluation.reasons,
        summary: evaluation.summary,
        repository: decisionResult.decision.repository,
        environment: decisionResult.decision.environment,
        pullRequestNumber: decisionResult.decision.pullRequestNumber,
        pullRequestUrl: decisionResult.decision.pullRequestUrl,
        headSha: decisionResult.decision.headSha,
        trustTrusted: decisionResult.decision.trustTrusted,
        hasCurrentHeadReview: decisionResult.decision.hasCurrentHeadReview,
        staleReviewCount: decisionResult.decision.staleReviewCount,
        actionableCommentCount: decisionResult.decision.actionableCommentCount,
        unresolvedThreadCount: decisionResult.decision.unresolvedThreadCount,
        requiredChecksReady: decisionResult.decision.requiredChecksReady,
      },
      evaluationState: evaluation.state,
      approvalRequested: options.approve === true,
      approvalPerformed,
      approvalState,
      approvalComment,
    });

    const reportPath = await writeJsonFn(options.reportPath, report);
    await appendStepSummaryFn(options.stepSummaryPath, report);
    return {
      exitCode: report.status === 'pass' ? 0 : 1,
      report,
      reportPath,
      decisionPath: path.resolve(process.cwd(), options.decisionOutPath),
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const report = buildFailureReport(options ?? { environment: DEFAULT_ENVIRONMENT, approve: false }, now, message);
    const reportPath =
      options?.reportPath ? await writeJsonFn(options.reportPath, report) : null;
    if (options?.stepSummaryPath) {
      await appendStepSummaryFn(options.stepSummaryPath, report);
    }
    return {
      exitCode: 1,
      report,
      reportPath,
      decisionPath: options?.decisionOutPath ? path.resolve(process.cwd(), options.decisionOutPath) : null,
    };
  }
}

const entryPointPath = process.argv[1] ? path.resolve(process.argv[1]) : null;

if (entryPointPath && fileURLToPath(import.meta.url) === entryPointPath) {
  const result = await runValidationApprovalHelper();
  if (result.reportPath) {
    console.log(`[validation-approval-helper] report: ${result.reportPath}`);
  }
  if (result.decisionPath) {
    console.log(`[validation-approval-helper] decision: ${result.decisionPath}`);
  }
  if (result.report) {
    console.log(
      `[validation-approval-helper] status=${result.report.status} decision=${result.report.decision.state} approval=${result.report.approval.state}`,
    );
  }
  process.exit(result.exitCode);
}

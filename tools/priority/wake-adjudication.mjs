#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { main as runDownstreamOnboarding } from './downstream-onboarding.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'issue', 'wake-adjudication.json');
export const DEFAULT_REVALIDATED_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'onboarding',
  'downstream-onboarding-revalidated.json'
);

const WARNING_ONLY_IDS = new Set(['protected-environments-configured', 'required-checks-visible']);

function printUsage() {
  console.log('Usage: node tools/priority/wake-adjudication.mjs --reported <path> [options]');
  console.log('');
  console.log('Options:');
  console.log('  --reported <path>              Reported downstream onboarding report to adjudicate (required).');
  console.log(`  --output <path>                Wake adjudication report path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log(
    `  --revalidated-output <path>    Where the live replay report should be written (default: ${DEFAULT_REVALIDATED_OUTPUT_PATH}).`
  );
  console.log('  --revalidated-report <path>    Use an existing revalidated report instead of replaying live.');
  console.log('  --branch <name>                Override the branch used for live replay.');
  console.log('  -h, --help                     Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    reportedPath: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    revalidatedOutputPath: DEFAULT_REVALIDATED_OUTPUT_PATH,
    revalidatedReportPath: null,
    revalidatedBranch: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (
      token === '--reported' ||
      token === '--output' ||
      token === '--revalidated-output' ||
      token === '--revalidated-report' ||
      token === '--branch'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--reported') options.reportedPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--revalidated-output') options.revalidatedOutputPath = next;
      if (token === '--revalidated-report') options.revalidatedReportPath = next;
      if (token === '--branch') options.revalidatedBranch = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !options.reportedPath) {
    throw new Error('Missing required option: --reported <path>.');
  }

  return options;
}

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function asOptional(value) {
  const normalized = normalizeText(value);
  return normalized.length > 0 ? normalized : null;
}

function resolvePath(repoRoot, candidate) {
  return path.resolve(repoRoot, candidate);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

function ensureDownstreamOnboardingReport(payload, filePath) {
  if (payload?.schema !== 'priority/downstream-onboarding-report@v1') {
    throw new Error(`Expected downstream onboarding report at ${filePath}.`);
  }
  return payload;
}

function summarizeChecklist(report, desiredStatus) {
  return Array.isArray(report?.checklist)
    ? report.checklist
        .filter((entry) => normalizeText(entry?.status) === desiredStatus)
        .map((entry) => ({
          id: normalizeText(entry?.id),
          reason: normalizeText(entry?.reason),
          required: entry?.required === true
        }))
        .filter((entry) => entry.id && entry.reason)
    : [];
}

function toObservation(reportPath, report, overrides = {}) {
  const requiredFailures = summarizeChecklist(report, 'fail')
    .filter((entry) => entry.required)
    .map((entry) => ({
      id: entry.id,
      reason: entry.reason
    }));
  const warnings = summarizeChecklist(report, 'warn').map((entry) => ({
    id: entry.id,
    reason: entry.reason
  }));
  return {
    path: reportPath,
    generatedAt: asOptional(report?.generatedAt),
    downstreamRepository: normalizeText(report?.downstreamRepository),
    targetBranch: normalizeText(report?.targetBranch),
    defaultBranch: asOptional(report?.repository?.defaultBranch),
    branchResolutionSource: asOptional(report?.branchResolution?.source) || asOptional(report?.repository?.branchResolutionSource),
    summaryStatus: normalizeText(report?.summary?.status) || 'fail',
    requiredFailCount: Number.isInteger(report?.summary?.requiredFailCount) ? report.summary.requiredFailCount : requiredFailures.length,
    warningCount: Number.isInteger(report?.summary?.warnCount) ? report.summary.warnCount : warnings.length,
    workflowReferenceCount: Number.isInteger(report?.workflowDiscovery?.referencedWorkflowCount)
      ? report.workflowDiscovery.referencedWorkflowCount
      : Array.isArray(report?.workflowReferences)
        ? report.workflowReferences.length
        : 0,
    successfulRunCount: Number.isInteger(report?.runs?.successful) ? report.runs.successful : 0,
    requiredFailures,
    warnings,
    ...overrides
  };
}

function createAuthorityTier(tier, observation, source) {
  return {
    tier,
    repository: normalizeText(observation?.downstreamRepository),
    targetBranch: normalizeText(observation?.targetBranch),
    defaultBranch: asOptional(observation?.defaultBranch),
    generatedAt: asOptional(observation?.generatedAt),
    branchResolutionSource: asOptional(observation?.branchResolutionSource),
    source
  };
}

function createAuthorityModel(reported, revalidated) {
  const contradictionFields = [];
  if (normalizeText(reported?.targetBranch) !== normalizeText(revalidated?.targetBranch)) {
    contradictionFields.push('targetBranch');
  }
  if (normalizeText(reported?.defaultBranch) !== normalizeText(revalidated?.defaultBranch)) {
    contradictionFields.push('defaultBranch');
  }

  let authoritativeSource = 'live-replay';
  if (normalizeText(revalidated?.branchResolutionSource) === 'live-repository-default-branch') {
    authoritativeSource = 'live-repository-default-branch';
  } else if (normalizeText(revalidated?.branchResolutionSource) === 'explicit-override') {
    authoritativeSource = 'explicit-override';
  } else if (normalizeText(revalidated?.branchResolutionSource) === 'fallback-default-branch') {
    authoritativeSource = 'fallback-default-branch';
  }

  return {
    reported: createAuthorityTier('reported', reported, 'reported-artifact'),
    revalidated: createAuthorityTier('revalidated', revalidated, 'live-replay'),
    authoritative: createAuthorityTier('authoritative', revalidated, authoritativeSource),
    routing: {
      preferredTier: 'authoritative',
      selectedTier: 'authoritative',
      contradictionFields,
      blockedLowerTier: contradictionFields.length > 0,
      reason:
        contradictionFields.length > 0
          ? 'Higher-authority live replay contradicted the reported wake, so routing must ignore lower-authority branch truth.'
          : 'Higher-authority live replay confirmed the wake, so routing may proceed from authoritative evidence.'
    }
  };
}

function uniqueIds(entries) {
  return [...new Set((Array.isArray(entries) ? entries : []).map((entry) => normalizeText(entry?.id)).filter(Boolean))];
}

function diffIds(beforeEntries, afterEntries) {
  const before = new Set(uniqueIds(beforeEntries));
  const after = new Set(uniqueIds(afterEntries));
  return {
    cleared: [...before].filter((entry) => !after.has(entry)),
    persistent: [...before].filter((entry) => after.has(entry)),
    added: [...after].filter((entry) => !before.has(entry))
  };
}

function isPermissionGapReason(reason) {
  const normalized = normalizeText(reason).toLowerCase();
  return (
    normalized.includes('api-401') ||
    normalized.includes('api-403') ||
    normalized.includes('api-404') ||
    normalized.includes('unavailable') ||
    normalized.includes('visibility')
  );
}

function classifyWake({ reported, revalidated, reportedReport }) {
  const targetBranchChanged = normalizeText(reported.targetBranch) !== normalizeText(revalidated.targetBranch);
  const defaultBranchChanged = normalizeText(reported.defaultBranch) !== normalizeText(revalidated.defaultBranch);
  const liveWarnings = Array.isArray(revalidated.warnings) ? revalidated.warnings : [];
  const liveWarningIds = uniqueIds(liveWarnings);
  const warningsOnly = liveWarnings.length > 0 && liveWarningIds.every((entry) => WARNING_ONLY_IDS.has(entry));
  const liveRequiredFailures = Array.isArray(revalidated.requiredFailures) ? revalidated.requiredFailures : [];
  const livePermissionOnly =
    liveRequiredFailures.length > 0 && liveRequiredFailures.every((entry) => isPermissionGapReason(entry.reason));

  if (reported.requiredFailCount > 0 && revalidated.requiredFailCount === 0) {
    if (targetBranchChanged || defaultBranchChanged) {
      return {
        classification: 'branch-target-drift',
        status: 'suppressed',
        suppressIssueInjection: true,
        suppressDownstreamIssueInjection: true,
        suppressTemplateIssueInjection: true,
        recommendedOwnerRepository: normalizeText(reportedReport?.upstreamRepository) || null,
        nextAction: 'reconcile-downstream-branch-target-provenance',
        reason:
          'The reported wake failed against stale downstream branch truth, while live replay resolved a different current branch and cleared all required blockers.'
      };
    }
    if (warningsOnly || revalidated.summaryStatus === 'warn') {
      return {
        classification: 'environment-only',
        status: 'monitoring',
        suppressIssueInjection: true,
        suppressDownstreamIssueInjection: true,
        suppressTemplateIssueInjection: true,
        recommendedOwnerRepository: normalizeText(revalidated.downstreamRepository) || null,
        nextAction: 'monitor-warning-only-downstream-surface',
        reason:
          'Required blockers cleared on live replay; only warning-level environment or branch-protection gaps remain.'
      };
    }
    return {
      classification: 'stale-artifact',
      status: 'suppressed',
      suppressIssueInjection: true,
      suppressDownstreamIssueInjection: true,
      suppressTemplateIssueInjection: true,
      recommendedOwnerRepository: null,
      nextAction: 'suppress-stale-reported-wake',
      reason:
        'The reported failure no longer reproduces on live replay and should not reopen work by itself.'
    };
  }

  if (revalidated.requiredFailCount > 0) {
    if (livePermissionOnly) {
      return {
        classification: 'platform-permission-gap',
        status: 'actionable',
        suppressIssueInjection: false,
        suppressDownstreamIssueInjection: true,
        suppressTemplateIssueInjection: true,
        recommendedOwnerRepository: normalizeText(reportedReport?.upstreamRepository) || null,
        nextAction: 'route-platform-governance-gap',
        reason:
          'Live replay still fails, but only through platform or permission visibility gaps rather than a downstream consumer defect.'
      };
    }
    return {
      classification: 'live-defect',
      status: 'actionable',
      suppressIssueInjection: false,
      suppressDownstreamIssueInjection: false,
      suppressTemplateIssueInjection: false,
      recommendedOwnerRepository: normalizeText(revalidated.downstreamRepository) || null,
      nextAction: 'route-live-downstream-defect',
      reason:
        'The reported failure survives live replay and still blocks required downstream onboarding checks.'
    };
  }

  return {
    classification: warningsOnly ? 'environment-only' : 'stale-artifact',
    status: warningsOnly ? 'monitoring' : 'suppressed',
    suppressIssueInjection: true,
    suppressDownstreamIssueInjection: true,
    suppressTemplateIssueInjection: true,
    recommendedOwnerRepository: warningsOnly ? normalizeText(revalidated.downstreamRepository) || null : null,
    nextAction: warningsOnly ? 'monitor-warning-only-downstream-surface' : 'suppress-stale-reported-wake',
    reason: warningsOnly
      ? 'Live replay reports warning-only downstream conditions with no required blockers.'
      : 'Live replay cleared the reported failure.'
  };
}

export function buildRevalidationArgv(reportedReport, options) {
  const argv = [
    'node',
    'downstream-onboarding.mjs',
    '--repo',
    normalizeText(reportedReport?.downstreamRepository),
    '--upstream-repo',
    normalizeText(reportedReport?.upstreamRepository),
    '--action-repo',
    normalizeText(reportedReport?.actionRepository),
    '--output',
    normalizeText(options.revalidatedOutputPath)
  ];
  const branchOverride = asOptional(options.revalidatedBranch);
  if (branchOverride) {
    argv.push('--branch', branchOverride);
  }
  return argv;
}

export async function runWakeAdjudication(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const reportedPath = resolvePath(repoRoot, options.reportedPath);
  const outputPath = resolvePath(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);
  const revalidatedOutputPath = resolvePath(repoRoot, options.revalidatedOutputPath || DEFAULT_REVALIDATED_OUTPUT_PATH);
  const revalidatedReportPath = options.revalidatedReportPath
    ? resolvePath(repoRoot, options.revalidatedReportPath)
    : revalidatedOutputPath;

  const reportedReport = ensureDownstreamOnboardingReport(readJson(reportedPath), reportedPath);

  let revalidatedExitCode = null;
  let reran = false;
  if (!options.revalidatedReportPath) {
    reran = true;
    const argv = buildRevalidationArgv(reportedReport, {
      ...options,
      revalidatedOutputPath
    });
    const runFn = deps.runDownstreamOnboardingFn || runDownstreamOnboarding;
    revalidatedExitCode = await runFn(argv);
  }

  const revalidatedReport = ensureDownstreamOnboardingReport(readJson(revalidatedReportPath), revalidatedReportPath);
  const reported = toObservation(reportedPath, reportedReport);
  const revalidated = toObservation(revalidatedReportPath, revalidatedReport, {
    reran,
    exitCode: revalidatedExitCode
  });
  const failureDiff = diffIds(reported.requiredFailures, revalidated.requiredFailures);
  const summary = classifyWake({ reported, revalidated, reportedReport });
  const authority = createAuthorityModel(reported, revalidated);

  const report = {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: new Date().toISOString(),
    wakeKind: 'downstream-onboarding',
    reported,
    revalidated,
    authority,
    delta: {
      targetBranchChanged: normalizeText(reported.targetBranch) !== normalizeText(revalidated.targetBranch),
      defaultBranchChanged: normalizeText(reported.defaultBranch) !== normalizeText(revalidated.defaultBranch),
      workflowReferenceCountDelta: revalidated.workflowReferenceCount - reported.workflowReferenceCount,
      successfulRunCountDelta: revalidated.successfulRunCount - reported.successfulRunCount,
      reportedRequiredFailureIds: uniqueIds(reported.requiredFailures),
      revalidatedRequiredFailureIds: uniqueIds(revalidated.requiredFailures),
      clearedRequiredFailureIds: failureDiff.cleared,
      persistentRequiredFailureIds: failureDiff.persistent,
      newRequiredFailureIds: failureDiff.added
    },
    summary
  };

  writeJson(outputPath, report);
  console.log(
    `[wake-adjudication] wrote ${outputPath} (${report.summary.classification}, action=${report.summary.nextAction})`
  );
  return { report, outputPath, revalidatedReportPath };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  await runWakeAdjudication(options);
  return 0;
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

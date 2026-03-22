#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { appendDecisionLedgerEntry, DEFAULT_LEDGER_PATH } from './decision-ledger.mjs';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'monitoring-work-injection.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'issue', 'monitoring-work-injection.json');
export const DEFAULT_QUEUE_EMPTY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'no-standing-priority.json'
);
export const DEFAULT_MONITORING_MODE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'monitoring-mode.json'
);
export const DEFAULT_HOST_SIGNAL_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'runtime',
  'daemon-host-signal.json'
);
export const DEFAULT_WAKE_ADJUDICATION_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'wake-adjudication.json'
);
export const DEFAULT_WAKE_WORK_SYNTHESIS_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'wake-work-synthesis.json'
);
export const DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'capital',
  'wake-investment-accounting.json'
);
export const DEFAULT_DECISION_LEDGER_PATH = DEFAULT_LEDGER_PATH;

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function readOptionalJson(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function ensureWakeAdjudicationReport(payload, filePath) {
  if (payload?.schema !== 'priority/wake-adjudication-report@v1') {
    throw new Error(`Expected wake adjudication report at ${filePath}.`);
  }
  return payload;
}

function ensureWakeWorkSynthesisReport(payload, filePath) {
  if (payload?.schema !== 'priority/wake-work-synthesis-report@v1') {
    throw new Error(`Expected wake work synthesis report at ${filePath}.`);
  }
  return payload;
}

function ensureWakeInvestmentAccountingReport(payload, filePath) {
  if (payload?.schema !== 'priority/wake-investment-accounting-report@v1') {
    throw new Error(`Expected wake investment accounting report at ${filePath}.`);
  }
  return payload;
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function computeMonitoringDecisionFingerprint({
  repository,
  wakeEvidence,
  selectedRule,
  resolvedDedupeMarker,
  summary
}) {
  const hash = createHash('sha256');
  hash.update(
    JSON.stringify({
      repository: asOptional(repository),
      classification: wakeEvidence?.classification || null,
      decision: wakeEvidence?.decision || null,
      status: wakeEvidence?.status || null,
      nextAction: wakeEvidence?.nextAction || null,
      recommendedOwnerRepository: wakeEvidence?.recommendedOwnerRepository || null,
      accountingBucket: wakeEvidence?.accountingBucket || null,
      accountingStatus: wakeEvidence?.accountingStatus || null,
      paybackStatus: wakeEvidence?.paybackStatus || null,
      selectedRuleId: asOptional(selectedRule?.id),
      resolvedDedupeMarker: asOptional(resolvedDedupeMarker),
      summaryStatus: asOptional(summary?.status),
      triggerId: asOptional(summary?.triggerId),
      issueNumber: Number.isInteger(summary?.issueNumber) ? summary.issueNumber : null
    })
  );
  return `monitoring-work-injection:${hash.digest('hex')}`;
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) {
    return null;
  }
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo, execSyncFn = execSync) {
  if (asOptional(explicitRepo)?.includes('/')) {
    return asOptional(explicitRepo);
  }
  if (asOptional(process.env.GITHUB_REPOSITORY)?.includes('/')) {
    return asOptional(process.env.GITHUB_REPOSITORY);
  }
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSyncFn(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) {
        return slug;
      }
    } catch {
      // ignore missing remotes
    }
  }
  return null;
}

function runGhJson(args, spawnSyncFn = spawnSync) {
  const result = spawnSyncFn('gh', args, {
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.error || result.status !== 0) {
    const message =
      asOptional(result.stderr) ||
      asOptional(result.stdout) ||
      result.error?.message ||
      `gh ${args.join(' ')} failed`;
    throw new Error(message);
  }
  return JSON.parse(result.stdout || 'null');
}

function runGh(args, spawnSyncFn = spawnSync) {
  const result = spawnSyncFn('gh', args, {
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.error || result.status !== 0) {
    const message =
      asOptional(result.stderr) ||
      asOptional(result.stdout) ||
      result.error?.message ||
      `gh ${args.join(' ')} failed`;
    throw new Error(message);
  }
  return result;
}

function extractIssueNumberFromUrl(url) {
  const match = asOptional(url)?.match(/\/issues\/(\d+)(?:$|[?#/])/i);
  return match ? Number.parseInt(match[1], 10) : null;
}

function normalizeIssue(issue) {
  return {
    number: Number.isInteger(issue?.number) ? issue.number : null,
    title: asOptional(issue?.title),
    url: asOptional(issue?.url),
    body: asOptional(issue?.body) || '',
    labels: Array.isArray(issue?.labels)
      ? issue.labels
          .map((entry) => asOptional(entry?.name ?? entry))
          .filter(Boolean)
      : []
  };
}

function normalizeRule(rule) {
  const labels = Array.isArray(rule?.issue?.labels)
    ? rule.issue.labels.map((entry) => asOptional(entry)).filter(Boolean)
    : [];
  return {
    id: asOptional(rule?.id),
    when: {
      hostSignalStatus: asOptional(rule?.when?.hostSignalStatus),
      wakeClassification: asOptional(rule?.when?.wakeClassification),
      wakeDecision: asOptional(rule?.when?.wakeDecision),
      wakeStatus: asOptional(rule?.when?.wakeStatus),
      recommendedOwnerRepository: asOptional(rule?.when?.recommendedOwnerRepository),
      wakeAccountingBucket: asOptional(rule?.when?.wakeAccountingBucket),
      wakeAccountingStatus: asOptional(rule?.when?.wakeAccountingStatus)
    },
    issue: {
      title: asOptional(rule?.issue?.title),
      dedupeMarker: asOptional(rule?.issue?.dedupeMarker),
      dedupeDimension: asOptional(rule?.issue?.dedupeDimension),
      labels,
      bodyLines: Array.isArray(rule?.issue?.bodyLines)
        ? rule.issue.bodyLines.map((entry) => String(entry))
        : []
    },
    requireMonitoringMode: asOptional(rule?.requireMonitoringMode)
  };
}

function loadPolicy(policyPath) {
  const policy = JSON.parse(fs.readFileSync(path.resolve(policyPath), 'utf8'));
  if (policy?.schema !== 'priority/monitoring-work-injection-policy@v1') {
    throw new Error(`Unsupported monitoring work injection policy schema in ${policyPath}`);
  }
  return {
    ...policy,
    requireQueueEmpty: policy.requireQueueEmpty !== false,
    rules: Array.isArray(policy.rules) ? policy.rules.map(normalizeRule) : []
  };
}

function sanitizeMarkerSegment(value) {
  const normalized = asOptional(value);
  if (!normalized) {
    return 'unknown';
  }
  return normalized.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'unknown';
}

function createWakeEvidence(wakeAdjudication, wakeWorkSynthesis, wakeInvestmentAccounting) {
  return {
    classification:
      asOptional(wakeAdjudication?.summary?.classification) || asOptional(wakeWorkSynthesis?.wake?.classification),
    decision: asOptional(wakeWorkSynthesis?.summary?.decision),
    status: asOptional(wakeWorkSynthesis?.summary?.status),
    nextAction: asOptional(wakeAdjudication?.summary?.nextAction) || asOptional(wakeWorkSynthesis?.wake?.nextAction),
    recommendedOwnerRepository:
      asOptional(wakeWorkSynthesis?.summary?.recommendedOwnerRepository) ||
      asOptional(wakeAdjudication?.summary?.recommendedOwnerRepository),
    reason: asOptional(wakeWorkSynthesis?.summary?.reason) || asOptional(wakeAdjudication?.summary?.reason),
    suppressIssueInjection:
      wakeAdjudication?.summary?.suppressIssueInjection === true ||
      wakeWorkSynthesis?.wake?.suppressIssueInjection === true,
    suppressTemplateIssueInjection:
      wakeAdjudication?.summary?.suppressTemplateIssueInjection === true ||
      wakeWorkSynthesis?.wake?.suppressTemplateIssueInjection === true,
    suppressDownstreamIssueInjection:
      wakeAdjudication?.summary?.suppressDownstreamIssueInjection === true ||
      wakeWorkSynthesis?.wake?.suppressDownstreamIssueInjection === true,
    accountingBucket: asOptional(wakeInvestmentAccounting?.summary?.accountingBucket),
    accountingStatus: asOptional(wakeInvestmentAccounting?.summary?.status),
    paybackStatus: asOptional(wakeInvestmentAccounting?.summary?.paybackStatus)
  };
}

function resolveDedupeMarker(rule, wakeEvidence) {
  const baseMarker = asOptional(rule?.issue?.dedupeMarker);
  if (!baseMarker) {
    return null;
  }
  const dimension = asOptional(rule?.issue?.dedupeDimension);
  if (!dimension) {
    return baseMarker;
  }
  let suffix = null;
  if (dimension === 'classification') {
    suffix = wakeEvidence.classification;
  } else if (dimension === 'decision') {
    suffix = wakeEvidence.decision;
  } else if (dimension === 'next-action') {
    suffix = wakeEvidence.nextAction;
  } else if (dimension === 'recommended-owner-repository') {
    suffix = wakeEvidence.recommendedOwnerRepository;
  } else if (dimension === 'accounting-bucket') {
    suffix = wakeEvidence.accountingBucket;
  }
  return `${baseMarker}:${sanitizeMarkerSegment(suffix)}`;
}

function ruleMatches(rule, monitoringMode, hostSignal, wakeEvidence) {
  if (!rule?.id || !rule.issue?.title || !rule.issue?.dedupeMarker) {
    return false;
  }
  if (rule.requireMonitoringMode && asOptional(monitoringMode?.summary?.status) !== rule.requireMonitoringMode) {
    return false;
  }
  if (rule.when.hostSignalStatus && asOptional(hostSignal?.status) !== rule.when.hostSignalStatus) {
    return false;
  }
  if (rule.when.wakeClassification && wakeEvidence.classification !== rule.when.wakeClassification) {
    return false;
  }
  if (rule.when.wakeDecision && wakeEvidence.decision !== rule.when.wakeDecision) {
    return false;
  }
  if (rule.when.wakeStatus && wakeEvidence.status !== rule.when.wakeStatus) {
    return false;
  }
  if (
    rule.when.recommendedOwnerRepository &&
    wakeEvidence.recommendedOwnerRepository !== rule.when.recommendedOwnerRepository
  ) {
    return false;
  }
  if (rule.when.wakeAccountingBucket && wakeEvidence.accountingBucket !== rule.when.wakeAccountingBucket) {
    return false;
  }
  if (rule.when.wakeAccountingStatus && wakeEvidence.accountingStatus !== rule.when.wakeAccountingStatus) {
    return false;
  }
  return true;
}

function renderIssueBody(rule, monitoringMode, hostSignal, queueEmptyReport, wakeEvidence, resolvedDedupeMarker) {
  const lines = [...(Array.isArray(rule.issue.bodyLines) ? rule.issue.bodyLines : [])];
  lines.push('');
  lines.push(`- monitoring-mode: ${asOptional(monitoringMode?.summary?.status) || 'unknown'}`);
  lines.push(`- future-agent-action: ${asOptional(monitoringMode?.summary?.futureAgentAction) || 'unknown'}`);
  lines.push(`- queue-state: ${asOptional(queueEmptyReport?.reason) || 'unknown'}`);
  lines.push(`- host-signal-status: ${asOptional(hostSignal?.status) || 'unknown'}`);
  lines.push(`- host-signal-provider: ${asOptional(hostSignal?.provider) || 'unknown'}`);
  lines.push(`- wake-classification: ${wakeEvidence.classification || 'unknown'}`);
  lines.push(`- wake-decision: ${wakeEvidence.decision || 'unknown'}`);
  lines.push(`- wake-status: ${wakeEvidence.status || 'unknown'}`);
  lines.push(`- wake-next-action: ${wakeEvidence.nextAction || 'unknown'}`);
  lines.push(`- wake-owner-repository: ${wakeEvidence.recommendedOwnerRepository || 'unknown'}`);
  lines.push(`- wake-accounting-bucket: ${wakeEvidence.accountingBucket || 'unknown'}`);
  lines.push(`- wake-accounting-status: ${wakeEvidence.accountingStatus || 'unknown'}`);
  lines.push(`- wake-payback-status: ${wakeEvidence.paybackStatus || 'unknown'}`);
  if (wakeEvidence.reason) {
    lines.push(`- wake-reason: ${wakeEvidence.reason}`);
  }
  lines.push('');
  lines.push(`<!-- ${resolvedDedupeMarker} -->`);
  return `${lines.join('\n').trim()}\n`;
}

function findExistingInjectedIssue(openIssues, resolvedDedupeMarker) {
  return openIssues.find((issue) => issue.body.includes(`<!-- ${resolvedDedupeMarker} -->`));
}

function buildFallbackSummary(wakeEvidence, repository) {
  if (wakeEvidence.status === 'suppressed' || wakeEvidence.decision === 'suppress') {
    return {
      status: 'suppressed-wake',
      injected: false,
      reason:
        wakeEvidence.reason ||
        'The monitoring wake was suppressed after live revalidation, so no new standing issue should be injected.',
      issueNumber: null,
      issueUrl: null,
      triggerId: null
    };
  }
  if (wakeEvidence.status === 'monitoring' || wakeEvidence.decision === 'monitor') {
    return {
      status: 'monitoring-only',
      injected: false,
      reason:
        wakeEvidence.reason ||
        'The monitoring wake remains observational only, so no standing issue should be injected.',
      issueNumber: null,
      issueUrl: null,
      triggerId: null
    };
  }
  if (
    wakeEvidence.status === 'actionable' &&
    wakeEvidence.recommendedOwnerRepository &&
    repository &&
    wakeEvidence.recommendedOwnerRepository !== repository
  ) {
    return {
      status: 'external-route',
      injected: false,
      reason:
        wakeEvidence.reason ||
        `The monitoring wake is actionable but belongs to ${wakeEvidence.recommendedOwnerRepository}, not ${repository}.`,
      issueNumber: null,
      issueUrl: null,
      triggerId: null
    };
  }
  if (wakeEvidence.status === 'actionable' && (wakeEvidence.recommendedOwnerRepository === repository || !wakeEvidence.recommendedOwnerRepository)) {
    return {
      status: 'policy-blocked',
      injected: false,
      reason:
        wakeEvidence.reason ||
        'The monitoring wake is actionable for this repository but no policy rule mapped it to injected work.',
      issueNumber: null,
      issueUrl: null,
      triggerId: null
    };
  }
  return {
    status: 'no-trigger',
    injected: false,
    reason: 'No policy-approved monitoring wake condition requires issue injection.',
    issueNumber: null,
    issueUrl: null,
    triggerId: null
  };
}

function ensureIssueLabels(repository, issueNumber, desiredLabels, currentLabels, runGhFn) {
  const missing = desiredLabels.filter((label) => !currentLabels.includes(label));
  if (missing.length === 0) {
    return [];
  }
  const helperCallsExecuted = [];
  for (const label of missing) {
    runGhFn(['issue', 'edit', String(issueNumber), '--repo', repository, '--add-label', label]);
    helperCallsExecuted.push(`gh issue edit ${issueNumber} --repo ${repository} --add-label ${label}`);
  }
  return helperCallsExecuted;
}

function createIssue(repository, rule, body, runGhFn) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-'));
  const bodyPath = path.join(tmpDir, 'issue-body.md');
  fs.writeFileSync(bodyPath, body, 'utf8');
  try {
    const args = ['issue', 'create', '--repo', repository, '--title', rule.issue.title, '--body-file', bodyPath];
    for (const label of rule.issue.labels) {
      args.push('--label', label);
    }
    const result = runGhFn(args);
    const issueUrl = asOptional(result.stdout)
      ?.split(/\r?\n/)
      .map((entry) => asOptional(entry))
      .filter(Boolean)
      .pop();
    return {
      issueUrl,
      issueNumber: extractIssueNumberFromUrl(issueUrl),
      helperCallsExecuted: [`gh issue create --repo ${repository} --title \"${rule.issue.title}\" --body-file <temp>`]
    };
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

export async function runMonitoringWorkInjection(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const policyPath = path.resolve(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);
  const ledgerPath = path.resolve(repoRoot, options.ledgerPath || DEFAULT_DECISION_LEDGER_PATH);
  const queueEmptyReportPath = path.resolve(repoRoot, options.queueEmptyReportPath || DEFAULT_QUEUE_EMPTY_REPORT_PATH);
  const monitoringModePath = path.resolve(repoRoot, options.monitoringModePath || DEFAULT_MONITORING_MODE_PATH);
  const hostSignalPath = path.resolve(repoRoot, options.hostSignalPath || DEFAULT_HOST_SIGNAL_PATH);
  const wakeAdjudicationPath = path.resolve(repoRoot, options.wakeAdjudicationPath || DEFAULT_WAKE_ADJUDICATION_PATH);
  const wakeWorkSynthesisPath = path.resolve(repoRoot, options.wakeWorkSynthesisPath || DEFAULT_WAKE_WORK_SYNTHESIS_PATH);
  const wakeInvestmentAccountingPath = path.resolve(
    repoRoot,
    options.wakeInvestmentAccountingPath || DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH
  );
  const apply = options.apply !== false;
  const policy = loadPolicy(policyPath);
  const repository =
    asOptional(options.repository) ||
    resolveRepoSlug(options.repository, deps.execSyncFn || execSync) ||
    policy.compareRepository;
  const queueEmptyReport = readOptionalJson(queueEmptyReportPath);
  const monitoringMode = readOptionalJson(monitoringModePath);
  const hostSignal = readOptionalJson(hostSignalPath);
  const rawWakeAdjudication = readOptionalJson(wakeAdjudicationPath);
  const rawWakeWorkSynthesis = readOptionalJson(wakeWorkSynthesisPath);
  const rawWakeInvestmentAccounting = readOptionalJson(wakeInvestmentAccountingPath);
  const wakeAdjudication = rawWakeAdjudication ? ensureWakeAdjudicationReport(rawWakeAdjudication, wakeAdjudicationPath) : null;
  const wakeWorkSynthesis = rawWakeWorkSynthesis
    ? ensureWakeWorkSynthesisReport(rawWakeWorkSynthesis, wakeWorkSynthesisPath)
    : null;
  const wakeInvestmentAccounting = rawWakeInvestmentAccounting
    ? ensureWakeInvestmentAccountingReport(rawWakeInvestmentAccounting, wakeInvestmentAccountingPath)
    : null;
  const wakeEvidence = createWakeEvidence(wakeAdjudication, wakeWorkSynthesis, wakeInvestmentAccounting);
  const helperCallsExecuted = [];
  const appendLedger = options.appendLedger !== false;
  const queueEligible =
    !policy.requireQueueEmpty ||
    (queueEmptyReport?.schema === 'standing-priority/no-standing@v1' && queueEmptyReport?.reason === 'queue-empty');

  let selectedRule = null;
  if (queueEligible && repository) {
    selectedRule = policy.rules.find((rule) => ruleMatches(rule, monitoringMode, hostSignal, wakeEvidence)) ?? null;
  }
  const resolvedDedupeMarker = selectedRule ? resolveDedupeMarker(selectedRule, wakeEvidence) : null;

  let summary = buildFallbackSummary(wakeEvidence, repository);
  if (!queueEligible) {
    summary = {
      status: 'no-trigger',
      injected: false,
      reason: 'No policy-approved monitoring wake condition requires issue injection.',
      issueNumber: null,
      issueUrl: null,
      triggerId: null
    };
  }

  if (selectedRule) {
    const runGhJsonFn = deps.runGhJsonFn ?? ((args) => runGhJson(args, deps.spawnSyncFn));
    const runGhFn = deps.runGhFn ?? ((args) => runGh(args, deps.spawnSyncFn));
    const openIssues = (runGhJsonFn([
      'issue',
      'list',
      '--repo',
      repository,
      '--state',
      'open',
      '--limit',
      '200',
      '--json',
      'number,title,url,body,labels'
    ]) || [])
      .map(normalizeIssue);
    const existingIssue = findExistingInjectedIssue(openIssues, resolvedDedupeMarker);
    if (existingIssue) {
      helperCallsExecuted.push(
        ...ensureIssueLabels(repository, existingIssue.number, selectedRule.issue.labels, existingIssue.labels, runGhFn)
      );
      summary = {
        status: 'existing-issue',
        injected: true,
        reason: `Monitoring wake condition ${selectedRule.id} already maps to open issue #${existingIssue.number}.`,
        issueNumber: existingIssue.number,
        issueUrl: existingIssue.url,
        triggerId: selectedRule.id
      };
    } else if (!apply) {
      summary = {
        status: 'would-create-issue',
        injected: false,
        reason: `Monitoring wake condition ${selectedRule.id} would create a standing issue when apply mode is enabled.`,
        issueNumber: null,
        issueUrl: null,
        triggerId: selectedRule.id
      };
    } else {
      const body = renderIssueBody(selectedRule, monitoringMode, hostSignal, queueEmptyReport, wakeEvidence, resolvedDedupeMarker);
      const createResult = createIssue(repository, selectedRule, body, runGhFn);
      helperCallsExecuted.push(...createResult.helperCallsExecuted);
      summary = {
        status: 'created-issue',
        injected: true,
        reason: `Monitoring wake condition ${selectedRule.id} created standing issue #${createResult.issueNumber}.`,
        issueNumber: createResult.issueNumber,
        issueUrl: createResult.issueUrl,
        triggerId: selectedRule.id
      };
    }
  }

  const eventFingerprint = computeMonitoringDecisionFingerprint({
    repository,
    wakeEvidence,
    selectedRule,
    resolvedDedupeMarker,
    summary
  });
  const report = {
    schema: 'priority/monitoring-work-injection-report@v1',
    generatedAt: new Date().toISOString(),
    repository,
    event: {
      category: 'monitoring-work-injection',
      fingerprint: eventFingerprint,
      dedupeMarker: resolvedDedupeMarker,
      triggerId: asOptional(summary.triggerId),
      terminalStatus: asOptional(summary.status),
      issueNumber: Number.isInteger(summary.issueNumber) ? summary.issueNumber : null
    },
    policy: {
      path: path.relative(repoRoot, policyPath).replace(/\\/g, '/'),
      requireQueueEmpty: policy.requireQueueEmpty,
      ruleIds: policy.rules.map((rule) => rule.id)
    },
    inputs: {
      queueEmptyReportPath: path.relative(repoRoot, queueEmptyReportPath).replace(/\\/g, '/'),
      monitoringModePath: path.relative(repoRoot, monitoringModePath).replace(/\\/g, '/'),
      hostSignalPath: path.relative(repoRoot, hostSignalPath).replace(/\\/g, '/'),
      wakeAdjudicationPath: path.relative(repoRoot, wakeAdjudicationPath).replace(/\\/g, '/'),
      wakeWorkSynthesisPath: path.relative(repoRoot, wakeWorkSynthesisPath).replace(/\\/g, '/'),
      wakeInvestmentAccountingPath: path.relative(repoRoot, wakeInvestmentAccountingPath).replace(/\\/g, '/')
    },
    evidence: {
      queueEmpty: queueEmptyReport
        ? {
            schema: asOptional(queueEmptyReport.schema),
            reason: asOptional(queueEmptyReport.reason),
            openIssueCount: Number.isInteger(queueEmptyReport.openIssueCount) ? queueEmptyReport.openIssueCount : null
          }
        : null,
      monitoringMode: monitoringMode
        ? {
            status: asOptional(monitoringMode.summary?.status),
            futureAgentAction: asOptional(monitoringMode.summary?.futureAgentAction),
            wakeConditionCount: Number.isInteger(monitoringMode.summary?.wakeConditionCount)
              ? monitoringMode.summary.wakeConditionCount
              : null
          }
        : null,
      hostSignal: hostSignal
        ? {
            status: asOptional(hostSignal.status),
            provider: asOptional(hostSignal.provider),
            daemonFingerprint: asOptional(hostSignal.daemonFingerprint)
          }
        : null,
      wake: wakeAdjudication || wakeWorkSynthesis || wakeInvestmentAccounting
        ? {
            classification: wakeEvidence.classification,
            decision: wakeEvidence.decision,
            status: wakeEvidence.status,
            nextAction: wakeEvidence.nextAction,
            recommendedOwnerRepository: wakeEvidence.recommendedOwnerRepository,
            suppressIssueInjection: wakeEvidence.suppressIssueInjection,
            suppressTemplateIssueInjection: wakeEvidence.suppressTemplateIssueInjection,
            suppressDownstreamIssueInjection: wakeEvidence.suppressDownstreamIssueInjection,
            accountingBucket: wakeEvidence.accountingBucket,
            accountingStatus: wakeEvidence.accountingStatus,
            paybackStatus: wakeEvidence.paybackStatus
          }
        : null
    },
    selectedRule: selectedRule
      ? {
          id: selectedRule.id,
          requireMonitoringMode: selectedRule.requireMonitoringMode,
          issueTitle: selectedRule.issue.title,
          dedupeMarker: selectedRule.issue.dedupeMarker,
          resolvedDedupeMarker,
          labels: selectedRule.issue.labels,
          conditions: {
            hostSignalStatus: selectedRule.when.hostSignalStatus,
            wakeClassification: selectedRule.when.wakeClassification,
            wakeDecision: selectedRule.when.wakeDecision,
            wakeStatus: selectedRule.when.wakeStatus,
            recommendedOwnerRepository: selectedRule.when.recommendedOwnerRepository,
            wakeAccountingBucket: selectedRule.when.wakeAccountingBucket,
            wakeAccountingStatus: selectedRule.when.wakeAccountingStatus
          }
        }
      : null,
    decisionLedger: {
      path: path.relative(repoRoot, ledgerPath).replace(/\\/g, '/'),
      appended: false,
      source: 'monitoring-work-injection',
      sequence: null,
      decisionDigest: null,
      fingerprint: eventFingerprint,
      error: null
    },
    summary,
    helperCallsExecuted
  };

  const writtenPath = writeJson(outputPath, report);
  if (appendLedger) {
    try {
      const appendFn = deps.appendDecisionLedgerEntryFn ?? appendDecisionLedgerEntry;
      const appended = await appendFn({
        decisionPath: writtenPath,
        ledgerPath,
        source: 'monitoring-work-injection'
      });
      report.decisionLedger = {
        path: path.relative(repoRoot, appended.ledgerPath).replace(/\\/g, '/'),
        appended: true,
        source: 'monitoring-work-injection',
        sequence: Number.isInteger(appended.entry?.sequence) ? appended.entry.sequence : null,
        decisionDigest: asOptional(appended.entry?.decisionDigest),
        fingerprint: asOptional(appended.entry?.fingerprint) || eventFingerprint,
        error: null
      };
      writeJson(outputPath, report);
    } catch (error) {
      report.decisionLedger = {
        ...report.decisionLedger,
        error: error?.message || String(error)
      };
      writeJson(outputPath, report);
    }
  }

  return {
    report,
    outputPath: writtenPath,
    ledgerPath: report.decisionLedger.appended ? path.resolve(repoRoot, report.decisionLedger.path) : null,
    issueNumber: summary.issueNumber,
    issueUrl: summary.issueUrl
  };
}

export function parseArgs(argv = process.argv) {
  const args = {
    repoRoot: DEFAULT_REPO_ROOT,
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    queueEmptyReportPath: DEFAULT_QUEUE_EMPTY_REPORT_PATH,
    monitoringModePath: DEFAULT_MONITORING_MODE_PATH,
    hostSignalPath: DEFAULT_HOST_SIGNAL_PATH,
    wakeAdjudicationPath: DEFAULT_WAKE_ADJUDICATION_PATH,
    wakeWorkSynthesisPath: DEFAULT_WAKE_WORK_SYNTHESIS_PATH,
    wakeInvestmentAccountingPath: DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH,
    ledgerPath: DEFAULT_DECISION_LEDGER_PATH,
    repository: null,
    apply: true,
    appendLedger: true
  };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--repo-root') {
      args.repoRoot = argv[++index];
    } else if (arg === '--policy') {
      args.policyPath = argv[++index];
    } else if (arg === '--output') {
      args.outputPath = argv[++index];
    } else if (arg === '--queue-empty-report') {
      args.queueEmptyReportPath = argv[++index];
    } else if (arg === '--monitoring-mode') {
      args.monitoringModePath = argv[++index];
    } else if (arg === '--host-signal') {
      args.hostSignalPath = argv[++index];
    } else if (arg === '--wake-adjudication') {
      args.wakeAdjudicationPath = argv[++index];
    } else if (arg === '--wake-work-synthesis') {
      args.wakeWorkSynthesisPath = argv[++index];
    } else if (arg === '--wake-investment-accounting') {
      args.wakeInvestmentAccountingPath = argv[++index];
    } else if (arg === '--repo') {
      args.repository = argv[++index];
    } else if (arg === '--dry-run') {
      args.apply = false;
    } else if (arg === '--apply') {
      args.apply = true;
    } else if (arg === '--ledger') {
      args.ledgerPath = argv[++index];
    } else if (arg === '--skip-ledger') {
      args.appendLedger = false;
    } else if (arg === '--help' || arg === '-h') {
      args.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    console.log(
      'Usage: node tools/priority/monitoring-work-injection.mjs [--dry-run] [--repo <owner/repo>] [--wake-adjudication <path>] [--wake-work-synthesis <path>] [--wake-investment-accounting <path>] [--ledger <path>] [--skip-ledger]'
    );
    return 0;
  }
  const { report, outputPath } = await runMonitoringWorkInjection(args);
  console.log(
    `[monitoring-work-injection] wrote ${outputPath} (${report.summary.status}, trigger=${report.summary.triggerId || 'none'})`
  );
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await main(process.argv);
    process.exit(exitCode);
  } catch (error) {
    console.error(`[monitoring-work-injection] ${error.message}`);
    process.exit(1);
  }
}

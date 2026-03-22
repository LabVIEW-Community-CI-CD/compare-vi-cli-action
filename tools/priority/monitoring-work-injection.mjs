#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

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

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
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
      hostSignalStatus: asOptional(rule?.when?.hostSignalStatus)
    },
    issue: {
      title: asOptional(rule?.issue?.title),
      dedupeMarker: asOptional(rule?.issue?.dedupeMarker),
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

function ruleMatches(rule, monitoringMode, hostSignal) {
  if (!rule?.id || !rule.issue?.title || !rule.issue?.dedupeMarker) {
    return false;
  }
  if (rule.requireMonitoringMode && asOptional(monitoringMode?.summary?.status) !== rule.requireMonitoringMode) {
    return false;
  }
  if (rule.when.hostSignalStatus && asOptional(hostSignal?.status) !== rule.when.hostSignalStatus) {
    return false;
  }
  return true;
}

function renderIssueBody(rule, monitoringMode, hostSignal, queueEmptyReport) {
  const lines = [...(Array.isArray(rule.issue.bodyLines) ? rule.issue.bodyLines : [])];
  lines.push('');
  lines.push(`- monitoring-mode: ${asOptional(monitoringMode?.summary?.status) || 'unknown'}`);
  lines.push(`- future-agent-action: ${asOptional(monitoringMode?.summary?.futureAgentAction) || 'unknown'}`);
  lines.push(`- queue-state: ${asOptional(queueEmptyReport?.reason) || 'unknown'}`);
  lines.push(`- host-signal-status: ${asOptional(hostSignal?.status) || 'unknown'}`);
  lines.push(`- host-signal-provider: ${asOptional(hostSignal?.provider) || 'unknown'}`);
  lines.push('');
  lines.push(`<!-- ${rule.issue.dedupeMarker} -->`);
  return `${lines.join('\n').trim()}\n`;
}

function findExistingInjectedIssue(openIssues, rule) {
  return openIssues.find((issue) => issue.body.includes(`<!-- ${rule.issue.dedupeMarker} -->`));
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
  const queueEmptyReportPath = path.resolve(repoRoot, options.queueEmptyReportPath || DEFAULT_QUEUE_EMPTY_REPORT_PATH);
  const monitoringModePath = path.resolve(repoRoot, options.monitoringModePath || DEFAULT_MONITORING_MODE_PATH);
  const hostSignalPath = path.resolve(repoRoot, options.hostSignalPath || DEFAULT_HOST_SIGNAL_PATH);
  const apply = options.apply !== false;
  const policy = loadPolicy(policyPath);
  const repository =
    asOptional(options.repository) ||
    resolveRepoSlug(options.repository, deps.execSyncFn || execSync) ||
    policy.compareRepository;
  const queueEmptyReport = readOptionalJson(queueEmptyReportPath);
  const monitoringMode = readOptionalJson(monitoringModePath);
  const hostSignal = readOptionalJson(hostSignalPath);
  const helperCallsExecuted = [];

  let selectedRule = null;
  if (
    (!policy.requireQueueEmpty ||
      (queueEmptyReport?.schema === 'standing-priority/no-standing@v1' && queueEmptyReport?.reason === 'queue-empty')) &&
    repository
  ) {
    selectedRule = policy.rules.find((rule) => ruleMatches(rule, monitoringMode, hostSignal)) ?? null;
  }

  let summary = {
    status: 'no-trigger',
    injected: false,
    reason: 'No policy-approved monitoring wake condition requires issue injection.',
    issueNumber: null,
    issueUrl: null,
    triggerId: null
  };

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
    const existingIssue = findExistingInjectedIssue(openIssues, selectedRule);
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
      const body = renderIssueBody(selectedRule, monitoringMode, hostSignal, queueEmptyReport);
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

  const report = {
    schema: 'priority/monitoring-work-injection-report@v1',
    generatedAt: new Date().toISOString(),
    repository,
    policy: {
      path: path.relative(repoRoot, policyPath).replace(/\\/g, '/'),
      requireQueueEmpty: policy.requireQueueEmpty,
      ruleIds: policy.rules.map((rule) => rule.id)
    },
    inputs: {
      queueEmptyReportPath: path.relative(repoRoot, queueEmptyReportPath).replace(/\\/g, '/'),
      monitoringModePath: path.relative(repoRoot, monitoringModePath).replace(/\\/g, '/'),
      hostSignalPath: path.relative(repoRoot, hostSignalPath).replace(/\\/g, '/')
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
        : null
    },
    selectedRule: selectedRule
      ? {
          id: selectedRule.id,
          requireMonitoringMode: selectedRule.requireMonitoringMode,
          issueTitle: selectedRule.issue.title,
          dedupeMarker: selectedRule.issue.dedupeMarker,
          labels: selectedRule.issue.labels,
          conditions: {
            hostSignalStatus: selectedRule.when.hostSignalStatus
          }
        }
      : null,
    summary,
    helperCallsExecuted
  };

  const writtenPath = writeJson(outputPath, report);
  return {
    report,
    outputPath: writtenPath,
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
    repository: null,
    apply: true
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
    } else if (arg === '--repo') {
      args.repository = argv[++index];
    } else if (arg === '--dry-run') {
      args.apply = false;
    } else if (arg === '--apply') {
      args.apply = true;
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
    console.log('Usage: node tools/priority/monitoring-work-injection.mjs [--dry-run] [--repo <owner/repo>]');
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

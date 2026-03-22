#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'template-monitoring.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'handoff', 'monitoring-mode.json');
export const DEFAULT_QUEUE_EMPTY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'no-standing-priority.json'
);
export const DEFAULT_CONTINUITY_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'continuity-summary.json'
);
export const DEFAULT_TEMPLATE_PIVOT_GATE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-pivot-gate-report.json'
);

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
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

function toRelative(targetPath) {
  return path.relative(process.cwd(), path.resolve(targetPath)).replace(/\\/g, '/');
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

function createWakeCondition(code, triggered, message) {
  return { code, triggered, message };
}

function normalizeStatus(result) {
  if (!result) {
    return 'unknown';
  }
  return result === 'pass' || result === 'fail' ? result : 'unknown';
}

function runGhJson(args) {
  const result = spawnSync('gh', args, {
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

function probeOpenIssues(repository, runGhJsonFn) {
  try {
    const issues = runGhJsonFn(['issue', 'list', '-R', repository, '--state', 'open', '--limit', '200', '--json', 'number']);
    const count = Array.isArray(issues) ? issues.length : 0;
    return {
      status: 'pass',
      count
    };
  } catch {
    return {
      status: 'unknown',
      count: null
    };
  }
}

function probeBranchSha(repository, branch, runGhJsonFn) {
  try {
    const response = runGhJsonFn(['api', `repos/${repository}/branches/${branch}`]);
    return {
      status: 'pass',
      headSha: asOptional(response?.commit?.sha)
    };
  } catch {
    return {
      status: 'unknown',
      headSha: null
    };
  }
}

function probeSupportedRun(repository, proofPolicy, branch, runGhJsonFn) {
  if (!proofPolicy) {
    return null;
  }
  try {
    const runs = runGhJsonFn([
      'run',
      'list',
      '-R',
      repository,
      '--workflow',
      proofPolicy.workflowFile,
      '--branch',
      branch,
      '--event',
      proofPolicy.event,
      '--limit',
      '20',
      '--json',
      'status,conclusion,url,workflowName,headBranch,headSha,createdAt,updatedAt,databaseId'
    ]);
    const latestRun = Array.isArray(runs) ? runs[0] ?? null : null;
    if (!latestRun) {
      return {
        status: 'fail',
        workflowFile: proofPolicy.workflowFile,
        event: proofPolicy.event,
        requiredConclusion: proofPolicy.requiredConclusion,
        runUrl: null,
        headSha: null,
        conclusion: null
      };
    }
    const success = latestRun.conclusion === proofPolicy.requiredConclusion;
    return {
      status: success ? 'pass' : 'fail',
      workflowFile: proofPolicy.workflowFile,
      event: proofPolicy.event,
      requiredConclusion: proofPolicy.requiredConclusion,
      runUrl: asOptional(latestRun.url),
      headSha: asOptional(latestRun.headSha),
      conclusion: asOptional(latestRun.conclusion)
    };
  } catch {
    return {
      status: 'unknown',
      workflowFile: proofPolicy.workflowFile,
      event: proofPolicy.event,
      requiredConclusion: proofPolicy.requiredConclusion,
      runUrl: null,
      headSha: null,
      conclusion: null
    };
  }
}

function evaluateRepositoryMonitor(entry, canonicalHeadSha, runGhJsonFn) {
  const openIssuesProbe = probeOpenIssues(entry.repository, runGhJsonFn);
  const openIssuesStatus =
    openIssuesProbe.status === 'pass' && openIssuesProbe.count === entry.openIssuesMustEqual
      ? 'pass'
      : openIssuesProbe.status === 'pass'
        ? 'fail'
        : 'unknown';
  const branchProbe = probeBranchSha(entry.repository, entry.branch, runGhJsonFn);
  const branchAlignment = entry.mustMatchCanonicalBranch
    ? {
        status:
          branchProbe.status === 'pass' && canonicalHeadSha && branchProbe.headSha
            ? branchProbe.headSha === canonicalHeadSha
              ? 'pass'
              : 'fail'
            : 'unknown',
        branch: entry.branch,
        headSha: branchProbe.headSha,
        canonicalHeadSha: canonicalHeadSha ?? null
      }
    : null;
  const supportedProof = probeSupportedRun(entry.repository, entry.supportedProof ?? null, entry.branch, runGhJsonFn);
  const statuses = [
    openIssuesStatus,
    branchAlignment?.status ?? 'pass',
    supportedProof?.status ?? 'pass'
  ].map(normalizeStatus);
  const monitoringStatus = statuses.includes('fail')
    ? 'fail'
    : statuses.includes('unknown')
      ? 'unknown'
      : 'pass';

  return {
    role: entry.role,
    repository: entry.repository,
    monitoringStatus,
    openIssues: {
      status: openIssuesStatus,
      count: openIssuesProbe.count
    },
    branchAlignment,
    supportedProof
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    queueEmptyReportPath: DEFAULT_QUEUE_EMPTY_REPORT_PATH,
    continuitySummaryPath: DEFAULT_CONTINUITY_SUMMARY_PATH,
    templatePivotGatePath: DEFAULT_TEMPLATE_PIVOT_GATE_PATH,
    repo: null,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--policy', 'policyPath'],
    ['--output', 'outputPath'],
    ['--queue-empty-report', 'queueEmptyReportPath'],
    ['--continuity-summary', 'continuitySummaryPath'],
    ['--template-pivot-gate', 'templatePivotGatePath'],
    ['--repo', 'repo']
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (stringFlags.has(token)) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      options[stringFlags.get(token)] = next;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  [
    'Usage: node tools/priority/handoff-monitoring-mode.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>          Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --policy <path>             Monitoring policy path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --queue-empty-report <path> Queue-empty report (default: ${DEFAULT_QUEUE_EMPTY_REPORT_PATH}).`,
    `  --continuity-summary <path> Continuity summary (default: ${DEFAULT_CONTINUITY_SUMMARY_PATH}).`,
    `  --template-pivot-gate <path> Template pivot gate report (default: ${DEFAULT_TEMPLATE_PIVOT_GATE_PATH}).`,
    `  --output <path>             Monitoring receipt output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  --repo <owner/repo>         Explicit compare repository slug.',
    '  -h, --help                  Show help.'
  ].forEach((line) => console.log(line));
}

export async function runHandoffMonitoringMode(
  options,
  {
    now = new Date(),
    resolveRepoSlugFn = resolveRepoSlug,
    readJsonFn = readJson,
    readOptionalJsonFn = readOptionalJson,
    writeJsonFn = writeJson,
    runGhJsonFn = runGhJson
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const repository = resolveRepoSlugFn(options.repo) || null;
  const policyPath = path.resolve(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  const policy = readJsonFn(policyPath);
  if (policy?.schema !== 'priority/template-monitoring-policy@v1') {
    throw new Error('Template monitoring policy schema mismatch.');
  }

  const queueEmptyReportPath = path.resolve(repoRoot, options.queueEmptyReportPath || DEFAULT_QUEUE_EMPTY_REPORT_PATH);
  const continuitySummaryPath = path.resolve(repoRoot, options.continuitySummaryPath || DEFAULT_CONTINUITY_SUMMARY_PATH);
  const templatePivotGatePath = path.resolve(repoRoot, options.templatePivotGatePath || DEFAULT_TEMPLATE_PIVOT_GATE_PATH);

  const queueEmpty = readOptionalJsonFn(queueEmptyReportPath);
  const continuity = readOptionalJsonFn(continuitySummaryPath);
  const templatePivotGate = readOptionalJsonFn(templatePivotGatePath);

  const queueEmptyReady =
    queueEmpty?.schema === 'standing-priority/no-standing@v1' && queueEmpty?.reason === 'queue-empty';
  const continuityReady =
    continuity?.schema === 'priority/continuity-telemetry-report@v1' &&
    continuity?.status === 'maintained' &&
    continuity?.continuity?.turnBoundary?.status === 'safe-idle' &&
    continuity?.continuity?.turnBoundary?.operatorPromptRequiredToResume === false;
  const pivotReady =
    templatePivotGate?.schema === 'priority/template-pivot-gate@v1' &&
    templatePivotGate?.summary?.status === 'ready' &&
    templatePivotGate?.summary?.readyForFutureAgentPivot === true;

  const canonicalEntry = policy.canonicalTemplate;
  const canonicalBranchProbe = probeBranchSha(canonicalEntry.repository, canonicalEntry.branch, runGhJsonFn);
  const canonicalHeadSha = canonicalBranchProbe.headSha;
  const canonicalMonitor = evaluateRepositoryMonitor(canonicalEntry, canonicalHeadSha, runGhJsonFn);
  const forkMonitors = policy.consumerForks.map((entry) => evaluateRepositoryMonitor(entry, canonicalHeadSha, runGhJsonFn));
  const templateStatuses = [canonicalMonitor.monitoringStatus, ...forkMonitors.map((entry) => entry.monitoringStatus)];
  const templateMonitoringStatus = templateStatuses.includes('fail')
    ? 'fail'
    : templateStatuses.includes('unknown')
      ? 'unknown'
      : 'pass';

  const wakeConditions = [
    createWakeCondition(
      'compare-queue-not-empty',
      !queueEmptyReady,
      'Wake compare work only when the standing queue stops reporting queue-empty.'
    ),
    createWakeCondition(
      'compare-continuity-not-safe-idle',
      !continuityReady,
      'Wake compare work when continuity stops reporting maintained/safe-idle.'
    ),
    createWakeCondition(
      'compare-template-pivot-not-ready',
      !pivotReady,
      'Wake compare work when the template pivot gate is no longer ready.'
    ),
    createWakeCondition(
      'template-canonical-open-issues',
      canonicalMonitor.openIssues.status === 'fail',
      'Wake template work when the canonical template repository develops open issues.'
    ),
    createWakeCondition(
      'template-consumer-fork-drift',
      forkMonitors.some((entry) => entry.branchAlignment?.status === 'fail' || entry.openIssues.status === 'fail'),
      'Wake template work when a supported consumer fork drifts off canonical develop or accumulates open issues.'
    ),
    createWakeCondition(
      'template-supported-workflow-dispatch-regressed',
      forkMonitors.some((entry) => entry.supportedProof?.status === 'fail'),
      'Wake template work when a supported workflow_dispatch template-smoke proof regresses on a consumer fork.'
    )
  ];

  const compareReadyForMonitoring = queueEmptyReady && continuityReady && pivotReady;
  const triggeredWakeConditions = wakeConditions.filter((entry) => entry.triggered).map((entry) => entry.code);
  const futureAgentAction = !compareReadyForMonitoring
    ? 'stay-in-compare-monitoring'
    : triggeredWakeConditions.some((code) =>
        code === 'template-canonical-open-issues' ||
        code === 'template-consumer-fork-drift' ||
        code === 'template-supported-workflow-dispatch-regressed'
      )
      ? 'reopen-template-monitoring-work'
      : 'future-agent-may-pivot';

  const report = {
    schema: 'agent-handoff/monitoring-mode-v1',
    generatedAt: now.toISOString(),
    repository: repository ?? policy.compareRepository,
    policy: {
      path: toRelative(policyPath),
      compareRepository: policy.compareRepository,
      pivotTargetRepository: policy.pivotTargetRepository,
      wakeConditions: policy.wakeConditions
    },
    compare: {
      queueState: {
        reportPath: toRelative(queueEmptyReportPath),
        ready: queueEmptyReady,
        status: queueEmptyReady ? 'queue-empty' : 'not-queue-empty',
        detail: queueEmpty?.reason ?? null
      },
      continuity: {
        reportPath: toRelative(continuitySummaryPath),
        ready: continuityReady,
        status: continuity?.status ?? 'missing',
        detail: continuity?.continuity?.turnBoundary?.status ?? null
      },
      pivotGate: {
        reportPath: toRelative(templatePivotGatePath),
        ready: pivotReady,
        status: templatePivotGate?.summary?.status ?? 'missing',
        detail: templatePivotGate?.summary?.pivotDecision ?? null
      },
      readyForMonitoring: compareReadyForMonitoring
    },
    templateMonitoring: {
      status: templateMonitoringStatus,
      repositories: [canonicalMonitor, ...forkMonitors],
      unsupportedPaths: policy.unsupportedPaths.map((entry) => ({
        name: entry.name,
        status: 'unsupported',
        message: entry.message
      }))
    },
    wakeConditions,
    summary: {
      status: compareReadyForMonitoring ? 'active' : 'blocked',
      futureAgentAction,
      wakeConditionCount: triggeredWakeConditions.length,
      triggeredWakeConditions
    }
  };

  const outputPath = writeJsonFn(path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH), report);
  return { report, outputPath };
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[handoff-monitoring-mode] ${error.message}`);
    printHelp();
    return 1;
  }
  if (options.help) {
    printHelp();
    return 0;
  }
  try {
    const { report, outputPath } = await runHandoffMonitoringMode(options);
    console.log(
      `[handoff-monitoring-mode] wrote ${outputPath} (${report.summary.status}, action=${report.summary.futureAgentAction})`
    );
    return 0;
  } catch (error) {
    console.error(`[handoff-monitoring-mode] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  const exitCode = await main(process.argv);
  if (exitCode !== 0) {
    process.exit(exitCode);
  }
}

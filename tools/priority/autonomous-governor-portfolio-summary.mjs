#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const DEFAULT_COMPARE_GOVERNOR_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'autonomous-governor-summary.json'
);
export const DEFAULT_MONITORING_MODE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'monitoring-mode.json'
);
export const DEFAULT_REPO_GRAPH_TRUTH_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'downstream-repo-graph-truth.json'
);
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'autonomous-governor-portfolio-summary.json'
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

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function toRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
}

function ensureSchema(payload, filePath, schema) {
  if (payload?.schema !== schema) {
    throw new Error(`Expected ${schema} at ${filePath}.`);
  }
  return payload;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    compareGovernorSummaryPath: DEFAULT_COMPARE_GOVERNOR_SUMMARY_PATH,
    monitoringModePath: DEFAULT_MONITORING_MODE_PATH,
    repoGraphTruthPath: DEFAULT_REPO_GRAPH_TRUTH_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--compare-governor-summary', 'compareGovernorSummaryPath'],
    ['--monitoring-mode', 'monitoringModePath'],
    ['--repo-graph-truth', 'repoGraphTruthPath'],
    ['--output', 'outputPath']
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
    'Usage: node tools/priority/autonomous-governor-portfolio-summary.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>                  Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --compare-governor-summary <path>  Compare governor summary path (default: ${DEFAULT_COMPARE_GOVERNOR_SUMMARY_PATH}).`,
    `  --monitoring-mode <path>           Monitoring mode path (default: ${DEFAULT_MONITORING_MODE_PATH}).`,
    `  --repo-graph-truth <path>          Repo graph truth path (default: ${DEFAULT_REPO_GRAPH_TRUTH_PATH}).`,
    `  --output <path>                    Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  -h, --help                         Show help.'
  ].forEach((line) => console.log(line));
}

function createWakeConditionsByRepository(triggeredWakeConditions) {
  const triggered = new Set(Array.isArray(triggeredWakeConditions) ? triggeredWakeConditions : []);
  return {
    compare: [
      'compare-queue-not-empty',
      'compare-continuity-not-safe-idle',
      'compare-template-pivot-not-ready'
    ].filter((code) => triggered.has(code)),
    'canonical-template': ['template-canonical-open-issues', 'template-monitoring-unverified'].filter((code) =>
      triggered.has(code)
    ),
    'org-consumer-fork': ['template-consumer-fork-drift', 'template-supported-workflow-dispatch-regressed'].filter(
      (code) => triggered.has(code)
    ),
    'personal-consumer-fork': ['template-consumer-fork-drift', 'template-supported-workflow-dispatch-regressed'].filter(
      (code) => triggered.has(code)
    )
  };
}

function derivePortfolioMode(compareGovernorSummary, monitoringMode) {
  const compareMode = asOptional(compareGovernorSummary?.summary?.governorMode);
  const futureAgentAction = asOptional(monitoringMode?.summary?.futureAgentAction);

  if (compareMode === 'monitoring-active' && futureAgentAction === 'reopen-template-monitoring-work') {
    return 'template-work';
  }

  return compareMode || 'attention-required';
}

function deriveOwners(compareGovernorSummary, monitoringMode, portfolioMode) {
  const compareRepository =
    asOptional(compareGovernorSummary?.summary?.currentOwnerRepository) ||
    asOptional(monitoringMode?.policy?.compareRepository) ||
    asOptional(compareGovernorSummary?.repository);
  const pivotTargetRepository =
    asOptional(monitoringMode?.policy?.pivotTargetRepository) || asOptional(compareRepository);
  const futureAgentAction = asOptional(monitoringMode?.summary?.futureAgentAction);

  if (portfolioMode === 'template-work') {
    return {
      currentOwnerRepository: pivotTargetRepository,
      nextOwnerRepository: pivotTargetRepository,
      nextAction: 'reopen-template-monitoring-work',
      ownerDecisionSource: 'template-monitoring'
    };
  }

  if (portfolioMode === 'monitoring-active') {
    return {
      currentOwnerRepository: compareRepository,
      nextOwnerRepository: futureAgentAction === 'future-agent-may-pivot' ? pivotTargetRepository : compareRepository,
      nextAction: futureAgentAction || asOptional(compareGovernorSummary?.summary?.nextAction) || 'remain-in-monitoring',
      ownerDecisionSource: 'compare-monitoring-mode'
    };
  }

  return {
    currentOwnerRepository:
      asOptional(compareGovernorSummary?.summary?.currentOwnerRepository) || compareRepository,
    nextOwnerRepository: asOptional(compareGovernorSummary?.summary?.nextOwnerRepository) || compareRepository,
    nextAction: asOptional(compareGovernorSummary?.summary?.nextAction) || 'refresh-portfolio-inputs',
    ownerDecisionSource: 'compare-governor-summary'
  };
}

function normalizeMonitoringStatus(value) {
  if (value === 'pass' || value === 'fail' || value === 'unknown') {
    return value;
  }
  return 'unknown';
}

function deriveRepositoryEntries(repoGraphTruth, monitoringMode, compareGovernorSummary) {
  const monitoringRepositories = new Map(
    (monitoringMode?.templateMonitoring?.repositories || []).map((entry) => [entry.repository, entry])
  );
  const wakeConditionsByRepository = createWakeConditionsByRepository(monitoringMode?.summary?.triggeredWakeConditions);

  return (repoGraphTruth?.repositories || []).map((entry) => {
    const monitor = monitoringRepositories.get(entry.repository);
    const compareSummary =
      entry.id === 'compare'
        ? {
            queueState: asOptional(compareGovernorSummary?.summary?.queueState),
            continuityStatus: asOptional(compareGovernorSummary?.summary?.continuityStatus),
            monitoringStatus: asOptional(compareGovernorSummary?.summary?.monitoringStatus),
            futureAgentAction: asOptional(compareGovernorSummary?.summary?.futureAgentAction),
            governorMode: asOptional(compareGovernorSummary?.summary?.governorMode),
            nextAction: asOptional(compareGovernorSummary?.summary?.nextAction)
          }
        : null;

    return {
      id: entry.id,
      repository: entry.repository,
      kind: entry.kind,
      roleTruthStatus: asOptional(entry.status) || 'unknown',
      roleCount: Number.isInteger(entry?.roles?.length) ? entry.roles.length : 0,
      summary: {
        requiredMissingRoleCount: entry?.summary?.requiredMissingRoleCount ?? null,
        optionalMissingRoleCount: entry?.summary?.optionalMissingRoleCount ?? null,
        alignmentFailureCount: entry?.summary?.alignmentFailureCount ?? null,
        unknownRoleCount: entry?.summary?.unknownRoleCount ?? null
      },
      monitoring: monitor
        ? {
            status: normalizeMonitoringStatus(monitor.monitoringStatus),
            openIssuesStatus: asOptional(monitor?.openIssues?.status) || 'unknown',
            openIssueCount: Number.isInteger(monitor?.openIssues?.count) ? monitor.openIssues.count : null,
            branchAlignmentStatus: asOptional(monitor?.branchAlignment?.status),
            branchHeadSha: asOptional(monitor?.branchAlignment?.headSha),
            canonicalHeadSha: asOptional(monitor?.branchAlignment?.canonicalHeadSha),
            supportedProofStatus: asOptional(monitor?.supportedProof?.status),
            supportedProofRunUrl: asOptional(monitor?.supportedProof?.runUrl),
            supportedProofConclusion: asOptional(monitor?.supportedProof?.conclusion)
          }
        : null,
      compare: compareSummary,
      triggeredWakeConditions: wakeConditionsByRepository[entry.id] || []
    };
  });
}

function deriveTemplateMonitoringStatus(repositoryEntries) {
  const templateStatuses = repositoryEntries
    .filter((entry) => entry.id !== 'compare')
    .map((entry) => entry.monitoring?.status)
    .filter(Boolean);

  if (templateStatuses.includes('fail')) {
    return 'fail';
  }
  if (templateStatuses.includes('unknown')) {
    return 'unknown';
  }
  if (templateStatuses.length === 0) {
    return 'unknown';
  }
  return 'pass';
}

function deriveSupportedProofStatus(repositoryEntries) {
  const proofStatuses = repositoryEntries
    .filter((entry) => entry.monitoring?.supportedProofStatus)
    .map((entry) => entry.monitoring.supportedProofStatus);

  if (proofStatuses.includes('fail')) {
    return 'fail';
  }
  if (proofStatuses.includes('unknown')) {
    return 'unknown';
  }
  if (proofStatuses.length === 0) {
    return 'unknown';
  }
  return 'pass';
}

function buildReport({
  repoRoot,
  compareGovernorSummaryPath,
  compareGovernorSummary,
  monitoringModePath,
  monitoringMode,
  repoGraphTruthPath,
  repoGraphTruth,
  now
}) {
  const portfolioMode = derivePortfolioMode(compareGovernorSummary, monitoringMode);
  const ownerDecision = deriveOwners(compareGovernorSummary, monitoringMode, portfolioMode);
  const repositoryEntries = deriveRepositoryEntries(repoGraphTruth, monitoringMode, compareGovernorSummary);
  const templateMonitoringStatus = deriveTemplateMonitoringStatus(repositoryEntries);
  const supportedProofStatus = deriveSupportedProofStatus(repositoryEntries);
  const triggeredWakeConditions = Array.isArray(monitoringMode?.summary?.triggeredWakeConditions)
    ? monitoringMode.summary.triggeredWakeConditions
    : [];

  return {
    schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
    generatedAt: now.toISOString(),
    repository: asOptional(compareGovernorSummary?.repository) || asOptional(monitoringMode?.repository),
    inputs: {
      compareGovernorSummaryPath: toRelative(repoRoot, compareGovernorSummaryPath),
      monitoringModePath: toRelative(repoRoot, monitoringModePath),
      repoGraphTruthPath: toRelative(repoRoot, repoGraphTruthPath)
    },
    compare: {
      repository:
        asOptional(compareGovernorSummary?.repository) || asOptional(monitoringMode?.policy?.compareRepository),
      queueState: asOptional(compareGovernorSummary?.summary?.queueState),
      continuityStatus: asOptional(compareGovernorSummary?.summary?.continuityStatus),
      monitoringStatus: asOptional(compareGovernorSummary?.summary?.monitoringStatus),
      futureAgentAction: asOptional(compareGovernorSummary?.summary?.futureAgentAction),
      governorMode: asOptional(compareGovernorSummary?.summary?.governorMode),
      nextAction: asOptional(compareGovernorSummary?.summary?.nextAction)
    },
    portfolio: {
      repositoryCount: repositoryEntries.length,
      repositories: repositoryEntries,
      unsupportedPaths: Array.isArray(monitoringMode?.templateMonitoring?.unsupportedPaths)
        ? monitoringMode.templateMonitoring.unsupportedPaths.map((entry) => ({
            name: asOptional(entry?.name),
            status: asOptional(entry?.status) || 'unsupported',
            message: asOptional(entry?.message)
          }))
        : []
    },
    summary: {
      status: portfolioMode === 'monitoring-active' ? 'monitoring' : 'active',
      governorMode: portfolioMode,
      currentOwnerRepository: ownerDecision.currentOwnerRepository,
      nextOwnerRepository: ownerDecision.nextOwnerRepository,
      nextAction: ownerDecision.nextAction,
      ownerDecisionSource: ownerDecision.ownerDecisionSource,
      templateMonitoringStatus,
      supportedProofStatus,
      repoGraphStatus: asOptional(repoGraphTruth?.summary?.status),
      portfolioWakeConditionCount: triggeredWakeConditions.length,
      triggeredWakeConditions
    }
  };
}

export async function runAutonomousGovernorPortfolioSummary(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const compareGovernorSummaryPath = path.resolve(
    repoRoot,
    options.compareGovernorSummaryPath || DEFAULT_COMPARE_GOVERNOR_SUMMARY_PATH
  );
  const monitoringModePath = path.resolve(repoRoot, options.monitoringModePath || DEFAULT_MONITORING_MODE_PATH);
  const repoGraphTruthPath = path.resolve(repoRoot, options.repoGraphTruthPath || DEFAULT_REPO_GRAPH_TRUTH_PATH);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);

  const readJsonFn = deps.readJsonFn || readJson;
  const writeJsonFn = deps.writeJsonFn || writeJson;
  const now = deps.now || new Date();

  const compareGovernorSummary = ensureSchema(
    readJsonFn(compareGovernorSummaryPath),
    compareGovernorSummaryPath,
    'priority/autonomous-governor-summary-report@v1'
  );
  const monitoringMode = ensureSchema(
    readJsonFn(monitoringModePath),
    monitoringModePath,
    'agent-handoff/monitoring-mode-v1'
  );
  const repoGraphTruth = ensureSchema(
    readJsonFn(repoGraphTruthPath),
    repoGraphTruthPath,
    'priority/downstream-repo-graph-truth@v1'
  );

  const report = buildReport({
    repoRoot,
    compareGovernorSummaryPath,
    compareGovernorSummary,
    monitoringModePath,
    monitoringMode,
    repoGraphTruthPath,
    repoGraphTruth,
    now
  });

  const writtenPath = writeJsonFn(outputPath, report);
  return { report, outputPath: writtenPath };
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[autonomous-governor-portfolio-summary] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runAutonomousGovernorPortfolioSummary(options);
    console.log(
      `[autonomous-governor-portfolio-summary] wrote ${outputPath} (${report.summary.governorMode}, next=${report.summary.nextAction})`
    );
    return 0;
  } catch (error) {
    console.error(`[autonomous-governor-portfolio-summary] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && modulePath === invokedPath) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

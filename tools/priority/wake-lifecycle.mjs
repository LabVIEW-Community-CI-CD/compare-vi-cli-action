#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

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
export const DEFAULT_MONITORING_WORK_INJECTION_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'monitoring-work-injection.json'
);
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'wake-lifecycle.json'
);

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
    wakeAdjudicationPath: DEFAULT_WAKE_ADJUDICATION_PATH,
    wakeWorkSynthesisPath: DEFAULT_WAKE_WORK_SYNTHESIS_PATH,
    wakeInvestmentAccountingPath: DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH,
    monitoringWorkInjectionPath: DEFAULT_MONITORING_WORK_INJECTION_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--wake-adjudication', 'wakeAdjudicationPath'],
    ['--wake-work-synthesis', 'wakeWorkSynthesisPath'],
    ['--wake-investment-accounting', 'wakeInvestmentAccountingPath'],
    ['--monitoring-work-injection', 'monitoringWorkInjectionPath'],
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
    'Usage: node tools/priority/wake-lifecycle.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>                 Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --wake-adjudication <path>        Wake adjudication report path (default: ${DEFAULT_WAKE_ADJUDICATION_PATH}).`,
    `  --wake-work-synthesis <path>      Wake work synthesis report path (default: ${DEFAULT_WAKE_WORK_SYNTHESIS_PATH}).`,
    `  --wake-investment-accounting <path> Wake investment accounting report path (default: ${DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH}).`,
    `  --monitoring-work-injection <path> Monitoring work injection report path (default: ${DEFAULT_MONITORING_WORK_INJECTION_PATH}).`,
    `  --output <path>                   Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  -h, --help                        Show help.'
  ].forEach((line) => console.log(line));
}

function createTransition(stage, status, reason) {
  return {
    stage,
    status,
    reason: normalizeText(reason)
  };
}

function determineTerminalState(wakeWorkSynthesis, monitoringWorkInjection) {
  const decision = asOptional(wakeWorkSynthesis?.summary?.decision);
  const monitoringStatus = asOptional(monitoringWorkInjection?.summary?.status);

  if (monitoringStatus === 'suppressed-wake') {
    return 'suppressed';
  }
  if (monitoringStatus === 'monitoring-only') {
    return 'monitoring';
  }
  if (monitoringStatus === 'external-route') {
    if (decision === 'template-work' || decision === 'consumer-proving-drift') {
      return 'template-work';
    }
    return 'external-route';
  }
  if (monitoringStatus === 'no-trigger') {
    return 'retired';
  }
  if (monitoringStatus === 'created-issue' || monitoringStatus === 'existing-issue' || monitoringStatus === 'would-create-issue') {
    if (decision === 'template-work' || decision === 'consumer-proving-drift') {
      return 'template-work';
    }
    return 'compare-work';
  }
  if (decision === 'suppress') {
    return 'suppressed';
  }
  if (decision === 'monitor') {
    return 'monitoring';
  }
  if (decision === 'template-work' || decision === 'consumer-proving-drift') {
    return 'template-work';
  }
  if (decision === 'compare-governance-work' || decision === 'investment-work') {
    return 'compare-work';
  }
  return 'retired';
}

function buildLifecycleReport({
  repoRoot,
  wakeAdjudicationPath,
  wakeAdjudication,
  wakeWorkSynthesisPath,
  wakeWorkSynthesis,
  wakeInvestmentAccountingPath,
  wakeInvestmentAccounting,
  monitoringWorkInjectionPath,
  monitoringWorkInjection,
  now
}) {
  const summaryClassification = asOptional(wakeAdjudication?.summary?.classification);
  const nextAction = asOptional(wakeAdjudication?.summary?.nextAction) || asOptional(wakeWorkSynthesis?.wake?.nextAction);
  const recommendedOwnerRepository =
    asOptional(wakeWorkSynthesis?.summary?.recommendedOwnerRepository) ||
    asOptional(wakeAdjudication?.summary?.recommendedOwnerRepository);
  const terminalState = determineTerminalState(wakeWorkSynthesis, monitoringWorkInjection);

  const transitions = [
    createTransition('reported', 'completed', 'Reported wake artifact loaded.'),
    createTransition('revalidated', 'completed', 'Revalidated wake artifact loaded.'),
    createTransition(
      'authoritative',
      wakeAdjudication?.authority?.routing?.blockedLowerTier === true ? 'contradicted' : 'completed',
      wakeAdjudication?.authority?.routing?.reason || 'Authoritative wake branch truth resolved.'
    ),
    createTransition(
      'synthesized',
      'completed',
      wakeWorkSynthesis?.summary?.reason || 'Wake work synthesis completed.'
    ),
    createTransition(
      'accounted',
      'completed',
      wakeInvestmentAccounting?.summary?.reason || 'Wake investment accounting completed.'
    ),
    createTransition(
      'monitoring-work-injection',
      'completed',
      monitoringWorkInjection?.summary?.reason || 'Monitoring work injection decision recorded.'
    )
  ];

  return {
    schema: 'priority/wake-lifecycle-report@v1',
    generatedAt: now.toISOString(),
    repository:
      asOptional(monitoringWorkInjection?.repository) ||
      asOptional(wakeWorkSynthesis?.repository) ||
      recommendedOwnerRepository,
    inputs: {
      wakeAdjudicationPath: toRelative(repoRoot, wakeAdjudicationPath),
      wakeWorkSynthesisPath: toRelative(repoRoot, wakeWorkSynthesisPath),
      wakeInvestmentAccountingPath: toRelative(repoRoot, wakeInvestmentAccountingPath),
      monitoringWorkInjectionPath: toRelative(repoRoot, monitoringWorkInjectionPath)
    },
    wake: {
      classification: summaryClassification,
      nextAction,
      recommendedOwnerRepository,
      reason: asOptional(wakeAdjudication?.summary?.reason) || asOptional(wakeWorkSynthesis?.summary?.reason)
    },
    stages: {
      reported: {
        state: 'reported',
        repository: asOptional(wakeAdjudication?.reported?.downstreamRepository),
        targetBranch: asOptional(wakeAdjudication?.reported?.targetBranch),
        defaultBranch: asOptional(wakeAdjudication?.reported?.defaultBranch),
        generatedAt: asOptional(wakeAdjudication?.reported?.generatedAt)
      },
      revalidated: {
        state: 'revalidated',
        repository: asOptional(wakeAdjudication?.revalidated?.downstreamRepository),
        targetBranch: asOptional(wakeAdjudication?.revalidated?.targetBranch),
        defaultBranch: asOptional(wakeAdjudication?.revalidated?.defaultBranch),
        generatedAt: asOptional(wakeAdjudication?.revalidated?.generatedAt)
      },
      authoritative: {
        state: 'authoritative',
        selectedTier: asOptional(wakeAdjudication?.authority?.routing?.selectedTier),
        repository: asOptional(wakeAdjudication?.authority?.authoritative?.repository),
        targetBranch: asOptional(wakeAdjudication?.authority?.authoritative?.targetBranch),
        defaultBranch: asOptional(wakeAdjudication?.authority?.authoritative?.defaultBranch),
        generatedAt: asOptional(wakeAdjudication?.authority?.authoritative?.generatedAt),
        source: asOptional(wakeAdjudication?.authority?.authoritative?.source),
        blockedLowerTier: wakeAdjudication?.authority?.routing?.blockedLowerTier === true,
        contradictionFields: Array.isArray(wakeAdjudication?.authority?.routing?.contradictionFields)
          ? wakeAdjudication.authority.routing.contradictionFields.map((entry) => normalizeText(entry)).filter(Boolean)
          : []
      },
      synthesized: {
        state: 'synthesized',
        decision: asOptional(wakeWorkSynthesis?.summary?.decision),
        status: asOptional(wakeWorkSynthesis?.summary?.status),
        workKind: asOptional(wakeWorkSynthesis?.summary?.workKind),
        recommendedOwnerRepository: asOptional(wakeWorkSynthesis?.summary?.recommendedOwnerRepository),
        routingAuthorityTier: asOptional(wakeWorkSynthesis?.summary?.routingAuthorityTier),
        blockedLowerTierEvidence: wakeWorkSynthesis?.summary?.blockedLowerTierEvidence === true,
        reason: asOptional(wakeWorkSynthesis?.summary?.reason)
      },
      accounted: {
        state: 'accounted',
        accountingBucket: asOptional(wakeInvestmentAccounting?.summary?.accountingBucket),
        status: asOptional(wakeInvestmentAccounting?.summary?.status),
        paybackStatus: asOptional(wakeInvestmentAccounting?.summary?.paybackStatus),
        currentObservedCostUsd:
          typeof wakeInvestmentAccounting?.summary?.currentObservedCostUsd === 'number'
            ? wakeInvestmentAccounting.summary.currentObservedCostUsd
            : null
      },
      monitoringWorkInjection: {
        state: 'monitoring-work-injection',
        status: asOptional(monitoringWorkInjection?.summary?.status),
        triggerId: asOptional(monitoringWorkInjection?.summary?.triggerId),
        issueNumber: Number.isInteger(monitoringWorkInjection?.summary?.issueNumber)
          ? monitoringWorkInjection.summary.issueNumber
          : null,
        issueUrl: asOptional(monitoringWorkInjection?.summary?.issueUrl),
        replayMatchedBy: asOptional(monitoringWorkInjection?.replay?.matchedBy),
        replayMatchedEntryCount: Number.isInteger(monitoringWorkInjection?.replay?.matchedEntryCount)
          ? monitoringWorkInjection.replay.matchedEntryCount
          : 0,
        replayAuthorityCompatible:
          monitoringWorkInjection?.replay?.authorityCompatible !== false,
        replayAuthorityMismatchReason: asOptional(monitoringWorkInjection?.replay?.authorityMismatchReason)
      }
    },
    transitions,
    summary: {
      currentStage: 'monitoring-work-injection',
      terminalState,
      wakeClassification: summaryClassification,
      decision: asOptional(wakeWorkSynthesis?.summary?.decision),
      monitoringStatus: asOptional(monitoringWorkInjection?.summary?.status),
      issueNumber: Number.isInteger(monitoringWorkInjection?.summary?.issueNumber)
        ? monitoringWorkInjection.summary.issueNumber
        : null,
      issueUrl: asOptional(monitoringWorkInjection?.summary?.issueUrl),
      authoritativeTier: asOptional(wakeAdjudication?.authority?.routing?.selectedTier),
      blockedLowerTierEvidence:
        wakeAdjudication?.authority?.routing?.blockedLowerTier === true ||
        wakeWorkSynthesis?.summary?.blockedLowerTierEvidence === true,
      replayMatched: Number.isInteger(monitoringWorkInjection?.replay?.matchedEntryCount)
        ? monitoringWorkInjection.replay.matchedEntryCount > 0
        : false,
      replayAuthorityCompatible:
        monitoringWorkInjection?.replay?.authorityCompatible !== false
    }
  };
}

export async function runWakeLifecycle(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const wakeAdjudicationPath = path.resolve(repoRoot, options.wakeAdjudicationPath || DEFAULT_WAKE_ADJUDICATION_PATH);
  const wakeWorkSynthesisPath = path.resolve(repoRoot, options.wakeWorkSynthesisPath || DEFAULT_WAKE_WORK_SYNTHESIS_PATH);
  const wakeInvestmentAccountingPath = path.resolve(
    repoRoot,
    options.wakeInvestmentAccountingPath || DEFAULT_WAKE_INVESTMENT_ACCOUNTING_PATH
  );
  const monitoringWorkInjectionPath = path.resolve(
    repoRoot,
    options.monitoringWorkInjectionPath || DEFAULT_MONITORING_WORK_INJECTION_PATH
  );
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);

  const readJsonFn = deps.readJsonFn || readJson;
  const writeJsonFn = deps.writeJsonFn || writeJson;
  const now = deps.now || new Date();

  const wakeAdjudication = ensureSchema(
    readJsonFn(wakeAdjudicationPath),
    wakeAdjudicationPath,
    'priority/wake-adjudication-report@v1'
  );
  const wakeWorkSynthesis = ensureSchema(
    readJsonFn(wakeWorkSynthesisPath),
    wakeWorkSynthesisPath,
    'priority/wake-work-synthesis-report@v1'
  );
  const wakeInvestmentAccounting = ensureSchema(
    readJsonFn(wakeInvestmentAccountingPath),
    wakeInvestmentAccountingPath,
    'priority/wake-investment-accounting-report@v1'
  );
  const monitoringWorkInjection = ensureSchema(
    readJsonFn(monitoringWorkInjectionPath),
    monitoringWorkInjectionPath,
    'priority/monitoring-work-injection-report@v1'
  );

  const report = buildLifecycleReport({
    repoRoot,
    wakeAdjudicationPath,
    wakeAdjudication,
    wakeWorkSynthesisPath,
    wakeWorkSynthesis,
    wakeInvestmentAccountingPath,
    wakeInvestmentAccounting,
    monitoringWorkInjectionPath,
    monitoringWorkInjection,
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
    console.error(`[wake-lifecycle] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runWakeLifecycle(options);
    console.log(
      `[wake-lifecycle] wrote ${outputPath} (${report.summary.terminalState}, stage=${report.summary.currentStage})`
    );
    return 0;
  } catch (error) {
    console.error(`[wake-lifecycle] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && modulePath === invokedPath) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

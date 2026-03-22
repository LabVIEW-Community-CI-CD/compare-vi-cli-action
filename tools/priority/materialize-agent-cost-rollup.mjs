#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runAgentCostTurn } from './agent-cost-turn.mjs';
import { runAgentCostRollup } from './agent-cost-rollup.mjs';

export const REPORT_SCHEMA = 'priority/agent-cost-rollup-materialization@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'agent-cost-rollup-materialization.json');
export const DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH = path.join('tools', 'policy', 'live-agent-model-selection.json');

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

function toPositiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function ensureParentDir(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  ensureParentDir(resolved);
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function safeReadJson(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    return null;
  }
  try {
    return readJson(resolved);
  } catch {
    return null;
  }
}

function safeRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
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
      }).toString('utf8').trim();
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

function resolveCurrentBranch(execSyncFn = execSync) {
  try {
    return asOptional(execSyncFn('git branch --show-current', {
      stdio: ['ignore', 'pipe', 'ignore']
    }).toString('utf8').trim());
  } catch {
    return null;
  }
}

function parseIssueNumberFromBranch(branch) {
  const normalized = normalizeText(branch);
  if (!normalized.toLowerCase().startsWith('issue/')) {
    return null;
  }
  const suffix = normalized.slice('issue/'.length);
  for (const token of suffix.split('-')) {
    const parsed = toPositiveInteger(token);
    if (parsed) {
      return parsed;
    }
  }
  return null;
}

function createBlocker(code, message, targetPath = null) {
  return {
    code,
    message,
    path: targetPath ? normalizeText(targetPath) : null
  };
}

function parseDateTime(value) {
  const normalized = asOptional(value);
  if (!normalized) {
    return null;
  }
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? normalized : null;
}

function listJsonFiles(dirPath) {
  const resolved = path.resolve(dirPath);
  if (!fs.existsSync(resolved)) {
    return [];
  }
  return fs.readdirSync(resolved, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.json'))
    .map((entry) => path.join(resolved, entry.name));
}

function chooseNewestByBasename(filePaths) {
  const winners = new Map();
  for (const filePath of filePaths) {
    const resolved = path.resolve(filePath);
    const key = path.basename(resolved).toLowerCase();
    const mtimeMs = fs.existsSync(resolved) ? fs.statSync(resolved).mtimeMs : 0;
    const existing = winners.get(key);
    if (!existing || mtimeMs > existing.mtimeMs) {
      winners.set(key, {
        fileName: path.basename(resolved),
        sourcePath: resolved,
        mtimeMs
      });
    }
  }
  return Array.from(winners.values()).sort((left, right) => left.fileName.localeCompare(right.fileName));
}

function uniquePaths(values) {
  return Array.from(new Set(values.filter(Boolean).map((value) => path.resolve(value))));
}

function discoverRepoRoots(repoRoot, policy) {
  const currentRoot = path.resolve(repoRoot);
  const roots = new Set([currentRoot, path.dirname(currentRoot)]);
  for (const configuredRoot of Array.isArray(policy.discoveryRoots) ? policy.discoveryRoots : []) {
    if (asOptional(configuredRoot)) {
      roots.add(path.resolve(configuredRoot));
    }
  }
  return Array.from(roots);
}

function discoverReceiptFiles(repoRoot, relativeDir, policy) {
  const repoFamilyPrefix = asOptional(policy.repoFamilyPrefix) || path.basename(path.resolve(repoRoot));
  const discovered = [];
  const roots = discoverRepoRoots(repoRoot, policy);
  discovered.push(...listJsonFiles(path.resolve(repoRoot, relativeDir)));

  for (const root of roots) {
    const resolvedRoot = path.resolve(root);
    if (!fs.existsSync(resolvedRoot)) {
      continue;
    }
    let entries = [];
    try {
      entries = fs.readdirSync(resolvedRoot, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || !entry.name.startsWith(repoFamilyPrefix)) {
        continue;
      }
      discovered.push(...listJsonFiles(path.join(resolvedRoot, entry.name, relativeDir)));
    }
  }

  return chooseNewestByBasename(uniquePaths(discovered));
}

function syncReceiptsToLocal(repoRoot, relativeDir, discoveredFiles) {
  const destinationDir = path.resolve(repoRoot, relativeDir);
  fs.mkdirSync(destinationDir, { recursive: true });
  const files = [];
  for (const entry of discoveredFiles) {
    const destinationPath = path.join(destinationDir, entry.fileName);
    if (path.resolve(entry.sourcePath) !== path.resolve(destinationPath)) {
      fs.copyFileSync(entry.sourcePath, destinationPath);
    }
    files.push({
      fileName: entry.fileName,
      sourcePath: entry.sourcePath,
      destinationPath
    });
  }
  return {
    destinationDir,
    discoveredCount: discoveredFiles.length,
    materializedCount: files.length,
    files
  };
}

function resolveInvoiceTurnId(localInvoiceDir) {
  const candidates = listJsonFiles(localInvoiceDir)
    .map((filePath) => ({
      filePath,
      payload: safeReadJson(filePath),
      mtimeMs: fs.existsSync(filePath) ? fs.statSync(filePath).mtimeMs : 0
    }))
    .filter((entry) => entry.payload?.schema === 'priority/agent-cost-invoice-turn@v1')
    .sort((left, right) => right.mtimeMs - left.mtimeMs);
  return asOptional(candidates[0]?.payload?.invoiceTurnId);
}

function loadLiveAgentDefaults(policyPath, providerId) {
  const payload = readJson(policyPath);
  const provider = Array.isArray(payload.providers)
    ? payload.providers.find((entry) => asOptional(entry?.providerId) === providerId && asOptional(entry?.agentRole) === 'live')
    : null;
  if (!provider) {
    throw new Error(`Unable to resolve live-agent defaults for provider '${providerId}' from ${policyPath}.`);
  }
  return {
    requestedModel: asOptional(provider.defaultModel),
    requestedReasoningEffort: asOptional(provider.defaultReasoningEffort)
  };
}

function resolveUsageObservedAt(operatorSteeringEvent, now) {
  return parseDateTime(operatorSteeringEvent?.generatedAt) || parseDateTime(operatorSteeringEvent?.issueContext?.observedAt) || now.toISOString();
}

function sanitizeSegment(value) {
  return normalizeText(value).replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'lane';
}

function summarizeSyncedReceipts(repoRoot, syncResult) {
  return {
    destinationDir: safeRelative(repoRoot, syncResult.destinationDir),
    discoveredCount: syncResult.discoveredCount,
    materializedCount: syncResult.materializedCount,
    files: syncResult.files.map((entry) => ({
      fileName: entry.fileName,
      sourcePath: entry.sourcePath,
      destinationPath: safeRelative(repoRoot, entry.destinationPath)
    }))
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: process.cwd(),
    repo: null,
    issueNumber: null,
    laneId: null,
    laneBranch: null,
    policyPath: DEFAULT_POLICY_PATH,
    liveAgentModelSelectionPolicyPath: DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH,
    outputPath: null,
    costRollupPath: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (['--repo-root', '--repo', '--issue-number', '--lane-id', '--lane-branch', '--policy', '--live-agent-model-selection-policy', '--output', '--cost-rollup'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--repo') options.repo = next;
      if (token === '--issue-number') options.issueNumber = next;
      if (token === '--lane-id') options.laneId = next;
      if (token === '--lane-branch') options.laneBranch = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--live-agent-model-selection-policy') options.liveAgentModelSelectionPolicyPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--cost-rollup') options.costRollupPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  options.issueNumber = options.issueNumber != null ? toPositiveInteger(options.issueNumber) : null;
  return options;
}

export function runMaterializeAgentCostRollup(
  options,
  {
    now = new Date(),
    execSyncFn = execSync,
    resolveRepoSlugFn = resolveRepoSlug,
    writeJsonFn = writeJson,
    runAgentCostTurnFn = runAgentCostTurn,
    runAgentCostRollupFn = runAgentCostRollup
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || process.cwd());
  const policyPath = path.resolve(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  const liveAgentModelSelectionPolicyPath = path.resolve(repoRoot, options.liveAgentModelSelectionPolicyPath || DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH);
  const policy = readJson(policyPath);
  const repository = resolveRepoSlugFn(options.repo, execSyncFn);
  if (!repository) {
    throw new Error('Unable to determine repository slug for cost rollup materialization.');
  }

  const laneBranch = asOptional(options.laneBranch) || resolveCurrentBranch(execSyncFn);
  const laneId = asOptional(options.laneId) || laneBranch;
  const issueNumber = options.issueNumber ?? parseIssueNumberFromBranch(laneBranch);
  if (!laneBranch || !laneId || !issueNumber) {
    throw new Error('Cost rollup materialization requires a lane branch, lane id, and issue number.');
  }

  const operatorSteeringEventPath = path.resolve(repoRoot, asOptional(policy.operatorSteeringEventPath) || 'tests/results/_agent/runtime/operator-steering-event.json');
  const operatorSteeringEvent = safeReadJson(operatorSteeringEventPath);

  const syncedInvoiceTurns = syncReceiptsToLocal(repoRoot, path.join('tests', 'results', '_agent', 'cost', 'invoice-turns'), discoverReceiptFiles(repoRoot, path.join('tests', 'results', '_agent', 'cost', 'invoice-turns'), policy));
  const syncedUsageExports = syncReceiptsToLocal(repoRoot, path.join('tests', 'results', '_agent', 'cost', 'usage-exports'), discoverReceiptFiles(repoRoot, path.join('tests', 'results', '_agent', 'cost', 'usage-exports'), policy));
  const syncedAccountBalances = syncReceiptsToLocal(repoRoot, path.join('tests', 'results', '_agent', 'cost', 'account-balances'), discoverReceiptFiles(repoRoot, path.join('tests', 'results', '_agent', 'cost', 'account-balances'), policy));

  const heuristic = policy.liveLaneHeuristic;
  const liveDefaults = loadLiveAgentDefaults(liveAgentModelSelectionPolicyPath, asOptional(heuristic?.providerId));
  const turnsDir = path.resolve(repoRoot, asOptional(policy.turnsDir) || path.join('tests', 'results', '_agent', 'cost', 'turns'));
  const heuristicTurnPath = path.join(turnsDir, asOptional(policy.heuristicTurnFileName) || 'current-lane-heuristic.json');
  const invoiceTurnId = resolveInvoiceTurnId(syncedInvoiceTurns.destinationDir);
  const usageObservedAt = resolveUsageObservedAt(operatorSteeringEvent, now);
  const turnId = `heuristic-${sanitizeSegment(laneId)}-${now.toISOString().replace(/[:.]/g, '-')}`;

  const turnResult = runAgentCostTurnFn({
    providerId: heuristic.providerId,
    providerKind: heuristic.providerKind,
    providerRuntime: heuristic.providerRuntime,
    executionPlane: heuristic.executionPlane,
    requestedModel: liveDefaults.requestedModel,
    effectiveModel: liveDefaults.requestedModel,
    requestedReasoningEffort: liveDefaults.requestedReasoningEffort,
    effectiveReasoningEffort: liveDefaults.requestedReasoningEffort,
    inputTokens: heuristic.usage.inputTokens,
    cachedInputTokens: heuristic.usage.cachedInputTokens,
    outputTokens: heuristic.usage.outputTokens,
    usageUnitKind: heuristic.usage.usageUnitKind,
    usageUnitCount: heuristic.usage.usageUnitCount,
    exactness: 'estimated',
    rateCardId: heuristic.rateCard.id,
    rateCardSource: heuristic.rateCard.source,
    pricingBasis: heuristic.rateCard.pricingBasis,
    inputUsdPer1kTokens: heuristic.rateCard.inputUsdPer1kTokens,
    cachedInputUsdPer1kTokens: heuristic.rateCard.cachedInputUsdPer1kTokens,
    outputUsdPer1kTokens: heuristic.rateCard.outputUsdPer1kTokens,
    usageUnitUsd: heuristic.rateCard.usageUnitUsd,
    repository,
    issueNumber,
    laneId,
    laneBranch,
    sessionId: `session-${sanitizeSegment(laneId)}`,
    turnId,
    agentRole: 'live',
    sourceSchema: REPORT_SCHEMA,
    sourceReceiptPath: operatorSteeringEventPath,
    sourceReportPath: options.outputPath || path.resolve(repoRoot, asOptional(policy.materializationReportPath) || path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup-materialization.json')),
    usageObservedAt,
    operatorSteered: Boolean(operatorSteeringEvent),
    operatorSteeringKind: asOptional(operatorSteeringEvent?.steeringKind),
    operatorSteeringSource: asOptional(operatorSteeringEvent?.provenance?.source),
    operatorSteeringObservedAt: parseDateTime(operatorSteeringEvent?.issueContext?.observedAt) || parseDateTime(operatorSteeringEvent?.generatedAt),
    operatorSteeringNote: asOptional(operatorSteeringEvent?.continuity?.recommendation),
    steeringInvoiceTurnId: invoiceTurnId,
    outputPath: heuristicTurnPath
  }, now);

  const costRollupPath = path.resolve(repoRoot, options.costRollupPath || asOptional(policy.costRollupPath) || path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json'));
  const rollupResult = runAgentCostRollupFn({
    turnReportPaths: [turnResult.outputPath],
    invoiceTurnPaths: syncedInvoiceTurns.files.map((entry) => entry.destinationPath),
    usageExportPaths: syncedUsageExports.files.map((entry) => entry.destinationPath),
    accountBalancePaths: syncedAccountBalances.files.map((entry) => entry.destinationPath),
    operatorSteeringEventPaths: operatorSteeringEvent ? [operatorSteeringEventPath] : [],
    outputPath: costRollupPath,
    repo: repository,
    failOnInvalidInputs: false
  });

  const blockers = rollupResult.report.summary.status === 'pass'
    ? []
    : (Array.isArray(rollupResult.report.summary.blockers)
      ? rollupResult.report.summary.blockers.map((entry) => ({
          code: normalizeText(entry.code) || 'rollup-blocker',
          message: normalizeText(entry.message) || 'Cost rollup reported a blocker.',
          path: asOptional(entry.inputPath)
        }))
      : [createBlocker('rollup-blocked', 'Cost rollup materialization did not produce a passing rollup.')]);

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    issueNumber,
    laneId,
    laneBranch,
    inputs: {
      policyPath: safeRelative(repoRoot, policyPath),
      liveAgentModelSelectionPolicyPath: safeRelative(repoRoot, liveAgentModelSelectionPolicyPath),
      operatorSteeringEventPath: operatorSteeringEvent ? safeRelative(repoRoot, operatorSteeringEventPath) : null
    },
    syncedReceipts: {
      invoiceTurns: summarizeSyncedReceipts(repoRoot, syncedInvoiceTurns),
      usageExports: summarizeSyncedReceipts(repoRoot, syncedUsageExports),
      accountBalances: summarizeSyncedReceipts(repoRoot, syncedAccountBalances)
    },
    heuristicTurn: {
      path: safeRelative(repoRoot, turnResult.outputPath),
      providerId: heuristic.providerId,
      providerKind: heuristic.providerKind,
      providerRuntime: heuristic.providerRuntime,
      executionPlane: heuristic.executionPlane,
      requestedModel: liveDefaults.requestedModel,
      effectiveModel: liveDefaults.requestedModel,
      requestedReasoningEffort: liveDefaults.requestedReasoningEffort,
      effectiveReasoningEffort: liveDefaults.requestedReasoningEffort,
      usageObservedAt,
      sourceSchema: REPORT_SCHEMA,
      usage: {
        inputTokens: heuristic.usage.inputTokens,
        cachedInputTokens: heuristic.usage.cachedInputTokens,
        outputTokens: heuristic.usage.outputTokens,
        totalTokens: heuristic.usage.inputTokens + heuristic.usage.cachedInputTokens + heuristic.usage.outputTokens,
        usageUnitKind: heuristic.usage.usageUnitKind,
        usageUnitCount: heuristic.usage.usageUnitCount
      },
      billing: {
        exactness: 'estimated',
        rateCard: heuristic.rateCard
      }
    },
    costRollup: {
      path: safeRelative(repoRoot, costRollupPath),
      status: normalizeText(rollupResult.report.summary.status) || 'blocked',
      blockerCount: Number(rollupResult.report.summary.blockerCount ?? blockers.length)
    },
    summary: {
      status: rollupResult.report.summary.status === 'pass' ? 'pass' : 'blocked',
      recommendation: rollupResult.report.summary.status === 'pass' ? 'use-materialized-cost-rollup' : 'repair-cost-rollup-materialization',
      materializedRollup: true,
      materializedHeuristicTurn: true,
      blockerCount: blockers.length,
      blockers
    }
  };

  const outputPath = writeJsonFn(options.outputPath || path.resolve(repoRoot, asOptional(policy.materializationReportPath) || path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup-materialization.json')), report);
  return { report, outputPath, costRollupPath, heuristicTurnPath: turnResult.outputPath };
}

function printUsage() {
  [
    'Usage: node tools/priority/materialize-agent-cost-rollup.mjs [options]',
    '',
    'Options:',
    `  --policy <path>                        Policy path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --live-agent-model-selection-policy <path>  Live-agent model-selection policy path (default: ${DEFAULT_LIVE_AGENT_MODEL_SELECTION_POLICY_PATH}).`,
    '  --repo-root <path>                    Repository root (default: cwd).',
    '  --repo <owner/repo>                   Repository slug override.',
    '  --issue-number <number>               Explicit issue number override.',
    '  --lane-id <value>                     Explicit lane id override.',
    '  --lane-branch <value>                 Explicit lane branch override.',
    '  --cost-rollup <path>                  Output path for the materialized rollup.',
    '  --output <path>                       Materialization report output path.',
    '  -h, --help                            Show help.'
  ].forEach((line) => console.log(line));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv);
    if (options.help) {
      printUsage();
      process.exit(0);
    }
    const result = runMaterializeAgentCostRollup(options);
    console.log(`[agent-cost-rollup-materialization] wrote ${result.outputPath}`);
  } catch (error) {
    console.error(`[agent-cost-rollup-materialization] ${error.message}`);
    process.exit(1);
  }
}

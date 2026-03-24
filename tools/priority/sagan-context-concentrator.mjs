#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

export const REPORT_SCHEMA = 'priority/sagan-context-concentrator-report@v1';
export const SUBAGENT_EPISODE_SCHEMA = 'priority/subagent-episode-report@v1';
export const DEFAULT_PRIORITY_CACHE_PATH = '.agent_priority_cache.json';
export const DEFAULT_GOVERNOR_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'autonomous-governor-summary.json'
);
export const DEFAULT_GOVERNOR_PORTFOLIO_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'autonomous-governor-portfolio-summary.json'
);
export const DEFAULT_MONITORING_MODE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'monitoring-mode.json'
);
export const DEFAULT_OPERATOR_STEERING_EVENT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'operator-steering-event.json'
);
export const DEFAULT_EPISODE_DIR = path.join(
  'tests',
  'results',
  '_agent',
  'memory',
  'subagent-episodes'
);
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'sagan-context-concentrator.json'
);

function normalizeText(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeFiniteNumber(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizeInteger(value) {
  if (value == null || value === '') {
    return null;
  }
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function normalizeBoolean(value) {
  if (value === true || value === false) {
    return value;
  }
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (normalized === 'true') {
      return true;
    }
    if (normalized === 'false') {
      return false;
    }
  }
  return null;
}

function toPortablePath(filePath) {
  return String(filePath).replace(/\\/g, '/');
}

function toRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
}

function toDisplayPath(repoRoot, targetPath) {
  if (!targetPath) {
    return null;
  }
  const relative = path.relative(path.resolve(repoRoot), path.resolve(targetPath));
  if (!relative.startsWith('..') && !path.isAbsolute(relative)) {
    return toPortablePath(relative);
  }
  return toPortablePath(path.resolve(targetPath));
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function readOptionalJson(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function ensureSchema(payload, filePath, schema) {
  if (payload?.schema !== schema) {
    throw new Error(`Expected ${schema} at ${filePath}.`);
  }
  return payload;
}

function isEpisodeActive(episode) {
  const status = normalizeText(episode?.summary?.status)?.toLowerCase();
  return !['completed', 'pass', 'success', 'closed', 'retired'].includes(status || '');
}

function buildExecutionOwnershipLabel(record) {
  const parts = [];
  const cellId = normalizeText(record?.cellId);
  const dockerLaneId = normalizeText(record?.dockerLaneId);
  const harnessInstanceId = normalizeText(record?.harnessInstanceId);
  const harnessInstanceLeaseId = normalizeText(record?.harnessInstanceLeaseId);
  const runtimeSurface = normalizeText(record?.runtimeSurface);
  const processModelClass = normalizeText(record?.processModelClass);
  const premiumSaganMode = normalizeBoolean(record?.premiumSaganMode);

  if (cellId) {
    parts.push(`cell ${cellId}`);
  }
  if (dockerLaneId) {
    parts.push(`docker ${dockerLaneId}`);
  }
  if (harnessInstanceId) {
    parts.push(`harness ${harnessInstanceId}`);
  }
  if (harnessInstanceLeaseId) {
    parts.push(`harness-lease ${harnessInstanceLeaseId}`);
  }
  if (runtimeSurface) {
    parts.push(runtimeSurface);
  }
  if (processModelClass) {
    parts.push(processModelClass);
  }
  if (premiumSaganMode === true) {
    parts.push('premium-sagan');
  }

  return parts.length > 0 ? parts.join(' / ') : null;
}

function buildEpisodeDigest(episode, repoRoot, filePath) {
  const execution = episode?.execution || {};
  return {
    episodeId: normalizeText(episode?.episodeId),
    generatedAt: normalizeText(episode?.generatedAt),
    agentId: normalizeText(episode?.agent?.id),
    agentName: normalizeText(episode?.agent?.name),
    agentRole: normalizeText(episode?.agent?.role),
    status: normalizeText(episode?.summary?.status),
    taskSummary: normalizeText(episode?.task?.summary),
    nextAction: normalizeText(episode?.summary?.nextAction),
    blocker: normalizeText(episode?.summary?.blocker),
    executionPlane: normalizeText(execution.executionPlane),
    dockerLaneId: normalizeText(execution.dockerLaneId),
    cellId: normalizeText(execution.cellId),
    executionCellLeaseId: normalizeText(execution.executionCellLeaseId),
    dockerLaneLeaseId: normalizeText(execution.dockerLaneLeaseId),
    cellClass: normalizeText(execution.cellClass),
    suiteClass: normalizeText(execution.suiteClass),
    harnessKind: normalizeText(execution.harnessKind),
    harnessInstanceId: normalizeText(execution.harnessInstanceId),
    harnessInstanceLeaseId: normalizeText(execution.harnessInstanceLeaseId),
    harnessInstanceLeasePath: normalizeText(execution.harnessInstanceLeasePath),
    runtimeSurface: normalizeText(execution.runtimeSurface),
    processModelClass: normalizeText(execution.processModelClass),
    operatorAuthorizationRef: normalizeText(execution.operatorAuthorizationRef),
    premiumSaganMode: normalizeBoolean(execution.premiumSaganMode),
    executionOwnershipLabel: buildExecutionOwnershipLabel(execution),
    sourcePath: toDisplayPath(repoRoot, filePath)
  };
}

function makeMemoryItem({
  id,
  kind,
  label,
  status,
  detail = null,
  executionPlane = null,
  cellId = null,
  dockerLaneId = null,
  harnessInstanceId = null,
  harnessInstanceLeaseId = null,
  harnessInstanceLeasePath = null,
  runtimeSurface = null,
  processModelClass = null,
  premiumSaganMode = null,
  executionOwnershipLabel = null,
  sourcePath = null,
  updatedAt = null,
  issueNumber = null,
  repository = null,
  agentName = null,
  nextAction = null
}) {
  return {
    id: normalizeText(id),
    kind: normalizeText(kind),
    label: normalizeText(label),
    status: normalizeText(status),
    detail: normalizeText(detail),
    executionPlane: normalizeText(executionPlane),
    cellId: normalizeText(cellId),
    dockerLaneId: normalizeText(dockerLaneId),
    harnessInstanceId: normalizeText(harnessInstanceId),
    harnessInstanceLeaseId: normalizeText(harnessInstanceLeaseId),
    harnessInstanceLeasePath: normalizeText(harnessInstanceLeasePath),
    runtimeSurface: normalizeText(runtimeSurface),
    processModelClass: normalizeText(processModelClass),
    premiumSaganMode: normalizeBoolean(premiumSaganMode),
    executionOwnershipLabel: normalizeText(executionOwnershipLabel),
    sourcePath: normalizeText(sourcePath),
    updatedAt: normalizeText(updatedAt),
    issueNumber: normalizeInteger(issueNumber),
    repository: normalizeText(repository),
    agentName: normalizeText(agentName),
    nextAction: normalizeText(nextAction)
  };
}

function addUniqueMemoryItem(collection, item, seenIds) {
  if (!item?.id || seenIds.has(item.id)) {
    return false;
  }
  collection.push(item);
  seenIds.add(item.id);
  return true;
}

function sortEpisodesDescending(entries) {
  return [...entries].sort((left, right) => {
    const leftTime = Date.parse(left.episode.generatedAt || 0);
    const rightTime = Date.parse(right.episode.generatedAt || 0);
    return rightTime - leftTime;
  });
}

function listEpisodeFiles(directoryPath) {
  if (!fs.existsSync(directoryPath) || !fs.statSync(directoryPath).isDirectory()) {
    return [];
  }
  return fs
    .readdirSync(directoryPath, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.json'))
    .map((entry) => path.join(directoryPath, entry.name))
    .sort();
}

function readEpisodes(repoRoot, episodeDirPath, readJsonFn = readOptionalJson) {
  const episodeFiles = listEpisodeFiles(episodeDirPath);
  const validEpisodes = [];
  const invalidEpisodes = [];

  for (const episodePath of episodeFiles) {
    try {
      const payload = readJsonFn(episodePath);
      ensureSchema(payload, episodePath, SUBAGENT_EPISODE_SCHEMA);
      validEpisodes.push({ path: episodePath, episode: payload });
    } catch (error) {
      invalidEpisodes.push({
        path: toDisplayPath(repoRoot, episodePath),
        error: error.message
      });
    }
  }

  return {
    files: episodeFiles,
    validEpisodes,
    invalidEpisodes
  };
}

function countByStatus(entries) {
  const counts = new Map();
  for (const entry of entries) {
    const status = normalizeText(entry.episode?.summary?.status) || 'unknown';
    counts.set(status, (counts.get(status) || 0) + 1);
  }
  return [...counts.entries()]
    .map(([status, count]) => ({ status, count }))
    .sort((left, right) => left.status.localeCompare(right.status));
}

function countByAgent(entries) {
  const counts = new Map();
  for (const entry of entries) {
    const agentId = normalizeText(entry.episode?.agent?.id) || 'unknown';
    const agentName = normalizeText(entry.episode?.agent?.name);
    const key = `${agentId}::${agentName || ''}`;
    const current = counts.get(key) || {
      agentId,
      agentName,
      count: 0
    };
    current.count += 1;
    counts.set(key, current);
  }
  return [...counts.values()].sort((left, right) => {
    if (right.count !== left.count) {
      return right.count - left.count;
    }
    return (left.agentName || left.agentId).localeCompare(right.agentName || right.agentId);
  });
}

function sumEpisodeCost(entries, fieldName) {
  return entries.reduce((sum, entry) => {
    const value = normalizeFiniteNumber(entry.episode?.cost?.[fieldName]);
    return sum + (value ?? 0);
  }, 0);
}

function deriveOwnerSummary(governorSummary, governorPortfolioSummary, monitoringMode) {
  return {
    currentOwnerRepository:
      normalizeText(governorPortfolioSummary?.summary?.currentOwnerRepository) ||
      normalizeText(governorSummary?.summary?.currentOwnerRepository) ||
      normalizeText(monitoringMode?.policy?.compareRepository),
    nextOwnerRepository:
      normalizeText(governorPortfolioSummary?.summary?.nextOwnerRepository) ||
      normalizeText(governorSummary?.summary?.nextOwnerRepository),
    nextAction:
      normalizeText(governorPortfolioSummary?.summary?.nextAction) ||
      normalizeText(governorSummary?.summary?.nextAction),
    governorMode:
      normalizeText(governorSummary?.summary?.governorMode) ||
      normalizeText(governorPortfolioSummary?.summary?.governorMode),
    monitoringStatus:
      normalizeText(governorSummary?.summary?.monitoringStatus) ||
      normalizeText(monitoringMode?.summary?.status)
  };
}

function deriveFocus(priorityCache, ownerSummary) {
  const number = normalizeInteger(priorityCache?.number);
  return {
    activeIssue: number
      ? {
          number,
          title: normalizeText(priorityCache?.title),
          url: normalizeText(priorityCache?.url),
          state: normalizeText(priorityCache?.state),
          repository: normalizeText(priorityCache?.repository)
        }
      : null,
    currentOwnerRepository: ownerSummary.currentOwnerRepository,
    nextOwnerRepository: ownerSummary.nextOwnerRepository,
    nextAction: ownerSummary.nextAction,
    governorMode: ownerSummary.governorMode,
    monitoringStatus: ownerSummary.monitoringStatus
  };
}

function deriveSystemMemoryItems({
  repoRoot,
  priorityCachePath,
  governorSummaryPath,
  governorSummary,
  governorPortfolioSummaryPath,
  governorPortfolioSummary,
  focus
}) {
  const items = [];
  const seenIds = new Set();

  if (focus.activeIssue) {
    addUniqueMemoryItem(
      items,
      makeMemoryItem({
        id: `issue-${focus.activeIssue.number}`,
        kind: 'active-issue',
        label: `#${focus.activeIssue.number}: ${focus.activeIssue.title || 'standing priority'}`,
        status: focus.activeIssue.state || 'open',
        detail: 'Current standing-priority objective',
        sourcePath: toDisplayPath(repoRoot, priorityCachePath),
        updatedAt: normalizeText(priorityCachePath ? focus.activeIssue?.updatedAt : null),
        issueNumber: focus.activeIssue.number,
        repository: focus.activeIssue.repository,
        nextAction: focus.nextAction
      }),
      seenIds
    );
  }

  addUniqueMemoryItem(
    items,
    makeMemoryItem({
      id: 'governor-owner-decision',
      kind: 'owner-decision',
      label: focus.currentOwnerRepository
        ? `Owner: ${focus.currentOwnerRepository}`
        : 'Owner decision unavailable',
      status: focus.governorMode || 'unknown',
      detail: focus.nextOwnerRepository
        ? `Next owner ${focus.nextOwnerRepository}`
        : 'No next-owner decision recorded',
      sourcePath: toDisplayPath(repoRoot, governorPortfolioSummaryPath || governorSummaryPath),
      updatedAt:
        normalizeText(governorPortfolioSummary?.generatedAt) || normalizeText(governorSummary?.generatedAt),
      repository: focus.currentOwnerRepository,
      nextAction: focus.nextAction
    }),
    seenIds
  );

  const releaseBlocker = normalizeText(governorSummary?.summary?.releaseSigningExternalBlocker);
  const releasePublishedBundleState = normalizeText(governorSummary?.summary?.releasePublishedBundleState);
  if (releaseBlocker || releasePublishedBundleState) {
    addUniqueMemoryItem(
      items,
      makeMemoryItem({
        id: 'release-publication-blocker',
        kind: 'blocker',
        label: releaseBlocker || `Published bundle ${releasePublishedBundleState}`,
        status: normalizeText(governorSummary?.summary?.releaseSigningStatus) || 'warn',
        detail: normalizeText(governorSummary?.summary?.releasePublicationState),
        sourcePath: toDisplayPath(repoRoot, governorSummaryPath),
        updatedAt: normalizeText(governorSummary?.generatedAt),
        issueNumber: focus.activeIssue?.number,
        repository: focus.currentOwnerRepository,
        nextAction: focus.nextAction
      }),
      seenIds
    );
  }

  const dependencyStatus = normalizeText(governorPortfolioSummary?.summary?.viHistoryDistributorDependencyStatus);
  if (dependencyStatus) {
    addUniqueMemoryItem(
      items,
      makeMemoryItem({
        id: 'vi-history-distributor-dependency',
        kind: 'dependency',
        label: `vi-history dependency ${dependencyStatus}`,
        status: dependencyStatus,
        detail:
          normalizeText(governorPortfolioSummary?.summary?.viHistoryDistributorDependencyExternalBlocker) ||
          normalizeText(governorPortfolioSummary?.summary?.viHistoryDistributorDependencyPublishedBundleState),
        sourcePath: toDisplayPath(repoRoot, governorPortfolioSummaryPath),
        updatedAt: normalizeText(governorPortfolioSummary?.generatedAt),
        repository:
          normalizeText(governorPortfolioSummary?.summary?.viHistoryDistributorDependencyTargetRepository),
        nextAction: focus.nextAction
      }),
      seenIds
    );
  }

  return { items, seenIds };
}

function deriveEpisodeMemoryItems(sortedEpisodes, repoRoot, seenIds) {
  const hotEpisodes = [];
  const warmEpisodes = [];
  const usedEpisodeIds = new Set();

  for (const entry of sortedEpisodes) {
    const digest = buildEpisodeDigest(entry.episode, repoRoot, entry.path);
    const detail =
      digest.blocker ||
      digest.executionOwnershipLabel ||
      digest.executionPlane;
    const item = makeMemoryItem({
      id: `episode-${digest.episodeId || digest.agentId || digest.generatedAt}`,
      kind: 'subagent-episode',
      label: `${digest.agentName || digest.agentId || 'subagent'}: ${digest.taskSummary || 'task'}`,
      status: digest.status || 'reported',
      detail,
      executionPlane: digest.executionPlane,
      cellId: digest.cellId,
      dockerLaneId: digest.dockerLaneId,
      harnessInstanceId: digest.harnessInstanceId,
      harnessInstanceLeaseId: digest.harnessInstanceLeaseId,
      harnessInstanceLeasePath: digest.harnessInstanceLeasePath,
      runtimeSurface: digest.runtimeSurface,
      processModelClass: digest.processModelClass,
      premiumSaganMode: digest.premiumSaganMode,
      executionOwnershipLabel: digest.executionOwnershipLabel,
      sourcePath: digest.sourcePath,
      updatedAt: digest.generatedAt,
      issueNumber: normalizeInteger(entry.episode?.task?.issueNumber),
      repository: normalizeText(entry.episode?.repository),
      agentName: digest.agentName,
      nextAction: digest.nextAction
    });

    if (usedEpisodeIds.has(item.id) || seenIds.has(item.id)) {
      continue;
    }

    if (isEpisodeActive(entry.episode) && hotEpisodes.length < 3) {
      hotEpisodes.push(item);
      usedEpisodeIds.add(item.id);
      seenIds.add(item.id);
      continue;
    }

    if (warmEpisodes.length < 5) {
      warmEpisodes.push(item);
      usedEpisodeIds.add(item.id);
      continue;
    }
  }

  const archiveCount = Math.max(sortedEpisodes.length - usedEpisodeIds.size, 0);
  return { hotEpisodes, warmEpisodes, archiveCount };
}

function buildReport({
  repoRoot,
  priorityCachePath,
  priorityCache,
  governorSummaryPath,
  governorSummary,
  governorPortfolioSummaryPath,
  governorPortfolioSummary,
  monitoringModePath,
  monitoringMode,
  operatorSteeringEventPath,
  operatorSteeringEvent,
  episodeDirPath,
  episodes,
  now
}) {
  const ownerSummary = deriveOwnerSummary(governorSummary, governorPortfolioSummary, monitoringMode);
  const focus = deriveFocus(priorityCache, ownerSummary);
  const { items: systemItems, seenIds } = deriveSystemMemoryItems({
    repoRoot,
    priorityCachePath,
    governorSummaryPath,
    governorSummary,
    governorPortfolioSummaryPath,
    governorPortfolioSummary,
    focus
  });
  const sortedEpisodes = sortEpisodesDescending(episodes.validEpisodes);
  const { hotEpisodes, warmEpisodes, archiveCount } = deriveEpisodeMemoryItems(sortedEpisodes, repoRoot, seenIds);
  const hotWorkingSet = [...systemItems, ...hotEpisodes];
  const byStatus = countByStatus(episodes.validEpisodes);
  const byAgent = countByAgent(episodes.validEpisodes);
  const cost = {
    episodeCountWithCost: episodes.validEpisodes.filter(
      (entry) =>
        normalizeFiniteNumber(entry.episode?.cost?.tokenUsd) != null ||
        normalizeFiniteNumber(entry.episode?.cost?.operatorLaborUsd) != null ||
        normalizeFiniteNumber(entry.episode?.cost?.blendedLowerBoundUsd) != null
    ).length,
    tokenUsd: Number(sumEpisodeCost(episodes.validEpisodes, 'tokenUsd').toFixed(6)),
    operatorLaborUsd: Number(sumEpisodeCost(episodes.validEpisodes, 'operatorLaborUsd').toFixed(6)),
    blendedLowerBoundUsd: Number(sumEpisodeCost(episodes.validEpisodes, 'blendedLowerBoundUsd').toFixed(6)),
    observedDurationSeconds: Number(sumEpisodeCost(episodes.validEpisodes, 'observedDurationSeconds').toFixed(3))
  };
  const blockerCount = hotWorkingSet.filter((item) =>
    ['blocked', 'warn', 'fail', 'unknown', 'producer-native-incomplete'].includes((item.status || '').toLowerCase())
  ).length;
  const concentrationStatus =
    episodes.invalidEpisodes.length > 0
      ? 'warn'
      : governorSummary || governorPortfolioSummary
        ? 'pass'
        : 'incomplete';

  return {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository:
      normalizeText(governorSummary?.repository) ||
      normalizeText(governorPortfolioSummary?.repository) ||
      normalizeText(priorityCache?.repository),
    inputs: {
      priorityCachePath: toDisplayPath(repoRoot, priorityCachePath),
      governorSummaryPath: toDisplayPath(repoRoot, governorSummaryPath),
      governorPortfolioSummaryPath: toDisplayPath(repoRoot, governorPortfolioSummaryPath),
      monitoringModePath: toDisplayPath(repoRoot, monitoringModePath),
      operatorSteeringEventPath: toDisplayPath(repoRoot, operatorSteeringEventPath),
      episodeDirectoryPath: toDisplayPath(repoRoot, episodeDirPath)
    },
    sources: {
      priorityCache: {
        path: toDisplayPath(repoRoot, priorityCachePath),
        exists: Boolean(priorityCache)
      },
      governorSummary: {
        path: toDisplayPath(repoRoot, governorSummaryPath),
        exists: Boolean(governorSummary)
      },
      governorPortfolioSummary: {
        path: toDisplayPath(repoRoot, governorPortfolioSummaryPath),
        exists: Boolean(governorPortfolioSummary)
      },
      monitoringMode: {
        path: toDisplayPath(repoRoot, monitoringModePath),
        exists: Boolean(monitoringMode)
      },
      operatorSteeringEvent: {
        path: toDisplayPath(repoRoot, operatorSteeringEventPath),
        exists: Boolean(operatorSteeringEvent)
      },
      episodeDirectory: {
        path: toDisplayPath(repoRoot, episodeDirPath),
        exists: fs.existsSync(episodeDirPath),
        fileCount: episodes.files.length,
        validEpisodeCount: episodes.validEpisodes.length,
        invalidEpisodeCount: episodes.invalidEpisodes.length
      }
    },
    focus,
    memory: {
      hotWorkingSet,
      warmMemory: warmEpisodes,
      archiveCount
    },
    episodes: {
      totalCount: episodes.files.length,
      validCount: episodes.validEpisodes.length,
      invalidCount: episodes.invalidEpisodes.length,
      invalidEpisodes: episodes.invalidEpisodes,
      byStatus,
      byAgent,
      recent: sortedEpisodes.slice(0, 5).map((entry) => buildEpisodeDigest(entry.episode, repoRoot, entry.path))
    },
    cost,
    summary: {
      status:
        normalizeText(governorSummary?.summary?.governorMode) === 'monitoring-active' ? 'monitoring' : 'active',
      concentrationStatus,
      currentOwnerRepository: focus.currentOwnerRepository,
      nextOwnerRepository: focus.nextOwnerRepository,
      nextAction: focus.nextAction,
      activeIssueNumber: normalizeInteger(focus.activeIssue?.number),
      hotWorkingSetCount: hotWorkingSet.length,
      warmMemoryCount: warmEpisodes.length,
      archiveCount,
      blockerCount,
      recentEpisodeCount: episodes.validEpisodes.length,
      blendedLowerBoundUsd: cost.blendedLowerBoundUsd
    }
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    priorityCachePath: DEFAULT_PRIORITY_CACHE_PATH,
    governorSummaryPath: DEFAULT_GOVERNOR_SUMMARY_PATH,
    governorPortfolioSummaryPath: DEFAULT_GOVERNOR_PORTFOLIO_SUMMARY_PATH,
    monitoringModePath: DEFAULT_MONITORING_MODE_PATH,
    operatorSteeringEventPath: DEFAULT_OPERATOR_STEERING_EVENT_PATH,
    episodeDirectoryPath: DEFAULT_EPISODE_DIR,
    outputPath: DEFAULT_OUTPUT_PATH,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--priority-cache', 'priorityCachePath'],
    ['--governor-summary', 'governorSummaryPath'],
    ['--governor-portfolio-summary', 'governorPortfolioSummaryPath'],
    ['--monitoring-mode', 'monitoringModePath'],
    ['--operator-steering-event', 'operatorSteeringEventPath'],
    ['--episode-directory', 'episodeDirectoryPath'],
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
      index += 1;
      options[stringFlags.get(token)] = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  console.log('Usage: node tools/priority/sagan-context-concentrator.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>                   Repository root.');
  console.log(`  --priority-cache <path>              Priority cache (default: ${DEFAULT_PRIORITY_CACHE_PATH}).`);
  console.log(`  --governor-summary <path>            Governor summary (default: ${DEFAULT_GOVERNOR_SUMMARY_PATH}).`);
  console.log(
    `  --governor-portfolio-summary <path>  Governor portfolio summary (default: ${DEFAULT_GOVERNOR_PORTFOLIO_SUMMARY_PATH}).`
  );
  console.log(`  --monitoring-mode <path>             Monitoring mode report (default: ${DEFAULT_MONITORING_MODE_PATH}).`);
  console.log(
    `  --operator-steering-event <path>     Operator steering event (default: ${DEFAULT_OPERATOR_STEERING_EVENT_PATH}).`
  );
  console.log(`  --episode-directory <path>           Subagent episode directory (default: ${DEFAULT_EPISODE_DIR}).`);
  console.log(`  --output <path>                      Output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  -h, --help                           Show this help text.');
}

export async function runSaganContextConcentrator(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const priorityCachePath = path.resolve(repoRoot, options.priorityCachePath || DEFAULT_PRIORITY_CACHE_PATH);
  const governorSummaryPath = path.resolve(repoRoot, options.governorSummaryPath || DEFAULT_GOVERNOR_SUMMARY_PATH);
  const governorPortfolioSummaryPath = path.resolve(
    repoRoot,
    options.governorPortfolioSummaryPath || DEFAULT_GOVERNOR_PORTFOLIO_SUMMARY_PATH
  );
  const monitoringModePath = path.resolve(repoRoot, options.monitoringModePath || DEFAULT_MONITORING_MODE_PATH);
  const operatorSteeringEventPath = path.resolve(
    repoRoot,
    options.operatorSteeringEventPath || DEFAULT_OPERATOR_STEERING_EVENT_PATH
  );
  const episodeDirPath = path.resolve(repoRoot, options.episodeDirectoryPath || DEFAULT_EPISODE_DIR);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);

  const readOptionalJsonFn = deps.readOptionalJsonFn || readOptionalJson;
  const writeJsonFn = deps.writeJsonFn || writeJson;
  const now = deps.now || new Date();

  const priorityCache = readOptionalJsonFn(priorityCachePath);
  const governorSummary = readOptionalJsonFn(governorSummaryPath);
  const governorPortfolioSummary = readOptionalJsonFn(governorPortfolioSummaryPath);
  const monitoringMode = readOptionalJsonFn(monitoringModePath);
  const operatorSteeringEvent = readOptionalJsonFn(operatorSteeringEventPath);
  const episodes = readEpisodes(repoRoot, episodeDirPath, readOptionalJsonFn);

  if (governorSummary) {
    ensureSchema(governorSummary, governorSummaryPath, 'priority/autonomous-governor-summary-report@v1');
  }
  if (governorPortfolioSummary) {
    ensureSchema(
      governorPortfolioSummary,
      governorPortfolioSummaryPath,
      'priority/autonomous-governor-portfolio-summary-report@v1'
    );
  }
  if (monitoringMode) {
    ensureSchema(monitoringMode, monitoringModePath, 'agent-handoff/monitoring-mode-v1');
  }

  const report = buildReport({
    repoRoot,
    priorityCachePath,
    priorityCache,
    governorSummaryPath,
    governorSummary,
    governorPortfolioSummaryPath,
    governorPortfolioSummary,
    monitoringModePath,
    monitoringMode,
    operatorSteeringEventPath,
    operatorSteeringEvent,
    episodeDirPath,
    episodes,
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
    console.error(`[sagan-context-concentrator] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runSaganContextConcentrator(options);
    console.log(
      `[sagan-context-concentrator] wrote ${outputPath} (${report.summary.concentrationStatus}, hot=${report.summary.hotWorkingSetCount})`
    );
    return 0;
  } catch (error) {
    console.error(`[sagan-context-concentrator] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) {
        process.exitCode = code;
      }
    })
    .catch((error) => {
      console.error(`[sagan-context-concentrator] ${error.message}`);
      process.exitCode = 1;
    });
}

#!/usr/bin/env node
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  classifyNoStandingPriorityCondition,
  createSnapshot,
  fetchIssue,
  resolveStandingPriorityForRepo,
  resolveStandingPriorityLabels
} from './sync-standing-priority.mjs';

const MODULE_FILE_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = path.resolve(path.dirname(MODULE_FILE_PATH), '../..');
const DEFAULT_REGISTRY_PATH = path.join('tools', 'priority', 'lane-marketplace.json');
export const DEFAULT_MARKETPLACE_SNAPSHOT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'marketplace',
  'lane-marketplace-snapshot.json'
);

const AUTHORITY_TIER_ORDER = new Map([
  ['upstream-integration', 0],
  ['shared-platform', 1],
  ['consumer-proving', 2],
  ['org-fork-review', 3],
  ['personal-authoring', 4]
]);

const PROMOTION_RAIL_ORDER = new Map([
  ['integration', 0],
  ['shared-platform', 1],
  ['consumer-proving', 2],
  ['fork-review', 3],
  ['authoring', 4]
]);

function printUsage() {
  console.log('Usage: node tools/priority/lane-marketplace.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --registry <path>  Marketplace registry path (default: ${DEFAULT_REGISTRY_PATH})`);
  console.log(`  --output <path>    Snapshot output path (default: ${DEFAULT_MARKETPLACE_SNAPSHOT_PATH})`);
  console.log('  -h, --help         Show this help text and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    registryPath: DEFAULT_REGISTRY_PATH,
    outputPath: DEFAULT_MARKETPLACE_SNAPSHOT_PATH,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    if (arg === '--registry' || arg === '--output') {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--registry') {
        options.registryPath = value;
      } else {
        options.outputPath = value;
      }
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return options;
}

function normalizeText(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeStringArray(values) {
  const seen = new Set();
  const normalized = [];
  for (const value of Array.isArray(values) ? values : []) {
    const text = normalizeText(value)?.toLowerCase();
    if (!text || seen.has(text)) {
      continue;
    }
    seen.add(text);
    normalized.push(text);
  }
  return normalized;
}

function readRank(map, key, fallback) {
  const normalized = normalizeText(key)?.toLowerCase();
  if (!normalized) {
    return fallback;
  }
  return map.get(normalized) ?? fallback;
}

export async function loadMarketplaceRegistry(registryPath, options = {}) {
  const repoRoot = options.repoRoot ?? REPO_ROOT;
  const resolvedPath = path.resolve(repoRoot, registryPath);
  const raw = await readFile(resolvedPath, 'utf8');
  const parsed = JSON.parse(raw);
  if (parsed?.schema !== 'priority/lane-marketplace-registry@v1') {
    throw new Error(`Unsupported marketplace registry schema in ${resolvedPath}.`);
  }
  if (!Array.isArray(parsed.repositories) || parsed.repositories.length === 0) {
    throw new Error(`Marketplace registry ${resolvedPath} does not define any repositories.`);
  }

  const seenIds = new Set();
  const seenSlugs = new Set();
  const repositories = parsed.repositories.map((entry, index) => {
    const id = normalizeText(entry?.id);
    const slug = normalizeText(entry?.slug);
    const authorityTier = normalizeText(entry?.authorityTier);
    const laneClass = normalizeText(entry?.laneClass);
    const promotionRail = normalizeText(entry?.promotionRail);
    if (!id || !slug || !authorityTier || !laneClass || !promotionRail) {
      throw new Error(`Marketplace registry entry ${index} is missing a required field.`);
    }
    if (seenIds.has(id)) {
      throw new Error(`Duplicate marketplace repository id: ${id}`);
    }
    if (seenSlugs.has(slug.toLowerCase())) {
      throw new Error(`Duplicate marketplace repository slug: ${slug}`);
    }
    seenIds.add(id);
    seenSlugs.add(slug.toLowerCase());
    return {
      id,
      slug,
      authorityTier,
      laneClass,
      promotionRail,
      standingLabels: normalizeStringArray(entry?.standingLabels),
      enabled: entry?.enabled !== false,
      priorityBias: Number.isFinite(entry?.priorityBias) ? Number(entry.priorityBias) : 0
    };
  });

  return {
    path: resolvedPath,
    repositories
  };
}

function buildStandingEntryBase(entry, standingLabels) {
  return {
    id: entry.id,
    repository: entry.slug,
    authorityTier: entry.authorityTier,
    laneClass: entry.laneClass,
    promotionRail: entry.promotionRail,
    standingLabels,
    enabled: entry.enabled !== false
  };
}

export async function collectMarketplaceEntry(repoRoot, entry, options = {}) {
  const standingLabels =
    entry.standingLabels.length > 0
      ? [...entry.standingLabels]
      : resolveStandingPriorityLabels(repoRoot, entry.slug, options.env ?? process.env);
  const base = buildStandingEntryBase(entry, standingLabels);
  if (entry.enabled === false) {
    return {
      ...base,
      eligible: false,
      status: 'disabled',
      reason: 'disabled',
      message: 'Marketplace entry is disabled.',
      standing: null,
      ranking: null
    };
  }

  const standingResolution = await (options.resolveStandingPriorityForRepoFn ?? resolveStandingPriorityForRepo)(
    repoRoot,
    entry.slug,
    standingLabels,
    options.resolveOptions ?? {}
  );

  if (standingResolution?.found?.number) {
    let issueSnapshot = {
      number: standingResolution.found.number,
      url: null,
      title: null,
      labels: standingLabels
    };
    try {
      const issue = await (options.fetchIssueFn ?? fetchIssue)(
        standingResolution.found.number,
        repoRoot,
        entry.slug,
        options.fetchIssueOptions ?? {}
      );
      issueSnapshot = createSnapshot(issue);
    } catch (error) {
      issueSnapshot.fetchError = normalizeText(error?.message) || 'issue-fetch-failed';
    }

    return {
      ...base,
      eligible: true,
      status: 'standing-ready',
      reason: 'standing-ready',
      message: `Standing lane available in ${entry.slug}.`,
      standing: {
        ...issueSnapshot,
        source: standingResolution.found.source ?? null
      },
      ranking: null
    };
  }

  const classification = await (options.classifyNoStandingPriorityConditionFn ?? classifyNoStandingPriorityCondition)(
    repoRoot,
    entry.slug,
    standingLabels,
    options.classifyOptions ?? {}
  );

  return {
    ...base,
    eligible: false,
    status: normalizeText(classification?.reason) || 'error',
    reason: normalizeText(classification?.reason) || 'error',
    message: normalizeText(classification?.message) || 'Unable to classify marketplace entry.',
    openIssueCount: Number.isInteger(classification?.openIssueCount) ? classification.openIssueCount : null,
    standing: null,
    ranking: null
  };
}

export function rankMarketplaceEntries(entries) {
  const ranked = (Array.isArray(entries) ? entries : []).map((entry) => {
    const authorityRank = readRank(AUTHORITY_TIER_ORDER, entry.authorityTier, 99);
    const promotionRank = readRank(PROMOTION_RAIL_ORDER, entry.promotionRail, 99);
    const priorityBias = Number.isFinite(entry.priorityBias) ? Number(entry.priorityBias) : 0;
    const eligibleRank = entry.eligible === true ? 0 : 1;
    return {
      ...entry,
      ranking: {
        eligibleRank,
        authorityRank,
        promotionRank,
        priorityBias
      }
    };
  });

  ranked.sort((left, right) => {
    const eligibleDelta = left.ranking.eligibleRank - right.ranking.eligibleRank;
    if (eligibleDelta !== 0) return eligibleDelta;
    const authorityDelta = left.ranking.authorityRank - right.ranking.authorityRank;
    if (authorityDelta !== 0) return authorityDelta;
    const promotionDelta = left.ranking.promotionRank - right.ranking.promotionRank;
    if (promotionDelta !== 0) return promotionDelta;
    const biasDelta = left.ranking.priorityBias - right.ranking.priorityBias;
    if (biasDelta !== 0) return biasDelta;
    return left.repository.localeCompare(right.repository);
  });

  return ranked.map((entry, index) => ({
    ...entry,
    ranking: {
      ...entry.ranking,
      order: index + 1
    }
  }));
}

export async function collectMarketplaceSnapshot(options = {}) {
  const repoRoot = options.repoRoot ?? REPO_ROOT;
  const registry = options.registry ?? await loadMarketplaceRegistry(options.registryPath ?? DEFAULT_REGISTRY_PATH, { repoRoot });
  const entries = [];
  for (const repository of registry.repositories) {
    entries.push(await collectMarketplaceEntry(repoRoot, repository, options));
  }
  const rankedEntries = rankMarketplaceEntries(entries);
  const eligibleEntries = rankedEntries.filter((entry) => entry.eligible === true);
  const summary = {
    repositoryCount: rankedEntries.length,
    eligibleLaneCount: eligibleEntries.length,
    queueEmptyCount: rankedEntries.filter((entry) => entry.reason === 'queue-empty').length,
    labelMissingCount: rankedEntries.filter((entry) => entry.reason === 'label-missing').length,
    errorCount: rankedEntries.filter((entry) => entry.reason === 'error').length,
    topEligibleLane: eligibleEntries[0]
      ? {
          repository: eligibleEntries[0].repository,
          issueNumber: eligibleEntries[0].standing?.number ?? null,
          authorityTier: eligibleEntries[0].authorityTier,
          promotionRail: eligibleEntries[0].promotionRail
        }
      : null
  };

  return {
    schema: 'priority/lane-marketplace-snapshot@v1',
    generatedAt: new Date().toISOString(),
    registryPath: registry.path,
    summary,
    entries: rankedEntries
  };
}

export function selectMarketplaceRecommendation(
  snapshot,
  {
    currentRepository = null,
    requireDifferentRepository = false
  } = {}
) {
  const normalizedCurrentRepository = normalizeText(currentRepository)?.toLowerCase() || null;
  const entries = Array.isArray(snapshot?.entries) ? snapshot.entries : [];
  const selected = entries.find((entry) => {
    if (entry?.eligible !== true) {
      return false;
    }
    const repository = normalizeText(entry?.repository)?.toLowerCase() || null;
    if (requireDifferentRepository && normalizedCurrentRepository && repository === normalizedCurrentRepository) {
      return false;
    }
    return true;
  });
  if (!selected) {
    return null;
  }

  return {
    repository: selected.repository,
    issueNumber: selected.standing?.number ?? null,
    issueUrl: normalizeText(selected.standing?.url) || null,
    issueTitle: normalizeText(selected.standing?.title) || null,
    authorityTier: selected.authorityTier,
    laneClass: selected.laneClass,
    promotionRail: selected.promotionRail,
    reason: selected.reason,
    standingLabels: Array.isArray(selected.standingLabels) ? [...selected.standingLabels] : [],
    ranking: selected.ranking ?? null
  };
}

export async function writeMarketplaceSnapshot(outputPath, snapshot, repoRoot = REPO_ROOT) {
  const resolvedPath = path.resolve(repoRoot, outputPath);
  await mkdir(path.dirname(resolvedPath), { recursive: true });
  await writeFile(resolvedPath, `${JSON.stringify(snapshot, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const snapshot = await collectMarketplaceSnapshot({
    repoRoot: REPO_ROOT,
    registryPath: options.registryPath
  });
  const outputPath = await writeMarketplaceSnapshot(options.outputPath, snapshot, REPO_ROOT);
  console.log(
    `[lane-marketplace] wrote ${outputPath} top=${snapshot.summary.topEligibleLane?.repository ?? 'none'} ready=${snapshot.summary.eligibleLaneCount}`
  );
  return 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === MODULE_FILE_PATH) {
  main(process.argv).then((code) => {
    if (code !== 0) {
      process.exitCode = code;
    }
  }).catch((error) => {
    console.error(error?.stack ?? error?.message ?? String(error));
    process.exitCode = 1;
  });
}

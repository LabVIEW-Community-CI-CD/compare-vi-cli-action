#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'wake-work-synthesis.json');
export const DEFAULT_WAKE_ADJUDICATION_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'wake-adjudication.json'
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
  'issue',
  'wake-work-synthesis.json'
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

function ensureWakeAdjudicationReport(payload, filePath) {
  if (payload?.schema !== 'priority/wake-adjudication-report@v1') {
    throw new Error(`Expected wake adjudication report at ${filePath}.`);
  }
  return payload;
}

function ensureRepoGraphTruthReport(payload, filePath) {
  if (payload?.schema !== 'priority/downstream-repo-graph-truth@v1') {
    throw new Error(`Expected downstream repo graph truth report at ${filePath}.`);
  }
  return payload;
}

function ensurePolicy(payload, filePath) {
  if (payload?.schema !== 'priority/wake-work-synthesis-policy@v1') {
    throw new Error(`Expected wake work synthesis policy at ${filePath}.`);
  }
  return payload;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    policyPath: DEFAULT_POLICY_PATH,
    wakeAdjudicationPath: DEFAULT_WAKE_ADJUDICATION_PATH,
    repoGraphTruthPath: DEFAULT_REPO_GRAPH_TRUTH_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--policy', 'policyPath'],
    ['--wake-adjudication', 'wakeAdjudicationPath'],
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
    'Usage: node tools/priority/wake-work-synthesis.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>         Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --policy <path>            Work synthesis policy path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --wake-adjudication <path> Wake adjudication report path (default: ${DEFAULT_WAKE_ADJUDICATION_PATH}).`,
    `  --repo-graph-truth <path>  Repo graph truth report path (default: ${DEFAULT_REPO_GRAPH_TRUTH_PATH}).`,
    `  --output <path>            Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  -h, --help                 Show help.'
  ].forEach((line) => console.log(line));
}

function buildRoleMatches(repoGraphTruth, repository, branch) {
  const repositorySlug = asOptional(repository);
  const targetBranch = normalizeText(branch);
  if (!repositorySlug || !targetBranch) {
    return [];
  }

  const matches = [];
  for (const repositoryEntry of repoGraphTruth.repositories || []) {
    if (normalizeText(repositoryEntry.repository) !== repositorySlug) {
      continue;
    }
    for (const role of repositoryEntry.roles || []) {
      if (normalizeText(role.branch) !== targetBranch) {
        continue;
      }
      matches.push({
        repositoryId: normalizeText(repositoryEntry.id),
        repository: repositorySlug,
        repositoryKind: normalizeText(repositoryEntry.kind),
        repositoryStatus: normalizeText(repositoryEntry.status) || 'unknown',
        roleId: normalizeText(role.id),
        role: normalizeText(role.role),
        branch: normalizeText(role.branch),
        localRefAlias: asOptional(role.localRefAlias),
        required: role.required === true,
        roleStatus: normalizeText(role.status) || 'unknown',
        relationshipStatus: asOptional(role.relationship?.status)
      });
    }
  }
  return matches;
}

function selectRole(matches) {
  return (
    matches.find((entry) => entry.roleStatus === 'pass' && (entry.relationshipStatus == null || entry.relationshipStatus === 'pass')) ||
    matches.find((entry) => entry.roleStatus === 'pass') ||
    matches[0] ||
    null
  );
}

function selectFallbackRole(repoGraphTruth, repository) {
  const repositorySlug = asOptional(repository);
  if (!repositorySlug) {
    return null;
  }
  const repositoryEntry = (repoGraphTruth.repositories || []).find(
    (entry) => normalizeText(entry.repository) === repositorySlug
  );
  if (!repositoryEntry) {
    return null;
  }
  return (
    selectRole(
      (repositoryEntry.roles || []).map((role) => ({
        repositoryId: normalizeText(repositoryEntry.id),
        repository: repositorySlug,
        repositoryKind: normalizeText(repositoryEntry.kind),
        repositoryStatus: normalizeText(repositoryEntry.status) || 'unknown',
        roleId: normalizeText(role.id),
        role: normalizeText(role.role),
        branch: normalizeText(role.branch),
        localRefAlias: asOptional(role.localRefAlias),
        required: role.required === true,
        roleStatus: normalizeText(role.status) || 'unknown',
        relationshipStatus: asOptional(role.relationship?.status)
      }))
    ) || null
  );
}

function createIssueRouting(decision) {
  return {
    compareGovernanceWork: decision === 'compare-governance-work',
    templateWork: decision === 'template-work',
    consumerProvingDriftWork: decision === 'consumer-proving-drift',
    investmentWork: decision === 'investment-work'
  };
}

function determineLiveDefectDecision(policy, compareRepository, governingRole, ownerRepository) {
  if (normalizeText(governingRole?.repository) === compareRepository || normalizeText(ownerRepository) === compareRepository) {
    return policy.liveDefectRouting.compareRepositoryDecision;
  }
  if (
    normalizeText(governingRole?.repositoryKind) === 'consumer-fork' ||
    normalizeText(governingRole?.role) === 'consumer-proving-rail' ||
    normalizeText(governingRole?.role) === 'canonical-development-mirror'
  ) {
    return policy.liveDefectRouting.consumerProvingDecision;
  }
  if (asOptional(ownerRepository) || asOptional(governingRole?.repository)) {
    return policy.classificationDefaults['live-defect'].decision;
  }
  return policy.liveDefectRouting.fallbackDecision;
}

function determineWorkKind(policy, classification, decision) {
  if (classification !== 'live-defect') {
    return policy.classificationDefaults[classification].workKind;
  }
  if (decision === 'compare-governance-work') {
    return 'governance';
  }
  if (decision === 'consumer-proving-drift') {
    return 'drift-correction';
  }
  if (decision === 'investment-work') {
    return 'investment';
  }
  return policy.classificationDefaults['live-defect'].workKind;
}

function determineStatus(decision) {
  if (decision === 'suppress') {
    return 'suppressed';
  }
  if (decision === 'monitor') {
    return 'monitoring';
  }
  return 'actionable';
}

function determineOwnerRepository(policy, decision, wakeSummary, governingRole) {
  if (decision === 'compare-governance-work' || decision === 'investment-work') {
    return policy.compareRepository;
  }
  return asOptional(wakeSummary.recommendedOwnerRepository) || asOptional(governingRole?.repository);
}

export function synthesizeWakeWork(policy, wakeReport, repoGraphTruth) {
  const wakeSummary = wakeReport.summary;
  const reportedRoleMatches = buildRoleMatches(
    repoGraphTruth,
    wakeReport.reported?.downstreamRepository,
    wakeReport.reported?.targetBranch
  );
  const revalidatedRoleMatches = buildRoleMatches(
    repoGraphTruth,
    wakeReport.revalidated?.downstreamRepository,
    wakeReport.revalidated?.targetBranch
  );

  const compareRepository = normalizeText(policy.compareRepository);
  const governingRole =
    (wakeSummary.classification === 'branch-target-drift' ? selectRole(reportedRoleMatches) : null) ||
    selectRole(revalidatedRoleMatches) ||
    selectFallbackRole(repoGraphTruth, wakeSummary.recommendedOwnerRepository) ||
    selectRole(reportedRoleMatches);

  let decision = policy.classificationDefaults[wakeSummary.classification]?.decision;
  if (!decision) {
    throw new Error(`Unsupported wake classification: ${wakeSummary.classification}`);
  }

  if (wakeSummary.classification === 'live-defect') {
    decision = determineLiveDefectDecision(
      policy,
      compareRepository,
      governingRole,
      wakeSummary.recommendedOwnerRepository
    );
  }

  const workKind = determineWorkKind(policy, wakeSummary.classification, decision);
  const recommendedOwnerRepository = determineOwnerRepository(policy, decision, wakeSummary, governingRole);
  const status = determineStatus(decision);

  return {
    wake: {
      classification: wakeSummary.classification,
      status: wakeSummary.status,
      recommendedOwnerRepository: asOptional(wakeSummary.recommendedOwnerRepository),
      nextAction: normalizeText(wakeSummary.nextAction),
      reason: normalizeText(wakeSummary.reason),
      suppressIssueInjection: wakeSummary.suppressIssueInjection === true,
      suppressDownstreamIssueInjection: wakeSummary.suppressDownstreamIssueInjection === true,
      suppressTemplateIssueInjection: wakeSummary.suppressTemplateIssueInjection === true
    },
    roles: {
      reportedRoleMatches,
      revalidatedRoleMatches,
      governingRole: governingRole ?? null
    },
    summary: {
      decision,
      status,
      workKind,
      recommendedOwnerRepository,
      reason:
        decision === 'investment-work'
          ? `${normalizeText(wakeSummary.reason)} No live repo-graph role matched the wake, so the next work should improve the control plane instead of reopening the wrong repo.`
          : normalizeText(wakeSummary.reason),
      issueRouting: createIssueRouting(decision)
    }
  };
}

export async function runWakeWorkSynthesis(
  options = {},
  {
    now = new Date(),
    readJsonFn = readJson,
    writeJsonFn = writeJson
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const policyPath = path.resolve(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  const wakeAdjudicationPath = path.resolve(repoRoot, options.wakeAdjudicationPath || DEFAULT_WAKE_ADJUDICATION_PATH);
  const repoGraphTruthPath = path.resolve(repoRoot, options.repoGraphTruthPath || DEFAULT_REPO_GRAPH_TRUTH_PATH);
  const outputPath = path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH);

  const policy = ensurePolicy(readJsonFn(policyPath), policyPath);
  const wakeReport = ensureWakeAdjudicationReport(readJsonFn(wakeAdjudicationPath), wakeAdjudicationPath);
  const repoGraphTruth = ensureRepoGraphTruthReport(readJsonFn(repoGraphTruthPath), repoGraphTruthPath);

  const synthesized = synthesizeWakeWork(policy, wakeReport, repoGraphTruth);
  const report = {
    schema: 'priority/wake-work-synthesis-report@v1',
    generatedAt: now.toISOString(),
    repository: normalizeText(repoGraphTruth.repository) || normalizeText(policy.compareRepository),
    policy: {
      path: toRelative(repoRoot, policyPath),
      compareRepository: normalizeText(policy.compareRepository)
    },
    inputs: {
      wakeAdjudicationReportPath: toRelative(repoRoot, wakeAdjudicationPath),
      repoGraphTruthPath: toRelative(repoRoot, repoGraphTruthPath)
    },
    ...synthesized
  };

  const writtenPath = writeJsonFn(outputPath, report);
  return { report, outputPath: writtenPath };
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[wake-work-synthesis] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runWakeWorkSynthesis(options);
    console.log(
      `[wake-work-synthesis] wrote ${outputPath} (${report.summary.decision}, status=${report.summary.status})`
    );
    return 0;
  } catch (error) {
    console.error(`[wake-work-synthesis] ${error.message}`);
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

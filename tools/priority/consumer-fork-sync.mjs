#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'downstream-repo-graph.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'consumer-fork-sync.json'
);

function asOptional(value) {
  if (value == null) return null;
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

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    apply: false,
    help: false
  };

  const stringFlags = new Map([
    ['--repo-root', 'repoRoot'],
    ['--policy', 'policyPath'],
    ['--output', 'outputPath'],
    ['--repo', 'repo']
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--apply') {
      options.apply = true;
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
    'Usage: node tools/priority/consumer-fork-sync.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>  Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --policy <path>     Repo graph policy path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --output <path>     Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  --repo <owner/repo> Explicit supervisor repository slug.',
    '  --apply             Patch configured consumer-fork refs when fast-forward-safe.',
    '  -h, --help          Show help.'
  ].forEach((line) => console.log(line));
}

function probeBranch(repository, branch, runGhJsonFn) {
  try {
    const response = runGhJsonFn(['api', `repos/${repository}/branches/${encodeURIComponent(branch)}`]);
    return {
      status: 'pass',
      branchExists: true,
      headSha: asOptional(response?.commit?.sha)
    };
  } catch (error) {
    const message = String(error?.message || error || '');
    if (/404|not found|no branch/i.test(message)) {
      return {
        status: 'missing',
        branchExists: false,
        headSha: null
      };
    }
    return {
      status: 'unknown',
      branchExists: null,
      headSha: null,
      error: message
    };
  }
}

function compareHeads(repository, baseSha, headSha, runGhJsonFn) {
  try {
    const response = runGhJsonFn(['api', `repos/${repository}/compare/${baseSha}...${headSha}`]);
    return {
      status: asOptional(response?.status) ?? 'unknown',
      aheadBy: Number.isFinite(response?.ahead_by) ? response.ahead_by : null,
      behindBy: Number.isFinite(response?.behind_by) ? response.behind_by : null,
      totalCommits: Number.isFinite(response?.total_commits) ? response.total_commits : null,
      htmlUrl: asOptional(response?.html_url)
    };
  } catch (error) {
    return {
      status: 'unknown',
      aheadBy: null,
      behindBy: null,
      totalCommits: null,
      htmlUrl: null,
      error: String(error?.message || error || '')
    };
  }
}

function patchBranch(repository, branch, targetSha, runGhJsonFn) {
  return runGhJsonFn([
    'api',
    '-X',
    'PATCH',
    `repos/${repository}/git/refs/heads/${encodeURIComponent(branch)}`,
    '-f',
    `sha=${targetSha}`,
    '-F',
    'force=false'
  ]);
}

function summarizeTargets(targets, apply) {
  const syncedCount = targets.filter((entry) => entry.status === 'synced').length;
  const syncReadyCount = targets.filter((entry) => entry.status === 'sync-ready').length;
  const noopCount = targets.filter((entry) => entry.status === 'noop').length;
  const blockedCount = targets.filter((entry) => entry.status === 'blocked').length;
  const unknownCount = targets.filter((entry) => entry.status === 'unknown').length;
  const status =
    blockedCount > 0
      ? 'fail'
      : unknownCount > 0
        ? 'unknown'
        : !apply && syncReadyCount > 0
          ? 'pending'
          : 'pass';

  return {
    status,
    targetCount: targets.length,
    syncedCount,
    syncReadyCount,
    noopCount,
    blockedCount,
    unknownCount
  };
}

export async function runConsumerForkSync(
  options,
  {
    now = new Date(),
    readJsonFn = readJson,
    writeJsonFn = writeJson,
    runGhJsonFn = runGhJson
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const policyPath = path.resolve(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  const policy = readJsonFn(policyPath);
  if (policy?.schema !== 'priority/downstream-repo-graph-policy@v1') {
    throw new Error('Downstream repo graph policy schema mismatch.');
  }

  const repositoryIndex = new Map();
  const roleIndex = new Map();
  for (const repository of policy.repositories ?? []) {
    repositoryIndex.set(repository.id, repository);
    for (const role of repository.roles ?? []) {
      roleIndex.set(role.id, {
        repositoryId: repository.id,
        repository: repository.repository,
        repositoryKind: repository.kind,
        role
      });
    }
  }

  const targets = [];
  for (const repository of policy.repositories ?? []) {
    if (repository.kind !== 'consumer-fork') {
      continue;
    }
    for (const role of repository.roles ?? []) {
      if (role.role !== 'canonical-development-mirror' || role.syncPolicy !== 'fast-forward-only') {
        continue;
      }

      const tracked = role.tracksRoleId ? roleIndex.get(role.tracksRoleId) : null;
      const currentProbe = probeBranch(repository.repository, role.branch, runGhJsonFn);
      const trackedProbe = tracked
        ? probeBranch(tracked.repository, tracked.role.branch, runGhJsonFn)
        : { status: 'unknown', branchExists: null, headSha: null };

      const target = {
        repository: repository.repository,
        repositoryKind: repository.kind,
        roleId: role.id,
        role: role.role,
        branch: role.branch,
        syncPolicy: role.syncPolicy,
        status: 'unknown',
        reason: 'evaluation-pending',
        currentHeadSha: currentProbe.headSha,
        trackedRoleId: role.tracksRoleId ?? null,
        trackedRepository: tracked?.repository ?? null,
        trackedRepositoryKind: tracked?.repositoryKind ?? null,
        trackedBranch: tracked?.role?.branch ?? null,
        trackedHeadSha: trackedProbe.headSha,
        compare: null,
        patch: null
      };

      if (!tracked) {
        target.status = 'blocked';
        target.reason = 'tracked-role-unavailable';
        targets.push(target);
        continue;
      }

      if (!currentProbe.headSha || !trackedProbe.headSha) {
        target.status = currentProbe.status === 'unknown' || trackedProbe.status === 'unknown' ? 'unknown' : 'blocked';
        target.reason = !currentProbe.headSha && !trackedProbe.headSha ? 'branch-missing-both' : 'branch-missing';
        targets.push(target);
        continue;
      }

      if (currentProbe.headSha === trackedProbe.headSha) {
        target.status = 'noop';
        target.reason = 'already-aligned';
        target.compare = {
          status: 'identical',
          aheadBy: 0,
          behindBy: 0,
          totalCommits: 0,
          htmlUrl: null
        };
        targets.push(target);
        continue;
      }

      const compare = compareHeads(tracked.repository, currentProbe.headSha, trackedProbe.headSha, runGhJsonFn);
      target.compare = compare;

      if (compare.status === 'identical') {
        target.status = 'noop';
        target.reason = 'already-aligned';
        targets.push(target);
        continue;
      }

      if (compare.status === 'ahead') {
        if (!options.apply) {
          target.status = 'sync-ready';
          target.reason = 'fast-forward-ready';
          targets.push(target);
          continue;
        }

        try {
          const patchResult = patchBranch(repository.repository, role.branch, trackedProbe.headSha, runGhJsonFn);
          target.status = 'synced';
          target.reason = 'fast-forward-applied';
          target.patch = {
            ref: asOptional(patchResult?.ref),
            resultingSha: asOptional(patchResult?.object?.sha) ?? trackedProbe.headSha
          };
        } catch (error) {
          target.status = 'blocked';
          target.reason = 'patch-failed';
          target.patch = {
            error: String(error?.message || error || '')
          };
        }
        targets.push(target);
        continue;
      }

      if (compare.status === 'behind') {
        target.status = 'blocked';
        target.reason = 'mirror-ahead-of-tracked';
        targets.push(target);
        continue;
      }

      if (compare.status === 'diverged') {
        target.status = 'blocked';
        target.reason = 'diverged-history';
        targets.push(target);
        continue;
      }

      target.status = 'unknown';
      target.reason = 'compare-unavailable';
      targets.push(target);
    }
  }

  const report = {
    schema: 'priority/consumer-fork-sync-report@v1',
    generatedAt: now.toISOString(),
    repository: asOptional(options.repo) ?? policy.compareRepository,
    mode: options.apply ? 'apply' : 'dry-run',
    policy: {
      path: toRelative(repoRoot, policyPath),
      compareRepository: policy.compareRepository
    },
    targets,
    summary: summarizeTargets(targets, options.apply)
  };

  const outputPath = writeJsonFn(path.resolve(repoRoot, options.outputPath || DEFAULT_OUTPUT_PATH), report);
  return { report, outputPath };
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[consumer-fork-sync] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runConsumerForkSync(options);
    console.log(
      `[consumer-fork-sync] wrote ${outputPath} (${report.summary.status}, targets=${report.summary.targetCount})`
    );
    return report.summary.status === 'fail' || report.summary.status === 'unknown' ? 1 : 0;
  } catch (error) {
    console.error(`[consumer-fork-sync] ${error.message}`);
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

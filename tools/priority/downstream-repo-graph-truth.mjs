#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'downstream-repo-graph.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'downstream-repo-graph-truth.json'
);

function asOptional(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function toRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, path.resolve(targetPath)).replace(/\\/g, '/');
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) return null;
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo, execSyncFn = execSync) {
  if (asOptional(explicitRepo)?.includes('/')) return asOptional(explicitRepo);
  if (asOptional(process.env.GITHUB_REPOSITORY)?.includes('/')) return asOptional(process.env.GITHUB_REPOSITORY);
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSyncFn(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) return slug;
    } catch {
      // ignore
    }
  }
  return null;
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
    'Usage: node tools/priority/downstream-repo-graph-truth.mjs [options]',
    '',
    'Options:',
    `  --repo-root <path>  Repository root override (default: ${DEFAULT_REPO_ROOT}).`,
    `  --policy <path>     Repo graph policy path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --output <path>     Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  --repo <owner/repo> Explicit compare repository slug.',
    '  -h, --help          Show help.'
  ].forEach((line) => console.log(line));
}

function isMissingBranchError(error) {
  const message = String(error?.message || error || '');
  return /404|not found|no branch/i.test(message);
}

function probeBranch(repository, branch, runGhJsonFn) {
  try {
    const response = runGhJsonFn(['api', `repos/${repository}/branches/${branch}`]);
    return {
      status: 'pass',
      branchExists: true,
      headSha: asOptional(response?.commit?.sha)
    };
  } catch (error) {
    if (isMissingBranchError(error)) {
      return {
        status: 'missing',
        branchExists: false,
        headSha: null
      };
    }
    return {
      status: 'unknown',
      branchExists: null,
      headSha: null
    };
  }
}

function summarizeRepository(roles) {
  const requiredMissingRoleCount = roles.filter((entry) => entry.required && entry.status === 'missing').length;
  const optionalMissingRoleCount = roles.filter((entry) => !entry.required && entry.status === 'missing').length;
  const alignmentFailureCount = roles.filter((entry) => entry.relationship?.status === 'fail').length;
  const unknownRoleCount = roles.filter(
    (entry) => entry.status === 'unknown' || (entry.status !== 'missing' && entry.relationship?.status === 'unknown')
  ).length;
  const status =
    requiredMissingRoleCount > 0 || roles.some((entry) => entry.status === 'fail') || alignmentFailureCount > 0
      ? 'fail'
      : unknownRoleCount > 0
        ? 'unknown'
        : 'pass';

  return {
    status,
    requiredMissingRoleCount,
    optionalMissingRoleCount,
    alignmentFailureCount,
    unknownRoleCount
  };
}

export async function runDownstreamRepoGraphTruth(
  options,
  {
    now = new Date(),
    resolveRepoSlugFn = resolveRepoSlug,
    readJsonFn = readJson,
    writeJsonFn = writeJson,
    runGhJsonFn = runGhJson
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || DEFAULT_REPO_ROOT);
  const repository = resolveRepoSlugFn(options.repo) || null;
  const policyPath = path.resolve(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  const policy = readJsonFn(policyPath);
  if (policy?.schema !== 'priority/downstream-repo-graph-policy@v1') {
    throw new Error('Downstream repo graph policy schema mismatch.');
  }

  const roleMap = new Map();
  const repositories = policy.repositories.map((entry) => {
    const roles = entry.roles.map((role) => {
      const branchProbe = probeBranch(entry.repository, role.branch, runGhJsonFn);
      const roleTruth = {
        id: role.id,
        role: role.role,
        branch: role.branch,
        localRefAlias: asOptional(role.localRefAlias),
        required: role.required === true,
        status: branchProbe.status,
        branchExists: branchProbe.branchExists,
        headSha: branchProbe.headSha,
        relationship: null
      };
      roleMap.set(role.id, roleTruth);
      return roleTruth;
    });

    return {
      id: entry.id,
      repository: entry.repository,
      kind: entry.kind,
      status: 'unknown',
      roles,
      summary: {
        requiredMissingRoleCount: 0,
        optionalMissingRoleCount: 0,
        alignmentFailureCount: 0,
        unknownRoleCount: 0
      }
    };
  });

  for (const entry of policy.repositories) {
    const repositoryTruth = repositories.find((candidate) => candidate.id === entry.id);
    for (const role of entry.roles) {
      if (!role.tracksRoleId) {
        continue;
      }
      const roleTruth = repositoryTruth.roles.find((candidate) => candidate.id === role.id);
      const trackedRole = roleMap.get(role.tracksRoleId);
      let status = 'unknown';
      let reason = 'tracked-role-unavailable';
      if (trackedRole) {
        if (trackedRole.headSha && roleTruth.headSha) {
          status = trackedRole.headSha === roleTruth.headSha ? 'pass' : 'fail';
          reason = trackedRole.headSha === roleTruth.headSha ? 'head-sha-match' : 'head-sha-mismatch';
        } else if (trackedRole.status === 'missing' || roleTruth.status === 'missing') {
          status = 'unknown';
          reason = 'branch-missing';
        }
      }
      roleTruth.relationship = {
        tracksRoleId: role.tracksRoleId,
        status,
        trackedHeadSha: trackedRole?.headSha ?? null,
        reason
      };
    }
  }

  for (const repositoryTruth of repositories) {
    const { status: repositoryStatus, ...summary } = summarizeRepository(repositoryTruth.roles);
    repositoryTruth.summary = summary;
    repositoryTruth.status = repositoryStatus;
  }

  const roleCount = repositories.reduce((total, entry) => total + entry.roles.length, 0);
  const requiredMissingRoleCount = repositories.reduce(
    (total, entry) => total + entry.summary.requiredMissingRoleCount,
    0
  );
  const optionalMissingRoleCount = repositories.reduce(
    (total, entry) => total + entry.summary.optionalMissingRoleCount,
    0
  );
  const alignmentFailureCount = repositories.reduce(
    (total, entry) => total + entry.summary.alignmentFailureCount,
    0
  );
  const unknownRoleCount = repositories.reduce(
    (total, entry) => total + entry.summary.unknownRoleCount,
    0
  );
  const status =
    requiredMissingRoleCount > 0 || alignmentFailureCount > 0 || repositories.some((entry) => entry.status === 'fail')
      ? 'fail'
      : unknownRoleCount > 0
        ? 'unknown'
        : 'pass';

  const report = {
    schema: 'priority/downstream-repo-graph-truth@v1',
    generatedAt: now.toISOString(),
    repository: repository ?? policy.compareRepository,
    policy: {
      path: toRelative(repoRoot, policyPath),
      compareRepository: policy.compareRepository
    },
    repositories,
    summary: {
      status,
      repositoryCount: repositories.length,
      roleCount,
      requiredMissingRoleCount,
      optionalMissingRoleCount,
      alignmentFailureCount,
      unknownRoleCount
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
    console.error(`[downstream-repo-graph-truth] ${error.message}`);
    printHelp();
    return 1;
  }

  if (options.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runDownstreamRepoGraphTruth(options);
    console.log(
      `[downstream-repo-graph-truth] wrote ${outputPath} (${report.summary.status}, roles=${report.summary.roleCount})`
    );
    return 0;
  } catch (error) {
    console.error(`[downstream-repo-graph-truth] ${error.message}`);
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

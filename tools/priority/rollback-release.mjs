#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ensureCleanWorkingTree, getRepoRoot, run } from './lib/branch-utils.mjs';
import { ensureGhCli, resolveUpstream, tryResolveRemote } from './lib/remote-utils.mjs';
import {
  DEFAULT_RELEASE_ROLLBACK_POLICY_PATH,
  loadReleaseRollbackPolicy,
  getReleaseRollbackStreamPolicy
} from './lib/release-rollback-policy.mjs';

export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'rollback-report.json'
);

const USAGE_LINES = [
  'Usage: node tools/npm/run-script.mjs release:rollback [options]',
  '',
  'Resolve a previous-good release pointer for a stream and optionally rollback branch tips to that tag.',
  '',
  'Options:',
  '  --stream <stable|rc|lts>         Stream pointer to use (default: stable).',
  '  --repo <owner/repo>              Repository slug (default: upstream/GITHUB_REPOSITORY).',
  `  --policy <path>                  Rollback policy path (default: ${DEFAULT_RELEASE_ROLLBACK_POLICY_PATH}).`,
  `  --report <path>                  Report path (default: ${DEFAULT_REPORT_PATH}).`,
  '  --target-tag <tag>               Explicit rollback tag override (default: previous-good).',
  '  --remote <name>                  Git remote for branch rollback (default: policy rollback.remote).',
  '  --main-branch <name>             Mainline branch name (default: main).',
  '  --develop-branch <name>          Develop branch name (default: develop).',
  '  --max-releases <n>               Max release records to inspect (default: 50).',
  '  --apply                          Apply rollback (default: dry-run planning only).',
  '  --sync-origin                    Mirror rollback to origin remote after upstream apply.',
  '  --skip-policy-sync               Skip post-apply policy sync validation.',
  '  -h, --help                       Show this message and exit.'
];

function printUsage() {
  for (const line of USAGE_LINES) {
    console.log(line);
  }
}

function addFailure(failures, code, message) {
  failures.push({ code, message });
}

function truncateOutput(text, maxLength = 800) {
  const raw = String(text || '').trim();
  if (raw.length <= maxLength) {
    return raw;
  }
  return `${raw.slice(0, maxLength)}...`;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    stream: 'stable',
    repo: null,
    policyPath: DEFAULT_RELEASE_ROLLBACK_POLICY_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    targetTag: null,
    remote: null,
    mainBranch: 'main',
    developBranch: 'develop',
    maxReleases: 50,
    apply: false,
    syncOrigin: false,
    skipPolicySync: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (token === '--apply') {
      options.apply = true;
      continue;
    }

    if (token === '--sync-origin') {
      options.syncOrigin = true;
      continue;
    }

    if (token === '--skip-policy-sync') {
      options.skipPolicySync = true;
      continue;
    }

    if (
      token === '--stream' ||
      token === '--repo' ||
      token === '--policy' ||
      token === '--report' ||
      token === '--target-tag' ||
      token === '--remote' ||
      token === '--main-branch' ||
      token === '--develop-branch' ||
      token === '--max-releases'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--stream') options.stream = String(next).trim();
      if (token === '--repo') options.repo = String(next).trim();
      if (token === '--policy') options.policyPath = String(next).trim();
      if (token === '--report') options.reportPath = String(next).trim();
      if (token === '--target-tag') options.targetTag = String(next).trim();
      if (token === '--remote') options.remote = String(next).trim();
      if (token === '--main-branch') options.mainBranch = String(next).trim();
      if (token === '--develop-branch') options.developBranch = String(next).trim();
      if (token === '--max-releases') {
        const parsed = Number.parseInt(String(next), 10);
        if (!Number.isFinite(parsed) || parsed < 2) {
          throw new Error(`Invalid value for --max-releases: ${next}`);
        }
        options.maxReleases = parsed;
      }
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export function normalizeReleaseRecord(raw) {
  const source = raw && typeof raw === 'object' ? raw : {};
  return {
    tag: String(source.tag_name ?? source.tagName ?? '').trim(),
    isDraft: Boolean(source.draft ?? source.isDraft),
    isPrerelease: Boolean(source.prerelease ?? source.isPrerelease),
    publishedAt: source.published_at ?? source.publishedAt ?? null,
    targetCommitish: source.target_commitish ?? source.targetCommitish ?? null,
    url: source.html_url ?? source.url ?? null
  };
}

export function filterReleasesForStream(releases, streamPolicy) {
  const matcher = new RegExp(streamPolicy.tagPattern, 'i');
  return releases
    .map((release) => normalizeReleaseRecord(release))
    .filter((release) => release.tag && !release.isDraft && matcher.test(release.tag))
    .sort((left, right) => {
      const leftTime = left.publishedAt ? Date.parse(left.publishedAt) : 0;
      const rightTime = right.publishedAt ? Date.parse(right.publishedAt) : 0;
      return rightTime - leftTime;
    });
}

export function resolveRollbackPointer({ streamReleases, streamPolicy, targetTag = null }) {
  if (targetTag) {
    const explicit = streamReleases.find((release) => release.tag === targetTag);
    if (!explicit) {
      throw new Error(`Explicit target tag ${targetTag} not found in stream release set.`);
    }
    return {
      strategy: 'explicit-tag',
      current: streamReleases[0] ?? null,
      target: explicit
    };
  }

  if (streamReleases.length < streamPolicy.minimumHistory) {
    throw new Error(
      `Insufficient release history for stream (required=${streamPolicy.minimumHistory}, found=${streamReleases.length}).`
    );
  }

  return {
    strategy: 'previous-good-release-tag',
    current: streamReleases[0],
    target: streamReleases[1]
  };
}

function runGhApiJson(args, repoRoot) {
  const result = spawnSync('gh', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const detail = truncateOutput(result.stderr || result.stdout || '');
    throw new Error(`gh ${args.join(' ')} failed: ${detail || `exit-${result.status}`}`);
  }
  try {
    return JSON.parse(result.stdout || 'null');
  } catch (error) {
    throw new Error(`Failed to parse gh JSON output: ${error.message}`);
  }
}

function resolveRepositorySlug(explicitRepo, repoRoot) {
  if (explicitRepo && explicitRepo.includes('/')) {
    return explicitRepo;
  }
  const envRepo = String(process.env.GITHUB_REPOSITORY || '').trim();
  if (envRepo && envRepo.includes('/')) {
    return envRepo;
  }
  const upstream = resolveUpstream(repoRoot);
  return `${upstream.owner}/${upstream.repo}`;
}

function toRepositorySlug(parsedRemote) {
  if (!parsedRemote?.owner || !parsedRemote?.repo) {
    return null;
  }
  return `${parsedRemote.owner}/${parsedRemote.repo}`.toLowerCase();
}

export function resolveRollbackRemoteName({
  repoRoot,
  preferredRemote,
  repository,
  tryResolveRemoteFn = tryResolveRemote
}) {
  const configuredRemote = String(preferredRemote || 'upstream').trim() || 'upstream';
  const configured = tryResolveRemoteFn(repoRoot, configuredRemote);
  if (configured?.parsed) {
    return {
      configuredRemote,
      effectiveRemote: configuredRemote,
      fallbackReason: null
    };
  }

  const repositorySlug = String(repository || '').trim().toLowerCase();
  const origin = configuredRemote === 'origin' ? configured : tryResolveRemoteFn(repoRoot, 'origin');
  const originSlug = toRepositorySlug(origin?.parsed);
  if (originSlug && repositorySlug && originSlug === repositorySlug) {
    return {
      configuredRemote,
      effectiveRemote: 'origin',
      fallbackReason: `Configured rollback remote '${configuredRemote}' is missing; using origin because it matches ${repository}.`
    };
  }

  throw new Error(
    `Rollback remote '${configuredRemote}' is not configured and origin does not match repository '${repository || '<unknown>'}'.`
  );
}

function fetchReleaseRecords(repoRoot, repository, maxReleases) {
  const perPage = Math.min(100, Math.max(2, maxReleases));
  const payload = runGhApiJson(
    ['api', '-H', 'Accept: application/vnd.github+json', `repos/${repository}/releases?per_page=${perPage}`],
    repoRoot
  );
  if (!Array.isArray(payload)) {
    throw new Error('Unexpected GitHub release API payload.');
  }
  return payload;
}

function tryResolveRef(repoRoot, ref) {
  const result = spawnSync('git', ['rev-parse', ref], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    return null;
  }
  return String(result.stdout || '').trim() || null;
}

function forcePushBranch(repoRoot, remote, branch, targetCommit, leaseCommit) {
  if (!leaseCommit) {
    throw new Error(`Unable to resolve remote lease commit for ${remote}/${branch}.`);
  }
  run(
    'git',
    [
      'push',
      `--force-with-lease=${branch}:${leaseCommit}`,
      remote,
      `${targetCommit}:refs/heads/${branch}`
    ],
    { cwd: repoRoot }
  );
}

function fetchRemoteRefs(repoRoot, remote, branches) {
  run('git', ['fetch', remote, '--tags', '--prune'], { cwd: repoRoot });
  run('git', ['fetch', remote, ...branches], { cwd: repoRoot });
}

function resolveTagCommit(repoRoot, tag) {
  const commit = run('git', ['rev-list', '-n', '1', tag], { cwd: repoRoot });
  if (!commit) {
    throw new Error(`Tag ${tag} does not resolve to a commit.`);
  }
  return commit;
}

function runPolicySync(repoRoot) {
  const result = spawnSync('node', ['tools/npm/run-script.mjs', 'priority:policy:sync'], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return {
    executed: true,
    status: result.status === 0 ? 'pass' : 'fail',
    exitCode: Number.isInteger(result.status) ? result.status : 1,
    stdout: truncateOutput(result.stdout || ''),
    stderr: truncateOutput(result.stderr || '')
  };
}

function appendStepSummary(report, reportPath) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (!summaryPath) {
    return;
  }

  const lines = [
    '### Release Rollback',
    `- Mode: \`${report.mode}\``,
    `- Stream: \`${report.stream}\``,
    `- Target tag: \`${report.pointer.targetTag || 'n/a'}\``,
    `- Target commit: \`${report.target.commit || 'n/a'}\``,
    `- Status: \`${report.summary.status}\``,
    `- Failures: \`${report.summary.failureCount}\``,
    `- Report: \`${reportPath}\``
  ];
  if (report.failures.length > 0) {
    lines.push('', '| Code | Message |', '| --- | --- |');
    for (const failure of report.failures) {
      lines.push(`| \`${failure.code}\` | ${failure.message.replace(/\|/g, '\\|')} |`);
    }
  }
  fs.appendFileSync(summaryPath, `${lines.join('\n')}\n`, 'utf8');
}

export function evaluateRollbackValidation(branches, targetCommit, policySyncResult = null) {
  const failures = [];
  for (const branch of branches) {
    if (!branch.matchesTarget) {
      addFailure(
        failures,
        'branch-not-at-target',
        `${branch.remote}/${branch.name} expected ${targetCommit} but found ${branch.after || '<missing>'}.`
      );
    }
  }

  if (policySyncResult?.executed && policySyncResult.status !== 'pass') {
    addFailure(
      failures,
      'policy-sync-failed',
      `priority:policy:sync exited with code ${policySyncResult.exitCode}.`
    );
  }

  return {
    status: failures.length === 0 ? 'pass' : 'fail',
    failures
  };
}

function writeJsonReport(reportPath, report) {
  const resolved = path.resolve(reportPath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runRollback(options, dependencies = {}) {
  const repoRoot = dependencies.repoRoot || getRepoRoot();
  const generatedAt = (dependencies.now instanceof Date ? dependencies.now : new Date()).toISOString();
  const policy = dependencies.policy || loadReleaseRollbackPolicy(options.policyPath);
  const streamPolicy = getReleaseRollbackStreamPolicy(policy, options.stream);
  const repository = resolveRepositorySlug(options.repo, repoRoot);
  const remoteResolver =
    dependencies.remoteResolver ||
    ((args) => resolveRollbackRemoteName({ ...args, tryResolveRemoteFn: dependencies.tryResolveRemote || tryResolveRemote }));
  const rollbackRemoteResolution = remoteResolver({
    repoRoot,
    preferredRemote: options.remote || policy.rollback.remote || 'upstream',
    repository
  });
  const rollbackRemote = rollbackRemoteResolution.effectiveRemote;
  const targetBranches = [options.mainBranch, options.developBranch];

  const failures = [];

  const releaseFetcher =
    dependencies.fetchReleaseRecords ||
    ((repo, max) => fetchReleaseRecords(repoRoot, repo, max));
  const releaseRecords = releaseFetcher(repository, options.maxReleases);
  const streamReleases = filterReleasesForStream(releaseRecords, streamPolicy);
  const pointer = resolveRollbackPointer({
    streamReleases,
    streamPolicy,
    targetTag: options.targetTag
  });

  const fetchRemoteRefsFn = dependencies.fetchRemoteRefs || fetchRemoteRefs;
  const resolveTagCommitFn = dependencies.resolveTagCommit || resolveTagCommit;
  const tryResolveRefFn = dependencies.tryResolveRef || tryResolveRef;
  const forcePushBranchFn = dependencies.forcePushBranch || forcePushBranch;

  fetchRemoteRefsFn(repoRoot, rollbackRemote, targetBranches);
  const targetCommit = resolveTagCommitFn(repoRoot, pointer.target.tag);

  const branches = targetBranches.map((name) => ({
    name,
    remote: rollbackRemote,
    before: tryResolveRefFn(repoRoot, `${rollbackRemote}/${name}`),
    after: null,
    pushed: false,
    matchesTarget: false
  }));

  if (options.apply) {
    for (const branch of branches) {
      forcePushBranchFn(repoRoot, rollbackRemote, branch.name, targetCommit, branch.before);
      branch.pushed = true;
    }
    fetchRemoteRefsFn(repoRoot, rollbackRemote, targetBranches);
  }

  for (const branch of branches) {
    branch.after = tryResolveRefFn(repoRoot, `${rollbackRemote}/${branch.name}`);
    branch.matchesTarget = options.apply ? branch.after === targetCommit : false;
  }

  let originSync = null;
  if (options.apply && options.syncOrigin) {
    const originBranches = targetBranches.map((name) => ({
      name,
      remote: 'origin',
      before: tryResolveRef(repoRoot, `origin/${name}`),
      after: null,
      pushed: false,
      matchesTarget: false
    }));
    for (const branch of originBranches) {
      if (!branch.before) {
        addFailure(failures, 'origin-branch-missing', `origin/${branch.name} does not exist for sync-origin.`);
        continue;
      }
      forcePushBranchFn(repoRoot, 'origin', branch.name, targetCommit, branch.before);
      branch.pushed = true;
    }
    fetchRemoteRefsFn(repoRoot, 'origin', targetBranches);
    for (const branch of originBranches) {
      branch.after = tryResolveRefFn(repoRoot, `origin/${branch.name}`);
      branch.matchesTarget = branch.after === targetCommit;
    }
    originSync = originBranches;
  }

  let policySyncResult = {
    executed: false,
    status: 'skipped',
    exitCode: 0,
    stdout: '',
    stderr: ''
  };
  if (options.apply && !options.skipPolicySync) {
    const executor = dependencies.policySync || (() => runPolicySync(repoRoot));
    policySyncResult = executor();
  }

  const validation = options.apply
    ? evaluateRollbackValidation(branches, targetCommit, policySyncResult)
    : {
      status: 'pass',
      failures: []
    };

  failures.push(...validation.failures);
  if (originSync) {
    for (const branch of originSync) {
      if (branch.pushed && !branch.matchesTarget) {
        addFailure(
          failures,
          'origin-sync-mismatch',
          `origin/${branch.name} expected ${targetCommit} but found ${branch.after || '<missing>'}.`
        );
      }
    }
  }

  const summaryStatus = failures.length === 0 ? 'pass' : 'fail';
  return {
    schema: 'release/rollback@v1',
    generatedAt,
    repository,
    stream: options.stream,
    mode: options.apply ? 'apply' : 'dry-run',
    policy: {
      path: options.policyPath,
      schema: policy.schema,
      configuredRemote: rollbackRemoteResolution.configuredRemote,
      remote: rollbackRemote,
      remoteFallbackReason: rollbackRemoteResolution.fallbackReason,
      targetBranches,
      minimumHistory: streamPolicy.minimumHistory
    },
    pointer: {
      strategy: pointer.strategy,
      immutable: true,
      currentTag: pointer.current?.tag ?? null,
      currentPublishedAt: pointer.current?.publishedAt ?? null,
      currentUrl: pointer.current?.url ?? null,
      targetTag: pointer.target.tag,
      targetPublishedAt: pointer.target.publishedAt ?? null,
      targetUrl: pointer.target.url ?? null
    },
    target: {
      tag: pointer.target.tag,
      commit: targetCommit
    },
    branches,
    originSync,
    validation: {
      status: validation.status,
      policySync: policySyncResult
    },
    failures,
    summary: {
      status: summaryStatus,
      failureCount: failures.length,
      failureCodes: [...new Set(failures.map((failure) => failure.code))].sort(),
      shouldPausePromotion: summaryStatus !== 'pass'
    }
  };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  if (!['stable', 'rc', 'lts'].includes(options.stream)) {
    throw new Error(`Unsupported stream: ${options.stream}`);
  }

  if (options.apply) {
    ensureCleanWorkingTree(run, 'Working tree not clean. Commit or stash changes before running rollback apply.');
  }

  ensureGhCli();
  const report = await runRollback(options);
  const outputPath = writeJsonReport(options.reportPath, report);
  appendStepSummary(report, options.reportPath);
  console.log(
    `[release:rollback] wrote ${outputPath} (mode=${report.mode}, target=${report.target.tag}, status=${report.summary.status})`
  );
  return report.summary.status === 'pass' ? 0 : 1;
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
      const message = error?.stack || error?.message || String(error);
      let reportPath = DEFAULT_REPORT_PATH;
      try {
        const parsed = parseArgs(process.argv);
        reportPath = parsed.reportPath || reportPath;
      } catch {
        // ignore parse fallback
      }
      const fallback = {
        schema: 'release/rollback@v1',
        generatedAt: new Date().toISOString(),
        mode: 'error',
        failures: [{ code: 'execution-error', message }],
        summary: {
          status: 'fail',
          failureCount: 1,
          failureCodes: ['execution-error'],
          shouldPausePromotion: true
        }
      };
      try {
        writeJsonReport(reportPath, fallback);
      } catch {
        // ignore write fallback errors
      }
      console.error(message);
      process.exitCode = 1;
    });
}

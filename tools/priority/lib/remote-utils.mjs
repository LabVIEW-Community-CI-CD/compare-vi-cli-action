#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { run } from './branch-utils.mjs';

const DEFAULT_GH_OPTIONS = {
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'pipe']
};
const DEFAULT_FORK_REMOTE = 'origin';
const SUPPORTED_FORK_REMOTES = new Set(['origin', 'personal']);

export function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = url.match(/:(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const httpsMatch = url.match(/github\.com\/(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) {
    return null;
  }
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return { owner, repo };
}

export function parseRepositorySlug(value) {
  const trimmed = String(value || '').trim();
  if (!trimmed.includes('/')) {
    throw new Error(`Invalid repository slug '${value}'. Expected <owner>/<repo>.`);
  }

  const [owner, repo] = trimmed.split('/', 2);
  if (!owner || !repo) {
    throw new Error(`Invalid repository slug '${value}'. Expected <owner>/<repo>.`);
  }

  return { owner, repo };
}

export function normalizeForkRemoteName(value, { fallback = DEFAULT_FORK_REMOTE } = {}) {
  const normalized = String(value ?? '').trim().toLowerCase();
  if (!normalized) {
    return fallback;
  }
  if (!SUPPORTED_FORK_REMOTES.has(normalized)) {
    throw new Error(
      `Unsupported fork remote '${value}'. Expected one of: ${Array.from(SUPPORTED_FORK_REMOTES).join(', ')}.`
    );
  }
  return normalized;
}

export function resolveActiveForkRemoteName(env = process.env, { fallback = DEFAULT_FORK_REMOTE } = {}) {
  return normalizeForkRemoteName(env.AGENT_PRIORITY_ACTIVE_FORK_REMOTE, { fallback });
}

export function buildRepositorySlug(repository) {
  if (!repository?.owner || !repository?.repo) {
    return null;
  }
  return `${repository.owner}/${repository.repo}`;
}

function requireRepositorySlug(repository, label) {
  const repoSlug = buildRepositorySlug(repository);
  if (!repoSlug) {
    throw new Error(`Invalid ${label} repository coordinates. Expected owner and repo.`);
  }
  return repoSlug;
}

function normalizePrText(value, { label, allowEmpty = false } = {}) {
  if (value === null || value === undefined) {
    if (allowEmpty) {
      return '';
    }
    throw new Error(`${label} is required.`);
  }
  const text = String(value);
  if (!allowEmpty && text.trim().length === 0) {
    throw new Error(`${label} is required.`);
  }
  return text;
}

export function isSameRepository(left, right) {
  const leftSlug = buildRepositorySlug(left);
  const rightSlug = buildRepositorySlug(right);
  return leftSlug !== null && leftSlug === rightSlug;
}

export function isSameOwnerForkRepository(origin, upstream) {
  return Boolean(
    origin?.owner &&
      origin?.repo &&
      upstream?.owner &&
      upstream?.repo &&
      origin.owner === upstream.owner &&
      origin.repo !== upstream.repo
  );
}

export function isRepositoryForkOfUpstream(metadata, upstream) {
  const upstreamSlug = buildRepositorySlug(upstream);
  if (!upstreamSlug || !metadata) {
    return false;
  }

  const isFork = metadata.isFork === true || metadata.fork === true;
  const parentSlug = String(metadata.parentNameWithOwner ?? metadata.parent?.nameWithOwner ?? '').trim();
  const sourceSlug = String(metadata.sourceNameWithOwner ?? metadata.source?.nameWithOwner ?? '').trim();
  return isFork && (parentSlug === upstreamSlug || sourceSlug === upstreamSlug);
}

export function tryResolveRemote(repoRoot, remoteName) {
  try {
    const url = run('git', ['config', '--get', `remote.${remoteName}.url`], { cwd: repoRoot });
    return { url, parsed: parseRemoteUrl(url) };
  } catch {
    return null;
  }
}

export function ensureGhCli({ spawnSyncFn = spawnSync } = {}) {
  const result = spawnSyncFn('gh', ['--version'], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error('GitHub CLI (gh) not found. Install gh and authenticate first.');
  }
}

function sanitizeGhArgs(args) {
  const sensitiveFlags = new Set(['--title', '--body']);
  const sanitized = [];
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    sanitized.push(value);
    if (sensitiveFlags.has(value) && index + 1 < args.length) {
      sanitized.push(`<redacted:${value.slice(2)}>`);
      index += 1;
    }
  }
  return sanitized;
}

function buildGhCommandError(args, result, fallbackMessage) {
  const stderr = String(result?.stderr ?? '').trim();
  const stdout = String(result?.stdout ?? '').trim();
  const diagnostic = stderr || stdout || fallbackMessage;
  return `gh ${sanitizeGhArgs(args).join(' ')} failed: ${diagnostic}`;
}

export function runGhJson(repoRoot, args, { spawnSyncFn = spawnSync } = {}) {
  const result = spawnSyncFn('gh', args, {
    cwd: repoRoot,
    ...DEFAULT_GH_OPTIONS
  });
  if (result.status !== 0) {
    throw new Error(buildGhCommandError(args, result, `exit ${result.status}`));
  }

  const text = String(result.stdout ?? '').trim();
  return text ? JSON.parse(text) : null;
}

export function buildGraphqlArgs(query, variables = {}) {
  const args = ['api', 'graphql', '-f', `query=${query}`];
  for (const [key, value] of Object.entries(variables)) {
    if (value == null) {
      continue;
    }
    const flag =
      typeof value === 'boolean' ||
      typeof value === 'number' ||
      typeof value === 'bigint'
        ? '-F'
        : '-f';
    args.push(flag, `${key}=${String(value)}`);
  }
  return args;
}

export function runGhGraphql(repoRoot, query, variables = {}, { spawnSyncFn = spawnSync } = {}) {
  return runGhJson(repoRoot, buildGraphqlArgs(query, variables), { spawnSyncFn });
}

export function loadRepositoryGraphMetadata(
  repoRoot,
  repository,
  {
    runGhGraphqlFn = runGhGraphql,
    spawnSyncFn = spawnSync
  } = {}
) {
  const query = `
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        id
        nameWithOwner
        isFork
        parent { nameWithOwner }
      }
    }
  `;

  const payload = runGhGraphqlFn(
    repoRoot,
    query,
    {
      owner: repository.owner,
      repo: repository.repo
    },
    { spawnSyncFn }
  );
  const repoNode = payload?.data?.repository;
  if (!repoNode?.id) {
    throw new Error(`Unable to resolve repository metadata for ${buildRepositorySlug(repository)}.`);
  }

  return {
    id: repoNode.id,
    nameWithOwner: repoNode.nameWithOwner ?? buildRepositorySlug(repository),
    isFork: repoNode.isFork === true,
    parentNameWithOwner: repoNode.parent?.nameWithOwner ?? null
  };
}

export function resolveUpstream(repoRoot) {
  const upstream = tryResolveRemote(repoRoot, 'upstream');
  if (upstream?.parsed) {
    return upstream.parsed;
  }

  const envRepo = process.env.GITHUB_REPOSITORY;
  if (envRepo && envRepo.includes('/')) {
    return parseRepositorySlug(envRepo);
  }

  throw new Error(
    'Unable to determine upstream repository. Configure a remote named "upstream" or set GITHUB_REPOSITORY.'
  );
}

export function ensureForkRemote(
  repoRoot,
  upstream,
  remoteName = DEFAULT_FORK_REMOTE,
  {
    tryResolveRemoteFn = tryResolveRemote,
    spawnSyncFn = spawnSync,
    loadRepositoryGraphMetadataFn = loadRepositoryGraphMetadata
  } = {}
) {
  const selectedRemote = normalizeForkRemoteName(remoteName);
  let remote = tryResolveRemoteFn(repoRoot, selectedRemote);

  if (!remote?.parsed || isSameRepository(remote.parsed, upstream)) {
    if (selectedRemote !== DEFAULT_FORK_REMOTE) {
      throw new Error(
        `Fork remote '${selectedRemote}' is missing or points to upstream. Configure that remote before opening a PR from it.`
      );
    }
    console.log(`[priority] ${selectedRemote} remote missing or points to upstream. Creating fork via gh...`);
    const args = [
      'repo',
      'fork',
      `${upstream.owner}/${upstream.repo}`,
      '--remote',
      '--remote-name',
      selectedRemote
    ];
    const forkResult = spawnSyncFn('gh', args, {
      cwd: repoRoot,
      stdio: 'inherit',
      encoding: 'utf8'
    });
    if (forkResult.status !== 0) {
      throw new Error(`Failed to fork repository or set ${selectedRemote} remote.`);
    }
    remote = tryResolveRemoteFn(repoRoot, selectedRemote);
  }

  if (!remote?.parsed) {
    throw new Error(`Unable to determine ${selectedRemote} remote after attempting to configure it.`);
  }

  if (isSameRepository(remote.parsed, upstream)) {
    throw new Error(
      `${selectedRemote} remote still points to upstream after attempting to configure it. Confirm you have permission and rerun.`
    );
  }

  if (isSameOwnerForkRepository(remote.parsed, upstream)) {
    const metadata = loadRepositoryGraphMetadataFn(repoRoot, remote.parsed, { spawnSyncFn });
    if (!isRepositoryForkOfUpstream(metadata, upstream)) {
      throw new Error(
        `${selectedRemote} remote ${buildRepositorySlug(remote.parsed)} shares the upstream owner but is not a fork of ${buildRepositorySlug(upstream)}.`
      );
    }

    return {
      ...remote.parsed,
      remoteName: selectedRemote,
      sameOwnerFork: true,
      repositoryId: metadata.id
    };
  }

  return {
    ...remote.parsed,
    remoteName: selectedRemote,
    sameOwnerFork: false,
    repositoryId: null
  };
}

export function ensureOriginFork(repoRoot, upstream, options = {}) {
  return ensureForkRemote(repoRoot, upstream, DEFAULT_FORK_REMOTE, options);
}

export function remoteBranchExists(repoRoot, remote, branch, { runFn = run } = {}) {
  try {
    const output = runFn('git', ['ls-remote', '--heads', remote, branch], {
      cwd: repoRoot
    });
    return Boolean(String(output || '').trim());
  } catch {
    return false;
  }
}

export function getRemoteBranchHead(repoRoot, remote, branch, { runFn = run } = {}) {
  try {
    const output = runFn('git', ['ls-remote', '--heads', remote, branch], {
      cwd: repoRoot
    });
    const firstLine = String(output || '').trim().split(/\r?\n/, 1)[0] ?? '';
    const [sha] = firstLine.split(/\s+/);
    return sha ? sha.trim() : null;
  } catch {
    return null;
  }
}

export function getLocalBranchHead(repoRoot, branch, { runFn = run } = {}) {
  try {
    const output = runFn('git', ['rev-parse', branch], {
      cwd: repoRoot
    });
    return String(output || '').trim() || null;
  } catch {
    return null;
  }
}

export function pushBranch(
  repoRoot,
  branch,
  remote = DEFAULT_FORK_REMOTE,
  {
    runFn = run,
    getRemoteBranchHeadFn = getRemoteBranchHead,
    getLocalBranchHeadFn = getLocalBranchHead
  } = {}
) {
  const selectedRemote = normalizeForkRemoteName(remote);
  const localHead = getLocalBranchHeadFn(repoRoot, branch, { runFn });
  const remoteHeadBeforePush = getRemoteBranchHeadFn(repoRoot, selectedRemote, branch, { runFn });
  try {
    runFn('git', ['push', '--set-upstream', selectedRemote, branch], {
      cwd: repoRoot
    });
    if (localHead && remoteHeadBeforePush && remoteHeadBeforePush === localHead) {
      return {
        status: 'already-published',
        remote: selectedRemote,
        branch,
        recoveredFromPushFailure: false
      };
    }
    return {
      status: 'pushed',
      remote: selectedRemote,
      branch
    };
  } catch (error) {
    const remoteHead = getRemoteBranchHeadFn(repoRoot, selectedRemote, branch, { runFn });
    if (remoteHead && localHead && remoteHead === localHead) {
      return {
        status: 'already-published',
        remote: selectedRemote,
        branch,
        recoveredFromPushFailure: true
      };
    }
    const cause = String(error?.stderr ?? error?.message ?? error ?? '').trim();
    const detail = cause ? ` ${cause}` : '';
    throw new Error(`Failed to push branch to ${selectedRemote}.${detail}`);
  }
}

export function pushToRemote(repoRoot, remote, ref) {
  try {
    run('git', ['push', remote, ref], {
      cwd: repoRoot
    });
  } catch {
    throw new Error(`Failed to push ${ref} to ${remote}. Resolve the push error above.`);
  }
}

export function buildGhPrCreateArgs({ upstream, origin, headRepository, branch, base, title, body, draft = false }) {
  const resolvedHeadRepository = headRepository ?? origin;
  const repoSlug = requireRepositorySlug(upstream, 'upstream');
  return [
    'pr',
    'create',
    '--repo',
    repoSlug,
    '--base',
    base,
    '--head',
    `${resolvedHeadRepository.owner}:${branch}`,
    ...(draft ? ['--draft'] : []),
    '--title',
    normalizePrText(title, { label: 'PR title' }),
    '--body',
    normalizePrText(body, { label: 'PR body', allowEmpty: true })
  ];
}

export function buildGhPrEditArgs({ upstream, pullRequest, title, body }) {
  const repoSlug = requireRepositorySlug(upstream, 'upstream');
  const pullRequestNumber = Number.parseInt(String(pullRequest?.number ?? ''), 10);
  if (!Number.isInteger(pullRequestNumber) || pullRequestNumber <= 0) {
    throw new Error('Existing pull request number is required.');
  }
  return [
    'pr',
    'edit',
    String(pullRequestNumber),
    '--repo',
    repoSlug,
    '--title',
    normalizePrText(title, { label: 'PR title' }),
    '--body',
    normalizePrText(body, { label: 'PR body', allowEmpty: true })
  ];
}

export function buildGhPrListArgs({ upstream, branch, base, head, state = 'open' }) {
  return [
    'pr',
    'list',
    '--repo',
    buildRepositorySlug(upstream),
    '--state',
    state,
    '--base',
    base,
    '--head',
    head ?? branch,
    '--json',
    'number,url,state,isDraft,headRefName,baseRefName,headRepositoryOwner,isCrossRepository'
  ];
}

export function selectPullRequestCreateStrategy({ upstream, origin, headRepository }) {
  const resolvedHeadRepository = headRepository ?? origin;
  if (
    resolvedHeadRepository?.sameOwnerFork ||
    isSameOwnerForkRepository(resolvedHeadRepository, upstream)
  ) {
    return 'graphql-same-owner-fork';
  }

  return 'gh-pr-create';
}

export function buildCreatePullRequestMutation({
  repositoryId,
  headRepositoryId,
  headRefName,
  baseRefName,
  title,
  body,
  draft = true
}) {
  return {
    query: `
      mutation(
        $repositoryId: ID!,
        $headRepositoryId: ID,
        $headRefName: String!,
        $baseRefName: String!,
        $draft: Boolean!,
        $title: String!,
        $body: String!
      ) {
        createPullRequest(
          input: {
            repositoryId: $repositoryId,
            headRepositoryId: $headRepositoryId,
            headRefName: $headRefName,
            baseRefName: $baseRefName,
            draft: $draft,
            title: $title,
            body: $body,
            maintainerCanModify: true
          }
        ) {
          pullRequest {
            number
            url
          }
        }
      }
    `,
    variables: {
      repositoryId,
      headRepositoryId,
      headRefName,
      baseRefName,
      draft: draft === true,
      title,
      body
    }
  };
}

export function buildSameOwnerForkHeadRefCandidates(origin, branch) {
  return [branch, `${origin.owner}:${branch}`];
}

export function extractPullRequestFromMutation(payload) {
  return payload?.data?.createPullRequest?.pullRequest ?? null;
}

export function isExistingPullRequestError(error) {
  return /a pull request already exists/i.test(String(error?.message ?? error ?? ''));
}

export function findExistingPullRequest(
  repoRoot,
  { upstream, origin, headRepository, branch, base },
  {
    runGhJsonFn = runGhJson,
    spawnSyncFn = spawnSync
  } = {}
) {
  const resolvedHeadRepository = headRepository ?? origin;
  const expectedOwner = String(resolvedHeadRepository?.owner ?? '')
    .trim()
    .toLowerCase();
  const headSelectors = Array.from(
    new Set([
      expectedOwner ? `${resolvedHeadRepository.owner}:${branch}` : null,
      branch
    ].filter(Boolean))
  );
  const pulls = [];
  for (const headSelector of headSelectors) {
    const response =
      runGhJsonFn(repoRoot, buildGhPrListArgs({ upstream, branch, base, head: headSelector }), {
        spawnSyncFn
      }) ?? [];
    if (Array.isArray(response) && response.length > 0) {
      pulls.push(...response);
      break;
    }
  }
  if (pulls.length === 0) {
    return null;
  }

  return (
    pulls.find((pull) => {
      const headRefName = String(pull?.headRefName ?? '').trim();
      const baseRefName = String(pull?.baseRefName ?? '').trim();
      const headOwner = String(pull?.headRepositoryOwner?.login ?? '')
        .trim()
        .toLowerCase();

      if (headRefName !== branch || baseRefName !== base) {
        return false;
      }
      if (!expectedOwner) {
        return true;
      }
      return headOwner === expectedOwner;
    }) ?? null
  );
}

export function findMergedPullRequest(
  repoRoot,
  { upstream, origin, headRepository, branch, base },
  {
    runGhJsonFn = runGhJson,
    spawnSyncFn = spawnSync
  } = {}
) {
  const resolvedHeadRepository = headRepository ?? origin;
  const expectedOwner = String(resolvedHeadRepository?.owner ?? '')
    .trim()
    .toLowerCase();
  const headSelectors = Array.from(
    new Set([
      expectedOwner ? `${resolvedHeadRepository.owner}:${branch}` : null,
      branch
    ].filter(Boolean))
  );
  const pulls = [];
  for (const headSelector of headSelectors) {
    const response =
      runGhJsonFn(repoRoot, buildGhPrListArgs({ upstream, branch, base, head: headSelector, state: 'merged' }), {
        spawnSyncFn
      }) ?? [];
    if (Array.isArray(response) && response.length > 0) {
      pulls.push(...response);
      break;
    }
  }
  if (pulls.length === 0) {
    return null;
  }

  return (
    pulls.find((pull) => {
      const headRefName = String(pull?.headRefName ?? '').trim();
      const baseRefName = String(pull?.baseRefName ?? '').trim();
      const headOwner = String(pull?.headRepositoryOwner?.login ?? '')
        .trim()
        .toLowerCase();
      const state = String(pull?.state ?? '').trim().toUpperCase();

      if (headRefName !== branch || baseRefName !== base) {
        return false;
      }
      if (state && state !== 'MERGED') {
        return false;
      }
      if (!expectedOwner) {
        return true;
      }
      return headOwner === expectedOwner;
    }) ?? null
  );
}

function isGitAncestor(repoRoot, ancestor, descendant, { spawnSyncFn = spawnSync } = {}) {
  const result = spawnSyncFn('git', ['merge-base', '--is-ancestor', ancestor, descendant], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  return result.status === 0;
}

function getGitCommitDistance(repoRoot, ancestor, descendant, { spawnSyncFn = spawnSync } = {}) {
  const result = spawnSyncFn('git', ['rev-list', '--count', `${ancestor}..${descendant}`], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  if (result.status !== 0) {
    return Number.POSITIVE_INFINITY;
  }

  const parsed = Number.parseInt(String(result.stdout ?? '').trim(), 10);
  return Number.isFinite(parsed) ? parsed : Number.POSITIVE_INFINITY;
}

export function findOpenAncestorPullRequest(
  repoRoot,
  { upstream, origin, headRepository, branch, base, headSha },
  {
    runGhJsonFn = runGhJson,
    spawnSyncFn = spawnSync,
    limit = 100
  } = {}
) {
  const resolvedHeadRepository = headRepository ?? origin;
  const expectedOwner = String(resolvedHeadRepository?.owner ?? '')
    .trim()
    .toLowerCase();
  const normalizedHeadSha = String(headSha ?? '').trim();
  if (!normalizedHeadSha) {
    return null;
  }

  const pulls =
    runGhJsonFn(
      repoRoot,
      [
        'pr',
        'list',
        '--repo',
        buildRepositorySlug(upstream),
        '--state',
        'open',
        '--base',
        base,
        '--limit',
        String(limit),
        '--json',
        'number,url,state,isDraft,headRefName,baseRefName,headRepositoryOwner,isCrossRepository,headRefOid,mergeStateStatus'
      ],
      {
        spawnSyncFn
      }
    ) ?? [];
  if (!Array.isArray(pulls) || pulls.length === 0) {
    return null;
  }

  const candidates = pulls
    .map((pull) => {
      const headRefName = String(pull?.headRefName ?? '').trim();
      const baseRefName = String(pull?.baseRefName ?? '').trim();
      const headOwner = String(pull?.headRepositoryOwner?.login ?? '')
        .trim()
        .toLowerCase();
      const candidateHeadSha = String(pull?.headRefOid ?? '').trim();

      if (!headRefName || headRefName === branch || baseRefName !== base || !candidateHeadSha) {
        return null;
      }
      if (expectedOwner && headOwner !== expectedOwner) {
        return null;
      }
      if (!isGitAncestor(repoRoot, candidateHeadSha, normalizedHeadSha, { spawnSyncFn })) {
        return null;
      }

      return {
        ...pull,
        stackDistance: getGitCommitDistance(repoRoot, candidateHeadSha, normalizedHeadSha, { spawnSyncFn })
      };
    })
    .filter(Boolean)
    .sort((left, right) => {
      if (left.stackDistance !== right.stackDistance) {
        return left.stackDistance - right.stackDistance;
      }
      return Number(left.number ?? Number.MAX_SAFE_INTEGER) - Number(right.number ?? Number.MAX_SAFE_INTEGER);
    });

  return candidates[0] ?? null;
}

export function runGhPrCreate(
  { repoRoot, upstream, origin, headRepository, branch, base, title, body, draft = null },
  {
    spawnSyncFn = spawnSync,
    loadRepositoryGraphMetadataFn = loadRepositoryGraphMetadata,
    runGhGraphqlFn = runGhGraphql,
    runGhJsonFn = runGhJson,
    findExistingPullRequestFn = findExistingPullRequest,
    updateExistingPullRequestFn = updateExistingPullRequest,
    writeStdoutFn = (text) => process.stdout.write(text),
    writeStderrFn = (text) => process.stderr.write(text)
  } = {}
) {
  const resolvedHeadRepository = headRepository ?? origin;
  const strategy = selectPullRequestCreateStrategy({ upstream, headRepository: resolvedHeadRepository });
  const createAsDraft = draft === true || strategy === 'graphql-same-owner-fork';

  if (strategy === 'graphql-same-owner-fork') {
    const upstreamMetadata = loadRepositoryGraphMetadataFn(repoRoot, upstream, {
      spawnSyncFn,
      runGhGraphqlFn
    });
    const originMetadata =
      resolvedHeadRepository?.repositoryId && resolvedHeadRepository?.sameOwnerFork
        ? { id: resolvedHeadRepository.repositoryId }
        : loadRepositoryGraphMetadataFn(repoRoot, resolvedHeadRepository, {
          spawnSyncFn,
          runGhGraphqlFn
        });
    const failures = [];

    for (const headRefName of buildSameOwnerForkHeadRefCandidates(resolvedHeadRepository, branch)) {
      try {
        const request = buildCreatePullRequestMutation({
          repositoryId: upstreamMetadata.id,
          headRepositoryId: originMetadata.id,
          headRefName,
          baseRefName: base,
          draft: createAsDraft,
          title,
          body
        });
        const payload = runGhGraphqlFn(repoRoot, request.query, request.variables, { spawnSyncFn });
        const pullRequest = extractPullRequestFromMutation(payload);
        if (!pullRequest?.url) {
          throw new Error(`GitHub GraphQL mutation returned no pull request URL for head '${headRefName}'.`);
        }

        writeStdoutFn(`${pullRequest.url}\n`);
        return {
          strategy,
          pullRequest: {
            ...pullRequest,
            isDraft: createAsDraft
          }
        };
      } catch (error) {
        if (isExistingPullRequestError(error)) {
          const pullRequest = findExistingPullRequestFn(
            repoRoot,
            {
              upstream,
              origin,
              headRepository: resolvedHeadRepository,
              branch,
              base
            },
            {
              runGhJsonFn,
              spawnSyncFn
            }
          );
          if (pullRequest?.url) {
            const updateResult = tryUpdateExistingPullRequest(
              repoRoot,
              {
                upstream,
                pullRequest,
                title,
                body
              },
              {
                updateExistingPullRequestFn,
                writeStderrFn,
                spawnSyncFn
              }
            );
            writeStdoutFn(`${pullRequest.url}\n`);
            return {
              strategy,
              pullRequest,
              reusedExisting: true,
              updateWarning: updateResult.warning
            };
          }
        }
        failures.push({ headRefName, error });
      }
    }

    const details = failures
      .map((entry) => `[${entry.headRefName}] ${entry.error.message}`)
      .join(' ');
    throw new Error(`Failed to create PR for same-owner fork via GraphQL. ${details}`);
  }

  const args = buildGhPrCreateArgs({
    upstream,
    headRepository: resolvedHeadRepository,
    branch,
    base,
    title,
    body,
    draft: createAsDraft
  });
  const result = spawnSyncFn('gh', args, {
    cwd: repoRoot,
    ...DEFAULT_GH_OPTIONS
  });
  if (result.status !== 0) {
    const error = new Error(buildGhCommandError(args, result, `exit ${result.status}`));
    if (isExistingPullRequestError(error)) {
      const pullRequest = findExistingPullRequestFn(
        repoRoot,
        {
          upstream,
          origin,
          headRepository: resolvedHeadRepository,
          branch,
          base
        },
        {
          runGhJsonFn,
          spawnSyncFn
        }
      );
      if (pullRequest?.url) {
        const updateResult = tryUpdateExistingPullRequest(
          repoRoot,
          {
            upstream,
            pullRequest,
            title,
            body
          },
          {
            updateExistingPullRequestFn,
            writeStderrFn,
            spawnSyncFn
          }
        );
        writeStdoutFn(`${pullRequest.url}\n`);
        return {
          strategy,
          pullRequest,
          reusedExisting: true,
          updateWarning: updateResult.warning
        };
      }
    }
    throw error;
  }

  const stdout = String(result.stdout ?? '');
  if (stdout) {
    writeStdoutFn(stdout);
  }

  const urlMatch = stdout.match(/https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/(?<number>\d+)/);
  const pullRequest = urlMatch?.[0]
    ? {
        number: Number.parseInt(urlMatch.groups.number, 10),
        url: urlMatch[0],
        isDraft: createAsDraft
      }
    : null;

  return {
    strategy,
    pullRequest
  };
}

export function updateExistingPullRequest(
  repoRoot,
  { upstream, pullRequest, title, body },
  {
    spawnSyncFn = spawnSync
  } = {}
) {
  const args = buildGhPrEditArgs({ upstream, pullRequest, title, body });
  const result = spawnSyncFn('gh', args, {
    cwd: repoRoot,
    ...DEFAULT_GH_OPTIONS
  });
  if (result.status !== 0) {
    throw new Error(buildGhCommandError(args, result, `exit ${result.status}`));
  }
}

function tryUpdateExistingPullRequest(
  repoRoot,
  { upstream, pullRequest, title, body },
  {
    updateExistingPullRequestFn = updateExistingPullRequest,
    writeStderrFn = (text) => process.stderr.write(text),
    spawnSyncFn = spawnSync
  } = {}
) {
  try {
    updateExistingPullRequestFn(
      repoRoot,
      {
        upstream,
        pullRequest,
        title,
        body
      },
      {
        spawnSyncFn
      }
    );
    return {
      updated: true,
      warning: null
    };
  } catch (error) {
    const message = String(error?.message ?? error ?? '').trim() || 'unknown update error';
    writeStderrFn(`Warning: Failed to update existing pull request ${pullRequest?.url ?? '<unknown>'}: ${message}\n`);
    return {
      updated: false,
      warning: message
    };
  }
}

#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { run } from './branch-utils.mjs';

const DEFAULT_GH_OPTIONS = {
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'pipe']
};

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

export function buildRepositorySlug(repository) {
  if (!repository?.owner || !repository?.repo) {
    return null;
  }
  return `${repository.owner}/${repository.repo}`;
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

function buildGhCommandError(args, result, fallbackMessage) {
  const stderr = String(result?.stderr ?? '').trim();
  const stdout = String(result?.stdout ?? '').trim();
  const diagnostic = stderr || stdout || fallbackMessage;
  return `gh ${args.join(' ')} failed: ${diagnostic}`;
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
    args.push('-f', `${key}=${String(value)}`);
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
        source { nameWithOwner }
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
    parentNameWithOwner: repoNode.parent?.nameWithOwner ?? null,
    sourceNameWithOwner: repoNode.source?.nameWithOwner ?? null
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

export function ensureOriginFork(
  repoRoot,
  upstream,
  {
    tryResolveRemoteFn = tryResolveRemote,
    spawnSyncFn = spawnSync,
    loadRepositoryGraphMetadataFn = loadRepositoryGraphMetadata
  } = {}
) {
  let origin = tryResolveRemoteFn(repoRoot, 'origin');

  if (!origin?.parsed || isSameRepository(origin.parsed, upstream)) {
    console.log('[priority] origin remote missing or points to upstream. Creating fork via gh...');
    const args = [
      'repo',
      'fork',
      `${upstream.owner}/${upstream.repo}`,
      '--remote',
      '--remote-name',
      'origin'
    ];
    const forkResult = spawnSyncFn('gh', args, {
      cwd: repoRoot,
      stdio: 'inherit',
      encoding: 'utf8'
    });
    if (forkResult.status !== 0) {
      throw new Error('Failed to fork repository or set origin remote.');
    }
    origin = tryResolveRemoteFn(repoRoot, 'origin');
  }

  if (!origin?.parsed) {
    throw new Error('Unable to determine origin remote after attempting to fork.');
  }

  if (isSameRepository(origin.parsed, upstream)) {
    throw new Error(
      'Origin remote still points to upstream after attempting to fork. Confirm you have permission and rerun.'
    );
  }

  if (isSameOwnerForkRepository(origin.parsed, upstream)) {
    const metadata = loadRepositoryGraphMetadataFn(repoRoot, origin.parsed, { spawnSyncFn });
    if (!isRepositoryForkOfUpstream(metadata, upstream)) {
      throw new Error(
        `Origin remote ${buildRepositorySlug(origin.parsed)} shares the upstream owner but is not a fork of ${buildRepositorySlug(upstream)}.`
      );
    }

    return {
      ...origin.parsed,
      sameOwnerFork: true,
      repositoryId: metadata.id
    };
  }

  return {
    ...origin.parsed,
    sameOwnerFork: false,
    repositoryId: null
  };
}

export function pushBranch(repoRoot, branch) {
  try {
    run('git', ['push', '--set-upstream', 'origin', branch], {
      cwd: repoRoot
    });
  } catch {
    throw new Error('Failed to push branch to origin. Resolve the push error above.');
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

export function buildGhPrCreateArgs({ upstream, origin, branch, base, title, body }) {
  return [
    'pr',
    'create',
    '--repo',
    buildRepositorySlug(upstream),
    '--base',
    base,
    '--head',
    `${origin.owner}:${branch}`,
    '--title',
    title,
    '--body',
    body
  ];
}

export function selectPullRequestCreateStrategy({ upstream, origin }) {
  if (origin?.sameOwnerFork || isSameOwnerForkRepository(origin, upstream)) {
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
  body
}) {
  return {
    query: `
      mutation(
        $repositoryId: ID!,
        $headRepositoryId: ID,
        $headRefName: String!,
        $baseRefName: String!,
        $title: String!,
        $body: String!
      ) {
        createPullRequest(
          input: {
            repositoryId: $repositoryId,
            headRepositoryId: $headRepositoryId,
            headRefName: $headRefName,
            baseRefName: $baseRefName,
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

export function runGhPrCreate(
  { repoRoot, upstream, origin, branch, base, title, body },
  {
    spawnSyncFn = spawnSync,
    loadRepositoryGraphMetadataFn = loadRepositoryGraphMetadata,
    runGhGraphqlFn = runGhGraphql
  } = {}
) {
  const strategy = selectPullRequestCreateStrategy({ upstream, origin });

  if (strategy === 'graphql-same-owner-fork') {
    const upstreamMetadata = loadRepositoryGraphMetadataFn(repoRoot, upstream, {
      spawnSyncFn,
      runGhGraphqlFn
    });
    const originMetadata =
      origin?.repositoryId && origin?.sameOwnerFork
        ? { id: origin.repositoryId }
        : loadRepositoryGraphMetadataFn(repoRoot, origin, {
          spawnSyncFn,
          runGhGraphqlFn
        });
    const failures = [];

    for (const headRefName of buildSameOwnerForkHeadRefCandidates(origin, branch)) {
      try {
        const request = buildCreatePullRequestMutation({
          repositoryId: upstreamMetadata.id,
          headRepositoryId: originMetadata.id,
          headRefName,
          baseRefName: base,
          title,
          body
        });
        const payload = runGhGraphqlFn(repoRoot, request.query, request.variables, { spawnSyncFn });
        const pullRequest = extractPullRequestFromMutation(payload);
        if (!pullRequest?.url) {
          throw new Error(`GitHub GraphQL mutation returned no pull request URL for head '${headRefName}'.`);
        }

        console.log(pullRequest.url);
        return {
          strategy,
          pullRequest
        };
      } catch (error) {
        failures.push({ headRefName, error });
      }
    }

    const details = failures
      .map((entry) => `[${entry.headRefName}] ${entry.error.message}`)
      .join(' ');
    throw new Error(`Failed to create PR for same-owner fork via GraphQL. ${details}`);
  }

  const args = buildGhPrCreateArgs({ upstream, origin, branch, base, title, body });
  const result = spawnSyncFn('gh', args, {
    cwd: repoRoot,
    stdio: 'inherit',
    encoding: 'utf8'
  });
  if (result.status !== 0) {
    throw new Error('gh pr create failed. Review the messages above.');
  }

  return {
    strategy,
    pullRequest: null
  };
}

#!/usr/bin/env node

import process from 'node:process';
import { resolveUpstream, tryResolveRemote } from './remote-utils.mjs';

function parseEnvRepository(env) {
  const slug = env.GITHUB_REPOSITORY ?? '';
  if (slug.includes('/')) {
    const [owner, repo] = slug.split('/', 2);
    if (owner && repo) {
      return { owner, repo };
    }
  }

  const owner = env.GITHUB_REPOSITORY_OWNER ?? '';
  const repo = env.GITHUB_REPOSITORY_NAME ?? env.GITHUB_REPOSITORY?.split('/')?.[1] ?? null;
  if (owner && repo) {
    return { owner, repo };
  }

  return null;
}

export function resolveRepoContext(repoRoot, options = {}) {
  const {
    resolveUpstreamFn = resolveUpstream,
    resolveRemoteFn = tryResolveRemote,
    env = process.env
  } = options;

  const upstream = resolveUpstreamFn(repoRoot);
  const upstreamRemote = resolveRemoteFn(repoRoot, 'upstream');
  const originRemote = resolveRemoteFn(repoRoot, 'origin');
  const envRepo = parseEnvRepository(env);

  const origin = originRemote?.parsed ?? null;
  const upstreamSlug = upstreamRemote?.parsed ?? upstream ?? null;

  const working = origin ?? envRepo ?? upstreamSlug;

  const isFork =
    Boolean(working?.owner) &&
    Boolean(upstream?.owner) &&
    working.owner.toLowerCase() !== upstream.owner.toLowerCase();

  return {
    upstream,
    upstreamRemote: upstreamRemote?.parsed ?? null,
    origin,
    working,
    isFork
  };
}


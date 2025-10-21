#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { run } from './branch-utils.mjs';

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

export function tryResolveRemote(repoRoot, remoteName) {
  try {
    const url = run('git', ['config', '--get', `remote.${remoteName}.url`], { cwd: repoRoot });
    return { url, parsed: parseRemoteUrl(url) };
  } catch {
    return null;
  }
}

export function ensureGhCli() {
  const result = spawnSync('gh', ['--version'], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error('GitHub CLI (gh) not found. Install gh and authenticate first.');
  }
}

export function resolveUpstream(repoRoot) {
  const upstream = tryResolveRemote(repoRoot, 'upstream');
  if (upstream?.parsed) {
    return upstream.parsed;
  }

  const envRepo = process.env.GITHUB_REPOSITORY;
  if (envRepo && envRepo.includes('/')) {
    const [owner, repo] = envRepo.split('/');
    return { owner, repo };
  }

  throw new Error(
    'Unable to determine upstream repository. Configure a remote named "upstream" or set GITHUB_REPOSITORY.'
  );
}

export function ensureOriginFork(repoRoot, upstream) {
  let origin = tryResolveRemote(repoRoot, 'origin');

  if (!origin?.parsed || origin.parsed.owner === upstream.owner) {
    console.log('[priority] origin remote missing or points to upstream. Creating fork via gh...');
    const args = [
      'repo',
      'fork',
      `${upstream.owner}/${upstream.repo}`,
      '--remote',
      '--remote-name',
      'origin'
    ];
    const forkResult = spawnSync('gh', args, {
      cwd: repoRoot,
      stdio: 'inherit',
      encoding: 'utf8'
    });
    if (forkResult.status !== 0) {
      throw new Error('Failed to fork repository or set origin remote.');
    }
    origin = tryResolveRemote(repoRoot, 'origin');
  }

  if (!origin?.parsed) {
    throw new Error('Unable to determine origin remote after attempting to fork.');
  }

  if (origin.parsed.owner === upstream.owner) {
    throw new Error(
      'Origin remote still points to upstream after attempting to fork. Confirm you have permission and rerun.'
    );
  }

  return origin.parsed;
}

export function pushBranch(repoRoot, branch) {
  const pushResult = spawnSync(
    'git',
    ['push', '--set-upstream', 'origin', branch],
    {
      cwd: repoRoot,
      stdio: 'inherit',
      encoding: 'utf8'
    }
  );
  if (pushResult.status !== 0) {
    throw new Error('Failed to push branch to origin. Resolve the push error above.');
  }
}

export function pushToRemote(repoRoot, remote, ref) {
  const result = spawnSync('git', ['push', remote, ref], {
    cwd: repoRoot,
    stdio: 'inherit',
    encoding: 'utf8'
  });
  if (result.status !== 0) {
    throw new Error(`Failed to push ${ref} to ${remote}. Resolve the push error above.`);
  }
}

export function runGhPrCreate({ upstream, origin, branch, base, title, body }) {
  const args = [
    'pr',
    'create',
    '--repo',
    `${upstream.owner}/${upstream.repo}`,
    '--base',
    base,
    '--head',
    `${origin.owner}:${branch}`,
    '--title',
    title,
    '--body',
    body
  ];

  const result = spawnSync('gh', args, { stdio: 'inherit', encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error('gh pr create failed. Review the messages above.');
  }
}

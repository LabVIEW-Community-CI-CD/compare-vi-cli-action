#!/usr/bin/env node

import path from 'node:path';
import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  run,
  ensureCleanWorkingTree,
  ensureBranchExists,
  ensureBranchDoesNotExist,
  getCurrentBranch,
  getRepoRoot
} from './lib/branch-utils.mjs';
import { ensureGhCli } from './lib/remote-utils.mjs';
import { resolveRepoContext } from './lib/git-context.mjs';

const USAGE = [
  'Usage: node tools/priority/rename-issue-branch.mjs --issue <number> [options]',
  '',
  'Renames the current (or specified) branch to issue/<number>-<slug>, pushes the new name',
  'to any remotes that carried the old branch, retargets the matching pull request, and',
  'optionally deletes the old remote branch.',
  '',
  'Options:',
  '  --issue <number>        Issue number supplying the target branch prefix (required)',
  '  --branch <name>         Branch to rename (defaults to the current branch)',
  '  --slug <value>          Override the slug derived from the issue title',
  '  --keep-remote           Do not delete the old branch name from remotes',
  '  --skip-pr               Do not retarget any open pull request',
  '  --help                  Show this message and exit'
];

function printUsage() {
  for (const line of USAGE) {
    console.log(line);
  }
}

export function parseArgs(argv) {
  const args = Array.isArray(argv) ? argv.slice(2) : [];
  const result = {
    issue: null,
    branch: null,
    slugOverride: null,
    keepRemote: false,
    skipPr: false,
    help: false
  };

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--help' || arg === '-h') {
      result.help = true;
      return result;
    }
    if (arg === '--issue') {
      if (i + 1 >= args.length) {
        throw new Error('--issue requires a value');
      }
      result.issue = Number(args[i + 1]);
      if (!Number.isInteger(result.issue) || result.issue <= 0) {
        throw new Error('Issue number must be a positive integer.');
      }
      i += 1;
      continue;
    }
    if (arg === '--branch') {
      if (i + 1 >= args.length) {
        throw new Error('--branch requires a value');
      }
      result.branch = args[i + 1];
      i += 1;
      continue;
    }
    if (arg === '--slug') {
      if (i + 1 >= args.length) {
        throw new Error('--slug requires a value');
      }
      result.slugOverride = args[i + 1];
      i += 1;
      continue;
    }
    if (arg === '--keep-remote') {
      result.keepRemote = true;
      continue;
    }
    if (arg === '--skip-pr') {
      result.skipPr = true;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return result;
}

export function sanitizeSlug(source) {
  if (!source) return 'work';
  const ascii = source
    .normalize('NFKD')
    .replace(/[^A-Za-z0-9\s-]/g, '')
    .trim();
  const dashed = ascii.replace(/\s+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').toLowerCase();
  return dashed || 'work';
}

function fetchIssue(repoSlug, issueNumber) {
  const raw = run('gh', [
    'issue',
    'view',
    String(issueNumber),
    '--repo',
    repoSlug,
    '--json',
    'number,title,state,url'
  ]);
  if (!raw) {
    throw new Error(`Unable to load issue #${issueNumber} from ${repoSlug}.`);
  }
  const parsed = JSON.parse(raw);
  if (!parsed?.title) {
    throw new Error(`Issue #${issueNumber} does not expose a title.`);
  }
  return parsed;
}

function detectRemoteBranch(repoRoot, branch) {
  const probe = spawnSync(
    'git',
    ['for-each-ref', '--format=%(upstream)', `refs/heads/${branch}`],
    { cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }
  );
  if (probe.status !== 0) {
    return null;
  }
  const value = probe.stdout.trim();
  if (!value) return null;
  const slashIndex = value.indexOf('/');
  if (slashIndex <= 0) return null;
  return {
    remote: value.slice(0, slashIndex),
    ref: value.slice(slashIndex + 1)
  };
}

function remoteHasBranch(repoRoot, remote, branch) {
  const result = spawnSync(
    'git',
    ['ls-remote', '--exit-code', remote, `refs/heads/${branch}`],
    { cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
  );
  return result.status === 0;
}

function renameLocalBranch(repoRoot, oldBranch, newBranch) {
  run('git', ['branch', '-m', oldBranch, newBranch], { cwd: repoRoot });
}

function pushBranch(repoRoot, remote, branch, { setUpstream = false } = {}) {
  const args = ['push', remote, branch];
  if (setUpstream) {
    args.splice(1, 0, '--set-upstream');
  }
  try {
    run('git', args, { cwd: repoRoot });
  } catch {
    throw new Error(`git push ${remote} ${branch} failed. Resolve the push error above.`);
  }
}

function deleteRemoteBranch(repoRoot, remote, branch) {
  try {
    run('git', ['push', remote, `:${branch}`], {
      cwd: repoRoot
    });
  } catch {
    throw new Error(`Failed to delete ${remote}/${branch}. Resolve the push error above.`);
  }
}

function findPullRequest(repoSlug, branch, originOwner, upstreamOwner) {
  const owners = [];
  if (originOwner) owners.push(originOwner);
  if (upstreamOwner && !owners.includes(upstreamOwner)) owners.push(upstreamOwner);

  for (const owner of owners) {
    const raw = run('gh', [
      'pr',
      'list',
      '--repo',
      repoSlug,
      '--state',
      'open',
      '--head',
      `${owner}:${branch}`,
      '--json',
      'number,url'
    ]);
    if (!raw) continue;
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed) && parsed.length > 0) {
      return { number: parsed[0].number, url: parsed[0].url, headOwner: owner };
    }
  }

  return null;
}

function retargetPullRequest(repoSlug, prNumber, headOwner, newBranch) {
  run('gh', [
    'pr',
    'edit',
    String(prNumber),
    '--repo',
    repoSlug,
    '--head',
    `${headOwner}:${newBranch}`
  ]);
}

function main() {
  const options = parseArgs(process.argv);
  if (options.help) {
    printUsage();
    return;
  }
  if (!options.issue) {
    printUsage();
    throw new Error('Missing required --issue option.');
  }

  ensureGhCli();

  const repoRoot = getRepoRoot();
  process.chdir(repoRoot);

  ensureCleanWorkingTree(run, 'Working tree not clean. Commit or stash before renaming the branch.');

  const currentBranch = getCurrentBranch();
  const branchToRename = options.branch ?? currentBranch;

  ensureBranchExists(branchToRename);

  const context = resolveRepoContext(repoRoot);
  if (!context?.upstream?.owner || !context?.upstream?.repo) {
    throw new Error('Unable to resolve upstream repository slug (owner/repo).');
  }
  const repoSlug = `${context.upstream.owner}/${context.upstream.repo}`;
  const issue = fetchIssue(repoSlug, options.issue);

  const slug = options.slugOverride ? sanitizeSlug(options.slugOverride) : sanitizeSlug(issue.title);
  const newBranchName = `issue/${options.issue}-${slug}`;

  if (newBranchName === branchToRename) {
    console.log(`[rename] Branch already uses ${newBranchName}; nothing to do.`);
    return;
  }

  ensureBranchDoesNotExist(newBranchName);

  const remoteTracking = detectRemoteBranch(repoRoot, branchToRename);

  const remotesToUpdate = new Set();
  if (remoteTracking?.remote) {
    remotesToUpdate.add(remoteTracking.remote);
  }

  const knownRemotes = ['origin', 'upstream'];
  for (const remote of knownRemotes) {
    if (remoteHasBranch(repoRoot, remote, branchToRename)) {
      remotesToUpdate.add(remote);
    }
  }

  const remotes = Array.from(remotesToUpdate);

  console.log(`[rename] Issue #${issue.number}: "${issue.title}"`);
  console.log(`[rename] Old branch: ${branchToRename}`);
  console.log(`[rename] New branch: ${newBranchName}`);
  if (remotes.length > 0) {
    console.log(`[rename] Remotes to update: ${remotes.join(', ')}`);
  } else {
    console.log('[rename] No remote branches detected for the old name.');
  }

  renameLocalBranch(repoRoot, branchToRename, newBranchName);

  let defaultSetUpstream = true;
  for (const remote of remotes) {
    pushBranch(repoRoot, remote, newBranchName, { setUpstream: defaultSetUpstream });
    defaultSetUpstream = false;
    if (!options.keepRemote) {
      deleteRemoteBranch(repoRoot, remote, branchToRename);
    }
  }

  if (!options.skipPr) {
    const pr = findPullRequest(
      repoSlug,
      branchToRename,
      context.origin?.owner ?? null,
      context.upstream?.owner ?? null
    );
    if (pr) {
      retargetPullRequest(repoSlug, pr.number, pr.headOwner, newBranchName);
      console.log(`[rename] Retargeted PR #${pr.number} -> ${pr.url || ''}`.trim());
    } else {
      console.log('[rename] No open pull request found for the old branch.');
    }
  } else {
    console.log('[rename] Skipping PR retarget as requested.');
  }

  console.log('[rename] Branch rename completed.');
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;

if (invokedPath && invokedPath === modulePath) {
  try {
    main();
  } catch (error) {
    console.error(`[priority:branch:rename] ${error.message}`);
    process.exit(1);
  }
}

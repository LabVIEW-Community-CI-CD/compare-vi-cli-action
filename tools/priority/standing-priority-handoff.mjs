#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import {
  main as syncStandingPriority,
  resolveRepositorySlug,
  resolveStandingPriorityLabels,
  selectAutoStandingPriorityCandidate
} from './sync-standing-priority.mjs';
import { releaseWriterLease } from './agent-writer-lease.mjs';
import { assertPresent } from './lib/github-text.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(scriptPath), '..', '..');

function normalizeIssueLabels(labels) {
  if (!Array.isArray(labels)) {
    return [];
  }

  return labels
    .map((label) => {
      if (typeof label === 'string') {
        return label.trim();
      }
      if (label && typeof label.name === 'string') {
        return label.name.trim();
      }
      return '';
    })
    .filter(Boolean);
}

function defaultGhRunner(args, { quiet = false } = {}) {
  const result = spawnSync('gh', args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', quiet ? 'ignore' : 'pipe']
  });
  if (result.status !== 0) {
    const stderr = result.stderr?.trim() || 'unknown error';
    throw new Error(`gh ${args.join(' ')} failed (${result.status}): ${stderr}`);
  }
  return (result.stdout || '').trim();
}

function parseIssueList(input) {
  const trimmed = (input || '').trim();
  if (!trimmed) return [];
  try {
    const parsed = JSON.parse(trimmed);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((entry) => entry && typeof entry.number !== 'undefined')
      .map((entry) => {
        const number = Number.parseInt(entry.number, 10);
        if (!Number.isFinite(number)) {
          return null;
        }
        return {
          number,
          title: typeof entry.title === 'string' ? entry.title : '',
          body: typeof entry.body === 'string' ? entry.body : '',
          createdAt: entry.createdAt || null,
          updatedAt: entry.updatedAt || null,
          url: entry.url || null,
          labels: normalizeIssueLabels(entry.labels)
        };
      })
      .filter(Boolean);
  } catch (error) {
    throw new Error(`Unable to parse gh issue list output: ${error.message}`);
  }
}

function buildIssueListArgs(repoSlug, fields, extraArgs = []) {
  return [
    'issue',
    'list',
    '--repo',
    repoSlug,
    '--state',
    'open',
    '--limit',
    '100',
    '--json',
    fields.join(','),
    ...extraArgs
  ];
}

function listOpenIssues(ghRunner, repoSlug) {
  return parseIssueList(
    ghRunner(
      buildIssueListArgs(repoSlug, ['number', 'title', 'body', 'labels', 'createdAt', 'updatedAt', 'url']),
      { quiet: true }
    )
  );
}

function collectStandingIssues(ghRunner, repoSlug, standingPriorityLabels) {
  const issueMap = new Map();
  for (const label of standingPriorityLabels) {
    const issues = parseIssueList(
      ghRunner(
        buildIssueListArgs(repoSlug, ['number', 'title', 'body', 'labels', 'createdAt', 'updatedAt', 'url'], [
          '--label',
          label
        ]),
        { quiet: true }
      )
    );

    for (const issue of issues) {
      const existing = issueMap.get(issue.number);
      issueMap.set(issue.number, existing ? { ...existing, ...issue, labels: Array.from(new Set([...existing.labels, ...issue.labels])) } : issue);
    }
  }

  return Array.from(issueMap.values()).sort((left, right) => left.number - right.number);
}

function buildIssueEditArgs(issueNumber, { removeLabels = [], addLabels = [] } = {}) {
  const args = ['issue', 'edit', String(issueNumber)];
  for (const label of removeLabels) {
    args.push('--remove-label', label);
  }
  for (const label of addLabels) {
    args.push('--add-label', label);
  }
  return args;
}

function resolveTargetIssue(nextIssue, auto, openIssues, excludedIssueNumbers) {
  const target = String(nextIssue ?? '').trim();
  if (target) {
    assertPresent(target, 'Next standing priority issue number is required.');
    if (!/^\d+$/.test(target)) {
      throw new Error(`Issue number must be digits only (received: ${target})`);
    }
    const issueNumber = Number.parseInt(target, 10);
    if (!Number.isInteger(issueNumber) || issueNumber <= 0) {
      throw new Error(`Issue number must be a positive integer (> 0), received: ${target}`);
    }
    return {
      issueNumber,
      source: 'explicit'
    };
  }

  if (!auto) {
    throw new Error('Next standing priority issue number is required unless --auto is specified.');
  }

  const selected = selectAutoStandingPriorityCandidate(openIssues, {
    excludeIssueNumbers: excludedIssueNumbers
  });
  if (!selected?.number) {
    throw new Error('No open issues remain that can receive standing-priority in this repository.');
  }

  return {
    issueNumber: selected.number,
    source: 'auto',
    selected
  };
}

/**
 * Rotate the standing-priority label to a new issue.
 *
 * @param {number|string|null} nextIssue
 * @param {{ dryRun?: boolean, auto?: boolean, repoSlug?: string|null, repoRoot?: string, env?: NodeJS.ProcessEnv, ghRunner?: Function, syncFn?: Function, logger?: Function, leaseReleaseFn?: Function, releaseLease?: boolean, leaseScope?: string }} [options]
 */
export async function handoffStandingPriority(
  nextIssue,
  {
    dryRun = false,
    auto = false,
    repoSlug = null,
    repoRoot: workingRepoRoot = repoRoot,
    env = process.env,
    ghRunner = defaultGhRunner,
    syncFn = syncStandingPriority,
    logger = console.log,
    leaseReleaseFn = releaseWriterLease,
    releaseLease = true,
    leaseScope = 'workspace'
  } = {}
) {
  const resolvedRepoSlug = repoSlug || resolveRepositorySlug(workingRepoRoot, env);
  assertPresent(resolvedRepoSlug, 'Unable to resolve repository slug for standing-priority handoff.');
  const standingPriorityLabels = resolveStandingPriorityLabels(workingRepoRoot, resolvedRepoSlug, env);
  const primaryLabel = standingPriorityLabels[0];

  logger(
    `[standing-handoff] Resolving standing issues in ${resolvedRepoSlug} using labels: ${standingPriorityLabels.join(', ')}`
  );
  const currentIssues = collectStandingIssues(ghRunner, resolvedRepoSlug, standingPriorityLabels);
  const currentIssueNumbers = currentIssues.map((issue) => issue.number);
  const openIssues = auto ? listOpenIssues(ghRunner, resolvedRepoSlug) : [];
  const targetSelection = resolveTargetIssue(nextIssue, auto, openIssues, currentIssueNumbers);
  const targetIssueNumber = targetSelection.issueNumber;
  const removeTargets = currentIssues
    .filter((issue) => issue.number !== targetIssueNumber)
    .map((issue) => ({
      number: issue.number,
      removeLabels: standingPriorityLabels.filter((label) => issue.labels.includes(label))
    }))
    .filter((issue) => issue.removeLabels.length > 0);
  const targetIssue = currentIssues.find((issue) => issue.number === targetIssueNumber) || null;
  const targetRemoveLabels = targetIssue
    ? standingPriorityLabels.filter((label) => label !== primaryLabel && targetIssue.labels.includes(label))
    : [];
  const targetNeedsPrimaryLabel = !targetIssue || !targetIssue.labels.includes(primaryLabel);

  if (dryRun) {
    logger(
      `[standing-handoff] Current labelled issues: ${currentIssueNumbers.length ? currentIssueNumbers.join(', ') : 'none'}`
    );
    if (targetSelection.source === 'auto') {
      logger(`[standing-handoff] Auto-selected issue #${targetIssueNumber} in ${resolvedRepoSlug}.`);
    }
    if (removeTargets.length > 0) {
      for (const issue of removeTargets) {
        logger(
          `[standing-handoff] Would remove ${issue.removeLabels.join(', ')} from issue #${issue.number}.`
        );
      }
    }
    if (targetRemoveLabels.length > 0) {
      logger(
        `[standing-handoff] Would remove legacy standing labels from issue #${targetIssueNumber}: ${targetRemoveLabels.join(', ')}`
      );
    }
    if (targetNeedsPrimaryLabel) {
      logger(`[standing-handoff] Would add '${primaryLabel}' label to issue #${targetIssueNumber}`);
    } else {
      logger(`[standing-handoff] Issue #${targetIssueNumber} already carries '${primaryLabel}'.`);
    }
    if (releaseLease) {
      logger(`[standing-handoff] Would release writer lease for scope '${leaseScope}'.`);
    }
    logger('[standing-handoff] Dry run complete – skipping sync.');
    return;
  }

  for (const issue of removeTargets) {
    logger(
      `[standing-handoff] Removing ${issue.removeLabels.join(', ')} from issue #${issue.number}...`
    );
    ghRunner(buildIssueEditArgs(issue.number, { removeLabels: issue.removeLabels }));
  }

  if (targetRemoveLabels.length > 0 || targetNeedsPrimaryLabel) {
    logger(`[standing-handoff] Normalizing standing labels on issue #${targetIssueNumber}...`);
    ghRunner(
      buildIssueEditArgs(targetIssueNumber, {
        removeLabels: targetRemoveLabels,
        addLabels: targetNeedsPrimaryLabel ? [primaryLabel] : []
      })
    );
  } else {
    logger(`[standing-handoff] Issue #${targetIssueNumber} already labelled – ensuring cache is updated.`);
  }

  logger('[standing-handoff] Synchronising priority cache...');
  await syncFn({ env });
  if (releaseLease && typeof leaseReleaseFn === 'function') {
    logger(`[standing-handoff] Releasing writer lease for scope '${leaseScope}'...`);
    try {
      const leaseResult = await leaseReleaseFn({ scope: leaseScope });
      if (leaseResult?.status) {
        logger(`[standing-handoff] Writer lease release status: ${leaseResult.status}.`);
      }
    } catch (error) {
      logger(`[standing-handoff] Writer lease release failed: ${error.message}`);
    }
  }
  logger('[standing-handoff] Standing priority hand-off completed.');
}

async function main() {
  const args = process.argv.slice(2);
  let dryRun = false;
  let auto = false;
  let repoSlug = null;
  let nextIssue;

  for (let i = 0; i < args.length; i++) {
    const token = args[i];
    if (token === '--dry-run') {
      dryRun = true;
    } else if (token === '--auto') {
      auto = true;
    } else if (token === '--repo') {
      repoSlug = args[i + 1] ? String(args[i + 1]).trim() : '';
      i += 1;
      if (!repoSlug) {
        console.error('[standing-handoff] Missing value for --repo.');
        printUsage();
        process.exit(1);
      }
    } else if (token === '--help' || token === '-h') {
      printUsage();
      process.exit(0);
    } else if (!nextIssue) {
      nextIssue = token;
    } else {
      console.error(`[standing-handoff] Unknown argument: ${token}`);
      printUsage();
      process.exit(1);
    }
  }

  if (auto && nextIssue) {
    console.error('[standing-handoff] Specify either <next-issue-number> or --auto, not both.');
    printUsage();
    process.exit(1);
  }

  if (!auto && !nextIssue) {
    console.error('[standing-handoff] Missing next issue number.');
    printUsage();
    process.exit(1);
  }

  try {
    await handoffStandingPriority(nextIssue ?? null, { dryRun, auto, repoSlug });
  } catch (error) {
    console.error(`[standing-handoff] ${error.message}`);
    process.exit(1);
  }
}

function printUsage() {
  console.log(`Usage:
  node tools/priority/standing-priority-handoff.mjs [--repo <owner/repo>] [--dry-run] <next-issue-number>
  node tools/priority/standing-priority-handoff.mjs [--repo <owner/repo>] [--dry-run] --auto`);
}

const modulePath = path.resolve(scriptPath);
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  await main();
}

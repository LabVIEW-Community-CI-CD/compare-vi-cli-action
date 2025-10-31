#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { main as syncStandingPriority } from './sync-standing-priority.mjs';
import { assertPresent } from './lib/github-text.mjs';

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
      .map((entry) => Number.parseInt(entry.number, 10))
      .filter((num) => Number.isFinite(num));
  } catch (error) {
    throw new Error(`Unable to parse gh issue list output: ${error.message}`);
  }
}

/**
 * Rotate the standing-priority label to a new issue.
 *
 * @param {number|string} nextIssue
 * @param {{ dryRun?: boolean, ghRunner?: Function, syncFn?: Function, logger?: Function }} [options]
 */
export async function handoffStandingPriority(
  nextIssue,
  { dryRun = false, ghRunner = defaultGhRunner, syncFn = syncStandingPriority, logger = console.log } = {}
) {
  const target = String(nextIssue ?? '').trim();
  assertPresent(target, 'Next standing priority issue number is required.');
  if (!/^\d+$/.test(target)) {
    throw new Error(`Issue number must be digits only (received: ${target})`);
  }

  logger(`[standing-handoff] Resolving current standing priority issues...`);
  const listOutput = ghRunner(
    ['issue', 'list', '--label', 'standing-priority', '--state', 'open', '--limit', '20', '--json', 'number'],
    { quiet: true }
  );
  const currentIssues = parseIssueList(listOutput);
  const currentSet = new Set(currentIssues);
  const removeTargets = currentIssues.filter((num) => num !== Number.parseInt(target, 10));

  if (dryRun) {
    logger(`[standing-handoff] Current labelled issues: ${currentIssues.length ? currentIssues.join(', ') : 'none'}`);
    if (removeTargets.length > 0) {
      logger(`[standing-handoff] Would remove 'standing-priority' label from: ${removeTargets.join(', ')}`);
    }
    if (!currentSet.has(Number.parseInt(target, 10))) {
      logger(`[standing-handoff] Would add 'standing-priority' label to issue #${target}`);
    } else {
      logger(`[standing-handoff] Issue #${target} already carries the label (no add required).`);
    }
    logger('[standing-handoff] Dry run complete – skipping sync.');
    return;
  }

  for (const issue of removeTargets) {
    logger(`[standing-handoff] Removing label from issue #${issue}...`);
    ghRunner(['issue', 'edit', String(issue), '--remove-label', 'standing-priority']);
  }

  if (!currentSet.has(Number.parseInt(target, 10))) {
    logger(`[standing-handoff] Adding label to issue #${target}...`);
    ghRunner(['issue', 'edit', String(target), '--add-label', 'standing-priority']);
  } else {
    logger(`[standing-handoff] Issue #${target} already labelled – ensuring cache is updated.`);
  }

  logger('[standing-handoff] Synchronising priority cache...');
  await syncFn();
  logger('[standing-handoff] Standing priority hand-off completed.');
}

async function main() {
  const args = process.argv.slice(2);
  let dryRun = false;
  let nextIssue;

  for (let i = 0; i < args.length; i++) {
    const token = args[i];
    if (token === '--dry-run') {
      dryRun = true;
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

  if (!nextIssue) {
    console.error('[standing-handoff] Missing next issue number.');
    printUsage();
    process.exit(1);
  }

  try {
    await handoffStandingPriority(nextIssue, { dryRun });
  } catch (error) {
    console.error(`[standing-handoff] ${error.message}`);
    process.exit(1);
  }
}

function printUsage() {
  console.log(`Usage:
  node tools/priority/standing-priority-handoff.mjs [--dry-run] <next-issue-number>`);
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  await main();
}

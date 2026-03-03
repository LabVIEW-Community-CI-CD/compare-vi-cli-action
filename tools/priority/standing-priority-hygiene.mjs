#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', shell: false, ...opts });
}

function ensureCommand(result, cmd) {
  if (result?.error?.code === 'ENOENT') {
    const err = new Error(`Command not found: ${cmd}`);
    err.code = 'ENOENT';
    throw err;
  }
  return result;
}

export function issueHasLabel(issue, label = 'standing-priority') {
  if (!issue || !Array.isArray(issue.labels)) return false;
  const normalized = String(label || '')
    .trim()
    .toLowerCase();
  if (!normalized) return false;
  return issue.labels.some((entry) => {
    const name = typeof entry === 'string' ? entry : entry?.name;
    return String(name || '')
      .trim()
      .toLowerCase() === normalized;
  });
}

export function shouldRemoveStandingPriorityLabel(issue, label = 'standing-priority') {
  const state = String(issue?.state || '')
    .trim()
    .toUpperCase();
  return state === 'CLOSED' && issueHasLabel(issue, label);
}

export function parseCliArgs(argv = process.argv.slice(2)) {
  const args = Array.from(argv || []);
  const options = {
    issue: null,
    label: 'standing-priority',
    dryRun: false
  };

  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === '--issue') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --issue');
      const parsed = Number(value);
      if (!Number.isInteger(parsed) || parsed <= 0) {
        throw new Error(`Invalid issue number: ${value}`);
      }
      options.issue = parsed;
      continue;
    }
    if (token === '--label') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --label');
      options.label = value;
      continue;
    }
    if (token === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    throw new Error(`Unknown argument: ${token}`);
  }

  if (!options.help && !options.issue) {
    throw new Error('Missing required --issue <number>');
  }
  return options;
}

function printHelp() {
  console.log(`Usage:
  node tools/priority/standing-priority-hygiene.mjs --issue <number> [--label <name>] [--dry-run]

Removes the standing-priority label from a closed issue when present.`);
}

export async function runHygiene(options = {}) {
  const issueNumber = options.issue;
  const label = options.label || 'standing-priority';
  const dryRun = Boolean(options.dryRun);

  const viewResult = ensureCommand(
    sh('gh', ['issue', 'view', String(issueNumber), '--json', 'number,state,labels,url']),
    'gh'
  );
  if (viewResult.status !== 0) {
    const details = viewResult.stderr?.trim() || viewResult.stdout?.trim() || 'unknown error';
    throw new Error(`Failed to inspect issue #${issueNumber}: ${details}`);
  }

  const issue = JSON.parse(viewResult.stdout || '{}');
  if (!shouldRemoveStandingPriorityLabel(issue, label)) {
    console.log(
      `[standing-hygiene] No cleanup needed for issue #${issue.number ?? issueNumber} (state=${issue.state || 'unknown'}).`
    );
    return { removed: false, issue };
  }

  if (dryRun) {
    console.log(
      `[standing-hygiene] Dry-run: would remove label '${label}' from closed issue #${issue.number}.`
    );
    return { removed: false, issue, dryRun: true };
  }

  const editResult = ensureCommand(
    sh('gh', ['issue', 'edit', String(issue.number), '--remove-label', label]),
    'gh'
  );
  if (editResult.status !== 0) {
    const details = editResult.stderr?.trim() || editResult.stdout?.trim() || 'unknown error';
    throw new Error(
      `Failed to remove label '${label}' from issue #${issue.number}: ${details}`
    );
  }

  console.log(`[standing-hygiene] Removed label '${label}' from issue #${issue.number}.`);
  return { removed: true, issue };
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  (async () => {
    try {
      const options = parseCliArgs(process.argv.slice(2));
      if (options.help) {
        printHelp();
        process.exitCode = 0;
        return;
      }
      await runHygiene(options);
      process.exitCode = 0;
    } catch (err) {
      console.error(`[standing-hygiene] ${err.message}`);
      process.exitCode = 1;
    }
  })();
}


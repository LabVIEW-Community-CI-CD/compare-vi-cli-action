#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureValidIdentifier,
  ensureCleanWorkingTree,
  ensureBranchDoesNotExist,
  getCurrentBranch,
  getRepoRoot
} from './lib/branch-utils.mjs';

const USAGE_LINES = [
  'Usage: npm run feature:branch:dry -- <slug>',
  '',
  'Creates a feature/<slug> branch (dry-run) and records metadata under tests/results/_agent/feature/.',
  '',
  'Options:',
  '  -h, --help    Show this message and exit'
];

async function main() {
  const name = parseSingleValueArg(process.argv, {
    usageLines: USAGE_LINES,
    valueLabel: '<slug>'
  });
  ensureValidIdentifier(name, { label: 'feature slug' });

  const branch = `feature/${name}`;
  const root = getRepoRoot();
  ensureCleanWorkingTree(run, 'Working tree not clean. Commit or stash changes before running the dry-run helper.');
  ensureBranchDoesNotExist(branch);

  const originalBranch = getCurrentBranch();

  let baseCommit;
  let restoreBranch = false;
  try {
    run('git', ['checkout', '-B', 'develop', 'upstream/develop']);
    run('git', ['checkout', '-b', branch]);
    baseCommit = run('git', ['rev-parse', 'HEAD']);
    restoreBranch = true;
  } finally {
    if (restoreBranch && originalBranch) {
      try {
        run('git', ['checkout', originalBranch]);
      } catch (restoreError) {
        console.warn(`[feature:branch:dry] warning: failed to restore branch ${originalBranch}: ${restoreError.message}`);
      }
    }
  }

  if (!baseCommit) {
    throw new Error('Failed to determine feature branch base commit.');
  }

  const dir = path.join(root, 'tests', 'results', '_agent', 'feature');
  await mkdir(dir, { recursive: true });
  const payload = {
    schema: 'feature/branch-dryrun@v1',
    branch,
    baseBranch: 'develop',
    baseCommit,
    dryRun: true,
    createdAt: new Date().toISOString()
  };
  const file = path.join(dir, `feature-${name}-dryrun.json`);
  await writeFile(file, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

  console.log(`[dry-run] created ${branch} at ${baseCommit}`);
  console.log(`[dry-run] metadata -> ${file}`);
  console.log('[dry-run] skipping push and PR creation');
}

main().catch((error) => {
  console.error(`[feature:branch:dry] ${error.message}`);
  process.exit(1);
});

#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureValidIdentifier,
  ensureCleanWorkingTree,
  getCurrentCheckoutTarget,
  getRepoRoot,
  checkoutDetachedRef
} from './lib/branch-utils.mjs';

const USAGE_LINES = [
  'Usage: node tools/npm/run-script.mjs feature:branch:dry -- <slug>',
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

  const originalCheckout = getCurrentCheckoutTarget();

  let baseCommit;
  try {
    checkoutDetachedRef('upstream/develop');
    baseCommit = run('git', ['rev-parse', 'HEAD']);
    run('git', ['branch', '-f', branch, 'HEAD']);
  } finally {
    if (originalCheckout) {
      try {
        run('git', ['checkout', originalCheckout]);
      } catch (restoreError) {
        console.warn(
          `[feature:branch:dry] warning: failed to restore checkout ${originalCheckout}: ${restoreError.message}`
        );
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

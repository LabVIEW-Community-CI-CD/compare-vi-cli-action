#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureCleanWorkingTree,
  getCurrentCheckoutTarget,
  getRepoRoot,
  checkoutDetachedRef
} from './lib/branch-utils.mjs';
import { normalizeVersionInput } from './lib/release-utils.mjs';

const USAGE_LINES = [
  'Usage: node tools/npm/run-script.mjs release:branch:dry -- <version>',
  '',
  'Creates a release/<version> branch (dry-run) and records metadata under tests/results/_agent/release/.',
  '',
  'Options:',
  '  -h, --help    Show this message and exit'
];

async function main() {
  const versionInput = parseSingleValueArg(process.argv, {
    usageLines: USAGE_LINES,
    valueLabel: '<version>'
  });
  const { tag, semver } = normalizeVersionInput(versionInput);

  const branch = `release/${tag}`;
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
          `[release:branch:dry] warning: failed to restore checkout ${originalCheckout}: ${restoreError.message}`
        );
      }
    }
  }

  if (!baseCommit) {
    throw new Error('Failed to determine release branch base commit.');
  }

  const dir = path.join(root, 'tests', 'results', '_agent', 'release');
  await mkdir(dir, { recursive: true });
  const payload = {
    schema: 'release/branch-dryrun@v1',
    branch,
    version: tag,
    semver,
    baseBranch: 'develop',
    baseCommit,
    dryRun: true,
    createdAt: new Date().toISOString()
  };
  const file = path.join(dir, `release-${tag}-dryrun.json`);
  await writeFile(file, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

  console.log(`[dry-run] created ${branch} at ${baseCommit}`);
  console.log(`[dry-run] metadata -> ${file}`);
  console.log('[dry-run] skipping push and PR creation');
}

main().catch((error) => {
  console.error(`[release:branch:dry] ${error.message}`);
  process.exit(1);
});

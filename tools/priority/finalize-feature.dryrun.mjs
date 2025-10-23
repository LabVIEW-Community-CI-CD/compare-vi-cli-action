#!/usr/bin/env node

import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureValidIdentifier,
  ensureBranchExists,
  getRepoRoot
} from './lib/branch-utils.mjs';

const USAGE_LINES = [
  'Usage: npm run feature:finalize:dry -- <slug>',
  '',
  'Simulates rebasing feature/<slug> onto develop and writes metadata under tests/results/_agent/feature/.',
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
  ensureBranchExists(branch);

  const root = getRepoRoot();
  const featureCommit = run('git', ['rev-parse', branch]);
  const developBase = run('git', ['rev-parse', 'upstream/develop']);

  console.log(`[dry-run] would rebase ${branch} onto upstream/develop (${developBase})`);
  console.log(`[dry-run] git push origin ${branch}`);
  console.log('[dry-run] merge via PR (squash)');

  const dir = path.join(root, 'tests', 'results', '_agent', 'feature');
  const payload = {
    schema: 'feature/finalize-dryrun@v1',
    branch,
    branchCommit: featureCommit,
    developBase,
    dryRun: true,
    generatedAt: new Date().toISOString()
  };
  await writeFile(path.join(dir, `feature-${name}-finalize-dryrun.json`), `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  console.log('[dry-run] wrote feature finalize dry-run metadata');
}

main().catch((error) => {
  console.error(`[feature:finalize:dry] ${error.message}`);
  process.exit(1);
});

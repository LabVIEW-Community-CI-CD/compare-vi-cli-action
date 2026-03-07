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
  'Usage: node tools/npm/run-script.mjs release:finalize:dry -- <version>',
  '',
  'Simulates fast-forwarding release/<version> into main/develop and writes metadata under tests/results/_agent/release/.',
  '',
  'Options:',
  '  -h, --help    Show this message and exit'
];

function resolveFirstExistingRef(refs) {
  for (const ref of refs) {
    try {
      return {
        ref,
        sha: run('git', ['rev-parse', ref])
      };
    } catch {
      // Try the next candidate.
    }
  }

  throw new Error(`Unable to resolve any candidate ref from: ${refs.join(', ')}`);
}

async function main() {
  const version = parseSingleValueArg(process.argv, {
    usageLines: USAGE_LINES,
    valueLabel: '<version>'
  });
  ensureValidIdentifier(version, { label: 'version' });

  const branch = `release/${version}`;
  ensureBranchExists(branch);

  const root = getRepoRoot();

  const releaseCommit = run('git', ['rev-parse', branch]);
  const mainBase = resolveFirstExistingRef(['upstream/main', 'origin/main', 'main', 'HEAD']);
  const developBase = resolveFirstExistingRef(['upstream/develop', 'origin/develop', 'develop', 'HEAD']);

  console.log(`[dry-run] would fast-forward main to ${releaseCommit} (current ${mainBase.ref} ${mainBase.sha})`);
  console.log('[dry-run] git push upstream main');
  console.log(`[dry-run] gh release create --draft ${version}`);
  console.log(`[dry-run] would fast-forward develop to ${releaseCommit} (current ${developBase.ref} ${developBase.sha})`);
  console.log('[dry-run] git push upstream develop');

  const dir = path.join(root, 'tests', 'results', '_agent', 'release');
  const metadata = {
    schema: 'release/finalize-dryrun@v1',
    version,
    releaseBranch: branch,
    releaseCommit,
    mainBase: mainBase.sha,
    mainBaseRef: mainBase.ref,
    developBase: developBase.sha,
    developBaseRef: developBase.ref,
    dryRun: true,
    generatedAt: new Date().toISOString()
  };
  await writeFile(path.join(dir, `release-${version}-finalize-dryrun.json`), `${JSON.stringify(metadata, null, 2)}\n`, 'utf8');
  console.log('[dry-run] wrote finalize dry-run metadata');
}

main().catch((error) => {
  console.error(`[release:finalize:dry] ${error.message}`);
  process.exit(1);
});

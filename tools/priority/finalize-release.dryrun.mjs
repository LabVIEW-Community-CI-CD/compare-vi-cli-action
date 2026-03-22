#!/usr/bin/env node

import process from 'node:process';
import {
  run,
  parseSingleValueArg,
  ensureBranchExists,
  getRepoRoot
} from './lib/branch-utils.mjs';
import { normalizeVersionInput, writeReleaseMetadata } from './lib/release-utils.mjs';

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
  const versionInput = parseSingleValueArg(process.argv, {
    usageLines: USAGE_LINES,
    valueLabel: '<version>'
  });
  const { tag, semver } = normalizeVersionInput(versionInput);

  const branch = `release/${tag}`;
  ensureBranchExists(branch);

  const root = getRepoRoot();

  const releaseCommit = run('git', ['rev-parse', branch]);
  const mainBase = resolveFirstExistingRef(['upstream/main', 'origin/main', 'main', 'HEAD']);
  const developBase = resolveFirstExistingRef(['upstream/develop', 'origin/develop', 'develop', 'HEAD']);

  console.log(`[dry-run] would fast-forward main to ${releaseCommit} (current ${mainBase.ref} ${mainBase.sha})`);
  console.log('[dry-run] git push upstream main');
  console.log(`[dry-run] gh release create --draft ${tag}`);
  console.log(`[dry-run] would fast-forward develop to ${releaseCommit} (current ${developBase.ref} ${developBase.sha})`);
  console.log('[dry-run] git push upstream develop');

  const metadata = {
    schema: 'release/finalize-dryrun@v1',
    version: tag,
    semver,
    releaseBranch: branch,
    releaseCommit,
    mainBase: mainBase.sha,
    mainBaseRef: mainBase.ref,
    developBase: developBase.sha,
    developBaseRef: developBase.ref,
    dryRun: true,
    generatedAt: new Date().toISOString()
  };
  const metadataPath = await writeReleaseMetadata(root, tag, 'finalize-dryrun', metadata);
  console.log(`[dry-run] wrote finalize dry-run metadata -> ${metadataPath}`);
}

main().catch((error) => {
  console.error(`[release:finalize:dry] ${error.message}`);
  process.exit(1);
});

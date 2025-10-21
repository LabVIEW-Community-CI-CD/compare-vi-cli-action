#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
    ...options
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed with exit code ${result.status}`);
  }
  return result.stdout.trim();
}

async function main() {
  const version = process.argv[2];
  if (!version) {
    console.error('Usage: npm run release:finalize:dry -- vX.Y.Z');
    process.exit(1);
  }

  const branch = `release/${version}`;
  const root = run('git', ['rev-parse', '--show-toplevel']);

  const branches = run('git', ['branch'])
    .split('\n')
    .map((line) => line.replace('*', '').trim())
    .filter(Boolean);
  if (!branches.includes(branch)) {
    throw new Error(`Branch ${branch} not found. Create it before running the dry-run finalizer.`);
  }

  const releaseCommit = run('git', ['rev-parse', branch]);
  const mainBase = run('git', ['rev-parse', 'upstream/main']);
  const developBase = run('git', ['rev-parse', 'upstream/develop']);

  console.log(`[dry-run] would fast-forward main to ${releaseCommit} (current upstream/main ${mainBase})`);
  console.log('[dry-run] git push upstream main');
  console.log(`[dry-run] gh release create --draft ${version}`);
  console.log(`[dry-run] would fast-forward develop to ${releaseCommit} (current upstream/develop ${developBase})`);
  console.log('[dry-run] git push upstream develop');

  const dir = path.join(root, 'tests', 'results', '_agent', 'release');
  const metadata = {
    schema: 'release/finalize-dryrun@v1',
    version,
    releaseBranch: branch,
    releaseCommit,
    mainBase,
    developBase,
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

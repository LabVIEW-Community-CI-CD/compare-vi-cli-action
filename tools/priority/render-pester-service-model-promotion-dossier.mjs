#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

const repoRoot = process.cwd();
const baseDir = path.join(repoRoot, 'tests', 'results', '_agent', 'pester-service-model');
const releaseEvidenceDir = path.join(baseDir, 'release-evidence');
const outputPath = path.join(releaseEvidenceDir, 'promotion-dossier.md');

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    upstreamIssue: '2069',
    forkIssue: '2078',
    forkBasisCommit: '',
    forkBasisUrl: ''
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const next = argv[i + 1];
    if (token === '--upstream-issue') {
      options.upstreamIssue = next;
      i += 1;
      continue;
    }
    if (token === '--fork-issue') {
      options.forkIssue = next;
      i += 1;
      continue;
    }
    if (token === '--fork-basis-commit') {
      options.forkBasisCommit = next;
      i += 1;
      continue;
    }
    if (token === '--fork-basis-url') {
      options.forkBasisUrl = next;
      i += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function runGit(args) {
  const result = spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || `git ${args.join(' ')} failed`);
  }
  return result.stdout.trim();
}

async function ensureFile(filePath) {
  await fs.access(filePath);
}

async function main() {
  const options = parseArgs();
  const coveragePath = path.join(releaseEvidenceDir, 'coverage.xml');
  const docsPath = path.join(releaseEvidenceDir, 'docs-link-check.json');
  const rtm = await fs.readFile(path.join(repoRoot, 'docs', 'rtm-pester-service-model.csv'), 'utf8');

  await fs.mkdir(releaseEvidenceDir, { recursive: true });
  await Promise.all([ensureFile(coveragePath), ensureFile(docsPath)]);

  const lines = [
    '# Pester Service Model Promotion Dossier',
    '',
    `- Upstream slice commit: ${runGit(['rev-parse', 'HEAD'])}`,
    `- Upstream epic: \`#${options.upstreamIssue}\``,
    `- Fork basis issue: \`#${options.forkIssue}\``,
    `- Fork basis commit: ${options.forkBasisCommit || 'unspecified'}`,
    `- Fork basis reference: ${options.forkBasisUrl || 'unspecified'}`,
    '- Hosted promotion evidence retained: yes',
    '',
    '## Promotion Basis',
    '',
    '- This upstream slice is derived from the retained fork promotion dossier and requirement packet.',
    '- It promotes only hosted quality and release-evidence surfaces.',
    '- It does not change the self-hosted execution boundary or required gate ownership.',
    '',
    '## Requirement Traceability',
    '',
    '```csv',
    rtm.trim(),
    '```',
    '',
    '## Promotion Evidence',
    '',
    '- the service-model requirement packet is now present on the upstream slice',
    '- hosted packet quality retains `coverage.xml`',
    '- hosted docs integrity retains `docs-link-check.json`',
    '- the release-evidence bundle retains the upstream quality report and RTM alongside the evidence artifacts',
    '',
    '## Minimal Upstream Slice',
    '',
    '1. Keep the slice hosted-only: quality, packet docs, and retained promotion evidence.',
    '2. Re-prove the mounted slice on the upstream integration rail before widening self-hosted behavior.',
    '3. Use this dossier to justify the next service-model promotion step under `#2069`.',
    ''
  ];

  await fs.writeFile(outputPath, `${lines.join('\n')}\n`, 'utf8');
  console.log(`promotion_dossier=${outputPath}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});

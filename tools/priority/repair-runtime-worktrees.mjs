#!/usr/bin/env node

import path from 'node:path';
import { mkdir, writeFile } from 'node:fs/promises';
import { repairRegisteredWorktreeGitPointers } from './runtime-worker-checkout.mjs';

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    repoRoot: process.cwd(),
    report: path.join(process.cwd(), 'tests', 'results', '_agent', 'runtime', 'worktree-repair.json')
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = normalizeText(argv[index]);
    if (!arg) {
      continue;
    }
    if (arg === '--repo-root') {
      options.repoRoot = path.resolve(argv[index + 1] || process.cwd());
      index += 1;
      continue;
    }
    if (arg === '--report') {
      options.report = path.resolve(argv[index + 1] || options.report);
      index += 1;
    }
  }

  return options;
}

const options = parseArgs();
const report = await repairRegisteredWorktreeGitPointers({
  repoRoot: options.repoRoot
});

const payload = {
  schema: 'priority/runtime-worktree-repair-report@v1',
  generatedAt: new Date().toISOString(),
  repoRoot: options.repoRoot,
  ...report
};

await mkdir(path.dirname(options.report), { recursive: true });
await writeFile(options.report, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);

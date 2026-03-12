#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readdirSync, readFileSync } from 'node:fs';

const repoRoot = process.cwd();
const prohibitedRequiredContexts = ['ubuntu-latest', 'windows-latest']
  .map((runner) => `hook-parity (${runner})`);

const textExtensions = new Set([
  '.json',
  '.md',
  '.mjs',
  '.js',
  '.ps1',
  '.psm1',
  '.ts',
  '.yml',
  '.yaml',
]);

const excludedDirectories = new Set([
  '.git',
  'dist',
  'node_modules',
  'tests/results',
  'tests\\results',
]);

function walk(relativeDir) {
  const absoluteDir = path.join(repoRoot, relativeDir);
  const entries = readdirSync(absoluteDir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const relativePath = relativeDir ? path.join(relativeDir, entry.name) : entry.name;
    const normalizedRelativePath = relativePath.replace(/\\/g, '/');
    if (entry.isDirectory()) {
      if (excludedDirectories.has(normalizedRelativePath) || excludedDirectories.has(entry.name)) {
        continue;
      }
      files.push(...walk(relativePath));
      continue;
    }

    if (!textExtensions.has(path.extname(entry.name))) {
      continue;
    }

    files.push(relativePath);
  }

  return files;
}

test('canonical required-check mappings do not include stale hook-parity contexts', () => {
  const policyPath = path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json');
  const policy = JSON.parse(readFileSync(policyPath, 'utf8'));

  for (const context of prohibitedRequiredContexts) {
    assert.doesNotMatch(JSON.stringify(policy), new RegExp(context.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});

test('checked-in policy and guidance do not mention stale hook-parity required contexts', () => {
  const files = walk('');
  const offenders = [];

  for (const relativePath of files) {
    const normalizedRelativePath = relativePath.replace(/\\/g, '/');
    if (normalizedRelativePath === '.github/workflows/validate.yml') {
      continue;
    }

    const raw = readFileSync(path.join(repoRoot, relativePath), 'utf8');
    for (const context of prohibitedRequiredContexts) {
      if (raw.includes(context)) {
        offenders.push(`${normalizedRelativePath}: ${context}`);
      }
    }
  }

  assert.deepEqual(
    offenders,
    [],
    `stale hook-parity required-check contexts must stay out of checked-in policy and docs: ${offenders.join(', ')}`,
  );
});

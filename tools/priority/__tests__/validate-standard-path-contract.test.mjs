#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function extractWorkflowJobSection(workflow, jobName, nextJobName = null) {
  const escapedJobName = jobName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const boundary = nextJobName
    ? `\\r?\\n\\s{2}${nextJobName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:`
    : '$';
  const pattern = new RegExp(`${escapedJobName}:\\s*\\r?\\n([\\s\\S]*?)${boundary}`);
  const match = workflow.match(pattern);
  assert.ok(match, `Expected to locate workflow section for ${jobName}`);
  return match[1];
}

test('Validate standard path is not blocked by a validation environment approval gate', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  assert.doesNotMatch(workflow, /^\s*environment:\s*\r?\n\s*name:\s*validation\b/ms);
  assert.doesNotMatch(workflow, /^\s*deployment-determinism:\s*$/m);
  assert.doesNotMatch(workflow, /priority:deployment:assert/);
});

test('hook-parity checks out the PR head directly instead of the merge ref on pull_request', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const hookParitySection = extractWorkflowJobSection(workflow, 'hook-parity', 'semver');

  assert.match(hookParitySection, /name:\s+hook-parity \(ubuntu-latest\)/);
  assert.match(
    hookParitySection,
    /- uses: actions\/checkout@v5\s*\r?\n\s+with:\s*\r?\n\s+repository: \$\{\{ github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name \|\| github\.repository \}\}\s*\r?\n\s+ref: \$\{\{ github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/
  );
  assert.doesNotMatch(
    hookParitySection,
    /- uses: actions\/checkout@v5\s*\r?\n(?!\s+with:)[\s\S]*?actions\/setup-node@v5/
  );
});

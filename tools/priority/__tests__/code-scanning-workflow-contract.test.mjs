#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('code scanning workflow is deterministic across pull_request, merge_group, and push', () => {
  const workflow = readRepoFile('.github/workflows/code-scanning.yml');
  assert.match(workflow, /name:\s+Code Scanning/);
  assert.match(workflow, /pull_request:\s*\n\s*branches:\s*\n\s*-\s*develop\s*\n\s*-\s*main/);
  assert.match(workflow, /merge_group:\s*\n\s*branches:\s*\n\s*-\s*develop\s*\n\s*-\s*main/);
  assert.match(workflow, /push:\s*\n\s*branches:\s*\n\s*-\s*develop\s*\n\s*-\s*main/);
  assert.match(workflow, /security-events:\s+write/);
  assert.match(workflow, /concurrency:\s*\n\s*group:\s+code-scanning-\$\{\{\s*github\.event_name\s*\}\}-\$\{\{\s*github\.event\.pull_request\.number \|\| github\.ref\s*\}\}/);
  assert.match(workflow, /cancel-in-progress:\s+true/);
});

test('code scanning workflow uses CodeQL security-and-quality queries for JavaScript/TypeScript', () => {
  const workflow = readRepoFile('.github/workflows/code-scanning.yml');
  assert.match(workflow, /github\/codeql-action\/init@v3/);
  assert.match(workflow, /languages:\s+javascript-typescript/);
  assert.match(workflow, /queries:\s+security-and-quality/);
  assert.match(workflow, /github\/codeql-action\/analyze@v3/);
  assert.match(workflow, /category:\s+\/language:javascript-typescript/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('pr-automerge workflow uses gh CLI with GH_TOKEN fallback', () => {
  const workflow = readRepoFile('.github/workflows/pr-automerge.yml');

  assert.match(workflow, /name:\s*PR Auto-merge \(on label\)/);
  assert.match(workflow, /pull_request_target:\s*\r?\n\s+types:\s*\[labeled, synchronize, reopened\]/);
  assert.match(workflow, /if:\s*contains\(github\.event\.pull_request\.labels\.\*\.name,\s*'automerge'\)/);
  assert.match(workflow, /GH_TOKEN:\s*\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN\s*\}\}/);
  assert.match(workflow, /gh pr merge -R "\$\{\{\s*github\.repository\s*\}\}" --auto --squash "\$\{\{\s*github\.event\.pull_request\.number\s*\}\}"/);
  assert.doesNotMatch(workflow, /enable-pull-request-automerge@v3/);
});

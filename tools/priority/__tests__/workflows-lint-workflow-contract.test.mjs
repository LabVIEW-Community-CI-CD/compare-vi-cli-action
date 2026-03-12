#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

test('workflows-lint uses explicit shallow PR-head checkout and runs the checkout contract suite', () => {
  const workflow = readFileSync(path.join(repoRoot, '.github', 'workflows', 'workflows-lint.yml'), 'utf8');

  assert.match(workflow, /- uses: actions\/checkout@v5/);
  assert.match(
    workflow,
    /repository:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name \|\| github\.repository\s*\}\}/
  );
  assert.match(
    workflow,
    /ref:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| github\.sha\s*\}\}/
  );
  assert.doesNotMatch(workflow, /checkout-workflow-context/);
  assert.doesNotMatch(workflow, /fetch-depth:\s*0/);
  assert.match(workflow, /Assert workflow checkout contract/);
});

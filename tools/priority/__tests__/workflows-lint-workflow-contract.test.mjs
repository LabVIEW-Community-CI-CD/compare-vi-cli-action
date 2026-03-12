#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

test('workflows-lint uses the checkout workflow context helper with the default shallow PR-head mode', () => {
  const workflow = readFileSync(path.join(repoRoot, '.github', 'workflows', 'workflows-lint.yml'), 'utf8');

  assert.match(workflow, /- uses: \.\/\.github\/actions\/checkout-workflow-context/);
  assert.match(workflow, /- uses: \.\/\.github\/actions\/checkout-workflow-context\s*\r?\n\s+with:\s*\r?\n\s+mode:\s*'pr-head'/);
  assert.doesNotMatch(workflow, /actions\/checkout@v5/);
  assert.doesNotMatch(workflow, /- uses: \.\/\.github\/actions\/checkout-workflow-context\s*\r?\n\s+with:\s*\r?\n\s+mode:\s*'pr-head'\s*\r?\n\s+fetch-depth:\s*0/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

test('workflows-lint uses the default shallow checkout', () => {
  const workflow = readFileSync(path.join(repoRoot, '.github', 'workflows', 'workflows-lint.yml'), 'utf8');

  assert.match(workflow, /- uses: actions\/checkout@v5/);
  assert.match(
    workflow,
    /- uses: actions\/checkout@v5\s*\r?\n\s+with:\s*\r?\n\s+repository: \$\{\{ github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name \|\| github\.repository \}\}\s*\r?\n\s+ref: \$\{\{ github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/
  );
  assert.doesNotMatch(workflow, /- uses: actions\/checkout@v5\s*\r?\n\s+with:\s*\r?\n\s+fetch-depth:\s*0/);
});

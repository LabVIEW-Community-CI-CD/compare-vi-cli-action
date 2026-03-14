#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('fixture drift hosted ni-linux job fetches the pull request base commit before vi-history diffing', () => {
  const workflow = readRepoFile('.github/workflows/fixture-drift.yml');

  assert.match(workflow, /name: Fetch pull request base commit for history diff\s+if: github\.event_name == 'pull_request'\s+shell: bash/ms);
  assert.match(
    workflow,
    /git fetch --no-tags --depth=1 "https:\/\/github\.com\/\$\{\{ github\.event\.pull_request\.base\.repo\.full_name \}\}\.git" "\$\{\{ github\.event\.pull_request\.base\.sha \}\}"/,
  );
  assert.match(workflow, /git rev-parse --verify "\$\{\{ github\.event\.pull_request\.base\.sha \}\}\^\{commit\}"/);
  assert.match(workflow, /-HistoryBaselineRef \$historyBaselineRef/);
});

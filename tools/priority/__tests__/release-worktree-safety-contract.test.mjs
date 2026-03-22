#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readPriorityFile(relativePath) {
  return readFileSync(path.join(repoRoot, 'tools', 'priority', relativePath), 'utf8');
}

test('release helpers use detached upstream bases instead of reclaiming local develop/main branches', () => {
  const releaseBranchDryrun = readPriorityFile('create-release-branch.dryrun.mjs');
  const releaseBranch = readPriorityFile('create-release-branch.mjs');
  const featureBranchDryrun = readPriorityFile('create-feature-branch.dryrun.mjs');
  const finalizeRelease = readPriorityFile('finalize-release.mjs');

  for (const script of [releaseBranchDryrun, releaseBranch, featureBranchDryrun, finalizeRelease]) {
    assert.match(script, /checkoutDetachedRef/);
  }

  assert.doesNotMatch(releaseBranchDryrun, /checkout', '-B', 'develop'/);
  assert.doesNotMatch(releaseBranch, /checkout', '-B', 'develop'/);
  assert.doesNotMatch(featureBranchDryrun, /checkout', '-B', 'develop'/);
  assert.doesNotMatch(finalizeRelease, /checkout', '-B', 'develop'/);
  assert.doesNotMatch(finalizeRelease, /checkout', '-B', 'main'/);

  assert.match(finalizeRelease, /HEAD:main/);
  assert.match(finalizeRelease, /HEAD:develop/);
});

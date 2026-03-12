#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertAllowedTransition,
  branchPatternToRegExp,
  classifyBranch,
  loadBranchClassContract,
  matchBranchPattern,
  normalizeBranchName,
  resolveRepositoryRole
} from '../lib/branch-classification.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const contract = loadBranchClassContract(repoRoot);

test('normalizeBranchName removes refs/heads prefix and lowercases', () => {
  assert.equal(normalizeBranchName('refs/heads/Main'), 'main');
  assert.equal(normalizeBranchName('issue/Origin-1041-Branch-Roles'), 'issue/origin-1041-branch-roles');
});

test('branchPatternToRegExp and matchBranchPattern support wildcard branch classes', () => {
  assert.equal(branchPatternToRegExp('release/*').test('release/2026.03'), true);
  assert.equal(matchBranchPattern('gh-readonly-queue/develop/pr-1-deadbeef', 'gh-readonly-queue/**'), true);
  assert.equal(matchBranchPattern('feature/branch-topology', 'issue/*'), false);
});

test('resolveRepositoryRole distinguishes upstream and fork repositories', () => {
  assert.equal(resolveRepositoryRole('LabVIEW-Community-CI-CD/compare-vi-cli-action', contract), 'upstream');
  assert.equal(resolveRepositoryRole('LabVIEW-Community-CI-CD/compare-vi-cli-action-fork', contract), 'fork');
});

test('classifyBranch resolves upstream integration, fork mirror, and lane branches', () => {
  assert.equal(
    classifyBranch({
      branch: 'develop',
      contract,
      repositoryRole: 'upstream'
    }).id,
    'upstream-integration'
  );
  assert.equal(
    classifyBranch({
      branch: 'develop',
      contract,
      repositoryRole: 'fork'
    }).id,
    'fork-mirror-develop'
  );
  assert.equal(
    classifyBranch({
      branch: 'issue/origin-1041-branch-roles',
      contract,
      repositoryRole: 'fork'
    }).id,
    'lane'
  );
});

test('classifyBranch resolves merge queue refs as their own class', () => {
  const result = classifyBranch({
    branch: 'gh-readonly-queue/develop/pr-1041-abcdef',
    contract,
    repositoryRole: 'upstream'
  });

  assert.equal(result.id, 'merge-queue');
  assert.equal(result.mergePolicy, 'queue-owned');
});

test('assertAllowedTransition accepts upstream develop sync to fork mirror and rejects inverse promotion', () => {
  const syncTransition = assertAllowedTransition({
    from: 'upstream-integration',
    to: 'fork-mirror-develop',
    action: 'sync',
    contract
  });
  assert.equal(syncTransition.via, 'priority:develop:sync');

  assert.throws(
    () =>
      assertAllowedTransition({
        from: 'fork-mirror-develop',
        to: 'upstream-integration',
        action: 'promote',
        contract
      }),
    /not allowed by the branch class contract/i
  );
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertAllowedTransition,
  branchPatternToRegExp,
  classifyBranch,
  findRepositoryPlaneEntry,
  loadBranchClassContract,
  matchBranchPattern,
  normalizeBranchName,
  resolveLaneBranchPrefix,
  resolveRepositoryPlane,
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

test('resolveRepositoryPlane distinguishes upstream, origin, and personal planes', () => {
  assert.equal(resolveRepositoryPlane('LabVIEW-Community-CI-CD/compare-vi-cli-action', contract), 'upstream');
  assert.equal(resolveRepositoryPlane('LabVIEW-Community-CI-CD/compare-vi-cli-action-fork', contract), 'origin');
  assert.equal(resolveRepositoryPlane('svelderrainruiz/compare-vi-cli-action', contract), 'personal');
  assert.equal(resolveRepositoryPlane('someone-else/compare-vi-cli-action', contract), 'fork');
});

test('resolveLaneBranchPrefix follows repository plane metadata from the branch contract', () => {
  assert.equal(resolveLaneBranchPrefix({ contract, plane: 'upstream' }), 'issue/');
  assert.equal(resolveLaneBranchPrefix({ contract, plane: 'origin' }), 'issue/origin-');
  assert.equal(resolveLaneBranchPrefix({ contract, plane: 'personal' }), 'issue/personal-');
  assert.equal(resolveLaneBranchPrefix({ contract, repository: 'svelderrainruiz/compare-vi-cli-action' }), 'issue/personal-');
  assert.equal(findRepositoryPlaneEntry(contract, 'origin')?.laneBranchPrefix, 'issue/origin-');
});

test('loadBranchClassContract rejects missing or invalid upstreamRepository slugs', () => {
  const missingUpstream = JSON.stringify({
    ...contract,
    upstreamRepository: ''
  });
  const invalidUpstream = JSON.stringify({
    ...contract,
    upstreamRepository: 'LabVIEW-Community-CI-CD'
  });

  assert.throws(
    () =>
      loadBranchClassContract(repoRoot, {
        readFileSyncFn: () => missingUpstream
      }),
    /must define a non-empty upstreamRepository owner\/repo slug/i
  );

  assert.throws(
    () =>
      loadBranchClassContract(repoRoot, {
        readFileSyncFn: () => invalidUpstream
      }),
    /has invalid upstreamRepository/i
  );
});

test('classifyBranch resolves upstream integration, fork mirror, and lane branches', () => {
  const upstreamDevelop = classifyBranch({
    branch: 'develop',
    contract,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  });
  const forkDevelop = classifyBranch({
    branch: 'develop',
    contract,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'
  });
  const personalLane = classifyBranch({
    branch: 'issue/personal-1084-fork-plane-branching-model',
    contract,
    repository: 'svelderrainruiz/compare-vi-cli-action'
  });

  assert.equal(upstreamDevelop.id, 'upstream-integration');
  assert.equal(upstreamDevelop.repositoryPlane, 'upstream');
  assert.equal(forkDevelop.id, 'fork-mirror-develop');
  assert.equal(forkDevelop.repositoryPlane, 'origin');
  assert.equal(personalLane.id, 'lane');
  assert.equal(personalLane.repositoryPlane, 'personal');
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

test('branch class contract records explicit plane metadata and transitions for personal/origin/upstream collaboration', () => {
  assert.deepEqual(
    contract.repositoryPlanes.map((entry) => entry.id),
    ['upstream', 'origin', 'personal']
  );

  const originPlane = contract.repositoryPlanes.find((entry) => entry.id === 'origin');
  const personalPlane = contract.repositoryPlanes.find((entry) => entry.id === 'personal');
  assert.equal(originPlane.laneBranchPrefix, 'issue/origin-');
  assert.equal(personalPlane.laneBranchPrefix, 'issue/personal-');

  assert.deepEqual(
    contract.planeTransitions.map((entry) => `${entry.from}:${entry.action}:${entry.to}`),
    [
      'upstream:sync:origin',
      'upstream:sync:personal',
      'personal:review:origin',
      'personal:promote:upstream',
      'origin:promote:upstream'
    ]
  );
});

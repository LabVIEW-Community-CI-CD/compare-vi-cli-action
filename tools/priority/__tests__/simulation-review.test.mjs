#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { normalizeSimulationReviewPolicy, runSimulationReview } from '../simulation-review.mjs';

test('normalizeSimulationReviewPolicy keeps the deterministic clean-pass default', () => {
  const policy = normalizeSimulationReviewPolicy({});
  assert.equal(policy.enabled, false);
  assert.equal(policy.scenario, 'clean-pass');
  assert.match(policy.receiptPath, /simulation-review[\\/]+receipt\.json$/);
});

test('runSimulationReview passes cleanly for the clean-pass scenario', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'simulation-review-pass-'));
  const result = await runSimulationReview({
    repoRoot,
    policy: {
      enabled: true,
      scenario: 'clean-pass',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json'
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.overall.status, 'passed');
  assert.equal(result.receipt.git.headSha, 'abc123');
  assert.equal(result.receipt.findings.length, 0);
});

test('runSimulationReview fails closed with actionable findings for the actionable-findings scenario', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'simulation-review-findings-'));
  const result = await runSimulationReview({
    repoRoot,
    policy: {
      enabled: true,
      scenario: 'actionable-findings',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json'
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.overall.status, 'failed');
  assert.equal(result.receipt.overall.actionableFindingCount, 1);
  assert.equal(result.receipt.findings[0].actionable, true);
});

test('runSimulationReview can exercise stale-head seams deterministically', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'simulation-review-stale-head-'));
  const result = await runSimulationReview({
    repoRoot,
    policy: {
      enabled: true,
      scenario: 'stale-head',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json'
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'failed');
  assert.match(result.receipt.git.headSha, /-stale$/);
  const persisted = JSON.parse(
    await readFile(path.join(repoRoot, 'tests', 'results', 'docker-tools-parity', 'simulation-review', 'receipt.json'), 'utf8')
  );
  assert.equal(persisted.scenario, 'stale-head');
});

test('runSimulationReview marks the tracked tree dirty for the dirty-tracked scenario', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'simulation-review-dirty-tracked-'));
  const result = await runSimulationReview({
    repoRoot,
    policy: {
      enabled: true,
      scenario: 'dirty-tracked',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json'
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.overall.status, 'failed');
  assert.equal(result.receipt.git.dirtyTracked, true);
  assert.equal(result.receipt.findings.length, 0);
});

test('runSimulationReview reports deterministic provider failure without inventing findings', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'simulation-review-provider-failure-'));
  const result = await runSimulationReview({
    repoRoot,
    policy: {
      enabled: true,
      scenario: 'provider-failure',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json'
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.overall.status, 'failed');
  assert.equal(result.receipt.overall.actionableFindingCount, 0);
  assert.equal(result.receipt.findings.length, 0);
});

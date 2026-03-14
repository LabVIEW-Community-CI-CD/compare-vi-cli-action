#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  loadAgentReviewPolicy,
  normalizeAgentReviewPolicy,
  parseArgs,
  runAgentReviewPolicy
} from '../agent-review-policy.mjs';

test('normalizeAgentReviewPolicy leaves space for Copilot, Codex, Simulation, and Ollama providers', () => {
  const policy = normalizeAgentReviewPolicy({
    reviewProviders: ['copilot-cli', 'simulation', 'codex-cli', 'ollama']
  });
  assert.deepEqual(policy.reviewProviders, ['copilot-cli', 'simulation', 'codex-cli', 'ollama']);
  assert.equal(policy.codexCli.enabled, false);
  assert.equal(policy.ollama.enabled, false);
});

test('parseArgs defaults hook profiles to profile-scoped receipt paths', () => {
  const options = parseArgs([
    'node',
    'tools/priority/agent-review-policy.mjs',
    '--repo-root',
    '/tmp/repo',
    '--review-provider',
    'copilot-cli',
    '--profile',
    'pre-commit'
  ]);

  assert.equal(options.repoRoot, '/tmp/repo');
  assert.equal(options.request.profile, 'pre-commit');
  assert.deepEqual(options.request.reviewProviders, ['copilot-cli']);
  assert.match(options.request.agentReviewPolicyReceiptPath, /_hooks[\\/]pre-commit-agent-review-policy\.json$/);
});

test('loadAgentReviewPolicy reads local review provider selection from delivery-agent policy', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-load-'));
  await mkdir(path.join(repoRoot, 'tools', 'priority'), { recursive: true });
  await writeFile(
    path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'),
    JSON.stringify({
      localReviewLoop: {
        reviewProviders: ['copilot-cli', 'simulation'],
        copilotCliReview: true,
        simulationReview: true,
        simulationReviewConfig: {
          enabled: true,
          scenario: 'actionable-findings'
        }
      }
    }),
    'utf8'
  );

  const policy = await loadAgentReviewPolicy(repoRoot);
  assert.deepEqual(policy.reviewProviders, ['copilot-cli', 'simulation']);
  assert.equal(policy.simulation.enabled, true);
  assert.equal(policy.simulation.scenario, 'actionable-findings');
});

test('runAgentReviewPolicy skips cleanly when no providers are requested', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-skip-'));
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'skipped');
  assert.equal(result.receipt.overall.status, 'skipped');
});

test('runAgentReviewPolicy combines Copilot CLI and Simulation providers into one deterministic receipt', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-pass-'));
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true,
      reviewProviders: ['copilot-cli', 'simulation']
    },
    runCopilotCliReviewFn: async () => ({
      providerId: 'copilot-cli',
      status: 'passed',
      reason: 'Copilot CLI passed.',
      receiptPath: 'tests/results/docker-tools-parity/copilot-cli-review/receipt.json',
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0,
          message: 'Copilot CLI passed.'
        }
      }
    }),
    runSimulationReviewFn: async () => ({
      providerId: 'simulation',
      status: 'passed',
      reason: 'Simulation passed.',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json',
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0,
          message: 'Simulation passed.'
        }
      }
    }),
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.providerSelection.selectionSource, 'explicit-request');
  assert.deepEqual(result.receipt.providerSelection.explicitProviders, ['copilot-cli', 'simulation']);
  assert.deepEqual(result.receipt.providerSelection.policyProviders, []);
  assert.deepEqual(result.receipt.providerSelection.impliedProviders, []);
  assert.deepEqual(result.receipt.requestedProviders, ['copilot-cli', 'simulation']);
  assert.equal(result.receipt.providers['copilot-cli'].status, 'passed');
  assert.equal(result.receipt.providers.simulation.status, 'passed');
});

test('runAgentReviewPolicy forwards the requested execution profile to the Copilot CLI provider', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-profile-'));
  let observedProfile = null;
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true,
      profile: 'pre-push',
      reviewProviders: ['copilot-cli']
    },
    runCopilotCliReviewFn: async (options) => {
      observedProfile = options.profile;
      return {
        providerId: 'copilot-cli',
        status: 'passed',
        reason: 'Copilot CLI passed.',
        receiptPath: 'tests/results/_hooks/pre-push-copilot-cli-review.json',
        receipt: {
          overall: {
            status: 'passed',
            actionableFindingCount: 0,
            message: 'Copilot CLI passed.'
          }
        }
      };
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(observedProfile, 'pre-push');
  assert.equal(result.receipt.profile, 'pre-push');
  assert.match(result.receiptPath, /_hooks[\\/]pre-push-agent-review-policy\.json$/);
});

test('runAgentReviewPolicy preserves explicit provider ordering in the combined receipt', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-order-'));
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true,
      reviewProviders: ['simulation', 'copilot-cli']
    },
    runCopilotCliReviewFn: async () => ({
      providerId: 'copilot-cli',
      status: 'passed',
      reason: 'Copilot CLI passed.',
      receiptPath: 'tests/results/docker-tools-parity/copilot-cli-review/receipt.json',
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0,
          message: 'Copilot CLI passed.'
        }
      }
    }),
    runSimulationReviewFn: async () => ({
      providerId: 'simulation',
      status: 'passed',
      reason: 'Simulation passed.',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json',
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0,
          message: 'Simulation passed.'
        }
      }
    }),
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.deepEqual(result.receipt.requestedProviders, ['simulation', 'copilot-cli']);
  assert.deepEqual(result.receipt.executedProviders, ['simulation', 'copilot-cli']);
  assert.deepEqual(result.receipt.recommendedReviewOrder, ['simulation', 'copilot-cli']);
});

test('runAgentReviewPolicy fails closed when the Simulation provider surfaces a regression seam', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-fail-'));
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true,
      simulationReview: true
    },
    runSimulationReviewFn: async () => ({
      providerId: 'simulation',
      status: 'failed',
      reason: 'Simulation injected a stale-head failure.',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json',
      receipt: {
        overall: {
          status: 'failed',
          actionableFindingCount: 1,
          message: 'Simulation injected a stale-head failure.'
        }
      }
    }),
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.overall.failedProvider, 'simulation');
});

test('runAgentReviewPolicy fails closed when an explicitly selected reserved provider is not implemented', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-reserved-provider-'));
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true,
      reviewProviders: ['codex-cli']
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.overall.failedProvider, 'codex-cli');
  assert.equal(result.receipt.providers['codex-cli'].status, 'failed');
  assert.match(result.receipt.providers['codex-cli'].reason, /not implemented yet/i);
});

test('runAgentReviewPolicy records policy-default provider selection when no explicit providers are requested', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-policy-default-'));
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true
    },
    policy: {
      reviewProviders: ['simulation']
    },
    runSimulationReviewFn: async () => ({
      providerId: 'simulation',
      status: 'passed',
      reason: 'Simulation passed.',
      receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json',
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0,
          message: 'Simulation passed.'
        }
      }
    }),
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.providerSelection.selectionSource, 'policy-default');
  assert.deepEqual(result.receipt.providerSelection.explicitProviders, []);
  assert.deepEqual(result.receipt.providerSelection.policyProviders, ['simulation']);
  assert.deepEqual(result.receipt.providerSelection.impliedProviders, []);
  assert.deepEqual(result.receipt.requestedProviders, ['simulation']);
});

test('runAgentReviewPolicy records legacy-boolean fallback provider selection when deriving providers from booleans', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'agent-review-policy-legacy-fallback-'));
  const result = await runAgentReviewPolicy({
    repoRoot,
    request: {
      requested: true,
      copilotCliReview: true
    },
    runCopilotCliReviewFn: async () => ({
      providerId: 'copilot-cli',
      status: 'passed',
      reason: 'Copilot CLI passed.',
      receiptPath: 'tests/results/docker-tools-parity/copilot-cli-review/receipt.json',
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0,
          message: 'Copilot CLI passed.'
        }
      }
    }),
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    })
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.providerSelection.selectionSource, 'legacy-boolean-fallback');
  assert.deepEqual(result.receipt.providerSelection.explicitProviders, []);
  assert.deepEqual(result.receipt.providerSelection.policyProviders, []);
  assert.deepEqual(result.receipt.providerSelection.impliedProviders, ['copilot-cli']);
  assert.deepEqual(result.receipt.requestedProviders, ['copilot-cli']);
});

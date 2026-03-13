#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  describeLocalReviewProvider,
  executeLocalReviewProvider,
  normalizeLocalReviewProfile,
  normalizeLocalReviewProviderId,
  normalizeLocalReviewProviderList,
  normalizeLocalReviewProviderPolicies
} from '../local-review-providers.mjs';

test('normalizeLocalReviewProviderId accepts supported provider ids and rejects unknown ones', () => {
  assert.equal(normalizeLocalReviewProviderId('copilot-cli'), 'copilot-cli');
  assert.equal(normalizeLocalReviewProviderId('  simulation  '), 'simulation');
  assert.throws(() => normalizeLocalReviewProviderId('review-bot'), /Unsupported local review provider/i);
});

test('normalizeLocalReviewProviderList deduplicates while preserving requested order', () => {
  const providers = normalizeLocalReviewProviderList(['simulation', 'copilot-cli', 'simulation', 'codex-cli']);
  assert.deepEqual(providers, ['simulation', 'copilot-cli', 'codex-cli']);
});

test('normalizeLocalReviewProfile defaults to daemon and rejects unsupported profiles', () => {
  assert.equal(normalizeLocalReviewProfile(''), 'daemon');
  assert.equal(normalizeLocalReviewProfile('pre-push'), 'pre-push');
  assert.throws(() => normalizeLocalReviewProfile('commit-msg'), /Unsupported local review profile/i);
});

test('normalizeLocalReviewProviderPolicies keeps executable and reserved providers distinct', () => {
  const policies = normalizeLocalReviewProviderPolicies({
    reviewProviders: ['copilot-cli', 'simulation', 'codex-cli', 'ollama']
  });
  assert.deepEqual(policies.reviewProviders, ['copilot-cli', 'simulation', 'codex-cli', 'ollama']);
  assert.equal(policies.codexCli.enabled, false);
  assert.equal(policies.ollama.enabled, false);
});

test('executeLocalReviewProvider routes Copilot CLI through the provider registry', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-review-provider-copilot-'));
  let observedOptions = null;
  const result = await executeLocalReviewProvider({
    providerId: 'copilot-cli',
    repoRoot,
    executionProfile: 'pre-commit',
    policies: {
      reviewProviders: ['copilot-cli'],
      copilotCli: {
        enabled: true,
        model: 'gpt-5.5-mini'
      }
    },
    runCopilotCliReviewFn: async (options) => {
      observedOptions = options;
      return {
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
      };
    }
  });

  assert.equal(result.providerId, 'copilot-cli');
  assert.equal(result.status, 'passed');
  assert.equal(observedOptions.profile, 'pre-commit');
  assert.equal(observedOptions.policy.model, 'gpt-5.5-mini');
});

test('executeLocalReviewProvider routes Simulation through the provider registry', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-review-provider-simulation-'));
  let observedOptions = null;
  const result = await executeLocalReviewProvider({
    providerId: 'simulation',
    repoRoot,
    executionProfile: 'daemon',
    policies: {
      reviewProviders: ['simulation'],
      simulation: {
        enabled: true,
        scenario: 'provider-failure'
      }
    },
    runSimulationReviewFn: async (options) => {
      observedOptions = options;
      return {
        status: 'failed',
        reason: 'Simulation failed.',
        receiptPath: 'tests/results/docker-tools-parity/simulation-review/receipt.json',
        receipt: {
          overall: {
            status: 'failed',
            actionableFindingCount: 0,
            message: 'Simulation failed.'
          }
        }
      };
    }
  });

  assert.equal(result.providerId, 'simulation');
  assert.equal(result.status, 'failed');
  assert.equal(observedOptions.policy.scenario, 'provider-failure');
});

test('executeLocalReviewProvider fails closed for reserved providers', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-review-provider-reserved-'));
  const result = await executeLocalReviewProvider({
    providerId: 'codex-cli',
    repoRoot,
    repoGitState: {
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123',
      dirtyTracked: false
    }
  });

  assert.equal(result.providerId, 'codex-cli');
  assert.equal(result.status, 'failed');
  assert.match(result.reason, /not implemented yet/i);
});

test('describeLocalReviewProvider marks executable and reserved providers correctly', () => {
  assert.deepEqual(describeLocalReviewProvider('copilot-cli'), {
    providerId: 'copilot-cli',
    executable: true,
    reserved: false,
    supportsProfiles: ['pre-commit', 'daemon', 'pre-push']
  });
  assert.deepEqual(describeLocalReviewProvider('ollama'), {
    providerId: 'ollama',
    executable: false,
    reserved: true,
    supportsProfiles: ['pre-commit', 'daemon', 'pre-push']
  });
});

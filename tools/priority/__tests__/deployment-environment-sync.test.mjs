#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  POLICY_SCHEMA,
  buildDesiredEnvironmentContract,
  loadPortabilityPolicy,
  parseArgs,
  runDeploymentEnvironmentSync
} from '../sync-deployment-environments.mjs';

function makeEnvironment(payload = {}) {
  return {
    name: 'production',
    can_admins_bypass: false,
    protection_rules: [
      {
        type: 'required_reviewers',
        prevent_self_review: false,
        reviewers: [
          {
            type: 'User',
            reviewer: {
              login: 'svelderrainruiz',
              id: 156447188
            }
          }
        ]
      }
    ],
    ...payload
  };
}

test('parseArgs captures defaults and explicit target selectors', () => {
  const defaults = parseArgs(['node', 'sync-deployment-environments.mjs']);
  assert.equal(defaults.apply, false);
  assert.deepEqual(defaults.targetSelectors, []);
  assert.match(defaults.policyPath, /deployment-environment-parity\.json$/);

  const parsed = parseArgs([
    'node',
    'sync-deployment-environments.mjs',
    '--target',
    'origin',
    '--target',
    'personal',
    '--source-repo',
    'owner/repo',
    '--apply'
  ]);
  assert.deepEqual(parsed.targetSelectors, ['origin', 'personal']);
  assert.equal(parsed.sourceRepository, 'owner/repo');
  assert.equal(parsed.apply, true);
});

test('loadPortabilityPolicy normalizes targets and overrides', async () => {
  const policy = await loadPortabilityPolicy('ignored.json', async () =>
    JSON.stringify({
      schema: POLICY_SCHEMA,
      sourceRepository: 'owner/repo',
      targets: {
        origin: {
          repository: 'owner/repo-fork',
          overrides: {
            production: {
              reviewers: [{ type: 'User', login: 'maintainer' }]
            }
          }
        }
      }
    })
  );

  assert.equal(policy.sourceRepository, 'owner/repo');
  assert.equal(policy.targets.get('origin').repository, 'owner/repo-fork');
  assert.deepEqual(policy.targets.get('origin').overrides.production.reviewers, [{ type: 'User', login: 'maintainer' }]);
});

test('buildDesiredEnvironmentContract preserves source defaults and applies target overrides', () => {
  const sourceMonthly = makeEnvironment({
    name: 'monthly-stability-release',
    protection_rules: [
      {
        type: 'required_reviewers',
        prevent_self_review: true,
        reviewers: [
          { type: 'User', reviewer: { login: 'francois-normandin', id: 1 } },
          { type: 'User', reviewer: { login: 'crossrulz', id: 2 } }
        ]
      }
    ]
  });
  const targetPolicy = {
    overrides: {
      'monthly-stability-release': {
        preventSelfReview: false,
        reviewers: [{ type: 'User', login: 'svelderrainruiz' }]
      }
    }
  };

  const desired = buildDesiredEnvironmentContract(sourceMonthly, targetPolicy);
  assert.equal(desired.canAdminsBypass, false);
  assert.equal(desired.preventSelfReview, false);
  assert.deepEqual(desired.reviewers, [{ type: 'User', login: 'svelderrainruiz' }]);
});

test('runDeploymentEnvironmentSync dry-run reports target-specific noops from live-shaped policy', async () => {
  const policy = {
    schema: POLICY_SCHEMA,
    sourceRepository: 'upstream/repo',
    targets: new Map([
      ['origin', { alias: 'origin', repository: 'org/repo', overrides: {} }],
      [
        'personal',
        {
          alias: 'personal',
          repository: 'personal/repo',
          overrides: {
            'monthly-stability-release': {
              preventSelfReview: false,
              reviewers: [{ type: 'User', login: 'svelderrainruiz' }]
            }
          }
        }
      ]
    ])
  };

  const sourceMonthly = makeEnvironment({
    name: 'monthly-stability-release',
    protection_rules: [
      {
        type: 'required_reviewers',
        prevent_self_review: true,
        reviewers: [
          { type: 'User', reviewer: { login: 'francois-normandin', id: 11 } },
          { type: 'User', reviewer: { login: 'crossrulz', id: 22 } }
        ]
      }
    ]
  });

  const environments = new Map([
    ['upstream/repo|production', makeEnvironment({ name: 'production' })],
    ['upstream/repo|monthly-stability-release', sourceMonthly],
    ['org/repo|production', makeEnvironment({ name: 'production' })],
    ['org/repo|monthly-stability-release', sourceMonthly],
    ['personal/repo|production', makeEnvironment({ name: 'production' })],
    [
      'personal/repo|monthly-stability-release',
      makeEnvironment({
        name: 'monthly-stability-release',
        protection_rules: [
          {
            type: 'required_reviewers',
            prevent_self_review: false,
            reviewers: [{ type: 'User', reviewer: { login: 'svelderrainruiz', id: 156447188 } }]
          }
        ]
      })
    ]
  ]);

  const reportPaths = [];
  const result = await runDeploymentEnvironmentSync({
    args: {
      policyPath: 'tools/policy/deployment-environment-parity.json',
      reportPath: 'tests/results/_agent/deployments/environment-gate-sync.json',
      targetSelectors: [],
      sourceRepository: null,
      apply: false,
      help: false
    },
    token: 'token',
    loadPolicyFn: async () => policy,
    requestGitHubJsonFn: async (url) => {
      const asString = String(url);
      if (asString.includes('/users/')) {
        return { id: 156447188 };
      }
      const match = asString.match(/repos\/([^/]+\/[^/]+)\/environments\/([^/?]+)/);
      if (!match) {
        throw new Error(`unexpected url ${url}`);
      }
      const key = `${match[1]}|${decodeURIComponent(match[2])}`;
      if (!environments.has(key)) {
        const error = new Error('missing');
        error.statusCode = 404;
        throw error;
      }
      return environments.get(key);
    },
    writeJsonFn: async (reportPath, report) => {
      reportPaths.push({ reportPath, report });
      return reportPath;
    }
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.actionsRequired, 0);
  const personalMonthly = result.report.targets
    .find((entry) => entry.alias === 'personal')
    .environments.find((entry) => entry.name === 'monthly-stability-release');
  assert.equal(personalMonthly.action, 'noop');
  assert.deepEqual(personalMonthly.desired.reviewers, [{ type: 'User', login: 'svelderrainruiz' }]);
  assert.equal(personalMonthly.desired.preventSelfReview, false);
  assert.equal(reportPaths.length, 1);
});

test('runDeploymentEnvironmentSync apply mode creates missing environments with resolved reviewer ids', async () => {
  const policy = {
    schema: POLICY_SCHEMA,
    sourceRepository: 'upstream/repo',
    targets: new Map([['origin', { alias: 'origin', repository: 'org/repo', overrides: {} }]])
  };
  const environments = new Map([
    ['upstream/repo|production', makeEnvironment({ name: 'production' })],
    [
      'upstream/repo|monthly-stability-release',
      makeEnvironment({
        name: 'monthly-stability-release',
        protection_rules: [
          {
            type: 'required_reviewers',
            prevent_self_review: true,
            reviewers: [{ type: 'User', reviewer: { login: 'francois-normandin', id: 11728548 } }]
          }
        ]
      })
    ]
  ]);
  const puts = [];

  const result = await runDeploymentEnvironmentSync({
    args: {
      policyPath: 'tools/policy/deployment-environment-parity.json',
      reportPath: 'tests/results/_agent/deployments/environment-gate-sync.json',
      targetSelectors: ['origin'],
      sourceRepository: null,
      apply: true,
      help: false
    },
    token: 'token',
    loadPolicyFn: async () => policy,
    requestGitHubJsonFn: async (url) => {
      const asString = String(url);
      if (asString.includes('/users/')) {
        if (asString.endsWith('/francois-normandin')) {
          return { id: 11728548 };
        }
        if (asString.endsWith('/svelderrainruiz')) {
          return { id: 156447188 };
        }
        throw new Error(`unexpected reviewer lookup ${url}`);
      }
      const match = asString.match(/repos\/([^/]+\/[^/]+)\/environments\/([^/?]+)/);
      if (!match) {
        throw new Error(`unexpected url ${url}`);
      }
      const key = `${match[1]}|${decodeURIComponent(match[2])}`;
      if (!environments.has(key)) {
        const error = new Error('missing');
        error.statusCode = 404;
        throw error;
      }
      return environments.get(key);
    },
    putGitHubJsonFn: async (url, token, method, payload) => {
      puts.push({ url: String(url), token, method, payload });
      const match = String(url).match(/repos\/([^/]+\/[^/]+)\/environments\/([^/?]+)/);
      const repository = match[1];
      const name = decodeURIComponent(match[2]);
      const reviewerLogin = name === 'production' ? 'svelderrainruiz' : 'francois-normandin';
      const reviewerId = name === 'production' ? 156447188 : 11728548;
      const created = makeEnvironment({
        name,
        can_admins_bypass: payload.can_admins_bypass,
        protection_rules: [
          {
            type: 'required_reviewers',
            prevent_self_review: payload.prevent_self_review,
            reviewers: [{ type: 'User', reviewer: { login: reviewerLogin, id: reviewerId } }]
          }
        ]
      });
      environments.set(`${repository}|${name}`, created);
      return created;
    },
    writeJsonFn: async (reportPath) => reportPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(puts.length, 2);
  assert.equal(puts[0].method, 'PUT');
  assert.equal(puts[1].payload.can_admins_bypass, false);
  assert.equal(puts[1].payload.prevent_self_review, true);
  assert.deepEqual(puts[1].payload.reviewers, [{ type: 'User', id: 11728548 }]);
});

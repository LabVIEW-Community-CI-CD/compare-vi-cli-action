#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluateEnvironmentGatePolicy, parseArgs, runDeploymentGatePolicy } from '../check-deployment-gates.mjs';

function makeEnvironment(payload = {}) {
  return {
    name: 'validation',
    can_admins_bypass: false,
    protection_rules: [
      {
        type: 'required_reviewers',
        prevent_self_review: false,
        reviewers: [
          {
            type: 'User',
            reviewer: {
              login: 'maintainer',
              id: 123
            }
          }
        ]
      }
    ],
    ...payload
  };
}

test('parseArgs applies defaults and explicit flags', () => {
  const defaults = parseArgs(['node', 'check-deployment-gates.mjs']);
  assert.equal(defaults.reportPath.endsWith('environment-gate-policy.json'), true);
  assert.deepEqual(defaults.environments, ['validation', 'production']);
  assert.equal(defaults.failOnAdminBypass, true);
  assert.equal(defaults.failOnMissingReviewers, true);

  const parsed = parseArgs([
    'node',
    'check-deployment-gates.mjs',
    '--report',
    'out.json',
    '--repo',
    'owner/repo',
    '--environments',
    'validation',
    '--allow-admin-bypass',
    '--allow-no-reviewers'
  ]);
  assert.equal(parsed.reportPath, 'out.json');
  assert.equal(parsed.repo, 'owner/repo');
  assert.deepEqual(parsed.environments, ['validation']);
  assert.equal(parsed.failOnAdminBypass, false);
  assert.equal(parsed.failOnMissingReviewers, false);
});

test('evaluateEnvironmentGatePolicy passes with reviewer rule and admin bypass disabled', () => {
  const result = evaluateEnvironmentGatePolicy(makeEnvironment());
  assert.equal(result.status, 'pass');
  assert.equal(result.checks.requiredReviewers.status, 'pass');
  assert.equal(result.checks.adminBypassDisabled.status, 'pass');
  assert.equal(result.reviewers.length, 1);
});

test('evaluateEnvironmentGatePolicy fails when reviewer rule missing or admin bypass enabled', () => {
  const result = evaluateEnvironmentGatePolicy(
    makeEnvironment({
      can_admins_bypass: true,
      protection_rules: []
    })
  );
  assert.equal(result.status, 'fail');
  assert.ok(result.reasons.includes('missing-required-reviewers'));
  assert.ok(result.reasons.includes('admin-bypass-enabled'));
});

test('runDeploymentGatePolicy emits fail when an environment is missing', async () => {
  const requestGitHubJsonFn = async (url) => {
    if (String(url).endsWith('/environments/validation')) {
      return makeEnvironment({ name: 'validation' });
    }
    const error = new Error('missing');
    error.statusCode = 404;
    throw error;
  };

  const { report, exitCode } = await runDeploymentGatePolicy({
    repoRoot: process.cwd(),
    args: {
      reportPath: 'tests/results/_agent/deployments/environment-gate-policy.json',
      repo: 'owner/repo',
      environments: ['validation', 'production'],
      failOnAdminBypass: true,
      failOnMissingReviewers: true,
      help: false
    },
    token: 'token',
    requestGitHubJsonFn,
    writeJsonFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 1);
  assert.equal(report.summary.status, 'fail');
  assert.deepEqual(report.summary.failingEnvironments, ['production']);
});

test('runDeploymentGatePolicy passes when all environments are protected', async () => {
  const requestGitHubJsonFn = async (url) => {
    if (String(url).endsWith('/environments/validation')) {
      return makeEnvironment({ name: 'validation' });
    }
    if (String(url).endsWith('/environments/production')) {
      return makeEnvironment({ name: 'production' });
    }
    throw new Error(`unexpected url: ${url}`);
  };

  const { report, exitCode } = await runDeploymentGatePolicy({
    repoRoot: process.cwd(),
    args: {
      reportPath: 'tests/results/_agent/deployments/environment-gate-policy.json',
      repo: 'owner/repo',
      environments: ['validation', 'production'],
      failOnAdminBypass: true,
      failOnMissingReviewers: true,
      help: false
    },
    token: 'token',
    requestGitHubJsonFn,
    writeJsonFn: async (reportPath) => reportPath
  });

  assert.equal(exitCode, 0);
  assert.equal(report.summary.status, 'pass');
  assert.equal(report.summary.failingEnvironmentCount, 0);
});

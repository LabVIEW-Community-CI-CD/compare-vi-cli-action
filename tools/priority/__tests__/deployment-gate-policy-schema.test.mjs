#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runDeploymentGatePolicy } from '../check-deployment-gates.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('environment gate policy report validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'environment-gate-policy-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const requestGitHubJsonFn = async (url) => {
    if (String(url).endsWith('/environments/validation')) {
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
        ]
      };
    }
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
                login: 'maintainer',
                id: 123
              }
            }
          ]
        }
      ]
    };
  };

  const { report } = await runDeploymentGatePolicy({
    repoRoot,
    now: new Date('2026-03-07T03:45:00Z'),
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

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

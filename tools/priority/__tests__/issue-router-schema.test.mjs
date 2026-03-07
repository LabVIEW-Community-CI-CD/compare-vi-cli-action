#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runIssueRouter } from '../issue-router.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('issue router report schema validates generated report and preserves label/idempotence seams', async () => {
  const schema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'issue-routing-report-v1.schema.json'), 'utf8')
  );

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-router-schema-'));
  const reportPath = path.join(tmpDir, 'report.json');
  const decision = {
    schema: 'priority/policy-decision-report@v1',
    evaluation: {
      selectedRuleId: 'workflow-failure'
    },
    decision: {
      type: 'open-issue',
      priority: 'P1',
      labels: ['ci', 'governance'],
      owner: 'release-platform',
      titlePrefix: '[Workflow Incident]',
      reason: 'workflow-failure'
    },
    event: {
      schema: 'incident-event@v1',
      sourceType: 'workflow-run',
      incidentClass: 'workflow-run-failure',
      severity: 'high',
      branch: 'develop',
      sha: 'abc123',
      signature: 'validate:failure',
      fingerprint: 'schema-fingerprint',
      repository: 'example/repo',
      suggestedLabels: ['ci']
    }
  };

  const result = await runIssueRouter(
    {
      decisionPath: 'decision.json',
      reportPath,
      dryRun: true
    },
    {
      now: new Date('2026-03-06T23:04:00Z'),
      readJsonFileFn: async () => decision,
      writeJsonFn: (filePath, payload) => {
        fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
        return filePath;
      },
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => 'token',
      requestGitHubJsonFn: async (url) => {
        if (url.includes('/search/issues')) {
          return { items: [] };
        }
        throw new Error(`unexpected request: ${url}`);
      }
    }
  );

  assert.equal(result.exitCode, 0);
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.schema, 'priority/issue-routing-report@v1');
  assert.equal(report.route.operation.action, 'would-create');
  assert.deepEqual(report.route.labels.desired, ['ci', 'governance']);
  assert.equal(typeof report.route.idempotence.bodyDigest, 'string');
});

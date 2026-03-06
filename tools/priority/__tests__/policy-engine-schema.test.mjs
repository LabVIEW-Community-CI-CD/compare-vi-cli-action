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
import { runPolicyEngine } from '../policy-engine.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('policy engine schemas validate policy contract and report artifact', async () => {
  const policySchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'issue-routing-policy-v1.schema.json'), 'utf8')
  );
  const reportSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'policy-decision-report-v1.schema.json'), 'utf8')
  );
  const policy = JSON.parse(await readFile(path.join(repoRoot, 'tools', 'priority', 'issue-routing-policy.json'), 'utf8'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);

  const validatePolicy = ajv.compile(policySchema);
  const policyValid = validatePolicy(policy);
  assert.equal(policyValid, true, JSON.stringify(validatePolicy.errors, null, 2));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'policy-engine-schema-'));
  const eventPath = path.join(tmpDir, 'event.json');
  const reportPath = path.join(tmpDir, 'report.json');

  fs.writeFileSync(
    eventPath,
    `${JSON.stringify(
      {
        schema: 'incident-event@v1',
        sourceType: 'workflow-run',
        incidentClass: 'workflow-run-failure',
        severity: 'high',
        branch: 'develop',
        sha: 'abc123',
        signature: 'validate:failure',
        fingerprint: 'event-123',
        suggestedLabels: ['ci'],
        metadata: {}
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const result = await runPolicyEngine({
    argv: [
      'node',
      'policy-engine.mjs',
      '--event',
      eventPath,
      '--policy',
      path.join(repoRoot, 'tools', 'priority', 'issue-routing-policy.json'),
      '--branch-policy',
      path.join(repoRoot, 'tools', 'priority', 'policy.json'),
      '--report',
      reportPath
    ],
    now: new Date('2026-03-06T21:23:00Z'),
    repoRoot
  });

  assert.equal(result.exitCode, 0);
  const report = JSON.parse(await readFile(reportPath, 'utf8'));

  const validateReport = ajv.compile(reportSchema);
  const reportValid = validateReport(report);
  assert.equal(reportValid, true, JSON.stringify(validateReport.errors, null, 2));
  assert.equal(report.decision.priority, 'P1');
  assert.deepEqual(report.decision.labels, ['ci']);
});

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
import { runCanaryReplayConformance } from '../canary-replay-conformance.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('canary replay conformance report validates schema and preserves route metadata seams', async () => {
  const schema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'canary-replay-conformance-report-v1.schema.json'), 'utf8')
  );
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-replay-schema-'));
  const reportPath = path.join(tmpDir, 'replay-report.json');

  const result = await runCanaryReplayConformance({
    argv: [
      'node',
      'canary-replay-conformance.mjs',
      '--catalog',
      path.join(repoRoot, 'tools', 'priority', 'canary-signal-catalog.json'),
      '--policy',
      path.join(repoRoot, 'tools', 'priority', 'issue-routing-policy.json'),
      '--branch-policy',
      path.join(repoRoot, 'tools', 'priority', 'policy.json'),
      '--required-checks',
      path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'),
      '--report',
      reportPath,
      '--repo',
      'example/repo'
    ],
    now: new Date('2026-03-07T02:12:00Z'),
    repoRoot
  });

  assert.equal(result.exitCode, 0);
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));

  assert.ok(report.scenarios.every((scenario) => scenario.operations.length > 0));
  assert.ok(report.scenarios.every((scenario) => scenario.decisionSnapshots.length > 0));
  assert.ok(
    report.scenarios.every((scenario) =>
      scenario.decisionSnapshots.every((snapshot) => snapshot.policyDecision.schema === 'priority/policy-decision-report@v1')
    )
  );
});

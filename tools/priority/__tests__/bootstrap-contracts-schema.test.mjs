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
import { runBootstrapContracts } from '../bootstrap-contracts.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('bootstrap contracts report schema validates generated report and flags/label seams', async () => {
  const schema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'bootstrap-contracts-report-v1.schema.json'), 'utf8')
  );
  const reportDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bootstrap-contracts-schema-'));
  const reportPath = path.join(reportDir, 'report.json');
  const policyReportPath = path.join(reportDir, 'policy-report.json');

  const result = await runBootstrapContracts({
    argv: [
      'node',
      'bootstrap-contracts.mjs',
      '--repo',
      'example/repo',
      '--labels-policy',
      path.join(repoRoot, 'tools', 'policy', 'priority-bootstrap-labels.json'),
      '--report',
      reportPath,
      '--policy-report',
      policyReportPath,
      '--dry-run'
    ],
    repoRoot,
    runPolicyCheckFn: async ({ argv }) => {
      const reportArgIndex = argv.indexOf('--report');
      const outputPath = argv[reportArgIndex + 1];
      fs.writeFileSync(
        outputPath,
        `${JSON.stringify({ schema: 'priority/policy-report@v1', result: 'pass' }, null, 2)}\n`,
        'utf8'
      );
      return 0;
    }
  });

  assert.equal(result.exitCode, 0);
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.flags.dryRun, true);
  assert.ok(report.labels.desiredCount > 0);
  assert.ok(report.operations.every((entry) => typeof entry.wrote === 'boolean'));
});

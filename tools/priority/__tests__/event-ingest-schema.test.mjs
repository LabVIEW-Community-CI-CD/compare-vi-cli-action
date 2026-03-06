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
import { runEventIngest } from '../event-ingest.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('event-ingest report schema validates generated artifact with label/flag coverage', async () => {
  const incidentSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'incident-event-v1.schema.json'), 'utf8')
  );
  const reportSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'event-ingest-report-v1.schema.json'), 'utf8')
  );

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'event-ingest-schema-'));
  const inputPath = path.join(tmpDir, 'input.json');
  const reportPath = path.join(tmpDir, 'report.json');

  fs.writeFileSync(
    inputPath,
    `${JSON.stringify(
      {
        schema: 'priority/policy-report@v1',
        result: 'fail',
        repository: 'example/repo',
        summary: {
          totalDiffCount: 3,
          branchDiffCount: 2,
          rulesetDiffCount: 1
        }
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const result = await runEventIngest({
    argv: [
      'node',
      'event-ingest.mjs',
      '--source-type',
      'required-check-drift',
      '--input',
      inputPath,
      '--report',
      reportPath,
      '--dry-run'
    ],
    now: new Date('2026-03-06T21:10:00Z')
  });

  assert.equal(result.exitCode, 0);

  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  ajv.addSchema(incidentSchema, './incident-event-v1.schema.json');
  ajv.addSchema(incidentSchema, 'incident-event-v1.schema.json');
  const validate = ajv.compile(reportSchema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));

  assert.equal(report.flags.dryRun, true);
  assert.equal(report.flags.classOverride, false);
  assert.deepEqual(report.event.suggestedLabels, ['ci', 'governance']);
  assert.equal(report.event.severity, 'high');
});

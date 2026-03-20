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
import { DEFAULT_THRESHOLDS, runDependencyAudit } from '../dependency-audit.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('dependency audit schema validates the generated report', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'dependency-audit-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dependency-audit-schema-'));
  const outputPath = path.join(tmpDir, 'report.json');

  const result = await runDependencyAudit(
    {
      outputPath,
      rawOutputPath: path.join(tmpDir, 'npm-audit.json'),
      mode: 'observe',
      thresholds: { ...DEFAULT_THRESHOLDS },
    },
    {
      runAuditCommandFn: async () => ({
        command: 'node',
        args: ['npm-cli.js', 'audit', '--json'],
        stdout: `${JSON.stringify({
          auditReportVersion: 2,
          vulnerabilities: {},
          metadata: {
            vulnerabilities: {
              info: 0,
              low: 0,
              moderate: 0,
              high: 0,
              critical: 0,
              total: 0,
            },
            dependencies: {
              prod: 4,
              dev: 2,
              optional: 0,
              peer: 0,
              peerOptional: 0,
              total: 6,
            },
          },
        }, null, 2)}\n`,
        stderr: '',
        exitCode: 0,
        error: null,
      }),
      log: () => {},
      error: () => {},
    },
  );

  const report = JSON.parse(await readFile(outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(result.report.result, 'pass');
});

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
import { runCanaryCatalog } from '../canary-catalog.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function createAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

test('canary signal catalog fixture validates against schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'canary-signal-catalog-v1.schema.json');
  const catalogPath = path.join(repoRoot, 'tools', 'priority', 'canary-signal-catalog.json');

  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const catalog = JSON.parse(await readFile(catalogPath, 'utf8'));

  const validate = createAjv().compile(schema);
  const valid = validate(catalog);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.ok(Array.isArray(catalog.signals) && catalog.signals.length > 0);
});

test('canary report validates against schema and preserves label coverage', async () => {
  const catalogSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'canary-signal-catalog-v1.schema.json');
  const reportSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'canary-signal-catalog-report-v1.schema.json');
  const catalogPath = path.join(repoRoot, 'tools', 'priority', 'canary-signal-catalog.json');
  const reportSchema = JSON.parse(await readFile(reportSchemaPath, 'utf8'));
  const catalogSchema = JSON.parse(await readFile(catalogSchemaPath, 'utf8'));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-catalog-schema-'));
  const reportPath = path.join(tmpDir, 'report.json');

  const result = await runCanaryCatalog({
    argv: ['node', 'canary-catalog.mjs', '--catalog', catalogPath, '--report', reportPath],
    now: new Date('2026-03-06T22:30:00Z'),
    repoRoot
  });

  assert.equal(result.exitCode, 0);

  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  const ajv = createAjv();
  const validateCatalog = ajv.compile(catalogSchema);
  const validateReport = ajv.compile(reportSchema);
  const catalogSignalsFromReport = report.signals.map((signal) => ({
    id: signal.id,
    sourceType: signal.sourceType,
    incidentClass: signal.incidentClass,
    branch: signal.branch,
    signaturePattern: signal.signaturePattern,
    severity: signal.severity,
    owner: signal.owner,
    labels: signal.labels,
    expectedRoute: signal.expectedRoute
  }));

  const validCatalog = validateCatalog(result.report ? {
    schema: 'canary-signal-catalog@v1',
    schemaVersion: result.report.catalog.schemaVersion ?? '1.0.0',
    signals: catalogSignalsFromReport
  } : null);
  assert.equal(validCatalog, true, JSON.stringify(validateCatalog.errors, null, 2));

  const validReport = validateReport(report);
  assert.equal(validReport, true, JSON.stringify(validateReport.errors, null, 2));

  assert.equal(report.status, 'pass');
  assert.ok(report.catalog.signalCount >= 1);
  assert.ok(Object.keys(report.coverage.bySourceType).length >= 1);
  assert.ok(report.signals.every((signal) => Array.isArray(signal.expectedRoute.labels) && signal.expectedRoute.labels.length > 0));
});

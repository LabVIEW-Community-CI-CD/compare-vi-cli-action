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
import { DEFAULT_ROUTE_LABELS, DEFAULT_THRESHOLDS, runSecurityIntake } from '../security-intake.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function sampleAlert(overrides = {}) {
  return {
    number: 1,
    state: 'open',
    created_at: '2026-02-01T00:00:00Z',
    fixed_at: null,
    dismissed_at: null,
    auto_dismissed_at: null,
    html_url: 'https://example.test/alerts/1',
    security_advisory: {
      severity: 'moderate'
    },
    dependency: {
      package: {
        ecosystem: 'npm',
        name: 'brace-expansion'
      },
      manifest_path: 'package-lock.json'
    },
    ...overrides
  };
}

test('security intake schema validates generated report and asserts labels/flags coverage', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'security-intake-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const now = new Date('2026-03-06T12:00:00Z');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'security-intake-schema-'));
  const outputPath = path.join(tmpDir, 'report.json');

  const result = await runSecurityIntake(
    {
      outputPath,
      routeOnBreach: true,
      failOnBreach: false,
      failOnSkip: true,
      thresholds: {
        ...DEFAULT_THRESHOLDS,
        openModerateMax: 0
      }
    },
    {
      now,
      resolveRepositorySlugFn: () => 'example/repo',
      resolveTokenFn: () => ({ token: 'token', source: 'gh-token-env' }),
      listDependabotAlertsFn: async ({ state }) => {
        if (state === 'open') return [sampleAlert()];
        return [];
      },
      upsertRemediationIssueFn: async () => ({
        action: 'created',
        issueNumber: 7,
        issueUrl: 'https://example.test/issues/7',
        title: '[Security Intake] Vulnerability remediation required',
        labels: DEFAULT_ROUTE_LABELS
      })
    }
  );

  const report = JSON.parse(await readFile(outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));

  assert.equal(result.report.flags.routeOnBreach, true);
  assert.equal(result.report.flags.failOnSkip, true);
  assert.equal(result.report.authSource, 'gh-token-env');
  assert.deepEqual(result.report.route.labels, DEFAULT_ROUTE_LABELS);
  assert.equal(result.report.route.action, 'created');
  assert.equal(result.report.remediation.candidateCount, 1);
});

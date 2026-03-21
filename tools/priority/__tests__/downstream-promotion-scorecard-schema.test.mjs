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
import { runDownstreamPromotionScorecard } from '../downstream-promotion-scorecard.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('downstream promotion scorecard schema validates generated report payload', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'downstream-promotion-scorecard-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-schema-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const outputPath = path.join(tmpDir, 'scorecard.json');

  writeJson(successReportPath, {
    schema: 'priority/downstream-onboarding-success@v1',
    summary: {
      status: 'pass',
      repositoriesEvaluated: 2,
      totalBlockers: 0,
      totalWarnings: 1
    }
  });
  writeJson(feedbackReportPath, {
    schema: 'priority/downstream-onboarding-feedback@v1',
    inputs: {
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    execution: {
      status: 'pass',
      evaluateExitCode: 0,
      successExitCode: 0
    }
  });

  const result = runDownstreamPromotionScorecard({
    repo: 'example/repo',
    successReportPath,
    feedbackReportPath,
    outputPath
  });

  const report = JSON.parse(await readFile(outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.gates.feedbackReport.status, 'pass');
});

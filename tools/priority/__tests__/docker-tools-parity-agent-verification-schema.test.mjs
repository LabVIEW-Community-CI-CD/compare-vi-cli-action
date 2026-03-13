#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function makeAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

test('docker parity agent verification schema validates the bounded _agent receipt', async () => {
  const schema = JSON.parse(
    await readFile(
      path.join(repoRoot, 'docs', 'schemas', 'docker-tools-parity-agent-verification-v1.schema.json'),
      'utf8'
    )
  );
  const data = {
    schema: 'docker-tools-parity-agent-verification@v1',
    generatedAt: '2026-03-13T09:00:00.000Z',
    authoritativeSource: 'docker-tools-parity',
    reviewLoopReceiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
    overall: {
      status: 'passed',
      failedCheck: '',
      message: '',
      exitCode: 0
    },
    requirementsCoverage: {
      requirementTotal: 9,
      requirementCovered: 9,
      requirementUncovered: 0,
      uncoveredRequirementIds: [],
      unknownRequirementIds: []
    },
    artifacts: {
      reviewLoopReceiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
      requirementsSummaryPath: 'tests/results/docker-tools-parity/requirements-verification/verification-summary.json',
      traceMatrixJsonPath: 'tests/results/docker-tools-parity/requirements-verification/trace-matrix.json',
      traceMatrixHtmlPath: 'tests/results/docker-tools-parity/requirements-verification/trace-matrix.html'
    },
    recommendedReviewOrder: [
      'tests/results/docker-tools-parity/review-loop-receipt.json',
      'tests/results/_agent/verification/docker-review-loop-summary.json',
      'tests/results/docker-tools-parity/requirements-verification/verification-summary.json',
      'tests/results/docker-tools-parity/requirements-verification/trace-matrix.json',
      'tests/results/docker-tools-parity/requirements-verification/trace-matrix.html'
    ]
  };

  const validate = makeAjv().compile(schema);
  assert.equal(validate(data), true, JSON.stringify(validate.errors, null, 2));
});

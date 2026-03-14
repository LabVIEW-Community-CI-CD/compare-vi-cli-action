import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import {
  buildPublicLinuxDiagnosticsReviewSummary,
  parseArgs,
  runPublicLinuxDiagnosticsReviewSummary
} from '../public-linux-diagnostics-review-summary.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

async function loadFixture(relativePath) {
  return JSON.parse(await readFile(path.join(repoRoot, relativePath), 'utf8'));
}

async function loadSchema() {
  return JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'public-linux-diagnostics-review-summary-v1.schema.json'), 'utf8')
  );
}

function makeAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

test('parseArgs accepts explicit review-summary surface overrides', () => {
  const options = parseArgs([
    'node',
    'tools/priority/public-linux-diagnostics-review-summary.mjs',
    '--dispatch',
    'dispatch.json',
    '--review-summary',
    'review.json',
    '--decision',
    'decision.json',
    '--out-json',
    'summary.json',
    '--out-md',
    'summary.md'
  ]);

  assert.equal(options.dispatchPath, 'dispatch.json');
  assert.equal(options.reviewSummaryPath, 'review.json');
  assert.equal(options.decisionPath, 'decision.json');
  assert.equal(options.outputJsonPath, 'summary.json');
  assert.equal(options.outputMarkdownPath, 'summary.md');
});

test('runPublicLinuxDiagnosticsReviewSummary writes deterministic JSON and Markdown when a decision exists', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'public-linux-review-summary-'));
  const dispatchPath = path.join(tempRoot, 'dispatch.json');
  const reviewPath = path.join(tempRoot, 'review.json');
  const decisionPath = path.join(tempRoot, 'decision.json');
  const outputJsonPath = path.join(tempRoot, 'summary.json');
  const outputMarkdownPath = path.join(tempRoot, 'summary.md');

  await fs.promises.writeFile(
    dispatchPath,
    JSON.stringify(await loadFixture('tools/priority/__fixtures__/diagnostics/public-linux-diagnostics-workflow-dispatch.json'))
  );
  await fs.promises.writeFile(
    reviewPath,
    JSON.stringify(await loadFixture('tools/priority/__fixtures__/handoff/docker-review-loop-summary.json'))
  );
  await fs.promises.writeFile(
    decisionPath,
    JSON.stringify(await loadFixture('tools/priority/__fixtures__/handoff/human-go-no-go-decision.json'))
  );

  const result = await runPublicLinuxDiagnosticsReviewSummary({
    argv: [
      'node',
      'tools/priority/public-linux-diagnostics-review-summary.mjs',
      '--dispatch',
      dispatchPath,
      '--review-summary',
      reviewPath,
      '--decision',
      decisionPath,
      '--out-json',
      outputJsonPath,
      '--out-md',
      outputMarkdownPath
    ],
    now: new Date('2026-03-14T14:40:00Z')
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.payload.review.readyForHumanDecision, true);
  assert.equal(result.payload.decision.state, 'recorded');
  assert.equal(result.payload.review.sessionComplete, true);
  assert.equal(result.payload.review.blocking, true);

  const schema = await loadSchema();
  const validate = makeAjv().compile(schema);
  const payload = JSON.parse(await readFile(outputJsonPath, 'utf8'));
  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));

  const markdown = await readFile(outputMarkdownPath, 'utf8');
  assert.match(markdown, /Public Linux Diagnostics Review Summary/);
  assert.match(markdown, /human decision recorded: `true`/);
  assert.match(markdown, /decision: `nogo`/);
});

test('runPublicLinuxDiagnosticsReviewSummary keeps the human decision pending when no decision file exists', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'public-linux-review-summary-pending-'));
  const dispatchPath = path.join(tempRoot, 'dispatch.json');
  const reviewPath = path.join(tempRoot, 'review.json');

  await fs.promises.writeFile(
    dispatchPath,
    JSON.stringify(await loadFixture('tools/priority/__fixtures__/diagnostics/public-linux-diagnostics-workflow-dispatch.json'))
  );
  await fs.promises.writeFile(
    reviewPath,
    JSON.stringify(await loadFixture('tools/priority/__fixtures__/handoff/docker-review-loop-summary.json'))
  );

  const result = await runPublicLinuxDiagnosticsReviewSummary({
    argv: [
      'node',
      'tools/priority/public-linux-diagnostics-review-summary.mjs',
      '--dispatch',
      dispatchPath,
      '--review-summary',
      reviewPath
    ],
    now: new Date('2026-03-14T14:40:00Z')
  });

  assert.equal(result.payload.decision.state, 'pending');
  assert.equal(result.payload.review.humanDecisionRecorded, false);
  assert.equal(result.payload.review.sessionComplete, false);
  assert.equal(result.payload.review.readyForHumanDecision, true);
});

test('runPublicLinuxDiagnosticsReviewSummary fails closed on corrupt required inputs', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'public-linux-review-summary-bad-'));
  const dispatchPath = path.join(tempRoot, 'dispatch.json');
  const reviewPath = path.join(tempRoot, 'review.json');
  await fs.promises.writeFile(dispatchPath, '{not-json');
  await fs.promises.writeFile(reviewPath, '{}');

  await assert.rejects(
    () =>
      runPublicLinuxDiagnosticsReviewSummary({
        argv: [
          'node',
          'tools/priority/public-linux-diagnostics-review-summary.mjs',
          '--dispatch',
          dispatchPath,
          '--review-summary',
          reviewPath
        ]
      }),
    /Dispatch receipt is not valid JSON/
  );
});

test('buildPublicLinuxDiagnosticsReviewSummary preserves the shared artifact order for operator review', async () => {
  const payload = buildPublicLinuxDiagnosticsReviewSummary({
    dispatchReceipt: await loadFixture('tools/priority/__fixtures__/diagnostics/public-linux-diagnostics-workflow-dispatch.json'),
    reviewSummary: await loadFixture('tools/priority/__fixtures__/handoff/docker-review-loop-summary.json'),
    decision: null,
    dispatchPath: 'tests/results/_agent/diagnostics/public-linux-diagnostics-workflow-dispatch.json',
    reviewSummaryPath: 'tests/results/_agent/verification/docker-review-loop-summary.json',
    decisionPath: 'tests/results/_agent/handoff/human-go-no-go-decision.json',
    outputJsonPath: 'tests/results/_agent/diagnostics/public-linux-diagnostics-review-summary.json',
    outputMarkdownPath: 'tests/results/_agent/diagnostics/public-linux-diagnostics-review-summary.md',
    generatedAt: '2026-03-14T14:40:00Z'
  });

  assert.deepEqual(payload.diagnostics.recommendedReviewOrder, [
    'tests/results/docker-tools-parity/review-loop-receipt.json',
    'tests/results/_agent/verification/docker-review-loop-summary.json',
    'tests/results/docker-tools-parity/requirements-verification/verification-summary.json',
    'tests/results/docker-tools-parity/requirements-verification/trace-matrix.json',
    'tests/results/docker-tools-parity/requirements-verification/trace-matrix.html'
  ]);
});

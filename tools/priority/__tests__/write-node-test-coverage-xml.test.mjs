#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { buildCoberturaXml, extractCoverageMetrics, materializeCoverageXml, parseArgs } from '../write-node-test-coverage-xml.mjs';

test('extractCoverageMetrics parses aggregate node coverage summary', () => {
  const sample = `
ℹ start of coverage report
ℹ ----------------------------------------------------------
ℹ file      | line % | branch % | funcs % | uncovered lines
ℹ ----------------------------------------------------------
ℹ ----------------------------------------------------------
ℹ all files | 100.00 |   87.50 |  92.30 |
ℹ ----------------------------------------------------------
ℹ end of coverage report
`;
  const metrics = extractCoverageMetrics(sample);
  assert.deepEqual(metrics, {
    lineRatePercent: 100,
    branchRatePercent: 87.5,
    functionRatePercent: 92.3
  });
});

test('buildCoberturaXml writes aggregate line and branch rates', () => {
  const xml = buildCoberturaXml({
    lineRatePercent: 100,
    branchRatePercent: 87.5,
    functionRatePercent: 92.3,
    lineThreshold: 75
  });
  assert.match(xml, /line-rate="1.0000"/);
  assert.match(xml, /branch-rate="0.8750"/);
  assert.match(xml, /thresholds line="75"/);
});

test('parseArgs accepts explicit paths and threshold', () => {
  const parsed = parseArgs(['--input', 'in.log', '--output', 'coverage.xml', '--line-threshold', '80']);
  assert.deepEqual(parsed, {
    input: 'in.log',
    output: 'coverage.xml',
    lineThreshold: 80
  });
});

test('parseArgs returns help sentinel', () => {
  assert.deepEqual(parseArgs(['--help']), { help: true });
});

test('materializeCoverageXml writes output on passing threshold', async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'coverage-xml-'));
  const inputPath = path.join(tempDir, 'node-test.log');
  const outputPath = path.join(tempDir, 'coverage.xml');
  await fs.writeFile(inputPath, `
ℹ start of coverage report
ℹ all files | 100.00 |   87.50 |  92.30 |
ℹ end of coverage report
`, 'utf8');

  const result = await materializeCoverageXml({
    inputPath,
    outputPath,
    lineThreshold: 75
  });

  const xml = await fs.readFile(outputPath, 'utf8');
  assert.equal(result.metrics.lineRatePercent, 100);
  assert.match(xml, /coverage line-rate="1.0000"/);
});

test('materializeCoverageXml fails when threshold is not met', async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'coverage-xml-'));
  const inputPath = path.join(tempDir, 'node-test.log');
  const outputPath = path.join(tempDir, 'coverage.xml');
  await fs.writeFile(inputPath, `
ℹ start of coverage report
ℹ all files | 48.72 |   66.67 |  50.00 |
ℹ end of coverage report
`, 'utf8');

  await assert.rejects(
    materializeCoverageXml({
      inputPath,
      outputPath,
      lineThreshold: 75
    }),
    /below threshold 75/
  );
});

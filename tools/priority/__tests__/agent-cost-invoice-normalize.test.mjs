#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  INPUT_SCHEMA,
  buildNormalizedInvoiceTurnFromMetadata,
  parseArgs,
  runAgentCostInvoiceNormalize
} from '../agent-cost-invoice-normalize.mjs';

const repoRoot = path.resolve(process.cwd());
const fixtureRoot = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('parseArgs requires metadata path and captures output override', () => {
  const parsed = parseArgs([
    'node',
    'agent-cost-invoice-normalize.mjs',
    '--metadata',
    'private-invoice.json',
    '--output',
    'invoice-turn.json'
  ]);

  assert.equal(parsed.metadataPath, 'private-invoice.json');
  assert.equal(parsed.outputPath, 'invoice-turn.json');
});

test('buildNormalizedInvoiceTurnFromMetadata derives invoice id and unit price from local metadata', () => {
  const metadata = readJson(path.join(fixtureRoot, 'private-invoice-metadata-sample.json'));
  const result = buildNormalizedInvoiceTurnFromMetadata(metadata);

  assert.equal(result.report.schema, 'priority/agent-cost-invoice-turn@v1');
  assert.equal(result.report.invoiceId, 'HQ1VJLMV-0027');
  assert.equal(result.report.billingPeriod.openedAt, '2026-03-21T10:01:07.000-07:00');
  assert.equal(result.report.credits.purchased, 10000);
  assert.equal(result.report.credits.unitPriceUsd, 0.04);
  assert.equal(result.report.billing.prepaidUsd, 400);
  assert.equal(result.report.policy.activationState, 'active');
  assert.equal(result.report.policy.fundingPurpose, 'operational');
  assert.equal(result.report.provenance.sourcePath, 'C:/Users/operator/Downloads/Invoice-HQ1VJLMV-0027.pdf');
});

test('runAgentCostInvoiceNormalize writes a normalized invoice-turn receipt from local metadata', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-invoice-normalize-'));
  const outputPath = path.join(tmpDir, 'invoice-turn.json');
  const result = runAgentCostInvoiceNormalize({
    metadataPath: path.join(fixtureRoot, 'private-invoice-metadata-sample.json'),
    outputPath
  });

  assert.equal(result.report.invoiceId, 'HQ1VJLMV-0027');
  assert.equal(result.report.credits.unitPriceUsd, 0.04);
  assert.equal(fs.existsSync(outputPath), true);
});

test('agent-cost-invoice-normalize CLI writes a receipt directly', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-invoice-normalize-cli-'));
  const outputPath = path.join(tmpDir, 'invoice-turn.json');
  const result = spawnSync(
    process.execPath,
    [
      path.join('tools', 'priority', 'agent-cost-invoice-normalize.mjs'),
      '--metadata',
      path.join('tools', 'priority', '__fixtures__', 'agent-cost-rollup', 'private-invoice-metadata-sample.json'),
      '--output',
      outputPath
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[agent-cost-invoice-normalize\] wrote /);
  assert.equal(fs.existsSync(outputPath), true);
});

test('local private invoice metadata fixture stays on the local-only input schema', () => {
  const metadata = readJson(path.join(fixtureRoot, 'private-invoice-metadata-sample.json'));
  assert.equal(metadata.schema, INPUT_SCHEMA);
});

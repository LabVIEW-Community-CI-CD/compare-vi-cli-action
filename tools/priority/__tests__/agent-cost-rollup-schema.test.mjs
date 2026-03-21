import '../../shims/punycode-userland.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runAgentCostRollup } from '../agent-cost-rollup.mjs';

const repoRoot = path.resolve(process.cwd());
const fixtureRoot = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('agent cost turn fixtures and rollup report match the checked-in schemas', () => {
  const invoiceTurnSchema = readJson(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-invoice-turn-v1.schema.json'));
  const turnSchema = readJson(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-turn-v1.schema.json'));
  const rollupSchema = readJson(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-rollup-v1.schema.json'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validateInvoiceTurn = ajv.compile(invoiceTurnSchema);
  const validateTurn = ajv.compile(turnSchema);
  const validateRollup = ajv.compile(rollupSchema);

  for (const fixtureName of ['invoice-turn-baseline.json', 'invoice-turn-next-baseline.json', 'invoice-turn-baseline-reconciled.json']) {
    const invoiceTurnFixture = readJson(path.join(fixtureRoot, fixtureName));
    const validInvoiceTurn = validateInvoiceTurn(invoiceTurnFixture);
    if (!validInvoiceTurn) {
      const errors = (validateInvoiceTurn.errors || [])
        .map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`)
        .join('\n');
      assert.fail(`Invoice turn fixture ${fixtureName} failed schema validation:\n${errors}`);
    }
  }

  for (const fixtureName of ['live-turn-estimated.json', 'background-turn-exact.json']) {
    const fixturePayload = readJson(path.join(fixtureRoot, fixtureName));
    const valid = validateTurn(fixturePayload);
    if (!valid) {
      const errors = (validateTurn.errors || [])
        .map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`)
        .join('\n');
      assert.fail(`Turn fixture ${fixtureName} failed schema validation:\n${errors}`);
    }
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-rollup-schema-'));
  const usageExportPath = path.join(tmpDir, 'usage-export.json');
  const accountBalancePath = path.join(tmpDir, 'account-balance.json');
  writeJson(usageExportPath, {
    schema: 'priority/agent-cost-usage-export@v1',
    generatedAt: '2026-03-21T20:20:00.000Z',
    reportWindow: {
      startDate: '2026-03-15',
      endDate: '2026-03-20',
      rowCount: 6
    },
    usageType: 'codex',
    totals: {
      usageCredits: 10559.88,
      usageQuantity: 211197.6
    },
    sourceKind: 'operator-usage-export',
    sourcePathEvidence: 'usage-export.csv',
    operatorNote: 'Current partial usage window.'
  });
  writeJson(accountBalancePath, {
    schema: 'priority/agent-cost-account-balance@v1',
    generatedAt: '2026-03-21T20:21:00.000Z',
    effectiveAt: '2026-03-21T20:21:00.000Z',
    plan: {
      name: 'Business',
      renewsAt: '2026-04-15T00:00:00.000Z'
    },
    balances: {
      totalCredits: 27500,
      usedCredits: 15800,
      remainingCredits: 11700
    },
    sourceKind: 'operator-account-balance',
    sourcePathEvidence: 'account-balance',
    operatorNote: 'Current account balance snapshot.'
  });
  const result = runAgentCostRollup({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turnReportPaths: [
      path.join(fixtureRoot, 'live-turn-estimated.json'),
      path.join(fixtureRoot, 'background-turn-exact.json')
    ],
    invoiceTurnPaths: [path.join(fixtureRoot, 'invoice-turn-baseline.json')],
    usageExportPaths: [usageExportPath],
    accountBalancePaths: [accountBalancePath],
    outputPath: path.join(tmpDir, 'agent-cost-rollup.json')
  });

  const validRollup = validateRollup(result.report);
  if (!validRollup) {
    const errors = (validateRollup.errors || [])
      .map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`)
      .join('\n');
    assert.fail(`Agent cost rollup report failed schema validation:\n${errors}`);
  }
});

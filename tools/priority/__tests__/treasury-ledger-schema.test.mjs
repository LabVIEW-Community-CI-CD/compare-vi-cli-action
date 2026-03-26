#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runTreasuryLedger } from '../treasury-ledger.mjs';

const repoRoot = path.resolve(process.cwd());
const fixtureRoot = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup');
const usageHeader = 'date_partition,account_id,account_user_id,email,name,public_id,usage_type,usage_credits,usage_quantity,usage_units';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function writeCsv(filePath, csvText) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${csvText}\n`, 'utf8');
}

function enumerateDates(startDate, endDate) {
  const dates = [];
  let current = new Date(`${startDate}T00:00:00Z`);
  const end = new Date(`${endDate}T00:00:00Z`);

  while (current <= end) {
    dates.push(current.toISOString().slice(0, 10));
    current = new Date(current.getTime() + 86400000);
  }

  return dates;
}

function buildUsageExportCsv({
  startDate,
  endDate,
  accountId = 'acct-001',
  accountUserId = 'user-001',
  email = 'operator@example.com',
  name = 'Operator Example',
  publicId = 'user-example-001',
  usageType = 'codex',
  usageCredits = 1.25,
  usageQuantity = 25,
  usageUnits = 'counts'
}) {
  const rows = enumerateDates(startDate, endDate).map((date) =>
    [date, accountId, accountUserId, email, name, publicId, usageType, usageCredits, usageQuantity, usageUnits].join(',')
  );

  return [usageHeader, ...rows].join('\n');
}

function createInvoiceMetadata(tmpDir) {
  const sample = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'private-invoice-metadata-sample.json'), 'utf8'));
  const invoiceMetadataPath = path.join(tmpDir, 'HQ1VJLMV-0030.private.json');
  writeJson(invoiceMetadataPath, {
    ...sample,
    invoiceId: 'HQ1VJLMV-0030',
    sourcePath: 'C:/Users/sveld/Downloads/Invoice-HQ1VJLMV-0030.pdf',
    creditsPurchased: 5000,
    prepaidUsd: 200,
    replenishmentReason: 'post-exhaustion',
    exhaustionObservedAt: '2026-03-25T23:50:00Z',
    resumeObservedAt: '2026-03-26T00:12:00Z'
  });
  return invoiceMetadataPath;
}

function createCostRollup(tmpDir) {
  const costRollupPath = path.join(tmpDir, 'agent-cost-rollup.json');
  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    generatedAt: '2026-03-26T00:15:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      selectedInvoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0030'
    },
    summary: {
      metrics: {
        creditsRemaining: 4998.75,
        estimatedPrepaidUsdRemaining: 199.95
      }
    },
    billingWindow: {
      invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0030',
      invoiceId: 'HQ1VJLMV-0030',
      openedAt: '2026-03-26T00:10:00Z',
      activationState: 'active',
      fundingPurpose: 'operational',
      sourceKind: 'operator-invoice',
      sourcePathEvidence: 'C:/Users/sveld/Downloads/Invoice-HQ1VJLMV-0030.pdf',
      operatorNote: 'Operational funding window selected for treasury tests.'
    }
  });
  return costRollupPath;
}

test('treasury ledger receipt and nested normalized receipts validate against the checked-in schemas', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-ledger-schema-'));
  const outputPath = path.join(tmpDir, 'runtime', 'treasury-ledger.json');
  const handoffOutputPath = path.join(tmpDir, 'handoff', 'treasury-ledger.json');
  const usageExportCsvPath = path.join(
    tmpDir,
    'LabVIEW Open-Source Initiative Credit Usage Report (Mar 15 - Mar 24).csv'
  );

  writeCsv(
    usageExportCsvPath,
    buildUsageExportCsv({
      startDate: '2026-03-15',
      endDate: '2026-03-24'
    })
  );

  const result = runTreasuryLedger(
    {
      repoRoot: tmpDir,
      invoiceMetadataPath: createInvoiceMetadata(tmpDir),
      usageExportCsvPath,
      costRollupPath: createCostRollup(tmpDir),
      operatorSteeringEventPath: path.join(tmpDir, 'operator-steering-event.json'),
      outputPath,
      handoffOutputPath
    },
    new Date('2026-03-25T17:00:00.000Z')
  );

  const ledgerSchema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'treasury-ledger-v1.schema.json'), 'utf8')
  );
  const invoiceTurnSchema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-invoice-turn-v1.schema.json'), 'utf8')
  );
  const usageExportSchema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-usage-export-v1.schema.json'), 'utf8')
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);

  const validateLedger = ajv.compile(ledgerSchema);
  const validateInvoiceTurn = ajv.compile(invoiceTurnSchema);
  const validateUsageExport = ajv.compile(usageExportSchema);

  assert.equal(validateLedger(result.report), true, JSON.stringify(validateLedger.errors, null, 2));
  assert.equal(result.report.schema, 'priority/treasury-ledger@v1');
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.schedulerState.status, 'pass');
  assert.equal(result.report.schedulerState.status, result.report.summary.status);
  assert.equal(result.report.remainingCapitalPosture.status, 'resolved');
  assert.equal(result.report.summary.remainingCapitalStatus, 'resolved');
  assert.equal(result.report.observedBurn.filenameRangeStatus, 'match');

  const invoiceTurn = JSON.parse(fs.readFileSync(result.report.inputs.normalizedInvoiceTurnPath, 'utf8'));
  const usageExport = JSON.parse(fs.readFileSync(result.report.inputs.normalizedUsageExportPath, 'utf8'));

  assert.equal(validateInvoiceTurn(invoiceTurn), true, JSON.stringify(validateInvoiceTurn.errors, null, 2));
  assert.equal(validateUsageExport(usageExport), true, JSON.stringify(validateUsageExport.errors, null, 2));
  assert.equal(invoiceTurn.schema, 'priority/agent-cost-invoice-turn@v1');
  assert.equal(usageExport.schema, 'priority/agent-cost-usage-export@v1');
  assert.equal(usageExport.reportWindow.startDate, '2026-03-15');
  assert.equal(usageExport.reportWindow.endDate, '2026-03-24');
});

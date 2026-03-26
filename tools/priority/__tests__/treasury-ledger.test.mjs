#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

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
    operatorNote: 'Local-only replenishment metadata for treasury-ledger tests.',
    replenishmentReason: 'post-exhaustion',
    exhaustionObservedAt: '2026-03-25T23:50:00Z',
    resumeObservedAt: '2026-03-26T00:12:00Z'
  });
  return invoiceMetadataPath;
}

function createCostRollup(tmpDir, invoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0030') {
  const costRollupPath = path.join(tmpDir, 'agent-cost-rollup.json');
  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    generatedAt: '2026-03-26T00:15:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      selectedInvoiceTurnId: invoiceTurnId
    },
    summary: {
      metrics: {
        creditsRemaining: 4998.75,
        estimatedPrepaidUsdRemaining: 199.95
      }
    },
    billingWindow: {
      invoiceTurnId,
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

function createTreasuryLedgerInputs(tmpDir, { filenameStartLabel, filenameEndLabel, observedEndDate }) {
  const usageExportCsvPath = path.join(
    tmpDir,
    `LabVIEW Open-Source Initiative Credit Usage Report (${filenameStartLabel} - ${filenameEndLabel}).csv`
  );

  writeCsv(
    usageExportCsvPath,
    buildUsageExportCsv({
      startDate: '2026-03-15',
      endDate: observedEndDate
    })
  );

  return {
    invoiceMetadataPath: createInvoiceMetadata(tmpDir),
    usageExportCsvPath,
    costRollupPath: createCostRollup(tmpDir),
    operatorSteeringEventPath: path.join(tmpDir, 'operator-steering-event.json'),
    outputPath: path.join(tmpDir, 'runtime', 'treasury-ledger.json'),
    handoffOutputPath: path.join(tmpDir, 'handoff', 'treasury-ledger.json')
  };
}

function createAutoDiscoveryFixture(tmpDir, { filenameStartLabel, filenameEndLabel, observedEndDate, rollupInvoiceTurnId }) {
  const treasuryDir = path.join(tmpDir, 'tests', 'results', '_agent', 'cost', 'treasury');
  const costDir = path.join(tmpDir, 'tests', 'results', '_agent', 'cost');
  const runtimeDir = path.join(tmpDir, 'tests', 'results', '_agent', 'runtime');
  const usageExportCsvPath = path.join(
    tmpDir,
    `LabVIEW Open-Source Initiative Credit Usage Report (${filenameStartLabel} - ${filenameEndLabel}).csv`
  );

  writeCsv(
    usageExportCsvPath,
    buildUsageExportCsv({
      startDate: '2026-03-15',
      endDate: observedEndDate
    })
  );

  fs.mkdirSync(treasuryDir, { recursive: true });
  fs.copyFileSync(createInvoiceMetadata(tmpDir), path.join(treasuryDir, 'HQ1VJLMV-0030.private-metadata.local.json'));
  fs.mkdirSync(runtimeDir, { recursive: true });
  writeJson(path.join(runtimeDir, 'operator-steering-event.json'), {
    schema: 'priority/operator-steering-event@v1',
    generatedAt: '2026-03-26T00:12:00Z',
    observedAt: '2026-03-26T00:12:00Z',
    steeringKind: 'operator-prompt-resume',
    eventKey: 'resume-001',
    source: { kind: 'bootstrap-resume-detection' }
  });
  writeJson(path.join(costDir, 'agent-cost-rollup.json'), {
    schema: 'priority/agent-cost-rollup@v1',
    generatedAt: '2026-03-26T00:15:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      selectedInvoiceTurnId: rollupInvoiceTurnId
    },
    summary: {
      metrics: {
        creditsRemaining: 9999.4975,
        estimatedPrepaidUsdRemaining: 399.9799
      }
    },
    billingWindow: {
      invoiceTurnId: rollupInvoiceTurnId,
      invoiceId: rollupInvoiceTurnId.endsWith('0030') ? 'HQ1VJLMV-0030' : 'HQ1VJLMV-0027',
      openedAt: rollupInvoiceTurnId.endsWith('0030') ? '2026-03-26T00:00:00-07:00' : '2026-03-21T10:01:07.000-07:00',
      activationState: 'active',
      fundingPurpose: 'operational',
      sourceKind: 'operator-invoice',
      sourcePathEvidence: 'C:/Users/sveld/Downloads/Invoice-HQ1VJLMV-0027.pdf',
      operatorNote: 'Auto-discovery treasury test rollup.'
    }
  });

  runTreasuryLedger(
    {
      repoRoot: tmpDir,
      usageExportCsvPath,
      costRollupPath: path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json'),
      operatorSteeringEventPath: path.join('tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'),
      outputPath: path.join('tests', 'results', '_agent', 'capital', 'seed.json'),
      handoffOutputPath: path.join('tests', 'results', '_agent', 'handoff', 'seed.json')
    },
    new Date('2026-03-25T17:00:00.000Z')
  );
}

test('runTreasuryLedger materializes normalized invoice-turn and usage-export receipts from local inputs', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-ledger-pass-'));
  const options = createTreasuryLedgerInputs(tmpDir, {
    filenameStartLabel: 'Mar 15',
    filenameEndLabel: 'Mar 24',
    observedEndDate: '2026-03-24'
  });

  const result = runTreasuryLedger(options, new Date('2026-03-25T17:00:00.000Z'));

  assert.equal(result.report.schema, 'priority/treasury-ledger@v1');
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.schedulerState.status, 'pass');
  assert.equal(result.report.schedulerState.status, result.report.summary.status);
  assert.equal(result.report.schedulerState.treasuryPosture, 'trusted-capital');
  assert.equal(result.report.remainingCapitalPosture.status, 'resolved');
  assert.equal(result.report.summary.remainingCapitalStatus, 'resolved');
  assert.equal(result.report.summary.remainingCapitalStatus, result.report.remainingCapitalPosture.status);
  assert.equal(result.report.summary.treasuryPosture, 'trusted-capital');
  assert.equal(result.report.observedBurn.status, 'observed');
  assert.equal(result.report.observedBurn.filenameRangeStatus, 'match');
  assert.equal(result.report.summary.blockerCount, 0);
  assert.equal(result.report.summary.warningCount, 0);
  assert.equal(result.report.fundingWindow.status, 'selected');
  assert.equal(result.report.events.replenishment.status, 'observed');
  assert.equal(result.report.events.replenishment.invoiceId, 'HQ1VJLMV-0030');
  assert.equal(result.report.events.hardStop.status, 'observed');
  assert.equal(result.report.events.resume.status, 'observed');
  assert.equal(result.report.summary.currentFundingWindowId, result.report.fundingWindow.invoiceTurnId);
  assert.equal(result.report.schedulerState.currentFundingWindowId, result.report.fundingWindow.invoiceTurnId);
  assert.equal(fs.existsSync(options.outputPath), true);
  assert.equal(fs.existsSync(options.handoffOutputPath), true);

  const invoiceTurnPath = result.report.inputs.normalizedInvoiceTurnPath;
  const usageExportPath = result.report.inputs.normalizedUsageExportPath;
  assert.ok(invoiceTurnPath);
  assert.ok(usageExportPath);
  assert.equal(fs.existsSync(invoiceTurnPath), true);
  assert.equal(fs.existsSync(usageExportPath), true);

  const invoiceTurn = JSON.parse(fs.readFileSync(invoiceTurnPath, 'utf8'));
  const usageExport = JSON.parse(fs.readFileSync(usageExportPath, 'utf8'));
  assert.equal(invoiceTurn.schema, 'priority/agent-cost-invoice-turn@v1');
  assert.equal(invoiceTurn.invoiceId, 'HQ1VJLMV-0030');
  assert.equal(invoiceTurn.billing.prepaidUsd, 200);
  assert.equal(invoiceTurn.policy.activationState, 'active');
  assert.equal(usageExport.schema, 'priority/agent-cost-usage-export@v1');
  assert.equal(usageExport.reportWindow.startDate, '2026-03-15');
  assert.equal(usageExport.reportWindow.endDate, '2026-03-24');
  assert.equal(usageExport.provenance.windowId, '2026-03-15..2026-03-24');
});

test('runTreasuryLedger fails closed when the usage CSV filename claims a broader range than the observed rows', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-ledger-fail-closed-'));
  const options = createTreasuryLedgerInputs(tmpDir, {
    filenameStartLabel: 'Mar 15',
    filenameEndLabel: 'Apr 15',
    observedEndDate: '2026-03-24'
  });

  const result = runTreasuryLedger(options, new Date('2026-03-25T17:00:00.000Z'));

  assert.equal(result.report.schema, 'priority/treasury-ledger@v1');
  assert.equal(result.report.summary.status, 'fail-closed');
  assert.equal(result.report.schedulerState.status, 'fail-closed');
  assert.equal(result.report.schedulerState.failClosed, true);
  assert.equal(result.report.schedulerState.treasuryPosture, 'trusted-capital');
  assert.equal(result.report.remainingCapitalPosture.status, 'resolved');
  assert.equal(result.report.summary.remainingCapitalStatus, 'resolved');
  assert.equal(result.report.observedBurn.status, 'fail-closed');
  assert.equal(result.report.observedBurn.filenameRangeStatus, 'mismatch');
  assert.equal(result.report.summary.blockerCount, result.report.summary.blockers.length);
  assert.ok(result.report.summary.blockerCount > 0);
  assert.equal(result.report.summary.warningCount, 0);
  assert.equal(fs.existsSync(options.outputPath), true);
  assert.equal(fs.existsSync(options.handoffOutputPath), true);
});

test('runTreasuryLedger auto-discovers local treasury evidence and marks post-exhaustion replenishment as unreconciled when rollup is still on the prior invoice turn', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-ledger-autodiscovery-'));
  createAutoDiscoveryFixture(tmpDir, {
    filenameStartLabel: 'Mar 15',
    filenameEndLabel: 'Mar 24',
    observedEndDate: '2026-03-24',
    rollupInvoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027'
  });

  const result = runTreasuryLedger(
    {
      repoRoot: tmpDir,
      outputPath: path.join('tests', 'results', '_agent', 'capital', 'treasury-ledger.json'),
      handoffOutputPath: path.join('tests', 'results', '_agent', 'handoff', 'treasury-ledger.json')
    },
    new Date('2026-03-26T06:30:00.000Z')
  );

  assert.match(result.report.inputs.invoiceMetadataPath || '', /HQ1VJLMV-0030\.private-metadata\.local\.json$/i);
  assert.match(result.report.inputs.normalizedUsageExportPath || '', /usage-exports/i);
  assert.equal(result.report.events.replenishment.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0030');
  assert.equal(result.report.fundingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0030');
  assert.equal(result.report.remainingCapitalPosture.status, 'replenished-but-unreconciled');
  assert.equal(result.report.remainingCapitalPosture.reason, 'funding-window-rollup-lagging-replenishment');
  assert.equal(result.report.schedulerState.status, 'pass');
  assert.equal(result.report.schedulerState.treasuryPosture, 'replenished-but-unreconciled');
  assert.equal(result.report.schedulerState.capitalModeRecommended, 'conserve');
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.remainingCapitalStatus, 'replenished-but-unreconciled');
  assert.equal(result.report.summary.treasuryPosture, 'replenished-but-unreconciled');
  assert.equal(result.report.summary.warningCount, 1);
  assert.equal(result.report.summary.warnings[0].code, 'treasury-reconciliation-pending');
});

test('runTreasuryLedger records current-cycle idle authority from fresh queue-empty runtime receipts', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'treasury-ledger-idle-authority-'));
  const options = createTreasuryLedgerInputs(tmpDir, {
    filenameStartLabel: 'Mar 15',
    filenameEndLabel: 'Mar 24',
    observedEndDate: '2026-03-24'
  });

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'), {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: '2026-03-25T16:59:00.000Z',
    status: 'idle',
    laneLifecycle: 'idle',
    activeLane: {
      laneId: 'queue-empty-monitoring',
      issue: null,
      actionType: 'monitoring-idle',
      outcome: 'queue-empty',
      reason: 'queue-empty',
      nextWakeCondition: 'future-agent-may-pivot',
      syntheticIdle: true
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'runtime', 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: '2026-03-25T16:59:30.000Z',
    outcome: 'queue-empty',
    activeLane: null
  });

  const result = runTreasuryLedger(
    {
      repoRoot: tmpDir,
      ...options,
      deliveryRuntimeStatePath: path.join('tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'),
      observerHeartbeatPath: path.join('tests', 'results', '_agent', 'runtime', 'observer-heartbeat.json')
    },
    new Date('2026-03-25T17:00:00.000Z')
  );

  assert.equal(result.report.schedulerState.currentCycleIdleStatus, 'observed');
  assert.equal(result.report.schedulerState.currentCycleIdleSource, 'delivery-and-observer');
  assert.equal(result.report.summary.currentCycleIdleStatus, 'observed');
  assert.equal(result.report.summary.currentCycleIdleSource, 'delivery-and-observer');
});

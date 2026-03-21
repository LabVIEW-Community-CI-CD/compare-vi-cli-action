#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  buildNormalizedUsageExportReceiptFromCsv,
  buildNormalizedUsageExportReceiptsFromCsvInputs,
  deriveDefaultOutputPath,
  parseArgs,
  runAgentCostUsageExportNormalize
} from '../agent-cost-usage-export-normalize.mjs';

const repoRoot = path.resolve(process.cwd());
const fixturePath = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup', 'usage-export-sample.csv');
const usageHeader = 'date_partition,account_id,account_user_id,email,name,public_id,usage_type,usage_credits,usage_quantity,usage_units';

function roundNumber(value) {
  return Number(Number(value).toFixed(6));
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
  rowCount,
  totalUsageCredits,
  totalUsageQuantity,
  baseUsageCredits,
  baseUsageQuantity,
  accountId = 'acct-001',
  accountUserId = 'user-001',
  email = 'operator@example.com',
  name = 'Operator Example',
  publicId = 'user-example-001',
  usageType = 'codex',
  usageUnits = 'counts'
}) {
  const dates = enumerateDates(startDate, endDate);
  const selectedDates = rowCount >= dates.length ? dates : [...dates.slice(0, rowCount - 1), dates[dates.length - 1]];
  const rows = selectedDates.map((date, index) => {
    const isLast = index === selectedDates.length - 1;
    const usageCredits = isLast
      ? roundNumber(totalUsageCredits - baseUsageCredits * (selectedDates.length - 1))
      : baseUsageCredits;
    const usageQuantity = isLast
      ? roundNumber(totalUsageQuantity - baseUsageQuantity * (selectedDates.length - 1))
      : baseUsageQuantity;
    return [date, accountId, accountUserId, email, name, publicId, usageType, usageCredits, usageQuantity, usageUnits].join(',');
  });

  return [usageHeader, ...rows].join('\n');
}

function writeUsageExportCsv(filePath, csvText) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${csvText}\n`, 'utf8');
}

function createContiguousUsageExportInputs(tmpDir) {
  const janPath = path.join(tmpDir, 'usage-export-2026-01-15.csv');
  const febPath = path.join(tmpDir, 'usage-export-2026-02-15.csv');
  const marPath = path.join(tmpDir, 'usage-export-2026-03-15.csv');

  writeUsageExportCsv(
    janPath,
    buildUsageExportCsv({
      startDate: '2026-01-15',
      endDate: '2026-02-14',
      rowCount: 17,
      totalUsageCredits: 5599.02,
      totalUsageQuantity: 111980.4,
      baseUsageCredits: 250,
      baseUsageQuantity: 5000
    })
  );
  writeUsageExportCsv(
    febPath,
    buildUsageExportCsv({
      startDate: '2026-02-15',
      endDate: '2026-03-14',
      rowCount: 26,
      totalUsageCredits: 29481.3,
      totalUsageQuantity: 589626.0,
      baseUsageCredits: 1000,
      baseUsageQuantity: 20000
    })
  );
  fs.copyFileSync(fixturePath, marPath);

  return [janPath, febPath, marPath];
}

test('parseArgs captures repeated usage export inputs and optional overrides', () => {
  const options = parseArgs([
    'node',
    'agent-cost-usage-export-normalize.mjs',
    '--input',
    'a.csv',
    '--input',
    'b.csv',
    '--output',
    'tests/results/_agent/cost/usage-exports/custom.json',
    '--source-kind',
    'operator-private-usage-export-csv',
    '--operator-note',
    'checked from local export'
  ]);

  assert.deepEqual(options.inputPaths, ['a.csv', 'b.csv']);
  assert.equal(options.outputPath, 'tests/results/_agent/cost/usage-exports/custom.json');
  assert.equal(options.sourceKind, 'operator-private-usage-export-csv');
  assert.equal(options.operatorNote, 'checked from local export');
});

test('deriveDefaultOutputPath keeps usage export receipts under the local cost namespace', () => {
  const derived = deriveDefaultOutputPath(fixturePath);

  assert.ok(derived.includes(path.join('tests', 'results', '_agent', 'cost', 'usage-exports')));
  assert.match(path.basename(derived), /usage-export-sample\.json$/);
});

test('buildNormalizedUsageExportReceiptFromCsv normalizes a single usage export receipt deterministically', () => {
  const csv = fs.readFileSync(fixturePath, 'utf8');
  const { report, outputPath } = buildNormalizedUsageExportReceiptFromCsv(csv, {
    inputPath: fixturePath,
    sourcePath: fixturePath,
    sourceSha256: 'local-private-fingerprint'
  }, new Date('2026-03-21T20:10:00.000Z'));

  assert.equal(report.schema, 'priority/agent-cost-usage-export@v1');
  assert.deepEqual(report.reportWindow, { startDate: '2026-03-15', endDate: '2026-03-20', rowCount: 6 });
  assert.equal(report.usageType, 'codex');
  assert.deepEqual(report.totals, { usageCredits: 10559.88, usageQuantity: 211197.6 });
  assert.equal(report.sourceKind, 'operator-private-usage-export-csv');
  assert.equal(report.sourcePathEvidence, fixturePath);
  assert.equal(report.operatorNote, 'Normalized from a local private account usage export CSV.');
  assert.equal(report.provenance.sourceSha256, 'local-private-fingerprint');
  assert.equal(report.provenance.windowId, '2026-03-15..2026-03-20');
  assert.equal(report.confidence.level, 'high');
  assert.equal(report.continuity.windowIndex, 1);
  assert.equal(report.rows, undefined);
  assert.equal(outputPath, deriveDefaultOutputPath(fixturePath));
});

test('buildNormalizedUsageExportReceiptsFromCsvInputs preserves three adjacent windows without double counting', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-usage-export-rollup-'));
  const [janPath, febPath, marPath] = createContiguousUsageExportInputs(tmpDir);
  const inputs = [janPath, febPath, marPath].map((inputPath) => {
    const raw = fs.readFileSync(inputPath, 'utf8');
    return {
      resolvedPath: inputPath,
      raw,
      sourceSha256: `sha256-${path.basename(inputPath)}`
    };
  });

  const { reports, outputPaths } = buildNormalizedUsageExportReceiptsFromCsvInputs(inputs, {
    sourceKind: 'operator-private-usage-export-csv'
  }, new Date('2026-03-21T20:10:00.000Z'));

  assert.equal(reports.length, 3);
  assert.equal(reports[0].reportWindow.startDate, '2026-01-15');
  assert.equal(reports[2].reportWindow.endDate, '2026-03-20');
  assert.equal(reports[0].continuity.isContiguousWithNext, true);
  assert.equal(reports[1].continuity.isContiguousWithPrevious, true);
  assert.equal(reports[1].continuity.isContiguousWithNext, true);
  assert.equal(reports[2].continuity.isContiguousWithPrevious, true);
  assert.equal(reports[0].continuity.windowCount, 3);
  assert.equal(reports[2].continuity.windowIndex, 3);
  assert.equal(reports[0].totals.usageCredits, 5599.02);
  assert.equal(reports[1].totals.usageCredits, 29481.3);
  assert.equal(reports[2].totals.usageCredits, 10559.88);
  assert.equal(outputPaths.length, 3);
  const totalUsageCredits = reports.reduce((sum, report) => sum + report.totals.usageCredits, 0);
  const totalUsageQuantity = reports.reduce((sum, report) => sum + report.totals.usageQuantity, 0);
  assert.equal(totalUsageCredits, 45640.2);
  assert.equal(totalUsageQuantity, 912804);
});

test('runAgentCostUsageExportNormalize writes receipts to the requested output directory for multiple windows', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-usage-export-run-'));
  const outputDir = path.join(tmpDir, 'usage-exports');
  const [janPath, febPath, marPath] = createContiguousUsageExportInputs(tmpDir);
  const result = runAgentCostUsageExportNormalize({
    inputPaths: [janPath, febPath, marPath],
    outputPath: outputDir
  }, new Date('2026-03-21T20:10:00.000Z'));

  assert.equal(result.reports.length, 3);
  assert.equal(fs.existsSync(path.join(outputDir, 'usage-export-2026-01-15.json')), true);
  assert.equal(fs.existsSync(path.join(outputDir, 'usage-export-2026-02-15.json')), true);
  assert.equal(fs.existsSync(path.join(outputDir, 'usage-export-2026-03-15.json')), true);
});

test('CLI entrypoint writes the usage export receipts on repeated window inputs', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-usage-export-cli-'));
  const outputDir = path.join(tmpDir, 'usage-exports');
  const [janPath, febPath, marPath] = createContiguousUsageExportInputs(tmpDir);
  const result = spawnSync(
    process.execPath,
    [
      path.join(repoRoot, 'tools', 'priority', 'agent-cost-usage-export-normalize.mjs'),
      '--input',
      janPath,
      '--input',
      febPath,
      '--input',
      marPath,
      '--output',
      outputDir
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /\[agent-cost-usage-export-normalize\] wrote /);
  assert.equal(fs.existsSync(outputDir), true);
});

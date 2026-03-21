import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { buildNormalizedUsageExportRollupFromCsvInputs } from '../agent-cost-usage-export-normalize.mjs';

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

test('normalized usage export rollup matches the checked-in schema', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-usage-export-schema-'));
  const janPath = path.join(tmpDir, 'usage-export-2026-01-15.csv');
  const febPath = path.join(tmpDir, 'usage-export-2026-02-15.csv');

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
  const marPath = path.join(tmpDir, 'usage-export-2026-03-15.csv');
  fs.copyFileSync(fixturePath, marPath);

  const inputs = [janPath, febPath, marPath].map((inputPath) => ({
    resolvedPath: inputPath,
    raw: fs.readFileSync(inputPath, 'utf8'),
    sourceSha256: `sha256-${path.basename(inputPath)}`
  }));
  const { report } = buildNormalizedUsageExportRollupFromCsvInputs(inputs, {
    sourceKind: 'operator-private-usage-export-csv'
  }, new Date('2026-03-21T20:10:00.000Z'));

  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-usage-export-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.windows.length, 3);
  assert.equal(report.transitions[0].status, 'adjacent');
});


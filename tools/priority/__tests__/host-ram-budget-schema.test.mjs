#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildHostRamBudgetReport } from '../host-ram-budget.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('host RAM budget schema validates the generated report', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'host-ram-budget-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const report = buildHostRamBudgetReport(
    {
      targetProfile: 'ni-linux-flag-combination',
      minimumParallelism: 1,
    },
    {
      totalmemFn: () => 16 * 1024 * 1024 * 1024,
      freememFn: () => 10 * 1024 * 1024 * 1024,
      availableParallelismFn: () => 12,
    },
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

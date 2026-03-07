#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { appendDecisionLedgerEntry } from '../decision-ledger.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('ops decision ledger payload validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'ops-decision-ledger-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const decision = {
    schema: 'priority/policy-decision-report@v1',
    generatedAt: '2026-03-07T04:00:00Z',
    event: { fingerprint: 'fp-100' },
    decision: { type: 'open-issue', labels: ['governance'] }
  };

  const appended = await appendDecisionLedgerEntry({
    decisionPath: 'ignored',
    ledgerPath: 'ignored',
    source: 'policy-engine',
    now: new Date('2026-03-07T04:10:00Z'),
    readDecisionFn: async () => decision,
    readLedgerFn: async () => ({
      schema: 'ops-decision-ledger@v1',
      generatedAt: null,
      entryCount: 0,
      entries: []
    }),
    writeJsonFn: async (ledgerPath, payload) => ({ ledgerPath, payload })
  });

  const ledger = appended.ledger;
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(ledger);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

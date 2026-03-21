import '../../shims/punycode-userland.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runAgentCostInvoiceNormalize } from '../agent-cost-invoice-normalize.mjs';

const repoRoot = path.resolve(process.cwd());
const fixtureRoot = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('local private invoice metadata fixture and normalized invoice-turn output match the checked-in schemas', () => {
  const metadataSchema = readJson(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-private-invoice-metadata-v1.schema.json'));
  const invoiceTurnSchema = readJson(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-invoice-turn-v1.schema.json'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validateMetadata = ajv.compile(metadataSchema);
  const validateInvoiceTurn = ajv.compile(invoiceTurnSchema);

  const metadataFixture = readJson(path.join(fixtureRoot, 'private-invoice-metadata-sample.json'));
  if (!validateMetadata(metadataFixture)) {
    const errors = (validateMetadata.errors || []).map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`).join('\n');
    assert.fail(`Private invoice metadata fixture failed schema validation:\n${errors}`);
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-private-invoice-schema-'));
  const result = runAgentCostInvoiceNormalize({
    metadataPath: path.join(fixtureRoot, 'private-invoice-metadata-sample.json'),
    outputPath: path.join(tmpDir, 'invoice-turn.json')
  });

  if (!validateInvoiceTurn(result.report)) {
    const errors = (validateInvoiceTurn.errors || []).map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`).join('\n');
    assert.fail(`Normalized invoice-turn output failed schema validation:\n${errors}`);
  }
});

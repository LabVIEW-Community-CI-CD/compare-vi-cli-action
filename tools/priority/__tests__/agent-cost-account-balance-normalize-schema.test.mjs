import '../../shims/punycode-userland.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runAgentCostAccountBalanceNormalize } from '../agent-cost-account-balance-normalize.mjs';

const repoRoot = path.resolve(process.cwd());
const fixtureRoot = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('normalized account balance receipts match the checked-in schema', () => {
  const schema = readJson(path.join(repoRoot, 'docs', 'schemas', 'agent-cost-account-balance-v1.schema.json'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-account-balance-schema-'));
  const result = runAgentCostAccountBalanceNormalize({
    snapshotPath: path.join(fixtureRoot, 'private-account-balance-sample.json'),
    outputPath: path.join(tmpDir, 'account-balance.json')
  });

  if (!validate(result.report)) {
    const errors = (validate.errors || []).map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`).join('\n');
    assert.fail(`Normalized account balance receipt failed schema validation:\n${errors}`);
  }
});

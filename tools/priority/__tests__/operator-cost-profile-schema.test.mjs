import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import Ajv2020 from 'ajv/dist/2020.js';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('operator cost profile policy matches the checked-in schema', () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'operator-cost-profile-v1.schema.json');
  const policyPath = path.join(repoRoot, 'tools', 'policy', 'operator-cost-profile.json');
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  const validate = ajv.compile(schema);
  const valid = validate(policy);

  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

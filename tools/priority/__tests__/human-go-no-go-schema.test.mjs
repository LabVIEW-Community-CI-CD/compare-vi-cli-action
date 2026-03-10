import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('human go/no-go decision schema validates the contract fixture', async () => {
  const schema = JSON.parse(
    await readFile(
      path.join(repoRoot, 'docs', 'schemas', 'human-go-no-go-decision-v1.schema.json'),
      'utf8',
    ),
  );
  const payload = JSON.parse(
    await readFile(
      path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'handoff', 'human-go-no-go-decision.json'),
      'utf8',
    ),
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(payload.schema, 'human-go-no-go-decision@v1');
  assert.equal(payload.decision.value, 'nogo');
  assert.equal(payload.nextIteration.recommendedAction, 'revise');
});

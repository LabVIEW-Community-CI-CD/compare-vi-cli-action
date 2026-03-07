import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildQueueReadinessReport } from '../queue-readiness.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('queue readiness report validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'queue-readiness-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const payload = buildQueueReadinessReport({
    repository: 'example/repo',
    now: new Date('2026-03-06T12:00:00.000Z'),
    orderedEligible: [201],
    candidates: [
      {
        number: 201,
        title: '[P1] deterministic ready',
        body: 'Coupling: independent\nRisk-Class: low',
        labels: [],
        updatedAt: '2026-03-06T11:00:00.000Z',
        eligible: true,
        reasons: [],
        priority: 1,
        coupling: 'independent',
        unresolvedOpenDependencies: [],
        checks: { ok: true },
        url: 'https://example.test/pr/201'
      }
    ]
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(payload);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

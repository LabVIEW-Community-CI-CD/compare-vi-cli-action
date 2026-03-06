import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import {
  summarizeWorkflowRuns,
  buildSloSummary,
  evaluateBreaches
} from '../slo-metrics.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('slo metrics schema validates generated payload', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'priority-slo-metrics-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const now = new Date('2026-03-06T12:00:00Z');
  const workflowSummary = summarizeWorkflowRuns(
    [
      {
        created_at: '2026-03-06T08:00:00Z',
        updated_at: '2026-03-06T08:10:00Z',
        conclusion: 'failure'
      },
      {
        created_at: '2026-03-06T09:00:00Z',
        updated_at: '2026-03-06T09:12:00Z',
        conclusion: 'success'
      },
      {
        created_at: '2026-03-06T10:00:00Z',
        updated_at: '2026-03-06T10:06:00Z',
        conclusion: 'skipped'
      }
    ],
    now
  );

  const workflowSummaries = [
    {
      workflow: 'commit-integrity.yml',
      runCount: 3,
      summary: workflowSummary
    }
  ];
  const summary = buildSloSummary(workflowSummaries);
  const thresholds = {
    failureRate: 0.3,
    skipRate: 0.25,
    mttrHours: 24,
    staleHours: 168,
    gateRegressions: 3
  };

  const payload = {
    schema: 'priority/slo-metrics@v1',
    generatedAt: now.toISOString(),
    repository: 'example/repo',
    lookbackDays: 30,
    thresholds,
    workflowSummaries,
    summary,
    breaches: evaluateBreaches(summary, thresholds),
    route: {
      action: 'none'
    }
  };

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(payload);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

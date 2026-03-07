import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { evaluateAdaptiveInflight, computeRetryPressure } from '../queue-supervisor.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('throughput-controller state payload validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'ops-throughput-controller-state-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const now = new Date('2026-03-06T12:00:00.000Z');
  const retryPressure = computeRetryPressure(
    {
      '101': { failures: ['2026-03-06T10:00:00.000Z'] },
      '102': { failures: ['2026-03-06T09:00:00.000Z', '2026-03-06T11:00:00.000Z'] }
    },
    10
  );
  const adaptive = evaluateAdaptiveInflight({
    maxInflight: 5,
    minInflight: 2,
    adaptiveCap: true,
    health: { successRate: 0.88, minSuccessRate: 0.8 },
    runtimeFleet: { totals: { queued: 1, inProgress: 2, stalled: 0 }, thresholds: { maxQueuedRuns: 6, maxInProgressRuns: 8 } },
    retryPressure,
    previousControllerState: { mode: 'guarded', upgradeStreak: 0 }
  });

  const payload = {
    schema: 'ops-throughput-controller-state@v1',
    generatedAt: now.toISOString(),
    repository: 'example/repo',
    mode: adaptive.mode,
    desiredMode: adaptive.desiredMode,
    targetCap: adaptive.effectiveMaxInflight,
    capByMode: adaptive.capByMode,
    adaptiveEnabled: adaptive.enabled,
    reasons: adaptive.reasons,
    metrics: adaptive.metrics,
    thresholds: adaptive.thresholds,
    hysteresis: adaptive.hysteresis,
    retryPressure,
    paused: false,
    pausedReasons: []
  };

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(payload);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

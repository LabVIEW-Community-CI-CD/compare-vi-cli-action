#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildThroughputScorecard } from '../throughput-scorecard.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('throughput-scorecard schema validates generated report payloads', () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'throughput-scorecard-v1.schema.json');
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const report = buildThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeState: {
      workerPool: {
        targetSlotCount: 4,
        occupiedSlotCount: 1,
        availableSlotCount: 3,
        releasedLaneCount: 1,
        utilizationRatio: 0.25
      },
      activeCodingLanes: 1
    },
    deliveryMemory: {
      summary: {
        totalTerminalPullRequestCount: 2,
        mergedPullRequestCount: 1,
        closedPullRequestCount: 1,
        hostedWaitEscapeCount: 1,
        meanTerminalDurationMinutes: 12.5,
        viHistorySuitePullRequestCount: 1
      }
    },
    queueReport: {
      inflight: 1,
      capacity: 1,
      effectiveMaxInflight: 2,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1512 }]
      }
    },
    inputPaths: {
      runtimeStatePath: 'tests/results/_agent/runtime/delivery-agent-state.json',
      deliveryMemoryPath: 'tests/results/_agent/runtime/delivery-memory.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json'
    },
    now: new Date('2026-03-21T03:10:00.000Z')
  });

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

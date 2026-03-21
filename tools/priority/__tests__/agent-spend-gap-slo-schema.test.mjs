#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { buildAgentSpendGapSlo } from '../agent-spend-gap-slo.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('agent-spend-gap-slo schema validates generated report payloads', () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'agent-spend-gap-slo-v1.schema.json');
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const report = buildAgentSpendGapSlo({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    costRollup: {
      schema: 'priority/agent-cost-rollup@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      turns: [
        {
          issueNumber: 1650,
          laneId: 'issue/origin-1650-agent-spend-gap-slo',
          turnId: 'turn-1',
          agentRole: 'live',
          providerId: 'codex-cli',
          effectiveModel: 'gpt-5.4',
          effectiveReasoningEffort: 'medium',
          amountUsd: 0.02,
          exactness: 'estimated',
          generatedAt: '2026-03-21T08:00:00.000Z',
          provenance: {
            usageObservedAt: '2026-03-21T08:00:00.000Z'
          }
        },
        {
          issueNumber: 1650,
          laneId: 'issue/origin-1650-agent-spend-gap-slo',
          turnId: 'turn-2',
          agentRole: 'live',
          providerId: 'codex-cli',
          effectiveModel: 'gpt-5.4',
          effectiveReasoningEffort: 'high',
          amountUsd: 0.03,
          exactness: 'exact',
          generatedAt: '2026-03-21T08:45:00.000Z',
          provenance: {
            usageObservedAt: '2026-03-21T08:45:00.000Z'
          }
        }
      ]
    },
    throughputScorecard: {
      schema: 'priority/throughput-scorecard@v1',
      summary: {
        status: 'warn',
        reasons: ['actionable-work-with-idle-worker-pool'],
        metrics: {
          currentWorkerUtilizationRatio: 0,
          readyPrInventory: 2,
          concurrentLaneActiveCount: 0,
          concurrentLaneDeferredCount: 0,
          hostedWaitEscapeCount: 0
        }
      }
    },
    inputPaths: {
      costRollupPath: {
        path: 'tests/results/_agent/cost/agent-cost-rollup.json',
        exists: true,
        error: null
      },
      throughputScorecardPath: {
        path: 'tests/results/_agent/throughput/throughput-scorecard.json',
        exists: true,
        error: null
      }
    },
    gapThresholdMinutes: 30,
    now: new Date('2026-03-21T09:00:00.000Z')
  });

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { buildFundedThroughputScorecard } from '../funded-throughput-scorecard.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('funded-throughput-scorecard schema validates generated report payloads', () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'funded-throughput-scorecard-v1.schema.json');
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const report = buildFundedThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    costRollup: {
      schema: 'priority/agent-cost-rollup@v1',
      summary: {
        metrics: {
          totalUsd: 20,
          exactUsd: 20,
          estimatedUsd: 0,
          actualUsdConsumed: 19.5,
          heuristicUsdDelta: 0.5,
          heuristicUsdDeltaRatio: 0.025641
        }
      },
      billingWindow: {
        invoiceTurnId: 'invoice-turn-001',
        invoiceId: 'invoice-001',
        openedAt: '2026-03-21T00:00:00.000Z',
        closedAt: '2026-03-21T12:00:00.000Z',
        fundingPurpose: 'operational',
        activationState: 'active',
        reconciliationStatus: 'actual-observed',
        selection: {
          mode: 'hold',
          calibrationWindowId: null
        },
        reconciledAt: '2026-03-21T12:30:00.000Z'
      }
    },
    throughputScorecard: {
      schema: 'priority/throughput-scorecard@v1',
      delivery: {
        totalTerminalPullRequestCount: 5,
        mergedPullRequestCount: 4,
        hostedWaitEscapeCount: 2
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
    now: new Date('2026-03-21T17:00:00.000Z')
  });

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { buildAverageIssueCostScorecard } from '../average-issue-cost-scorecard.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('average-issue-cost-scorecard schema validates generated report payloads', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'average-issue-cost-scorecard-v1.schema.json');
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const report = await buildAverageIssueCostScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    costRollup: {
      schema: 'priority/agent-cost-rollup@v1',
      turns: [
        {
          sourcePath: 'tests/results/_agent/cost/turns/turn-1.json',
          generatedAt: '2026-03-12T10:00:00.000Z',
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          issueNumber: 301,
          laneId: 'lane-1708',
          laneBranch: 'issue/origin-1708-average-issue-cost-over-time',
          sessionId: 'session-1708',
          turnId: 'turn-1',
          workerSlotId: 'worker-1',
          agentRole: 'live',
          providerId: 'openai',
          providerKind: 'api',
          providerRuntime: 'responses',
          executionPlane: 'local',
          requestedModel: 'gpt-5.4',
          effectiveModel: 'gpt-5.4',
          requestedReasoningEffort: 'medium',
          effectiveReasoningEffort: 'medium',
          operatorIntervened: false,
          steeringKind: null,
          steeringSource: null,
          steeringObservedAt: null,
          steeringNote: null,
          steeringInvoiceTurnId: null,
          usageUnitKind: 'token',
          usageUnitCount: 100,
          inputTokens: 60,
          cachedInputTokens: 0,
          outputTokens: 40,
          totalTokens: 100,
          exactness: 'exact',
          amountUsd: 5,
          amountSource: 'rate-card-estimate',
          rateCardId: 'rate-card-1',
          rateCardSource: 'checked-in-fixture',
          rateCardRetrievedAt: '2026-03-12T10:00:00.000Z',
          pricingBasis: 'token',
          provenance: {
            sourceSchema: 'priority/agent-cost-turn@v1',
            sourceReceiptPath: 'tests/results/_agent/cost/turns/turn-1.json',
            sourceReportPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
            usageObservedAt: '2026-03-12T10:00:00.000Z'
          }
        }
      ],
      billingWindow: {
        invoiceTurnId: 'invoice-turn-001',
        invoiceId: 'invoice-001',
        openedAt: '2026-03-11T00:00:00.000Z',
        closedAt: null,
        fundingPurpose: 'operational',
        activationState: 'active',
        reconciliationStatus: 'baseline-only',
        selection: {
          mode: 'hold',
          calibrationWindowId: null
        },
        reconciledAt: null
      },
      inputs: {
        invoiceTurnPaths: [{ path: 'tests/results/_agent/cost/invoice-turns/invoice-turn-001.json', exists: true, error: null }]
      }
    },
    costRollupInput: {
      path: 'tests/results/_agent/cost/agent-cost-rollup.json',
      exists: true,
      error: null
    },
    invoiceTurnInputs: [
      {
        path: 'tests/results/_agent/cost/invoice-turns/invoice-turn-001.json',
        exists: true,
        error: null,
        payload: {
          schema: 'priority/agent-cost-invoice-turn@v1',
          invoiceTurnId: 'invoice-turn-001',
          invoiceId: 'invoice-001',
          billingPeriod: {
            openedAt: '2026-03-11T00:00:00.000Z',
            closedAt: null
          },
          policy: {
            activationState: 'active',
            fundingPurpose: 'operational'
          },
          reconciliation: {
            status: 'baseline-only',
            reconciledAt: null
          },
          selection: {
            mode: 'hold',
            calibrationWindowId: null
          }
        }
      }
    ],
    fetchIssueFn: async () => ({
      number: 301,
      title: 'Example issue',
      state: 'open',
      updatedAt: '2026-03-21T00:00:00.000Z',
      url: 'https://example.test/301',
      labels: [],
      body: '',
      comments: []
    }),
    now: new Date('2026-03-21T21:00:00.000Z')
  });

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

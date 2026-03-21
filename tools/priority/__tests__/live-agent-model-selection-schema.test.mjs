#!/usr/bin/env node

import '../../shims/punycode-userland.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runLiveAgentModelSelection } from '../live-agent-model-selection.mjs';

const repoRoot = path.resolve(process.cwd());

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('live-agent model selection policy fixture and generated report match the checked-in schemas', () => {
  const policySchema = readJson('docs/schemas/live-agent-model-selection-policy-v1.schema.json');
  const reportSchema = readJson('docs/schemas/live-agent-model-selection-report-v1.schema.json');
  const policyFixture = readJson('tools/policy/live-agent-model-selection.json');

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validatePolicy = ajv.compile(policySchema);
  const validateReport = ajv.compile(reportSchema);

  assert.equal(validatePolicy(policyFixture), true, JSON.stringify(validatePolicy.errors, null, 2));

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'live-agent-model-selection-schema-'));
  const costRollupPath = path.join(tempDir, 'tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
  const throughputPath = path.join(tempDir, 'tests', 'results', '_agent', 'throughput', 'throughput-scorecard.json');
  const deliveryMemoryPath = path.join(tempDir, 'tests', 'results', '_agent', 'runtime', 'delivery-memory.json');
  const outputPath = path.join(tempDir, 'tests', 'results', '_agent', 'runtime', 'live-agent-model-selection.json');
  const policyPath = path.join(tempDir, 'tools', 'policy', 'live-agent-model-selection.json');

  writeJson(policyPath, {
    ...policyFixture,
    outputPath: path.relative(tempDir, outputPath).replace(/\\/g, '/'),
    previousReportPath: path.relative(tempDir, outputPath).replace(/\\/g, '/'),
    inputs: {
      costRollupPath: path.relative(tempDir, costRollupPath).replace(/\\/g, '/'),
      throughputScorecardPath: path.relative(tempDir, throughputPath).replace(/\\/g, '/'),
      deliveryMemoryPath: path.relative(tempDir, deliveryMemoryPath).replace(/\\/g, '/')
    }
  });
  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    generatedAt: '2026-03-21T13:10:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turns: [
      {
        schema: 'priority/agent-cost-turn@v1',
        invoiceTurnId: 'invoice-turn-1',
        agentRole: 'live',
        providerId: 'local-codex',
        effectiveModel: 'gpt-5.4',
        effectiveReasoningEffort: 'xhigh',
        amountUsd: 11.1,
        amountKind: 'estimated'
      }
    ]
  });
  writeJson(throughputPath, {
    schema: 'priority/throughput-scorecard@v1',
    generatedAt: '2026-03-21T13:11:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      status: 'pass',
      reasons: [],
      metrics: {
        readyPrInventory: 2,
        mergeQueueOccupancyRatio: 1
      }
    }
  });
  writeJson(deliveryMemoryPath, {
    schema: 'priority/delivery-memory@v1',
    generatedAt: '2026-03-21T13:12:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      totalTerminalPullRequestCount: 2,
      mergedPullRequestCount: 2,
      hostedWaitEscapeCount: 0,
      meanTerminalDurationMinutes: 9
    }
  });

  const result = runLiveAgentModelSelection({
    policyPath,
    costRollupPath,
    throughputScorecardPath: throughputPath,
    deliveryMemoryPath,
    outputPath
  });

  assert.equal(validateReport(result.report), true, JSON.stringify(validateReport.errors, null, 2));
});

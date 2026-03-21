#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  buildLiveAgentModelSelectionProjection,
  evaluateLiveAgentModelSelection,
  parseArgs,
  runLiveAgentModelSelection
} from '../live-agent-model-selection.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createTempTelemetryRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'live-agent-model-selection-'));
}

function writeTelemetrySet(root, options = {}) {
  const {
    policyMode = 'recommend-only',
    currentModel = 'gpt-5.4',
    currentReasoningEffort = 'xhigh',
    amountUsd = 12.8,
    throughputStatus = 'pass',
    throughputReasons = [],
    readyInventory = 3,
    queueOccupancyRatio = 1,
    totalTerminalPullRequests = 4,
    mergedPullRequests = 4,
    hostedWaitEscapeCount = 0,
    meanTerminalDurationMinutes = 14,
    previousReport = null,
    forcedModel = null,
    forcedReasoningEffort = null
  } = options;
  const policyPath = path.join(root, 'tools', 'policy', 'live-agent-model-selection.json');
  const costRollupPath = path.join(root, 'tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
  const throughputPath = path.join(root, 'tests', 'results', '_agent', 'throughput', 'throughput-scorecard.json');
  const deliveryMemoryPath = path.join(root, 'tests', 'results', '_agent', 'runtime', 'delivery-memory.json');
  const outputPath = path.join(root, 'tests', 'results', '_agent', 'runtime', 'live-agent-model-selection.json');

  writeJson(policyPath, {
    schema: 'priority/live-agent-model-selection-policy@v1',
    mode: policyMode,
    outputPath: path.relative(root, outputPath).replace(/\\/g, '/'),
    previousReportPath: path.relative(root, outputPath).replace(/\\/g, '/'),
    inputs: {
      costRollupPath: path.relative(root, costRollupPath).replace(/\\/g, '/'),
      throughputScorecardPath: path.relative(root, throughputPath).replace(/\\/g, '/'),
      deliveryMemoryPath: path.relative(root, deliveryMemoryPath).replace(/\\/g, '/')
    },
    evidenceWindow: {
      minLiveTurnCount: 1,
      minTerminalPullRequests: 1,
      confidenceThreshold: 'medium'
    },
    stability: {
      cooldownReports: 2,
      hysteresisScoreDelta: 0.5,
      holdCurrentOnCostOnly: true,
      performancePressureOverridesCooldown: true,
      throughputWarnEscalates: true,
      meanTerminalDurationWarningMinutes: 180,
      minMergeSuccessRatio: 0.6,
      maxHostedWaitEscapeCount: 0
    },
    providers: [
      {
        providerId: 'local-codex',
        agentRole: 'live',
        defaultModel: 'gpt-5.4',
        defaultReasoningEffort: 'xhigh',
        forcedModel,
        forcedReasoningEffort,
        candidateModels: [
          { model: 'gpt-5.4-mini', reasoningEffort: 'medium', strength: 1, costTier: 1, notes: 'cheaper' },
          { model: 'gpt-5.4', reasoningEffort: 'high', strength: 2, costTier: 2, notes: 'stronger' },
          { model: 'gpt-5.4', reasoningEffort: 'xhigh', strength: 3, costTier: 3, notes: 'strongest' }
        ]
      }
    ]
  });

  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    generatedAt: '2026-03-21T12:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turns: [
      {
        schema: 'priority/agent-cost-turn@v1',
        invoiceTurnId: 'invoice-turn-1',
        agentRole: 'live',
        providerId: 'local-codex',
        effectiveModel: currentModel,
        effectiveReasoningEffort: currentReasoningEffort,
        amountUsd,
        amountKind: 'estimated'
      }
    ]
  });

  writeJson(throughputPath, {
    schema: 'priority/throughput-scorecard@v1',
    generatedAt: '2026-03-21T12:01:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      status: throughputStatus,
      reasons: throughputReasons,
      metrics: {
        readyPrInventory: readyInventory,
        mergeQueueOccupancyRatio: queueOccupancyRatio
      }
    }
  });

  writeJson(deliveryMemoryPath, {
    schema: 'priority/delivery-memory@v1',
    generatedAt: '2026-03-21T12:02:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      totalTerminalPullRequestCount: totalTerminalPullRequests,
      mergedPullRequestCount: mergedPullRequests,
      hostedWaitEscapeCount,
      meanTerminalDurationMinutes
    }
  });

  if (previousReport) {
    writeJson(outputPath, previousReport);
  }

  return { policyPath, costRollupPath, throughputPath, deliveryMemoryPath, outputPath };
}

function buildInlineInputs() {
  const policy = {
    schema: 'priority/live-agent-model-selection-policy@v1',
    mode: 'recommend-only',
    __policyPath: 'tools/policy/live-agent-model-selection.json',
    outputPath: 'tests/results/_agent/runtime/live-agent-model-selection.json',
    previousReportPath: 'tests/results/_agent/runtime/live-agent-model-selection.json',
    inputs: {
      costRollupPath: 'tests/results/_agent/cost/agent-cost-rollup.json',
      throughputScorecardPath: 'tests/results/_agent/throughput/throughput-scorecard.json',
      deliveryMemoryPath: 'tests/results/_agent/runtime/delivery-memory.json'
    },
    evidenceWindow: {
      minLiveTurnCount: 1,
      minTerminalPullRequests: 1,
      confidenceThreshold: 'medium'
    },
    stability: {
      cooldownReports: 1,
      hysteresisScoreDelta: 0.5,
      holdCurrentOnCostOnly: true,
      performancePressureOverridesCooldown: true,
      throughputWarnEscalates: true,
      meanTerminalDurationWarningMinutes: 180,
      minMergeSuccessRatio: 0.6,
      maxHostedWaitEscapeCount: 0
    },
    providers: [
      {
        providerId: 'local-codex',
        providerKind: 'local-codex',
        agentRole: 'live',
        defaultModel: 'gpt-5.4',
        defaultReasoningEffort: 'xhigh',
        forcedModel: null,
        forcedReasoningEffort: null,
        candidateModels: [
          { model: 'gpt-5.4-mini', reasoningEffort: 'medium', strength: 1, costTier: 1, notes: null },
          { model: 'gpt-5.4', reasoningEffort: 'high', strength: 2, costTier: 2, notes: null },
          { model: 'gpt-5.4', reasoningEffort: 'xhigh', strength: 3, costTier: 3, notes: null }
        ]
      }
    ]
  };
  const costRollupInput = {
    exists: true,
    path: path.join(process.cwd(), 'tests/results/_agent/cost/agent-cost-rollup.json'),
    payload: {
      turns: [{ providerId: 'local-codex', agentRole: 'live', effectiveModel: 'gpt-5.4', effectiveReasoningEffort: 'xhigh', amountUsd: 12.2 }]
    }
  };
  const throughputInput = {
    exists: true,
    path: path.join(process.cwd(), 'tests/results/_agent/throughput/throughput-scorecard.json'),
    payload: {
      summary: {
        status: 'pass',
        reasons: [],
        metrics: {
          readyPrInventory: 2,
          mergeQueueOccupancyRatio: 1
        }
      }
    }
  };
  const deliveryMemoryInput = {
    exists: true,
    path: path.join(process.cwd(), 'tests/results/_agent/runtime/delivery-memory.json'),
    payload: {
      summary: {
        totalTerminalPullRequestCount: 3,
        mergedPullRequestCount: 3,
        hostedWaitEscapeCount: 0,
        meanTerminalDurationMinutes: 14
      }
    }
  };
  return { policy, costRollupInput, throughputInput, deliveryMemoryInput };
}

test('parseArgs exposes deterministic live-agent model selection defaults', () => {
  const options = parseArgs(['node', 'live-agent-model-selection.mjs']);
  assert.match(options.policyPath, /live-agent-model-selection\.json$/);
  assert.match(options.costRollupPath, /agent-cost-rollup\.json$/);
  assert.match(options.throughputScorecardPath, /throughput-scorecard\.json$/);
  assert.match(options.deliveryMemoryPath, /delivery-memory\.json$/);
  assert.match(options.outputPath, /live-agent-model-selection\.json$/);
  assert.equal(options.failOnBlockers, false);
});

test('runLiveAgentModelSelection stays on the current model when cost is the only improvement signal', () => {
  const root = createTempTelemetryRoot();
  const { policyPath, costRollupPath, throughputPath, deliveryMemoryPath, outputPath } = writeTelemetrySet(root);
  const result = runLiveAgentModelSelection({
    policyPath,
    costRollupPath,
    throughputScorecardPath: throughputPath,
    deliveryMemoryPath,
    outputPath,
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.providers[0].selectedModel, 'gpt-5.4');
  assert.equal(result.report.providers[0].selectedReasoningEffort, 'xhigh');
  assert.equal(result.report.providers[0].action, 'stay');
  assert.ok(result.report.providers[0].reasonCodes.includes('cost-only-not-enough') || result.report.providers[0].reasonCodes.includes('stable-current-model'));
  assert.match(result.report.policyPath, /tools\/policy\/live-agent-model-selection\.json$/);
});

test('runLiveAgentModelSelection escalates to the stronger model when throughput and outcome pressure are present', () => {
  const root = createTempTelemetryRoot();
  const { policyPath, costRollupPath, throughputPath, deliveryMemoryPath, outputPath } = writeTelemetrySet(root, {
    currentModel: 'gpt-5.4-mini',
    currentReasoningEffort: 'medium',
    amountUsd: 3.5,
    throughputStatus: 'warn',
    throughputReasons: ['actionable-work-below-worker-slot-target'],
    hostedWaitEscapeCount: 2,
    meanTerminalDurationMinutes: 240,
    totalTerminalPullRequests: 6,
    mergedPullRequests: 2
  });
  const result = runLiveAgentModelSelection({
    policyPath,
    costRollupPath,
    throughputScorecardPath: throughputPath,
    deliveryMemoryPath,
    outputPath
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.providers[0].selectedModel, 'gpt-5.4');
  assert.equal(result.report.providers[0].selectedReasoningEffort, 'xhigh');
  assert.equal(result.report.providers[0].action, 'switch');
  assert.ok(result.report.providers[0].reasonCodes.includes('throughput-pressure'));
  assert.ok(result.report.providers[0].reasonCodes.includes('outcome-quality-pressure'));
  assert.ok(result.report.providers[0].reasonCodes.includes('terminal-duration-pressure'));
  assert.ok(result.report.providers[0].reasonCodes.includes('hosted-wait-pressure'));
});

test('runLiveAgentModelSelection holds the current model when hysteresis is not cleared', () => {
  const root = createTempTelemetryRoot();
  const { policyPath, costRollupPath, throughputPath, deliveryMemoryPath, outputPath } = writeTelemetrySet(root, {
    currentModel: 'gpt-5.4',
    currentReasoningEffort: 'high',
    amountUsd: 98,
    throughputStatus: 'pass',
    meanTerminalDurationMinutes: 181,
    totalTerminalPullRequests: 2,
    mergedPullRequests: 2
  });
  const result = runLiveAgentModelSelection({
    policyPath,
    costRollupPath,
    throughputScorecardPath: throughputPath,
    deliveryMemoryPath,
    outputPath
  });

  assert.equal(result.report.providers[0].selectedModel, 'gpt-5.4');
  assert.equal(result.report.providers[0].selectedReasoningEffort, 'high');
  assert.equal(result.report.providers[0].action, 'hold');
  assert.ok(result.report.providers[0].reasonCodes.includes('hysteresis-hold'));
});

test('runLiveAgentModelSelection honors explicit forced-model overrides', () => {
  const root = createTempTelemetryRoot();
  const { policyPath, costRollupPath, throughputPath, deliveryMemoryPath, outputPath } = writeTelemetrySet(root, {
    currentModel: 'gpt-5.4-mini',
    currentReasoningEffort: 'medium',
    forcedModel: 'gpt-5.4',
    forcedReasoningEffort: 'xhigh'
  });
  const result = runLiveAgentModelSelection({
    policyPath,
    costRollupPath,
    throughputScorecardPath: throughputPath,
    deliveryMemoryPath,
    outputPath
  });

  assert.equal(result.report.providers[0].selectedModel, 'gpt-5.4');
  assert.equal(result.report.providers[0].selectedReasoningEffort, 'xhigh');
  assert.equal(result.report.providers[0].action, 'override');
  assert.equal(result.report.providers[0].recommendationSource, 'policy-override');
  assert.deepEqual(result.report.providers[0].reasonCodes, ['policy-override']);
});

test('evaluateLiveAgentModelSelection emits stable results for unchanged inputs', () => {
  const { policy, costRollupInput, throughputInput, deliveryMemoryInput } = buildInlineInputs();
  const left = evaluateLiveAgentModelSelection({
    policy,
    costRollupInput,
    throughputInput,
    deliveryMemoryInput,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    now: new Date('2026-03-21T13:00:00.000Z')
  });
  const right = evaluateLiveAgentModelSelection({
    policy,
    costRollupInput,
    throughputInput,
    deliveryMemoryInput,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    now: new Date('2026-03-21T13:00:00.000Z')
  });

  assert.deepEqual(left, right);
});

test('buildLiveAgentModelSelectionProjection returns the selected provider projection for runtime consumers', () => {
  const projection = buildLiveAgentModelSelectionProjection({
    policy: {
      mode: 'recommend-only',
      __policyPath: 'tools/policy/live-agent-model-selection.json',
      outputPath: 'tests/results/_agent/runtime/live-agent-model-selection.json',
      previousReportPath: 'tests/results/_agent/runtime/live-agent-model-selection.json'
    },
    report: {
      generatedAt: '2026-03-21T13:05:00.000Z',
      summary: {
        status: 'pass',
        blockerCount: 0
      },
      providers: [
        {
          providerId: 'local-codex',
          providerKind: 'local-codex',
          agentRole: 'live',
          currentModel: 'gpt-5.4',
          currentReasoningEffort: 'xhigh',
          selectedModel: 'gpt-5.4',
          selectedReasoningEffort: 'xhigh',
          action: 'stay',
          confidence: 'medium',
          reasonCodes: ['stable-current-model']
        }
      ]
    },
    selectedProviderId: 'local-codex'
  });

  assert.equal(projection.policyPath, 'tools/policy/live-agent-model-selection.json');
  assert.equal(projection.reportPath, 'tests/results/_agent/runtime/live-agent-model-selection.json');
  assert.equal(projection.recommendationStatus, 'pass');
  assert.equal(projection.currentProvider.providerId, 'local-codex');
  assert.equal(projection.currentProvider.selectedModel, 'gpt-5.4');
  assert.equal(projection.currentProvider.selectedReasoningEffort, 'xhigh');
});

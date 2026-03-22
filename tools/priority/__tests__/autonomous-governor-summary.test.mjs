import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_OUTPUT_PATH,
  parseArgs,
  runAutonomousGovernorSummary
} from '../autonomous-governor-summary.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createMonitoringMode() {
  return {
    schema: 'agent-handoff/monitoring-mode-v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    compare: {
      queueState: { status: 'queue-empty', detail: 'queue-empty', ready: true },
      continuity: { status: 'maintained', detail: 'safe-idle', ready: true }
    },
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0
    }
  };
}

function createContinuitySummary() {
  return {
    schema: 'priority/continuity-telemetry-report@v1',
    status: 'maintained',
    continuity: {
      turnBoundary: {
        status: 'safe-idle',
        supervisionState: 'safe-idle',
        operatorPromptRequiredToResume: false
      }
    }
  };
}

function createQueueEmpty() {
  return {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 11
  };
}

function createWakeLifecycle() {
  return {
    schema: 'priority/wake-lifecycle-report@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    wake: {
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    summary: {
      terminalState: 'compare-work',
      currentStage: 'monitoring-work-injection',
      wakeClassification: 'branch-target-drift',
      decision: 'compare-governance-work',
      monitoringStatus: 'would-create-issue',
      authoritativeTier: 'authoritative',
      blockedLowerTierEvidence: true,
      replayMatched: false,
      replayAuthorityCompatible: false,
      issueNumber: null,
      issueUrl: null
    }
  };
}

function createWakeInvestmentAccounting() {
  return {
    schema: 'priority/wake-investment-accounting-report@v1',
    billingWindow: {
      invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
      fundingPurpose: 'operational',
      activationState: 'active'
    },
    summary: {
      accountingBucket: 'compare-governance-work',
      status: 'warn',
      paybackStatus: 'neutral',
      recommendation: 'continue-estimated-telemetry',
      metrics: {
        benchmarkIssueUsd: 0.0201,
        observedWakeIssueUsd: 0.0201,
        netPaybackUsd: 0
      }
    }
  };
}

test('parseArgs keeps governor summary defaults and accepts overrides', () => {
  const parsed = parseArgs([
    'node',
    'autonomous-governor-summary.mjs',
    '--repo-root',
    'C:/repo',
    '--output',
    'custom/summary.json'
  ]);

  assert.equal(parsed.repoRoot, 'C:/repo');
  assert.equal(parsed.outputPath, 'custom/summary.json');
  assert.equal(
    DEFAULT_OUTPUT_PATH,
    path.join('tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json')
  );
});

test('runAutonomousGovernorSummary reports compare governance work when the latest wake resolves to compare-work', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-lifecycle.json'), createWakeLifecycle());
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'capital', 'wake-investment-accounting.json'),
    createWakeInvestmentAccounting()
  );

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'compare-governance-work');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextAction, 'continue-compare-governance-work');
  assert.equal(report.summary.signalQuality, 'validated-governance-work');
  assert.equal(report.funding.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
});

test('runAutonomousGovernorSummary reports monitoring-active when no wake lifecycle exists', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-monitoring-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'monitoring-active');
  assert.equal(report.summary.nextAction, 'future-agent-may-pivot');
  assert.equal(report.summary.signalQuality, 'idle-monitoring');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.wake.terminalState, null);
});

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { DEFAULT_OUTPUT_PATH, parseArgs, runWakeLifecycle } from '../wake-lifecycle.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createWakeAdjudication({
  classification = 'branch-target-drift',
  reason = 'Live replay contradicted the stale reported wake.'
} = {}) {
  return {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: '2026-03-22T22:00:00.000Z',
    reported: {
      path: 'reported.json',
      generatedAt: '2026-03-22T21:30:00.000Z',
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      targetBranch: 'downstream/develop',
      defaultBranch: 'downstream/develop'
    },
    revalidated: {
      path: 'revalidated.json',
      generatedAt: '2026-03-22T21:45:00.000Z',
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      targetBranch: 'develop',
      defaultBranch: 'develop'
    },
    authority: {
      authoritative: {
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        targetBranch: 'develop',
        defaultBranch: 'develop',
        generatedAt: '2026-03-22T21:45:00.000Z',
        source: 'live-replay'
      },
      routing: {
        selectedTier: 'authoritative',
        blockedLowerTier: true,
        contradictionFields: ['targetBranch', 'defaultBranch'],
        reason: 'Higher-authority live replay contradicted the reported wake.'
      }
    },
    summary: {
      classification,
      nextAction: 'reconcile-downstream-branch-target-provenance',
      reason,
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    }
  };
}

function createWakeWorkSynthesis({
  decision = 'compare-governance-work',
  workKind = 'drift-correction',
  recommendedOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  reason = 'Wake belongs to compare governance.'
} = {}) {
  return {
    schema: 'priority/wake-work-synthesis-report@v1',
    generatedAt: '2026-03-22T22:01:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      decision,
      status: 'actionable',
      workKind,
      recommendedOwnerRepository,
      routingAuthorityTier: 'authoritative',
      blockedLowerTierEvidence: true,
      reason
    }
  };
}

function createWakeInvestmentAccounting() {
  return {
    schema: 'priority/wake-investment-accounting-report@v1',
    generatedAt: '2026-03-22T22:02:00.000Z',
    summary: {
      accountingBucket: 'compare-governance-work',
      status: 'warn',
      paybackStatus: 'neutral',
      currentObservedCostUsd: 0.0201
    }
  };
}

function createMonitoringWorkInjection({
  status = 'would-create-issue',
  issueNumber = 1843,
  issueUrl = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1843',
  replayMatchedBy = null,
  replayMatchedEntryCount = 0,
  replayAuthorityCompatible = true,
  replayAuthorityMismatchReason = null
} = {}) {
  return {
    schema: 'priority/monitoring-work-injection-report@v1',
    generatedAt: '2026-03-22T22:03:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    replay: {
      matchedBy: replayMatchedBy,
      matchedEntryCount: replayMatchedEntryCount,
      authorityCompatible: replayAuthorityCompatible,
      authorityMismatchReason: replayAuthorityMismatchReason
    },
    summary: {
      status,
      reason: 'Monitoring work injection evaluated the wake.',
      issueNumber,
      issueUrl,
      triggerId: 'compare-governance-wake'
    }
  };
}

test('parseArgs keeps lifecycle defaults and accepts overrides', () => {
  const parsed = parseArgs([
    'node',
    'wake-lifecycle.mjs',
    '--repo-root',
    'C:/repo',
    '--output',
    'custom/output.json'
  ]);

  assert.equal(parsed.repoRoot, 'C:/repo');
  assert.equal(parsed.outputPath, 'custom/output.json');
  assert.equal(DEFAULT_OUTPUT_PATH, path.join('tests', 'results', '_agent', 'issue', 'wake-lifecycle.json'));
});

test('runWakeLifecycle writes a compare-work lifecycle report', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-lifecycle-'));
  const adjudicationPath = path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-adjudication.json');
  const synthesisPath = path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-work-synthesis.json');
  const accountingPath = path.join(tmpDir, 'tests', 'results', '_agent', 'capital', 'wake-investment-accounting.json');
  const injectionPath = path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'monitoring-work-injection.json');
  const outputPath = path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-lifecycle.json');

  writeJson(adjudicationPath, createWakeAdjudication());
  writeJson(synthesisPath, createWakeWorkSynthesis());
  writeJson(accountingPath, createWakeInvestmentAccounting());
  writeJson(injectionPath, createMonitoringWorkInjection());

  const { report, outputPath: writtenPath } = await runWakeLifecycle({
    repoRoot: tmpDir,
    wakeAdjudicationPath: path.relative(tmpDir, adjudicationPath),
    wakeWorkSynthesisPath: path.relative(tmpDir, synthesisPath),
    wakeInvestmentAccountingPath: path.relative(tmpDir, accountingPath),
    monitoringWorkInjectionPath: path.relative(tmpDir, injectionPath),
    outputPath: path.relative(tmpDir, outputPath)
  });

  assert.equal(writtenPath, outputPath);
  assert.equal(report.schema, 'priority/wake-lifecycle-report@v1');
  assert.equal(report.summary.currentStage, 'monitoring-work-injection');
  assert.equal(report.summary.terminalState, 'compare-work');
  assert.equal(report.summary.wakeClassification, 'branch-target-drift');
  assert.equal(report.summary.decision, 'compare-governance-work');
  assert.equal(report.summary.authoritativeTier, 'authoritative');
  assert.equal(report.summary.blockedLowerTierEvidence, true);
  assert.equal(report.summary.replayMatched, false);
  assert.equal(report.summary.replayAuthorityCompatible, true);
  assert.equal(report.stages.monitoringWorkInjection.status, 'would-create-issue');
  assert.equal(report.transitions.length, 6);

  const writtenReport = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(writtenReport.summary.terminalState, 'compare-work');
});

test('runWakeLifecycle maps external template routing to template-work', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-lifecycle-template-'));
  const adjudicationPath = path.join(tmpDir, 'wake-adjudication.json');
  const synthesisPath = path.join(tmpDir, 'wake-work-synthesis.json');
  const accountingPath = path.join(tmpDir, 'wake-investment-accounting.json');
  const injectionPath = path.join(tmpDir, 'monitoring-work-injection.json');

  writeJson(adjudicationPath, createWakeAdjudication({ classification: 'live-defect' }));
  writeJson(
    synthesisPath,
    createWakeWorkSynthesis({
      decision: 'template-work',
      workKind: 'defect',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      reason: 'Wake belongs to canonical template work.'
    })
  );
  writeJson(accountingPath, createWakeInvestmentAccounting());
  writeJson(
    injectionPath,
    createMonitoringWorkInjection({
      status: 'external-route',
      issueNumber: null,
      issueUrl: null,
      replayAuthorityCompatible: false,
      replayAuthorityMismatchReason: 'authority-context-changed'
    })
  );

  const { report } = await runWakeLifecycle({
    repoRoot: tmpDir,
    wakeAdjudicationPath: 'wake-adjudication.json',
    wakeWorkSynthesisPath: 'wake-work-synthesis.json',
    wakeInvestmentAccountingPath: 'wake-investment-accounting.json',
    monitoringWorkInjectionPath: 'monitoring-work-injection.json',
    outputPath: 'wake-lifecycle.json'
  });

  assert.equal(report.summary.terminalState, 'template-work');
  assert.equal(report.summary.decision, 'template-work');
  assert.equal(report.summary.monitoringStatus, 'external-route');
  assert.equal(report.summary.replayAuthorityCompatible, false);
  assert.equal(report.stages.monitoringWorkInjection.replayAuthorityMismatchReason, 'authority-context-changed');
});

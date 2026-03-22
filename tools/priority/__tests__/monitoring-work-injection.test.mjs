import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { runMonitoringWorkInjection } from '../monitoring-work-injection.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy() {
  return {
    schema: 'priority/monitoring-work-injection-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    requireQueueEmpty: true,
    rules: [
      {
        id: 'compare-governance-wake',
        requireMonitoringMode: 'active',
        when: {
          wakeDecision: 'compare-governance-work',
          wakeStatus: 'actionable',
          recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        },
        issue: {
          title: '[governance]: reconcile monitoring wake drift in compare control plane',
          dedupeMarker: 'monitoring-work-injector:compare-governance-wake',
          dedupeDimension: 'next-action',
          labels: ['standing-priority', 'governance'],
          bodyLines: ['## Summary', 'Injected from wake evidence.']
        }
      },
      {
        id: 'runner-conflict',
        requireMonitoringMode: 'active',
        when: {
          hostSignalStatus: 'runner-conflict'
        },
        issue: {
          title: '[monitoring]: reconcile runner-conflict blocking autonomous loop',
          dedupeMarker: 'monitoring-work-injector:runner-conflict',
          labels: ['standing-priority', 'governance'],
          bodyLines: ['## Summary', 'Injected from automated monitoring.']
        }
      }
    ]
  };
}

function createInputs(tmpDir, { includeWakeEvidence = true } = {}) {
  const policyPath = path.join(tmpDir, 'policy.json');
  const queuePath = path.join(tmpDir, 'queue.json');
  const monitoringPath = path.join(tmpDir, 'monitoring.json');
  const hostSignalPath = path.join(tmpDir, 'host-signal.json');
  const wakeAdjudicationPath = path.join(tmpDir, 'wake-adjudication.json');
  const wakeWorkSynthesisPath = path.join(tmpDir, 'wake-work-synthesis.json');
  const wakeInvestmentAccountingPath = path.join(tmpDir, 'wake-investment-accounting.json');
  writeJson(policyPath, createPolicy());
  writeJson(queuePath, {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 0
  });
  writeJson(monitoringPath, {
    schema: 'agent-handoff/monitoring-mode-v1',
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0
    }
  });
  writeJson(hostSignalPath, {
    schema: 'priority/delivery-agent-host-signal@v1',
    status: 'runner-conflict',
    provider: 'native-wsl',
    daemonFingerprint: 'abc123'
  });
  if (includeWakeEvidence) {
    writeJson(wakeAdjudicationPath, {
      schema: 'priority/wake-adjudication-report@v1',
      summary: {
        classification: 'branch-target-drift',
        status: 'suppressed',
        nextAction: 'reconcile-downstream-branch-target-provenance',
        recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        suppressIssueInjection: true,
        suppressDownstreamIssueInjection: true,
        suppressTemplateIssueInjection: true,
        reason: 'Reported branch drift cleared during live replay.'
      }
    });
    writeJson(wakeWorkSynthesisPath, {
      schema: 'priority/wake-work-synthesis-report@v1',
      wake: {
        classification: 'branch-target-drift',
        nextAction: 'reconcile-downstream-branch-target-provenance',
        suppressIssueInjection: true,
        suppressDownstreamIssueInjection: true,
        suppressTemplateIssueInjection: true
      },
      summary: {
        decision: 'compare-governance-work',
        status: 'actionable',
        recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        reason: 'Wake belongs to compare governance.'
      }
    });
    writeJson(wakeInvestmentAccountingPath, {
      schema: 'priority/wake-investment-accounting-report@v1',
      summary: {
        accountingBucket: 'compare-governance-work',
        status: 'warn',
        paybackStatus: 'neutral'
      }
    });
  }
  return {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  };
}

test('runMonitoringWorkInjection reports no-trigger when queue is not empty', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-noop-'));
  const {
    policyPath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir, { includeWakeEvidence: false });
  const queuePath = path.join(tmpDir, 'queue.json');
  writeJson(queuePath, {
    schema: 'standing-priority/no-standing@v1',
    reason: 'labels-missing',
    openIssueCount: 1
  });

  const { report } = await runMonitoringWorkInjection({
    repoRoot: tmpDir,
    policyPath,
    queueEmptyReportPath: queuePath,
    monitoringModePath: monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath,
    repository: 'owner/repo'
  });

  assert.equal(report.summary.status, 'no-trigger');
  assert.equal(report.summary.injected, false);
});

test('runMonitoringWorkInjection creates an issue when runner-conflict fires in queue-empty monitoring mode', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-create-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir, { includeWakeEvidence: false });
  const ghCalls = [];

  const { report } = await runMonitoringWorkInjection(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      monitoringModePath: monitoringPath,
      hostSignalPath,
      wakeAdjudicationPath,
      wakeWorkSynthesisPath,
      wakeInvestmentAccountingPath,
      repository: 'owner/repo'
    },
    {
      runGhJsonFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'list') {
          return [];
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'create') {
          return {
            stdout: 'https://github.com/owner/repo/issues/123\n'
          };
        }
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.summary.status, 'created-issue');
  assert.equal(report.summary.issueNumber, 123);
  assert.equal(report.summary.triggerId, 'runner-conflict');
  assert.equal(report.event.category, 'monitoring-work-injection');
  assert.equal(report.decisionLedger.appended, true);
  assert.ok(Number.isInteger(report.decisionLedger.sequence));
  assert.ok(ghCalls.some((entry) => entry.startsWith('issue create')));
});

test('runMonitoringWorkInjection reuses an existing injected issue and restores missing labels', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-existing-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir, { includeWakeEvidence: false });
  const ghCalls = [];

  const { report } = await runMonitoringWorkInjection(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      monitoringModePath: monitoringPath,
      hostSignalPath,
      wakeAdjudicationPath,
      wakeWorkSynthesisPath,
      wakeInvestmentAccountingPath,
      repository: 'owner/repo'
    },
    {
      runGhJsonFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'list') {
          return [
            {
              number: 77,
              title: '[monitoring]: reconcile runner-conflict blocking autonomous loop',
              url: 'https://github.com/owner/repo/issues/77',
              body: '<!-- monitoring-work-injector:runner-conflict -->',
              labels: [{ name: 'governance' }]
            }
          ];
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'edit') {
          return { stdout: '' };
        }
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.summary.status, 'existing-issue');
  assert.equal(report.summary.issueNumber, 77);
  assert.ok(ghCalls.some((entry) => entry.includes('--add-label standing-priority')));
});

test('runMonitoringWorkInjection creates a compare governance issue from actionable wake evidence', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-compare-governance-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir);
  const ghCalls = [];

  const { report } = await runMonitoringWorkInjection(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      monitoringModePath: monitoringPath,
      hostSignalPath,
      wakeAdjudicationPath,
      wakeWorkSynthesisPath,
      wakeInvestmentAccountingPath,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      runGhJsonFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'list') {
          return [];
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'create') {
          return {
            stdout: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1820\n'
          };
        }
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.summary.status, 'created-issue');
  assert.equal(report.summary.triggerId, 'compare-governance-wake');
  assert.equal(report.selectedRule.resolvedDedupeMarker, 'monitoring-work-injector:compare-governance-wake:reconcile-downstream-branch-target-provenance');
  assert.equal(report.evidence.wake.decision, 'compare-governance-work');
  assert.ok(ghCalls.some((entry) => entry.startsWith('issue create')));
});

test('runMonitoringWorkInjection suppresses stale wakes instead of injecting new work', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-suppressed-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir);
  writeJson(wakeWorkSynthesisPath, {
    schema: 'priority/wake-work-synthesis-report@v1',
    wake: {
      classification: 'stale-artifact',
      nextAction: 'none',
      suppressIssueInjection: true,
      suppressDownstreamIssueInjection: true,
      suppressTemplateIssueInjection: true
    },
    summary: {
      decision: 'suppress',
      status: 'suppressed',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      reason: 'Reported wake is stale after replay.'
    }
  });
  writeJson(hostSignalPath, {
    schema: 'priority/delivery-agent-host-signal@v1',
    status: 'ready',
    provider: 'native-wsl',
    daemonFingerprint: 'abc123'
  });

  const { report } = await runMonitoringWorkInjection({
    repoRoot: tmpDir,
    policyPath,
    queueEmptyReportPath: queuePath,
    monitoringModePath: monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  }, {
    runGhJsonFn: () => {
      throw new Error('suppressed wakes must not query GitHub issue injection state');
    },
    runGhFn: () => {
      throw new Error('suppressed wakes must not edit or create issues');
    }
  });

  assert.equal(report.summary.status, 'suppressed-wake');
  assert.equal(report.summary.injected, false);
  assert.equal(report.summary.issueNumber, null);
  assert.equal(report.decisionLedger.appended, true);
  assert.ok(Number.isInteger(report.decisionLedger.sequence));
});

test('runMonitoringWorkInjection writes replayable ledger context for external-route wakes', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-ledger-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir);
  writeJson(wakeWorkSynthesisPath, {
    schema: 'priority/wake-work-synthesis-report@v1',
    wake: {
      classification: 'live-defect',
      nextAction: 'repair-template-smoke'
    },
    summary: {
      decision: 'template-work',
      status: 'actionable',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      reason: 'Supported template proof regressed.'
    }
  });
  writeJson(hostSignalPath, {
    schema: 'priority/delivery-agent-host-signal@v1',
    status: 'ready',
    provider: 'native-wsl',
    daemonFingerprint: 'abc123'
  });

  const { report, ledgerPath } = await runMonitoringWorkInjection({
    repoRoot: tmpDir,
    policyPath,
    queueEmptyReportPath: queuePath,
    monitoringModePath: monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  }, {
    runGhJsonFn: () => {
      throw new Error('external routes must not query compare issue injection state');
    },
    runGhFn: () => {
      throw new Error('external routes must not edit or create compare issues');
    }
  });

  const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
  assert.equal(report.summary.status, 'external-route');
  assert.equal(report.decisionLedger.appended, true);
  assert.equal(ledger.entryCount, 1);
  assert.equal(ledger.entries[0].source, 'monitoring-work-injection');
  assert.equal(ledger.entries[0].fingerprint, report.event.fingerprint);
  assert.equal(ledger.entries[0].decision.summary.status, 'external-route');
});

test('runMonitoringWorkInjection keeps external template work out of compare issue injection', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-external-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir);
  writeJson(wakeWorkSynthesisPath, {
    schema: 'priority/wake-work-synthesis-report@v1',
    wake: {
      classification: 'live-defect',
      nextAction: 'repair-template-smoke'
    },
    summary: {
      decision: 'template-work',
      status: 'actionable',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      reason: 'Supported template proof regressed.'
    }
  });
  writeJson(hostSignalPath, {
    schema: 'priority/delivery-agent-host-signal@v1',
    status: 'ready',
    provider: 'native-wsl',
    daemonFingerprint: 'abc123'
  });

  const { report } = await runMonitoringWorkInjection({
    repoRoot: tmpDir,
    policyPath,
    queueEmptyReportPath: queuePath,
    monitoringModePath: monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  }, {
    runGhJsonFn: () => {
      throw new Error('external routes must not query compare issue injection state');
    },
    runGhFn: () => {
      throw new Error('external routes must not edit or create compare issues');
    }
  });

  assert.equal(report.summary.status, 'external-route');
  assert.equal(report.summary.injected, false);
  assert.equal(report.summary.issueNumber, null);
});

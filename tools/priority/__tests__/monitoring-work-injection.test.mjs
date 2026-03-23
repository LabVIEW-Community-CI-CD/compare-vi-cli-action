import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { runMonitoringWorkInjection } from '../monitoring-work-injection.mjs';

const STALE_TEST_NOW = '2026-03-22T16:30:00.000Z';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy() {
  return {
    schema: 'priority/monitoring-work-injection-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    requireQueueEmpty: true,
    freshness: {
      hostSignalMaxAgeMinutes: 120,
      wakeAdjudicationMaxAgeMinutes: 120,
      wakeWorkSynthesisMaxAgeMinutes: 120,
      wakeInvestmentAccountingMaxAgeMinutes: 120
    },
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

function createGovernorPortfolioSummary({
  currentOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  nextOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  governorMode = 'compare-governance-work',
  nextAction = 'continue-compare-governance-work',
  ownerDecisionSource = 'compare-governor-summary',
  status = 'active'
} = {}) {
  return {
    schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
    generatedAt: '2099-01-01T00:00:30.000Z',
    inputs: {
      compareGovernorSummaryPath: 'tests/results/_agent/handoff/autonomous-governor-summary.json',
      monitoringModePath: 'tests/results/_agent/handoff/monitoring-mode.json',
      repoGraphTruthPath: 'tests/results/_agent/handoff/downstream-repo-graph-truth.json'
    },
    compare: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      queueState: 'queue-empty',
      continuityStatus: 'maintained',
      monitoringStatus: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      governorMode,
      nextAction
    },
    portfolio: {
      repositoryCount: 4,
      repositories: [],
      unsupportedPaths: []
    },
    summary: {
      status,
      governorMode,
      currentOwnerRepository,
      nextOwnerRepository,
      nextAction,
      ownerDecisionSource,
      templateMonitoringStatus: 'pass',
      supportedProofStatus: 'pass',
      repoGraphStatus: 'pass',
      portfolioWakeConditionCount: 0,
      triggeredWakeConditions: []
    }
  };
}

function createInputs(tmpDir, { includeWakeEvidence = true, governorPortfolioSummaryOverride = null } = {}) {
  const policyPath = path.join(tmpDir, 'policy.json');
  const queuePath = path.join(tmpDir, 'queue.json');
  const monitoringPath = path.join(tmpDir, 'monitoring.json');
  const governorPortfolioSummaryPath = path.join(
    tmpDir,
    'tests',
    'results',
    '_agent',
    'handoff',
    'autonomous-governor-portfolio-summary.json'
  );
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
  writeJson(
    governorPortfolioSummaryPath,
    governorPortfolioSummaryOverride || createGovernorPortfolioSummary()
  );
  writeJson(hostSignalPath, {
    schema: 'priority/delivery-agent-host-signal@v1',
    generatedAt: '2099-01-01T00:00:00.000Z',
    status: 'runner-conflict',
    provider: 'native-wsl',
    daemonFingerprint: 'abc123'
  });
  if (includeWakeEvidence) {
    writeJson(wakeAdjudicationPath, {
      schema: 'priority/wake-adjudication-report@v1',
      generatedAt: '2099-01-01T00:01:00.000Z',
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
      generatedAt: '2099-01-01T00:02:00.000Z',
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
        reason: 'Wake belongs to compare governance.',
        routingAuthorityTier: 'authoritative',
        blockedLowerTierEvidence: true
      },
      authority: {
        selectedTier: 'authoritative',
        blockedLowerTier: true,
        contradictionFields: ['targetBranch', 'defaultBranch'],
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        branch: 'develop',
        source: 'live-replay'
      }
    });
    writeJson(wakeInvestmentAccountingPath, {
      schema: 'priority/wake-investment-accounting-report@v1',
      generatedAt: '2099-01-01T00:03:00.000Z',
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
    governorPortfolioSummaryPath,
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
  assert.equal(report.portfolioRouting.status, 'owner-match');
  assert.ok(ghCalls.some((entry) => entry.startsWith('issue create')));
});

test('runMonitoringWorkInjection keeps template-owned actionable wakes out of compare issue injection when the portfolio routes ownership away', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-template-owned-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir, {
    governorPortfolioSummaryOverride: createGovernorPortfolioSummary({
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      governorMode: 'template-work',
      nextAction: 'reopen-template-monitoring-work',
      ownerDecisionSource: 'template-monitoring'
    })
  });
  writeJson(wakeWorkSynthesisPath, {
    schema: 'priority/wake-work-synthesis-report@v1',
    generatedAt: '2099-01-01T00:02:00.000Z',
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
    generatedAt: '2099-01-01T00:00:00.000Z',
    status: 'ready',
    provider: 'native-wsl',
    daemonFingerprint: 'abc123'
  });

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
      runGhJsonFn: () => {
        throw new Error('template-owned routes must not query compare issues');
      },
      runGhFn: () => {
        throw new Error('template-owned routes must not mutate compare issues');
      }
    }
  );

  assert.equal(report.summary.status, 'external-route');
  assert.equal(report.portfolioRouting.status, 'external-owner');
  assert.equal(report.evidence.governorPortfolio.currentOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
});

test('runMonitoringWorkInjection fails closed when portfolio ownership contradicts the lower-tier actionable wake', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-portfolio-contradiction-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir, {
    governorPortfolioSummaryOverride: createGovernorPortfolioSummary({
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      governorMode: 'template-work',
      nextAction: 'reopen-template-monitoring-work',
      ownerDecisionSource: 'template-monitoring'
    })
  });

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
      runGhJsonFn: () => {
        throw new Error('contradictory ownership must fail closed before GitHub queries');
      },
      runGhFn: () => {
        throw new Error('contradictory ownership must fail closed before issue mutation');
      }
    }
  );

  assert.equal(report.summary.status, 'policy-blocked');
  assert.equal(report.summary.triggerId, 'compare-governance-wake');
  assert.equal(report.portfolioRouting.status, 'contradiction');
  assert.deepEqual(report.portfolioRouting.contradictionFields, ['recommendedOwnerRepository']);
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

test('runMonitoringWorkInjection consults replay memory before repeating a suppressed wake', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-suppressed-replay-'));
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

  await runMonitoringWorkInjection({
    repoRoot: tmpDir,
    policyPath,
    queueEmptyReportPath: queuePath,
    monitoringModePath: monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
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
      throw new Error('suppressed wakes must stay local to replay memory');
    },
    runGhFn: () => {
      throw new Error('suppressed wakes must not inject work');
    }
  });

  assert.equal(report.summary.status, 'suppressed-wake');
  assert.equal(report.replay.matchedEntryCount, 1);
  assert.equal(report.replay.matchedBy, 'fingerprint');
  assert.equal(report.replay.suppressionApplied, true);
  assert.match(report.summary.reason, /Replay memory matched sequence \d+/);
});

test('runMonitoringWorkInjection blocks replay reuse when authority context strengthened', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-authority-replay-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir);
  const ledgerPath = path.join(tmpDir, 'tests', 'results', '_agent', 'ops', 'ops-decision-ledger.json');
  writeJson(ledgerPath, {
    schema: 'ops-decision-ledger@v1',
    generatedAt: '2099-01-01T00:10:00.000Z',
    entryCount: 1,
    entries: [
      {
        sequence: 1,
        appendedAt: '2099-01-01T00:10:00.000Z',
        source: 'monitoring-work-injection',
        decisionDigest: 'prior-decision',
        fingerprint: 'prior-fingerprint',
        decision: {
          event: {
            dedupeMarker: 'monitoring-work-injector:compare-governance-wake:reconcile-downstream-branch-target-provenance'
          },
          summary: {
            status: 'existing-issue',
            issueNumber: 88,
            issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/88'
          },
          evidence: {
            wake: {
              classification: 'branch-target-drift',
              decision: 'compare-governance-work',
              status: 'actionable',
              nextAction: 'reconcile-downstream-branch-target-provenance',
              recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              suppressIssueInjection: true,
              suppressTemplateIssueInjection: true,
              suppressDownstreamIssueInjection: true,
              accountingBucket: 'compare-governance-work',
              accountingStatus: 'warn',
              paybackStatus: 'neutral',
              authorityTier: 'revalidated',
              authorityBlockedLowerTier: false,
              authorityContradictionFields: [],
              authorityRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
              authorityBranch: 'develop',
              authoritySource: 'live-replay'
            }
          }
        }
      }
    ]
  });

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
      ledgerPath,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      runGhJsonFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'list') {
          return [
            {
              number: 88,
              title: '[governance]: reconcile monitoring wake drift in compare control plane',
              url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/88',
              body: '<!-- monitoring-work-injector:compare-governance-wake:reconcile-downstream-branch-target-provenance -->',
              labels: [{ name: 'standing-priority' }, { name: 'governance' }],
              state: 'OPEN'
            }
          ];
        }
        if (args[0] === 'issue' && args[1] === 'view') {
          throw new Error('authority-mismatched replay must not use direct issue-view reuse');
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        ghCalls.push(args.join(' '));
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.summary.status, 'existing-issue');
  assert.equal(report.summary.issueNumber, 88);
  assert.equal(report.replay.authorityCompatible, false);
  assert.equal(report.replay.authorityMismatchReason, 'authority-context-changed');
  assert.equal(report.replay.reusedExistingIssue, false);
  assert.ok(!ghCalls.some((entry) => entry.startsWith('issue view')));
  assert.ok(!report.summary.reason.includes('replay memory reused'));
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

test('runMonitoringWorkInjection reuses a prior created issue from replay memory before listing open issues', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-replay-existing-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir, { includeWakeEvidence: false });
  const firstRunGhCalls = [];

  await runMonitoringWorkInjection(
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
        firstRunGhCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'list') {
          return [];
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        firstRunGhCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'create') {
          return {
            stdout: 'https://github.com/owner/repo/issues/123\n'
          };
        }
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  const secondRunGhCalls = [];
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
        secondRunGhCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'view') {
          return {
            number: 123,
            title: '[monitoring]: reconcile runner-conflict blocking autonomous loop',
            url: 'https://github.com/owner/repo/issues/123',
            state: 'OPEN',
            body: '<!-- monitoring-work-injector:runner-conflict -->',
            labels: [{ name: 'governance' }]
          };
        }
        if (args[0] === 'issue' && args[1] === 'list') {
          throw new Error('replay-backed issue reuse should not fall back to issue list');
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        secondRunGhCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'edit') {
          return { stdout: '' };
        }
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  assert.ok(firstRunGhCalls.some((entry) => entry.startsWith('issue create')));
  assert.equal(report.summary.status, 'existing-issue');
  assert.equal(report.summary.issueNumber, 123);
  assert.equal(report.replay.matchedBy, 'dedupe-marker');
  assert.equal(report.replay.latestMatchingStatus, 'created-issue');
  assert.equal(report.replay.reusedExistingIssue, true);
  assert.ok(secondRunGhCalls.some((entry) => entry.startsWith('issue view 123')));
  assert.ok(secondRunGhCalls.some((entry) => entry.includes('--add-label standing-priority')));
});

test('runMonitoringWorkInjection fails closed when decision memory is unreadable for an actionable wake', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-ledger-invalid-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir, { includeWakeEvidence: false });
  const ledgerPath = path.join(tmpDir, 'tests', 'results', '_agent', 'ops', 'ops-decision-ledger.json');
  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true });
  fs.writeFileSync(ledgerPath, '{not-valid-json}', 'utf8');

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
      ledgerPath,
      repository: 'owner/repo'
    },
    {
      runGhJsonFn: () => {
        throw new Error('unreadable decision memory must fail closed before GitHub queries');
      },
      runGhFn: () => {
        throw new Error('unreadable decision memory must fail closed before issue mutation');
      }
    }
  );

  assert.equal(report.summary.status, 'policy-blocked');
  assert.equal(report.summary.injected, false);
  assert.equal(report.replay.available, false);
  assert.match(report.summary.reason, /Decision memory is unreadable/);
  assert.ok(report.replay.error);
});

test('runMonitoringWorkInjection fails closed when required live wake evidence is stale', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-stale-evidence-'));
  const {
    policyPath,
    queuePath,
    monitoringPath,
    hostSignalPath,
    wakeAdjudicationPath,
    wakeWorkSynthesisPath,
    wakeInvestmentAccountingPath
  } = createInputs(tmpDir);
  writeJson(wakeAdjudicationPath, {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: '2026-03-20T10:00:00.000Z',
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
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      now: STALE_TEST_NOW
    },
    {
      runGhJsonFn: () => {
        throw new Error('stale evidence must fail closed before GitHub queries');
      },
      runGhFn: () => {
        throw new Error('stale evidence must fail closed before issue mutation');
      }
    }
  );

  assert.equal(report.summary.status, 'policy-blocked');
  assert.equal(report.freshness.status, 'blocked');
  assert.ok(report.freshness.blockingSources.includes('wakeAdjudication'));
  assert.equal(report.freshness.sources.wakeAdjudication.status, 'stale');
  assert.match(report.summary.reason, /Required live wake evidence is not fresh enough/);
});

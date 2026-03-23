import assert from 'node:assert/strict';
import test from 'node:test';

import { compareviRuntimeTest } from '../runtime-supervisor.mjs';

function createGovernorPortfolioSummary({
  currentOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  nextOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  nextAction = 'continue-compare-governance-work',
  ownerDecisionSource = 'compare-governor-summary',
  governorMode = 'compare-governance-work'
} = {}) {
  return {
    schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
    generatedAt: '2026-03-23T03:30:00.000Z',
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
      status: 'active',
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

test('planCompareviRuntimeStep injects monitoring work when queue-empty and a wake condition maps to a new issue', async () => {
  const branchClassContract = {
    schema: 'branch-classes/v1',
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    repositoryPlanes: [
      {
        id: 'upstream',
        repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
        laneBranchPrefix: 'issue/'
      },
      {
        id: 'origin',
        repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
        laneBranchPrefix: 'issue/origin-'
      }
    ],
    classes: [
      {
        id: 'lane',
        repositoryRoles: ['upstream', 'fork'],
        branchPatterns: ['issue/*'],
        purpose: 'lane',
        prSourceAllowed: true,
        prTargetAllowed: false,
        mergePolicy: 'n/a'
      }
    ],
    allowedTransitions: [
      {
        from: 'lane',
        action: 'promote',
        to: 'upstream-integration',
        via: 'pull-request'
      }
    ]
  };
  const decision = await compareviRuntimeTest.planCompareviRuntimeStep({
    repoRoot: '/tmp/repo',
    env: { GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action' },
    options: {},
    deps: {
      branchClassContract,
      loadDeliveryAgentPolicyFn: async () => ({ implementationRemote: 'origin' }),
      runMonitoringWorkInjectionFn: async () => ({
        issueNumber: 1805,
        issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1805',
        outputPath: '/tmp/repo/tests/results/_agent/issue/monitoring-work-injection.json',
        ledgerPath: '/tmp/repo/tests/results/_agent/ops/ops-decision-ledger.json'
      }),
      classifyNoStandingPriorityConditionFn: async () => ({
        status: 'classified',
        reason: 'queue-empty',
        openIssueCount: 0,
        message: 'queue empty'
      }),
      readGovernorPortfolioSummaryFn: async () =>
        createGovernorPortfolioSummary({
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          nextAction: 'reopen-template-monitoring-work',
          ownerDecisionSource: 'template-monitoring',
          governorMode: 'template-work'
        }),
      resolveStandingPriorityForRepoFn: async () => ({ found: null }),
      ghIssueFetcher: async () => ({
        number: 1805,
        title: '[monitoring]: reconcile runner-conflict blocking autonomous loop',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1805',
        body: ''
      }),
      restIssueFetcher: async () => ({
        number: 1805,
        title: '[monitoring]: reconcile runner-conflict blocking autonomous loop',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1805',
        body: ''
      }),
      loadBranchClassContractFn: async () => branchClassContract
    }
  });

  assert.equal(decision.outcome, 'selected');
  assert.equal(decision.stepOptions.issue, 1805);
  assert.equal(decision.artifacts.monitoringWorkInjectionPath, '/tmp/repo/tests/results/_agent/issue/monitoring-work-injection.json');
  assert.equal(decision.artifacts.monitoringDecisionLedgerPath, '/tmp/repo/tests/results/_agent/ops/ops-decision-ledger.json');
  assert.equal(decision.artifacts.governorPortfolioHandoff, undefined);
});

test('planCompareviRuntimeStep keeps queue-empty compare ownership as idle with owner-match handoff metadata', async () => {
  const decision = await compareviRuntimeTest.planCompareviRuntimeStep({
    repoRoot: '/tmp/repo',
    env: { GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action' },
    options: {},
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({ implementationRemote: 'origin' }),
      runMonitoringWorkInjectionFn: async () => ({
        issueNumber: null,
        outputPath: '/tmp/repo/tests/results/_agent/issue/monitoring-work-injection.json',
        ledgerPath: '/tmp/repo/tests/results/_agent/ops/ops-decision-ledger.json'
      }),
      classifyNoStandingPriorityConditionFn: async () => ({
        status: 'classified',
        reason: 'queue-empty',
        openIssueCount: 0,
        message: 'queue empty'
      }),
      resolveStandingPriorityForRepoFn: async () => ({ found: null }),
      readGovernorPortfolioSummaryFn: async () => createGovernorPortfolioSummary()
    }
  });

  assert.equal(decision.outcome, 'idle');
  assert.match(decision.reason, /keeps ownership/i);
  assert.equal(decision.artifacts.governorPortfolioHandoff.status, 'owner-match');
  assert.equal(
    decision.artifacts.governorPortfolioHandoff.currentOwnerRepository,
    'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  );
});

test('planCompareviRuntimeStep reports queue-empty external-owner handoff metadata when portfolio points at template', async () => {
  const decision = await compareviRuntimeTest.planCompareviRuntimeStep({
    repoRoot: '/tmp/repo',
    env: { GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action' },
    options: {},
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({ implementationRemote: 'origin' }),
      runMonitoringWorkInjectionFn: async () => ({
        issueNumber: null,
        outputPath: '/tmp/repo/tests/results/_agent/issue/monitoring-work-injection.json',
        ledgerPath: '/tmp/repo/tests/results/_agent/ops/ops-decision-ledger.json'
      }),
      classifyNoStandingPriorityConditionFn: async () => ({
        status: 'classified',
        reason: 'queue-empty',
        openIssueCount: 0,
        message: 'queue empty'
      }),
      resolveStandingPriorityForRepoFn: async () => ({ found: null }),
      readGovernorPortfolioSummaryFn: async () =>
        createGovernorPortfolioSummary({
          currentOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          nextAction: 'reopen-template-monitoring-work',
          ownerDecisionSource: 'template-monitoring',
          governorMode: 'template-work'
        })
    }
  });

  assert.equal(decision.outcome, 'idle');
  assert.match(decision.reason, /hands ownership/i);
  assert.equal(decision.artifacts.governorPortfolioHandoff.status, 'external-owner');
  assert.equal(
    decision.artifacts.governorPortfolioHandoff.currentOwnerRepository,
    'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
  );
});

test('planCompareviRuntimeStep treats missing portfolio summary as non-blocking idle metadata', async () => {
  const decision = await compareviRuntimeTest.planCompareviRuntimeStep({
    repoRoot: '/tmp/repo',
    env: { GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action' },
    options: {},
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({ implementationRemote: 'origin' }),
      runMonitoringWorkInjectionFn: async () => ({
        issueNumber: null,
        outputPath: '/tmp/repo/tests/results/_agent/issue/monitoring-work-injection.json',
        ledgerPath: '/tmp/repo/tests/results/_agent/ops/ops-decision-ledger.json'
      }),
      classifyNoStandingPriorityConditionFn: async () => ({
        status: 'classified',
        reason: 'queue-empty',
        openIssueCount: 0,
        message: 'queue empty'
      }),
      resolveStandingPriorityForRepoFn: async () => ({ found: null }),
      readGovernorPortfolioSummaryFn: async () => null
    }
  });

  assert.equal(decision.outcome, 'idle');
  assert.match(decision.reason, /unavailable \(missing\)/i);
  assert.equal(decision.artifacts.governorPortfolioHandoff.status, 'missing');
});

test('planCompareviRuntimeStep treats invalid portfolio summary as non-blocking idle metadata', async () => {
  const decision = await compareviRuntimeTest.planCompareviRuntimeStep({
    repoRoot: '/tmp/repo',
    env: { GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action' },
    options: {},
    deps: {
      loadDeliveryAgentPolicyFn: async () => ({ implementationRemote: 'origin' }),
      runMonitoringWorkInjectionFn: async () => ({
        issueNumber: null,
        outputPath: '/tmp/repo/tests/results/_agent/issue/monitoring-work-injection.json',
        ledgerPath: '/tmp/repo/tests/results/_agent/ops/ops-decision-ledger.json'
      }),
      classifyNoStandingPriorityConditionFn: async () => ({
        status: 'classified',
        reason: 'queue-empty',
        openIssueCount: 0,
        message: 'queue empty'
      }),
      resolveStandingPriorityForRepoFn: async () => ({ found: null }),
      readGovernorPortfolioSummaryFn: async () => ({
        schema: 'priority/not-the-portfolio-report@v1'
      })
    }
  });

  assert.equal(decision.outcome, 'idle');
  assert.match(decision.reason, /unavailable \(invalid\)/i);
  assert.equal(decision.artifacts.governorPortfolioHandoff.status, 'invalid');
});

import assert from 'node:assert/strict';
import test from 'node:test';

import { compareviRuntimeTest } from '../runtime-supervisor.mjs';

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
});

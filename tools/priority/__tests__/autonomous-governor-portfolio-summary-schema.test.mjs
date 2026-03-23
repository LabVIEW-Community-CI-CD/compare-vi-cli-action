import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { runAutonomousGovernorPortfolioSummary } from '../autonomous-governor-portfolio-summary.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function resolveValidatorRepoRoot(repoRoot) {
  const localValidatorOk =
    fs.existsSync(path.join(repoRoot, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'ajv', 'package.json')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'argparse', 'package.json'));
  if (localValidatorOk) {
    return repoRoot;
  }
  const candidates = [
    path.resolve(repoRoot, '..', 'compare-monitoring-canonical'),
    path.resolve(repoRoot, '..', '1843-wake-lifecycle-state-machine')
  ];
  return (
    candidates.find(
      (candidate) =>
        fs.existsSync(path.join(candidate, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'ajv', 'package.json')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'argparse', 'package.json'))
    ) || repoRoot
  );
}

function runSchemaValidate(repoRoot, schemaPath, dataPath) {
  const validatorRepoRoot = resolveValidatorRepoRoot(repoRoot);
  const result = spawnSync(
    'node',
    [path.join(validatorRepoRoot, 'dist', 'tools', 'schemas', 'validate-json.js'), '--schema', schemaPath, '--data', dataPath],
    {
      cwd: validatorRepoRoot,
      encoding: 'utf8'
    }
  );
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

test('autonomous governor portfolio summary schema validates a generated report', async () => {
  const repoRoot = path.resolve(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..'));
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-portfolio-schema-'));

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'), {
    schema: 'priority/autonomous-governor-summary-report@v1',
    generatedAt: '2026-03-22T22:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      queueEmptyReportPath: 'tests/results/_agent/issue/no-standing-priority.json',
      continuitySummaryPath: 'tests/results/_agent/handoff/continuity-summary.json',
      monitoringModePath: 'tests/results/_agent/handoff/monitoring-mode.json',
      wakeLifecyclePath: 'tests/results/_agent/issue/wake-lifecycle.json',
      wakeInvestmentAccountingPath: 'tests/results/_agent/capital/wake-investment-accounting.json'
    },
    compare: {
      queueState: { status: 'queue-empty', reason: 'queue-empty', openIssueCount: 0, ready: true },
      continuity: { status: 'maintained', turnBoundary: 'safe-idle', supervisionState: 'idle-monitoring', operatorPromptRequiredToResume: false },
      monitoringMode: { status: 'active', futureAgentAction: 'future-agent-may-pivot', wakeConditionCount: 0 },
      deliveryRuntime: {
        status: 'checks-pending',
        runtimeStatus: 'waiting-ci',
        laneLifecycle: 'waiting-ci',
        actionType: 'merge-pr',
        outcome: 'waiting-ci',
        blockerClass: 'none',
        nextWakeCondition: 'checks-green',
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864',
        issueNumber: 1863,
        reason: 'Waiting for hosted checks to finish before merge queue advances.'
      }
    },
    wake: {
      terminalState: 'monitoring',
      currentStage: 'monitoring',
      classification: null,
      decision: null,
      monitoringStatus: 'active',
      authoritativeTier: null,
      blockedLowerTierEvidence: false,
      replayMatched: false,
      replayAuthorityCompatible: null,
      issueNumber: null,
      issueUrl: null,
      recommendedOwnerRepository: null
    },
    funding: {
      accountingBucket: null,
      status: null,
      paybackStatus: null,
      recommendation: null,
      invoiceTurnId: null,
      fundingPurpose: null,
      activationState: null,
      benchmarkIssueUsd: null,
      observedWakeIssueUsd: null,
      netPaybackUsd: null
    },
    summary: {
      governorMode: 'monitoring-active',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'future-agent-may-pivot',
      signalQuality: 'idle-monitoring',
      queueState: 'queue-empty',
      continuityStatus: 'maintained',
      wakeTerminalState: 'monitoring',
      monitoringStatus: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      queueHandoffStatus: 'checks-pending',
      queueHandoffNextWakeCondition: 'checks-green',
      queueHandoffPrUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864'
    }
  });

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), {
    schema: 'agent-handoff/monitoring-mode-v1',
    generatedAt: '2026-03-22T22:01:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/template-monitoring.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      repoGraphPolicyPath: 'tools/policy/downstream-repo-graph.json',
      wakeConditions: []
    },
    compare: {
      queueState: { reportPath: 'tests/results/_agent/issue/no-standing-priority.json', ready: true, status: 'queue-empty', detail: 'queue-empty' },
      continuity: { reportPath: 'tests/results/_agent/handoff/continuity-summary.json', ready: true, status: 'maintained', detail: 'safe-idle' },
      pivotGate: { reportPath: 'tests/results/_agent/promotion/template-pivot-gate-report.json', ready: true, status: 'ready', detail: 'future-agent-may-pivot' },
      readyForMonitoring: true
    },
    repoGraph: { reportPath: 'tests/results/_agent/handoff/downstream-repo-graph-truth.json', ready: true, status: 'pass', detail: 'roles=7' },
    templateMonitoring: {
      status: 'pass',
      repositories: [
        {
          role: 'canonical-template',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: null,
          supportedProof: null
        },
        {
          role: 'org-consumer-fork',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: { status: 'pass', branch: 'develop', headSha: 'abc123', canonicalHeadSha: 'abc123' },
          supportedProof: { status: 'pass', runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/1', conclusion: 'success' }
        },
        {
          role: 'personal-consumer-fork',
          repository: 'svelderrainruiz/LabviewGitHubCiTemplate',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: { status: 'pass', branch: 'develop', headSha: 'abc123', canonicalHeadSha: 'abc123' },
          supportedProof: { status: 'pass', runUrl: 'https://github.com/svelderrainruiz/LabviewGitHubCiTemplate/actions/runs/2', conclusion: 'success' }
        }
      ],
      unsupportedPaths: []
    },
    wakeConditions: [],
    summary: { status: 'active', futureAgentAction: 'future-agent-may-pivot', wakeConditionCount: 0, triggeredWakeConditions: [] }
  });

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'downstream-repo-graph-truth.json'), {
    schema: 'priority/downstream-repo-graph-truth@v1',
    generatedAt: '2026-03-22T22:02:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/downstream-repo-graph.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repositories: [
      {
        id: 'compare',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        kind: 'supervisor',
        status: 'pass',
        roles: [{ id: 'compare-producer-lineage' }],
        summary: { requiredMissingRoleCount: 0, optionalMissingRoleCount: 0, alignmentFailureCount: 0, unknownRoleCount: 0 }
      },
      {
        id: 'canonical-template',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        kind: 'canonical-template',
        status: 'pass',
        roles: [{ id: 'template-canonical-development' }],
        summary: { requiredMissingRoleCount: 0, optionalMissingRoleCount: 0, alignmentFailureCount: 0, unknownRoleCount: 0 }
      },
      {
        id: 'org-consumer-fork',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
        kind: 'consumer-fork',
        status: 'pass',
        roles: [{ id: 'org-fork-canonical-development' }],
        summary: { requiredMissingRoleCount: 0, optionalMissingRoleCount: 0, alignmentFailureCount: 0, unknownRoleCount: 0 }
      },
      {
        id: 'personal-consumer-fork',
        repository: 'svelderrainruiz/LabviewGitHubCiTemplate',
        kind: 'consumer-fork',
        status: 'pass',
        roles: [{ id: 'personal-fork-canonical-development' }],
        summary: { requiredMissingRoleCount: 0, optionalMissingRoleCount: 0, alignmentFailureCount: 0, unknownRoleCount: 0 }
      }
    ],
    summary: { status: 'pass', repositoryCount: 4, roleCount: 4, requiredMissingRoleCount: 0, optionalMissingRoleCount: 0, alignmentFailureCount: 0, unknownRoleCount: 0 }
  });

  const outputPath = path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-portfolio-summary.json');
  const { report } = await runAutonomousGovernorPortfolioSummary({ repoRoot: tmpDir, outputPath });

  runSchemaValidate(repoRoot, path.join(repoRoot, 'docs', 'schemas', 'autonomous-governor-portfolio-summary-report-v1.schema.json'), outputPath);
  assert.equal(report.schema, 'priority/autonomous-governor-portfolio-summary-report@v1');
});

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  parseArgs,
  runHandoffMonitoringMode
} from '../handoff-monitoring-mode.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy() {
  return {
    schema: 'priority/template-monitoring-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    canonicalTemplate: {
      role: 'canonical-template',
      repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      branch: 'develop',
      openIssuesMustEqual: 0,
      mustMatchCanonicalBranch: false,
      supportedProof: null
    },
    consumerForks: [
      {
        role: 'org-consumer-fork',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
        branch: 'develop',
        openIssuesMustEqual: 0,
        mustMatchCanonicalBranch: true,
        supportedProof: {
          workflowFile: 'template-smoke.yml',
          event: 'workflow_dispatch',
          requiredConclusion: 'success'
        }
      }
    ],
    unsupportedPaths: [
      {
        name: 'fork-local-pr-validation',
        message: 'unsupported'
      }
    ],
    wakeConditions: [
      'compare-queue-not-empty',
      'compare-continuity-not-safe-idle',
      'compare-template-pivot-not-ready',
      'template-canonical-open-issues',
      'template-consumer-fork-drift',
      'template-supported-workflow-dispatch-regressed',
      'template-monitoring-unverified'
    ]
  };
}

function createCompareReadyInputs(tmpDir) {
  const policyPath = path.join(tmpDir, 'policy.json');
  const queuePath = path.join(tmpDir, 'queue.json');
  const continuityPath = path.join(tmpDir, 'continuity.json');
  const pivotPath = path.join(tmpDir, 'pivot.json');

  writeJson(policyPath, createPolicy());
  writeJson(queuePath, {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 0
  });
  writeJson(continuityPath, {
    schema: 'priority/continuity-telemetry-report@v1',
    status: 'maintained',
    continuity: {
      turnBoundary: {
        status: 'safe-idle',
        operatorPromptRequiredToResume: false
      }
    }
  });
  writeJson(pivotPath, {
    schema: 'priority/template-pivot-gate@v1',
    summary: {
      status: 'ready',
      readyForFutureAgentPivot: true,
      pivotDecision: 'future-agent-may-pivot'
    }
  });

  return { policyPath, queuePath, continuityPath, pivotPath };
}

function createHealthyGhResponder() {
  const ghResponses = new Map([
    ['issue|LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate', []],
    ['issue|LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork', []],
    ['api|repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/branches/develop', { commit: { sha: 'abc123' } }],
    ['api|repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/branches/develop', { commit: { sha: 'abc123' } }],
    ['run|LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork|template-smoke.yml|develop|workflow_dispatch', [
      {
        conclusion: 'success',
        url: 'https://example.invalid/run/1',
        headSha: 'abc123'
      }
    ]]
  ]);

  return (args) => {
    if (args[0] === 'issue') {
      return ghResponses.get(`issue|${args[3]}`) ?? [];
    }
    if (args[0] === 'api') {
      return ghResponses.get(`api|${args[1]}`);
    }
    if (args[0] === 'run') {
      return ghResponses.get(`run|${args[3]}|${args[5]}|${args[7]}|${args[9]}`);
    }
    throw new Error(`unsupported args: ${args.join(' ')}`);
  };
}

test('parseArgs accepts monitoring mode paths', () => {
  const parsed = parseArgs([
    'node',
    'handoff-monitoring-mode.mjs',
    '--policy',
    'policy.json',
    '--output',
    'monitoring.json',
    '--queue-empty-report',
    'queue.json',
    '--continuity-summary',
    'continuity.json',
    '--template-pivot-gate',
    'pivot.json',
    '--repo',
    'example/repo'
  ]);

  assert.equal(parsed.policyPath, 'policy.json');
  assert.equal(parsed.outputPath, 'monitoring.json');
  assert.equal(parsed.queueEmptyReportPath, 'queue.json');
  assert.equal(parsed.continuitySummaryPath, 'continuity.json');
  assert.equal(parsed.templatePivotGatePath, 'pivot.json');
  assert.equal(parsed.repo, 'example/repo');
});

test('runHandoffMonitoringMode reports active monitoring and future-agent pivot when compare is safe-idle and template contract is healthy', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'handoff-monitoring-mode-active-'));
  const { policyPath, queuePath, continuityPath, pivotPath } = createCompareReadyInputs(tmpDir);
  const outputPath = path.join(tmpDir, 'monitoring.json');

  const { report } = await runHandoffMonitoringMode(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      continuitySummaryPath: continuityPath,
      templatePivotGatePath: pivotPath,
      outputPath
    },
    {
      resolveRepoSlugFn: () => 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runGhJsonFn: createHealthyGhResponder()
    }
  );

  assert.equal(report.compare.readyForMonitoring, true);
  assert.equal(report.templateMonitoring.status, 'pass');
  assert.equal(report.summary.status, 'active');
  assert.equal(report.summary.futureAgentAction, 'future-agent-may-pivot');
  assert.equal(report.summary.wakeConditionCount, 0);
});

test('runHandoffMonitoringMode wakes template monitoring work when a supported consumer proof regresses', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'handoff-monitoring-mode-wake-'));
  const { policyPath, queuePath, continuityPath, pivotPath } = createCompareReadyInputs(tmpDir);

  const { report } = await runHandoffMonitoringMode(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      continuitySummaryPath: continuityPath,
      templatePivotGatePath: pivotPath
    },
    {
      resolveRepoSlugFn: () => 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runGhJsonFn: (args) => {
        if (args[0] === 'issue') {
          return [];
        }
        if (args[0] === 'api') {
          return { commit: { sha: 'abc123' } };
        }
        if (args[0] === 'run') {
          return [
            {
              conclusion: 'failure',
              url: 'https://example.invalid/run/2',
              headSha: 'abc123'
            }
          ];
        }
        throw new Error(`unsupported args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.summary.status, 'blocked');
  assert.equal(report.templateMonitoring.status, 'fail');
  assert.equal(report.summary.futureAgentAction, 'reopen-template-monitoring-work');
  assert.ok(report.summary.triggeredWakeConditions.includes('template-supported-workflow-dispatch-regressed'));
});

test('runHandoffMonitoringMode stays fail-closed when template monitoring cannot be verified', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'handoff-monitoring-mode-unverified-'));
  const { policyPath, queuePath, continuityPath, pivotPath } = createCompareReadyInputs(tmpDir);

  const { report } = await runHandoffMonitoringMode(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      continuitySummaryPath: continuityPath,
      templatePivotGatePath: pivotPath
    },
    {
      resolveRepoSlugFn: () => 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runGhJsonFn: (args) => {
        if (args[0] === 'issue' || args[0] === 'api' || args[0] === 'run') {
          throw new Error('gh unavailable');
        }
        throw new Error(`unsupported args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.compare.readyForMonitoring, true);
  assert.equal(report.templateMonitoring.status, 'unknown');
  assert.equal(report.summary.status, 'blocked');
  assert.equal(report.summary.futureAgentAction, 'stay-in-compare-monitoring');
  assert.ok(report.summary.triggeredWakeConditions.includes('template-monitoring-unverified'));
});

test('runHandoffMonitoringMode fails stale supported proof when the latest successful run is not on the current branch head', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'handoff-monitoring-mode-stale-proof-'));
  const { policyPath, queuePath, continuityPath, pivotPath } = createCompareReadyInputs(tmpDir);

  const { report } = await runHandoffMonitoringMode(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      continuitySummaryPath: continuityPath,
      templatePivotGatePath: pivotPath
    },
    {
      resolveRepoSlugFn: () => 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runGhJsonFn: (args) => {
        if (args[0] === 'issue') {
          return [];
        }
        if (args[0] === 'api') {
          return { commit: { sha: args[1].includes('/LabviewGitHubCiTemplate-fork/') ? 'new456' : 'abc123' } };
        }
        if (args[0] === 'run') {
          return [
            {
              conclusion: 'success',
              url: 'https://example.invalid/run/3',
              headSha: 'old123'
            }
          ];
        }
        throw new Error(`unsupported args: ${args.join(' ')}`);
      }
    }
  );

  const forkMonitor = report.templateMonitoring.repositories.find((entry) => entry.role === 'org-consumer-fork');
  assert.equal(forkMonitor.supportedProof.status, 'fail');
  assert.equal(report.templateMonitoring.status, 'fail');
  assert.equal(report.summary.status, 'blocked');
  assert.equal(report.summary.futureAgentAction, 'reopen-template-monitoring-work');
  assert.ok(report.summary.triggeredWakeConditions.includes('template-supported-workflow-dispatch-regressed'));
});

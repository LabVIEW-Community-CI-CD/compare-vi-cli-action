import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runMonitoringWorkInjection } from '../monitoring-work-injection.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function toGlobPath(filePath) {
  return path.resolve(filePath).replace(/\\/g, '/');
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
    path.resolve(repoRoot, '..', '1818-wake-investment-accounting'),
    path.resolve(repoRoot, '..', 'compare-monitoring-canonical')
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
  execFileSync('node', ['dist/tools/schemas/validate-json.js', '--schema', toGlobPath(schemaPath), '--data', toGlobPath(dataPath)], {
    cwd: validatorRepoRoot,
    stdio: 'pipe'
  });
}

test('monitoring work injection report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-schema-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const queueEmptyReportPath = path.join(tmpDir, 'queue.json');
  const monitoringModePath = path.join(tmpDir, 'monitoring-mode.json');
  const hostSignalPath = path.join(tmpDir, 'host-signal.json');
  const wakeAdjudicationPath = path.join(tmpDir, 'wake-adjudication.json');
  const wakeWorkSynthesisPath = path.join(tmpDir, 'wake-work-synthesis.json');
  const wakeInvestmentAccountingPath = path.join(tmpDir, 'wake-investment-accounting.json');
  const outputPath = path.join(tmpDir, 'monitoring-work-injection.json');

  writeJson(policyPath, {
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
      }
    ]
  });
  writeJson(queueEmptyReportPath, {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 0
  });
  writeJson(monitoringModePath, {
    schema: 'agent-handoff/monitoring-mode-v1',
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 1
    }
  });
  writeJson(hostSignalPath, {
    schema: 'priority/delivery-agent-host-signal@v1',
    generatedAt: '2099-01-01T00:00:00.000Z',
    status: 'ready',
    provider: 'native-wsl',
    daemonFingerprint: 'daemon-123'
  });
  writeJson(wakeAdjudicationPath, {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: '2099-01-01T00:01:00.000Z',
    summary: {
      classification: 'branch-target-drift',
      status: 'suppressed',
      suppressIssueInjection: true,
      suppressDownstreamIssueInjection: true,
      suppressTemplateIssueInjection: true,
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'reconcile-downstream-branch-target-provenance',
      reason: 'Live replay cleared blockers on the stale branch target.'
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

  const { report } = await runMonitoringWorkInjection(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath,
      monitoringModePath,
      hostSignalPath,
      wakeAdjudicationPath,
      wakeWorkSynthesisPath,
      wakeInvestmentAccountingPath,
      outputPath,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      apply: false
    },
    {
      runGhJsonFn: () => [],
      runGhFn: () => {
        throw new Error('dry run should not create issues');
      }
    }
  );

  runSchemaValidate(repoRoot, path.join(repoRoot, 'docs', 'schemas', 'monitoring-work-injection-report-v1.schema.json'), outputPath);
  assert.equal(report.schema, 'priority/monitoring-work-injection-report@v1');
});

test('checked-in monitoring work injection policy matches schema', () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  runSchemaValidate(
    repoRoot,
    path.join(repoRoot, 'docs', 'schemas', 'monitoring-work-injection-policy-v1.schema.json'),
    path.join(repoRoot, 'tools', 'policy', 'monitoring-work-injection.json')
  );
  assert.ok(true);
});

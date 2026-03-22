import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runWakeLifecycle } from '../wake-lifecycle.mjs';

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
    path.resolve(repoRoot, '..', 'compare-monitoring-canonical'),
    path.resolve(repoRoot, '..', '1839-wake-authority-tiers'),
    path.resolve(repoRoot, '..', '1818-wake-investment-accounting')
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

function createWakeAdjudication() {
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
      classification: 'branch-target-drift',
      nextAction: 'reconcile-downstream-branch-target-provenance',
      reason: 'Live replay contradicted the stale reported wake.',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    }
  };
}

function createWakeWorkSynthesis() {
  return {
    schema: 'priority/wake-work-synthesis-report@v1',
    generatedAt: '2026-03-22T22:01:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      decision: 'compare-governance-work',
      status: 'actionable',
      workKind: 'drift-correction',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      routingAuthorityTier: 'authoritative',
      blockedLowerTierEvidence: true,
      reason: 'Wake belongs to compare governance.'
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

function createMonitoringWorkInjection() {
  return {
    schema: 'priority/monitoring-work-injection-report@v1',
    generatedAt: '2026-03-22T22:03:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    replay: {
      matchedBy: 'dedupe-marker',
      matchedEntryCount: 1,
      authorityCompatible: true,
      authorityMismatchReason: null
    },
    summary: {
      status: 'existing-issue',
      reason: 'Monitoring work injection reused the existing issue route.',
      issueNumber: 1843,
      issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1843',
      triggerId: 'compare-governance-wake'
    }
  };
}

test('wake lifecycle report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-lifecycle-schema-'));
  const adjudicationPath = path.join(tmpDir, 'wake-adjudication.json');
  const synthesisPath = path.join(tmpDir, 'wake-work-synthesis.json');
  const accountingPath = path.join(tmpDir, 'wake-investment-accounting.json');
  const injectionPath = path.join(tmpDir, 'monitoring-work-injection.json');
  const outputPath = path.join(tmpDir, 'wake-lifecycle.json');

  writeJson(adjudicationPath, createWakeAdjudication());
  writeJson(synthesisPath, createWakeWorkSynthesis());
  writeJson(accountingPath, createWakeInvestmentAccounting());
  writeJson(injectionPath, createMonitoringWorkInjection());

  const { report } = await runWakeLifecycle({
    repoRoot: tmpDir,
    wakeAdjudicationPath: 'wake-adjudication.json',
    wakeWorkSynthesisPath: 'wake-work-synthesis.json',
    wakeInvestmentAccountingPath: 'wake-investment-accounting.json',
    monitoringWorkInjectionPath: 'monitoring-work-injection.json',
    outputPath: 'wake-lifecycle.json'
  });

  runSchemaValidate(repoRoot, path.join(repoRoot, 'docs', 'schemas', 'wake-lifecycle-report-v1.schema.json'), outputPath);
  assert.equal(report.schema, 'priority/wake-lifecycle-report@v1');
});

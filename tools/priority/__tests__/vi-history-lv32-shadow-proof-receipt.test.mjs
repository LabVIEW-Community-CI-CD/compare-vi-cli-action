#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = process.cwd();
const scriptPath = path.join(repoRoot, 'tools', 'Write-VIHistoryLV32ShadowProofReceipt.ps1');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('Write-VIHistoryLV32ShadowProofReceipt writes a promotion-ready receipt when runner labels and host-plane are ready', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vi-history-lv32-shadow-proof-'));
  const hostPlanePath = path.join(tempDir, 'labview-2026-host-plane-report.json');
  const compareSummaryPath = path.join(tempDir, 'history-summary.json');
  const compareReportPath = path.join(tempDir, 'history-report.html');
  const labelPaths = [
    'self-hosted',
    'Windows',
    'X64',
    'comparevi',
    'capability-ingress',
    'labview-2026',
    'lv32'
  ].map((label) => path.join(tempDir, `runner-label-contract-${label}.json`));
  const outputPath = path.join(tempDir, 'vi-history-lv32-shadow-proof-receipt.json');
  const summaryPath = path.join(tempDir, 'receipt.md');

  for (const [index, label] of ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'].entries()) {
    writeJson(labelPaths[index], {
      schema: 'runner-label-contract@v1',
      generatedAtUtc: '2026-03-25T23:00:00.000Z',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runId: '123',
      validationMode: 'repository-runner',
      runnerName: 'lv32-shadow-runner-01',
      runnerId: '101',
      requiredLabel: label,
      labels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress', 'labview-2026', 'lv32'],
      hasRequiredLabel: true,
      status: 'success',
      failureClass: 'none',
      failureMessage: ''
    });
  }

  writeJson(hostPlanePath, {
    schema: 'labview-2026-host-plane-report@v1',
    generatedAt: '2026-03-25T23:00:00.000Z',
    host: {
      os: 'windows',
      computerName: 'builder',
      osFingerprint: {
        role: 'canonical-host-baseline',
        comparisonScope: 'isolated-lane-group',
        platform: 'windows',
        fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        canonical: {
          version: '10.0.26200',
          buildNumber: '26200',
          ubr: 8037,
          displayVersion: '25H2',
          editionId: 'Professional',
          installationType: 'Client',
          architecture: '64-bit',
          systemType: 'x64-based PC',
          buildLabEx: '26100.1.amd64fre.ge_release.240331-1435'
        },
        advisory: {
          caption: 'Microsoft Windows 11 Pro',
          productName: 'Windows 10 Pro',
          currentVersionCompatibility: '6.3',
          brandingMismatch: true,
          installDate: '2026-02-14T03:49:47.0000000-08:00',
          lastBootUpTime: '2026-03-20T09:06:51.0000000-07:00'
        },
        sources: {
          registryPath: 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion',
          cimClass: 'Win32_OperatingSystem',
          systemClass: 'Win32_ComputerSystem',
          comparisonFields: ['version', 'buildNumber']
        }
      }
    },
    runner: { hostIsRunner: true, runnerName: 'lv32-shadow-runner-01', githubActions: true },
    docker: { operatorLabels: ['linux-docker-fast-loop', 'windows-docker-fast-loop', 'dual-docker-fast-loop'] },
    policy: {
      authoritativePlanes: ['docker-desktop/linux-container-2026', 'docker-desktop/windows-container-2026'],
      hostNativeShadowPlane: {
        plane: 'native-labview-2026-32',
        role: 'acceleration-surface',
        authoritative: false,
        executionMode: 'manual-opt-in',
        hostedCiAllowed: false,
        promotionPrerequisites: ['docker-desktop/linux-container-2026', 'docker-desktop/windows-container-2026']
      }
    },
    native: {
      parallelLabVIEWSupported: true,
      sharedCliAcrossNativePlanes: true,
      recommendedParallelPlanes: ['native-labview-2026-64', 'native-labview-2026-32'],
      planes: {
        x64: {
          plane: 'native-labview-2026-64',
          operatorLabel: 'native-labview-2026-64',
          architecture: '64-bit',
          requestedLabVIEWPath: 'C:/lv64/LabVIEW.exe',
          requestedCliPath: 'C:/cli/LabVIEWCLI.exe',
          requestedComparePath: 'C:/compare/LVCompare.exe',
          labviewPath: 'C:/lv64/LabVIEW.exe',
          cliPath: 'C:/cli/LabVIEWCLI.exe',
          comparePath: 'C:/compare/LVCompare.exe',
          labviewPresent: true,
          cliPresent: true,
          comparePresent: true,
          status: 'ready',
          issues: []
        },
        x32: {
          plane: 'native-labview-2026-32',
          operatorLabel: 'native-labview-2026-32',
          architecture: '32-bit',
          requestedLabVIEWPath: 'C:/lv32/LabVIEW.exe',
          requestedCliPath: 'C:/cli/LabVIEWCLI.exe',
          requestedComparePath: 'C:/compare/LVCompare.exe',
          labviewPath: 'C:/lv32/LabVIEW.exe',
          cliPath: 'C:/cli/LabVIEWCLI.exe',
          comparePath: 'C:/compare/LVCompare.exe',
          labviewPresent: true,
          cliPresent: true,
          comparePresent: true,
          status: 'ready',
          issues: []
        }
      }
    },
    executionPolicy: {
      mutuallyExclusivePairs: { pairs: [] },
      provenParallelPairs: { pairs: [] },
      candidateParallelPairs: { pairs: [] }
    }
  });

  writeJson(compareSummaryPath, {
    schema: 'comparevi-tools/history-facade@v1',
    generatedAtUtc: '2026-03-26T01:12:33.2480163Z',
    execution: {
      status: 'ok',
      reportFormat: 'html',
      resultsDir: path.join(tempDir, 'history'),
      manifestPath: path.join(tempDir, 'history', 'manifest.json'),
      requestedModes: ['default'],
      executedModes: ['default']
    },
    summary: {
      modes: 1,
      comparisons: 0,
      diffs: 0,
      signalDiffs: 0,
      noiseCollapsed: 0,
      missing: 0,
      errors: 0,
      categories: [],
      bucketProfile: [],
      categoryCountKeys: [],
      bucketCountKeys: []
    },
    reports: {
      markdownPath: path.join(tempDir, 'history-report.md'),
      htmlPath: compareReportPath
    }
  });
  fs.writeFileSync(compareReportPath, '<html><body>shadow proof</body></html>', 'utf8');

  const quotedLabelPaths = labelPaths
    .map((entry) => `'${entry.replace(/'/g, "''")}'`)
    .join(', ');
  const command = [
    `& '${scriptPath.replace(/'/g, "''")}'`,
    "-LaneName 'vi-history-scenarios-windows-lv32'",
    `-RunnerLabelContractPaths @(${quotedLabelPaths})`,
    `-HostPlaneReportPath '${hostPlanePath.replace(/'/g, "''")}'`,
    `-CompareSummaryPath '${compareSummaryPath.replace(/'/g, "''")}'`,
    `-CompareReportPath '${compareReportPath.replace(/'/g, "''")}'`,
    `-OutputJsonPath '${outputPath.replace(/'/g, "''")}'`,
    `-StepSummaryPath '${summaryPath.replace(/'/g, "''")}'`
  ].join(' ');

  execFileSync(
    'pwsh',
    ['-NoLogo', '-NoProfile', '-Command', command],
    {
      cwd: repoRoot,
      stdio: 'pipe',
      env: {
        ...process.env,
        GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        GITHUB_SHA: '2e058f794595649c2beeb1b531ca8f5401d1ead5',
        LVCI_COMPARE_MODE: 'labview-cli',
        LVCI_COMPARE_POLICY: 'cli-only'
      }
    }
  );

  const receipt = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  const schema = JSON.parse(fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'vi-history-lv32-shadow-proof-receipt-v1.schema.json'), 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(receipt), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(receipt.schema, 'priority/vi-history-lv32-shadow-proof-receipt@v1');
  assert.equal(receipt.repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(receipt.sourceCommitSha, '2e058f794595649c2beeb1b531ca8f5401d1ead5');
  assert.equal(receipt.lane.id, 'vi-history-scenarios-windows-lv32');
  assert.equal(receipt.runner.labelsMatched, true);
  assert.deepEqual(receipt.runner.requiredLabels, [
    'self-hosted',
    'Windows',
    'X64',
    'comparevi',
    'capability-ingress',
    'labview-2026',
    'lv32'
  ]);
  assert.equal(receipt.headless.required, true);
  assert.equal(receipt.headless.enforced, true);
  assert.equal(receipt.headless.executionMode, 'labview-cli-headless');
  assert.equal(receipt.hostPlane.status, 'ready');
  assert.equal(receipt.hostPlane.native32Status, 'ready');
  assert.equal(receipt.hostPlane.reportPath, hostPlanePath);
  assert.equal(receipt.hostPlane.labviewPath, 'C:/lv32/LabVIEW.exe');
  assert.equal(receipt.hostPlane.cliPath, 'C:/cli/LabVIEWCLI.exe');
  assert.equal(receipt.hostPlane.comparePath, 'C:/compare/LVCompare.exe');
  assert.equal(receipt.verification.status, 'pass');
  assert.equal(receipt.verification.summaryPath, compareSummaryPath);
  assert.equal(receipt.verification.reportPath, compareReportPath);
  assert.ok(fs.existsSync(summaryPath), 'step summary should be written');
});

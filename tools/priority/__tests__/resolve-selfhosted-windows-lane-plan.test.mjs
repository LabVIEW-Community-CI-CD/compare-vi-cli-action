#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const repoRoot = process.cwd();
const scriptPath = path.join(repoRoot, 'tools', 'Resolve-SelfHostedWindowsLanePlan.ps1');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('Resolve-SelfHostedWindowsLanePlan reports available when an online idle runner advertises the full LV32 capability set', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'selfhosted-windows-lane-plan-'));
  const inventoryPath = path.join(tempDir, 'runner-inventory.json');
  const outputPath = path.join(tempDir, 'plan.json');
  const summaryPath = path.join(tempDir, 'plan.md');
  const outputFile = path.join(tempDir, 'github-output.txt');

  writeJson(inventoryPath, {
    runners: [
      {
        id: 101,
        name: 'lv32-shadow-runner-01',
        status: 'online',
        busy: false,
        labels: [
          'self-hosted',
          'Windows',
          'X64',
          'comparevi',
          'capability-ingress',
          'labview-2026',
          'lv32'
        ]
      },
      {
        id: 102,
        name: 'comparevi-ingress-only',
        status: 'online',
        busy: false,
        labels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress']
      }
    ]
  });

  execFileSync('pwsh', [
    '-NoLogo',
    '-NoProfile',
    '-File',
    scriptPath,
    '-Repository',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '-RunnerInventoryPath',
    inventoryPath,
    '-OutputJsonPath',
    outputPath,
    '-GitHubOutputPath',
    outputFile,
    '-StepSummaryPath',
    summaryPath
  ], { cwd: repoRoot, stdio: 'pipe' });

  const plan = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(plan.schema, 'priority/self-hosted-windows-lane-plan@v1');
  assert.equal(plan.available, true);
  assert.equal(plan.status, 'available');
  assert.equal(plan.matchingRunnerCount, 1);
  assert.equal(plan.matchingRunners[0].name, 'lv32-shadow-runner-01');
  assert.deepEqual(plan.requiredLabels, [
    'self-hosted',
    'Windows',
    'X64',
    'comparevi',
    'capability-ingress',
    'labview-2026',
    'lv32'
  ]);
  assert.ok(fs.existsSync(summaryPath), 'step summary should be written');
  assert.match(fs.readFileSync(outputFile, 'utf8'), /available=true/);
});

test('Resolve-SelfHostedWindowsLanePlan reports unavailable when the LV32 labels are missing', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'selfhosted-windows-lane-plan-missing-'));
  const inventoryPath = path.join(tempDir, 'runner-inventory.json');
  const outputPath = path.join(tempDir, 'plan.json');

  writeJson(inventoryPath, {
    runners: [
      {
        id: 201,
        name: 'comparevi-ingress-only',
        status: 'online',
        busy: false,
        labels: ['self-hosted', 'Windows', 'X64', 'comparevi', 'capability-ingress']
      }
    ]
  });

  execFileSync('pwsh', [
    '-NoLogo',
    '-NoProfile',
    '-File',
    scriptPath,
    '-Repository',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '-RunnerInventoryPath',
    inventoryPath,
    '-OutputJsonPath',
    outputPath
  ], { cwd: repoRoot, stdio: 'pipe' });

  const plan = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(plan.available, false);
  assert.equal(plan.status, 'missing-label');
  assert.equal(plan.matchingRunnerCount, 0);
  assert.match(plan.skipReason, /no online self-hosted Windows runner matched the required capability labels/i);
});

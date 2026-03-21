#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_OUTPUT_PATH,
  buildCrossPlaneBudgetReport,
  main,
  parseArgs,
} from '../vi-history-cross-plane-budget.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createMeasurement({
  runtimeProfile,
  runtimePlane,
  benchmarkSampleKind,
  elapsedMilliseconds,
  targetPath = 'fixtures/vi-attr/Head.vi',
  branchRef = 'HEAD',
  baselineRef = '',
  maxPairs = 2,
  maxCommitCount = 64,
  finalStatus = 'succeeded',
  generatedAt = '2026-03-21T06:30:00.000Z',
}) {
  return {
    schema: 'comparevi/local-refinement@v1',
    generatedAt,
    runtimeProfile,
    runtimePlane,
    image: 'placeholder-image',
    toolSource: 'test-stub',
    cacheReuseState: 'test',
    coldWarmClass: 'cold',
    benchmarkSampleKind,
    repoRoot: 'C:/repo',
    resultsRoot: `C:/repo/tests/results/local-vi-history/${runtimeProfile}`,
    timings: {
      elapsedMilliseconds,
      elapsedSeconds: Number((elapsedMilliseconds / 1000).toFixed(3)),
    },
    history: {
      targetPath: `C:/repo/${targetPath}`,
      branchRef,
      baselineRef,
      maxPairs,
      maxCommitCount,
    },
    finalStatus,
  };
}

test('parseArgs supports the cross-plane budget contract surface', () => {
  const parsed = parseArgs([
    'node',
    'vi-history-cross-plane-budget.mjs',
    '--linux-receipt',
    'linux.json',
    '--windows-receipt',
    'windows.json',
    '--shadow-receipt',
    'shadow.json',
    '--host-plane-report',
    'host.json',
    '--output',
    'custom-report.json',
    '--markdown',
    'custom-report.md',
    '--windows-threshold-ratio',
    '1.25',
    '--shadow-accelerator-ratio',
    '1.0',
    '--windows-over-budget-justification',
    'approved drift',
    '--fail-on-warn',
  ]);

  assert.equal(parsed.linuxReceiptPath, 'linux.json');
  assert.equal(parsed.windowsReceiptPath, 'windows.json');
  assert.equal(parsed.shadowReceiptPath, 'shadow.json');
  assert.equal(parsed.hostPlaneReportPath, 'host.json');
  assert.equal(parsed.outputPath, 'custom-report.json');
  assert.equal(parsed.markdownPath, 'custom-report.md');
  assert.equal(parsed.windowsThresholdRatio, 1.25);
  assert.equal(parsed.shadowAcceleratorRatio, 1.0);
  assert.equal(parsed.windowsOverBudgetJustification, 'approved drift');
  assert.equal(parsed.failOnWarn, true);
});

test('buildCrossPlaneBudgetReport passes when Windows stays within budget and shadow accelerates at least one plane', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vi-history-cross-plane-budget-'));
  const linuxPath = path.join(tempDir, 'linux.json');
  const windowsPath = path.join(tempDir, 'windows.json');
  const shadowPath = path.join(tempDir, 'shadow.json');
  const hostPath = path.join(tempDir, 'host-plane.json');

  writeJson(linuxPath, createMeasurement({
    runtimeProfile: 'proof',
    runtimePlane: 'linux',
    benchmarkSampleKind: 'proof-cold',
    elapsedMilliseconds: 1000,
  }));
  writeJson(windowsPath, createMeasurement({
    runtimeProfile: 'windows-mirror-proof',
    runtimePlane: 'windows-mirror',
    benchmarkSampleKind: 'windows-mirror-proof-cold',
    elapsedMilliseconds: 1150,
  }));
  writeJson(shadowPath, createMeasurement({
    runtimeProfile: 'host-32bit-shadow',
    runtimePlane: 'host-32bit-shadow',
    benchmarkSampleKind: 'host-32bit-shadow-cold',
    elapsedMilliseconds: 850,
  }));
  writeJson(hostPath, {
    schema: 'labview-2026-host-plane-report@v1',
    native: {
      parallelLabVIEWSupported: false,
      planes: {
        x64: { status: 'ready' },
        x32: { status: 'ready' },
      },
    },
  });

  const { report, markdown } = await buildCrossPlaneBudgetReport({
    linuxReceiptPath: linuxPath,
    windowsReceiptPath: windowsPath,
    shadowReceiptPath: shadowPath,
    hostPlaneReportPath: hostPath,
  });

  assert.equal(report.schema, 'vi-history/cross-plane-performance-budget@v1');
  assert.equal(report.workload.comparable, true);
  assert.equal(report.comparisons.windowsVsLinux.status, 'pass');
  assert.equal(report.comparisons.windowsVsLinux.candidateToBaselineRatio, 1.15);
  assert.equal(report.comparisons.shadowVsLinux.status, 'pass');
  assert.equal(report.comparisons.shadowVsWindows.status, 'pass');
  assert.equal(report.comparisons.shadowSummary.status, 'pass');
  assert.equal(report.overall.status, 'pass');
  assert.match(markdown, /Windows\/Linux ratio: `1\.15x`/);
  assert.match(markdown, /Shadow 32-bit: `0\.85s`/);
});

test('buildCrossPlaneBudgetReport fails on over-budget Windows timing and warns when shadow measurement is missing', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vi-history-cross-plane-budget-warn-'));
  const linuxPath = path.join(tempDir, 'linux.json');
  const windowsPath = path.join(tempDir, 'windows.json');
  const hostPath = path.join(tempDir, 'host-plane.json');

  writeJson(linuxPath, createMeasurement({
    runtimeProfile: 'proof',
    runtimePlane: 'linux',
    benchmarkSampleKind: 'proof-cold',
    elapsedMilliseconds: 1000,
  }));
  writeJson(windowsPath, createMeasurement({
    runtimeProfile: 'windows-mirror-proof',
    runtimePlane: 'windows-mirror',
    benchmarkSampleKind: 'windows-mirror-proof-cold',
    elapsedMilliseconds: 1400,
  }));
  writeJson(hostPath, {
    schema: 'labview-2026-host-plane-report@v1',
    native: {
      parallelLabVIEWSupported: false,
      planes: {
        x64: { status: 'ready' },
        x32: { status: 'ready' },
      },
    },
  });

  const { report } = await buildCrossPlaneBudgetReport({
    linuxReceiptPath: linuxPath,
    windowsReceiptPath: windowsPath,
    hostPlaneReportPath: hostPath,
  });

  assert.equal(report.comparisons.windowsVsLinux.status, 'fail');
  assert.equal(report.comparisons.windowsVsLinux.candidateToBaselineRatio, 1.4);
  assert.equal(report.planes.shadow32, null);
  assert.equal(report.comparisons.shadowSummary.status, 'missing');
  assert.equal(report.overall.status, 'fail');
  assert.equal(report.overall.blockers[0].code, 'windows-over-budget');
  assert.equal(report.overall.warnings[0].code, 'shadow-measurement-missing');
});

test('main writes JSON and Markdown receipts', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vi-history-cross-plane-budget-main-'));
  const linuxPath = path.join(tempDir, 'linux.json');
  const windowsPath = path.join(tempDir, 'windows.json');
  const outputPath = path.join(tempDir, 'report.json');
  const markdownPath = path.join(tempDir, 'report.md');

  writeJson(linuxPath, createMeasurement({
    runtimeProfile: 'proof',
    runtimePlane: 'linux',
    benchmarkSampleKind: 'proof-cold',
    elapsedMilliseconds: 1000,
  }));
  writeJson(windowsPath, createMeasurement({
    runtimeProfile: 'windows-mirror-proof',
    runtimePlane: 'windows-mirror',
    benchmarkSampleKind: 'windows-mirror-proof-cold',
    elapsedMilliseconds: 1100,
  }));

  const exitCode = await main([
    'node',
    'vi-history-cross-plane-budget.mjs',
    '--linux-receipt',
    linuxPath,
    '--windows-receipt',
    windowsPath,
    '--output',
    outputPath,
    '--markdown',
    markdownPath,
  ]);

  assert.equal(DEFAULT_OUTPUT_PATH.endsWith('cross-plane-performance-budget.json'), true);
  assert.equal(exitCode, 0);
  assert.equal(fs.existsSync(outputPath), true);
  assert.equal(fs.existsSync(markdownPath), true);
});

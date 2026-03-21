#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildCrossPlaneBudgetReport } from '../vi-history-cross-plane-budget.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createMeasurement({
  runtimeProfile,
  runtimePlane,
  benchmarkSampleKind,
  elapsedMilliseconds,
}) {
  return {
    schema: 'comparevi/local-refinement@v1',
    generatedAt: '2026-03-21T06:30:00.000Z',
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
      targetPath: 'C:/repo/fixtures/vi-attr/Head.vi',
      branchRef: 'HEAD',
      baselineRef: '',
      maxPairs: 2,
      maxCommitCount: 64,
    },
    finalStatus: 'succeeded',
  };
}

test('cross-plane budget report validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'vi-history-cross-plane-budget-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vi-history-cross-plane-budget-schema-'));
  const linuxPath = path.join(tempDir, 'linux.json');
  const windowsPath = path.join(tempDir, 'windows.json');
  const shadowPath = path.join(tempDir, 'shadow.json');
  const hostPath = path.join(tempDir, 'host.json');

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
    elapsedMilliseconds: 1180,
  }));
  writeJson(shadowPath, createMeasurement({
    runtimeProfile: 'host-32bit-shadow',
    runtimePlane: 'host-32bit-shadow',
    benchmarkSampleKind: 'host-32bit-shadow-cold',
    elapsedMilliseconds: 900,
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
    shadowReceiptPath: shadowPath,
    hostPlaneReportPath: hostPath,
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

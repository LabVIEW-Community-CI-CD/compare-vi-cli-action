#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_TARGET_PROFILE,
  PROFILE_CATALOG,
  buildHostRamBudgetReport,
  parseArgs,
} from '../host-ram-budget.mjs';

test('parseArgs supports explicit resource overrides and target profile', () => {
  const parsed = parseArgs([
    'node',
    'host-ram-budget.mjs',
    '--output',
    'custom-budget.json',
    '--target-profile',
    'heavy',
    '--total-bytes',
    '17179869184',
    '--free-bytes',
    '10737418240',
    '--cpu-parallelism',
    '12',
    '--minimum-parallelism',
    '1',
  ]);

  assert.equal(parsed.outputPath, 'custom-budget.json');
  assert.equal(parsed.targetProfile, 'heavy');
  assert.equal(parsed.totalBytes, 17179869184);
  assert.equal(parsed.freeBytes, 10737418240);
  assert.equal(parsed.cpuParallelism, 12);
  assert.equal(parsed.minimumParallelism, 1);
});

test('buildHostRamBudgetReport recommends parallel heavy scenarios on roomy hosts', () => {
  const report = buildHostRamBudgetReport(
    {
      targetProfile: 'ni-linux-flag-combination',
      minimumParallelism: 1,
    },
    {
      totalmemFn: () => 16 * 1024 * 1024 * 1024,
      freememFn: () => 10 * 1024 * 1024 * 1024,
      availableParallelismFn: () => 12,
    },
  );

  assert.equal(report.schema, 'priority/host-ram-budget@v1');
  assert.equal(report.selectedProfile.id, 'ni-linux-flag-combination');
  assert.equal(report.selectedProfile.recommendedParallelism, 2);
  assert.equal(report.selectedProfile.floorApplied, false);
  assert.equal(report.selectedProfile.degradedByPressure, true);
});

test('buildHostRamBudgetReport keeps a deterministic floor under memory pressure', () => {
  const report = buildHostRamBudgetReport(
    {
      targetProfile: 'windows-mirror-heavy',
      minimumParallelism: 1,
    },
    {
      totalmemFn: () => 8 * 1024 * 1024 * 1024,
      freememFn: () => 768 * 1024 * 1024,
      availableParallelismFn: () => 8,
    },
  );

  assert.equal(report.selectedProfile.id, 'windows-mirror-heavy');
  assert.equal(report.selectedProfile.recommendedParallelism, 1);
  assert.equal(report.selectedProfile.floorApplied, true);
  assert.ok(report.selectedProfile.reasons.includes('deterministic-floor'));
});

test('defaults stay aligned with the contract surface', () => {
  const parsed = parseArgs(['node', 'host-ram-budget.mjs']);
  assert.equal(parsed.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(parsed.targetProfile, DEFAULT_TARGET_PROFILE);
  assert.equal(parsed.minimumParallelism, 1);
  assert.ok(PROFILE_CATALOG.heavy);
});

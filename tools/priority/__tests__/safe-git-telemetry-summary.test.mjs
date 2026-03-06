#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { computeTrendSummary, runCli } from '../summarize-safe-git-telemetry.mjs';

function sampleRun({ status = 'success', recoveryElapsedMs = 0, counters = {} } = {}) {
  return {
    schema: 'priority/safe-git-run-telemetry@v1',
    startedAt: new Date('2026-03-06T00:00:00Z').toISOString(),
    finishedAt: new Date('2026-03-06T00:00:01Z').toISOString(),
    status,
    reason: status === 'success' ? 'ok' : 'git-nonzero',
    recoveryElapsedMs,
    counters: {
      lockDetections: 0,
      repairAttempts: 0,
      repairSuccesses: 0,
      repairFailures: 0,
      runtimeLockConflicts: 0,
      killedProcessCount: 0,
      ...counters
    }
  };
}

test('computeTrendSummary aggregates reliability counters and trend deltas', () => {
  const runs = [
    sampleRun({
      status: 'success',
      recoveryElapsedMs: 100,
      counters: { lockDetections: 1, repairAttempts: 1, repairSuccesses: 1 }
    }),
    sampleRun({
      status: 'blocked',
      recoveryElapsedMs: 0,
      counters: { lockDetections: 2, repairAttempts: 1, repairFailures: 1, runtimeLockConflicts: 1 }
    }),
    sampleRun({
      status: 'success',
      recoveryElapsedMs: 200,
      counters: { lockDetections: 1, repairAttempts: 1, repairSuccesses: 1, killedProcessCount: 1 }
    }),
    sampleRun({
      status: 'command-error',
      recoveryElapsedMs: 0,
      counters: { lockDetections: 0, repairAttempts: 0, repairFailures: 0 }
    })
  ];

  const summary = computeTrendSummary(runs, 4);
  assert.equal(summary.schema, 'priority/safe-git-reliability-trend@v1');
  assert.equal(summary.metrics.totalRuns, 4);
  assert.equal(summary.metrics.failedRuns, 2);
  assert.equal(summary.metrics.lockDetections, 4);
  assert.equal(summary.metrics.repairAttempts, 3);
  assert.equal(summary.metrics.repairSuccesses, 2);
  assert.equal(summary.metrics.repairFailures, 1);
  assert.equal(summary.metrics.runtimeLockConflicts, 1);
  assert.equal(summary.metrics.killedProcessCount, 1);
  assert.equal(summary.metrics.meanRecoveryMs, 150);
  assert.ok(typeof summary.trend.failureRatioDelta === 'number');
  assert.ok(typeof summary.trend.meanRecoveryDeltaMs === 'number');
});

test('summarize-safe-git-telemetry CLI writes summary from jsonl input', async () => {
  const work = await mkdtemp(path.join(tmpdir(), 'safe-git-summary-'));
  const input = path.join(work, 'safe-git-events.jsonl');
  const output = path.join(work, 'safe-git-trend-summary.json');

  const rows = [
    sampleRun({
      status: 'success',
      recoveryElapsedMs: 50,
      counters: { lockDetections: 1, repairAttempts: 1, repairSuccesses: 1 }
    }),
    sampleRun({
      status: 'blocked',
      recoveryElapsedMs: 0,
      counters: { lockDetections: 1, repairAttempts: 1, repairFailures: 1 }
    })
  ];

  await writeFile(input, `${rows.map((entry) => JSON.stringify(entry)).join('\n')}\n`, 'utf8');

  const code = await runCli(['--input', input, '--output', output, '--window', '10']);
  assert.equal(code, 0);

  const summary = JSON.parse(await readFile(output, 'utf8'));
  assert.equal(summary.schema, 'priority/safe-git-reliability-trend@v1');
  assert.equal(summary.metrics.totalRuns, 2);
  assert.equal(summary.metrics.lockDetections, 2);
  assert.equal(summary.metrics.failedRuns, 1);
});


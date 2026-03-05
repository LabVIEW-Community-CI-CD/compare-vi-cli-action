import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  readSessionIndexHygiene,
  parseRogueScanOutput,
  ensureRogueScanClean
} from '../lib/release-hygiene.mjs';

test('readSessionIndexHygiene accepts clean session index evidence', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-hygiene-ok-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));
  const resultsDir = path.join(repoDir, 'tests', 'results');
  await mkdir(resultsDir, { recursive: true });
  await writeFile(
    path.join(resultsDir, 'session-index.json'),
    `${JSON.stringify({
      status: 'ok',
      summary: { failed: 0, errors: 0, total: 3, skipped: 0 },
      branchProtection: { result: { status: 'ok' } }
    })}\n`,
    'utf8'
  );

  const summary = readSessionIndexHygiene(repoDir);
  assert.equal(summary.status, 'ok');
  assert.equal(summary.summary.failed, 0);
  assert.equal(summary.summary.errors, 0);
});

test('readSessionIndexHygiene rejects failing session index evidence', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-hygiene-fail-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));
  const resultsDir = path.join(repoDir, 'tests', 'results');
  await mkdir(resultsDir, { recursive: true });
  await writeFile(
    path.join(resultsDir, 'session-index.json'),
    `${JSON.stringify({
      status: 'warn',
      summary: { failed: 1, errors: 0 }
    })}\n`,
    'utf8'
  );

  assert.throws(() => readSessionIndexHygiene(repoDir), /status must be "ok"/i);
});

test('parseRogueScanOutput and ensureRogueScanClean accept clean rogue report', () => {
  const report = parseRogueScanOutput(
    JSON.stringify({
      generatedAt: '2026-03-05T00:00:00Z',
      lookbackSeconds: 900,
      rogue: { lvcompare: [], labview: [] },
      noticed: { lvcompare: [123], labview: [] }
    })
  );
  const summary = ensureRogueScanClean(report);
  assert.equal(summary.rogue.lvcompare.length, 0);
  assert.equal(summary.rogue.labview.length, 0);
});

test('ensureRogueScanClean rejects rogue process findings', () => {
  assert.throws(
    () =>
      ensureRogueScanClean({
        rogue: { lvcompare: [111], labview: [] },
        noticed: { lvcompare: [], labview: [] }
      }),
    /Rogue process detection must be clean/i
  );
});

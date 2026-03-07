#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { appendDecisionLedgerEntry, redactSensitiveFields, replayDecisionLedger, runDecisionLedger } from '../decision-ledger.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(payload, null, 2), 'utf8');
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('redactSensitiveFields redacts token-adjacent keys and values', () => {
  const payload = {
    token: 'ghp_abcdefghijklmnopqrstuvwxyz123456',
    auth: {
      authorization: 'Bearer secret-value',
      safe: 'ok'
    },
    notes: 'contains github_pat_abc12345678901234567890',
    nested: [
      {
        api_key: 'value'
      }
    ]
  };

  const redacted = redactSensitiveFields(payload);
  assert.equal(redacted.token, '[REDACTED]');
  assert.equal(redacted.auth.authorization, '[REDACTED]');
  assert.equal(redacted.auth.safe, 'ok');
  assert.equal(redacted.notes, '[REDACTED]');
  assert.equal(redacted.nested[0].api_key, '[REDACTED]');
});

test('appendDecisionLedgerEntry appends deterministically without mutating prior records', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ops-ledger-'));
  const ledgerPath = path.join(tmpDir, 'ledger.json');
  const decision1Path = path.join(tmpDir, 'decision-1.json');
  const decision2Path = path.join(tmpDir, 'decision-2.json');

  writeJson(decision1Path, {
    schema: 'priority/policy-decision-report@v1',
    event: { fingerprint: 'fp-1' },
    decision: { type: 'open-issue' },
    authToken: 'gho_secret_value_12345678901234567890'
  });
  writeJson(decision2Path, {
    schema: 'priority/policy-decision-report@v1',
    event: { fingerprint: 'fp-2' },
    decision: { type: 'comment-issue' }
  });

  const first = await appendDecisionLedgerEntry({
    decisionPath: decision1Path,
    ledgerPath,
    source: 'policy-engine',
    now: new Date('2026-03-07T04:00:00Z')
  });
  assert.equal(first.ledger.entryCount, 1);
  assert.equal(first.entry.sequence, 1);
  assert.equal(first.entry.fingerprint, 'fp-1');
  assert.equal(first.entry.decision.authToken, '[REDACTED]');

  const firstDigest = first.entry.decisionDigest;
  const second = await appendDecisionLedgerEntry({
    decisionPath: decision2Path,
    ledgerPath,
    source: 'policy-engine',
    now: new Date('2026-03-07T04:01:00Z')
  });

  assert.equal(second.ledger.entryCount, 2);
  assert.equal(second.ledger.entries[0].sequence, 1);
  assert.equal(second.ledger.entries[0].decisionDigest, firstDigest);
  assert.equal(second.ledger.entries[1].sequence, 2);
  assert.equal(second.ledger.entries[1].fingerprint, 'fp-2');

  const persisted = readJson(ledgerPath);
  assert.equal(persisted.entryCount, 2);
});

test('replayDecisionLedger filters by sequence and fingerprint deterministically', () => {
  const ledger = {
    schema: 'ops-decision-ledger@v1',
    generatedAt: '2026-03-07T04:00:00Z',
    entryCount: 2,
    entries: [
      { sequence: 1, appendedAt: '2026-03-07T04:00:00Z', source: 'a', decisionDigest: 'a'.repeat(64), fingerprint: 'fp-1', decision: { id: 1 } },
      { sequence: 2, appendedAt: '2026-03-07T04:01:00Z', source: 'b', decisionDigest: 'b'.repeat(64), fingerprint: 'fp-2', decision: { id: 2 } }
    ]
  };

  const bySequence = replayDecisionLedger(ledger, { sequence: 2, now: '2026-03-07T04:02:00Z' });
  assert.equal(bySequence.count, 1);
  assert.equal(bySequence.decisions[0].sequence, 2);

  const byFingerprint = replayDecisionLedger(ledger, { fingerprint: 'fp-1', now: '2026-03-07T04:02:00Z' });
  assert.equal(byFingerprint.count, 1);
  assert.equal(byFingerprint.decisions[0].fingerprint, 'fp-1');
});

test('runDecisionLedger supports append and replay commands', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ops-ledger-cli-'));
  const ledgerPath = path.join(tmpDir, 'ledger.json');
  const replayPath = path.join(tmpDir, 'replay.json');
  const decisionPath = path.join(tmpDir, 'decision.json');

  writeJson(decisionPath, {
    schema: 'priority/policy-decision-report@v1',
    event: { fingerprint: 'fp-cli' },
    decision: { type: 'open-issue' }
  });

  const appendResult = await runDecisionLedger({
    argv: ['node', 'decision-ledger.mjs', 'append', '--decision', decisionPath, '--ledger', ledgerPath, '--source', 'policy-engine']
  });
  assert.equal(appendResult.exitCode, 0);
  assert.equal(appendResult.mode, 'append');

  const replayResult = await runDecisionLedger({
    argv: ['node', 'decision-ledger.mjs', 'replay', '--ledger', ledgerPath, '--output', replayPath, '--sequence', '1']
  });
  assert.equal(replayResult.exitCode, 0);
  assert.equal(replayResult.mode, 'replay');

  const replay = readJson(replayPath);
  assert.equal(replay.schema, 'ops-decision-replay@v1');
  assert.equal(replay.count, 1);
});

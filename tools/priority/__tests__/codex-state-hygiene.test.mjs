#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import {
  normalizeCodexCwd,
  runCodexStateHygiene,
  selectStaleThreadCandidates,
  writeCodexStateHygieneReport
} from '../codex-state-hygiene.mjs';

async function createDatabase(dbPath) {
  const sqlite = await import('node:sqlite');
  const db = new sqlite.DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      rollout_path TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      source TEXT NOT NULL,
      model_provider TEXT NOT NULL,
      cwd TEXT NOT NULL,
      title TEXT NOT NULL,
      sandbox_policy TEXT NOT NULL,
      approval_mode TEXT NOT NULL,
      tokens_used INTEGER NOT NULL DEFAULT 0,
      has_user_event INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0,
      archived_at INTEGER,
      git_sha TEXT,
      git_branch TEXT,
      git_origin_url TEXT,
      cli_version TEXT NOT NULL DEFAULT '',
      first_user_message TEXT NOT NULL DEFAULT '',
      agent_nickname TEXT,
      agent_role TEXT,
      memory_mode TEXT NOT NULL DEFAULT 'enabled'
    );

    CREATE TABLE logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      thread_id TEXT,
      ts INTEGER NOT NULL,
      process_uuid TEXT,
      payload TEXT
    );
  `);
  return db;
}

test('selectStaleThreadCandidates keeps the newest runtime worktree thread and archives older duplicates', async () => {
  const now = new Date('2026-03-11T20:00:00.000Z');
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'codex-state-candidates-'));
  const runtimeCwd = path.join(tempRoot, '.runtime-worktrees', 'example', 'origin-1010');
  await mkdir(runtimeCwd, { recursive: true });
  const candidates = selectStaleThreadCandidates(
    [
      {
        id: 'latest-runtime',
        cwd: runtimeCwd,
        rollout_path: 'latest.jsonl',
        updated_at: Math.floor(new Date('2026-03-11T18:00:00.000Z').getTime() / 1000),
        archived: 0,
        git_branch: 'issue/origin-1010'
      },
      {
        id: 'older-runtime',
        cwd: runtimeCwd,
        rollout_path: 'older.jsonl',
        updated_at: Math.floor(new Date('2026-03-11T10:00:00.000Z').getTime() / 1000),
        archived: 0,
        git_branch: 'issue/origin-1010'
      },
      {
        id: 'wsl-thread',
        cwd: '\\\\wsl.localhost\\Ubuntu\\tmp',
        rollout_path: 'wsl.jsonl',
        updated_at: Math.floor(new Date('2026-03-11T09:00:00.000Z').getTime() / 1000),
        archived: 0,
        git_branch: ''
      }
    ],
    {
      now,
      minThreadAgeHours: 4
    }
  );

  assert.deepEqual(
    candidates.map((entry) => entry.id),
    ['older-runtime', 'wsl-thread']
  );
  assert.equal(candidates[0].reason, 'duplicate-runtime-thread');
  assert.equal(candidates[1].reason, 'wsl-unc-thread');
});

test('normalizeCodexCwd converts Linux and WSL worktree paths into host-safe Windows paths', () => {
  const repoRoot = 'C:\\dev\\compare-vi-cli-action\\compare-vi-cli-action';

  assert.equal(
    normalizeCodexCwd('/mnt/c/dev/compare-vi-cli-action/compare-vi-cli-action/.runtime-worktrees/repo/origin-1010', { repoRoot }),
    'C:\\dev\\compare-vi-cli-action\\compare-vi-cli-action\\.runtime-worktrees\\repo\\origin-1010'
  );
  assert.equal(
    normalizeCodexCwd('/work/.runtime-worktrees/repo/origin-1010', { repoRoot }),
    'C:\\dev\\compare-vi-cli-action\\compare-vi-cli-action\\.runtime-worktrees\\repo\\origin-1010'
  );
  assert.equal(
    normalizeCodexCwd('\\\\wsl.localhost\\Ubuntu\\mnt\\c\\dev\\compare-vi-cli-action\\compare-vi-cli-action', { repoRoot }),
    'C:\\dev\\compare-vi-cli-action\\compare-vi-cli-action'
  );
});

test('runCodexStateHygiene archives stale threads, prunes old null logs, and writes a report', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'codex-state-hygiene-'));
  const codexHome = path.join(tempRoot, '.codex');
  const sessionsRoot = path.join(codexHome, 'sessions', '2026', '03', '11');
  const stateDbPath = path.join(codexHome, 'state_5.sqlite');
  const reportPath = path.join(tempRoot, 'report.json');
  const runtimeCwd = path.join(tempRoot, 'repo', '.runtime-worktrees', 'example', 'origin-1010');
  const logPath = path.join(tempRoot, 'Codex.log');
  const now = new Date('2026-03-11T20:00:00.000Z');

  await mkdir(sessionsRoot, { recursive: true });
  await mkdir(runtimeCwd, { recursive: true });
  await writeFile(
    path.join(sessionsRoot, 'rollout-latest.jsonl'),
    [
      JSON.stringify({ type: 'session_meta', payload: { cwd: runtimeCwd } }),
      JSON.stringify({ type: 'turn_context', payload: { cwd: runtimeCwd } })
    ].join('\n'),
    'utf8'
  );
  await writeFile(
    path.join(sessionsRoot, 'rollout-older.jsonl'),
    [
      JSON.stringify({ type: 'session_meta', payload: { cwd: '/work/.runtime-worktrees/example/origin-1010' } }),
      JSON.stringify({ type: 'turn_context', payload: { cwd: '/work/.runtime-worktrees/example/origin-1010' } })
    ].join('\n'),
    'utf8'
  );
  await writeFile(
    logPath,
    [
      '2026-03-11 12:35:03.809 [error] Error fetching errorMessage="local-environments is not supported in the extension"',
      '2026-03-11 12:35:03.810 [error] Error fetching errorMessage="open-in-target not supported in extension"',
      '2026-03-11 12:35:03.811 [warning] [IpcClient] Received broadcast but no handler is configured method=thread-stream-state-changed',
      '2026-03-11 12:35:03.812 [warning] [git-origin-and-roots] Failed to resolve origin for workspace'
    ].join('\n'),
    'utf8'
  );

  const db = await createDatabase(stateDbPath);
  try {
    const nowSeconds = Math.floor(now.getTime() / 1000);
    db.prepare(
      `
        INSERT INTO threads (
          id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
          sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
          git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
          agent_role, memory_mode
        ) VALUES (?, ?, ?, ?, 'exec', 'openai', ?, 'title', 'danger', 'never', 0, 0, 0, NULL, NULL, ?, NULL, '0.114.0', '', NULL, NULL, 'enabled')
      `
    ).run(
      'latest-runtime',
      path.join(sessionsRoot, 'rollout-latest.jsonl'),
      nowSeconds - 7 * 3600,
      nowSeconds - 2 * 3600,
      runtimeCwd,
      'issue/origin-1010'
    );
    db.prepare(
      `
        INSERT INTO threads (
          id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
          sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
          git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
          agent_role, memory_mode
        ) VALUES (?, ?, ?, ?, 'exec', 'openai', ?, 'title', 'danger', 'never', 0, 0, 0, NULL, NULL, ?, NULL, '0.114.0', '', NULL, NULL, 'enabled')
      `
    ).run(
      'older-runtime',
      path.join(sessionsRoot, 'rollout-older.jsonl'),
      nowSeconds - 10 * 3600,
      nowSeconds - 8 * 3600,
      runtimeCwd,
      'issue/origin-1010'
    );
    db.prepare(
      `
        INSERT INTO threads (
          id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
          sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
          git_sha, git_branch, git_origin_url, cli_version, first_user_message, agent_nickname,
          agent_role, memory_mode
        ) VALUES (?, ?, ?, ?, 'exec', 'openai', ?, 'title', 'danger', 'never', 0, 0, 0, NULL, NULL, ?, NULL, '0.114.0', '', NULL, NULL, 'enabled')
      `
    ).run(
      'missing-wsl',
      path.join(sessionsRoot, 'rollout-missing.jsonl'),
      nowSeconds - 10 * 3600,
      nowSeconds - 9 * 3600,
      '\\\\wsl.localhost\\Ubuntu\\tmp',
      ''
    );

    db.prepare('INSERT INTO logs (thread_id, ts, process_uuid, payload) VALUES (?, ?, ?, ?)').run(
      null,
      nowSeconds - 48 * 3600,
      'p1',
      'old-null'
    );
    db.prepare('INSERT INTO logs (thread_id, ts, process_uuid, payload) VALUES (?, ?, ?, ?)').run(
      null,
      nowSeconds - 60,
      'p2',
      'recent-null'
    );
  } finally {
    db.close();
  }

  const result = await runCodexStateHygiene({
    apply: true,
    codexHome,
    latestLogPath: logPath,
    minThreadAgeHours: 4,
    nullLogRetentionHours: 4,
    now
  });
  await writeCodexStateHygieneReport(reportPath, result);

  const sqlite = await import('node:sqlite');
  const liveDb = new sqlite.DatabaseSync(stateDbPath);
  try {
    const archivedRows = liveDb.prepare('SELECT id, archived FROM threads ORDER BY id').all();
    const oldNullCount = Number(liveDb.prepare("SELECT COUNT(*) AS c FROM logs WHERE payload = 'old-null'").get().c || 0);
    const recentNullCount = Number(liveDb.prepare("SELECT COUNT(*) AS c FROM logs WHERE payload = 'recent-null'").get().c || 0);
    const olderRuntime = liveDb.prepare('SELECT rollout_path, cwd FROM threads WHERE id = ?').get('older-runtime');

    assert.equal(result.status, 'mutated');
    assert.equal(result.applied.archivedThreadCount, 2);
    assert.equal(result.applied.deletedNullLogCount, 1);
    assert.equal(result.applied.relocatedRolloutCount, 1);
    assert.equal(result.applied.rewrittenRolloutCount, 1);
    assert.equal(result.extensionLog.counts.localEnvironmentsUnsupported, 1);
    assert.equal(result.extensionLog.counts.openInTargetUnsupported, 1);
    assert.equal(result.extensionLog.counts.threadStreamStateChanged, 1);
    assert.equal(result.extensionLog.counts.gitOriginAndRoots, 1);
    assert.equal(oldNullCount, 0);
    assert.equal(recentNullCount, 1);
    assert.match(String(olderRuntime.rollout_path), /archive[\\/]sessions/);
    assert.equal(olderRuntime.cwd, runtimeCwd);
    assert.equal(existsSync(path.join(sessionsRoot, 'rollout-older.jsonl')), false);
    assert.equal(existsSync(String(olderRuntime.rollout_path)), true);
    assert.deepEqual(
      archivedRows.map((entry) => [entry.id, entry.archived]),
      [
        ['latest-runtime', 0],
        ['missing-wsl', 1],
        ['older-runtime', 1]
      ]
    );
  } finally {
    liveDb.close();
  }

  const persisted = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(persisted.status, 'mutated');
  assert.equal(persisted.database.staleThreadCandidates.length, 0);
  assert.equal(persisted.archiveSessions.fileCount, 1);
});

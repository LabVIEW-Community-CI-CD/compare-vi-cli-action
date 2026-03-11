#!/usr/bin/env node

import os from 'node:os';
import path from 'node:path';
import { existsSync } from 'node:fs';
import { mkdir, readFile, readdir, rename, stat, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

function normalizeText(value) {
  if (value == null) {
    return '';
  }

  return String(value).trim();
}

function toPositiveNumber(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return fallback;
  }
  return parsed;
}

export function parseArgs(argv = process.argv.slice(2)) {
  const codexHome = path.join(os.homedir(), '.codex');
  const repoRoot = process.cwd();
  let archiveRootExplicit = false;
  const options = {
    apply: false,
    codexHome,
    repoRoot,
    archiveRoot: path.join(codexHome, 'archive', 'sessions'),
    report: path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'codex-state-hygiene.json'),
    minThreadAgeHours: 4,
    nullLogRetentionHours: 0,
    maxHotSessionsBytes: 512 * 1024 * 1024,
    recentLogLines: 5000,
    latestLogPath: null
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = normalizeText(argv[index]);
    if (!arg) {
      continue;
    }

    if (arg === '--apply') {
      options.apply = true;
      continue;
    }

    if (arg === '--codex-home') {
      options.codexHome = path.resolve(argv[index + 1] || options.codexHome);
      index += 1;
      continue;
    }

    if (arg === '--repo-root') {
      options.repoRoot = path.resolve(argv[index + 1] || options.repoRoot);
      index += 1;
      continue;
    }

    if (arg === '--archive-root') {
      options.archiveRoot = path.resolve(argv[index + 1] || options.archiveRoot);
      archiveRootExplicit = true;
      index += 1;
      continue;
    }

    if (arg === '--report') {
      options.report = path.resolve(argv[index + 1] || options.report);
      index += 1;
      continue;
    }

    if (arg === '--min-thread-age-hours') {
      options.minThreadAgeHours = toPositiveNumber(argv[index + 1], options.minThreadAgeHours);
      index += 1;
      continue;
    }

    if (arg === '--null-log-retention-hours') {
      options.nullLogRetentionHours = toPositiveNumber(argv[index + 1], options.nullLogRetentionHours);
      index += 1;
      continue;
    }

    if (arg === '--max-hot-sessions-bytes') {
      options.maxHotSessionsBytes = Math.max(0, Math.floor(toPositiveNumber(argv[index + 1], options.maxHotSessionsBytes)));
      index += 1;
      continue;
    }

    if (arg === '--recent-log-lines') {
      options.recentLogLines = Math.max(1, Math.floor(toPositiveNumber(argv[index + 1], options.recentLogLines)));
      index += 1;
      continue;
    }

    if (arg === '--log-path') {
      options.latestLogPath = path.resolve(argv[index + 1] || '');
      index += 1;
    }
  }

  if (!archiveRootExplicit) {
    options.archiveRoot = path.join(options.codexHome, 'archive', 'sessions');
  }

  return options;
}

function stripOpaqueWindowsPrefix(value) {
  if (value.startsWith('\\\\?\\')) {
    return value.slice(4);
  }
  return value;
}

function normalizePathForFs(value) {
  const text = normalizeText(value);
  if (!text) {
    return '';
  }
  return stripOpaqueWindowsPrefix(text);
}

function isWindowsAbsolutePath(value) {
  if (typeof value !== 'string') {
    return false;
  }

  return /^[a-z]:[\\/]/i.test(value) || /^\\\\[^\\]+\\[^\\]+/i.test(value);
}

function pathExistsOrNull(value) {
  if (!value) {
    return false;
  }
  return existsSync(value);
}

export function normalizeCodexCwd(cwd, options = {}) {
  const normalized = normalizePathForFs(cwd);
  if (!normalized) {
    return '';
  }

  const repoRoot = path.resolve(options.repoRoot || process.cwd());

  const wslUncMountMatch = normalized.match(/^\\\\wsl(?:\.localhost)?\\[^\\]+\\mnt\\([a-z])\\(.*)$/i);
  if (wslUncMountMatch) {
    const drive = wslUncMountMatch[1].toUpperCase();
    const rest = wslUncMountMatch[2].replace(/\\/g, '\\');
    return `${drive}:\\${rest}`;
  }

  if (isWindowsAbsolutePath(normalized)) {
    return path.normalize(normalized);
  }

  const linuxMountMatch = normalized.match(/^\/mnt\/([a-z])\/(.*)$/i);
  if (linuxMountMatch) {
    const drive = linuxMountMatch[1].toUpperCase();
    const rest = linuxMountMatch[2].replace(/\//g, '\\');
    return `${drive}:\\${rest}`;
  }

  if (normalized === '/work') {
    return repoRoot;
  }

  if (normalized.startsWith('/work/')) {
    const suffix = normalized.slice('/work/'.length).replace(/\//g, path.sep);
    return path.join(repoRoot, suffix);
  }

  return repoRoot;
}

function inspectThreadCwd(cwd) {
  const normalized = normalizePathForFs(cwd);
  const lowerWindows = normalized.replace(/\//g, '\\').toLowerCase();
  let kind = 'workspace';

  if (normalized.startsWith('\\\\wsl.localhost\\')) {
    kind = 'wsl-unc';
  } else if (normalized.startsWith('/work/.runtime-worktrees/')) {
    kind = 'linux-runtime-worktree';
  } else if (/^\/mnt\/[a-z]\//i.test(normalized) && normalized.includes('/.runtime-worktrees/')) {
    kind = 'linux-runtime-worktree';
  } else if (lowerWindows.includes('\\.runtime-worktrees\\')) {
    kind = 'runtime-worktree';
  }

  return {
    original: normalizeText(cwd),
    normalized,
    key: lowerWindows,
    kind,
    exists: normalized ? existsSync(normalized) : false
  };
}

export function selectStaleThreadCandidates(threads, options = {}) {
  const now = options.now instanceof Date ? options.now : new Date();
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const minThreadAgeSeconds = Math.floor(toPositiveNumber(options.minThreadAgeHours, 4) * 3600);
  const grouped = new Map();

  for (const thread of threads) {
    const cwdInfo = inspectThreadCwd(thread.cwd);
    if (cwdInfo.kind === 'workspace' && cwdInfo.exists) {
      continue;
    }

    const updatedAt = Number(thread.updated_at || 0);
    const ageSeconds = Math.max(0, nowSeconds - updatedAt);
    const enriched = {
      ...thread,
      updated_at: updatedAt,
      archived: Number(thread.archived || 0),
      cwdInfo,
      ageSeconds
    };
    const key = cwdInfo.key || `thread:${thread.id}`;
    if (!grouped.has(key)) {
      grouped.set(key, []);
    }
    grouped.get(key).push(enriched);
  }

  const candidates = [];
  for (const group of grouped.values()) {
    group.sort((left, right) => Number(right.updated_at) - Number(left.updated_at));
    const keepThreadId = group.find((entry) => entry.cwdInfo.exists && entry.cwdInfo.kind === 'runtime-worktree')?.id || null;

    for (const thread of group) {
      if (thread.archived !== 0 || thread.ageSeconds < minThreadAgeSeconds) {
        continue;
      }

      let reason = null;
      if (!thread.cwdInfo.exists) {
        reason = 'missing-cwd';
      } else if (thread.cwdInfo.kind === 'wsl-unc') {
        reason = 'wsl-unc-thread';
      } else if (thread.cwdInfo.kind === 'linux-runtime-worktree') {
        reason = 'linux-runtime-worktree-thread';
      } else if (thread.cwdInfo.kind === 'runtime-worktree' && keepThreadId && thread.id !== keepThreadId) {
        reason = 'duplicate-runtime-thread';
      }

      if (reason) {
        candidates.push({
          id: thread.id,
          cwd: thread.cwdInfo.original,
          cwdKind: thread.cwdInfo.kind,
          cwdExists: thread.cwdInfo.exists,
          updatedAt: thread.updated_at,
          ageSeconds: thread.ageSeconds,
          gitBranch: normalizeText(thread.git_branch),
          rolloutPath: normalizeText(thread.rollout_path),
          reason
        });
      }
    }
  }

  return candidates.sort((left, right) => Number(right.updatedAt) - Number(left.updatedAt));
}

function isPathWithinRoot(candidatePath, rootPath) {
  const normalizedCandidate = path.resolve(normalizePathForFs(candidatePath));
  const normalizedRoot = path.resolve(normalizePathForFs(rootPath));
  if (normalizedCandidate.toLowerCase() === normalizedRoot.toLowerCase()) {
    return true;
  }
  return normalizedCandidate.toLowerCase().startsWith(`${normalizedRoot.toLowerCase()}${path.sep}`);
}

function buildArchivePath(rolloutPath, sessionsRoot, archiveRoot) {
  const relativePath = path.relative(path.resolve(sessionsRoot), path.resolve(rolloutPath));
  return path.join(path.resolve(archiveRoot), relativePath);
}

function makeRolloutMutationSet(threads, staleCandidates, options = {}) {
  const staleCandidateIds = new Set(staleCandidates.map((entry) => entry.id));
  const now = options.now instanceof Date ? options.now : new Date();
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const minThreadAgeSeconds = Math.floor(toPositiveNumber(options.minThreadAgeHours, 4) * 3600);
  const sessionsRoot = path.resolve(options.sessionsRoot || '');

  return threads.filter((thread) => {
    const updatedAt = Number(thread.updated_at || 0);
    const ageSeconds = Math.max(0, nowSeconds - updatedAt);
    const rolloutPath = normalizePathForFs(thread.rollout_path);
    if (!rolloutPath || !pathExistsOrNull(rolloutPath)) {
      return false;
    }
    if (!isPathWithinRoot(rolloutPath, sessionsRoot)) {
      return false;
    }
    if (ageSeconds < minThreadAgeSeconds) {
      return false;
    }
    return Number(thread.archived || 0) !== 0 || staleCandidateIds.has(thread.id);
  });
}

async function collectSessionSummary(sessionsRoot) {
  const summary = {
    exists: existsSync(sessionsRoot),
    fileCount: 0,
    totalBytes: 0,
    latestPath: null,
    latestMtimeMs: null,
    oldestPath: null,
    oldestMtimeMs: null
  };

  if (!summary.exists) {
    return summary;
  }

  const stack = [sessionsRoot];
  while (stack.length > 0) {
    const current = stack.pop();
    const entries = await readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }
      if (!entry.isFile()) {
        continue;
      }

      const fileStat = await stat(fullPath);
      summary.fileCount += 1;
      summary.totalBytes += fileStat.size;
      if (summary.latestMtimeMs == null || fileStat.mtimeMs > summary.latestMtimeMs) {
        summary.latestMtimeMs = fileStat.mtimeMs;
        summary.latestPath = fullPath;
      }
      if (summary.oldestMtimeMs == null || fileStat.mtimeMs < summary.oldestMtimeMs) {
        summary.oldestMtimeMs = fileStat.mtimeMs;
        summary.oldestPath = fullPath;
      }
    }
  }

  return summary;
}

async function findLatestCodexLog(logsRoot) {
  if (!existsSync(logsRoot)) {
    return null;
  }

  const windowCandidates = [];
  const topLevelEntries = await readdir(logsRoot, { withFileTypes: true });
  for (const topLevel of topLevelEntries) {
    if (!topLevel.isDirectory()) {
      continue;
    }
    const topLevelPath = path.join(logsRoot, topLevel.name);
    const windowRoot = path.join(topLevelPath, 'window1', 'exthost', 'openai.chatgpt', 'Codex.log');
    if (existsSync(windowRoot)) {
      const fileStat = await stat(windowRoot);
      windowCandidates.push({ path: windowRoot, mtimeMs: fileStat.mtimeMs });
    }

    const nestedEntries = await readdir(topLevelPath, { withFileTypes: true });
    for (const nested of nestedEntries) {
      if (!nested.isDirectory() || !nested.name.startsWith('window')) {
        continue;
      }
      const candidate = path.join(topLevelPath, nested.name, 'exthost', 'openai.chatgpt', 'Codex.log');
      if (!existsSync(candidate)) {
        continue;
      }
      const fileStat = await stat(candidate);
      windowCandidates.push({ path: candidate, mtimeMs: fileStat.mtimeMs });
    }
  }

  windowCandidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  return windowCandidates[0]?.path || null;
}

async function collectLogPatternCounts(logPath, recentLogLines) {
  const patterns = [
    ['gitOriginAndRoots', '[git-origin-and-roots]'],
    ['localEnvironmentsUnsupported', 'local-environments is not supported in the extension'],
    ['openInTargetUnsupported', 'open-in-target not supported in extension'],
    ['threadStreamStateChanged', 'thread-stream-state-changed'],
    ['databaseLocked', 'database is locked'],
    ['slowStatement', 'slow statement: execution time exceeded alert threshold']
  ];

  if (!logPath || !existsSync(logPath)) {
    return {
      available: false,
      path: logPath,
      lineCount: 0,
      recentLineCount: 0,
      counts: Object.fromEntries(patterns.map(([key]) => [key, 0]))
    };
  }

  const content = await readFile(logPath, 'utf8');
  const lines = content.split(/\r?\n/);
  const recentLines = lines.slice(Math.max(0, lines.length - recentLogLines));
  const counts = {};
  for (const [key, token] of patterns) {
    counts[key] = recentLines.reduce((total, line) => total + (line.includes(token) ? 1 : 0), 0);
  }

  return {
    available: true,
    path: logPath,
    lineCount: lines.filter(Boolean).length,
    recentLineCount: recentLines.filter(Boolean).length,
    counts
  };
}

async function rewriteRolloutCwds(rolloutPath, normalizedCwd) {
  if (!rolloutPath || !pathExistsOrNull(rolloutPath)) {
    return {
      rewritten: false,
      rewrittenLineCount: 0
    };
  }

  const content = await readFile(rolloutPath, 'utf8');
  const lines = content.split(/\r?\n/);
  let rewrittenLineCount = 0;
  const updatedLines = lines.map((line) => {
    if (!line.trim()) {
      return line;
    }

    try {
      const entry = JSON.parse(line);
      if (entry && entry.payload && typeof entry.payload.cwd === 'string' && entry.payload.cwd !== normalizedCwd) {
        entry.payload.cwd = normalizedCwd;
        rewrittenLineCount += 1;
        return JSON.stringify(entry);
      }
      return line;
    } catch {
      return line;
    }
  });

  if (rewrittenLineCount === 0) {
    return {
      rewritten: false,
      rewrittenLineCount: 0
    };
  }

  await writeFile(rolloutPath, `${updatedLines.join('\n').replace(/\n+$/u, '')}\n`, 'utf8');
  return {
    rewritten: true,
    rewrittenLineCount
  };
}

async function relocateRolloutFile(rolloutPath, sessionsRoot, archiveRoot) {
  const normalizedRolloutPath = path.resolve(normalizePathForFs(rolloutPath));
  if (!pathExistsOrNull(normalizedRolloutPath) || !isPathWithinRoot(normalizedRolloutPath, sessionsRoot)) {
    return {
      relocated: false,
      targetPath: normalizedRolloutPath,
      bytesMoved: 0
    };
  }

  const archivePath = buildArchivePath(normalizedRolloutPath, sessionsRoot, archiveRoot);
  if (archivePath.toLowerCase() === normalizedRolloutPath.toLowerCase()) {
    return {
      relocated: false,
      targetPath: normalizedRolloutPath,
      bytesMoved: 0
    };
  }

  const rolloutStat = await stat(normalizedRolloutPath);
  await mkdir(path.dirname(archivePath), { recursive: true });
  await rename(normalizedRolloutPath, archivePath);
  return {
    relocated: true,
    targetPath: archivePath,
    bytesMoved: rolloutStat.size
  };
}

function deriveStatus(summary, options = {}) {
  if (!summary.stateDb.exists) {
    return 'skipped';
  }
  if (
    summary.applied.requested
    && (
      summary.applied.archivedThreadCount > 0
      || summary.applied.deletedNullLogCount > 0
      || summary.applied.normalizedThreadCwdCount > 0
      || summary.applied.relocatedRolloutCount > 0
      || summary.applied.rewrittenRolloutCount > 0
    )
  ) {
    return 'mutated';
  }
  if (
    summary.database.threadlessLogRows > 100000
    || summary.database.staleThreadCandidates.length > 0
    || summary.sessions.totalBytes > toPositiveNumber(options.maxHotSessionsBytes, 512 * 1024 * 1024)
  ) {
    return 'action-needed';
  }
  return 'ok';
}

async function openDatabaseSync(dbPath, deps = {}) {
  const importSqliteFn = deps.importSqliteFn ?? ((specifier) => import(specifier));
  let sqlite;
  try {
    sqlite = await importSqliteFn('node:sqlite');
  } catch (error) {
    const unavailable = new Error(
      'Built-in SQLite module "node:sqlite" is not available in this Node.js runtime.'
    );
    unavailable.code = 'SQLITE_MODULE_UNAVAILABLE';
    unavailable.cause = error;
    throw unavailable;
  }

  if (typeof sqlite?.DatabaseSync !== 'function') {
    const unavailable = new Error('The "node:sqlite" module does not expose DatabaseSync.');
    unavailable.code = 'SQLITE_DATABASESYNC_UNAVAILABLE';
    throw unavailable;
  }

  return new sqlite.DatabaseSync(dbPath);
}

function countTableRows(db, tableName) {
  return Number(db.prepare(`SELECT COUNT(*) AS c FROM ${tableName}`).get().c || 0);
}

function checkpointWal(db) {
  try {
    const rows = db.prepare('PRAGMA wal_checkpoint(TRUNCATE)').all();
    return {
      ok: true,
      rows
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

export async function runCodexStateHygiene(options = {}, deps = {}) {
  const now = options.now instanceof Date ? options.now : new Date();
  const codexHome = path.resolve(options.codexHome || path.join(os.homedir(), '.codex'));
  const repoRoot = path.resolve(options.repoRoot || process.cwd());
  const stateDbPath = path.join(codexHome, 'state_5.sqlite');
  const walPath = `${stateDbPath}-wal`;
  const sessionsRoot = path.join(codexHome, 'sessions');
  const archiveRoot = path.resolve(options.archiveRoot || path.join(codexHome, 'archive', 'sessions'));
  const codeLogsRoot = options.codeLogsRoot || path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Code', 'logs');
  const latestLogPath = options.latestLogPath || (await findLatestCodexLog(codeLogsRoot));
  const sessionSummary = await collectSessionSummary(sessionsRoot);
  const archiveSessionSummary = await collectSessionSummary(archiveRoot);
  const logSummary = await collectLogPatternCounts(latestLogPath, options.recentLogLines || 5000);

  const summary = {
    schema: 'priority/codex-state-hygiene-report@v1',
    generatedAt: now.toISOString(),
    codexHome,
    repoRoot,
    stateDb: {
      path: stateDbPath,
      exists: existsSync(stateDbPath),
      sizeBytes: 0,
      walPath,
      walExists: existsSync(walPath),
      walSizeBytes: 0
    },
    sessions: sessionSummary,
    archiveSessions: archiveSessionSummary,
    extensionLog: logSummary,
    database: {
      journalMode: null,
      walAutocheckpoint: null,
      pageCount: 0,
      pageSize: 0,
      freelistCount: 0,
      threadCount: 0,
      logCount: 0,
      threadlessLogRows: 0,
      nullThreadLogRowsOlderThanRetention: 0,
      staleThreadCandidates: []
    },
    applied: {
      requested: Boolean(options.apply),
      archivedThreadCount: 0,
      deletedNullLogCount: 0,
      normalizedThreadCwdCount: 0,
      relocatedRolloutCount: 0,
      relocatedRolloutBytes: 0,
      rewrittenRolloutCount: 0,
      walCheckpoint: null,
      error: null
    },
    status: 'skipped'
  };

  if (summary.stateDb.exists) {
    summary.stateDb.sizeBytes = (await stat(stateDbPath)).size;
  }
  if (summary.stateDb.walExists) {
    summary.stateDb.walSizeBytes = (await stat(walPath)).size;
  }

  if (!summary.stateDb.exists) {
    summary.status = deriveStatus(summary, options);
    return summary;
  }

  let db;
  try {
    db = await openDatabaseSync(stateDbPath, deps);
  } catch (error) {
    if (error?.code === 'SQLITE_MODULE_UNAVAILABLE' || error?.code === 'SQLITE_DATABASESYNC_UNAVAILABLE') {
      summary.database.driver = 'unavailable';
      summary.database.unavailableReason = error.message;
      summary.applied.error = error.message;
      summary.status = 'action-needed';
      return summary;
    }
    throw error;
  }
  try {
    db.exec('PRAGMA busy_timeout = 10000');
    summary.database.journalMode = db.prepare('PRAGMA journal_mode').get().journal_mode || null;
    summary.database.walAutocheckpoint = Number(db.prepare('PRAGMA wal_autocheckpoint').get().wal_autocheckpoint || 0);
    summary.database.pageCount = Number(db.prepare('PRAGMA page_count').get().page_count || 0);
    summary.database.pageSize = Number(db.prepare('PRAGMA page_size').get().page_size || 0);
    summary.database.freelistCount = Number(db.prepare('PRAGMA freelist_count').get().freelist_count || 0);
    summary.database.threadCount = countTableRows(db, 'threads');
    summary.database.logCount = countTableRows(db, 'logs');
    summary.database.threadlessLogRows = Number(
      db.prepare('SELECT COUNT(*) AS c FROM logs WHERE thread_id IS NULL').get().c || 0
    );

    const nullThreadCutoff = Math.floor(now.getTime() / 1000) - Math.floor(toPositiveNumber(options.nullLogRetentionHours, 0) * 3600);
    summary.database.nullThreadLogRowsOlderThanRetention = Number(
      db.prepare('SELECT COUNT(*) AS c FROM logs WHERE thread_id IS NULL AND ts < ?').get(nullThreadCutoff).c || 0
    );

    const staleThreadQuery = db.prepare(
      `
        SELECT
          id,
          rollout_path,
          cwd,
          updated_at,
          archived,
          git_branch
        FROM threads
        ORDER BY updated_at DESC
      `
    );
    const threadRows = staleThreadQuery.all();
    summary.database.staleThreadCandidates = selectStaleThreadCandidates(threadRows, {
      now,
      minThreadAgeHours: options.minThreadAgeHours
    });
    const rolloutMutationCandidates = makeRolloutMutationSet(threadRows, summary.database.staleThreadCandidates, {
      now,
      minThreadAgeHours: options.minThreadAgeHours,
      sessionsRoot
    });

    if (options.apply) {
      try {
        db.exec('BEGIN');
        if (summary.database.staleThreadCandidates.length > 0) {
          const archiveStatement = db.prepare(
            'UPDATE threads SET archived = 1, archived_at = ?, cwd = ? WHERE id = ? AND archived = 0'
          );
          const archivedAt = Math.floor(now.getTime() / 1000);
          for (const candidate of summary.database.staleThreadCandidates) {
            const normalizedCwd = normalizeCodexCwd(candidate.cwd, { repoRoot }) || repoRoot;
            const result = archiveStatement.run(archivedAt, normalizedCwd, candidate.id);
            summary.applied.archivedThreadCount += Number(result.changes || 0);
            if (Number(result.changes || 0) > 0) {
              summary.applied.normalizedThreadCwdCount += 1;
            }
          }
        }

        const normalizeArchivedThreadStatement = db.prepare(
          'UPDATE threads SET cwd = ? WHERE id = ? AND cwd != ?'
        );
        for (const candidate of rolloutMutationCandidates) {
          const normalizedCwd = normalizeCodexCwd(candidate.cwd, { repoRoot }) || repoRoot;
          const result = normalizeArchivedThreadStatement.run(normalizedCwd, candidate.id, normalizedCwd);
          summary.applied.normalizedThreadCwdCount += Number(result.changes || 0);
        }

        const deleteNullLogs = db.prepare('DELETE FROM logs WHERE thread_id IS NULL AND ts < ?');
        const deletionResult = deleteNullLogs.run(nullThreadCutoff);
        summary.applied.deletedNullLogCount = Number(deletionResult.changes || 0);
        db.exec('COMMIT');
      } catch (error) {
        try {
          db.exec('ROLLBACK');
        } catch {
          // Ignore rollback failures and surface the original mutation error.
        }
        summary.applied.error = error instanceof Error ? error.message : String(error);
      }

      if (!summary.applied.error) {
        const refreshRows = staleThreadQuery.all();
        const refreshedRolloutMutationCandidates = makeRolloutMutationSet(refreshRows, summary.database.staleThreadCandidates, {
          now,
          minThreadAgeHours: options.minThreadAgeHours,
          sessionsRoot
        });
        const updateRolloutPathStatement = db.prepare('UPDATE threads SET rollout_path = ?, cwd = ? WHERE id = ?');
        for (const candidate of refreshedRolloutMutationCandidates) {
          const normalizedCwd = normalizeCodexCwd(candidate.cwd, { repoRoot }) || repoRoot;
          try {
            const relocation = await relocateRolloutFile(candidate.rollout_path, sessionsRoot, archiveRoot);
            const rewrite = await rewriteRolloutCwds(relocation.targetPath, normalizedCwd);
            updateRolloutPathStatement.run(relocation.targetPath, normalizedCwd, candidate.id);
            summary.applied.relocatedRolloutCount += relocation.relocated ? 1 : 0;
            summary.applied.relocatedRolloutBytes += relocation.bytesMoved;
            summary.applied.rewrittenRolloutCount += rewrite.rewritten ? 1 : 0;
          } catch (error) {
            summary.applied.error = error instanceof Error ? error.message : String(error);
            break;
          }
        }
      }

      summary.applied.walCheckpoint = checkpointWal(db);
      summary.database.freelistCount = Number(db.prepare('PRAGMA freelist_count').get().freelist_count || 0);
      summary.database.logCount = countTableRows(db, 'logs');
      summary.database.threadlessLogRows = Number(
        db.prepare('SELECT COUNT(*) AS c FROM logs WHERE thread_id IS NULL').get().c || 0
      );
      summary.database.nullThreadLogRowsOlderThanRetention = Number(
        db.prepare('SELECT COUNT(*) AS c FROM logs WHERE thread_id IS NULL AND ts < ?').get(nullThreadCutoff).c || 0
      );
      summary.database.staleThreadCandidates = selectStaleThreadCandidates(staleThreadQuery.all(), {
        now,
        minThreadAgeHours: options.minThreadAgeHours
      });
      summary.sessions = await collectSessionSummary(sessionsRoot);
      summary.archiveSessions = await collectSessionSummary(archiveRoot);
    }
  } finally {
    db.close();
  }

  summary.status = deriveStatus(summary, options);
  return summary;
}

export async function writeCodexStateHygieneReport(reportPath, payload) {
  await mkdir(path.dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && import.meta.url === pathToFileURL(invokedPath).href) {
  const options = parseArgs();
  const payload = await runCodexStateHygiene(options);
  await writeCodexStateHygieneReport(options.report, payload);
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
  if (payload.applied.error) {
    process.exitCode = 1;
  }
}

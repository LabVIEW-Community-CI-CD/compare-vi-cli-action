#!/usr/bin/env node

import { ArgumentParser } from 'argparse';
import chokidar from 'chokidar';
import fs from 'fs';
import fsp from 'fs/promises';
import path from 'path';
import process from 'process';

const parser = new ArgumentParser({
  description: 'Stream Pester dispatcher output and summary updates.',
});

parser.add_argument('--results', {
  help: 'Root directory containing Pester results',
  default: 'tests/results',
});
parser.add_argument('--log', {
  help: 'Relative log file path under results',
  default: 'pester-dispatcher.log',
});
parser.add_argument('--summary', {
  help: 'Relative summary JSON file under results',
  default: 'pester-summary.json',
});
parser.add_argument('--tail', {
  help: 'Initial tail line count',
  type: 'int',
  default: 40,
});
parser.add_argument('--warn-seconds', {
  help: 'Idle seconds before warning',
  type: 'int',
  default: 90,
});
parser.add_argument('--hang-seconds', {
  help: 'Idle seconds before hang suspicion',
  type: 'int',
  default: 180,
});
parser.add_argument('--poll-ms', {
  help: 'Periodic poll to catch missed writes',
  type: 'int',
  default: 10000,
});
parser.add_argument('--exit-on-hang', {
  help: 'Exit with non-zero code when hang is suspected',
  action: 'store_true',
  default: false,
});
parser.add_argument('--no-progress-seconds', {
  help: 'Seconds without progress before warning/failure (0 to disable)',
  type: 'int',
  default: 0,
});
parser.add_argument('--progress-regex', {
  help: 'Regex that identifies progress log lines',
  default: '^(?:\\s*\\[[-+\\*]\\]|\\s*It\\s)'
});
parser.add_argument('--exit-on-no-progress', {
  help: 'Exit with non-zero code when no-progress threshold is exceeded',
  action: 'store_true',
  default: false,
});
parser.add_argument('--status-file', {
  help: 'Optional JSON status file to update on each poll',
  default: '',
});
parser.add_argument('--heartbeat-file', {
  help: 'Optional JSON heartbeat file for external monitors',
  default: '',
});
parser.add_argument('--events-file', {
  help: 'Optional NDJSON runtime events file for downstream consumers',
  default: '',
});
parser.add_argument('--quiet', {
  help: 'Suppress informational messages',
  action: 'store_true',
  default: false,
});

const args = parser.parse_args();

const resultsDir = path.resolve(args.results);
const logPath = path.resolve(resultsDir, args.log);
const summaryPath = path.resolve(resultsDir, args.summary);
const tailLines = Math.max(0, args.tail);
const quiet = Boolean(args.quiet);
const warnSeconds = Math.max(1, Number(args['warn_seconds'] ?? args.warn_seconds ?? args['warn-seconds']));
const hangSeconds = Math.max(warnSeconds + 1, Number(args['hang_seconds'] ?? args.hang_seconds ?? args['hang-seconds']));
const pollMs = Math.max(250, Number(args['poll_ms'] ?? args.poll_ms ?? args['poll-ms']));
const exitOnHang = Boolean(args['exit_on_hang'] ?? args.exit_on_hang ?? args['exit-on-hang']);
const noProgressSecondsRaw = Number(args['no_progress_seconds'] ?? args.no_progress_seconds ?? args['no-progress-seconds']);
const noProgressSeconds = Number.isFinite(noProgressSecondsRaw) ? Math.max(0, noProgressSecondsRaw) : 0;
const progressPattern = args['progress_regex'] ?? args.progress_regex ?? args['progress-regex'] ?? '^(?:\s*\[[-+\*]\]|\s*It\s)';
let progressRegex;
try {
  progressRegex = new RegExp(progressPattern, 'i');
} catch (err) {
  throw new Error(`Invalid progress regex '${progressPattern}': ${err.message ?? err}`);
}
const exitOnNoProgress = Boolean(args['exit_on_no_progress'] ?? args.exit_on_no_progress ?? args['exit-on-no-progress']);
const noProgressWarnSeconds = noProgressSeconds > 0 ? Math.max(1, Math.min(noProgressSeconds, Math.floor(noProgressSeconds / 2) || 1)) : 0;
const statusFileRaw = args['status_file'] ?? args.status_file ?? args['status-file'] ?? '';
const statusFile = statusFileRaw ? path.resolve(statusFileRaw) : '';
const statusEnabled = Boolean(statusFile);
const heartbeatFileRaw = args['heartbeat_file'] ?? args.heartbeat_file ?? args['heartbeat-file'] ?? '';
const heartbeatFile = heartbeatFileRaw ? path.resolve(heartbeatFileRaw) : '';
const heartbeatEnabled = Boolean(heartbeatFile);
const eventsFileRaw = args['events_file'] ?? args.events_file ?? args['events-file'] ?? '';
const eventsFile = eventsFileRaw ? path.resolve(eventsFileRaw) : path.resolve(resultsDir, 'pester-watcher-events.ndjson');
const eventsEnabled = Boolean(eventsFile);
const startedAt = new Date();

let logPosition = 0;
let logProcessing = Promise.resolve();
let summaryTimer = null;
let lastActivityAt = Date.now();
let lastStatsSize = 0;
let lastStatsMtimeMs = 0;
let hangReported = false;
let shuttingDown = false;
let lastProgressAt = Date.now();
let lastProgressBytes = 0;
let busyReported = false;
let lastSummaryAt = null;
let lastHangWatchAt = null;
let lastHangSuspectAt = null;
let lastBusyWatchAt = null;
let lastBusySuspectAt = null;
let runtimeEventCount = 0;
let lastRuntimeEventAt = null;
let lastRuntimeEventPhase = null;
let lastRuntimeEventLevel = null;

function getRuntimeEventMetadata() {
  return {
    schema: 'comparevi/runtime-event/v1',
    source: 'pester-artifact-watcher',
    path: eventsFile,
    count: runtimeEventCount,
    lastEventAt: lastRuntimeEventAt,
    lastPhase: lastRuntimeEventPhase,
    lastLevel: lastRuntimeEventLevel,
  };
}

function appendRuntimeEvent(level, phase, message, data = undefined) {
  if (!eventsEnabled) {
    return;
  }

  try {
    fs.mkdirSync(path.dirname(eventsFile), { recursive: true });
    const payload = {
      schema: 'comparevi/runtime-event/v1',
      tsUtc: new Date().toISOString(),
      source: 'pester-artifact-watcher',
      phase,
      level,
      message,
      data: data && Object.keys(data).length > 0 ? data : undefined,
    };
    fs.appendFileSync(eventsFile, `${JSON.stringify(payload)}\n`, 'utf8');
    runtimeEventCount += 1;
    lastRuntimeEventAt = payload.tsUtc;
    lastRuntimeEventPhase = phase;
    lastRuntimeEventLevel = level;
  } catch {
    // Best-effort only; watcher logging must continue even if event persistence fails.
  }
}

function info(message, phase = 'console', data = undefined) {
  appendRuntimeEvent('info', phase, message, data);
  if (!quiet) {
    console.log(`[info] ${message}`);
  }
}

function warn(message, phase = 'console', data = undefined) {
  appendRuntimeEvent('warn', phase, message, data);
  console.warn(`[warn] ${message}`);
}

async function ensureDirectory(target) {
  try {
    await fsp.mkdir(target, { recursive: true });
  } catch (err) {
    if (err && err.code !== 'EEXIST') {
      throw err;
    }
  }
}

async function writeHeartbeat(state, statusPayload, timestamp) {
  if (!heartbeatEnabled) { return; }
  const heartbeat = {
    schema: 'pester-watcher/heartbeat-v1',
    pid: process.pid,
    startedAt: startedAt.toISOString(),
    timestamp,
    state,
    statusFile: statusEnabled ? statusFile : null,
    resultsDir,
    metrics: statusPayload?.metrics ?? {
      lastActivityAt: new Date(lastActivityAt).toISOString(),
      lastProgressAt: new Date(lastProgressAt).toISOString(),
      lastSummaryAt: lastSummaryAt ? new Date(lastSummaryAt).toISOString() : null,
    },
    events: getRuntimeEventMetadata(),
  };
  try {
    await fsp.mkdir(path.dirname(heartbeatFile), { recursive: true });
    await fsp.writeFile(heartbeatFile, JSON.stringify(heartbeat, null, 2), 'utf8');
  } catch (err) {
    warn(`[heartbeat] Failed to write heartbeat file: ${err.message ?? err}`, 'heartbeat-write-error');
  }
}

async function writeStatus(state) {
  const timestamp = new Date().toISOString();
  const payload = {
    schema: 'pester-watcher/status-v2',
    pid: process.pid,
    startedAt: startedAt.toISOString(),
    timestamp,
    state,
    resultsDir,
    logPath,
    summaryPath,
    thresholds: {
      warnSeconds,
      hangSeconds,
      noProgressSeconds,
      pollMs,
    },
    metrics: {
      lastActivityAt: new Date(lastActivityAt).toISOString(),
      lastProgressAt: new Date(lastProgressAt).toISOString(),
      lastSummaryAt: lastSummaryAt ? new Date(lastSummaryAt).toISOString() : null,
      lastHangWatchAt: lastHangWatchAt ? new Date(lastHangWatchAt).toISOString() : null,
      lastHangSuspectAt: lastHangSuspectAt ? new Date(lastHangSuspectAt).toISOString() : null,
      lastBusyWatchAt: lastBusyWatchAt ? new Date(lastBusyWatchAt).toISOString() : null,
      lastBusySuspectAt: lastBusySuspectAt ? new Date(lastBusySuspectAt).toISOString() : null,
      liveBytes: lastStatsSize,
      consumedBytes: logPosition,
      bytesSinceProgress: Math.max(0, logPosition - lastProgressBytes),
    },
    progressRegex: progressPattern,
    events: getRuntimeEventMetadata(),
  };
  if (statusEnabled) {
    try {
      await fsp.mkdir(path.dirname(statusFile), { recursive: true });
      await fsp.writeFile(statusFile, JSON.stringify(payload, null, 2), 'utf8');
    } catch (err) {
      warn(`[status] Failed to write status file: ${err.message ?? err}`, 'status-write-error');
    }
  }
  await writeHeartbeat(state, payload, timestamp);
}

async function readFileTail(filePath, lines) {
  try {
    const raw = await fsp.readFile(filePath, 'utf8');
    const allLines = raw.split(/\r?\n/).filter(Boolean);
    const start = lines > 0 ? Math.max(0, allLines.length - lines) : allLines.length;
    const tail = allLines.slice(start);
    let progressDetected = false;
    for (const line of tail) {
      if (line && progressRegex.test(line)) {
        progressDetected = true;
      }
      console.log(line);
    }
    if (tail.length > 0) {
      appendRuntimeEvent('info', 'log-tail', `tail lines=${tail.length}`, {
        lineCount: tail.length,
        progressDetected,
      });
    }
    const stats = await fsp.stat(filePath);
    logPosition = stats.size;
    lastStatsSize = stats.size;
    lastStatsMtimeMs = stats.mtimeMs;
    lastActivityAt = Date.now();
    hangReported = false;
    if (progressDetected) {
      lastProgressAt = Date.now();
      lastProgressBytes = stats.size;
      busyReported = false;
    } else if (lastProgressBytes === 0) {
      lastProgressBytes = stats.size;
    }
  } catch (err) {
    if (err.code === 'ENOENT') {
      logPosition = 0;
    } else {
      warn(`[watch] Failed to read tail for ${filePath}: ${err.message}`, 'log-tail-error');
    }
  }
}

async function readLogDelta(filePath) {
  try {
    const fh = await fsp.open(filePath, 'r');
    try {
      const stats = await fh.stat();
      if (stats.size < logPosition) {
        logPosition = 0;
      }
      const length = stats.size - logPosition;
      if (length <= 0) {
        // no new bytes; update stats baselines
        lastStatsSize = stats.size;
        lastStatsMtimeMs = stats.mtimeMs;
        return;
      }
      const buffer = Buffer.alloc(length);
      await fh.read(buffer, 0, length, logPosition);
      logPosition = stats.size;
      lastStatsSize = stats.size;
      lastStatsMtimeMs = stats.mtimeMs;
      const text = buffer.toString('utf8');
      let progressDetected = false;
      let lineCount = 0;
      for (const line of text.split(/\r?\n/)) {
        if (line.trim().length > 0) {
          lineCount += 1;
          if (progressRegex.test(line)) {
            progressDetected = true;
          }
          console.log(`[log] ${line}`);
        }
      }
      if (lineCount > 0) {
        appendRuntimeEvent('info', 'log-delta', `log lines=${lineCount}`, {
          lineCount,
          progressDetected,
          bytes: length,
        });
      }
      // Count any appended bytes as activity even if lines were blank/partial
      lastActivityAt = Date.now();
      if (progressDetected) {
        lastProgressAt = Date.now();
        lastProgressBytes = stats.size;
        busyReported = false;
      } else if (lastProgressBytes === 0) {
        lastProgressBytes = stats.size;
      }
      hangReported = false;
    } finally {
      await fh.close();
    }
  } catch (err) {
    if (err.code === 'ENOENT') {
      warn('[watch] Log file missing; waiting for recreation.', 'log-missing');
      logPosition = 0;
    } else {
      warn(`[watch] Failed to read log delta: ${err.message}`, 'log-delta-error');
    }
  }
}

function enqueueLogRead(fn) {
  logProcessing = logProcessing.then(fn, fn);
}

async function emitSummary(filePath) {
  try {
    const content = await fsp.readFile(filePath, 'utf8');
    if (!content.trim()) {
      return;
    }
    const data = JSON.parse(content);
    const result = data.result ?? data.Result ?? null;
    const totals = data.totals ?? data.Totals ?? {};
    const tests = totals.tests ?? totals.Tests ?? null;
    const passed = totals.passed ?? totals.Passed ?? null;
    const failed = totals.failed ?? totals.Failed ?? null;
    const skipped = totals.skipped ?? totals.Skipped ?? null;
    const duration = data.durationSeconds ?? data.DurationSeconds ?? data.duration ?? null;
    const parts = ['[summary]'];
    if (result !== null && result !== undefined) {
      parts.push(`Result=${result}`);
    }
    if (tests !== null && tests !== undefined) {
      parts.push(`Tests=${tests}`);
    }
    if (passed !== null && passed !== undefined) {
      parts.push(`Passed=${passed}`);
    }
    if (failed !== null && failed !== undefined) {
      parts.push(`Failed=${failed}`);
    }
    if (skipped !== null && skipped !== undefined) {
      parts.push(`Skipped=${skipped}`);
    }
    if (duration !== null && duration !== undefined) {
      parts.push(`Duration=${duration}`);
    }
    console.log(parts.join(' '));
    appendRuntimeEvent('info', 'summary-update', 'summary updated', {
      result: result ?? undefined,
      tests: tests ?? undefined,
      passed: passed ?? undefined,
      failed: failed ?? undefined,
      skipped: skipped ?? undefined,
      duration: duration ?? undefined,
    });
    lastSummaryAt = Date.now();
    lastProgressAt = Date.now();
    lastProgressBytes = logPosition;
    busyReported = false;
    hangReported = false;
  } catch (err) {
    if (err.code === 'ENOENT') {
      return;
    }
    warn(`[summary] Failed to parse summary: ${err.message}`, 'summary-parse-error');
  }
}

async function watch() {
  await ensureDirectory(path.dirname(logPath));
  await ensureDirectory(path.dirname(summaryPath));

  info(`[watch] Results directory: ${resultsDir}`, 'watch-start', { resultsDir });
  info(`[watch] Log: ${logPath}`, 'watch-start', { logPath });
  info(`[watch] Summary: ${summaryPath}`, 'watch-start', { summaryPath });
  info(`[watch] Events: ${eventsFile}`, 'watch-start', { eventsFile });

  if (fs.existsSync(logPath)) {
    info(`[watch] Initial tail (${tailLines} lines)`, 'tail-init', { tailLines });
    await readFileTail(logPath, tailLines);
  } else {
    info('[watch] Waiting for log file to appear...', 'watch-start');
  }

  const watcherOptions = {
    persistent: true,
    ignoreInitial: false,
    awaitWriteFinish: {
      stabilityThreshold: 150,
      pollInterval: 100,
    },
  };

  const logWatcher = chokidar.watch(logPath, watcherOptions);

  logWatcher
    .on('add', () => {
      info('[watch] Log file created.', 'log-file-created');
      enqueueLogRead(async () => {
        await readFileTail(logPath, tailLines);
      });
    })
    .on('change', () => {
      enqueueLogRead(async () => {
        await readLogDelta(logPath);
      });
    })
    .on('unlink', () => {
      warn('[watch] Log file deleted; resetting position.', 'log-file-deleted');
      logPosition = 0;
      lastStatsSize = 0;
      lastStatsMtimeMs = 0;
      lastProgressBytes = 0;
      lastProgressAt = Date.now();
      busyReported = false;
    })
    .on('error', (error) => {
      warn(`[watch] Log watcher error: ${error.message ?? error}`, 'log-watcher-error');
    });

  const summaryWatcher = chokidar.watch(summaryPath, watcherOptions);

  summaryWatcher
    .on('add', () => {
      info('[watch] Summary file created.', 'summary-file-created');
      emitSummary(summaryPath);
      lastActivityAt = Date.now();
      lastProgressAt = Date.now();
      lastProgressBytes = logPosition;
      busyReported = false;
    })
    .on('change', () => {
      if (summaryTimer) {
        clearTimeout(summaryTimer);
      }
      summaryTimer = setTimeout(() => {
        emitSummary(summaryPath);
        lastActivityAt = Date.now();
        lastProgressAt = Date.now();
        lastProgressBytes = logPosition;
        busyReported = false;
      }, 150);
    })
    .on('unlink', () => {
      info('[watch] Summary file removed.', 'summary-file-removed');
      if (summaryTimer) {
        clearTimeout(summaryTimer);
        summaryTimer = null;
      }
    })
    .on('error', (error) => {
      warn(`[watch] Summary watcher error: ${error.message ?? error}`, 'summary-watcher-error');
    });

  let pollTimer;

  async function runPoll() {
    try {
      const exists = fs.existsSync(logPath);
      if (exists) {
        const stats = await fsp.stat(logPath);
        if (stats.size > logPosition) {
          enqueueLogRead(async () => {
            await readLogDelta(logPath);
          });
        } else {
          lastStatsSize = stats.size;
          lastStatsMtimeMs = stats.mtimeMs;
        }
      }
    } catch (e) {
      // ignore
    }

    let state = 'ok';
    const idleMs = Date.now() - lastActivityAt;
    const idleSec = Math.floor(idleMs / 1000);

    if (idleSec >= hangSeconds) {
        lastHangSuspectAt = Date.now();
        if (!hangReported) {
        warn(`[hang-suspect] idle ~${idleSec}s (no new log bytes or summary). live-bytes=${lastStatsSize} consumed-bytes=${logPosition}`, 'hang-suspect', {
          idleSeconds: idleSec,
          liveBytes: lastStatsSize,
          consumedBytes: logPosition,
        });
        hangReported = true;
      }
      if (exitOnHang && !shuttingDown) {
        await shutdownWatcher('hang-suspect', 2);
        return;
      }
      state = 'hang-suspect';
    } else if (idleSec >= warnSeconds) {
      lastHangWatchAt = Date.now();
      info(`[hang-watch] idle ~${idleSec}s (monitoring). live-bytes=${lastStatsSize} consumed-bytes=${logPosition}`, 'hang-watch', {
        idleSeconds: idleSec,
        liveBytes: lastStatsSize,
        consumedBytes: logPosition,
      });
      state = 'hang-watch';
      hangReported = false;
    } else {
      hangReported = false;
    }

    if (noProgressSeconds > 0) {
      const nowTs = Date.now();
      const noProgMs = nowTs - lastProgressAt;
      const noProgSec = Math.floor(noProgMs / 1000);
      const bytesSinceProgress = Math.max(0, logPosition - lastProgressBytes);
      const bytesChanging = bytesSinceProgress > 0;

      if (noProgSec >= noProgressSeconds) {
        lastBusySuspectAt = nowTs;
        if (!busyReported) {
          warn(`[busy-suspect] no-progress ~${noProgSec}s (bytes-changing=${bytesChanging})`, 'busy-suspect', {
            noProgressSeconds: noProgSec,
            bytesChanging,
          });
          busyReported = true;
        }
        if (exitOnNoProgress && !shuttingDown) {
          await shutdownWatcher('busy-suspect', 3);
          return;
        }
        state = 'busy-suspect';
      } else if (noProgressWarnSeconds > 0 && noProgSec >= noProgressWarnSeconds) {
        lastBusyWatchAt = nowTs;
        info(`[busy-watch] no-progress ~${noProgSec}s (bytes-changing=${bytesChanging})`, 'busy-watch', {
          noProgressSeconds: noProgSec,
          bytesChanging,
        });
        if (state === 'ok') {
          state = 'busy-watch';
        }
        busyReported = false;
      } else if (noProgSec === 0) {
        busyReported = false;
      }
    }

    await writeStatus(state);
  }

  async function shutdownWatcher(finalState, exitCode) {
    if (shuttingDown) { return; }
    shuttingDown = true;
    if (pollTimer) {
      clearInterval(pollTimer);
    }
    try {
      await Promise.all([logWatcher.close(), summaryWatcher.close()]);
    } catch (err) {
      warn(`[watch] Error while closing watchers: ${err.message ?? err}`);
    }
    await writeStatus(finalState);
    if (typeof exitCode === 'number') {
      process.exit(exitCode);
    }
  }

  await writeStatus('ok');
  await runPoll();
  pollTimer = setInterval(() => {
    runPoll().catch((err) => {
      warn(`[watch] Poll error: ${err.message ?? err}`, 'poll-error');
    });
  }, pollMs);

  function shutdown(signal) {
    info(`[watch] Received ${signal}; shutting down watchers.`, 'watch-stop', { signal });
    shutdownWatcher('stopped', 0).catch((err) => {
      warn(`[watch] Shutdown error: ${err.message ?? err}`, 'watch-stop-error');
      process.exit(0);
    });
  }

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

watch().catch((error) => {
  warn(`[watch] Fatal error: ${error.message ?? error}`, 'watch-fatal');
  writeStatus('error').finally(() => process.exit(1));
});

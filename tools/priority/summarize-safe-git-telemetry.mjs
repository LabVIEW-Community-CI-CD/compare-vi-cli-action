#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const DEFAULT_INPUT_PATH = path.resolve(
  'tests',
  'results',
  '_agent',
  'reliability',
  'safe-git-events.jsonl'
);
const DEFAULT_OUTPUT_PATH = path.resolve(
  'tests',
  'results',
  '_agent',
  'reliability',
  'safe-git-trend-summary.json'
);

function printUsage() {
  console.log(`Usage:
  node tools/priority/summarize-safe-git-telemetry.mjs [options]

Options:
  --input <path>          JSONL run telemetry input path
  --output <path>         Summary JSON output path
  --window <n>            Number of most recent runs to analyze (default: 50)
  --step-summary <path>   Optional GitHub step summary markdown path
  --help                  Show this message and exit
`);
}

export function parseArgs(argv = process.argv.slice(2)) {
  const parsed = {
    input: DEFAULT_INPUT_PATH,
    output: DEFAULT_OUTPUT_PATH,
    window: 50,
    stepSummary: process.env.GITHUB_STEP_SUMMARY || ''
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') {
      parsed.help = true;
      continue;
    }
    const next = argv[index + 1];
    if (!next) {
      throw new Error(`Missing value for ${arg}`);
    }

    if (arg === '--input') {
      parsed.input = path.resolve(next);
      index += 1;
      continue;
    }
    if (arg === '--output') {
      parsed.output = path.resolve(next);
      index += 1;
      continue;
    }
    if (arg === '--window') {
      const value = Number.parseInt(next, 10);
      if (!Number.isFinite(value) || value <= 0) {
        throw new Error(`Invalid --window value: ${next}`);
      }
      parsed.window = value;
      index += 1;
      continue;
    }
    if (arg === '--step-summary') {
      parsed.stepSummary = path.resolve(next);
      index += 1;
      continue;
    }

    throw new Error(`Unknown option: ${arg}`);
  }

  return parsed;
}

async function readJsonl(pathname) {
  try {
    const raw = await fs.readFile(pathname, 'utf8');
    const lines = raw
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const rows = [];
    for (const line of lines) {
      try {
        rows.push(JSON.parse(line));
      } catch {
        // skip malformed line
      }
    }
    return rows;
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return [];
    }
    throw error;
  }
}

function toFixedNumber(value) {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Number(value.toFixed(2));
}

export function computeTrendSummary(runs, windowSize = 50) {
  const ordered = [...runs]
    .filter((run) => run && typeof run === 'object')
    .sort((left, right) => {
      const l = Date.parse(left.startedAt || left.finishedAt || 0);
      const r = Date.parse(right.startedAt || right.finishedAt || 0);
      return l - r;
    });

  const window = ordered.slice(-windowSize);
  const failures = window.filter((run) => run.status !== 'success');
  const lockDetections = window.reduce((sum, run) => sum + Number(run?.counters?.lockDetections || 0), 0);
  const repairAttempts = window.reduce((sum, run) => sum + Number(run?.counters?.repairAttempts || 0), 0);
  const repairSuccesses = window.reduce((sum, run) => sum + Number(run?.counters?.repairSuccesses || 0), 0);
  const repairFailures = window.reduce((sum, run) => sum + Number(run?.counters?.repairFailures || 0), 0);
  const runtimeLockConflicts = window.reduce((sum, run) => sum + Number(run?.counters?.runtimeLockConflicts || 0), 0);
  const killedProcessCount = window.reduce((sum, run) => sum + Number(run?.counters?.killedProcessCount || 0), 0);

  const recoveryValues = window
    .map((run) => Number(run?.recoveryElapsedMs || 0))
    .filter((value) => Number.isFinite(value) && value > 0);
  const meanRecoveryMs =
    recoveryValues.length > 0
      ? toFixedNumber(recoveryValues.reduce((sum, value) => sum + value, 0) / recoveryValues.length)
      : 0;

  const midpoint = Math.floor(window.length / 2);
  const previousSegment = midpoint > 0 ? window.slice(0, midpoint) : [];
  const currentSegment = midpoint > 0 ? window.slice(midpoint) : window;

  function failureRatio(segment) {
    if (!segment.length) {
      return 0;
    }
    const segmentFailures = segment.filter((run) => run.status !== 'success').length;
    return segmentFailures / segment.length;
  }

  function meanRecovery(segment) {
    const values = segment
      .map((run) => Number(run?.recoveryElapsedMs || 0))
      .filter((value) => Number.isFinite(value) && value > 0);
    if (!values.length) {
      return 0;
    }
    return values.reduce((sum, value) => sum + value, 0) / values.length;
  }

  const previousFailureRatio = failureRatio(previousSegment);
  const currentFailureRatio = failureRatio(currentSegment);
  const previousMeanRecovery = meanRecovery(previousSegment);
  const currentMeanRecovery = meanRecovery(currentSegment);

  return {
    schema: 'priority/safe-git-reliability-trend@v1',
    generatedAt: new Date().toISOString(),
    windowSize,
    sampleCount: window.length,
    metrics: {
      totalRuns: window.length,
      successfulRuns: window.length - failures.length,
      failedRuns: failures.length,
      failureRatio: toFixedNumber(currentFailureRatio),
      lockDetections,
      repairAttempts,
      repairSuccesses,
      repairFailures,
      runtimeLockConflicts,
      killedProcessCount,
      meanRecoveryMs
    },
    trend: {
      previousFailureRatio: toFixedNumber(previousFailureRatio),
      currentFailureRatio: toFixedNumber(currentFailureRatio),
      failureRatioDelta: toFixedNumber(currentFailureRatio - previousFailureRatio),
      previousMeanRecoveryMs: toFixedNumber(previousMeanRecovery),
      currentMeanRecoveryMs: toFixedNumber(currentMeanRecovery),
      meanRecoveryDeltaMs: toFixedNumber(currentMeanRecovery - previousMeanRecovery)
    }
  };
}

async function writeSummary(pathname, summary) {
  await fs.mkdir(path.dirname(pathname), { recursive: true });
  await fs.writeFile(pathname, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
}

async function appendStepSummary(pathname, summary) {
  if (!pathname) {
    return;
  }
  const lines = [
    '### Safe Git Reliability',
    '',
    `- Runs analyzed: ${summary.metrics.totalRuns}`,
    `- Failure ratio: ${summary.metrics.failureRatio}`,
    `- Lock detections: ${summary.metrics.lockDetections}`,
    `- Repair attempts: ${summary.metrics.repairAttempts}`,
    `- Repair successes: ${summary.metrics.repairSuccesses}`,
    `- Repair failures: ${summary.metrics.repairFailures}`,
    `- Mean recovery (ms): ${summary.metrics.meanRecoveryMs}`,
    `- Failure ratio delta: ${summary.trend.failureRatioDelta}`,
    `- Mean recovery delta (ms): ${summary.trend.meanRecoveryDeltaMs}`,
    ''
  ];
  await fs.appendFile(pathname, `${lines.join('\n')}\n`, 'utf8');
}

export async function runCli(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const runs = await readJsonl(args.input);
  const summary = computeTrendSummary(runs, args.window);
  await writeSummary(args.output, summary);
  await appendStepSummary(args.stepSummary, summary);

  console.log(
    `[safe-git-trend] summary: ${args.output} (runs=${summary.metrics.totalRuns}, failureRatio=${summary.metrics.failureRatio})`
  );

  return 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : '';
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await runCli();
    process.exit(exitCode);
  } catch (error) {
    console.error(`[safe-git-trend] ${error?.message || error}`);
    process.exit(1);
  }
}

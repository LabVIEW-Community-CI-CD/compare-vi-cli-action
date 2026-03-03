#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', shell: false, ...opts });
}

function ensureCommand(result, cmd) {
  if (result?.error?.code === 'ENOENT') {
    const err = new Error(`Command not found: ${cmd}`);
    err.code = 'ENOENT';
    throw err;
  }
  return result;
}

function trimText(value) {
  return String(value ?? '').trim();
}

function makeErrorMessage(args, result) {
  const details = trimText(result?.stderr) || trimText(result?.stdout) || 'unknown error';
  return `git ${args.join(' ')} failed: ${details}`;
}

function runGit(args, runner = sh) {
  const result = ensureCommand(runner('git', args), 'git');
  if (result.status !== 0) {
    const err = new Error(makeErrorMessage(args, result));
    err.status = result.status;
    err.stderr = result.stderr;
    err.stdout = result.stdout;
    err.args = args;
    throw err;
  }
  return result.stdout || '';
}

export function parseRevListCounts(stdout) {
  const text = trimText(stdout);
  const parts = text.split(/\s+/).filter(Boolean);
  if (parts.length < 2) {
    throw new Error(`Invalid rev-list count output: ${text || '(empty)'}`);
  }

  const baseOnly = Number(parts[0]);
  const headOnly = Number(parts[1]);
  if (!Number.isInteger(baseOnly) || !Number.isInteger(headOnly)) {
    throw new Error(`Invalid rev-list count output: ${text || '(empty)'}`);
  }

  return { baseOnly, headOnly };
}

export function parseFileList(stdout) {
  return String(stdout || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function toPositiveInt(value, fallback) {
  if (value == null || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Invalid non-negative integer: ${value}`);
  }
  return parsed;
}

export function parseCliArgs(argv = process.argv.slice(2)) {
  const args = Array.from(argv || []);
  const options = {
    baseRef: 'upstream/develop',
    headRef: 'origin/develop',
    sampleLimit: 20,
    outputPath: null,
    githubOutputPath: null,
    stepSummaryPath: null,
    strict: false
  };

  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === '--base-ref') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --base-ref');
      options.baseRef = value;
      continue;
    }
    if (token === '--head-ref') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --head-ref');
      options.headRef = value;
      continue;
    }
    if (token === '--sample-limit') {
      const value = args[++i];
      if (value == null) throw new Error('Missing value for --sample-limit');
      options.sampleLimit = toPositiveInt(value, 20);
      continue;
    }
    if (token === '--output-path') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --output-path');
      options.outputPath = value;
      continue;
    }
    if (token === '--github-output') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --github-output');
      options.githubOutputPath = value;
      continue;
    }
    if (token === '--step-summary') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --step-summary');
      options.stepSummaryPath = value;
      continue;
    }
    if (token === '--strict') {
      options.strict = true;
      continue;
    }
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    throw new Error(`Unknown argument: ${token}`);
  }

  return options;
}

export function collectParity(options = {}, runner = sh) {
  const baseRef = options.baseRef || 'upstream/develop';
  const headRef = options.headRef || 'origin/develop';
  const sampleLimit = toPositiveInt(options.sampleLimit, 20);
  const strict = Boolean(options.strict);
  const now = new Date().toISOString();

  try {
    const countsText = runGit(['rev-list', '--left-right', '--count', `${baseRef}...${headRef}`], runner);
    const counts = parseRevListCounts(countsText);
    const filesText = runGit(['diff', '--name-only', baseRef, headRef], runner);
    const files = parseFileList(filesText);
    const sample = sampleLimit > 0 ? files.slice(0, sampleLimit) : [];

    return {
      schema: 'origin-upstream-parity@v1',
      status: 'ok',
      generatedAt: now,
      baseRef,
      headRef,
      tipDiff: {
        fileCount: files.length,
        sampleLimit,
        sample
      },
      commitDivergence: {
        baseOnly: counts.baseOnly,
        headOnly: counts.headOnly
      }
    };
  } catch (err) {
    if (strict) throw err;
    return {
      schema: 'origin-upstream-parity@v1',
      status: 'unavailable',
      generatedAt: now,
      baseRef,
      headRef,
      reason: err.message
    };
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2) + '\n', 'utf8');
}

function appendGitHubOutput(filePath, name, value) {
  if (!filePath) return;
  fs.appendFileSync(filePath, `${name}=${String(value ?? '')}\n`, 'utf8');
}

export function renderSummaryMarkdown(report) {
  if (!report || report.status !== 'ok') {
    return [
      '### Origin/Upstream Parity',
      '',
      '| Metric | Value |',
      '| --- | --- |',
      `| Status | unavailable |`,
      `| Base Ref | ${report?.baseRef || '(none)'} |`,
      `| Head Ref | ${report?.headRef || '(none)'} |`,
      `| Reason | ${report?.reason || 'unknown'} |`,
      ''
    ].join('\n');
  }

  const lines = [
    '### Origin/Upstream Parity',
    '',
    '| Metric | Value |',
    '| --- | --- |',
    `| Status | ok |`,
    `| Base Ref | ${report.baseRef} |`,
    `| Head Ref | ${report.headRef} |`,
    `| Tip Diff File Count | ${report.tipDiff.fileCount} |`,
    `| Commit Divergence (base-only/head-only) | ${report.commitDivergence.baseOnly}/${report.commitDivergence.headOnly} |`
  ];

  if (Array.isArray(report.tipDiff.sample) && report.tipDiff.sample.length > 0) {
    lines.push('', 'Tip-diff sample:');
    for (const file of report.tipDiff.sample) {
      lines.push(`- \`${file}\``);
    }
  }

  lines.push('');
  return lines.join('\n');
}

function printHelp() {
  console.log(`Usage:
  node tools/priority/report-origin-upstream-parity.mjs [options]

Options:
  --base-ref <ref>          Base ref (default: upstream/develop)
  --head-ref <ref>          Head ref (default: origin/develop)
  --sample-limit <n>        Max sample files in output (default: 20)
  --output-path <file>      JSON output file path
  --github-output <file>    Append GitHub output variables
  --step-summary <file>     Append markdown summary
  --strict                  Fail on git/ref errors instead of reporting unavailable
  --help, -h                Show help`);
}

async function main() {
  const options = parseCliArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    process.exitCode = 0;
    return;
  }

  const outputPath =
    options.outputPath ||
    path.join(process.cwd(), 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  const report = collectParity(options);
  writeJson(outputPath, report);

  appendGitHubOutput(options.githubOutputPath, 'parity_status', report.status);
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_tip_diff_count',
    report.status === 'ok' ? report.tipDiff.fileCount : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_base_only_commits',
    report.status === 'ok' ? report.commitDivergence.baseOnly : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_head_only_commits',
    report.status === 'ok' ? report.commitDivergence.headOnly : ''
  );
  appendGitHubOutput(options.githubOutputPath, 'parity_report_path', outputPath);

  if (options.stepSummaryPath) {
    const summary = renderSummaryMarkdown(report);
    fs.appendFileSync(options.stepSummaryPath, `${summary}\n`, 'utf8');
  }

  console.log(`[parity] status=${report.status} base=${report.baseRef} head=${report.headRef}`);
  if (report.status === 'ok') {
    console.log(
      `[parity] tipDiff=${report.tipDiff.fileCount} commits=${report.commitDivergence.baseOnly}/${report.commitDivergence.headOnly}`
    );
  } else {
    console.log(`[parity] reason=${report.reason}`);
  }
  console.log(`[parity] report=${outputPath}`);
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main().catch((err) => {
    console.error(`[parity] ${err.message}`);
    process.exitCode = 1;
  });
}


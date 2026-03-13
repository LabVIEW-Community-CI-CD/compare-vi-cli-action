#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_REVIEW_LOOP_RECEIPT_PATH = path.join('tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
export const DEFAULT_LOCAL_REVIEW_LOOP_COMMAND = ['node', 'tools/priority/docker-desktop-review-loop.mjs'];
export const DEFAULT_REVIEW_LOOP_MAX_BUFFER_BYTES = 64 * 1024 * 1024;

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function coerceNonNegativeInteger(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return 0;
  }
  const parsed = Number(normalized);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : 0;
}

async function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }
    if (error instanceof SyntaxError || error?.name === 'SyntaxError') {
      return {
        __parseError: error.message
      };
    }
    throw error;
  }
}

function normalizeCommandResult(result = {}) {
  const stderr = [
    normalizeText(result.stderr),
    normalizeText(result.error?.message),
    normalizeText(result.signal ? `Process terminated by signal ${result.signal}.` : '')
  ]
    .filter(Boolean)
    .join('\n');
  return {
    status: Number.isInteger(result.status) ? result.status : 1,
    stdout: normalizeText(result.stdout),
    stderr
  };
}

export function normalizeRequest(request = {}) {
  const singleViHistory =
    request.singleViHistory && typeof request.singleViHistory === 'object'
      ? request.singleViHistory
      : {};
  const targetPath = normalizeText(singleViHistory.targetPath);
  const branchRef = normalizeText(singleViHistory.branchRef);
  const singleViHistoryEnabled = singleViHistory.enabled === true && Boolean(targetPath);
  return {
    requested: request.requested === true,
    receiptPath: normalizeText(request.receiptPath) || DEFAULT_REVIEW_LOOP_RECEIPT_PATH,
    actionlint: request.actionlint !== false,
    markdownlint: request.markdownlint !== false,
    docs: request.docs !== false,
    workflow: request.workflow !== false,
    dotnetCliBuild: request.dotnetCliBuild !== false,
    requirementsVerification: request.requirementsVerification === true,
    niLinuxReviewSuite: request.niLinuxReviewSuite === true || singleViHistoryEnabled,
    singleViHistory: {
      enabled: singleViHistoryEnabled,
      targetPath: targetPath || '',
      branchRef: branchRef || '',
      baselineRef: normalizeText(singleViHistory.baselineRef),
      maxCommitCount: coerceNonNegativeInteger(singleViHistory.maxCommitCount)
    }
  };
}

export function buildLocalReviewLoopCliArgs({ repoRoot, request }) {
  const normalized = normalizeRequest(request);
  const args = ['--repo-root', repoRoot, '--receipt-path', normalized.receiptPath];
  if (!normalized.actionlint) {
    args.push('--skip-actionlint');
  }
  if (!normalized.markdownlint) {
    args.push('--skip-markdown');
  }
  if (!normalized.docs) {
    args.push('--skip-docs');
  }
  if (!normalized.workflow) {
    args.push('--skip-workflow');
  }
  if (!normalized.dotnetCliBuild) {
    args.push('--skip-dotnet-cli-build');
  }
  if (normalized.requirementsVerification) {
    args.push('--requirements-verification');
  }
  if (normalized.niLinuxReviewSuite) {
    args.push('--ni-linux-review-suite');
  }
  if (normalized.singleViHistory.enabled) {
    args.push('--history-target-path', normalized.singleViHistory.targetPath);
    if (normalized.singleViHistory.branchRef) {
      args.push('--history-branch-ref', normalized.singleViHistory.branchRef);
    }
    if (normalized.singleViHistory.baselineRef) {
      args.push('--history-baseline-ref', normalized.singleViHistory.baselineRef);
    }
    if (normalized.singleViHistory.maxCommitCount > 0) {
      args.push('--history-max-commit-count', String(normalized.singleViHistory.maxCommitCount));
    }
  }
  return args;
}

export function buildDockerDesktopReviewLoopPowerShellArgs(request = {}) {
  const normalized = normalizeRequest(request);
  const args = [
    '-NoLogo',
    '-NoProfile',
    '-File',
    path.join('tools', 'Run-NonLVChecksInDocker.ps1'),
    '-UseToolsImage',
    '-DockerParityReviewReceiptPath',
    normalized.receiptPath
  ];

  if (!normalized.actionlint) {
    args.push('-SkipActionlint');
  }
  if (!normalized.markdownlint) {
    args.push('-SkipMarkdown');
  }
  if (!normalized.docs) {
    args.push('-SkipDocs');
  }
  if (!normalized.workflow) {
    args.push('-SkipWorkflow');
  }
  if (!normalized.dotnetCliBuild) {
    args.push('-SkipDotnetCliBuild');
  }
  if (normalized.requirementsVerification) {
    args.push('-RequirementsVerification');
  }
  if (normalized.niLinuxReviewSuite) {
    args.push('-NILinuxReviewSuite');
  }
  if (normalized.singleViHistory.enabled) {
    args.push('-NILinuxReviewSuiteHistoryTargetPath', normalized.singleViHistory.targetPath);
    if (normalized.singleViHistory.branchRef) {
      args.push('-NILinuxReviewSuiteHistoryBranchRef', normalized.singleViHistory.branchRef);
    }
    if (normalized.singleViHistory.baselineRef) {
      args.push('-NILinuxReviewSuiteHistoryBaselineRef', normalized.singleViHistory.baselineRef);
    }
    if (normalized.singleViHistory.maxCommitCount > 0) {
      args.push('-NILinuxReviewSuiteHistoryMaxCommitCount', String(normalized.singleViHistory.maxCommitCount));
    }
  }

  return args;
}

function defaultRunCommand(command, args, { cwd, env }) {
  return normalizeCommandResult(
    spawnSync(command, args, {
      cwd,
      env,
      encoding: 'utf8',
      maxBuffer: DEFAULT_REVIEW_LOOP_MAX_BUFFER_BYTES,
      stdio: ['ignore', 'pipe', 'pipe']
    })
  );
}

export async function runDockerDesktopReviewLoop({
  repoRoot,
  request,
  runCommandFn = defaultRunCommand
}) {
  const normalized = normalizeRequest(request);
  const command = 'pwsh';
  const args = buildDockerDesktopReviewLoopPowerShellArgs(normalized);
  const commandLine = [command, ...args].join(' ');
  const receiptPath = path.resolve(repoRoot, normalized.receiptPath);

  if (normalized.requested !== true) {
    return {
      status: 'skipped',
      source: 'docker-desktop-review-loop',
      reason: 'Local Docker/Desktop review loop is not requested for this task packet.',
      commandLine,
      receiptPath,
      receipt: null
    };
  }

  await rm(receiptPath, { force: true }).catch((error) => {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
  });

  const result = normalizeCommandResult(await runCommandFn(command, args, {
    cwd: repoRoot,
    env: process.env
  }));
  const receipt = await readJsonIfPresent(receiptPath);
  if (receipt?.__parseError) {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: `Docker/Desktop review loop produced a corrupt receipt: ${receipt.__parseError}`,
      commandLine,
      receiptPath,
      receipt: null
    };
  }
  const overallStatus = normalizeText(receipt?.overall?.status).toLowerCase();
  const failedCheck = normalizeText(receipt?.overall?.failedCheck);
  const failureReason =
    normalizeText(receipt?.overall?.message) ||
    (failedCheck ? `Docker/Desktop review loop failed on ${failedCheck}.` : '') ||
    normalizeText(result.stderr) ||
    normalizeText(result.stdout) ||
    'Docker/Desktop review loop failed without a receipt.';

  if (result.status !== 0 || overallStatus !== 'passed') {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: failureReason,
      commandLine,
      receiptPath,
      receipt
    };
  }

  return {
    status: 'passed',
    source: 'docker-desktop-review-loop',
    reason: 'Docker/Desktop review loop passed.',
    commandLine,
    receiptPath,
    receipt
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/docker-desktop-review-loop.mjs [options]');
  console.log('');
  console.log('Run the local Docker/Desktop parity loop and emit a machine-readable result.');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>              Repository root (default: current working directory).');
  console.log(`  --receipt-path <path>           Review-loop receipt path (default: ${DEFAULT_REVIEW_LOOP_RECEIPT_PATH}).`);
  console.log('  --skip-actionlint               Skip actionlint in the Docker/Desktop review loop.');
  console.log('  --skip-markdown                 Skip markdownlint in the Docker/Desktop review loop.');
  console.log('  --skip-docs                     Skip docs link validation in the Docker/Desktop review loop.');
  console.log('  --skip-workflow                 Skip workflow drift/contract checks in the Docker/Desktop review loop.');
  console.log('  --skip-dotnet-cli-build         Skip the CompareVI .NET CLI build in the Docker/Desktop review loop.');
  console.log('  --requirements-verification     Include requirements verification.');
  console.log('  --ni-linux-review-suite         Include the NI Linux smoke + VI history review suite.');
  console.log('  --history-target-path <path>    Single-VI history target path.');
  console.log('  --history-branch-ref <ref>      Single-VI branch ref.');
  console.log('  --history-baseline-ref <ref>    Single-VI baseline ref.');
  console.log('  --history-max-commit-count <n>  Single-VI max commit scan depth.');
  console.log('  -h, --help                      Show help.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repoRoot: process.cwd(),
    request: {
      requested: true,
      receiptPath: DEFAULT_REVIEW_LOOP_RECEIPT_PATH,
      actionlint: true,
      markdownlint: true,
      docs: true,
      workflow: true,
      dotnetCliBuild: true,
      requirementsVerification: false,
      niLinuxReviewSuite: false,
      singleViHistory: {
        enabled: false,
        targetPath: '',
        branchRef: '',
        baselineRef: '',
        maxCommitCount: 0
      }
    }
  };
  const valueOptionHandlers = new Map([
    ['--repo-root', (value) => { options.repoRoot = value; }],
    ['--receipt-path', (value) => { options.request.receiptPath = value; }],
    ['--history-target-path', (value) => {
      options.request.singleViHistory.enabled = true;
      options.request.niLinuxReviewSuite = true;
      options.request.singleViHistory.targetPath = value;
    }],
    ['--history-branch-ref', (value) => { options.request.singleViHistory.branchRef = value; }],
    ['--history-baseline-ref', (value) => { options.request.singleViHistory.baselineRef = value; }],
    ['--history-max-commit-count', (value) => {
      options.request.singleViHistory.maxCommitCount = coerceNonNegativeInteger(value);
    }]
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (token === '--skip-actionlint') {
      options.request.actionlint = false;
      continue;
    }
    if (token === '--skip-markdown') {
      options.request.markdownlint = false;
      continue;
    }
    if (token === '--skip-docs') {
      options.request.docs = false;
      continue;
    }
    if (token === '--skip-workflow') {
      options.request.workflow = false;
      continue;
    }
    if (token === '--skip-dotnet-cli-build') {
      options.request.dotnetCliBuild = false;
      continue;
    }
    if (token === '--requirements-verification') {
      options.request.requirementsVerification = true;
      continue;
    }
    if (token === '--ni-linux-review-suite') {
      options.request.niLinuxReviewSuite = true;
      continue;
    }

    if (token.startsWith('-') && !valueOptionHandlers.has(token)) {
      throw new Error(`Unknown option: ${token}`);
    }

    const next = args[index + 1];
    if (!next || next.startsWith('-')) {
      throw new Error(`Missing value for ${token}.`);
    }
    index += 1;
    valueOptionHandlers.get(token)(next);
  }

  return options;
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  const result = await runDockerDesktopReviewLoop({
    repoRoot: path.resolve(options.repoRoot),
    request: options.request
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  return result.status === 'passed' ? 0 : 1;
}

export function isDirectExecution(argv = process.argv, metaUrl = import.meta.url) {
  const modulePath = path.resolve(fileURLToPath(metaUrl));
  const invokedPath = argv[1] ? path.resolve(argv[1]) : null;
  return Boolean(invokedPath && invokedPath === modulePath);
}

if (isDirectExecution(process.argv, import.meta.url)) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}

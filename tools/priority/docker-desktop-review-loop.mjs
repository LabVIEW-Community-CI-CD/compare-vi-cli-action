#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_REVIEW_LOOP_RECEIPT_PATH = path.join('tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
export const DEFAULT_LOCAL_REVIEW_LOOP_COMMAND = ['node', 'tools/priority/docker-desktop-review-loop.mjs'];
export const DEFAULT_REVIEW_LOOP_MAX_BUFFER_BYTES = 64 * 1024 * 1024;
export const DOCKER_PARITY_RESULTS_ROOT = path.join('tests', 'results', 'docker-tools-parity');

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

function runGitCommand(repoRoot, args) {
  const result = spawnSync('git', ['-C', repoRoot, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return {
    ok: result.status === 0,
    stdout: normalizeText(result.stdout),
    stderr: normalizeText(result.stderr)
  };
}

export function resolveRepoGitState(repoRoot) {
  const headShaResult = runGitCommand(repoRoot, ['rev-parse', 'HEAD']);
  if (!headShaResult.ok || !headShaResult.stdout) {
    return null;
  }
  const branchResult = runGitCommand(repoRoot, ['branch', '--show-current']);
  const upstreamDevelopMergeBaseResult = runGitCommand(repoRoot, ['merge-base', 'HEAD', 'upstream/develop']);
  const dirtyTrackedResult = runGitCommand(repoRoot, ['status', '--short', '--untracked-files=no']);
  return {
    headSha: headShaResult.stdout,
    branch: branchResult.ok ? branchResult.stdout || null : null,
    upstreamDevelopMergeBase: upstreamDevelopMergeBaseResult.ok ? upstreamDevelopMergeBaseResult.stdout || null : null,
    dirtyTracked: dirtyTrackedResult.ok ? dirtyTrackedResult.stdout.length > 0 : null
  };
}

function normalizeReceiptGitMetadata(receipt = {}) {
  const git = receipt && typeof receipt === 'object' && receipt.git && typeof receipt.git === 'object' ? receipt.git : {};
  const headSha = normalizeText(git.headSha);
  const branch = normalizeText(git.branch) || null;
  const upstreamDevelopMergeBase = normalizeText(git.upstreamDevelopMergeBase) || null;
  const dirtyTracked = typeof git.dirtyTracked === 'boolean' ? git.dirtyTracked : null;
  return {
    headSha,
    branch,
    upstreamDevelopMergeBase,
    dirtyTracked
  };
}

function assertRepoContainedReceiptPath(repoRoot, receiptPath) {
  const normalized = normalizeText(receiptPath);
  if (!normalized) {
    throw new Error('Receipt path must be a non-empty repo-relative path.');
  }
  if (path.isAbsolute(normalized)) {
    throw new Error(`Receipt path must stay under the repository root: ${normalized}`);
  }
  const resolved = path.resolve(repoRoot, normalized);
  const relativeToRepo = path.relative(repoRoot, resolved);
  if (!relativeToRepo || relativeToRepo.startsWith('..') || path.isAbsolute(relativeToRepo)) {
    throw new Error(`Receipt path escapes the repository root: ${normalized}`);
  }
  const parityRoot = path.resolve(repoRoot, DOCKER_PARITY_RESULTS_ROOT);
  const relativeToParityRoot = path.relative(parityRoot, resolved);
  if (!relativeToParityRoot || relativeToParityRoot.startsWith('..') || path.isAbsolute(relativeToParityRoot)) {
    throw new Error(`Receipt path must stay under ${DOCKER_PARITY_RESULTS_ROOT}: ${normalized}`);
  }
  return {
    normalized,
    resolved
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

export async function assessDockerDesktopReviewLoopReceipt({
  repoRoot,
  receiptPath,
  resolveRepoGitStateFn = resolveRepoGitState
}) {
  let resolvedReceiptPathInfo;
  try {
    resolvedReceiptPathInfo = assertRepoContainedReceiptPath(repoRoot, receiptPath);
  } catch (error) {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: normalizeText(error?.message) || 'Invalid Docker/Desktop review loop receipt path.',
      receiptPath,
      receipt: null,
      currentHeadSha: null,
      receiptHeadSha: null,
      receiptFreshForHead: false,
      reusable: false
    };
  }

  const resolvedReceiptPath = resolvedReceiptPathInfo.resolved;
  const currentGitState =
    typeof resolveRepoGitStateFn === 'function' ? normalizeReceiptGitMetadata({ git: resolveRepoGitStateFn(repoRoot) ?? {} }) : null;
  const receipt = await readJsonIfPresent(resolvedReceiptPath);
  if (!receipt) {
    return {
      status: 'missing',
      source: 'docker-desktop-review-loop',
      reason: 'Docker/Desktop review loop receipt does not exist yet.',
      receiptPath: resolvedReceiptPathInfo.normalized,
      receipt: null,
      currentHeadSha: currentGitState?.headSha || null,
      receiptHeadSha: null,
      receiptFreshForHead: null,
      reusable: false
    };
  }
  if (receipt.__parseError) {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: `Docker/Desktop review loop produced a corrupt receipt: ${receipt.__parseError}`,
      receiptPath: resolvedReceiptPathInfo.normalized,
      receipt: null,
      currentHeadSha: currentGitState?.headSha || null,
      receiptHeadSha: null,
      receiptFreshForHead: false,
      reusable: false
    };
  }

  const receiptGit = normalizeReceiptGitMetadata(receipt);
  if (!receiptGit.headSha) {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: 'Docker/Desktop review loop receipt is missing git.headSha metadata.',
      receiptPath: resolvedReceiptPathInfo.normalized,
      receipt,
      currentHeadSha: currentGitState?.headSha || null,
      receiptHeadSha: null,
      receiptFreshForHead: false,
      reusable: false
    };
  }
  const receiptFreshForHead = currentGitState?.headSha ? currentGitState.headSha === receiptGit.headSha : null;
  if (receiptFreshForHead === false) {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: `Docker/Desktop review loop receipt is stale for the current HEAD (${receiptGit.headSha} != ${currentGitState.headSha}).`,
      receiptPath: resolvedReceiptPathInfo.normalized,
      receipt,
      currentHeadSha: currentGitState.headSha,
      receiptHeadSha: receiptGit.headSha,
      receiptFreshForHead,
      reusable: false
    };
  }

  const overallStatus = normalizeText(receipt?.overall?.status).toLowerCase();
  const failedCheck = normalizeText(receipt?.overall?.failedCheck);
  const failureReason =
    normalizeText(receipt?.overall?.message) ||
    (failedCheck ? `Docker/Desktop review loop failed on ${failedCheck}.` : '') ||
    'Docker/Desktop review loop failed without a receipt.';
  if (overallStatus !== 'passed') {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: failureReason,
      receiptPath: resolvedReceiptPathInfo.normalized,
      receipt,
      currentHeadSha: currentGitState?.headSha || null,
      receiptHeadSha: receiptGit.headSha,
      receiptFreshForHead,
      reusable: false
    };
  }

  const reusable = currentGitState?.dirtyTracked === false && receiptGit.dirtyTracked === false;
  const reuseReason = reusable
    ? 'Docker/Desktop review loop receipt is current for this clean HEAD.'
    : currentGitState?.dirtyTracked === true || receiptGit.dirtyTracked === true
      ? 'Docker/Desktop review loop receipt is current, but tracked changes are present.'
      : 'Docker/Desktop review loop receipt is current, but tracked-clean state could not be verified.';
  return {
    status: 'passed',
    source: 'docker-desktop-review-loop',
    reason: reuseReason,
    receiptPath: resolvedReceiptPathInfo.normalized,
    receipt,
    currentHeadSha: currentGitState?.headSha || null,
    receiptHeadSha: receiptGit.headSha,
    receiptFreshForHead,
    reusable
  };
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
  runCommandFn = defaultRunCommand,
  resolveRepoGitStateFn = resolveRepoGitState
}) {
  const normalized = normalizeRequest(request);
  const command = 'pwsh';
  const args = buildDockerDesktopReviewLoopPowerShellArgs(normalized);
  const commandLine = [command, ...args].join(' ');
  let receiptPath;
  try {
    receiptPath = assertRepoContainedReceiptPath(repoRoot, normalized.receiptPath).resolved;
  } catch (error) {
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: normalizeText(error?.message) || 'Invalid Docker/Desktop review loop receipt path.',
      commandLine,
      receiptPath: normalized.receiptPath,
      receipt: null
    };
  }

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
  const assessment = await assessDockerDesktopReviewLoopReceipt({
    repoRoot,
    receiptPath: normalized.receiptPath,
    resolveRepoGitStateFn
  });

  if (result.status !== 0 || assessment.status !== 'passed') {
    const failureReason =
      result.status !== 0
        ? normalizeText(result.stderr) || normalizeText(result.stdout) || normalizeText(assessment.reason)
        : normalizeText(assessment.reason) || normalizeText(result.stderr) || normalizeText(result.stdout);
    return {
      status: 'failed',
      source: 'docker-desktop-review-loop',
      reason: failureReason || 'Docker/Desktop review loop failed without a receipt.',
      commandLine,
      receiptPath,
      currentHeadSha: assessment.currentHeadSha,
      receiptHeadSha: assessment.receiptHeadSha,
      receiptFreshForHead: assessment.receiptFreshForHead,
      receipt: assessment.receipt
    };
  }

  return {
    status: 'passed',
    source: 'docker-desktop-review-loop',
    reason: 'Docker/Desktop review loop passed.',
    commandLine,
    receiptPath,
    currentHeadSha: assessment.currentHeadSha,
    receiptHeadSha: assessment.receiptHeadSha,
    receiptFreshForHead: assessment.receiptFreshForHead,
    receipt: assessment.receipt
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
    if (!token.startsWith('-')) {
      throw new Error(`Unknown argument: ${token}`);
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

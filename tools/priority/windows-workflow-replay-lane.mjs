#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { DEFAULT_SCHEMA_VERSION, resolveRepoGitState } from './docker-workflow-replay-lane.mjs';

export const REPORT_SCHEMA = 'windows-workflow-replay-lane@v1';
export const DEFAULT_MODE = 'windows-ni-2026q1-host-preflight';
export const DEFAULT_IMAGE = 'nationalinstruments/labview:2026q1-windows';
export const DEFAULT_RESULTS_ROOT = path.join('tests', 'results', 'docker-tools-parity', 'workflow-replay');
export const DEFAULT_REPLAY_MAX_BUFFER_BYTES = 64 * 1024 * 1024;
export const DEFAULT_WINDOWS_LABVIEW_PATH = 'C:\\Program Files\\National Instruments\\LabVIEW 2026\\LabVIEW.exe';

export const MODE_CONFIG = Object.freeze({
  'windows-ni-2026q1-host-preflight': Object.freeze({
    kind: 'preflight-only',
    helperPath: path.join('tools', 'Test-WindowsNI2026q1HostPreflight.ps1'),
    preflightReportPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'windows-ni-2026q1-host-preflight',
      'windows-ni-2026q1-host-preflight.json',
    ),
  }),
  'vi-history-scenarios-windows': Object.freeze({
    kind: 'preflight-compare',
    helperPath: path.join('tools', 'Test-WindowsNI2026q1HostPreflight.ps1'),
    compareHelperPath: path.join('tools', 'Run-NIWindowsContainerCompare.ps1'),
    preflightReportPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'vi-history-scenarios-windows',
      'windows-ni-2026q1-host-preflight.json',
    ),
    reportPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'vi-history-scenarios-windows',
      'windows-compare-report.html',
    ),
    runtimeSnapshotPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'vi-history-scenarios-windows',
      'runtime-manager-compare-windows.json',
    ),
    artifactSummaryPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'vi-history-scenarios-windows',
      'windows-compare-artifact-summary.json',
    ),
    capturePath: path.join(
      DEFAULT_RESULTS_ROOT,
      'vi-history-scenarios-windows',
      'ni-windows-container-capture.json',
    ),
    stdoutPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'vi-history-scenarios-windows',
      'ni-windows-container-stdout.txt',
    ),
    stderrPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'vi-history-scenarios-windows',
      'ni-windows-container-stderr.txt',
    ),
    baseVi: path.join('fixtures', 'vi-stage', 'control-rename', 'Base.vi'),
    headVi: path.join('fixtures', 'vi-stage', 'control-rename', 'Head.vi'),
    labviewPath: DEFAULT_WINDOWS_LABVIEW_PATH,
    timeoutSeconds: 600,
    runtimeEngineReadyTimeoutSeconds: 180,
    runtimeEngineReadyPollSeconds: 5,
  }),
});

function printUsage() {
  console.log('Usage: node tools/priority/windows-workflow-replay-lane.mjs [options]');
  console.log('');
  console.log('Run the governed Windows NI host-preflight as a local workflow-grade replay lane.');
  console.log('');
  console.log('Options:');
  console.log(`  --mode <name>                 Replay mode (default: ${DEFAULT_MODE}).`);
  console.log('  --execution-surface <name>    desktop-local or github-hosted-windows (default: desktop-local).');
  console.log(`  --image <ref>                 Windows container image (default: ${DEFAULT_IMAGE}).`);
  console.log(`  --labview-path <path>         In-container LabVIEW.exe path for compare modes (default: ${DEFAULT_WINDOWS_LABVIEW_PATH}).`);
  console.log('  --allow-unavailable           Accept an unavailable receipt when the helper supports it.');
  console.log(`  --receipt-path <path>         Outer receipt path (default: ${defaultReceiptPath(DEFAULT_MODE)}).`);
  console.log('  --preflight-report <path>     Override the inner host-preflight report path.');
  console.log('  -h, --help                    Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function resolveRepoPath(repoRoot, candidatePath) {
  if (path.isAbsolute(candidatePath)) {
    return candidatePath;
  }
  return path.resolve(repoRoot, candidatePath);
}

function writeJsonFile(repoRoot, outputPath, payload) {
  const resolvedPath = resolveRepoPath(repoRoot, outputPath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function formatShellToken(value) {
  if (/^[A-Za-z0-9_./:=+\\-]+$/.test(value)) {
    return value;
  }
  return JSON.stringify(value);
}

function formatCommandForShell(command, args) {
  return [command, ...args].map((token) => formatShellToken(token)).join(' ');
}

function runProcess(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? process.cwd(),
    encoding: 'utf8',
    env: options.env ?? process.env,
    maxBuffer: options.maxBuffer ?? DEFAULT_REPLAY_MAX_BUFFER_BYTES,
  });
  return {
    status: typeof result.status === 'number' ? result.status : null,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function defaultReceiptPath(mode) {
  return path.join(DEFAULT_RESULTS_ROOT, `${mode}-receipt.json`);
}

export function getModePaths(mode, overrides = {}) {
  const config = MODE_CONFIG[mode];
  if (!config) {
    throw new Error(`Unsupported replay mode: ${mode}`);
  }
  return {
    preflightReportPath: normalizeText(overrides.preflightReportPath) ?? config.preflightReportPath,
    reportPath: normalizeText(overrides.reportPath) ?? config.reportPath ?? null,
    runtimeSnapshotPath: normalizeText(overrides.runtimeSnapshotPath) ?? config.runtimeSnapshotPath ?? null,
    artifactSummaryPath: normalizeText(overrides.artifactSummaryPath) ?? config.artifactSummaryPath ?? null,
    capturePath: normalizeText(overrides.capturePath) ?? config.capturePath ?? null,
    stdoutPath: normalizeText(overrides.stdoutPath) ?? config.stdoutPath ?? null,
    stderrPath: normalizeText(overrides.stderrPath) ?? config.stderrPath ?? null,
  };
}

function assertRelativePathWithinRoot(repoRoot, requestedPath, rootPath, label) {
  const normalized = normalizeText(requestedPath);
  if (!normalized) {
    throw new Error(`${label} must be a non-empty repo-relative path.`);
  }
  if (path.isAbsolute(normalized)) {
    throw new Error(`${label} must stay under the repository root: ${normalized}`);
  }
  const resolvedPath = path.resolve(repoRoot, normalized);
  const relativeToRepo = path.relative(repoRoot, resolvedPath);
  if (!relativeToRepo || relativeToRepo.startsWith('..') || path.isAbsolute(relativeToRepo)) {
    throw new Error(`${label} escapes the repository root: ${normalized}`);
  }
  const resolvedRoot = path.resolve(repoRoot, rootPath);
  const relativeToRoot = path.relative(resolvedRoot, resolvedPath);
  if (!relativeToRoot || relativeToRoot.startsWith('..') || path.isAbsolute(relativeToRoot)) {
    throw new Error(`${label} must stay under ${rootPath}: ${normalized}`);
  }
  return normalized;
}

function applyRootPathGuard(repoRoot, options) {
  const guardedReceiptPath = assertRelativePathWithinRoot(
    repoRoot,
    options.receiptPath,
    DEFAULT_RESULTS_ROOT,
    'Receipt path',
  );
  const modePaths = getModePaths(options.mode, options);
  return {
    ...options,
    receiptPath: guardedReceiptPath,
    preflightReportPath: assertRelativePathWithinRoot(
      repoRoot,
      modePaths.preflightReportPath,
      DEFAULT_RESULTS_ROOT,
      'Preflight report path',
    ),
    reportPath: modePaths.reportPath
      ? assertRelativePathWithinRoot(repoRoot, modePaths.reportPath, DEFAULT_RESULTS_ROOT, 'Report path')
      : null,
    runtimeSnapshotPath: modePaths.runtimeSnapshotPath
      ? assertRelativePathWithinRoot(repoRoot, modePaths.runtimeSnapshotPath, DEFAULT_RESULTS_ROOT, 'Runtime snapshot path')
      : null,
    artifactSummaryPath: modePaths.artifactSummaryPath
      ? assertRelativePathWithinRoot(repoRoot, modePaths.artifactSummaryPath, DEFAULT_RESULTS_ROOT, 'Artifact summary path')
      : null,
    capturePath: modePaths.capturePath
      ? assertRelativePathWithinRoot(repoRoot, modePaths.capturePath, DEFAULT_RESULTS_ROOT, 'Capture path')
      : null,
    stdoutPath: modePaths.stdoutPath
      ? assertRelativePathWithinRoot(repoRoot, modePaths.stdoutPath, DEFAULT_RESULTS_ROOT, 'Stdout path')
      : null,
    stderrPath: modePaths.stderrPath
      ? assertRelativePathWithinRoot(repoRoot, modePaths.stderrPath, DEFAULT_RESULTS_ROOT, 'Stderr path')
      : null,
  };
}

export function parseArgs(argv = process.argv, repoRoot = process.cwd()) {
  const args = argv.slice(2);
  const options = {
    help: false,
    mode: DEFAULT_MODE,
    executionSurface: 'desktop-local',
    image: DEFAULT_IMAGE,
    labviewPath: null,
    allowUnavailable: false,
    receiptPath: defaultReceiptPath(DEFAULT_MODE),
    preflightReportPath: null,
    reportPath: null,
    runtimeSnapshotPath: null,
    artifactSummaryPath: null,
    capturePath: null,
    stdoutPath: null,
    stderrPath: null,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--allow-unavailable') {
      options.allowUnavailable = true;
      continue;
    }
    if (
      token === '--mode' ||
      token === '--execution-surface' ||
      token === '--image' ||
      token === '--labview-path' ||
      token === '--receipt-path' ||
      token === '--preflight-report'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--mode') {
        options.mode = normalizeText(next) ?? DEFAULT_MODE;
      }
      if (token === '--execution-surface') {
        options.executionSurface = normalizeText(next) ?? 'desktop-local';
      }
      if (token === '--image') {
        options.image = normalizeText(next) ?? DEFAULT_IMAGE;
      }
      if (token === '--labview-path') {
        options.labviewPath = normalizeText(next);
      }
      if (token === '--receipt-path') {
        options.receiptPath = next;
      }
      if (token === '--preflight-report') {
        options.preflightReportPath = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!MODE_CONFIG[options.mode]) {
      throw new Error(`Unsupported replay mode: ${options.mode}`);
    }
    if (!['desktop-local', 'github-hosted-windows'].includes(options.executionSurface)) {
      throw new Error(`Unsupported execution surface: ${options.executionSurface}`);
    }
  }

  if (options.help) {
    return options;
  }

  if (options.mode !== DEFAULT_MODE && options.receiptPath === defaultReceiptPath(DEFAULT_MODE)) {
    options.receiptPath = defaultReceiptPath(options.mode);
  }

  return applyRootPathGuard(repoRoot, options);
}

export function buildReplayCommand(options) {
  const config = MODE_CONFIG[options.mode];
  if (!config) {
    throw new Error(`Unsupported replay mode: ${options.mode}`);
  }
  const modePaths = getModePaths(options.mode, options);
  const command = [
    '-NoLogo',
    '-NoProfile',
    '-File',
    config.helperPath,
    '-Image',
    options.image,
    '-ResultsDir',
    path.dirname(modePaths.preflightReportPath),
    '-ExecutionSurface',
    options.executionSurface,
    '-OutputJsonPath',
    modePaths.preflightReportPath,
    '-GitHubOutputPath',
    '',
    '-StepSummaryPath',
    '',
  ];
  if (options.allowUnavailable) {
    command.push('-AllowUnavailable');
  }
  const replayCommand = {
    kind: config.kind,
    helperPath: config.helperPath,
    command,
    modePaths,
  };

  if (config.kind === 'preflight-compare') {
    replayCommand.compareHelperPath = config.compareHelperPath;
    replayCommand.compareCommand = [
      '-NoLogo',
      '-NoProfile',
      '-File',
      config.compareHelperPath,
      '-BaseVi',
      config.baseVi,
      '-HeadVi',
      config.headVi,
      '-Image',
      options.image,
      '-LabVIEWPath',
      options.labviewPath ?? config.labviewPath,
      '-ReportPath',
      modePaths.reportPath,
      '-TimeoutSeconds',
      String(config.timeoutSeconds),
      '-RuntimeEngineReadyTimeoutSeconds',
      String(config.runtimeEngineReadyTimeoutSeconds),
      '-RuntimeEngineReadyPollSeconds',
      String(config.runtimeEngineReadyPollSeconds),
      '-RuntimeSnapshotPath',
      modePaths.runtimeSnapshotPath,
    ];
  }

  return replayCommand;
}

function readJsonIfPresent(resolvedPath) {
  if (!fs.existsSync(resolvedPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
}

function buildReceiptBase(repoRoot, options, gitState, replayCommand) {
  return {
    schema: REPORT_SCHEMA,
    schemaVersion: DEFAULT_SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    repoRoot,
    git: {
      headSha: gitState?.headSha ?? null,
      branch: gitState?.branch ?? null,
      upstreamDevelopMergeBase: gitState?.upstreamDevelopMergeBase ?? null,
      dirtyTracked: typeof gitState?.dirtyTracked === 'boolean' ? gitState.dirtyTracked : false,
    },
    replay: {
      mode: options.mode,
      executionSurface: options.executionSurface,
      helperPath: replayCommand.helperPath,
    },
    windows: {
      image: options.image,
      labviewPath: options.labviewPath ?? MODE_CONFIG[options.mode]?.labviewPath ?? null,
      allowUnavailable: options.allowUnavailable,
      command: {
        entry: 'pwsh',
        args: [],
        sanitizedShellCommand: 'pwsh',
      },
      compareCommand: null,
    },
    artifacts: {
      receiptPath: options.receiptPath,
      preflightReportPath: options.preflightReportPath,
      reportPath: options.reportPath ?? null,
      runtimeSnapshotPath: options.runtimeSnapshotPath ?? null,
      artifactSummaryPath: options.artifactSummaryPath ?? null,
      capturePath: options.capturePath ?? null,
      stdoutPath: options.stdoutPath ?? null,
      stderrPath: options.stderrPath ?? null,
    },
    result: {
      status: 'failed',
      exitCode: 1,
      preflightStatus: null,
      failureClass: null,
      errorMessage: null,
      compareExitCode: null,
      compareGateOutcome: null,
      compareResultClass: null,
      reportExists: null,
      captureExists: null,
    },
  };
}

function buildWindowsCompareArtifactSummary({
  compareSucceeded,
  reportPath,
  reportExists,
  capturePath,
  captureExists,
  captureResultClass,
  captureGateOutcome,
  now,
}) {
  return {
    schema: 'vi-history/windows-compare-artifact-summary@v1',
    generatedAt: new Date(now).toISOString(),
    compareStepConclusion: compareSucceeded ? 'success' : 'failure',
    reportPath,
    reportExists,
    capturePath,
    captureExists,
    captureResultClass,
    captureGateOutcome,
  };
}

export async function runWindowsWorkflowReplayLane(
  options,
  {
    repoRoot = process.cwd(),
    env = process.env,
    runProcessFn = runProcess,
    resolveRepoGitStateFn = resolveRepoGitState,
    now = new Date(),
  } = {},
) {
  const replayCommand = buildReplayCommand(options);
  const gitState = resolveRepoGitStateFn(repoRoot, runProcessFn);
  const receipt = buildReceiptBase(repoRoot, options, gitState, replayCommand);
  receipt.generatedAt = new Date(now).toISOString();
  const preflightReportResolvedPath = resolveRepoPath(repoRoot, options.preflightReportPath);

  const failClosed = (message, exitCode = 1) => {
    receipt.result.status = 'failed';
    receipt.result.exitCode = exitCode;
    receipt.result.errorMessage = message;
    const persistedReceiptPath = writeJsonFile(repoRoot, options.receiptPath, receipt);
    return {
      status: 'failed',
      receipt,
      receiptPath: persistedReceiptPath,
    };
  };

  receipt.windows.command.args = replayCommand.command;
  receipt.windows.command.sanitizedShellCommand = formatCommandForShell('pwsh', replayCommand.command);
  if (replayCommand.compareCommand) {
    receipt.windows.compareCommand = {
      entry: 'pwsh',
      args: replayCommand.compareCommand,
      sanitizedShellCommand: formatCommandForShell('pwsh', replayCommand.compareCommand),
    };
  }

  const helperResult = runProcessFn('pwsh', replayCommand.command, {
    cwd: repoRoot,
    env,
    maxBuffer: DEFAULT_REPLAY_MAX_BUFFER_BYTES,
  });

  if (!fs.existsSync(preflightReportResolvedPath)) {
    return failClosed(
      normalizeText(helperResult.stderr) ??
        normalizeText(helperResult.stdout) ??
        (helperResult.error instanceof Error ? helperResult.error.message : null) ??
        `Windows replay helper did not write ${options.preflightReportPath}.`,
      helperResult.status ?? 1,
    );
  }

  let preflightReport;
  try {
    preflightReport = readJsonIfPresent(preflightReportResolvedPath);
  } catch (error) {
    return failClosed(
      `Windows preflight report could not be parsed: ${error instanceof Error ? error.message : String(error)}`,
      helperResult.status ?? 1,
    );
  }

  receipt.result.preflightStatus = normalizeText(preflightReport?.status);
  receipt.result.failureClass = normalizeText(preflightReport?.failureClass);
  receipt.result.exitCode = helperResult.status ?? 0;

  if (receipt.result.preflightStatus === 'ready') {
    if (replayCommand.kind !== 'preflight-compare') {
      receipt.result.status = 'passed';
      receipt.result.errorMessage = null;
    } else {
      const compareResult = runProcessFn('pwsh', replayCommand.compareCommand, {
        cwd: repoRoot,
        env,
        maxBuffer: DEFAULT_REPLAY_MAX_BUFFER_BYTES,
      });
      const compareExitCode = compareResult.status ?? 0;
      const reportResolvedPath = resolveRepoPath(repoRoot, replayCommand.modePaths.reportPath);
      const captureResolvedPath = resolveRepoPath(repoRoot, replayCommand.modePaths.capturePath);
      const captureExists = fs.existsSync(captureResolvedPath);
      const reportExists = fs.existsSync(reportResolvedPath);
      const capture = readJsonIfPresent(captureResolvedPath);
      const captureGateOutcome = normalizeText(capture?.gateOutcome);
      const captureResultClass = normalizeText(capture?.resultClass);
      const compareSucceeded = compareExitCode === 0;

      receipt.result.compareExitCode = compareExitCode;
      receipt.result.compareGateOutcome = captureGateOutcome;
      receipt.result.compareResultClass = captureResultClass;
      receipt.result.reportExists = reportExists;
      receipt.result.captureExists = captureExists;

      writeJsonFile(
        repoRoot,
        replayCommand.modePaths.artifactSummaryPath,
        buildWindowsCompareArtifactSummary({
          compareSucceeded,
          reportPath: replayCommand.modePaths.reportPath,
          reportExists,
          capturePath: replayCommand.modePaths.capturePath,
          captureExists,
          captureResultClass,
          captureGateOutcome,
          now,
        }),
      );

      if (!compareSucceeded && !captureExists) {
        return failClosed(
          normalizeText(compareResult.stderr) ??
            normalizeText(compareResult.stdout) ??
            (compareResult.error instanceof Error ? compareResult.error.message : null) ??
            `Windows compare failed (exit=${compareExitCode}) and no capture file was written at ${replayCommand.modePaths.capturePath}.`,
          compareExitCode || 1,
        );
      }

      const requireReport = compareSucceeded && captureResultClass === 'success-diff';
      if (requireReport && !reportExists) {
        return failClosed(
          `Windows compare classified success-diff but report file was not found: ${replayCommand.modePaths.reportPath}`,
          compareExitCode || 1,
        );
      }

      if (!compareSucceeded && captureGateOutcome !== 'pass') {
        return failClosed(
          normalizeText(capture?.failureMessage) ??
            normalizeText(compareResult.stderr) ??
            normalizeText(compareResult.stdout) ??
            (compareResult.error instanceof Error ? compareResult.error.message : null) ??
            `Windows compare failed with exit ${compareExitCode}.`,
          compareExitCode || 1,
        );
      }

      receipt.result.status = 'passed';
      receipt.result.errorMessage = null;
      receipt.result.exitCode = compareExitCode;
    }
  } else if (receipt.result.preflightStatus === 'unavailable' && options.allowUnavailable) {
    receipt.result.status = 'unavailable';
    receipt.result.errorMessage = normalizeText(preflightReport?.failureMessage);
  } else {
    receipt.result.status = 'failed';
    receipt.result.errorMessage =
      normalizeText(preflightReport?.failureMessage) ??
      normalizeText(helperResult.stderr) ??
      normalizeText(helperResult.stdout) ??
      (helperResult.error instanceof Error ? helperResult.error.message : null) ??
      `Windows preflight report status was '${receipt.result.preflightStatus ?? 'unknown'}'.`;
  }

  const persistedReceiptPath = writeJsonFile(repoRoot, options.receiptPath, receipt);
  return {
    status: receipt.result.status,
    receipt,
    receiptPath: persistedReceiptPath,
  };
}

export async function main(
  argv = process.argv,
  {
    logFn = console.log,
    errorFn = console.error,
    repoRoot = process.cwd(),
    runWindowsWorkflowReplayLaneFn = runWindowsWorkflowReplayLane,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv, repoRoot);
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  const result = await runWindowsWorkflowReplayLaneFn(options, {
    repoRoot,
  });

  logFn(`windows workflow replay lane: ${result.status}`);
  logFn(`receipt: ${path.relative(repoRoot, result.receiptPath).replace(/\\/g, '/')}`);
  if (result.receipt.result.errorMessage) {
    logFn(`message: ${result.receipt.result.errorMessage}`);
  }
  return result.status === 'failed' ? 1 : 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && fileURLToPath(import.meta.url) === invokedPath) {
  const exitCode = await main();
  process.exitCode = exitCode;
}

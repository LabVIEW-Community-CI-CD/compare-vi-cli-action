#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'docker-workflow-replay-lane@v1';
export const DEFAULT_SCHEMA_VERSION = '1.0.0';
export const DEFAULT_MODE = 'session-index-v2-promotion';
export const DEFAULT_BRANCH = 'develop';
export const DEFAULT_RESULTS_ROOT = path.join('tests', 'results', 'docker-tools-parity', 'workflow-replay');
export const DEFAULT_LOCAL_IMAGE = 'comparevi-tools:local';
export const DEFAULT_PUBLISHED_IMAGE = 'ghcr.io/labview-community-ci-cd/comparevi-tools:latest';
export const DEFAULT_REPLAY_MAX_BUFFER_BYTES = 64 * 1024 * 1024;

export const MODE_CONFIG = Object.freeze({
  'session-index-v2-promotion': Object.freeze({
    helperPath: path.join('tools', 'priority', 'session-index-v2-promotion-decision.mjs'),
    replayReportPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'session-index-v2-promotion',
      'session-index-v2-promotion-decision.json',
    ),
    downloadReportPath: path.join(
      DEFAULT_RESULTS_ROOT,
      'session-index-v2-promotion',
      'session-index-v2-promotion-download.json',
    ),
    destinationRoot: path.join(
      DEFAULT_RESULTS_ROOT,
      'session-index-v2-promotion',
      'artifacts',
    ),
  }),
});

function printUsage() {
  console.log('Usage: node tools/priority/docker-workflow-replay-lane.mjs [options]');
  console.log('');
  console.log('Run a workflow-grade replay helper inside the local CompareVI tools image.');
  console.log('');
  console.log('Options:');
  console.log(`  --mode <name>                 Replay mode (default: ${DEFAULT_MODE}).`);
  console.log('  --repo <owner/repo>           Target repository (default: GITHUB_REPOSITORY or git remotes).');
  console.log('  --run-id <id>                 Workflow run id to replay.');
  console.log(`  --branch <name>               Branch filter forwarded to the replay helper (default: ${DEFAULT_BRANCH}).`);
  console.log('  --image <ref>                 Override Docker image reference.');
  console.log('  --skip-pull-missing           Fail instead of pulling a missing image.');
  console.log(`  --receipt-path <path>         Outer receipt path (default: ${defaultReceiptPath(DEFAULT_MODE)}).`);
  console.log('  --replay-report <path>        Override in-container replay report path.');
  console.log('  --download-report <path>      Override replay artifact download report path.');
  console.log('  --destination-root <path>     Override replay artifact destination root.');
  console.log('  -h, --help                    Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeRepository(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const segments = normalized.split('/').map((segment) => segment.trim());
  if (segments.length !== 2 || segments.some((segment) => segment.length === 0)) {
    throw new Error(`Repository must use the form <owner>/<repo>; received '${value}'.`);
  }
  return `${segments[0]}/${segments[1]}`;
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

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  return normalizeRepository(repoPath);
}

function resolveGitConfigPaths(repoRoot) {
  const dotGitPath = path.join(repoRoot, '.git');
  if (!fs.existsSync(dotGitPath)) {
    return [];
  }
  const stat = fs.statSync(dotGitPath);
  if (stat.isDirectory()) {
    const configPath = path.join(dotGitPath, 'config');
    return fs.existsSync(configPath) ? [configPath] : [];
  }
  const dotGitContent = fs.readFileSync(dotGitPath, 'utf8');
  const gitDirMatch = dotGitContent.match(/^gitdir:\s*(.+)$/im);
  if (!gitDirMatch) {
    return [];
  }
  const gitDir = path.resolve(repoRoot, gitDirMatch[1].trim());
  const configPaths = [];
  const commonDirFile = path.join(gitDir, 'commondir');
  if (fs.existsSync(commonDirFile)) {
    const commonDir = path.resolve(gitDir, fs.readFileSync(commonDirFile, 'utf8').trim());
    const commonConfigPath = path.join(commonDir, 'config');
    if (fs.existsSync(commonConfigPath)) {
      configPaths.push(commonConfigPath);
    }
  }
  const gitDirConfigPath = path.join(gitDir, 'config');
  if (fs.existsSync(gitDirConfigPath)) {
    configPaths.push(gitDirConfigPath);
  }
  return configPaths;
}

function resolveRepositoryFromGitConfig(repoRoot) {
  const configPaths = resolveGitConfigPaths(repoRoot);
  for (const configPath of configPaths) {
    const config = fs.readFileSync(configPath, 'utf8');
    for (const remoteName of ['upstream', 'origin']) {
      const escaped = remoteName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const sectionMatch = config.match(
        new RegExp(`\\[remote\\s+"${escaped}"\\]([\\s\\S]*?)(?:\\n\\[|$)`, 'i'),
      );
      const section = sectionMatch?.[1];
      if (!section) {
        continue;
      }
      const urlMatch = section.match(/^\s*url\s*=\s*(.+)$/im);
      const repository = parseRemoteUrl(urlMatch?.[1]?.trim());
      if (repository) {
        return repository;
      }
    }
  }
  return null;
}

function formatShellToken(value) {
  if (/^[A-Za-z0-9_./:=+-]+$/.test(value)) {
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

function runGitCommand(repoRoot, args, runProcessFn = runProcess) {
  const result = runProcessFn('git', args, {
    cwd: repoRoot,
    maxBuffer: 8 * 1024 * 1024,
  });
  return {
    ok: result.status === 0,
    stdout: normalizeText(result.stdout),
    stderr: normalizeText(result.stderr),
  };
}

export function resolveRepoGitState(repoRoot, runProcessFn = runProcess) {
  const headShaResult = runGitCommand(repoRoot, ['rev-parse', 'HEAD'], runProcessFn);
  if (!headShaResult.ok || !headShaResult.stdout) {
    return null;
  }
  const branchResult = runGitCommand(repoRoot, ['branch', '--show-current'], runProcessFn);
  const upstreamDevelopMergeBaseResult = runGitCommand(repoRoot, ['merge-base', 'HEAD', 'upstream/develop'], runProcessFn);
  const dirtyTrackedResult = runGitCommand(repoRoot, ['status', '--short', '--untracked-files=no'], runProcessFn);
  return {
    headSha: headShaResult.stdout,
    branch: branchResult.ok ? branchResult.stdout || null : null,
    upstreamDevelopMergeBase: upstreamDevelopMergeBaseResult.ok ? upstreamDevelopMergeBaseResult.stdout || null : null,
    dirtyTracked: dirtyTrackedResult.ok ? dirtyTrackedResult.stdout.length > 0 : null,
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
    replayReportPath: normalizeText(overrides.replayReportPath) ?? config.replayReportPath,
    downloadReportPath: normalizeText(overrides.downloadReportPath) ?? config.downloadReportPath,
    destinationRoot: normalizeText(overrides.destinationRoot) ?? config.destinationRoot,
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
    replayReportPath: assertRelativePathWithinRoot(
      repoRoot,
      modePaths.replayReportPath,
      DEFAULT_RESULTS_ROOT,
      'Replay report path',
    ),
    downloadReportPath: assertRelativePathWithinRoot(
      repoRoot,
      modePaths.downloadReportPath,
      DEFAULT_RESULTS_ROOT,
      'Download report path',
    ),
    destinationRoot: assertRelativePathWithinRoot(
      repoRoot,
      modePaths.destinationRoot,
      DEFAULT_RESULTS_ROOT,
      'Destination root',
    ),
  };
}

export function parseArgs(argv = process.argv, env = process.env, repoRoot = process.cwd()) {
  const args = argv.slice(2);
  const options = {
    help: false,
    mode: DEFAULT_MODE,
    repo: normalizeText(env.GITHUB_REPOSITORY) ?? resolveRepositoryFromGitConfig(repoRoot),
    runId: null,
    branch: DEFAULT_BRANCH,
    image: null,
    skipPullMissing: false,
    receiptPath: defaultReceiptPath(DEFAULT_MODE),
    replayReportPath: null,
    downloadReportPath: null,
    destinationRoot: null,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--skip-pull-missing') {
      options.skipPullMissing = true;
      continue;
    }
    if (
      token === '--mode' ||
      token === '--repo' ||
      token === '--run-id' ||
      token === '--branch' ||
      token === '--image' ||
      token === '--receipt-path' ||
      token === '--replay-report' ||
      token === '--download-report' ||
      token === '--destination-root'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--mode') {
        options.mode = normalizeText(next) ?? DEFAULT_MODE;
      }
      if (token === '--repo') {
        options.repo = normalizeText(next);
      }
      if (token === '--run-id') {
        options.runId = normalizeText(next);
      }
      if (token === '--branch') {
        options.branch = normalizeText(next) ?? DEFAULT_BRANCH;
      }
      if (token === '--image') {
        options.image = normalizeText(next);
      }
      if (token === '--receipt-path') {
        options.receiptPath = next;
      }
      if (token === '--replay-report') {
        options.replayReportPath = next;
      }
      if (token === '--download-report') {
        options.downloadReportPath = next;
      }
      if (token === '--destination-root') {
        options.destinationRoot = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!MODE_CONFIG[options.mode]) {
      throw new Error(`Unsupported replay mode: ${options.mode}`);
    }
    options.repo = normalizeRepository(options.repo);
    if (!options.runId) {
      throw new Error('Run id is required. Pass --run-id <id>.');
    }
  }

  if (
    options.mode !== DEFAULT_MODE &&
    options.receiptPath === defaultReceiptPath(DEFAULT_MODE)
  ) {
    options.receiptPath = defaultReceiptPath(options.mode);
  }

  if (options.help) {
    return options;
  }

  return applyRootPathGuard(repoRoot, options);
}

export function resolveGitHubToken(env = process.env, runProcessFn = runProcess) {
  const ghToken = normalizeText(env.GH_TOKEN);
  if (ghToken) {
    return {
      value: ghToken,
      source: 'GH_TOKEN',
      errorMessage: null,
    };
  }
  const githubToken = normalizeText(env.GITHUB_TOKEN);
  if (githubToken) {
    return {
      value: githubToken,
      source: 'GITHUB_TOKEN',
      errorMessage: null,
    };
  }
  const ghAuth = runProcessFn('gh', ['auth', 'token'], {
    cwd: process.cwd(),
    env,
    maxBuffer: 4 * 1024 * 1024,
  });
  const ghAuthToken = normalizeText(ghAuth.stdout);
  if (ghAuth.status === 0 && ghAuthToken) {
    return {
      value: ghAuthToken,
      source: 'gh auth token',
      errorMessage: null,
    };
  }
  return {
    value: null,
    source: 'missing',
    errorMessage:
      normalizeText(ghAuth.stderr) ??
      normalizeText(ghAuth.stdout) ??
      (ghAuth.error instanceof Error ? ghAuth.error.message : null) ??
      'GitHub token was not available from GH_TOKEN, GITHUB_TOKEN, or gh auth token.',
  };
}

function dockerImageExists(image, runProcessFn, env, repoRoot) {
  const result = runProcessFn('docker', ['image', 'inspect', image], {
    cwd: repoRoot,
    env,
  });
  return result.status === 0;
}

function pullDockerImage(image, runProcessFn, env, repoRoot) {
  const result = runProcessFn('docker', ['pull', image], {
    cwd: repoRoot,
    env,
    maxBuffer: DEFAULT_REPLAY_MAX_BUFFER_BYTES,
  });
  if (result.status !== 0) {
    const errorMessage =
      normalizeText(result.stderr) ??
      normalizeText(result.stdout) ??
      (result.error instanceof Error ? result.error.message : null) ??
      `docker pull ${image} failed.`;
    throw new Error(errorMessage);
  }
}

export function resolveImageSelection(
  { requestedImage = null, skipPullMissing = false } = {},
  env = process.env,
  runProcessFn = runProcess,
  repoRoot = process.cwd(),
) {
  const explicitImage = normalizeText(requestedImage);
  if (explicitImage) {
    if (!dockerImageExists(explicitImage, runProcessFn, env, repoRoot)) {
      if (skipPullMissing) {
        throw new Error(`Docker image '${explicitImage}' is missing and --skip-pull-missing was requested.`);
      }
      pullDockerImage(explicitImage, runProcessFn, env, repoRoot);
      return { image: explicitImage, source: 'explicit-pulled' };
    }
    return { image: explicitImage, source: 'explicit' };
  }

  const envImage = normalizeText(env.COMPAREVI_TOOLS_IMAGE);
  if (envImage) {
    if (!dockerImageExists(envImage, runProcessFn, env, repoRoot)) {
      if (skipPullMissing) {
        throw new Error(`Docker image '${envImage}' from COMPAREVI_TOOLS_IMAGE is missing and --skip-pull-missing was requested.`);
      }
      pullDockerImage(envImage, runProcessFn, env, repoRoot);
      return { image: envImage, source: 'env-pulled' };
    }
    return { image: envImage, source: 'env' };
  }

  if (dockerImageExists(DEFAULT_LOCAL_IMAGE, runProcessFn, env, repoRoot)) {
    return { image: DEFAULT_LOCAL_IMAGE, source: 'local-default' };
  }

  if (dockerImageExists(DEFAULT_PUBLISHED_IMAGE, runProcessFn, env, repoRoot)) {
    return { image: DEFAULT_PUBLISHED_IMAGE, source: 'published-fallback-local' };
  }

  if (skipPullMissing) {
    throw new Error(
      `No usable Docker replay image was available locally (${DEFAULT_LOCAL_IMAGE} or ${DEFAULT_PUBLISHED_IMAGE}).`,
    );
  }

  pullDockerImage(DEFAULT_PUBLISHED_IMAGE, runProcessFn, env, repoRoot);
  return { image: DEFAULT_PUBLISHED_IMAGE, source: 'published-fallback-pulled' };
}

function getDockerHostPath(inputPath) {
  const resolved = path.resolve(inputPath);
  if (process.platform === 'win32') {
    const drive = resolved.slice(0, 1).toLowerCase();
    const remainder = resolved.slice(2).replace(/\\/g, '/').replace(/^\/+/, '');
    return `/${drive}/${remainder}`;
  }
  return resolved;
}

export function buildReplayCommand(options) {
  const config = MODE_CONFIG[options.mode];
  if (!config) {
    throw new Error(`Unsupported replay mode: ${options.mode}`);
  }
  const command = [
    'node',
    config.helperPath.replace(/\\/g, '/'),
    '--repo',
    options.repo,
    '--run-id',
    options.runId,
    '--branch',
    options.branch,
    '--out',
    options.replayReportPath.replace(/\\/g, '/'),
    '--download-report',
    options.downloadReportPath.replace(/\\/g, '/'),
    '--destination-root',
    options.destinationRoot.replace(/\\/g, '/'),
  ];
  return {
    helperPath: config.helperPath,
    command,
  };
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
      repository: options.repo,
      runId: options.runId,
      branch: options.branch,
      helperPath: replayCommand.helperPath.replace(/\\/g, '/'),
    },
    docker: {
      image: null,
      imageSource: null,
      tokenSource: null,
      command: {
        entry: 'docker',
        args: [],
        sanitizedShellCommand: 'docker run',
      },
    },
    artifacts: {
      receiptPath: options.receiptPath,
      replayReportPath: options.replayReportPath,
      downloadReportPath: options.downloadReportPath,
      destinationRoot: options.destinationRoot,
    },
    result: {
      status: 'failed',
      exitCode: 1,
      replayStatus: null,
      replayDecisionState: null,
      errorMessage: null,
    },
  };
}

export async function runDockerWorkflowReplayLane(
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
  const receiptResolvedPath = resolveRepoPath(repoRoot, options.receiptPath);
  const replayReportResolvedPath = resolveRepoPath(repoRoot, options.replayReportPath);

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

  const token = resolveGitHubToken(env, runProcessFn);
  receipt.docker.tokenSource = token.source;
  if (!token.value) {
    return failClosed(token.errorMessage ?? 'GitHub token is required for workflow replay.');
  }

  let imageSelection;
  try {
    imageSelection = resolveImageSelection(
      {
        requestedImage: options.image,
        skipPullMissing: options.skipPullMissing,
      },
      env,
      runProcessFn,
      repoRoot,
    );
  } catch (error) {
    return failClosed(error instanceof Error ? error.message : String(error));
  }

  receipt.docker.image = imageSelection.image;
  receipt.docker.imageSource = imageSelection.source;

  const dockerArgs = [
    'run',
    '--rm',
    '-v',
    `${getDockerHostPath(repoRoot)}:/work`,
    '-w',
    '/work',
    '-e',
    'GH_TOKEN',
    '-e',
    'GITHUB_TOKEN',
    imageSelection.image,
    ...replayCommand.command,
  ];
  receipt.docker.command.args = dockerArgs;
  receipt.docker.command.sanitizedShellCommand = formatCommandForShell('docker', dockerArgs);

  const dockerEnv = {
    ...env,
    GH_TOKEN: token.value,
    GITHUB_TOKEN: token.value,
  };

  const dockerResult = runProcessFn('docker', dockerArgs, {
    cwd: repoRoot,
    env: dockerEnv,
    maxBuffer: DEFAULT_REPLAY_MAX_BUFFER_BYTES,
  });

  if (dockerResult.status !== 0) {
    return failClosed(
      normalizeText(dockerResult.stderr) ??
        normalizeText(dockerResult.stdout) ??
        (dockerResult.error instanceof Error ? dockerResult.error.message : null) ??
        'docker replay lane failed.',
      dockerResult.status ?? 1,
    );
  }

  if (!fs.existsSync(replayReportResolvedPath)) {
    return failClosed(`Replay report was not written: ${options.replayReportPath}`);
  }

  let replayReport;
  try {
    replayReport = readJsonIfPresent(replayReportResolvedPath);
  } catch (error) {
    return failClosed(
      `Replay report could not be parsed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  receipt.result.replayStatus = normalizeText(replayReport?.status);
  receipt.result.replayDecisionState = normalizeText(replayReport?.decision?.state);
  receipt.result.exitCode = dockerResult.status ?? 0;
  if (receipt.result.replayStatus !== 'pass') {
    receipt.result.status = 'failed';
    receipt.result.errorMessage =
      normalizeText(replayReport?.decision?.errorMessage) ??
      normalizeText(replayReport?.summary?.message) ??
      `Replay report status was '${receipt.result.replayStatus ?? 'unknown'}'.`;
  } else {
    receipt.result.status = 'passed';
    receipt.result.errorMessage = null;
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
    env = process.env,
    logFn = console.log,
    errorFn = console.error,
    repoRoot = process.cwd(),
    runDockerWorkflowReplayLaneFn = runDockerWorkflowReplayLane,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv, env, repoRoot);
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  const result = await runDockerWorkflowReplayLaneFn(options, {
    repoRoot,
    env,
  });

  logFn(`docker workflow replay lane: ${result.status}`);
  logFn(`receipt: ${path.relative(repoRoot, result.receiptPath).replace(/\\/g, '/')}`);
  if (result.receipt.result.errorMessage) {
    logFn(`message: ${result.receipt.result.errorMessage}`);
  }
  return result.status === 'passed' ? 0 : 1;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && fileURLToPath(import.meta.url) === invokedPath) {
  const exitCode = await main();
  process.exitCode = exitCode;
}

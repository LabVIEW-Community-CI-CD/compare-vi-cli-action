#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import {
  buildReviewPrompt,
  collectInstructionSources,
  collectReviewContext,
  DEFAULT_COPILOT_CLI_MAX_BUFFER_BYTES,
  DEFAULT_COPILOT_CLI_REVIEW_POLICY,
  DELIVERY_AGENT_POLICY_PATH,
  resolveRepoGitState
} from './copilot-cli-review.mjs';
import { isEntrypoint } from './shim-utils.mjs';

export const CODEX_CLI_REVIEW_SCHEMA = 'priority/codex-cli-review@v1';
export const DEFAULT_CODEX_CLI_REVIEW_POLICY = {
  enabled: false,
  model: '',
  distro: 'Ubuntu',
  executionPlane: 'wsl2',
  sandbox: 'read-only',
  ephemeral: true,
  profiles: {
    preCommit: {
      enabled: true,
      mode: 'staged',
      receiptPath: path.join('tests', 'results', '_hooks', 'pre-commit-codex-cli-review.json'),
      failOnFindings: true,
      maxFiles: 12,
      maxDiffBytes: 12 * 1024
    },
    daemon: {
      enabled: true,
      mode: 'head',
      receiptPath: path.join('tests', 'results', 'docker-tools-parity', 'codex-cli-review', 'receipt.json'),
      failOnFindings: true,
      maxFiles: 24,
      maxDiffBytes: 16 * 1024
    },
    prePush: {
      enabled: true,
      mode: 'head',
      receiptPath: path.join('tests', 'results', '_hooks', 'pre-push-codex-cli-review.json'),
      failOnFindings: true,
      maxFiles: 24,
      maxDiffBytes: 16 * 1024
    }
  },
  collaboration: {
    ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration
  }
};

const PROFILE_NAME_MAP = new Map([
  ['pre-commit', 'preCommit'],
  ['preCommit', 'preCommit'],
  ['daemon', 'daemon'],
  ['pre-push', 'prePush'],
  ['prePush', 'prePush']
]);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function coercePositiveInteger(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function normalizeStringList(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => normalizeText(entry)).filter(Boolean);
  }
  if (typeof value === 'string') {
    return value
      .split(/\r?\n/)
      .map((entry) => normalizeText(entry))
      .filter(Boolean);
  }
  return [];
}

function normalizeProfileName(value) {
  const normalized = PROFILE_NAME_MAP.get(normalizeText(value));
  if (!normalized) {
    throw new Error(`Unsupported Codex CLI review profile: ${value}`);
  }
  return normalized;
}

function normalizeReviewFinding(value) {
  const finding = value && typeof value === 'object' ? value : {};
  const line = Number(finding.line);
  const severity = normalizeText(finding.severity).toLowerCase();
  return {
    severity: ['error', 'warning', 'note'].includes(severity) ? severity : 'warning',
    path: normalizeText(finding.path) || null,
    line: Number.isInteger(line) && line > 0 ? line : null,
    title: normalizeText(finding.title) || 'Codex CLI finding',
    body: normalizeText(finding.body) || '',
    actionable: finding.actionable !== false
  };
}

function parseStructuredAssistantPayload(raw) {
  const trimmed = normalizeText(raw);
  if (!trimmed) {
    throw new Error('Codex CLI did not return a final assistant message.');
  }
  let parsed;
  try {
    parsed = JSON.parse(trimmed);
  } catch (error) {
    throw new Error(`Codex CLI assistant message was not valid JSON: ${error.message}`);
  }
  const findings = Array.isArray(parsed.findings) ? parsed.findings.map(normalizeReviewFinding) : [];
  const status = normalizeText(parsed.status).toLowerCase() || (findings.length > 0 ? 'changes-requested' : 'approved');
  return {
    status: status === 'approved' ? 'approved' : 'changes-requested',
    summary: normalizeText(parsed.summary) || null,
    findings
  };
}

function buildCommandResult(result = {}) {
  return {
    status: Number.isInteger(result.status) ? result.status : 1,
    stdout: normalizeText(result.stdout),
    stderr: [
      normalizeText(result.stderr),
      normalizeText(result.error?.message),
      normalizeText(result.signal ? `Process terminated by signal ${result.signal}.` : '')
    ]
      .filter(Boolean)
      .join('\n')
  };
}

function runWslCommand(distro, args, { cwd, env } = {}) {
  return buildCommandResult(
    spawnSync('wsl.exe', ['-d', distro, '--', ...args], {
      cwd,
      env,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: DEFAULT_COPILOT_CLI_MAX_BUFFER_BYTES
    })
  );
}

function resolveRepoPath(repoRoot, candidatePath) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    throw new Error('Path must be a non-empty repo-relative path.');
  }
  if (path.isAbsolute(normalized)) {
    throw new Error(`Path must be repo-relative: ${normalized}`);
  }
  const resolved = path.resolve(repoRoot, normalized);
  const relativeToRepo = path.relative(repoRoot, resolved);
  if (!relativeToRepo || relativeToRepo.startsWith('..') || path.isAbsolute(relativeToRepo)) {
    throw new Error(`Path escapes the repository root: ${normalized}`);
  }
  return {
    normalized,
    resolved
  };
}

function normalizeProfilePolicy(value = {}) {
  const profile = value && typeof value === 'object' ? value : {};
  return {
    enabled: profile.enabled !== false,
    mode: normalizeText(profile.mode).toLowerCase() === 'staged' ? 'staged' : 'head',
    receiptPath: normalizeText(profile.receiptPath),
    failOnFindings: profile.failOnFindings !== false,
    maxFiles: coercePositiveInteger(profile.maxFiles),
    maxDiffBytes: coercePositiveInteger(profile.maxDiffBytes)
  };
}

export function normalizeCodexCliReviewPolicy(value = {}) {
  const policy = value && typeof value === 'object' ? value : {};
  const profiles = policy.profiles && typeof policy.profiles === 'object' ? policy.profiles : {};
  const collaboration = policy.collaboration && typeof policy.collaboration === 'object' ? policy.collaboration : {};
  return {
    ...DEFAULT_CODEX_CLI_REVIEW_POLICY,
    ...policy,
    model: normalizeText(policy.model),
    distro: normalizeText(policy.distro) || DEFAULT_CODEX_CLI_REVIEW_POLICY.distro,
    executionPlane: normalizeText(policy.executionPlane) || DEFAULT_CODEX_CLI_REVIEW_POLICY.executionPlane,
    sandbox: normalizeText(policy.sandbox) || DEFAULT_CODEX_CLI_REVIEW_POLICY.sandbox,
    ephemeral: policy.ephemeral !== false,
    profiles: {
      preCommit: {
        ...DEFAULT_CODEX_CLI_REVIEW_POLICY.profiles.preCommit,
        ...normalizeProfilePolicy({
          ...DEFAULT_CODEX_CLI_REVIEW_POLICY.profiles.preCommit,
          ...profiles.preCommit
        })
      },
      daemon: {
        ...DEFAULT_CODEX_CLI_REVIEW_POLICY.profiles.daemon,
        ...normalizeProfilePolicy({
          ...DEFAULT_CODEX_CLI_REVIEW_POLICY.profiles.daemon,
          ...profiles.daemon
        })
      },
      prePush: {
        ...DEFAULT_CODEX_CLI_REVIEW_POLICY.profiles.prePush,
        ...normalizeProfilePolicy({
          ...DEFAULT_CODEX_CLI_REVIEW_POLICY.profiles.prePush,
          ...profiles.prePush
        })
      }
    },
    collaboration: {
      ...DEFAULT_CODEX_CLI_REVIEW_POLICY.collaboration,
      ...collaboration
    }
  };
}

export async function loadCodexCliReviewPolicy(repoRoot) {
  try {
    const raw = JSON.parse(await readFile(path.join(repoRoot, DELIVERY_AGENT_POLICY_PATH), 'utf8'));
    const localReviewLoop = raw?.localReviewLoop && typeof raw.localReviewLoop === 'object' ? raw.localReviewLoop : {};
    const config =
      localReviewLoop.codexCliReviewConfig && typeof localReviewLoop.codexCliReviewConfig === 'object'
        ? localReviewLoop.codexCliReviewConfig
        : {};
    return normalizeCodexCliReviewPolicy({
      ...config,
      enabled: localReviewLoop.codexCliReview === true && config.enabled !== false
    });
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return normalizeCodexCliReviewPolicy({});
    }
    throw error;
  }
}

function parseCodexJsonLines(raw) {
  const events = [];
  for (const line of normalizeText(raw).split(/\r?\n/)) {
    const trimmed = normalizeText(line);
    if (!trimmed) {
      continue;
    }
    try {
      events.push(JSON.parse(trimmed));
    } catch (error) {
      throw new Error(`Unable to parse Codex CLI JSONL event: ${error.message}`);
    }
  }

  const usage = [...events]
    .reverse()
    .find((event) => normalizeText(event?.type) === 'turn.completed')?.usage ?? {};
  const assistantContent = [...events]
    .reverse()
    .find((event) => normalizeText(event?.type) === 'item.completed' && normalizeText(event?.item?.type) === 'agent_message')
    ?.item?.text ?? '';

  return {
    events,
    usage: {
      inputTokens: Number.isInteger(usage?.input_tokens) ? usage.input_tokens : 0,
      cachedInputTokens: Number.isInteger(usage?.cached_input_tokens) ? usage.cached_input_tokens : 0,
      outputTokens: Number.isInteger(usage?.output_tokens) ? usage.output_tokens : 0
    },
    assistantContent: normalizeText(assistantContent)
  };
}

function buildArtifactPaths(resolvedReceiptPath) {
  const directory = path.dirname(resolvedReceiptPath);
  const stem = path.basename(resolvedReceiptPath, path.extname(resolvedReceiptPath));
  return {
    promptPath: path.join(directory, `${stem}.prompt.txt`),
    responsePath: path.join(directory, `${stem}.jsonl`),
    lastMessagePath: path.join(directory, `${stem}.last-message.json`),
    stderrPath: path.join(directory, `${stem}.stderr.txt`)
  };
}

async function readTextFileIfPresent(filePath) {
  try {
    return await readFile(filePath, 'utf8');
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return '';
    }
    throw error;
  }
}

function buildCodexReviewPrompt({ basePrompt, distro, executionPlane }) {
  return [
    'You are Codex CLI running inside the isolated personal/codex execution plane.',
    `- Execution plane: ${executionPlane}`,
    `- WSL distro: ${distro}`,
    '- The operator controls the Windows host plane separately; do not assume host-side session state.',
    '',
    basePrompt
  ].join('\n');
}

function resolveWslPath({ distro, windowsPath, repoRoot, runWslCommandFn = runWslCommand }) {
  const result = runWslCommandFn(distro, ['wslpath', '-a', windowsPath], { cwd: repoRoot, env: process.env });
  if (result.status !== 0 || !normalizeText(result.stdout)) {
    throw new Error(
      normalizeText(result.stderr) ||
      `Unable to convert Windows path to a WSL path for distro '${distro}': ${windowsPath}`
    );
  }
  return normalizeText(result.stdout);
}

export function resolveWslCodexRuntime({
  repoRoot,
  distro,
  runWslCommandFn = runWslCommand
}) {
  const statusResult = buildCommandResult(spawnSync('wsl.exe', ['--status'], {
    cwd: repoRoot,
    env: process.env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: DEFAULT_COPILOT_CLI_MAX_BUFFER_BYTES
  }));
  if (statusResult.status !== 0) {
    throw new Error(normalizeText(statusResult.stderr) || 'WSL2 is not available on the host.');
  }

  const codexPathResult = runWslCommandFn(distro, ['bash', '-lc', 'command -v codex'], {
    cwd: repoRoot,
    env: process.env
  });
  if (codexPathResult.status !== 0 || !normalizeText(codexPathResult.stdout)) {
    throw new Error(`Codex CLI is not available in WSL distro '${distro}'.`);
  }

  return {
    executionPlane: 'wsl2',
    distro,
    codexPath: normalizeText(codexPathResult.stdout)
  };
}

export async function runCodexCliReview({
  repoRoot,
  profile = 'daemon',
  receiptPath = '',
  stagedFiles = [],
  policy = null,
  runWslCommandFn = runWslCommand
}) {
  const normalizedPolicy = normalizeCodexCliReviewPolicy(policy ?? await loadCodexCliReviewPolicy(repoRoot));
  const profileName = normalizeProfileName(profile);
  const profilePolicy = normalizedPolicy.profiles[profileName];
  const resolvedReceiptPathInfo = resolveRepoPath(
    repoRoot,
    normalizeText(receiptPath) || profilePolicy.receiptPath
  );

  await mkdir(path.dirname(resolvedReceiptPathInfo.resolved), { recursive: true });
  const artifactPaths = buildArtifactPaths(resolvedReceiptPathInfo.resolved);
  const baseReceipt = {
    schema: CODEX_CLI_REVIEW_SCHEMA,
    generatedAt: toIso(),
    repoRoot,
    profile: profileName,
    mode: profilePolicy.mode,
    provider: 'codex-cli',
    executionPlane: normalizedPolicy.executionPlane,
    providerRuntime: 'codex-cli',
    collaboration: normalizedPolicy.collaboration,
    instructionSources: {
      present: [],
      missing: []
    },
    git: resolveRepoGitState(repoRoot),
    context: {
      selectedFiles: [],
      omittedFileCount: 0,
      diffBytes: 0,
      diffTruncated: false,
      baseRef: null
    },
    runtime: {
      distro: normalizedPolicy.distro,
      available: false,
      codexPath: null,
      wslRepoRoot: null
    },
    usage: {
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0
    },
    overall: {
      status: 'skipped',
      actionableFindingCount: 0,
      message: 'Codex CLI review skipped.',
      exitCode: 0
    },
    findings: [],
    artifacts: {
      receiptPath: resolvedReceiptPathInfo.normalized,
      promptPath: path.relative(repoRoot, artifactPaths.promptPath).replace(/\\/g, '/'),
      responsePath: path.relative(repoRoot, artifactPaths.responsePath).replace(/\\/g, '/'),
      lastMessagePath: path.relative(repoRoot, artifactPaths.lastMessagePath).replace(/\\/g, '/'),
      stderrPath: path.relative(repoRoot, artifactPaths.stderrPath).replace(/\\/g, '/')
    }
  };

  if (normalizedPolicy.enabled !== true || profilePolicy.enabled !== true) {
    await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(baseReceipt, null, 2)}\n`, 'utf8');
    return {
      providerId: 'codex-cli',
      status: 'skipped',
      reason: 'Codex CLI review is disabled by policy.',
      receiptPath: resolvedReceiptPathInfo.normalized,
      executionPlane: normalizedPolicy.executionPlane,
      providerRuntime: 'codex-cli',
      receipt: baseReceipt
    };
  }

  const instructionSources = await collectInstructionSources(repoRoot);
  const context = collectReviewContext({
    repoRoot,
    mode: profilePolicy.mode,
    stagedFiles,
    maxFiles: profilePolicy.maxFiles,
    maxDiffBytes: profilePolicy.maxDiffBytes
  });

  const receipt = {
    ...baseReceipt,
    instructionSources,
    git: context.git,
    context: {
      selectedFiles: context.selectedFiles,
      omittedFileCount: context.omittedFileCount,
      diffBytes: context.diffBytes,
      diffTruncated: context.diffTruncated,
      baseRef: context.baseRef
    }
  };

  if (context.selectedFiles.length === 0) {
    receipt.overall = {
      status: 'skipped',
      actionableFindingCount: 0,
      message: profilePolicy.mode === 'staged' ? 'No staged files selected for Codex CLI review.' : 'No changed files selected for Codex CLI review.',
      exitCode: 0
    };
    await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
    return {
      providerId: 'codex-cli',
      status: 'skipped',
      reason: receipt.overall.message,
      receiptPath: resolvedReceiptPathInfo.normalized,
      executionPlane: normalizedPolicy.executionPlane,
      providerRuntime: 'codex-cli',
      receipt
    };
  }

  let runtime;
  try {
    runtime = resolveWslCodexRuntime({
      repoRoot,
      distro: normalizedPolicy.distro,
      runWslCommandFn
    });
  } catch (error) {
    receipt.overall = {
      status: 'failed',
      actionableFindingCount: 0,
      message: normalizeText(error?.message) || `Unable to access WSL2 distro '${normalizedPolicy.distro}'.`,
      exitCode: 1
    };
    await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
    return {
      providerId: 'codex-cli',
      status: 'failed',
      reason: receipt.overall.message,
      receiptPath: resolvedReceiptPathInfo.normalized,
      executionPlane: normalizedPolicy.executionPlane,
      providerRuntime: 'codex-cli',
      receipt
    };
  }

  const prompt = buildCodexReviewPrompt({
    basePrompt: buildReviewPrompt({
      collaboration: normalizedPolicy.collaboration,
      context,
      instructionSources,
      profileName,
      repoRoot
    }),
    distro: runtime.distro,
    executionPlane: runtime.executionPlane
  });
  await writeFile(artifactPaths.promptPath, prompt, 'utf8');

  const wslRepoRoot = resolveWslPath({
    distro: runtime.distro,
    windowsPath: repoRoot,
    repoRoot,
    runWslCommandFn
  });
  const wslPromptPath = resolveWslPath({
    distro: runtime.distro,
    windowsPath: artifactPaths.promptPath,
    repoRoot,
    runWslCommandFn
  });
  const wslLastMessagePath = resolveWslPath({
    distro: runtime.distro,
    windowsPath: artifactPaths.lastMessagePath,
    repoRoot,
    runWslCommandFn
  });
  const wslJsonlPath = resolveWslPath({
    distro: runtime.distro,
    windowsPath: artifactPaths.responsePath,
    repoRoot,
    runWslCommandFn
  });
  const wslStderrPath = resolveWslPath({
    distro: runtime.distro,
    windowsPath: artifactPaths.stderrPath,
    repoRoot,
    runWslCommandFn
  });

  receipt.runtime = {
    distro: runtime.distro,
    available: true,
    codexPath: runtime.codexPath,
    wslRepoRoot
  };

  const shellScript = `
set -euo pipefail
REPO_ROOT="$1"
PROMPT_PATH="$2"
LAST_MESSAGE_PATH="$3"
JSONL_PATH="$4"
STDERR_PATH="$5"
CODEX_PATH="$6"
MODEL="$7"
SANDBOX_MODE="$8"
EPHEMERAL_FLAG="$9"

ARGS=(exec --json --color never -C "$REPO_ROOT" --output-last-message "$LAST_MESSAGE_PATH")
if [ -n "$MODEL" ]; then
  ARGS+=(-m "$MODEL")
fi
if [ -n "$SANDBOX_MODE" ]; then
  ARGS+=(-s "$SANDBOX_MODE")
fi
if [ "$EPHEMERAL_FLAG" = "1" ]; then
  ARGS+=(--ephemeral)
fi
"$CODEX_PATH" "\${ARGS[@]}" - < "$PROMPT_PATH" > "$JSONL_PATH" 2> "$STDERR_PATH"
`.trim();

  const commandResult = runWslCommandFn(
    runtime.distro,
    [
      'bash',
      '-lc',
      shellScript,
      'bash',
      wslRepoRoot,
      wslPromptPath,
      wslLastMessagePath,
      wslJsonlPath,
      wslStderrPath,
      runtime.codexPath,
      normalizeText(normalizedPolicy.model),
      normalizeText(normalizedPolicy.sandbox),
      normalizedPolicy.ephemeral === true ? '1' : '0'
    ],
    {
      cwd: repoRoot,
      env: process.env
    }
  );

  const lastMessage = await readTextFileIfPresent(artifactPaths.lastMessagePath);
  const jsonlText = await readTextFileIfPresent(artifactPaths.responsePath);
  const stderrText = await readTextFileIfPresent(artifactPaths.stderrPath);

  let structured = null;
  let parsedJsonl = null;
  let failureReason = '';
  try {
    parsedJsonl = parseCodexJsonLines(jsonlText);
    structured = parseStructuredAssistantPayload(lastMessage || parsedJsonl.assistantContent);
  } catch (error) {
    failureReason = normalizeText(error?.message);
  }

  if (commandResult.status !== 0) {
    failureReason =
      normalizeText(stderrText) ||
      normalizeText(commandResult.stderr) ||
      failureReason ||
      'Codex CLI review command failed.';
  }

  const actionableFindingCount = structured?.findings?.filter((finding) => finding.actionable !== false).length ?? 0;
  const overallStatus =
    failureReason || (actionableFindingCount > 0 && profilePolicy.failOnFindings !== false)
      ? 'failed'
      : 'passed';
  const overallMessage =
    failureReason ||
    structured?.summary ||
    (actionableFindingCount > 0
      ? `Codex CLI reported ${actionableFindingCount} actionable finding(s).`
      : 'Codex CLI review passed.');

  receipt.usage = parsedJsonl?.usage ?? receipt.usage;
  receipt.findings = structured?.findings ?? [];
  receipt.overall = {
    status: overallStatus,
    actionableFindingCount,
    message: overallMessage,
    exitCode: commandResult.status
  };

  await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
  return {
    providerId: 'codex-cli',
    status: overallStatus,
    reason: overallMessage,
    receiptPath: resolvedReceiptPathInfo.normalized,
    executionPlane: normalizedPolicy.executionPlane,
    providerRuntime: 'codex-cli',
    requestedModel: normalizeText(normalizedPolicy.model) || null,
    effectiveModel: normalizeText(normalizedPolicy.model) || null,
    inputTokens: receipt.usage.inputTokens,
    cachedInputTokens: receipt.usage.cachedInputTokens,
    outputTokens: receipt.usage.outputTokens,
    receipt
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repoRoot: process.cwd(),
    profile: 'daemon',
    receiptPath: '',
    stagedFiles: []
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    const value = args[index + 1];
    if (!value || value.startsWith('-')) {
      throw new Error(`Missing value for ${token}.`);
    }
    index += 1;
    if (token === '--repo-root') {
      options.repoRoot = value;
    } else if (token === '--profile') {
      options.profile = value;
    } else if (token === '--receipt-path') {
      options.receiptPath = value;
    } else if (token === '--staged-files-json') {
      options.stagedFiles = normalizeStringList(JSON.parse(value));
    } else {
      throw new Error(`Unknown option: ${token}`);
    }
  }

  return options;
}

function printUsage() {
  console.log('Usage: node tools/local-collab/providers/codex-cli-review.mjs [options]');
  console.log('');
  console.log('Run a deterministic WSL-backed Codex CLI review for a hook or daemon profile.');
  console.log('');
  console.log('Options:');
  console.log('  --repo-root <path>           Repository root (default: current working directory).');
  console.log('  --profile <name>             Review profile: pre-commit, daemon, or pre-push.');
  console.log('  --receipt-path <path>        Override the profile receipt path.');
  console.log('  --staged-files-json <json>   JSON array of staged repo-relative paths (pre-commit only).');
  console.log('  -h, --help                   Show help.');
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(error.message);
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  try {
    const result = await runCodexCliReview({
      repoRoot: path.resolve(options.repoRoot),
      profile: options.profile,
      receiptPath: options.receiptPath,
      stagedFiles: options.stagedFiles
    });
    console.log(JSON.stringify(result, null, 2));
    return result.status === 'failed' ? 1 : 0;
  } catch (error) {
    console.error(error?.stack || error?.message || String(error));
    return 1;
  }
}

if (isEntrypoint(import.meta.url)) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

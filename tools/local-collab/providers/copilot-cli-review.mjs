#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const COPILOT_CLI_REVIEW_SCHEMA = 'priority/copilot-cli-review@v1';
export const DELIVERY_AGENT_POLICY_PATH = path.join('tools', 'priority', 'delivery-agent.policy.json');
export const DEFAULT_COPILOT_CLI_MODEL = 'gpt-5.4';
export const DEFAULT_COPILOT_CLI_MAX_BUFFER_BYTES = 8 * 1024 * 1024;

export const DEFAULT_COPILOT_CLI_REVIEW_POLICY = {
  enabled: true,
  model: DEFAULT_COPILOT_CLI_MODEL,
  promptOnly: true,
  disableBuiltinMcps: true,
  allowAllTools: false,
  availableTools: '',
  sessionPolicy: {
    reuse: 'fresh-per-head',
    scope: 'current-head',
    recordPromptArtifacts: true
  },
  convergence: {
    minPasses: 2,
    maxPasses: 4,
    stopOnCleanPass: true,
    stopOnNoNovelFindingsCount: 2,
    promoteInstructionGapAfterRepeatedFindings: 2
  },
  profiles: {
    preCommit: {
      enabled: true,
      mode: 'staged',
      receiptPath: path.join('tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.json'),
      failOnFindings: true,
      maxFiles: 12,
      maxDiffBytes: 12 * 1024
    },
    daemon: {
      enabled: true,
      mode: 'head',
      receiptPath: path.join('tests', 'results', 'docker-tools-parity', 'copilot-cli-review', 'receipt.json'),
      failOnFindings: true,
      maxFiles: 24,
      maxDiffBytes: 16 * 1024
    },
    prePush: {
      enabled: true,
      mode: 'head',
      receiptPath: path.join('tests', 'results', '_hooks', 'pre-push-copilot-cli-review.json'),
      failOnFindings: true,
      maxFiles: 24,
      maxDiffBytes: 16 * 1024
    }
  },
  collaboration: {
    coordinationRemote: 'upstream',
    coordinationPersona: 'daemon',
    authoringRemote: 'personal',
    authoringPersona: 'codex',
    reviewRemote: 'origin',
    reviewPersona: 'copilot-cli'
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
    throw new Error(`Unsupported Copilot CLI review profile: ${value}`);
  }
  return normalized;
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

function readPathEntries(env = process.env) {
  const pathValue = env.Path ?? env.PATH ?? '';
  return pathValue
    .split(path.delimiter)
    .map((entry) => normalizeText(entry))
    .filter(Boolean);
}

function resolveWindowsCopilotBundle(shimPath) {
  const shimDirectory = path.dirname(shimPath);
  const loaderPath = path.join(shimDirectory, 'node_modules', '@github', 'copilot', 'npm-loader.js');
  if (!existsSync(loaderPath)) {
    return {
      resolutionError: `Unable to resolve the Copilot CLI npm loader beside '${shimPath}'.`
    };
  }

  const bundledNodePath = path.join(shimDirectory, 'node.exe');
  return {
    spawnCommand: existsSync(bundledNodePath) ? bundledNodePath : process.execPath,
    spawnArgsPrefix: [loaderPath],
    shell: false
  };
}

export function resolveCopilotCliCommand(platform = process.platform, env = process.env) {
  if (platform !== 'win32') {
    return {
      command: 'copilot',
      spawnCommand: 'copilot',
      spawnArgsPrefix: [],
      shell: false
    };
  }

  const resolutionErrors = [];
  for (const directory of readPathEntries(env)) {
    const shimPath = path.join(directory, 'copilot.cmd');
    if (existsSync(shimPath)) {
      const bundle = resolveWindowsCopilotBundle(shimPath);
      if (!normalizeText(bundle?.resolutionError)) {
        return {
          command: 'copilot.cmd',
          spawnCommand: bundle?.spawnCommand ?? null,
          spawnArgsPrefix: bundle?.spawnArgsPrefix ?? [],
          shell: bundle?.shell ?? false,
          resolutionError: ''
        };
      }
      resolutionErrors.push(bundle.resolutionError);
    }
  }

  return {
    command: 'copilot.cmd',
    spawnCommand: null,
    spawnArgsPrefix: [],
    shell: false,
    resolutionError: resolutionErrors[0] || 'Unable to resolve copilot.cmd on PATH without shell mediation.'
  };
}

function runCommand(command, args, { cwd, env, shell = false } = {}) {
  return buildCommandResult(
    spawnSync(command, args, {
      cwd,
      env,
      shell,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: DEFAULT_COPILOT_CLI_MAX_BUFFER_BYTES
    })
  );
}

function runGit(repoRoot, args, env = process.env) {
  return runCommand('git', ['-C', repoRoot, ...args], { cwd: repoRoot, env });
}

function buildMergeBaseCandidates(env = process.env) {
  const baseRef = normalizeText(env.VALIDATE_BASE_REF) || normalizeText(env.GITHUB_BASE_REF);
  const baseSha = normalizeText(env.VALIDATE_BASE_SHA) || normalizeText(env.GITHUB_BASE_SHA);
  const candidates = [];

  if (baseSha) {
    candidates.push(['merge-base', 'HEAD', baseSha]);
  }
  if (baseRef) {
    candidates.push(['merge-base', 'HEAD', `upstream/${baseRef}`]);
    candidates.push(['merge-base', 'HEAD', `origin/${baseRef}`]);
    candidates.push(['merge-base', 'HEAD', baseRef]);
  }
  candidates.push(['merge-base', 'HEAD', 'upstream/develop']);
  candidates.push(['merge-base', 'HEAD', 'origin/develop']);
  candidates.push(['rev-parse', 'HEAD~1']);
  return {
    baseSha,
    baseRef,
    candidates
  };
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

function truncateText(value, maxBytes) {
  const source = String(value ?? '');
  if (!source) {
    return {
      text: '',
      bytes: 0,
      truncated: false
    };
  }
  const buffer = Buffer.from(source, 'utf8');
  if (!Number.isInteger(maxBytes) || maxBytes <= 0 || buffer.length <= maxBytes) {
    return {
      text: source,
      bytes: buffer.length,
      truncated: false
    };
  }
  const truncatedBuffer = buffer.subarray(0, maxBytes);
  const truncatedText = truncatedBuffer.toString('utf8');
  return {
    text: `${truncatedText}\n\n[diff truncated by copilot-cli-review wrapper]`,
    bytes: buffer.length,
    truncated: true
  };
}

function parseCopilotJsonLines(raw) {
  const events = [];
  for (const line of normalizeText(raw).split(/\r?\n/)) {
    const trimmed = normalizeText(line);
    if (!trimmed) {
      continue;
    }
    try {
      events.push(JSON.parse(trimmed));
    } catch (error) {
      throw new Error(`Unable to parse Copilot CLI JSONL event: ${error.message}`);
    }
  }
  const model =
    events.find((event) => normalizeText(event?.type) === 'session.tools_updated')?.data?.model ??
    null;
  const assistantContent =
    [...events]
      .reverse()
      .find((event) => normalizeText(event?.type) === 'assistant.message')?.data?.content ??
    '';
  return {
    events,
    model: normalizeText(model) || null,
    assistantContent: normalizeText(assistantContent)
  };
}

function normalizeFinding(value) {
  const finding = value && typeof value === 'object' ? value : {};
  const severity = normalizeText(finding.severity).toLowerCase() || 'warning';
  return {
    severity: ['error', 'warning', 'note'].includes(severity) ? severity : 'warning',
    path: normalizeText(finding.path) || null,
    line: Number.isInteger(finding.line) && finding.line > 0 ? finding.line : null,
    title: normalizeText(finding.title) || 'Copilot CLI finding',
    body: normalizeText(finding.body) || '',
    actionable: finding.actionable !== false
  };
}

function parseStructuredAssistantPayload(assistantContent) {
  const trimmed = normalizeText(assistantContent);
  if (!trimmed) {
    throw new Error('Copilot CLI did not return an assistant message.');
  }
  let parsed;
  try {
    parsed = JSON.parse(trimmed);
  } catch (error) {
    throw new Error(`Copilot CLI assistant message was not valid JSON: ${error.message}`);
  }
  const findings = Array.isArray(parsed.findings) ? parsed.findings.map(normalizeFinding) : [];
  const status = normalizeText(parsed.status).toLowerCase() || (findings.length > 0 ? 'changes-requested' : 'approved');
  return {
    status: status === 'approved' ? 'approved' : 'changes-requested',
    summary: normalizeText(parsed.summary) || null,
    findings
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

function normalizeConvergencePolicy(value = {}) {
  const convergence = value && typeof value === 'object' ? value : {};
  const maxPasses = Math.max(coercePositiveInteger(convergence.maxPasses, 4), 1);
  const minPasses = Math.min(Math.max(coercePositiveInteger(convergence.minPasses, 1), 1), maxPasses);
  return {
    minPasses,
    maxPasses,
    stopOnCleanPass: convergence.stopOnCleanPass !== false,
    stopOnNoNovelFindingsCount: coercePositiveInteger(convergence.stopOnNoNovelFindingsCount, 2),
    promoteInstructionGapAfterRepeatedFindings: coercePositiveInteger(
      convergence.promoteInstructionGapAfterRepeatedFindings,
      2
    )
  };
}

function normalizeSessionPolicy(value = {}) {
  const session = value && typeof value === 'object' ? value : {};
  return {
    reuse:
      normalizeText(session.reuse).toLowerCase() === 'fresh-per-invocation'
        ? 'fresh-per-invocation'
        : 'fresh-per-head',
    scope:
      normalizeText(session.scope).toLowerCase() === 'current-diff'
        ? 'current-diff'
        : 'current-head',
    recordPromptArtifacts: session.recordPromptArtifacts !== false
  };
}

function resolveEffectiveConvergencePolicy(convergence, profileName) {
  const normalizedProfileName = normalizeProfileName(profileName);
  if (normalizedProfileName !== 'preCommit') {
    return { ...convergence };
  }

  // Pre-commit is the interactive hot path. Keep the wrapper inside the caller timeout budget.
  const maxPasses = 1;
  const minPasses = 1;
  return {
    ...convergence,
    minPasses,
    maxPasses
  };
}

export function normalizeCopilotCliReviewPolicy(value = {}) {
  const policy = value && typeof value === 'object' ? value : {};
  const profiles = policy.profiles && typeof policy.profiles === 'object' ? policy.profiles : {};
  const collaboration = policy.collaboration && typeof policy.collaboration === 'object' ? policy.collaboration : {};
  return {
    ...DEFAULT_COPILOT_CLI_REVIEW_POLICY,
    ...policy,
    model: normalizeText(policy.model) || DEFAULT_COPILOT_CLI_REVIEW_POLICY.model,
    promptOnly: policy.promptOnly !== false,
    disableBuiltinMcps: policy.disableBuiltinMcps !== false,
    allowAllTools: policy.allowAllTools === true,
    availableTools:
      policy.availableTools === ''
        ? ''
        : normalizeText(policy.availableTools) || DEFAULT_COPILOT_CLI_REVIEW_POLICY.availableTools,
    sessionPolicy: normalizeSessionPolicy({
      ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.sessionPolicy,
      ...(policy.sessionPolicy && typeof policy.sessionPolicy === 'object' ? policy.sessionPolicy : {})
    }),
    convergence: normalizeConvergencePolicy({
      ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.convergence,
      ...(policy.convergence && typeof policy.convergence === 'object' ? policy.convergence : {})
    }),
    profiles: {
      preCommit: {
        ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.preCommit,
        ...normalizeProfilePolicy({
          ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.preCommit,
          ...profiles.preCommit
        })
      },
      daemon: {
        ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.daemon,
        ...normalizeProfilePolicy({
          ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.daemon,
          ...profiles.daemon
        })
      },
      prePush: {
        ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.prePush,
        ...normalizeProfilePolicy({
          ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.prePush,
          ...profiles.prePush
        })
      }
    },
    collaboration: {
      ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration,
      ...collaboration,
      coordinationRemote:
        normalizeText(collaboration.coordinationRemote) ||
        DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration.coordinationRemote,
      coordinationPersona:
        normalizeText(collaboration.coordinationPersona) ||
        DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration.coordinationPersona,
      authoringRemote:
        normalizeText(collaboration.authoringRemote) ||
        DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration.authoringRemote,
      authoringPersona:
        normalizeText(collaboration.authoringPersona) ||
        DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration.authoringPersona,
      reviewRemote:
        normalizeText(collaboration.reviewRemote) ||
        DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration.reviewRemote,
      reviewPersona:
        normalizeText(collaboration.reviewPersona) ||
        DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration.reviewPersona
    }
  };
}

function normalizeFingerprintText(value) {
  return normalizeText(value).replace(/\s+/g, ' ').toLowerCase();
}

function buildFindingFingerprint(finding) {
  return [
    normalizeFingerprintText(finding.severity),
    normalizeFingerprintText(finding.path),
    Number.isInteger(finding.line) ? String(finding.line) : '',
    normalizeFingerprintText(finding.title),
    normalizeFingerprintText(finding.body).slice(0, 160)
  ].join('|');
}

function dedupeFindings(findings = []) {
  const unique = [];
  const seen = new Set();
  for (const finding of findings) {
    const fingerprint = buildFindingFingerprint(finding);
    if (seen.has(fingerprint)) {
      continue;
    }
    seen.add(fingerprint);
    unique.push({
      ...finding,
      fingerprint
    });
  }
  return unique;
}

export async function loadCopilotCliReviewPolicy(repoRoot) {
  try {
    const raw = JSON.parse(await readFile(path.join(repoRoot, DELIVERY_AGENT_POLICY_PATH), 'utf8'));
    const localReviewLoop = raw?.localReviewLoop && typeof raw.localReviewLoop === 'object' ? raw.localReviewLoop : {};
    const config =
      localReviewLoop.copilotCliReviewConfig && typeof localReviewLoop.copilotCliReviewConfig === 'object'
        ? localReviewLoop.copilotCliReviewConfig
        : {};
    return normalizeCopilotCliReviewPolicy({
      ...config,
      enabled: localReviewLoop.copilotCliReview !== false && config.enabled !== false
    });
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return normalizeCopilotCliReviewPolicy({});
    }
    throw error;
  }
}

export function resolveRepoGitState(repoRoot, runGitFn = runGit) {
  const head = runGitFn(repoRoot, ['rev-parse', 'HEAD']);
  const branch = runGitFn(repoRoot, ['branch', '--show-current']);
  const mergeBase = runGitFn(repoRoot, ['merge-base', 'HEAD', 'upstream/develop']);
  const dirty = runGitFn(repoRoot, ['status', '--short', '--untracked-files=no']);
  return {
    headSha: normalizeText(head.stdout) || null,
    branch: normalizeText(branch.stdout) || null,
    upstreamDevelopMergeBase: normalizeText(mergeBase.stdout) || null,
    dirtyTracked: normalizeText(dirty.stdout).length > 0
  };
}

function resolveMergeBase(repoRoot, env = process.env, runGitFn = runGit) {
  const { baseRef, baseSha, candidates } = buildMergeBaseCandidates(env);
  for (const candidate of candidates) {
    const result = runGitFn(repoRoot, candidate);
    if (result.status === 0 && normalizeText(result.stdout)) {
      return normalizeText(result.stdout);
    }
  }
  if (env.GITHUB_ACTIONS === 'true' && baseSha) {
    for (const remote of ['origin', 'upstream']) {
      const fetchResult = runGitFn(repoRoot, ['fetch', '--no-tags', '--prune', '--depth=1', remote, baseSha], env);
      if (fetchResult.status !== 0) {
        continue;
      }
      for (const candidate of [
        ['merge-base', 'HEAD', baseSha],
        ['merge-base', 'HEAD', 'FETCH_HEAD'],
        ['rev-parse', baseSha]
      ]) {
        const result = runGitFn(repoRoot, candidate, env);
        if (result.status === 0 && normalizeText(result.stdout)) {
          return normalizeText(result.stdout);
        }
      }
    }
  }
  if (baseRef && env.GITHUB_ACTIONS === 'true') {
    for (const remote of ['origin', 'upstream']) {
      const fetchResult = runGitFn(repoRoot, ['fetch', '--no-tags', '--prune', '--depth=1', remote, baseRef], env);
      if (fetchResult.status !== 0) {
        continue;
      }
      for (const candidate of [
        ['merge-base', 'HEAD', `refs/remotes/${remote}/${baseRef}`],
        ['merge-base', 'HEAD', 'FETCH_HEAD']
      ]) {
        const result = runGitFn(repoRoot, candidate, env);
        if (result.status === 0 && normalizeText(result.stdout)) {
          return normalizeText(result.stdout);
        }
      }
    }
  }
  return null;
}

function parseOptionalJsonArgument(raw) {
  const normalized = normalizeText(raw);
  if (!normalized) {
    return [];
  }
  if (normalized.startsWith('@')) {
    throw new Error('File-backed staged-files arguments are not supported; pass JSON directly.');
  }
  let parsed;
  try {
    parsed = JSON.parse(normalized);
  } catch (error) {
    throw new Error(`Unable to parse staged files JSON: ${error.message}`);
  }
  return normalizeStringList(parsed);
}

export async function collectInstructionSources(repoRoot) {
  const githubDir = path.join(repoRoot, '.github');
  const instructionsDir = path.join(githubDir, 'instructions');
  const present = [];
  const missing = [];

  const addPresent = (filePath) => {
    if (existsSync(filePath)) {
      present.push(path.relative(repoRoot, filePath).replace(/\\/g, '/'));
    } else {
      missing.push(path.relative(repoRoot, filePath).replace(/\\/g, '/'));
    }
  };

  addPresent(path.join(repoRoot, 'AGENTS.md'));
  addPresent(path.join(githubDir, 'copilot-instructions.md'));

  if (existsSync(instructionsDir)) {
    const entries = await readdir(instructionsDir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isFile() && entry.name.endsWith('.instructions.md')) {
        present.push(path.relative(repoRoot, path.join(instructionsDir, entry.name)).replace(/\\/g, '/'));
      }
    }
  }

  return {
    present: Array.from(new Set(present)).sort(),
    missing: Array.from(new Set(missing)).sort()
  };
}

export function collectReviewContext({
  repoRoot,
  mode,
  stagedFiles = [],
  maxFiles,
  maxDiffBytes,
  env = process.env,
  runGitFn = runGit
}) {
  const gitState = resolveRepoGitState(repoRoot, runGitFn);
  const normalizedMode = mode === 'staged' ? 'staged' : 'head';
  let changedFiles = [];
  let diffArgs = [];
  let baseRef = null;

  if (normalizedMode === 'staged') {
    if (stagedFiles.length > 0) {
      changedFiles = stagedFiles;
    } else {
      const stagedDiff = runGitFn(repoRoot, ['diff', '--cached', '--name-only', '--diff-filter=ACMRT'], env);
      if (stagedDiff.status !== 0) {
        throw new Error(normalizeText(stagedDiff.stderr) || 'Unable to collect staged files for Copilot CLI review.');
      }
      changedFiles = normalizeStringList(stagedDiff.stdout);
    }
    diffArgs = ['diff', '--cached', '--unified=3', '--no-ext-diff'];
  } else {
    baseRef = resolveMergeBase(repoRoot, env, runGitFn);
    if (!baseRef) {
      throw new Error('Unable to resolve a merge base for Copilot CLI review.');
    }
    const headDiff = runGitFn(repoRoot, ['diff', '--name-only', '--diff-filter=ACMRT', `${baseRef}..HEAD`], env);
    if (headDiff.status !== 0) {
      throw new Error(normalizeText(headDiff.stderr) || 'Unable to collect changed files for Copilot CLI review.');
    }
    changedFiles = normalizeStringList(headDiff.stdout);
    diffArgs = ['diff', '--unified=3', '--no-ext-diff', `${baseRef}..HEAD`];
  }

  const selectedFiles = changedFiles.slice(0, maxFiles);
  if (selectedFiles.length === 0) {
    return {
      mode: normalizedMode,
      git: gitState,
      baseRef,
      selectedFiles: [],
      omittedFileCount: 0,
      diffText: '',
      diffBytes: 0,
      diffTruncated: false
    };
  }

  const diffResult = runGitFn(repoRoot, [...diffArgs, '--', ...selectedFiles], env);
  if (diffResult.status !== 0) {
    throw new Error(normalizeText(diffResult.stderr) || 'Unable to compute review diff.');
  }
  const diff = truncateText(diffResult.stdout, maxDiffBytes);
  return {
    mode: normalizedMode,
    git: gitState,
    baseRef,
    selectedFiles,
    omittedFileCount: Math.max(changedFiles.length - selectedFiles.length, 0),
    diffText: diff.text,
    diffBytes: diff.bytes,
    diffTruncated: diff.truncated
  };
}

export function buildReviewPrompt({
  collaboration,
  context,
  instructionSources,
  profileName,
  repoRoot
}) {
  const selectedFiles = context.selectedFiles.map((entry) => `- ${entry}`).join('\n') || '- none';
  const promptSections = [
    'You are performing a deterministic local code review for compare-vi-cli-action.',
    '',
    'Review contract:',
    `- Profile: ${profileName}`,
    `- Repository root: ${repoRoot}`,
    `- Review mode: ${context.mode}`,
    `- Coordination plane: ${collaboration.coordinationRemote} (${collaboration.coordinationPersona})`,
    `- Authoring plane: ${collaboration.authoringRemote} (${collaboration.authoringPersona})`,
    `- Review plane: ${collaboration.reviewRemote} (${collaboration.reviewPersona})`,
    `- Head SHA: ${context.git.headSha || 'unknown'}`,
    `- Branch: ${context.git.branch || 'unknown'}`,
    `- Merge base: ${context.baseRef || context.git.upstreamDevelopMergeBase || 'n/a'}`,
    '',
    'Instruction sources detected:',
    ...(instructionSources.present.length > 0 ? instructionSources.present.map((entry) => `- ${entry}`) : ['- none']),
    '',
    'Instruction sources missing:',
    ...(instructionSources.missing.length > 0 ? instructionSources.missing.map((entry) => `- ${entry}`) : ['- none']),
    '',
    'Changed files selected for review:',
    selectedFiles,
    context.omittedFileCount > 0 ? `- omitted additional files: ${context.omittedFileCount}` : '',
    context.diffTruncated ? `- diff truncated after ${context.diffBytes} UTF-8 bytes` : '',
    '',
    'Review focus:',
    '- correctness and deterministic behavior',
    '- hook / daemon / local-review contract safety',
    '- draft-review versus ready-validation semantics',
    '- regressions that would waste repeated GitHub Actions cycles',
    '',
    'Return exactly one JSON object with this shape and nothing else:',
    '{',
    '  "status": "approved" | "changes-requested",',
    '  "summary": "one-line review summary",',
    '  "findings": [',
    '    {',
    '      "severity": "error" | "warning" | "note",',
    '      "path": "repo-relative path or null",',
    '      "line": 123 | null,',
    '      "title": "short finding title",',
    '      "body": "specific actionable explanation",',
    '      "actionable": true | false',
    '    }',
    '  ]',
    '}',
    '',
    'If there are no actionable findings, set "status" to "approved" and "findings" to [].',
    'Do not ask questions. Review only the supplied diff/context.',
    '',
    'Diff to review:',
    context.diffText || '[no diff selected]'
  ].filter(Boolean);
  return promptSections.join('\n');
}

function buildArtifactPaths(resolvedReceiptPath) {
  const directory = path.dirname(resolvedReceiptPath);
  const stem = path.basename(resolvedReceiptPath, path.extname(resolvedReceiptPath));
  return {
    promptPath: path.join(directory, `${stem}.prompt.txt`),
    responsePath: path.join(directory, `${stem}.jsonl`),
    responsePathForPass(passNumber) {
      return path.join(directory, `${stem}.pass-${passNumber}.jsonl`);
    }
  };
}

export async function runCopilotCliReview({
  repoRoot,
  profile = 'daemon',
  receiptPath = '',
  stagedFiles = [],
  policy = null,
  runCommandFn = runCommand
}) {
  const normalizedPolicy = normalizeCopilotCliReviewPolicy(policy ?? await loadCopilotCliReviewPolicy(repoRoot));
  const profileName = normalizeProfileName(profile);
  const profilePolicy = normalizedPolicy.profiles[profileName];
  const effectiveConvergence = resolveEffectiveConvergencePolicy(normalizedPolicy.convergence, profileName);
  const resolvedReceiptPathInfo = resolveRepoPath(
    repoRoot,
    normalizeText(receiptPath) || profilePolicy.receiptPath
  );

  await mkdir(path.dirname(resolvedReceiptPathInfo.resolved), { recursive: true });
  const artifactPaths = buildArtifactPaths(resolvedReceiptPathInfo.resolved);

  const baseReceipt = {
    schema: COPILOT_CLI_REVIEW_SCHEMA,
    generatedAt: toIso(),
    repoRoot,
    profile: profileName,
    mode: profilePolicy.mode,
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
    copilot: {
      executed: false,
      model: normalizedPolicy.model,
      command: 'copilot',
      promptOnly: normalizedPolicy.promptOnly === true,
      disableBuiltinMcps: normalizedPolicy.disableBuiltinMcps === true,
      allowAllTools: normalizedPolicy.allowAllTools === true,
      availableTools: normalizedPolicy.availableTools,
      exitCode: null
    },
    permissionPolicy: {
      promptOnly: normalizedPolicy.promptOnly === true,
      disableBuiltinMcps: normalizedPolicy.disableBuiltinMcps === true,
      allowAllTools: normalizedPolicy.allowAllTools === true,
      availableTools: normalizedPolicy.availableTools
    },
    sessionPolicy: {
      ...normalizedPolicy.sessionPolicy,
      reusedPriorSession: false,
      checkpointKey: null
    },
    convergence: {
      ...effectiveConvergence,
      passCount: 0,
      stoppedReason: 'not-started',
      noNovelFindingStreak: 0,
      cleanPassCount: 0,
      instructionGapCandidate: false,
      instructionGapReason: '',
      repeatedFindingFingerprints: []
    },
    overall: {
      status: 'skipped',
      actionableFindingCount: 0,
      message: 'Copilot CLI review skipped.',
      exitCode: 0
    },
    findings: [],
    passes: [],
    artifacts: {
      receiptPath: resolvedReceiptPathInfo.normalized,
      promptPath: path.relative(repoRoot, artifactPaths.promptPath).replace(/\\/g, '/'),
      responsePath: path.relative(repoRoot, artifactPaths.responsePath).replace(/\\/g, '/')
    }
  };

  if (normalizedPolicy.enabled !== true || profilePolicy.enabled !== true) {
    await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(baseReceipt, null, 2)}\n`, 'utf8');
    return {
      status: 'skipped',
      reason: 'Copilot CLI review is disabled by policy.',
      receiptPath: resolvedReceiptPathInfo.normalized,
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
      message: profilePolicy.mode === 'staged' ? 'No staged files selected for Copilot CLI review.' : 'No changed files selected for Copilot CLI review.',
      exitCode: 0
    };
    await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
    return {
      status: 'skipped',
      reason: receipt.overall.message,
      receiptPath: resolvedReceiptPathInfo.normalized,
      receipt
    };
  }

  const prompt = buildReviewPrompt({
    collaboration: normalizedPolicy.collaboration,
    context,
    instructionSources,
    profileName,
    repoRoot
  });
  receipt.sessionPolicy = {
    ...receipt.sessionPolicy,
    checkpointKey: `${profileName}:${context.git.headSha || 'unknown'}:${context.baseRef || 'none'}`
  };
  await writeFile(artifactPaths.promptPath, prompt, 'utf8');

  const args = [
    '--output-format',
    'json',
    '--stream',
    'off',
    '--no-ask-user'
  ];
    if (normalizedPolicy.allowAllTools === true) {
      args.push('--allow-all-tools');
    }
    if (normalizedPolicy.availableTools === '') {
      args.push('--available-tools=');
    } else if (normalizeText(normalizedPolicy.availableTools)) {
      args.push('--available-tools', normalizedPolicy.availableTools);
    }
    if (normalizedPolicy.disableBuiltinMcps === true) {
      args.push('--disable-builtin-mcps');
    }
  if (normalizeText(normalizedPolicy.model)) {
    args.push('--model', normalizedPolicy.model);
  }
  args.push('--prompt', prompt);
  const copilotInvocation = resolveCopilotCliCommand(process.platform, process.env);
  if (normalizeText(copilotInvocation.resolutionError)) {
    receipt.copilot = {
      ...receipt.copilot,
      command: copilotInvocation.command,
      shell: copilotInvocation.shell
    };
    receipt.overall = {
      status: 'failed',
      actionableFindingCount: 0,
      message: copilotInvocation.resolutionError,
      exitCode: 1
    };
    await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
    return {
      status: 'failed',
      reason: copilotInvocation.resolutionError,
      receiptPath: resolvedReceiptPathInfo.normalized,
      receipt
    };
  }
  const aggregatedFindings = [];
  const findingOccurrences = new Map();
  let noNovelFindingStreak = 0;
  let cleanPassCount = 0;
  let stoppedReason = 'max-passes';
  let failureReason = '';
  let lastPassExitCode = 0;

  for (let passIndex = 1; passIndex <= effectiveConvergence.maxPasses; passIndex += 1) {
    const startedAt = new Date();
    const commandResult = buildCommandResult(
      await runCommandFn(copilotInvocation.spawnCommand, [...(copilotInvocation.spawnArgsPrefix ?? []), ...args], {
        cwd: repoRoot,
        env: process.env,
        shell: copilotInvocation.shell
      })
    );
    lastPassExitCode = commandResult.status;
    const passResponsePath = artifactPaths.responsePathForPass(passIndex);
    await writeFile(passResponsePath, `${commandResult.stdout}\n`, 'utf8');
    if (passIndex === 1) {
      await writeFile(artifactPaths.responsePath, `${commandResult.stdout}\n`, 'utf8');
    }

    let structured = null;
    let parsedJsonl = null;
    let passFailureReason = '';
    try {
      parsedJsonl = parseCopilotJsonLines(commandResult.stdout);
      receipt.copilot.model = parsedJsonl.model || receipt.copilot.model;
      structured = parseStructuredAssistantPayload(parsedJsonl.assistantContent);
    } catch (error) {
      passFailureReason = normalizeText(error?.message);
    }

    if (commandResult.status !== 0) {
      passFailureReason =
        normalizeText(commandResult.stderr) ||
        normalizeText(commandResult.stdout) ||
        passFailureReason ||
        'Copilot CLI review command failed.';
    }

    const passFindings = dedupeFindings(structured?.findings ?? []);
    const passActionableFindings = passFindings.filter((entry) => entry.actionable !== false);
    const novelActionableFindings = [];
    const repeatedActionableFingerprints = [];

    for (const finding of passActionableFindings) {
      if (!findingOccurrences.has(finding.fingerprint)) {
        novelActionableFindings.push(finding);
        aggregatedFindings.push(finding);
        findingOccurrences.set(finding.fingerprint, 1);
      } else {
        repeatedActionableFingerprints.push(finding.fingerprint);
        findingOccurrences.set(finding.fingerprint, findingOccurrences.get(finding.fingerprint) + 1);
      }
    }

    if (passActionableFindings.length === 0) {
      cleanPassCount += 1;
      noNovelFindingStreak = 0;
    } else if (novelActionableFindings.length === 0) {
      noNovelFindingStreak += 1;
    } else {
      noNovelFindingStreak = 0;
    }

    receipt.passes.push({
      passNumber: passIndex,
      startedAt: toIso(startedAt),
      completedAt: toIso(),
      durationMs: Math.max(Date.now() - startedAt.getTime(), 0),
      status:
        passFailureReason
          ? 'failed'
          : structured?.status === 'approved' && passActionableFindings.length === 0
            ? 'approved'
            : 'changes-requested',
      summary:
        passFailureReason ||
        structured?.summary ||
        (passActionableFindings.length === 0
          ? 'Copilot CLI review reported no actionable findings.'
          : 'Copilot CLI review reported actionable findings.'),
      actionableFindingCount: passActionableFindings.length,
      novelActionableFindingCount: novelActionableFindings.length,
      noNovelFindingStreak,
      repeatedActionableFingerprints,
      model: receipt.copilot.model,
      responsePath: path.relative(repoRoot, passResponsePath).replace(/\\/g, '/'),
      findings: passFindings
    });

    if (passFailureReason) {
      failureReason = passFailureReason;
      stoppedReason = 'command-failed';
      break;
    }

    const currentUnionActionableCount = aggregatedFindings.length;
    if (
      currentUnionActionableCount === 0 &&
      effectiveConvergence.stopOnCleanPass === true &&
      passIndex >= effectiveConvergence.minPasses
    ) {
      stoppedReason = 'clean-pass';
      break;
    }

    if (
      currentUnionActionableCount > 0 &&
      effectiveConvergence.stopOnNoNovelFindingsCount > 0 &&
      noNovelFindingStreak >= effectiveConvergence.stopOnNoNovelFindingsCount
    ) {
      stoppedReason = 'no-novel-findings';
      break;
    }
  }

  receipt.copilot = {
    ...receipt.copilot,
    executed: receipt.passes.length > 0,
    command: copilotInvocation.command,
    shell: copilotInvocation.shell,
    exitCode: lastPassExitCode
  };

  const repeatedFindingFingerprints = [...findingOccurrences.entries()]
    .filter(([, count]) => count >= effectiveConvergence.promoteInstructionGapAfterRepeatedFindings)
    .map(([fingerprint]) => fingerprint)
    .sort();
  const instructionGapCandidate =
    aggregatedFindings.length > 0 &&
    repeatedFindingFingerprints.length > 0 &&
    (stoppedReason === 'no-novel-findings' || stoppedReason === 'max-passes');
  const instructionGapReason = instructionGapCandidate
    ? 'Repeated local Copilot CLI findings converged without novel issues; refine Codex/Copilot instruction surfaces.'
    : '';

  const findingsShouldFail = profilePolicy.failOnFindings !== false;
  const overallStatus =
    failureReason || (aggregatedFindings.length > 0 && findingsShouldFail)
      ? 'failed'
      : 'passed';
  const overallMessage =
    failureReason ||
    (aggregatedFindings.length > 0
      ? findingsShouldFail
        ? `Copilot CLI review reported ${aggregatedFindings.length} unique actionable finding(s) across ${receipt.passes.length} pass(es).`
        : `Copilot CLI review recorded ${aggregatedFindings.length} unique actionable finding(s) across ${receipt.passes.length} pass(es) in report-only mode.`
      : `Copilot CLI review converged cleanly after ${receipt.passes.length} pass(es).`);

  receipt.findings = aggregatedFindings.map(({ fingerprint, ...finding }) => finding);
  receipt.convergence = {
    ...receipt.convergence,
    passCount: receipt.passes.length,
    stoppedReason,
    noNovelFindingStreak,
    cleanPassCount,
    instructionGapCandidate,
    instructionGapReason,
    repeatedFindingFingerprints
  };
  receipt.overall = {
    status: overallStatus,
    actionableFindingCount: aggregatedFindings.length,
    message: overallMessage,
    exitCode: lastPassExitCode
  };
  await writeFile(resolvedReceiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
  return {
    status: overallStatus,
    reason: overallMessage,
    receiptPath: resolvedReceiptPathInfo.normalized,
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

  const valueHandlers = new Map([
    ['--repo-root', (value) => { options.repoRoot = value; }],
    ['--profile', (value) => { options.profile = value; }],
    ['--receipt-path', (value) => { options.receiptPath = value; }],
    ['--staged-files-json', (value) => { options.stagedFiles = parseOptionalJsonArgument(value); }]
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (!valueHandlers.has(token)) {
      throw new Error(`Unknown option: ${token}`);
    }
    const value = args[index + 1];
    if (!value || value.startsWith('-')) {
      throw new Error(`Missing value for ${token}.`);
    }
    index += 1;
    valueHandlers.get(token)(value);
  }

  return options;
}

function printUsage() {
  console.log('Usage: node tools/local-collab/providers/copilot-cli-review.mjs [options]');
  console.log('');
  console.log('Run a deterministic local Copilot CLI review for a hook or daemon profile.');
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
    const result = await runCopilotCliReview({
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

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

#!/usr/bin/env node

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function sanitizeSegment(value, fallback = 'runtime') {
  const normalized = normalizeText(value)
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase();
  return normalized || fallback;
}

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

async function writeJson(filePath, payload) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function runCommand(command, args, { cwd, env, input } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    env,
    input,
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe']
  });
  return {
    status: result.status ?? 0,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? ''
  };
}

export function buildUnattendedCommandEnv(baseEnv = process.env) {
  const env = { ...baseEnv };
  if (!normalizeText(env.GIT_TERMINAL_PROMPT)) {
    env.GIT_TERMINAL_PROMPT = '0';
  }
  if (!normalizeText(env.GH_PROMPT_DISABLED)) {
    env.GH_PROMPT_DISABLED = '1';
  }
  if (!normalizeText(env.GCM_INTERACTIVE)) {
    env.GCM_INTERACTIVE = 'Never';
  }
  return env;
}

function resolveWorkDir(taskPacket, repoRoot) {
  const candidate = normalizeText(taskPacket?.evidence?.lane?.workerCheckoutPath);
  if (candidate) {
    return candidate;
  }
  return repoRoot;
}

function buildCodexOutputSchema() {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    type: 'object',
    additionalProperties: false,
    required: [
      'status',
      'outcome',
      'reason',
      'laneLifecycle',
      'blockerClass',
      'retryable',
      'nextWakeCondition',
      'helperCallsExecuted',
      'filesTouched',
      'pullRequestUrl',
      'notes'
    ],
    properties: {
      status: {
        enum: ['completed', 'blocked']
      },
      outcome: {
        type: 'string',
        minLength: 1
      },
      reason: {
        type: 'string',
        minLength: 1
      },
      laneLifecycle: {
        enum: [
          'planning',
          'reshaping-backlog',
          'coding',
          'waiting-ci',
          'waiting-review',
          'ready-merge',
          'blocked',
          'complete',
          'idle'
        ]
      },
      blockerClass: {
        type: 'string',
        minLength: 1
      },
      retryable: {
        type: 'boolean'
      },
      nextWakeCondition: {
        type: ['string', 'null']
      },
      helperCallsExecuted: {
        type: 'array',
        items: {
          type: 'string'
        }
      },
      filesTouched: {
        type: 'array',
        items: {
          type: 'string'
        }
      },
      pullRequestUrl: {
        type: ['string', 'null']
      },
      notes: {
        type: ['string', 'null']
      }
    }
  };
}

export function buildCodexTurnPrompt({ taskPacket, repoRoot, workDir }) {
  const objective = normalizeText(taskPacket?.objective?.summary) || 'Advance the active delivery lane.';
  const issueNumber = taskPacket?.evidence?.delivery?.selectedIssue?.number ?? taskPacket?.issue ?? null;
  const standingIssueNumber = taskPacket?.evidence?.delivery?.standingIssue?.number ?? null;
  const branchName = normalizeText(taskPacket?.branch?.name);
  const repository = normalizeText(taskPacket?.repository);
  const preferredHelpers = Array.isArray(taskPacket?.helperSurface?.preferred)
    ? taskPacket.helperSurface.preferred.filter((entry) => normalizeText(entry))
    : [];
  const fallbackHelpers = Array.isArray(taskPacket?.helperSurface?.fallbacks)
    ? taskPacket.helperSurface.fallbacks.filter((entry) => normalizeText(entry))
    : [];
  const relevantFiles = Array.isArray(taskPacket?.evidence?.delivery?.relevantFiles)
    ? taskPacket.evidence.delivery.relevantFiles.filter((entry) => normalizeText(entry))
    : [];
  const turnBudget = taskPacket?.evidence?.delivery?.turnBudget ?? {};
  const pullRequestUrl = normalizeText(taskPacket?.pullRequest?.url || taskPacket?.evidence?.delivery?.pullRequest?.url);

  return [
    'You are running one unattended delivery turn for compare-vi-cli-action.',
    '',
    'Execution contract:',
    `- Repository: ${repository || 'unknown'}`,
    `- Working directory: ${workDir}`,
    `- Repo root: ${repoRoot}`,
    `- Objective: ${objective}`,
    `- Selected issue: ${issueNumber ? `#${issueNumber}` : 'unknown'}`,
    `- Standing issue/epic: ${standingIssueNumber ? `#${standingIssueNumber}` : 'unknown'}`,
    `- Branch: ${branchName || 'unknown'}`,
    `- Existing PR: ${pullRequestUrl || 'none'}`,
    `- Max minutes: ${Number.isInteger(turnBudget.maxMinutes) ? turnBudget.maxMinutes : 20}`,
    `- Max tool calls: ${Number.isInteger(turnBudget.maxToolCalls) ? turnBudget.maxToolCalls : 12}`,
    '',
    'Hard rules:',
    '- Work only inside the active worker checkout.',
    '- Prefer checked-in repo helpers over raw GitHub commands.',
    '- Do not mutate branch protection, repo policy/rulesets, or release-admin surfaces.',
    '- Keep the turn bounded to one deliverable increment or one explicit blocker diagnosis.',
    '- If you make implementation progress, run focused validation, commit with the issue number in the subject, push the lane branch, and open or update the PR if needed.',
    '- If a PR already exists, update the branch and leave the lane ready for CI.',
    '- If you are blocked, stop and report the blocker directly; do not claim success.',
    '',
    'Preferred helpers:',
    ...(preferredHelpers.length > 0 ? preferredHelpers.map((entry) => `- ${entry}`) : ['- none provided']),
    '',
    'Fallback helpers:',
    ...(fallbackHelpers.length > 0 ? fallbackHelpers.map((entry) => `- ${entry}`) : ['- none provided']),
    '',
    'Relevant files:',
    ...(relevantFiles.length > 0 ? relevantFiles.map((entry) => `- ${entry}`) : ['- none provided']),
    '',
    'Finish by returning only JSON that matches the supplied schema.',
    'The JSON should describe the actual state after your work, including whether the lane is now blocked, still coding, waiting on CI, or complete.'
  ].join('\n');
}

function parseJsonOrNull(text) {
  const trimmed = normalizeText(text);
  if (!trimmed) {
    return null;
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

function classifyFailureMessage(message) {
  const normalized = normalizeText(message).toLowerCase();
  if (!normalized) {
    return {
      blockerClass: 'helperbug',
      outcome: 'codex-command-failed',
      retryable: false,
      nextWakeCondition: 'codex-command-fixed'
    };
  }
  if (normalized.includes('rate limit') || normalized.includes('429')) {
    return {
      blockerClass: 'rate-limit',
      outcome: 'rate-limit',
      retryable: true,
      nextWakeCondition: 'github-rate-limit-reset'
    };
  }
  if (normalized.includes('login') || normalized.includes('auth') || normalized.includes('credential')) {
    return {
      blockerClass: 'scope',
      outcome: 'codex-auth-required',
      retryable: false,
      nextWakeCondition: 'codex-auth-available'
    };
  }
  return {
    blockerClass: 'helperbug',
    outcome: 'codex-command-failed',
    retryable: false,
    nextWakeCondition: 'codex-command-fixed'
  };
}

function gitStdout(workDir, args, env = process.env) {
  const result = runCommand('git', args, { cwd: workDir, env });
  if (result.status !== 0) {
    return '';
  }
  return normalizeText(result.stdout);
}

function collectFilesTouched(workDir, startHead, endHead, env = process.env) {
  const touched = new Set();
  if (startHead && endHead && startHead !== endHead) {
    const diffNames = gitStdout(workDir, ['diff', '--name-only', `${startHead}..${endHead}`], env);
    for (const entry of diffNames.split(/\r?\n/)) {
      const normalized = normalizeText(entry);
      if (normalized) {
        touched.add(normalized);
      }
    }
  }
  const statusOutput = gitStdout(workDir, ['status', '--short'], env);
  for (const line of statusOutput.split(/\r?\n/)) {
    const normalized = normalizeText(line);
    if (!normalized) {
      continue;
    }
    const candidate = normalized.slice(3).trim();
    if (candidate) {
      touched.add(candidate);
    }
  }
  return Array.from(touched).sort();
}

function findPullRequest({ repository, branch, workDir, env = process.env }) {
  if (!normalizeText(repository) || !normalizeText(branch)) {
    return null;
  }
  const result = runCommand(
    'gh',
    ['pr', 'list', '--repo', repository, '--head', branch, '--limit', '1', '--json', 'number,url,state,isDraft'],
    { cwd: workDir, env }
  );
  if (result.status !== 0) {
    return null;
  }
  const parsed = parseJsonOrNull(result.stdout);
  return Array.isArray(parsed) && parsed.length > 0 ? parsed[0] : null;
}

function buildExecutionReceipt({
  taskPacket,
  codexResult,
  codexCommand,
  filesTouched,
  startHead,
  endHead,
  branchName,
  pullRequest,
  artifacts,
  failure
}) {
  const issueNumber = taskPacket?.evidence?.delivery?.selectedIssue?.number ?? taskPacket?.issue ?? null;
  const helperCallsExecuted = [
    codexCommand,
    ...(Array.isArray(codexResult?.helperCallsExecuted) ? codexResult.helperCallsExecuted : [])
  ];
  const pullRequestUrl =
    normalizeText(codexResult?.pullRequestUrl) ||
    normalizeText(pullRequest?.url) ||
    normalizeText(taskPacket?.pullRequest?.url) ||
    null;
  const effectiveFilesTouched = Array.isArray(codexResult?.filesTouched) && codexResult.filesTouched.length > 0
    ? Array.from(new Set([...filesTouched, ...codexResult.filesTouched.map((entry) => normalizeText(entry)).filter(Boolean)])).sort()
    : filesTouched;

  if (failure) {
    return {
      schema: 'priority/runtime-execution-receipt@v1',
      generatedAt: toIso(),
      runtimeAdapter: 'comparevi',
      repository: normalizeText(taskPacket?.repository) || null,
      laneId: normalizeText(taskPacket?.laneId) || null,
      issue: Number.isInteger(issueNumber) ? issueNumber : null,
      status: 'blocked',
      outcome: failure.outcome,
      reason: failure.reason,
      source: 'codex-delivery-turn-runner',
      stopLoop: false,
      details: {
        actionType: 'execute-coding-turn',
        laneLifecycle: 'blocked',
        blockerClass: failure.blockerClass,
        retryable: failure.retryable,
        nextWakeCondition: failure.nextWakeCondition,
        helperCallsExecuted,
        filesTouched: effectiveFilesTouched,
        branch: branchName || null,
        startHead: startHead || null,
        endHead: endHead || null,
        pullRequestUrl
      },
      artifacts
    };
  }

  let laneLifecycle = normalizeText(codexResult?.laneLifecycle) || 'coding';
  if (pullRequestUrl && laneLifecycle === 'coding') {
    laneLifecycle = 'waiting-ci';
  }
  const blockerClass = normalizeText(codexResult?.blockerClass) || (laneLifecycle === 'blocked' ? 'scope' : 'none');
  const status = normalizeText(codexResult?.status) || (laneLifecycle === 'blocked' ? 'blocked' : 'completed');

  return {
    schema: 'priority/runtime-execution-receipt@v1',
    generatedAt: toIso(),
    runtimeAdapter: 'comparevi',
    repository: normalizeText(taskPacket?.repository) || null,
    laneId: normalizeText(taskPacket?.laneId) || null,
    issue: Number.isInteger(issueNumber) ? issueNumber : null,
    status,
    outcome: normalizeText(codexResult?.outcome) || 'coding-command-finished',
    reason: normalizeText(codexResult?.reason) || 'Codex delivery turn completed.',
    source: 'codex-delivery-turn-runner',
    stopLoop: false,
    details: {
      actionType: 'execute-coding-turn',
      laneLifecycle,
      blockerClass,
      retryable: Boolean(codexResult?.retryable),
      nextWakeCondition: codexResult?.nextWakeCondition ?? (pullRequestUrl ? 'checks-green' : 'scheduler-rescan'),
      helperCallsExecuted,
      filesTouched: effectiveFilesTouched,
      branch: branchName || null,
      startHead: startHead || null,
      endHead: endHead || null,
      pullRequestUrl,
      notes: normalizeText(codexResult?.notes) || null
    },
    artifacts
  };
}

export async function runCodexDeliveryTurn({ taskPacketPath, receiptPath, repoRoot }) {
  const effectiveRepoRoot = normalizeText(repoRoot) || process.cwd();
  const packet = await readJson(taskPacketPath);
  const workDir = resolveWorkDir(packet, effectiveRepoRoot);
  const runtimeArtifactsRoot = path.join(effectiveRepoRoot, 'tests', 'results', '_agent', 'runtime', 'codex-turns');
  const runId = `${toIso().replace(/[:.]/g, '-')}-${sanitizeSegment(packet.laneId, 'lane')}`;
  const artifactDir = path.join(runtimeArtifactsRoot, runId);
  await mkdir(artifactDir, { recursive: true });

  const promptPath = path.join(artifactDir, 'prompt.txt');
  const schemaPath = path.join(artifactDir, 'output-schema.json');
  const lastMessagePath = path.join(artifactDir, 'last-message.json');
  const stdoutPath = path.join(artifactDir, 'stdout.jsonl');
  const stderrPath = path.join(artifactDir, 'stderr.txt');

  const prompt = buildCodexTurnPrompt({ taskPacket: packet, repoRoot: effectiveRepoRoot, workDir });
  const schema = buildCodexOutputSchema();
  await writeFile(promptPath, `${prompt}\n`, 'utf8');
  await writeJson(schemaPath, schema);
  const unattendedEnv = buildUnattendedCommandEnv(process.env);

  const startHead = gitStdout(workDir, ['rev-parse', 'HEAD'], unattendedEnv);
  const branchName = gitStdout(workDir, ['branch', '--show-current'], unattendedEnv);
  const codexArgs = [
    'exec',
    '--json',
    '--color',
    'never',
    '--cd',
    workDir,
    '--dangerously-bypass-approvals-and-sandbox',
    '--output-schema',
    schemaPath,
    '-o',
    lastMessagePath,
    '-'
  ];
  const codexResult = runCommand('codex', codexArgs, {
    cwd: workDir,
    env: unattendedEnv,
    input: prompt
  });
  await writeFile(stdoutPath, codexResult.stdout || '', 'utf8');
  await writeFile(stderrPath, codexResult.stderr || '', 'utf8');

  const endHead = gitStdout(workDir, ['rev-parse', 'HEAD'], unattendedEnv);
  const filesTouched = collectFilesTouched(workDir, startHead, endHead, unattendedEnv);
  const parsedLastMessage = parseJsonOrNull(await readFile(lastMessagePath, 'utf8').catch(() => ''));
  const pullRequest = findPullRequest({
    repository: normalizeText(packet.repository),
    branch: branchName,
    workDir,
    env: unattendedEnv
  });
  const artifacts = {
    taskPacketPath,
    promptPath,
    outputSchemaPath: schemaPath,
    codexLastMessagePath: lastMessagePath,
    codexStdoutPath: stdoutPath,
    codexStderrPath: stderrPath,
    workDir
  };

  let receipt;
  if (codexResult.status !== 0) {
    const failure = classifyFailureMessage(codexResult.stderr || codexResult.stdout);
    receipt = buildExecutionReceipt({
      taskPacket: packet,
      codexResult: parsedLastMessage,
      codexCommand: ['codex', ...codexArgs].join(' '),
      filesTouched,
      startHead,
      endHead,
      branchName,
      pullRequest,
      artifacts,
      failure: {
        ...failure,
        reason: normalizeText(codexResult.stderr) || normalizeText(codexResult.stdout) || 'codex exec failed'
      }
    });
  } else {
    receipt = buildExecutionReceipt({
      taskPacket: packet,
      codexResult: parsedLastMessage,
      codexCommand: ['codex', ...codexArgs].join(' '),
      filesTouched,
      startHead,
      endHead,
      branchName,
      pullRequest,
      artifacts,
      failure: null
    });
  }

  await writeJson(receiptPath, receipt);
  return receipt;
}

async function runCli() {
  const taskPacketPath = normalizeText(process.env.COMPAREVI_DELIVERY_TASK_PACKET_PATH);
  const receiptPath = normalizeText(process.env.COMPAREVI_DELIVERY_RECEIPT_PATH);
  const repoRoot = normalizeText(process.env.COMPAREVI_DELIVERY_REPO_ROOT) || process.cwd();

  if (!taskPacketPath) {
    throw new Error('COMPAREVI_DELIVERY_TASK_PACKET_PATH is required.');
  }
  if (!receiptPath) {
    throw new Error('COMPAREVI_DELIVERY_RECEIPT_PATH is required.');
  }

  const receipt = await runCodexDeliveryTurn({ taskPacketPath, receiptPath, repoRoot });
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await runCli();
    process.exit(exitCode);
  } catch (error) {
    const failure = {
      schema: 'priority/runtime-execution-receipt@v1',
      generatedAt: toIso(),
      runtimeAdapter: 'comparevi',
      repository: normalizeText(process.env.GITHUB_REPOSITORY) || null,
      laneId: null,
      issue: null,
      status: 'blocked',
      outcome: 'codex-delivery-turn-runner-failed',
      reason: error?.message || String(error),
      source: 'codex-delivery-turn-runner',
      stopLoop: false,
      details: {
        actionType: 'execute-coding-turn',
        laneLifecycle: 'blocked',
        blockerClass: 'helperbug',
        retryable: false,
        nextWakeCondition: 'codex-turn-runner-fixed',
        helperCallsExecuted: [],
        filesTouched: []
      }
    };
    const receiptPath = normalizeText(process.env.COMPAREVI_DELIVERY_RECEIPT_PATH);
    if (receiptPath) {
      await writeJson(receiptPath, failure).catch(() => {});
    }
    process.stderr.write(`${JSON.stringify(failure, null, 2)}\n`);
    process.exit(1);
  }
}

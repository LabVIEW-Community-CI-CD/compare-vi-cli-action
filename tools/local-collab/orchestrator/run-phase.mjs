#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { HookRunner, info, listStagedFiles } from '../../hooks/core/runner.mjs';
import { resolveGitContext, writeLocalCollaborationLedgerReceipt } from '../ledger/local-review-ledger.mjs';
import { AGENT_REVIEW_POLICY_PROFILE_RECEIPT_PATHS } from '../providers/agent-review-policy.mjs';

export const LOCAL_COLLAB_ORCHESTRATOR_SCHEMA = 'comparevi/local-collab-orchestrator@v1';
export const LOCAL_COLLAB_PHASES = ['pre-commit', 'post-commit', 'pre-push', 'daemon'];
export const DEFAULT_PHASE_PERSONAS = {
  'pre-commit': 'codex',
  'post-commit': 'codex',
  'pre-push': 'codex',
  daemon: 'daemon'
};
export const DEFAULT_PHASE_FORK_PLANES = {
  'pre-commit': 'personal',
  'post-commit': 'personal',
  'pre-push': 'personal',
  daemon: 'upstream'
};
export const DEFAULT_PHASE_EXECUTION_PLANES = {
  'pre-commit': 'windows-host',
  'post-commit': 'windows-host',
  'pre-push': 'windows-host',
  daemon: 'docker'
};
export const PHASE_PROVIDER_ENV_OVERRIDES = {
  'pre-commit': 'PRECOMMIT_AGENT_REVIEW_PROVIDERS',
  'pre-push': 'PREPUSH_AGENT_REVIEW_PROVIDERS',
  daemon: 'DAEMON_AGENT_REVIEW_PROVIDERS'
};
export const DEFAULT_ORCHESTRATOR_RECEIPT_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'local-collab',
  'orchestrator'
);
export const DEFAULT_DAEMON_DELEGATE_COMMAND = ['node', 'tools/priority/docker-desktop-review-loop.mjs'];
export const AGENT_REVIEW_POLICY_COMMAND = ['node', 'tools/local-collab/providers/agent-review-policy.mjs'];

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function normalizeStringList(values) {
  if (!Array.isArray(values)) {
    return [];
  }
  return [...new Set(values.map((value) => normalizeText(value)).filter(Boolean))];
}

function parseProviderList(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return [];
  }
  return normalized
    .split(',')
    .map((entry) => normalizeText(entry))
    .filter(Boolean);
}

function isPhase(value) {
  return LOCAL_COLLAB_PHASES.includes(normalizeText(value));
}

function defaultOrchestratorReceiptPath(repoRoot, phase) {
  return path.join(repoRoot, DEFAULT_ORCHESTRATOR_RECEIPT_ROOT, `${phase}.json`);
}

function runGit(repoRoot, args) {
  const result = spawnSync('git', ['-C', repoRoot, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const stdout = normalizeText(result.stdout);
  const stderr = normalizeText(result.stderr);
  if (result.status !== 0) {
    throw new Error(stderr || stdout || `git ${args.join(' ')} failed`);
  }
  return stdout;
}

function collectFilesTouchedForPhase(repoRoot, phase, git = {}) {
  if (phase === 'pre-commit') {
    return normalizeStringList(listStagedFiles(repoRoot));
  }

  if (phase === 'post-commit') {
    return normalizeStringList(runGit(repoRoot, ['show', '--pretty=format:', '--name-only', '--diff-filter=ACMRT', 'HEAD']).split(/\r?\n/));
  }

  if (phase === 'pre-push' || phase === 'daemon') {
    const baseSha = normalizeText(git.baseSha);
    const headSha = normalizeText(git.headSha);
    if (!baseSha || !headSha) {
      return [];
    }
    return normalizeStringList(
      runGit(repoRoot, ['diff', '--name-only', '--diff-filter=ACMRT', `${baseSha}..${headSha}`]).split(/\r?\n/)
    );
  }

  return [];
}

export function parseArgs(argv = process.argv) {
  const args = Array.isArray(argv) ? argv.slice(2) : [];
  const parsed = {
    phase: '',
    repoRoot: process.cwd(),
    orchestratorReceiptPath: '',
    forkPlane: '',
    persona: '',
    executionPlane: '',
    providers: [],
    delegateArgs: []
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    switch (token) {
      case '--phase':
        parsed.phase = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--repo-root':
        parsed.repoRoot = normalizeText(args[index + 1]) || parsed.repoRoot;
        index += 1;
        break;
      case '--orchestrator-receipt-path':
        parsed.orchestratorReceiptPath = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--fork-plane':
        parsed.forkPlane = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--persona':
        parsed.persona = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--execution-plane':
        parsed.executionPlane = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--providers':
        parsed.providers = parseProviderList(args[index + 1]);
        index += 1;
        break;
      default:
        parsed.delegateArgs.push(token);
        break;
    }
  }

  if (!isPhase(parsed.phase)) {
    throw new Error(`--phase must be one of: ${LOCAL_COLLAB_PHASES.join(', ')}`);
  }
  return parsed;
}

export function resolvePhaseProviderSelection(phase, env = process.env, explicitProviders = []) {
  const explicit = Array.isArray(explicitProviders) ? explicitProviders.filter(Boolean) : [];
  if (explicit.length > 0) {
    return {
      selectionSource: 'explicit',
      providers: explicit
    };
  }

  const phaseOverrideKey = PHASE_PROVIDER_ENV_OVERRIDES[phase];
  const phaseOverride = phaseOverrideKey ? parseProviderList(env[phaseOverrideKey]) : [];
  if (phaseOverride.length > 0) {
    return {
      selectionSource: phaseOverrideKey,
      providers: phaseOverride
    };
  }

  const hooksOverride = parseProviderList(env.HOOKS_AGENT_REVIEW_PROVIDERS);
  if (hooksOverride.length > 0) {
    return {
      selectionSource: 'HOOKS_AGENT_REVIEW_PROVIDERS',
      providers: hooksOverride
    };
  }

  return {
    selectionSource: 'default-empty',
    providers: []
  };
}

function resolvePhaseIdentity(phase, env = process.env, overrides = {}) {
  return {
    forkPlane: normalizeText(overrides.forkPlane) || normalizeText(env.LOCAL_COLLAB_FORK_PLANE) || DEFAULT_PHASE_FORK_PLANES[phase],
    persona: normalizeText(overrides.persona) || normalizeText(env.LOCAL_COLLAB_PERSONA) || DEFAULT_PHASE_PERSONAS[phase],
    executionPlane:
      normalizeText(overrides.executionPlane) ||
      normalizeText(env.LOCAL_COLLAB_EXECUTION_PLANE) ||
      DEFAULT_PHASE_EXECUTION_PLANES[phase]
  };
}

function normalizeCommandResult(result = {}) {
  return {
    status: Number.isInteger(result.status) ? result.status : 1,
    stdout: normalizeText(result.stdout),
    stderr: [normalizeText(result.stderr), normalizeText(result.error?.message)].filter(Boolean).join('\n')
  };
}

function tryParseJson(raw) {
  const normalized = normalizeText(raw);
  if (!normalized) {
    return null;
  }
  try {
    return JSON.parse(normalized);
  } catch {
    return null;
  }
}

function hardFailHookStep(runner, step, reason) {
  const rawExitCode = Number.isInteger(step?.rawExitCode) ? step.rawExitCode : step?.exitCode;
  if (!rawExitCode) {
    return;
  }
  step.status = 'failed';
  step.exitCode = rawExitCode;
  step.severity = 'error';
  runner.status = 'failed';
  runner.exitCode = rawExitCode;
  if (reason) {
    runner.addNote(reason);
  }
}

function invokeHookAgentReviewStep({ runner, repoRoot, phase, env, providerSelection, invokeAgentReviewPolicyFn }) {
  const configuredReceiptPath = AGENT_REVIEW_POLICY_PROFILE_RECEIPT_PATHS[phase];
  const normalizedReceiptPath = configuredReceiptPath.replace(/\\/g, '/');
  const args = [
    ...AGENT_REVIEW_POLICY_COMMAND.slice(1),
    '--repo-root',
    repoRoot,
    '--profile',
    phase,
    '--receipt-path',
    configuredReceiptPath
  ];
  for (const providerId of providerSelection.providers) {
    args.push('--review-provider', providerId);
  }

  let parsedReceipt = null;
  const step = runner.runStep('agent-review-policy', () => {
    const commandResult = typeof invokeAgentReviewPolicyFn === 'function'
      ? (() => {
          const injected = invokeAgentReviewPolicyFn({
            repoRoot,
            phase,
            env,
            providerSelection,
            receiptPath: configuredReceiptPath
          }) ?? {};
          parsedReceipt = injected.receipt ?? null;
          const status = Number.isInteger(injected.exitCode)
            ? injected.exitCode
            : normalizeText(parsedReceipt?.overall?.status) === 'failed'
              ? 1
              : 0;
          return {
            status,
            stdout: normalizeText(injected.stdout) || (parsedReceipt ? JSON.stringify(parsedReceipt, null, 2) : ''),
            stderr: normalizeText(injected.stderr)
          };
        })()
      : normalizeCommandResult(
          spawnSync(AGENT_REVIEW_POLICY_COMMAND[0], args, {
            cwd: repoRoot,
            encoding: 'utf8',
            env: {
              ...env
            },
            stdio: ['ignore', 'pipe', 'pipe']
          })
        );
    parsedReceipt ??= tryParseJson(commandResult.stdout);
    const requestedProviders = Array.isArray(parsedReceipt?.requestedProviders)
      ? parsedReceipt.requestedProviders.filter(Boolean)
      : [];
    const noteParts = [
      `receipt=${normalizedReceiptPath}`,
      `selectionSource=${normalizeText(parsedReceipt?.providerSelection?.selectionSource) || providerSelection.selectionSource}`
    ];
    if (requestedProviders.length > 0) {
      noteParts.push(`providers=${requestedProviders.join(',')}`);
    } else {
      noteParts.push('providers=(none)');
    }
    return {
      status:
        commandResult.status === 0
          ? normalizeText(parsedReceipt?.overall?.status) === 'skipped'
            ? 'skipped'
            : 'ok'
          : 'failed',
      exitCode: commandResult.status,
      stdout: commandResult.stdout,
      stderr: commandResult.stderr,
      note: noteParts.join(' ')
    };
  });

  if ((step.rawExitCode ?? step.exitCode) !== 0) {
    hardFailHookStep(
      runner,
      step,
      `Blocking local collaboration hook failure in ${phase}: agent-review-policy reported actionable findings or provider failure.`
    );
  }

  return {
    receiptPath: normalizedReceiptPath,
    receiptStatus: normalizeText(parsedReceipt?.overall?.status) || null,
    selectionSource:
      normalizeText(parsedReceipt?.providerSelection?.selectionSource) || providerSelection.selectionSource,
    requestedProviders: Array.isArray(parsedReceipt?.requestedProviders)
      ? parsedReceipt.requestedProviders.filter(Boolean)
      : [],
    actionableFindingCount: Number.isInteger(parsedReceipt?.overall?.actionableFindingCount)
      ? parsedReceipt.overall.actionableFindingCount
      : 0
  };
}

function invokePreCommitDelegate(
  repoRoot,
  {
    env = process.env,
    providerSelection = { selectionSource: 'default-empty', providers: [] },
    invokeAgentReviewPolicyFn
  } = {}
) {
  const runner = new HookRunner('pre-commit', { repoRoot });

  info('[pre-commit] Collecting staged files');
  let stagedFiles = [];
  runner.runStep('collect-staged', () => {
    stagedFiles = listStagedFiles(repoRoot);
    return {
      status: 'ok',
      exitCode: 0,
      stdout: stagedFiles.join('\n'),
      stderr: ''
    };
  });

  if (stagedFiles.length === 0) {
    info('[pre-commit] No staged files detected; skipping checks.');
    runner.addNote('No staged files; hook exited early.');
    runner.writeSummary();
    return {
      exitCode: 0,
      summaryPath: path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit.json')
    };
  }

  const psFiles = stagedFiles.filter((file) => file.match(/\.(ps1|psm1|psd1)$/i));
  if (psFiles.length > 0) {
    const scriptPath = path.join('tools', 'hooks', 'scripts', 'pre-commit.ps1');
    info('[pre-commit] Running PowerShell validation script');
    runner.runPwshStep('powershell-validation', scriptPath, [], {
      env: {
        HOOKS_STAGED_FILES_JSON: JSON.stringify(psFiles)
      }
    });
  } else {
    info('[pre-commit] No staged PowerShell files detected; skipping PowerShell lint.');
    runner.addNote('No staged PowerShell files detected; PowerShell lint skipped.');
  }

  info('[pre-commit] Running local agent review providers');
  const agentReview = invokeHookAgentReviewStep({
    runner,
    repoRoot,
    phase: 'pre-commit',
    env,
    providerSelection,
    invokeAgentReviewPolicyFn
  });
  runner.writeSummary();

  if (runner.exitCode !== 0) {
    info('[pre-commit] Hook failed; see tests/results/_hooks/pre-commit.json for details.');
  } else {
    info('[pre-commit] OK');
  }

  return {
    exitCode: runner.exitCode,
    summaryPath: path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit.json'),
    agentReview
  };
}

function invokePrePushDelegate(
  repoRoot,
  {
    env = process.env,
    providerSelection = { selectionSource: 'default-empty', providers: [] },
    invokeAgentReviewPolicyFn
  } = {}
) {
  const runner = new HookRunner('pre-push', { repoRoot });
  info('[pre-push] Running local agent review providers');
  const agentReview = invokeHookAgentReviewStep({
    runner,
    repoRoot,
    phase: 'pre-push',
    env,
    providerSelection,
    invokeAgentReviewPolicyFn
  });
  if (runner.exitCode === 0) {
    info('[pre-push] Running core pre-push checks');
    runner.runPwshStep('pre-push-checks', path.join('tools', 'PrePush-Checks.ps1'), [], {
      env: {
        LOCAL_COLLAB_ORCHESTRATED: '1',
        LOCAL_COLLAB_PHASE: 'pre-push'
      }
    });
  } else {
    runner.addNote('Skipped core pre-push checks because local agent review failed.');
  }
  runner.writeSummary();
  if (runner.exitCode !== 0) {
    info('[pre-push] Hook failed; inspect tests/results/_hooks/pre-push.json for details.');
  } else {
    info('[pre-push] OK');
  }
  return {
    exitCode: runner.exitCode,
    summaryPath: path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-push.json'),
    agentReview
  };
}

function invokeDaemonDelegate(repoRoot, delegateArgs) {
  const result = spawnSync(DEFAULT_DAEMON_DELEGATE_COMMAND[0], [...DEFAULT_DAEMON_DELEGATE_COMMAND.slice(1), '--repo-root', repoRoot, ...delegateArgs], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return normalizeCommandResult(result);
}

function invokePostCommitDelegate(repoRoot) {
  const runner = new HookRunner('post-commit', { repoRoot });
  info('[post-commit] Recording local collaboration authoring receipt');
  runner.runStep('record-authoring-receipt', () => ({
    status: 'ok',
    exitCode: 0,
    stdout: '',
    stderr: '',
    note: 'Post-commit authoring receipt recorded.'
  }));
  runner.addNote('Codex/operator commits are governed by the same local collaboration contract as review hooks.');
  runner.writeSummary();
  info('[post-commit] OK');
  return {
    exitCode: runner.exitCode,
    summaryPath: path.join(repoRoot, 'tests', 'results', '_hooks', 'post-commit.json')
  };
}

export async function runLocalCollaborationPhase(options = {}) {
  const phase = normalizeText(options.phase);
  const repoRoot = path.resolve(normalizeText(options.repoRoot) || process.cwd());
  const env = options.env ?? process.env;
  const delegateFns = options.delegateFns && typeof options.delegateFns === 'object' ? options.delegateFns : {};
  const providerSelection = resolvePhaseProviderSelection(phase, env, options.providers);
  const identity = resolvePhaseIdentity(phase, env, options);
  const git = resolveGitContext(repoRoot);
  const orchestratorReceiptPath = path.resolve(
    repoRoot,
    normalizeText(options.orchestratorReceiptPath) || defaultOrchestratorReceiptPath(repoRoot, phase)
  );
  await mkdir(path.dirname(orchestratorReceiptPath), { recursive: true });

  const started = Date.now();
  let result;
  if (typeof delegateFns[phase] === 'function') {
    result = await delegateFns[phase]({ repoRoot, phase, env, delegateArgs: options.delegateArgs ?? [] });
  } else if (phase === 'pre-commit') {
    result = invokePreCommitDelegate(repoRoot, {
      env,
      providerSelection,
      invokeAgentReviewPolicyFn: options.invokeAgentReviewPolicyFn
    });
  } else if (phase === 'pre-push') {
    result = invokePrePushDelegate(repoRoot, {
      env,
      providerSelection,
      invokeAgentReviewPolicyFn: options.invokeAgentReviewPolicyFn
    });
  } else if (phase === 'daemon') {
    result = invokeDaemonDelegate(repoRoot, options.delegateArgs ?? []);
  } else if (phase === 'post-commit') {
    result = invokePostCommitDelegate(repoRoot);
  } else {
    throw new Error(`Unsupported local collaboration phase: ${phase}`);
  }

  const finished = Date.now();
  const explicitFilesTouched = normalizeStringList(options.filesTouched);
  const filesTouched = explicitFilesTouched.length > 0
    ? explicitFilesTouched
    : collectFilesTouchedForPhase(repoRoot, phase, git);
  const agentReviewReceiptPath = normalizeText(result.agentReview?.receiptPath);
  const receipt = {
    schema: LOCAL_COLLAB_ORCHESTRATOR_SCHEMA,
    phase,
    repoRoot,
    forkPlane: identity.forkPlane,
    persona: identity.persona,
    executionPlane: identity.executionPlane,
    headSha: git.headSha,
    baseSha: git.baseSha,
    startedAt: new Date(started).toISOString(),
    finishedAt: new Date(finished).toISOString(),
    durationMs: finished - started,
    status: result.exitCode === 0 ? 'passed' : 'failed',
    outcome: result.exitCode === 0 ? 'completed' : 'blocked',
    filesTouched,
    commitCreated: phase === 'post-commit',
    selectionSource: providerSelection.selectionSource,
    providers: providerSelection.providers,
    delegate: {
      command:
        phase === 'daemon'
          ? [...DEFAULT_DAEMON_DELEGATE_COMMAND, '--repo-root', repoRoot, ...(options.delegateArgs ?? [])]
          : null,
      summaryPath: normalizeText(result.summaryPath) || null,
      note: normalizeText(result.note) || null,
      agentReview:
        result.agentReview && typeof result.agentReview === 'object'
          ? {
              receiptPath: normalizeText(result.agentReview.receiptPath) || null,
              receiptStatus: normalizeText(result.agentReview.receiptStatus) || null,
              selectionSource: normalizeText(result.agentReview.selectionSource) || null,
              requestedProviders: normalizeStringList(result.agentReview.requestedProviders),
              actionableFindingCount: Number.isInteger(result.agentReview.actionableFindingCount)
                ? result.agentReview.actionableFindingCount
                : 0
            }
          : null
    }
  };
  await writeFile(orchestratorReceiptPath, JSON.stringify(receipt, null, 2), 'utf8');

  const ledger = await writeLocalCollaborationLedgerReceipt({
    repoRoot,
    phase,
    git,
    forkPlane: receipt.forkPlane,
    persona: receipt.persona,
    executionPlane: receipt.executionPlane,
    providerRuntime: 'local-collab-orchestrator',
    providers: providerSelection.providers,
    selectionSource: providerSelection.selectionSource,
    startedAt: receipt.startedAt,
    finishedAt: receipt.finishedAt,
    durationMs: receipt.durationMs,
    status: receipt.status,
    outcome: receipt.outcome,
    filesTouched: receipt.filesTouched,
    commitCreated: receipt.commitCreated,
    sourcePaths: [
      orchestratorReceiptPath,
      normalizeText(result.summaryPath),
      agentReviewReceiptPath ? path.resolve(repoRoot, agentReviewReceiptPath) : ''
    ].filter(Boolean),
    metadata: {
      orchestratorReceiptPath: path.relative(repoRoot, orchestratorReceiptPath).replace(/\\/g, '/'),
      delegateSummaryPath: normalizeText(result.summaryPath) || null,
      agentReviewReceiptPath: agentReviewReceiptPath || null
    }
  });
  receipt.ledger = {
    receiptId: ledger.receipt.receiptId,
    receiptPath: path.relative(repoRoot, ledger.receiptPath).replace(/\\/g, '/'),
    latestIndexPath: path.relative(repoRoot, ledger.latestIndexPath).replace(/\\/g, '/')
  };
  await writeFile(orchestratorReceiptPath, JSON.stringify(receipt, null, 2), 'utf8');

  return {
    exitCode: result.exitCode ?? 1,
    receipt,
    receiptPath: orchestratorReceiptPath,
    ledgerReceipt: ledger.receipt,
    ledgerReceiptPath: ledger.receiptPath,
    ledgerLatestIndexPath: ledger.latestIndexPath,
    stdout: normalizeText(result.stdout),
    stderr: normalizeText(result.stderr)
  };
}

export async function main(argv = process.argv, overrides = {}) {
  const parsed = overrides.parsedArgs ?? parseArgs(argv);
  const result = await runLocalCollaborationPhase({
    ...parsed,
    env: overrides.env ?? process.env
  });

  if (parsed.phase === 'daemon') {
    if (result.stdout) {
      process.stdout.write(result.stdout);
    }
    if (result.stderr) {
      process.stderr.write(`${result.stderr}\n`);
    }
  }

  return result.exitCode;
}

const isEntrypoint = fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || '');

if (isEntrypoint) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}

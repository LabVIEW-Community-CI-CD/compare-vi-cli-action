#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { HookRunner, info, listStagedFiles } from '../../hooks/core/runner.mjs';
import { resolveGitContext, writeLocalCollaborationLedgerReceipt } from '../ledger/local-review-ledger.mjs';
import { AGENT_REVIEW_POLICY_PROFILE_RECEIPT_PATHS } from '../providers/agent-review-policy.mjs';
import {
  DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH,
  loadBranchClassContract
} from '../../priority/lib/branch-classification.mjs';

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
export const GITHUB_ACTIONS_PHASE_DEFAULT_PROVIDERS = {
  'pre-commit': ['simulation'],
  'pre-push': ['simulation']
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

function resolveCurrentBranchName(repoRoot) {
  return normalizeText(runGit(repoRoot, ['branch', '--show-current']));
}

function normalizeBranchPlaneEntry(entry = {}) {
  return {
    plane: normalizeText(entry.id),
    repositories: normalizeStringList(entry.repositories),
    developBranch: normalizeText(entry.developBranch),
    developClass: normalizeText(entry.developClass),
    laneBranchPrefix: normalizeText(entry.laneBranchPrefix),
    purpose: normalizeText(entry.purpose),
    personas: normalizeStringList(entry.personas)
  };
}

function resolveBranchModel(repoRoot, loadBranchClassContractFn = loadBranchClassContract) {
  const contract = loadBranchClassContractFn(repoRoot);
  const branchName = resolveCurrentBranchName(repoRoot);
  const planeEntries = Array.isArray(contract.repositoryPlanes)
    ? contract.repositoryPlanes.map((entry) => normalizeBranchPlaneEntry(entry))
    : [];
  const lanePlane = [...planeEntries]
    .sort((left, right) => right.laneBranchPrefix.length - left.laneBranchPrefix.length)
    .find((entry) => entry.laneBranchPrefix && branchName.startsWith(entry.laneBranchPrefix)) ?? null;

  return {
    contractPath: DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH.replace(/\\/g, '/'),
    branchName,
    plane: lanePlane?.plane || null,
    laneBranchPrefix: lanePlane?.laneBranchPrefix || null,
    developBranch: lanePlane?.developBranch || null,
    developClass: lanePlane?.developClass || null,
    purpose: lanePlane?.purpose || null,
    personas: lanePlane?.personas || []
  };
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

  const githubActions = normalizeText(env.GITHUB_ACTIONS).toLowerCase() === 'true';
  const hostedDefaults = githubActions ? normalizeStringList(GITHUB_ACTIONS_PHASE_DEFAULT_PROVIDERS[phase]) : [];
  if (hostedDefaults.length > 0) {
    return {
      selectionSource: 'github-actions-default',
      providers: hostedDefaults
    };
  }

  return {
    selectionSource: 'default-empty',
    providers: []
  };
}

function resolvePhaseIdentity(phase, repoRoot, env = process.env, overrides = {}, branchModel = null) {
  const explicitForkPlane = normalizeText(overrides.forkPlane);
  const envForkPlane = normalizeText(env.LOCAL_COLLAB_FORK_PLANE);
  const defaultForkPlane = DEFAULT_PHASE_FORK_PLANES[phase];
  const branchPlane = normalizeText(branchModel?.plane);

  if (phase !== 'daemon' && branchPlane) {
    if (explicitForkPlane && explicitForkPlane !== branchPlane) {
      throw new Error(`Explicit fork plane '${explicitForkPlane}' conflicts with branch plane '${branchPlane}' for '${branchModel.branchName}'.`);
    }
    if (envForkPlane && envForkPlane !== branchPlane) {
      throw new Error(`LOCAL_COLLAB_FORK_PLANE='${envForkPlane}' conflicts with branch plane '${branchPlane}' for '${branchModel.branchName}'.`);
    }
  }

  const resolvedForkPlane =
    explicitForkPlane ||
    envForkPlane ||
    (phase !== 'daemon' && branchPlane ? branchPlane : defaultForkPlane);

  return {
    forkPlane: resolvedForkPlane,
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

function hardFailHookStep(runner, step, reason, options = {}) {
  const rawExitCode = Number.isInteger(step?.rawExitCode) ? step.rawExitCode : step?.exitCode;
  const effectiveExitCode = options.useRawExitCode ? rawExitCode : step?.exitCode;
  if (!effectiveExitCode) {
    return;
  }
  step.status = 'failed';
  step.exitCode = rawExitCode || effectiveExitCode;
  step.severity = 'error';
  if (options.useRawExitCode && step.note && /HOOKS_ENFORCE=/.test(step.note)) {
    delete step.note;
  }
  step.error ??= reason || 'Blocking hook step failed.';
  runner.status = 'failed';
  runner.exitCode = rawExitCode || effectiveExitCode;
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

  // Respect the hook runner's post-enforcement exit code so warn/off modes do not
  // get re-promoted to hard failures after the summary has already downgraded them.
  if (step.exitCode !== 0) {
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
  const runner = new HookRunner('pre-commit', { repoRoot, env });

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
    const powerShellStep = runner.runPwshStep('powershell-validation', scriptPath, [], {
      env: {
        HOOKS_STAGED_FILES_JSON: JSON.stringify(psFiles)
      }
    });
    hardFailHookStep(
      runner,
      powerShellStep,
      'Blocking local collaboration hook failure in pre-commit: PowerShell validation failed.',
      { useRawExitCode: true }
    );
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
  const runner = new HookRunner('pre-push', { repoRoot, env });
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
    const prePushChecksStep = runner.runPwshStep('pre-push-checks', path.join('tools', 'PrePush-Checks.ps1'), [], {
      env: {
        LOCAL_COLLAB_ORCHESTRATED: '1',
        LOCAL_COLLAB_PHASE: 'pre-push'
      }
    });
    hardFailHookStep(
      runner,
      prePushChecksStep,
      'Blocking local collaboration hook failure in pre-push: core pre-push checks failed.',
      { useRawExitCode: true }
    );
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

function invokeDaemonAgentReview(
  repoRoot,
  {
    env = process.env,
    providerSelection = { selectionSource: 'default-empty', providers: [] },
    invokeAgentReviewPolicyFn
  } = {}
) {
  const configuredReceiptPath = AGENT_REVIEW_POLICY_PROFILE_RECEIPT_PATHS.daemon;
  const normalizedReceiptPath = configuredReceiptPath.replace(/\\/g, '/');
  const args = [
    ...AGENT_REVIEW_POLICY_COMMAND.slice(1),
    '--repo-root',
    repoRoot,
    '--profile',
    'daemon',
    '--receipt-path',
    configuredReceiptPath
  ];
  for (const providerId of providerSelection.providers) {
    args.push('--review-provider', providerId);
  }

  let parsedReceipt = null;
  const commandResult = typeof invokeAgentReviewPolicyFn === 'function'
    ? (() => {
        const injected = invokeAgentReviewPolicyFn({
          repoRoot,
          phase: 'daemon',
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

  return {
    exitCode: commandResult.status,
    receiptPath: normalizedReceiptPath,
    receiptStatus: normalizeText(parsedReceipt?.overall?.status) || null,
    selectionSource:
      normalizeText(parsedReceipt?.providerSelection?.selectionSource) || providerSelection.selectionSource,
    requestedProviders: Array.isArray(parsedReceipt?.requestedProviders)
      ? parsedReceipt.requestedProviders.filter(Boolean)
      : [],
    actionableFindingCount: Number.isInteger(parsedReceipt?.overall?.actionableFindingCount)
      ? parsedReceipt.overall.actionableFindingCount
      : 0,
    reason:
      normalizeText(parsedReceipt?.overall?.message) ||
      normalizeText(commandResult.stderr) ||
      normalizeText(commandResult.stdout) ||
      'Daemon local agent review providers did not return a machine-readable status.',
    receipt: parsedReceipt
  };
}

function buildDaemonCombinedStdout(delegateReport, agentReview) {
  if (!delegateReport || typeof delegateReport !== 'object') {
    return '';
  }

  const combined = {
    ...delegateReport,
    source: 'local-collab-daemon-review',
    reason:
      normalizeText(agentReview?.receiptStatus).toLowerCase() === 'failed'
        ? normalizeText(agentReview.reason) || 'Daemon local agent review providers failed after Docker/Desktop review passed.'
        : 'Docker/Desktop review loop passed and daemon local agent review providers passed.',
    agentReview: agentReview
      ? {
          receiptPath: normalizeText(agentReview.receiptPath) || null,
          receiptStatus: normalizeText(agentReview.receiptStatus) || null,
          selectionSource: normalizeText(agentReview.selectionSource) || null,
          requestedProviders: normalizeStringList(agentReview.requestedProviders),
          actionableFindingCount: Number.isInteger(agentReview.actionableFindingCount)
            ? agentReview.actionableFindingCount
            : 0
        }
      : null
  };

  if (normalizeText(agentReview?.receiptStatus).toLowerCase() === 'failed') {
    combined.status = 'failed';
  }
  return JSON.stringify(combined, null, 2);
}

function invokePostCommitDelegate(repoRoot, env = process.env) {
  const runner = new HookRunner('post-commit', { repoRoot, env });
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
  const branchModel = resolveBranchModel(repoRoot, options.loadBranchClassContractFn);
  const identity = resolvePhaseIdentity(phase, repoRoot, env, options, branchModel);
  const git = resolveGitContext(repoRoot);
  const orchestratorReceiptPath = path.resolve(
    repoRoot,
    normalizeText(options.orchestratorReceiptPath) || defaultOrchestratorReceiptPath(repoRoot, phase)
  );
  await mkdir(path.dirname(orchestratorReceiptPath), { recursive: true });

  const started = Date.now();
  let result;
  if (phase === 'daemon') {
    result = typeof delegateFns.daemon === 'function'
      ? await delegateFns.daemon({ repoRoot, phase, env, delegateArgs: options.delegateArgs ?? [] })
      : invokeDaemonDelegate(repoRoot, options.delegateArgs ?? []);
    const delegateReport = tryParseJson(result.stdout);
    const delegatePassed =
      result.exitCode === 0 &&
      delegateReport &&
      typeof delegateReport === 'object' &&
      normalizeText(delegateReport.status).toLowerCase() === 'passed';
    if (delegatePassed && providerSelection.providers.length > 0) {
      result.agentReview = invokeDaemonAgentReview(repoRoot, {
        env,
        providerSelection,
        invokeAgentReviewPolicyFn: options.invokeAgentReviewPolicyFn
      });
      result.stdout = buildDaemonCombinedStdout(delegateReport, result.agentReview);
      if (normalizeText(result.agentReview.receiptStatus).toLowerCase() === 'failed' || result.agentReview.exitCode !== 0) {
        result.exitCode = 1;
        result.stderr = normalizeText(result.agentReview.reason) || result.stderr;
      }
    }
  } else if (typeof delegateFns[phase] === 'function') {
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
  } else if (phase === 'post-commit') {
    result = invokePostCommitDelegate(repoRoot, env);
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
    branchModel,
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
      agentReviewReceiptPath: agentReviewReceiptPath || null,
      branchModel
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

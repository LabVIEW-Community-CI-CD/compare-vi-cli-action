import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCHEMA = 'comparevi/hooks-summary@v1';
const MODULE_FILE_PATH = fileURLToPath(import.meta.url);
const MODULE_REPO_ROOT = path.resolve(path.dirname(MODULE_FILE_PATH), '../../..');

function runCommand(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    shell: false,
    ...options,
  });

  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function formatCommandFailure(command, args, result, cwd) {
  const parts = [`${command} ${args.join(' ')} failed`];
  if (Number.isInteger(result?.status)) {
    parts.push(`status=${result.status}`);
  }
  if (result?.error?.code) {
    parts.push(`error=${result.error.code}`);
  }
  const stderr = (result?.stderr || '').trim();
  if (stderr) {
    parts.push(`stderr=${stderr}`);
  }
  parts.push(`cwd=${cwd}`);
  return parts.join(' ');
}

function hasRepoMarkers(candidateRoot) {
  if (!candidateRoot) {
    return false;
  }
  return existsSync(path.join(candidateRoot, '.git')) || existsSync(path.join(candidateRoot, 'package.json'));
}

function findGitRoot(options = {}) {
  const commandRunner = options.commandRunner ?? runCommand;
  const cwd = options.cwd ?? process.cwd();
  const fallbackRoot = options.fallbackRoot ?? MODULE_REPO_ROOT;

  const result = commandRunner('git', ['rev-parse', '--show-toplevel'], { cwd });
  if (result?.status === 0) {
    const root = (result.stdout || '').trim();
    if (root) {
      return root;
    }
  }

  if (hasRepoMarkers(fallbackRoot)) {
    return fallbackRoot;
  }

  const detail = formatCommandFailure('git', ['rev-parse', '--show-toplevel'], result, cwd);
  throw new Error(`Unable to resolve git repository root (${detail}).`);
}

function which(command, options = {}) {
  const commandRunner = options.commandRunner ?? runCommand;
  const platform = options.platform ?? process.platform;
  const exe = platform === 'win32' ? 'where' : 'which';
  const { status, stdout } = commandRunner(exe, [command]);
  if (status === 0) {
    const match = stdout.split(/\r?\n/).find(Boolean);
    if (match) {
      return match.trim();
    }
  }
  return null;
}

function truncate(text, limit = 4000) {
  if (!text) {
    return '';
  }
  if (text.length <= limit) {
    return text;
  }
  return `${text.slice(0, limit)}…[truncated ${text.length - limit} chars]`;
}

function detectPlane(overrides = {}) {
  const env = overrides.env ?? process.env;
  const platform = overrides.platform ?? process.platform;
  const githubActions = overrides.githubActions ?? (env.GITHUB_ACTIONS === 'true');
  const wslDetected = overrides.isWsl ?? Boolean(env.WSL_DISTRO_NAME);

  if (githubActions) {
    if (platform === 'win32') {
      return 'github-windows';
    }
    if (platform === 'darwin') {
      return 'github-macos';
    }
    return 'github-ubuntu';
  }

  if (wslDetected) {
    return 'linux-wsl';
  }

  if (platform === 'win32') {
    return 'windows-pwsh';
  }

  if (platform === 'darwin') {
    return 'macos-bash';
  }

  return 'linux-bash';
}

function resolveEnforcement(overrides = {}) {
  const env = overrides.env ?? process.env;
  const githubActions = overrides.githubActions ?? (env.GITHUB_ACTIONS === 'true');
  const raw = (overrides.mode ?? env.HOOKS_ENFORCE ?? '').toLowerCase();
  if (raw === 'fail' || raw === 'warn' || raw === 'off') {
    return raw;
  }
  return githubActions ? 'fail' : 'warn';
}

export class HookRunner {
  constructor(hookName, options = {}) {
    this.hook = hookName;
    this.commandRunner = options.commandRunner ?? runCommand;
    this.whichResolver = options.whichResolver ?? ((command) => which(command, { commandRunner: this.commandRunner, platform: options.platform }));
    this.runtimeEnv = options.env ?? process.env;
    this.platform = options.platform ?? process.platform;
    const githubActions = options.githubActions ?? (this.runtimeEnv.GITHUB_ACTIONS === 'true');
    const gitRootResolver = options.gitRootResolver ?? ((resolverOptions = {}) =>
      findGitRoot({
        commandRunner: this.commandRunner,
        cwd: resolverOptions.cwd,
        fallbackRoot: resolverOptions.fallbackRoot,
      }));
    this.repoRoot =
      options.repoRoot ??
      gitRootResolver({
        cwd: options.cwd,
        fallbackRoot: options.fallbackRoot,
      });
    this.steps = [];
    this.notes = [];
    this.status = 'ok';
    this.exitCode = 0;
    this.plane = detectPlane({
      env: this.runtimeEnv,
      platform: this.platform,
      githubActions,
      isWsl: options.isWsl,
    });
    this.enforcement = resolveEnforcement({
      env: this.runtimeEnv,
      githubActions,
      mode: options.enforcementMode,
    });
    const enforcementHint =
      this.enforcement === 'fail'
        ? 'Set HOOKS_ENFORCE=warn to treat parity mismatches as warnings during local experiments.'
        : null;

    this.environment = {
      platform: this.platform,
      nodeVersion: process.version,
      pwshPath: null,
      plane: this.plane,
      enforcement: this.enforcement,
      githubActions,
      runnerName: this.runtimeEnv.RUNNER_NAME || null,
      runnerOS: this.runtimeEnv.RUNNER_OS || null,
      runnerArch: this.runtimeEnv.RUNNER_ARCH || null,
      runnerTrackingId: this.runtimeEnv.RUNNER_TRACKING_ID || null,
      job: this.runtimeEnv.GITHUB_JOB || null,
      enforcementHint,
    };

    if (enforcementHint && !this.environment.githubActions) {
      info(`[hooks ${this.hook}] ${enforcementHint}`);
    }

    this.resultsDir = path.join(this.repoRoot, 'tests', 'results', '_hooks');
    mkdirSync(this.resultsDir, { recursive: true });
  }

  addNote(message) {
    this.notes.push(message);
  }

  resolvePwsh() {
    if (this.environment.pwshPath) {
      return this.environment.pwshPath;
    }

    const candidates = [
      this.runtimeEnv.HOOKS_PWSH,
      'pwsh',
      'pwsh.exe',
      // Common Windows default install location.
      'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
    ].filter(Boolean);

    for (const candidate of candidates) {
      if (candidate.includes('\\') || candidate.includes('/')) {
        const { status } = this.commandRunner(candidate, ['-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']);
        if (status === 0) {
          this.environment.pwshPath = candidate;
          return candidate;
        }
      } else {
        const found = this.whichResolver(candidate);
        if (found) {
          this.environment.pwshPath = found;
          return found;
        }
      }
    }

    return null;
  }

  runStep(name, fn) {
    const started = Date.now();
    const step = {
      name,
      status: 'ok',
      exitCode: 0,
      durationMs: 0,
      stdout: '',
      stderr: '',
      severity: 'info',
    };

    try {
      const result = fn();
      step.status = result?.status ?? 'ok';
      step.exitCode = result?.exitCode ?? 0;
      step.stdout = truncate(result?.stdout ?? '');
      step.stderr = truncate(result?.stderr ?? '');
      if (result?.note) {
        step.note = result.note;
      }
    } catch (err) {
      step.status = 'failed';
      step.exitCode = err?.exitCode ?? 1;
      step.stderr = truncate(err?.stderr ?? '');
      step.error = err instanceof Error ? err.message : String(err);
      step.severity = 'error';
    } finally {
      step.durationMs = Date.now() - started;
    }

    if ((step.status === 'failed' || step.exitCode !== 0) && step.severity === 'info') {
      step.severity = 'error';
    }

    this.applyEnforcement(step);
    this.steps.push(step);
    return step;
  }

  runPwshStep(name, scriptPath, args = [], options = {}) {
    const pwshPath = this.resolvePwsh();
    if (!pwshPath) {
      return this.runStep(name, () => ({
        status: 'skipped',
        exitCode: 0,
        stdout: '',
        stderr: '',
        note: 'pwsh not available on PATH; skipping PowerShell hook logic.',
      }));
    }

    const expandedScript = path.resolve(this.repoRoot, scriptPath);
    return this.runStep(name, () => {
      const { status, stdout, stderr, error } = spawnSync(
        pwshPath,
        ['-NoLogo', '-NoProfile', '-File', expandedScript, ...args],
        {
          cwd: this.repoRoot,
          encoding: 'utf8',
          env: {
            ...this.runtimeEnv,
            ...options.env,
          },
        },
      );

      if (error) {
        const err = new Error(`Failed to execute PowerShell script: ${error.message}`);
        err.exitCode = status ?? 1;
        err.stderr = stderr ?? '';
        throw err;
      }

      return {
        status: status === 0 ? 'ok' : 'failed',
        exitCode: status ?? 0,
        stdout,
        stderr,
      };
    });
  }

  writeSummary() {
    const summaryPath = path.join(this.resultsDir, `${this.hook}.json`);
    const payload = {
      schema: SCHEMA,
      hook: this.hook,
      timestamp: new Date().toISOString(),
      repoRoot: this.repoRoot,
      status: this.status,
      exitCode: this.exitCode,
      steps: this.steps,
      notes: this.notes,
      environment: this.environment,
    };

    writeFileSync(summaryPath, JSON.stringify(payload, null, 2), 'utf8');
  }

  applyEnforcement(step) {
    const failureDetected = step.status === 'failed' || step.exitCode !== 0;
    if (!failureDetected) {
      if (step.status === 'warn' && this.status === 'ok') {
        this.status = 'warn';
      }
      return;
    }

    switch (this.enforcement) {
      case 'fail': {
        this.status = 'failed';
        this.exitCode = step.exitCode || 1;
        step.severity = 'error';
        break;
      }
      case 'warn': {
        step.note = step.note ? `${step.note} (converted to warning by HOOKS_ENFORCE=warn)` : 'Converted to warning by HOOKS_ENFORCE=warn';
        step.status = 'warn';
        step.severity = 'warn';
        step.exitCode = 0;
        if (this.status === 'ok') {
          this.status = 'warn';
        }
        this.addNote(`Warning: step "${step.name}" reported a failure but HOOKS_ENFORCE=warn.`);
        break;
      }
      case 'off': {
        step.note = step.note ? `${step.note} (suppressed by HOOKS_ENFORCE=off)` : 'Suppressed by HOOKS_ENFORCE=off';
        step.status = 'skipped';
        step.severity = 'info';
        step.exitCode = 0;
        this.addNote(`Suppressed failure in step "${step.name}" due to HOOKS_ENFORCE=off.`);
        break;
      }
      default: {
        this.status = 'failed';
        this.exitCode = step.exitCode || 1;
        step.severity = 'error';
      }
    }
  }
}

export function listStagedFiles() {
  const { status, stdout } = runCommand('git', ['diff', '--cached', '--name-only', '--diff-filter=ACM']);
  if (status !== 0) {
    throw new Error('git diff --cached failed while collecting staged files.');
  }
  return stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

export function info(message) {
  process.stdout.write(`${message}\n`);
}

export { detectPlane, resolveEnforcement, runCommand, findGitRoot, which };

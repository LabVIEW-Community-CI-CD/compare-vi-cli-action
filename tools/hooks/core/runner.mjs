import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const SCHEMA = 'comparevi/hooks-summary@v1';

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

function findGitRoot() {
  const { status, stdout } = runCommand('git', ['rev-parse', '--show-toplevel']);
  if (status !== 0) {
    throw new Error('Unable to resolve git repository root (git rev-parse failed).');
  }
  return stdout.trim();
}

function which(command) {
  const exe = process.platform === 'win32' ? 'where' : 'which';
  const { status, stdout } = runCommand(exe, [command]);
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
  constructor(hookName) {
    this.hook = hookName;
    this.repoRoot = findGitRoot();
    this.steps = [];
    this.notes = [];
    this.status = 'ok';
    this.exitCode = 0;
    this.plane = detectPlane();
    this.enforcement = resolveEnforcement();
    const enforcementHint =
      this.enforcement === 'fail'
        ? 'Set HOOKS_ENFORCE=warn to treat parity mismatches as warnings during local experiments.'
        : null;

    this.environment = {
      platform: process.platform,
      nodeVersion: process.version,
      pwshPath: null,
      plane: this.plane,
      enforcement: this.enforcement,
      githubActions: process.env.GITHUB_ACTIONS === 'true',
      runnerName: process.env.RUNNER_NAME || null,
      runnerOS: process.env.RUNNER_OS || null,
      runnerArch: process.env.RUNNER_ARCH || null,
      runnerTrackingId: process.env.RUNNER_TRACKING_ID || null,
      job: process.env.GITHUB_JOB || null,
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
      process.env.HOOKS_PWSH,
      'pwsh',
      'pwsh.exe',
      // Common Windows default install location.
      'C:\\\\Program Files\\\\PowerShell\\\\7\\\\pwsh.exe',
    ].filter(Boolean);

    for (const candidate of candidates) {
      if (candidate.includes('\\') || candidate.includes('/')) {
        const { status } = runCommand(candidate, ['-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']);
        if (status === 0) {
          this.environment.pwshPath = candidate;
          return candidate;
        }
      } else {
        const found = which(candidate);
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
            ...process.env,
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

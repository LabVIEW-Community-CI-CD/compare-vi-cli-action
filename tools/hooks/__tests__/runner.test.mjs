import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { HookRunner, detectPlane, findGitRoot, resolveEnforcement } from '../core/runner.mjs';

test('detectPlane detects GitHub Ubuntu', () => {
  const plane = detectPlane({ platform: 'linux', env: { GITHUB_ACTIONS: 'true' } });
  assert.equal(plane, 'github-ubuntu');
});

test('detectPlane detects GitHub Windows', () => {
  const plane = detectPlane({ platform: 'win32', env: { GITHUB_ACTIONS: 'true' } });
  assert.equal(plane, 'github-windows');
});

test('detectPlane detects WSL', () => {
  const plane = detectPlane({ platform: 'linux', env: { WSL_DISTRO_NAME: 'Ubuntu-22.04' } });
  assert.equal(plane, 'linux-wsl');
});

test('detectPlane detects macOS', () => {
  const plane = detectPlane({ platform: 'darwin', env: {} });
  assert.equal(plane, 'macos-bash');
});

test('detectPlane defaults to linux bash', () => {
  const plane = detectPlane({ platform: 'linux', env: {} });
  assert.equal(plane, 'linux-bash');
});

test('resolveEnforcement respects explicit env', () => {
  const mode = resolveEnforcement({ env: { HOOKS_ENFORCE: 'off' } });
  assert.equal(mode, 'off');
});

test('resolveEnforcement defaults to fail on CI', () => {
  const mode = resolveEnforcement({ env: { GITHUB_ACTIONS: 'true' } });
  assert.equal(mode, 'fail');
});

test('resolveEnforcement defaults to warn locally', () => {
  const mode = resolveEnforcement({ env: {} });
  assert.equal(mode, 'warn');
});


test('findGitRoot falls back to module root when git rev-parse fails', () => {
  const fallbackRoot = process.cwd();
  const repoRoot = findGitRoot({
    fallbackRoot,
    commandRunner: () => ({ status: 1, stdout: '', stderr: 'fatal: unsafe repository', error: { code: 'EPERM' } })
  });
  assert.equal(repoRoot, fallbackRoot);
});

test('findGitRoot throws detailed error when git fails and no fallback markers exist', () => {
  const missingFallback = path.join(process.cwd(), 'tests', 'results', '_agent', '__missing-repo-root__');
  assert.throws(
    () =>
      findGitRoot({
        fallbackRoot: missingFallback,
        commandRunner: () => ({ status: 1, stdout: '', stderr: 'fatal: not a git repository', error: { code: 'EPERM' } })
      }),
    /git rev-parse --show-toplevel failed.*error=EPERM/
  );
});

test('HookRunner resolvePwsh honors injected commandRunner for explicit path probes', () => {
  const calls = [];
  const runner = new HookRunner('unit', {
    repoRoot: process.cwd(),
    platform: 'win32',
    env: {
      HOOKS_PWSH: 'C:\\custom\\pwsh.exe'
    },
    commandRunner: (command, args) => {
      calls.push({ command, args });
      if (command === 'C:\\custom\\pwsh.exe') {
        return { status: 0, stdout: '7.4.0', stderr: '', error: null };
      }
      return { status: 1, stdout: '', stderr: '', error: null };
    },
    whichResolver: () => null
  });

  const resolved = runner.resolvePwsh();
  assert.equal(resolved, 'C:\\custom\\pwsh.exe');
  assert.equal(calls.length >= 1, true);
});

test('HookRunner resolvePwsh honors injected whichResolver for named commands', () => {
  const runner = new HookRunner('unit', {
    repoRoot: process.cwd(),
    platform: 'win32',
    env: {},
    commandRunner: () => ({ status: 1, stdout: '', stderr: '', error: null }),
    whichResolver: (command) => {
      if (command === 'pwsh') {
        return 'C:\\Program Files\\PowerShell\\7\\pwsh.exe';
      }
      return null;
    }
  });

  const resolved = runner.resolvePwsh();
  assert.equal(resolved, 'C:\\Program Files\\PowerShell\\7\\pwsh.exe');
});

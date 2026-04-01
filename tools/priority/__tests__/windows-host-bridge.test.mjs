#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildWindowsNodeBridgeSpec,
  buildWindowsPath,
  buildWindowsPowerShellFileBridgeSpec,
  detectWindowsHostBridge,
  resolveRepoWindowsPath,
} from '../windows-host-bridge.mjs';

test('resolveRepoWindowsPath translates the repository root through wslpath', () => {
  const result = resolveRepoWindowsPath('/tmp/repo', (command, args) => {
    assert.equal(command, 'wslpath');
    assert.deepEqual(args, ['-w', '/tmp/repo']);
    return {
      status: 0,
      stdout: '\\\\wsl.localhost\\Ubuntu\\tmp\\repo\r\n',
      stderr: '',
      error: null,
    };
  });

  assert.equal(result, '\\\\wsl.localhost\\Ubuntu\\tmp\\repo');
});

test('detectWindowsHostBridge reports a reachable Windows bridge from Unix when PowerShell and node.exe are available', () => {
  const bridge = detectWindowsHostBridge('/tmp/repo', {
    platform: 'linux',
    pathExists(candidate) {
      return candidate === '/mnt/c/Program Files/PowerShell/7/pwsh.exe';
    },
    runProcessFn(command, args) {
      if (command === 'wslpath') {
        return {
          status: 0,
          stdout: '\\\\wsl.localhost\\Ubuntu\\tmp\\repo\n',
          stderr: '',
          error: null,
        };
      }

      if (
        command === '/mnt/c/Program Files/PowerShell/7/pwsh.exe' &&
        args.includes('$PSVersionTable.PSVersion.ToString()')
      ) {
        return {
          status: 0,
          stdout: '7.5.0\n',
          stderr: '',
          error: null,
        };
      }

      if (
        command === '/mnt/c/Program Files/PowerShell/7/pwsh.exe' &&
        args.includes('(Get-Command node.exe -ErrorAction Stop).Source')
      ) {
        return {
          status: 0,
          stdout: 'C:\\Program Files\\nodejs\\node.exe\r\n',
          stderr: '',
          error: null,
        };
      }

      throw new Error(`Unexpected probe: ${command} ${args.join(' ')}`);
    },
  });

  assert.equal(bridge.status, 'reachable');
  assert.equal(bridge.bridge_mode, 'wsl-windows');
  assert.equal(bridge.coordinator_host_platform, 'Unix');
  assert.equal(bridge.current_host_platform, 'Windows');
  assert.equal(bridge.repo_root_windows, '\\\\wsl.localhost\\Ubuntu\\tmp\\repo');
  assert.equal(bridge.windows_pwsh_path, '/mnt/c/Program Files/PowerShell/7/pwsh.exe');
  assert.equal(bridge.windows_node_path, 'C:\\Program Files\\nodejs\\node.exe');
});

test('detectWindowsHostBridge reports native mode on Windows coordinators', () => {
  const bridge = detectWindowsHostBridge('C:\\repo', { platform: 'win32' });

  assert.equal(bridge.status, 'native');
  assert.equal(bridge.bridge_mode, 'native-windows');
  assert.equal(bridge.coordinator_host_platform, 'Windows');
  assert.equal(bridge.current_host_platform, 'Windows');
  assert.equal(bridge.repo_root_windows, 'C:\\repo');
  assert.equal(bridge.windows_pwsh_path, 'pwsh');
});

test('buildWindowsPath joins UNC and relative Windows segments correctly', () => {
  const result = buildWindowsPath('\\\\wsl.localhost\\Ubuntu\\tmp\\repo', 'tools/priority/windows-host-bridge.mjs');
  assert.equal(result, '\\\\wsl.localhost\\Ubuntu\\tmp\\repo\\tools\\priority\\windows-host-bridge.mjs');
});

test('buildWindowsPowerShellFileBridgeSpec produces an execution-policy-bypass bridge command', () => {
  const spec = buildWindowsPowerShellFileBridgeSpec({
    bridge: {
      repo_root_windows: '\\\\wsl.localhost\\Ubuntu\\tmp\\repo',
      windows_pwsh_path: '/mnt/c/Program Files/PowerShell/7/pwsh.exe',
    },
    scriptRelativePath: 'tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1',
    scriptArgs: ['-ResultsDir', 'C:\\Temp\\comparevi'],
  });

  assert.equal(spec.command, '/mnt/c/Program Files/PowerShell/7/pwsh.exe');
  assert.deepEqual(spec.args.slice(0, 4), ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass']);
  assert.match(spec.script_path_windows, /Invoke-PesterWindowsContainerSurfaceProbe\.ps1$/);
  assert.match(spec.args.at(-1), /Set-Location -LiteralPath/);
  assert.match(spec.args.at(-1), /-ResultsDir/);
  assert.doesNotMatch(spec.args.at(-1), /'-ResultsDir'/);
});

test('buildWindowsNodeBridgeSpec requires node.exe and produces a Windows-node bridge command', () => {
  const spec = buildWindowsNodeBridgeSpec({
    bridge: {
      repo_root_windows: '\\\\wsl.localhost\\Ubuntu\\tmp\\repo',
      windows_pwsh_path: '/mnt/c/Program Files/PowerShell/7/pwsh.exe',
      windows_node_path: 'C:\\Program Files\\nodejs\\node.exe',
    },
    scriptRelativePath: 'tools/priority/windows-workflow-replay-lane.mjs',
    scriptArgs: ['--mode', 'vi-history-scenarios-windows'],
  });

  assert.equal(spec.command, '/mnt/c/Program Files/PowerShell/7/pwsh.exe');
  assert.equal(spec.node_path_windows, 'C:\\Program Files\\nodejs\\node.exe');
  assert.match(spec.script_path_windows, /windows-workflow-replay-lane\.mjs$/);
  assert.match(spec.args.at(-1), /node\.exe/);
  assert.match(spec.args.at(-1), /--mode/);
});

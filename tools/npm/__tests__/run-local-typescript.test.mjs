import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildExecutionPlan,
  isMountedWindowsWorktreeInWsl,
  parseArgs,
  resolveExecutionMode,
  resolveTsxCliPath
} from '../run-local-typescript.mjs';

test('parseArgs preserves script arguments after --', () => {
  const parsed = parseArgs([
    '--project',
    'tsconfig.json',
    '--entry',
    'tools/priority/delivery-agent.ts',
    '--fallback-dist',
    'dist/tools/priority/delivery-agent.js',
    '--',
    'ensure',
    '--sleep-mode'
  ]);

  assert.deepEqual(parsed, {
    project: 'tsconfig.json',
    entry: 'tools/priority/delivery-agent.ts',
    fallbackDist: 'dist/tools/priority/delivery-agent.js',
    scriptArgs: ['ensure', '--sleep-mode']
  });
});

test('resolveExecutionMode prefers tsx locally and compiled mode in hosted environments', () => {
  assert.equal(resolveExecutionMode({ githubActions: false, forceCompiled: false, tsxBinary: 'node_modules/.bin/tsx' }), 'tsx');
  assert.equal(resolveExecutionMode({ githubActions: true, forceCompiled: false, tsxBinary: 'node_modules/.bin/tsx' }), 'compiled');
  assert.equal(resolveExecutionMode({ githubActions: false, forceCompiled: true, tsxBinary: 'node_modules/.bin/tsx' }), 'compiled');
  assert.equal(resolveExecutionMode({ githubActions: false, forceCompiled: false, tsxBinary: null }), 'compiled');
});

test('resolveExecutionMode forces compiled mode for WSL-mounted Windows worktrees', () => {
  assert.equal(
    isMountedWindowsWorktreeInWsl({
      platform: 'linux',
      workingDirectory: '/mnt/e/comparevi-lanes/1827-runtime-daemon-launch',
    }),
    true,
  );
  assert.equal(
    resolveExecutionMode({
      githubActions: false,
      forceCompiled: false,
      tsxBinary: 'node_modules/.bin/tsx',
      mountedWindowsWorktreeInWsl: true,
    }),
    'compiled',
  );
  assert.equal(
    isMountedWindowsWorktreeInWsl({
      platform: 'linux',
      workingDirectory: '/home/codex/repo',
    }),
    false,
  );
});

test('buildExecutionPlan emits tsx locally and node+dist for compiled fallback', () => {
  const tsxPlan = buildExecutionPlan({
    project: 'tsconfig.json',
    entry: 'tools/priority/runtime-daemon.ts',
    fallbackDist: 'dist/tools/priority/runtime-daemon.js',
    scriptArgs: ['--status'],
    mode: 'tsx',
    tsxBinary: 'node_modules/.bin/tsx',
    platform: 'linux'
  });
  assert.deepEqual(tsxPlan, {
    mode: 'tsx',
    command: 'node_modules/.bin/tsx',
    args: ['--tsconfig', 'tsconfig.json', 'tools/priority/runtime-daemon.ts', '--status']
  });

  const compiledPlan = buildExecutionPlan({
    project: 'tsconfig.json',
    entry: 'tools/priority/runtime-daemon.ts',
    fallbackDist: 'dist/tools/priority/runtime-daemon.js',
    scriptArgs: ['--status'],
    mode: 'compiled',
    tsxBinary: 'node_modules/.bin/tsx'
  });
  assert.equal(compiledPlan.mode, 'compiled');
  assert.equal(compiledPlan.command, process.execPath);
  assert.deepEqual(compiledPlan.args, ['dist/tools/priority/runtime-daemon.js', '--status']);
});

test('buildExecutionPlan runs the local tsx cli through node on Windows', () => {
  const plan = buildExecutionPlan({
    project: 'tsconfig.cli.json',
    entry: 'tools/cli/project-portfolio.ts',
    fallbackDist: 'dist/tools/cli/project-portfolio.js',
    scriptArgs: ['check', '--help'],
    mode: 'tsx',
    tsxBinary: 'node_modules/.bin/tsx.cmd',
    tsxCliPath: 'node_modules/tsx/dist/cli.mjs',
    platform: 'win32'
  });

  assert.deepEqual(plan, {
    mode: 'tsx',
    command: process.execPath,
    args: [
      'node_modules/tsx/dist/cli.mjs',
      '--tsconfig',
      'tsconfig.cli.json',
      'tools/cli/project-portfolio.ts',
      'check',
      '--help'
    ]
  });
});

test('resolveTsxCliPath locates the installed tsx cli entrypoint', () => {
  const resolved = resolveTsxCliPath();
  assert.ok(resolved);
  assert.match(resolved, /node_modules[\\/]+tsx[\\/]+dist[\\/]+cli\.mjs$/i);
});

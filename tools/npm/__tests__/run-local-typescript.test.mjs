import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildExecutionPlan,
  parseArgs,
  resolveExecutionMode
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

test('buildExecutionPlan emits tsx locally and node+dist for compiled fallback', () => {
  const tsxPlan = buildExecutionPlan({
    project: 'tsconfig.json',
    entry: 'tools/priority/runtime-daemon.ts',
    fallbackDist: 'dist/tools/priority/runtime-daemon.js',
    scriptArgs: ['--status'],
    mode: 'tsx',
    tsxBinary: 'node_modules/.bin/tsx'
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

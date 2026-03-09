import assert from 'node:assert/strict';
import test from 'node:test';

import { createNpmLaunchSpec, resolveWindowsNpmCliPath } from '../../npm/spawn.mjs';

test('resolveWindowsNpmCliPath locates npm-cli.js relative to node.exe', () => {
  const path = resolveWindowsNpmCliPath(
    'C:\\Program Files\\nodejs\\node.exe',
    (candidate) => candidate === 'C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js',
  );

  assert.equal(path, 'C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js');
});

test('createNpmLaunchSpec uses node plus npm-cli.js directly on Windows', () => {
  const spec = createNpmLaunchSpec(
    ['run', 'priority:project:portfolio:apply', '--', '--program', 'Shared Infra'],
    {},
    'win32',
    'C:\\Program Files\\nodejs\\node.exe',
    (candidate) => candidate === 'C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js',
  );

  assert.deepEqual(spec, {
    command: 'C:\\Program Files\\nodejs\\node.exe',
    args: [
      'C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js',
      'run',
      'priority:project:portfolio:apply',
      '--',
      '--program',
      'Shared Infra',
    ],
  });
});

test('createNpmLaunchSpec uses npm directly on non-Windows platforms', () => {
  const spec = createNpmLaunchSpec(['run', 'build'], {}, 'linux');

  assert.deepEqual(spec, {
    command: 'npm',
    args: ['run', 'build'],
  });
});

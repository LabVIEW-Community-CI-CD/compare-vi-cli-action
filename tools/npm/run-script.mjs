#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { createSanitizedNpmEnv } from './sanitize-env.mjs';
import { createNpmLaunchSpec } from './spawn.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const essentialPackages = [
  'ajv',
  'ajv-formats',
  'argparse',
  'fast-glob',
  'typescript',
  'zod',
  'zod-to-json-schema',
  '@types/argparse',
  '@types/node',
];

function ensureNpmDependencies() {
  const missingPackages = essentialPackages.filter((packageName) => {
    const segments = packageName.split('/');
    return !existsSync(join(repoRoot, 'node_modules', ...segments));
  });

  if (missingPackages.length === 0) {
    return;
  }

  console.error(
    `Missing npm dependencies detected: ${missingPackages.join(', ')}. Running sanitized npm install...`,
  );

  const installer = spawnSync(process.execPath, [join(repoRoot, 'tools', 'npm', 'cli.mjs'), 'install'], {
    cwd: repoRoot,
    stdio: 'inherit',
  });

  if (installer.status !== 0) {
    const message =
      installer.error?.message ??
      `npm install exited with status ${installer.status ?? 'unknown'} while installing ${missingPackages.join(', ')}`;
    throw new Error(message);
  }
}

function printUsage() {
  console.error('Usage: run-script.mjs [npm-options] <script> [-- <script-args>]');
  console.error('Example: run-script.mjs --silent priority:sync');
}

const rawArgs = process.argv.slice(2);
const npmOptions = [];
const optionValueMap = new Set(['--prefix', '-C']);
let index = 0;
while (index < rawArgs.length) {
  const arg = rawArgs[index];
  if (arg === '--') {
    break;
  }
  if (!arg.startsWith('-')) {
    break;
  }
  npmOptions.push(arg);
  index += 1;
  const optionKey = arg.includes('=') ? arg.slice(0, arg.indexOf('=')) : arg;
  if (optionValueMap.has(optionKey) && !arg.includes('=') && index < rawArgs.length && !rawArgs[index].startsWith('-')) {
    npmOptions.push(rawArgs[index]);
    index += 1;
  }
}

if (index >= rawArgs.length) {
  printUsage();
  process.exitCode = 1;
  process.exit();
}

const scriptName = rawArgs[index];
index += 1;
let scriptArgs = [];
if (index < rawArgs.length) {
  if (rawArgs[index] === '--') {
    scriptArgs = rawArgs.slice(index + 1);
  } else {
    scriptArgs = rawArgs.slice(index);
  }
}

const npmArgs = ['run', ...npmOptions, scriptName];
if (scriptArgs.length > 0) {
  npmArgs.push('--', ...scriptArgs);
}

ensureNpmDependencies();

const env = createSanitizedNpmEnv();
const launchSpec = createNpmLaunchSpec(npmArgs, env);

const child = spawn(launchSpec.command, launchSpec.args, {
  env,
  stdio: 'inherit',
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});

child.on('error', (error) => {
  console.error(`Failed to launch npm: ${error.message}`);
  process.exit(1);
});

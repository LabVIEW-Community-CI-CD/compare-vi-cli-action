#!/usr/bin/env node
import { spawn } from 'node:child_process';

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

const env = { ...process.env };
const proxyMappings = [
  { source: 'npm_config_http_proxy', target: 'npm_config_proxy' },
  { source: 'NPM_CONFIG_HTTP_PROXY', target: 'NPM_CONFIG_PROXY' },
];

for (const mapping of proxyMappings) {
  const value = env[mapping.source];
  if (typeof value === 'string' && value.trim() !== '') {
    if (!env[mapping.target]) {
      env[mapping.target] = value;
    }
  }
  delete env[mapping.source];
}

const child = spawn(process.platform === 'win32' ? 'npm.cmd' : 'npm', npmArgs, {
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

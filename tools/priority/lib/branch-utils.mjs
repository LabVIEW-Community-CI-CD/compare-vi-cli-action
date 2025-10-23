#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import process from 'node:process';

const IDENTIFIER_REGEX = /^[A-Za-z0-9._-]+$/;

export function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
    ...options
  });

  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed with exit code ${result.status}`);
  }

  return result.stdout.trim();
}

export function parseSingleValueArg(argv, { usageLines, valueLabel }) {
  const args = argv.slice(2);
  let value;

  for (const arg of args) {
    if (arg === '--help' || arg === '-h') {
      printUsage(usageLines);
      process.exit(0);
    }

    if (arg.startsWith('-')) {
      throw new Error(`Unknown option: ${arg}`);
    }

    if (value) {
      throw new Error(`Too many arguments. Provide a single ${valueLabel}.`);
    }

    value = arg;
  }

  if (!value) {
    printUsage(usageLines);
    process.exit(1);
  }

  return value;
}

export function ensureValidIdentifier(value, { label }) {
  if (!IDENTIFIER_REGEX.test(value)) {
    throw new Error(`Invalid ${label} '${value}'. Use alphanumeric characters plus dash, underscore, or dot.`);
  }
}

export function ensureCleanWorkingTree(runFn = run, message = 'Working tree not clean. Commit or stash changes before running the helper.') {
  const status = runFn('git', ['status', '--porcelain']);
  if (status.length > 0) {
    throw new Error(message);
  }
}

export function ensureBranchDoesNotExist(branch, runFn = run) {
  const probe = spawnSync('git', ['rev-parse', '--verify', '--quiet', branch], {
    encoding: 'utf8',
    stdio: ['ignore', 'ignore', 'inherit']
  });
  if (probe.status === 0) {
    throw new Error(`Branch ${branch} already exists locally. Delete it or choose a new name.`);
  }
}

export function ensureBranchExists(branch, runFn = run) {
  const probe = spawnSync('git', ['rev-parse', '--verify', '--quiet', branch], {
    encoding: 'utf8',
    stdio: ['ignore', 'ignore', 'inherit']
  });
  if (probe.status !== 0) {
    throw new Error(`Branch ${branch} not found locally. Create it before running this helper.`);
  }
}

export function getCurrentBranch(runFn = run) {
  return runFn('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
}

export function getRepoRoot(runFn = run) {
  return runFn('git', ['rev-parse', '--show-toplevel']);
}

function printUsage(lines) {
  for (const line of lines) {
    console.log(line);
  }
}

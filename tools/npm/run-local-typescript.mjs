#!/usr/bin/env node

import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    project: 'tsconfig.json',
    entry: null,
    fallbackDist: null,
    scriptArgs: []
  };
  const args = [...argv];
  while (args.length > 0) {
    const token = args.shift();
    if (token === '--') {
      options.scriptArgs = args;
      break;
    }
    if (token === '--project') {
      options.project = args.shift() || null;
      continue;
    }
    if (token === '--entry') {
      options.entry = args.shift() || null;
      continue;
    }
    if (token === '--fallback-dist') {
      options.fallbackDist = args.shift() || null;
      continue;
    }
    throw new Error(`Unsupported argument '${token}'.`);
  }
  if (!options.entry || !options.fallbackDist) {
    throw new Error('--entry and --fallback-dist are required.');
  }
  return options;
}

export function resolveTtsxBinary(root = repoRoot) {
  const candidates =
    process.platform === 'win32'
      ? [path.join(root, 'node_modules', '.bin', 'tsx.cmd')]
      : [path.join(root, 'node_modules', '.bin', 'tsx')];
  return candidates.find((candidate) => existsSync(candidate)) || null;
}

export function resolveExecutionMode({
  githubActions = process.env.GITHUB_ACTIONS === 'true',
  forceCompiled = process.env.COMPAREVI_FORCE_COMPILED_TS === '1',
  tsxBinary = resolveTtsxBinary(repoRoot)
} = {}) {
  if (!githubActions && !forceCompiled && tsxBinary) {
    return 'tsx';
  }
  return 'compiled';
}

function run(command, args, cwd = repoRoot) {
  const result = spawnSync(command, args, {
    cwd,
    stdio: 'inherit',
    env: process.env
  });
  if (result.error) {
    throw result.error;
  }
  return result.status ?? 0;
}

function ensureCompiledFallback(distPath) {
  if (existsSync(path.join(repoRoot, distPath))) {
    return;
  }
  const buildExitCode = run(process.execPath, [path.join(repoRoot, 'tools', 'npm', 'run-script.mjs'), 'build']);
  if (buildExitCode !== 0) {
    throw new Error(`Failed to build compiled fallback '${distPath}'.`);
  }
}

export function buildExecutionPlan({
  project,
  entry,
  fallbackDist,
  scriptArgs = [],
  mode = resolveExecutionMode(),
  tsxBinary = resolveTtsxBinary(repoRoot)
}) {
  if (mode === 'tsx') {
    return {
      mode,
      command: tsxBinary,
      args: ['--tsconfig', project, entry, ...scriptArgs]
    };
  }
  return {
    mode: 'compiled',
    command: process.execPath,
    args: [fallbackDist, ...scriptArgs]
  };
}

export function printUsage() {
  console.error(
    'Usage: node tools/npm/run-local-typescript.mjs --entry <tools/...ts> --fallback-dist <dist/...js> [--project <tsconfig.json>] [-- <args>]'
  );
}

async function main() {
  const options = parseArgs();
  const mode = resolveExecutionMode();
  if (mode === 'compiled') {
    ensureCompiledFallback(options.fallbackDist);
  }
  const plan = buildExecutionPlan({
    ...options,
    mode
  });
  const exitCode = run(plan.command, plan.args);
  process.exit(exitCode);
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    await main();
  } catch (error) {
    printUsage();
    process.stderr.write(`${error?.message || String(error)}\n`);
    process.exit(1);
  }
}

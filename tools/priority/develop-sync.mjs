#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { resolveActiveForkRemoteName } from './lib/remote-utils.mjs';

const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'issue', 'develop-sync-report.json');
const SUPPORTED_FORK_REMOTES = new Set(['origin', 'personal']);

function printUsage() {
  console.log('Usage: node tools/priority/develop-sync.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --fork-remote <origin|personal|all>  Select which fork remote to sync (default: AGENT_PRIORITY_ACTIVE_FORK_REMOTE or origin).');
  console.log(`  --report <path>                      Write aggregate report JSON (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  -h, --help                           Show this help text and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    forkRemote: null,
    reportPath: DEFAULT_REPORT_PATH,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    if (arg === '--fork-remote' || arg === '--report') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--fork-remote') {
        options.forkRemote = next;
      } else {
        options.reportPath = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return options;
}

export function resolveForkRemoteTargets(value, env = process.env) {
  const selected = String(value || resolveActiveForkRemoteName(env))
    .trim()
    .toLowerCase();
  if (!selected || selected === 'origin') {
    return ['origin'];
  }
  if (selected === 'all') {
    return ['origin', 'personal'];
  }
  if (!SUPPORTED_FORK_REMOTES.has(selected)) {
    throw new Error(`Unsupported --fork-remote '${value}'. Expected origin, personal, or all.`);
  }
  return [selected];
}

export function buildParityReportPath(repoRoot, remote) {
  return path.join(repoRoot, 'tests', 'results', '_agent', 'issue', `${remote}-upstream-parity.json`);
}

export function buildPwshArgs({ repoRoot, remote, parityReportPath }) {
  return [
    '-NoLogo',
    '-NoProfile',
    '-File',
    path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
    '-HeadRemote',
    remote,
    '-ParityReportPath',
    parityReportPath
  ];
}

export function runDevelopSync({
  repoRoot = getRepoRoot(),
  options = parseArgs(),
  env = process.env,
  spawnSyncFn = spawnSync
} = {}) {
  const remotes = resolveForkRemoteTargets(options.forkRemote, env);
  const actions = [];

  for (const remote of remotes) {
    const parityReportPath = buildParityReportPath(repoRoot, remote);
    const args = buildPwshArgs({ repoRoot, remote, parityReportPath });
    const result = spawnSyncFn('pwsh', args, {
      cwd: repoRoot,
      stdio: 'inherit',
      encoding: 'utf8'
    });
    if (result.status !== 0) {
      throw new Error(`priority:develop:sync failed for ${remote}.`);
    }
    actions.push({
      remote,
      parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/')
    });
  }

  const reportPath = path.isAbsolute(options.reportPath) ? options.reportPath : path.join(repoRoot, options.reportPath);
  mkdirSync(path.dirname(reportPath), { recursive: true });
  const report = {
    schema: 'priority/develop-sync-report@v1',
    generatedAt: new Date().toISOString(),
    repositoryRoot: repoRoot,
    remotes,
    actions
  };
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return { report, reportPath };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const { reportPath, report } = runDevelopSync({ options });
  console.log(`[priority:develop-sync] report=${reportPath} remotes=${report.remotes.join(',')}`);
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const code = main(process.argv);
    if (code !== 0) {
      process.exitCode = code;
    }
  } catch (error) {
    console.error(`[priority:develop-sync] ${error.message}`);
    process.exitCode = 1;
  }
}

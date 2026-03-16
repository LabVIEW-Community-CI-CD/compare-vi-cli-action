#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { resolveGitAdminPaths } from './lib/git-admin-paths.mjs';
import { resolveActiveForkRemoteName } from './lib/remote-utils.mjs';
import {
  DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH,
  assertAllowedTransition,
  assertPlaneTransition,
  classifyBranch,
  loadBranchClassContract
} from './lib/branch-classification.mjs';

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

export function buildSyncLockName({ baseRemote = 'upstream', headRemote = 'origin', branch = 'develop' } = {}) {
  return `priority-sync-${baseRemote}-${headRemote}-${branch}.lock`.replace(/[^A-Za-z0-9._-]/g, '_');
}

export function buildSyncAdminPaths({
  repoRoot,
  remote,
  baseRemote = 'upstream',
  branch = 'develop',
  env = process.env,
  spawnSyncFn = spawnSync
}) {
  const adminPaths = resolveGitAdminPaths({
    cwd: repoRoot,
    env,
    spawnSyncFn,
    includeGitPaths: ['config']
  });

  return {
    repoRoot: adminPaths.repoRoot,
    gitDir: adminPaths.gitDir,
    gitCommonDir: adminPaths.gitCommonDir,
    gitConfigPath: adminPaths.gitPaths.config,
    lockPath: path.join(adminPaths.gitCommonDir, buildSyncLockName({ baseRemote, headRemote: remote, branch }))
  };
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

function requireClassifiedBranch({
  branch,
  repositoryRole,
  contract,
  contractPath = DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH
}) {
  const classified = classifyBranch({
    branch,
    contract,
    repositoryRole
  });
  if (!classified) {
    throw new Error(
      `Unable to classify branch '${branch}' for repository role '${repositoryRole}' using '${contractPath}'.`
    );
  }
  return classified;
}

export function buildDevelopSyncBranchClassTrace(repoRoot) {
  const contractPath = DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH.replace(/\\/g, '/');
  const contract = loadBranchClassContract(repoRoot, {
    relativePath: DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH
  });
  const source = requireClassifiedBranch({
    branch: 'develop',
    contract,
    repositoryRole: 'upstream',
    contractPath
  });
  const target = requireClassifiedBranch({
    branch: 'develop',
    contract,
    repositoryRole: 'fork',
    contractPath
  });
  const transition = assertAllowedTransition({
    from: source.id,
    to: target.id,
    action: 'sync',
    contract
  });
  const planeTransitions = {
    origin: assertPlaneTransition({
      fromPlane: 'upstream',
      toPlane: 'origin',
      action: 'sync',
      contract
    }),
    personal: assertPlaneTransition({
      fromPlane: 'upstream',
      toPlane: 'personal',
      action: 'sync',
      contract
    })
  };

  return {
    contractPath,
    source,
    target,
    transition,
    planeTransitions
  };
}

function writeDevelopSyncReport({ repoRoot, reportPath, remotes, actions, status }) {
  mkdirSync(path.dirname(reportPath), { recursive: true });
  const report = {
    schema: 'priority/develop-sync-report@v1',
    generatedAt: new Date().toISOString(),
    repositoryRoot: repoRoot,
    remotes,
    status,
    actions
  };
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return report;
}

function readJsonFile(filePath) {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to read parity report '${filePath}': ${error.message}`);
  }
}

function requirePlaneTransitionEvidence({ remote, parityReport, branchClassTrace, parityReportPath }) {
  const planeTransition = parityReport?.planeTransition;
  if (!planeTransition || !planeTransition.from || !planeTransition.to || !planeTransition.action || !planeTransition.via) {
    throw new Error(`Parity report '${parityReportPath}' is missing required planeTransition metadata for ${remote}.`);
  }

  const expected = branchClassTrace?.planeTransitions?.[remote] ?? null;
  if (!expected) {
    throw new Error(`No expected plane transition recorded for remote '${remote}'.`);
  }
  if (
    planeTransition.from !== expected.from ||
    planeTransition.to !== expected.to ||
    planeTransition.action !== expected.action ||
    planeTransition.via !== expected.via
  ) {
    throw new Error(
      `Parity report '${parityReportPath}' recorded planeTransition ${planeTransition.from}->${planeTransition.to} (${planeTransition.via}) but expected ${expected.from}->${expected.to} (${expected.via}).`
    );
  }

  return planeTransition;
}

function buildActionFromParityReport({
  remote,
  repoRoot,
  parityReportPath,
  adminPaths,
  branchClassTrace,
  parityReport,
  status,
  exitCode,
  error
}) {
  const planeTransition = requirePlaneTransitionEvidence({
    remote,
    parityReport,
    branchClassTrace,
    parityReportPath
  });

  return {
    remote,
    status,
    parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/'),
    adminPaths,
    branchClassTrace,
    planeTransition,
    syncMode: parityReport?.syncResult?.mode ?? 'direct-push',
    syncReason: parityReport?.syncResult?.reason ?? 'direct-push',
    parityConverged:
      typeof parityReport?.syncResult?.parityConverged === 'boolean'
        ? parityReport.syncResult.parityConverged
        : parityReport?.tipDiff?.fileCount === 0,
    protectedSync: parityReport?.syncResult?.protectedSync ?? null,
    recommendation: parityReport?.recommendation ?? null,
    commitDivergence: parityReport?.commitDivergence ?? null,
    exitCode,
    error
  };
}

export function runDevelopSync({
  repoRoot = getRepoRoot(),
  options = parseArgs(),
  env = process.env,
  spawnSyncFn = spawnSync
} = {}) {
  const remotes = resolveForkRemoteTargets(options.forkRemote, env);
  const actions = [];
  const reportPath = path.isAbsolute(options.reportPath) ? options.reportPath : path.join(repoRoot, options.reportPath);
  const branchClassTrace = buildDevelopSyncBranchClassTrace(repoRoot);

  for (const remote of remotes) {
    const parityReportPath = buildParityReportPath(repoRoot, remote);
    const adminPaths = buildSyncAdminPaths({ repoRoot, remote, env, spawnSyncFn });
    const args = buildPwshArgs({ repoRoot, remote, parityReportPath });
    if (existsSync(parityReportPath)) {
      rmSync(parityReportPath, { force: true });
    }
    const result = spawnSyncFn('pwsh', args, {
      cwd: repoRoot,
      stdio: 'inherit',
      encoding: 'utf8'
    });
    if (result.status !== 0) {
      const commandError = String(result.stderr ?? result.stdout ?? '').trim() || `pwsh exited with status ${result.status}`;
      if (existsSync(parityReportPath)) {
        try {
          const parityReport = readJsonFile(parityReportPath);
          actions.push(
            buildActionFromParityReport({
              remote,
              repoRoot,
              parityReportPath,
              adminPaths,
              branchClassTrace,
              parityReport,
              status: 'failed',
              exitCode: result.status,
              error: commandError
            })
          );
        } catch (error) {
          actions.push({
            remote,
            status: 'failed',
            parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/'),
            adminPaths,
            branchClassTrace,
            exitCode: result.status,
            error: error.message
          });
        }
      } else {
        actions.push({
          remote,
          status: 'failed',
          parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/'),
          adminPaths,
          branchClassTrace,
          exitCode: result.status,
          error: commandError
        });
      }
      writeDevelopSyncReport({
        repoRoot,
        reportPath,
        remotes,
        actions,
        status: 'failed'
      });
      throw new Error(`priority:develop:sync failed for ${remote}.`);
    }
    let parityReport;
    try {
      parityReport = readJsonFile(parityReportPath);
    } catch (error) {
      actions.push({
        remote,
        status: 'failed',
        parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/'),
        adminPaths,
        error: error.message
      });
      writeDevelopSyncReport({
        repoRoot,
        reportPath,
        remotes,
        actions,
        status: 'failed'
      });
      throw error;
    }
    try {
      actions.push(
        buildActionFromParityReport({
          remote,
          repoRoot,
          parityReportPath,
          adminPaths,
          branchClassTrace,
          parityReport,
          status: 'ok',
          exitCode: 0,
          error: null
        })
      );
    } catch (error) {
      actions.push({
        remote,
        status: 'failed',
        parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/'),
        adminPaths,
        branchClassTrace,
        error: error.message
      });
      writeDevelopSyncReport({
        repoRoot,
        reportPath,
        remotes,
        actions,
        status: 'failed'
      });
      throw error;
    }
  }
  const report = writeDevelopSyncReport({
    repoRoot,
    reportPath,
    remotes,
    actions,
    status: 'ok'
  });
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

#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';
import { resolveGitAdminPaths } from './lib/git-admin-paths.mjs';
import { resolveActiveForkRemoteName } from './lib/remote-utils.mjs';
import { collectParity } from './report-origin-upstream-parity.mjs';
import {
  DEFAULT_BRANCH_CLASS_CONTRACT_RELATIVE_PATH,
  assertAllowedTransition,
  assertPlaneTransition,
  classifyBranch,
  loadBranchClassContract
} from './lib/branch-classification.mjs';

const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'issue', 'develop-sync-report.json');
const SUPPORTED_FORK_REMOTES = new Set(['origin', 'personal']);
const WORK_BRANCH_PATTERN = /^(issue\/|feature\/|release\/|hotfix\/|bugfix\/)/i;

function printUsage() {
  console.log('Usage: node tools/priority/develop-sync.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(
    '  --fork-remote <origin|personal|all>  Select which fork remote to sync (default: all configured fork remotes, otherwise AGENT_PRIORITY_ACTIVE_FORK_REMOTE or origin).'
  );
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

export function listConfiguredForkRemotes({
  repoRoot = getRepoRoot(),
  env = process.env,
  spawnSyncFn = spawnSync
} = {}) {
  try {
    const remoteText = runGitText(spawnSyncFn, repoRoot, ['remote'], env);
    const configured = remoteText
      .split(/\r?\n/)
      .map((entry) => entry.trim().toLowerCase())
      .filter((entry) => SUPPORTED_FORK_REMOTES.has(entry));
    return [...new Set(configured)];
  } catch {
    return [];
  }
}

export function resolveForkRemoteTargets(
  value,
  env = process.env,
  { repoRoot = getRepoRoot(), spawnSyncFn = spawnSync } = {}
) {
  const explicit = String(value ?? '')
    .trim()
    .toLowerCase();
  const configured = listConfiguredForkRemotes({ repoRoot, env, spawnSyncFn });
  if (!explicit) {
    if (configured.length > 0) {
      return configured;
    }
    const fallback = String(resolveActiveForkRemoteName(env))
      .trim()
      .toLowerCase();
    if (!fallback || fallback === 'origin') {
      return ['origin'];
    }
    if (!SUPPORTED_FORK_REMOTES.has(fallback)) {
      throw new Error(`Unsupported --fork-remote '${fallback}'. Expected origin, personal, or all.`);
    }
    return [fallback];
  }
  if (explicit === 'origin') {
    return ['origin'];
  }
  if (explicit === 'all') {
    return configured.length > 0 ? configured : ['origin', 'personal'];
  }
  if (!SUPPORTED_FORK_REMOTES.has(explicit)) {
    throw new Error(`Unsupported --fork-remote '${value}'. Expected origin, personal, or all.`);
  }
  return [explicit];
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

export function parseGitWorktreeListPorcelain(text) {
  const entries = [];
  let current = null;
  for (const rawLine of String(text ?? '').split(/\r?\n/)) {
    const line = String(rawLine ?? '');
    if (!line.trim()) {
      if (current?.path) entries.push(current);
      current = null;
      continue;
    }
    if (line.startsWith('worktree ')) {
      if (current?.path) entries.push(current);
      current = {
        path: line.slice('worktree '.length).trim(),
        branchRef: null,
        head: null
      };
      continue;
    }
    if (!current) continue;
    if (line.startsWith('branch ')) {
      current.branchRef = line.slice('branch '.length).trim();
      continue;
    }
    if (line.startsWith('HEAD ')) {
      current.head = line.slice('HEAD '.length).trim();
    }
  }
  if (current?.path) entries.push(current);
  return entries;
}

function runGitText(spawnSyncFn, cwd, args, env) {
  const result = spawnSyncFn('git', args, {
    cwd,
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const detail = String(result.stderr ?? result.stdout ?? '').trim() || `git exited with status ${result.status}`;
    throw new Error(detail);
  }
  return String(result.stdout ?? '').trim();
}

function isWorkBranch(branch) {
  return WORK_BRANCH_PATTERN.test(branch);
}

function isDirtyWorktree({ repoRoot, env = process.env, spawnSyncFn = spawnSync } = {}) {
  const statusText = runGitText(spawnSyncFn, repoRoot, ['status', '--porcelain'], env);
  return statusText.length > 0;
}

function findDevelopHelperRoot({
  repoRoot,
  requireClean = false,
  env = process.env,
  spawnSyncFn = spawnSync
} = {}) {
  const worktreeText = runGitText(spawnSyncFn, repoRoot, ['worktree', 'list', '--porcelain'], env);
  const helpers = parseGitWorktreeListPorcelain(worktreeText)
    .map((entry) => ({
      ...entry,
      path: path.resolve(entry.path)
    }))
    .filter((entry) => entry.path !== repoRoot && entry.branchRef === 'refs/heads/develop');

  if (!requireClean) {
    return helpers[0]?.path ?? null;
  }

  for (const helper of helpers) {
    try {
      if (!isDirtyWorktree({ repoRoot: helper.path, env, spawnSyncFn })) {
        return helper.path;
      }
    } catch {}
  }

  return null;
}

function hasDevelopHelperRoot({
  repoRoot,
  env = process.env,
  spawnSyncFn = spawnSync
} = {}) {
  return findDevelopHelperRoot({
    repoRoot,
    requireClean: false,
    env,
    spawnSyncFn
  }) !== null;
}

function writeJsonFile(filePath, payload) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function refreshDevelopTrackingRef({ repoRoot, remote, branch = 'develop', env = process.env, spawnSyncFn = spawnSync }) {
  const trackingRef = `refs/remotes/${remote}/${branch}`;
  const refSpec = `+refs/heads/${branch}:${trackingRef}`;
  runGitText(spawnSyncFn, repoRoot, ['fetch', '--no-tags', remote, refSpec], env);
}

function collectRefRefreshParity({
  repoRoot,
  remote,
  currentBranch,
  parityReportPath,
  env = process.env,
  spawnSyncFn = spawnSync
}) {
  refreshDevelopTrackingRef({ repoRoot, remote: 'upstream', env, spawnSyncFn });
  refreshDevelopTrackingRef({ repoRoot, remote, env, spawnSyncFn });

  const parityReport = collectParity(
    {
      repoRoot,
      baseRef: 'upstream/develop',
      headRef: `${remote}/develop`,
      strict: true
    },
    (command, args) =>
      spawnSyncFn(command, args, {
        cwd: repoRoot,
        env,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe']
      })
  );

  parityReport.syncResult = {
    mode: 'ref-refresh',
    reason: 'dirty-work-branch',
    parityConverged: parityReport?.tipDiff?.fileCount === 0
  };
  parityReport.execution = {
    mode: 'ref-refresh',
    reason: 'dirty-work-branch',
    currentBranch,
    dirtyWorktree: true
  };
  writeJsonFile(parityReportPath, parityReport);
  return parityReport;
}

export function resolveDevelopSyncExecutionRoot({ repoRoot, env = process.env, spawnSyncFn = spawnSync } = {}) {
  const normalizedRepoRoot = path.resolve(repoRoot);
  let currentBranch = '';
  try {
    currentBranch = runGitText(spawnSyncFn, normalizedRepoRoot, ['branch', '--show-current'], env);
  } catch {
    return {
      repoRoot: normalizedRepoRoot,
      executionRepoRoot: normalizedRepoRoot,
      currentBranch: null,
      mode: 'full-sync',
      reason: null,
      dirtyWorktree: false,
      delegated: false,
      helperRoot: null
    };
  }

  if (currentBranch === 'develop') {
    try {
      if (isDirtyWorktree({ repoRoot: normalizedRepoRoot, env, spawnSyncFn })) {
        const helperRoot = findDevelopHelperRoot({
          repoRoot: normalizedRepoRoot,
          requireClean: true,
          env,
          spawnSyncFn
        });
        if (helperRoot) {
          return {
            repoRoot: normalizedRepoRoot,
            executionRepoRoot: helperRoot,
            currentBranch,
            mode: 'full-sync',
            reason: 'dirty-develop-root-helper',
            dirtyWorktree: true,
            delegated: true,
            helperRoot
          };
        }
      }
    } catch {}
  }

  if (!isWorkBranch(currentBranch)) {
    return {
      repoRoot: normalizedRepoRoot,
      executionRepoRoot: normalizedRepoRoot,
      currentBranch,
      mode: 'full-sync',
      reason: null,
      dirtyWorktree: false,
      delegated: false,
      helperRoot: null
    };
  }

  try {
    const helperRoot = findDevelopHelperRoot({
      repoRoot: normalizedRepoRoot,
      requireClean: true,
      env,
      spawnSyncFn
    });
    if (helperRoot) {
      return {
        repoRoot: normalizedRepoRoot,
        executionRepoRoot: helperRoot,
        currentBranch,
        mode: 'full-sync',
        reason: null,
        dirtyWorktree: false,
        delegated: true,
        helperRoot
      };
    }
    if (hasDevelopHelperRoot({ repoRoot: normalizedRepoRoot, env, spawnSyncFn })) {
      return {
        repoRoot: normalizedRepoRoot,
        executionRepoRoot: normalizedRepoRoot,
        currentBranch,
        mode: 'ref-refresh',
        reason: 'dirty-develop-helper',
        dirtyWorktree: false,
        delegated: false,
        helperRoot: null
      };
    }
  } catch {}

  try {
    if (isDirtyWorktree({ repoRoot: normalizedRepoRoot, env, spawnSyncFn })) {
      return {
        repoRoot: normalizedRepoRoot,
        executionRepoRoot: normalizedRepoRoot,
        currentBranch,
        mode: 'ref-refresh',
        reason: 'dirty-work-branch',
        dirtyWorktree: true,
        delegated: false,
        helperRoot: null
      };
    }
  } catch {}

  return {
    repoRoot: normalizedRepoRoot,
    executionRepoRoot: normalizedRepoRoot,
    currentBranch,
    mode: 'full-sync',
    reason: null,
    dirtyWorktree: false,
    delegated: false,
    helperRoot: null
  };
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

function writeDevelopSyncReport({ repoRoot, reportPath, remotes, actions, status, remoteSelection = null }) {
  const report = {
    schema: 'priority/develop-sync-report@v1',
    generatedAt: new Date().toISOString(),
    repositoryRoot: repoRoot,
    remotes,
    remoteSelection,
    status,
    actions
  };
  writeJsonFile(reportPath, report);
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
  executionPlan,
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
    execution: executionPlan
      ? {
          mode: executionPlan.mode ?? 'full-sync',
          reason: executionPlan.reason ?? null,
          currentBranch: executionPlan.currentBranch ?? null,
          dirtyWorktree: executionPlan.dirtyWorktree === true,
          delegated: executionPlan.delegated === true,
          helperRoot: executionPlan.helperRoot ?? null
        }
      : null,
    protectedSync: parityReport?.syncResult?.protectedSync ?? null,
    parityRemediation: parityReport?.syncResult?.parityRemediation ?? null,
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
  const executionPlan = resolveDevelopSyncExecutionRoot({ repoRoot, env, spawnSyncFn });
  const remotes = resolveForkRemoteTargets(options.forkRemote, env, { repoRoot, spawnSyncFn });
  const remoteSelection = {
    requested: options.forkRemote ?? null,
    resolved: remotes,
    summary: remotes.join(', ') || 'origin'
  };
  const actions = [];
  const reportPath = path.isAbsolute(options.reportPath) ? options.reportPath : path.join(repoRoot, options.reportPath);
  const reportHint = path.relative(repoRoot, reportPath).replace(/\\/g, '/');
  const branchClassTrace = buildDevelopSyncBranchClassTrace(repoRoot);
  const failedRemotes = [];
  let firstFailure = null;

  for (const remote of remotes) {
    const parityReportPath = buildParityReportPath(repoRoot, remote);
    const adminPaths = buildSyncAdminPaths({ repoRoot: executionPlan.executionRepoRoot, remote, env, spawnSyncFn });
    if (existsSync(parityReportPath)) {
      rmSync(parityReportPath, { force: true });
    }
    let result = null;
    let commandError = null;
    try {
      if (executionPlan.mode === 'ref-refresh') {
        collectRefRefreshParity({
          repoRoot,
          remote,
          currentBranch: executionPlan.currentBranch,
          parityReportPath,
          env,
          spawnSyncFn
        });
      } else {
        const args = buildPwshArgs({ repoRoot: executionPlan.executionRepoRoot, remote, parityReportPath });
        result = spawnSyncFn('pwsh', args, {
          cwd: executionPlan.executionRepoRoot,
          stdio: 'inherit',
          encoding: 'utf8'
        });
        if (result.status !== 0) {
          commandError = String(result.stderr ?? result.stdout ?? '').trim() || `pwsh exited with status ${result.status}`;
        }
      }
    } catch (error) {
      commandError = error.message;
      result = { status: 1, stdout: '', stderr: error.message };
    }
    const exitCode = result?.status ?? 0;
    if (exitCode !== 0) {
      if (existsSync(parityReportPath)) {
        let parityReport;
        try {
          parityReport = readJsonFile(parityReportPath);
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
          writeDevelopSyncReport({
            repoRoot,
            reportPath,
            remotes,
            remoteSelection,
            actions,
            status: 'failed'
          });
          throw new Error(`${error.message} report=${reportHint}`);
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
              executionPlan,
              status: 'failed',
              exitCode,
              error: commandError
            })
          );
          failedRemotes.push(remote);
          firstFailure ??= new Error(`priority:develop:sync failed for ${remote}. report=${reportHint} error=${commandError}`);
          continue;
        } catch (error) {
          actions.push({
            remote,
            status: 'failed',
            parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/'),
            adminPaths,
            branchClassTrace,
            exitCode,
            error: error.message
          });
          writeDevelopSyncReport({
            repoRoot,
            reportPath,
            remotes,
            remoteSelection,
            actions,
            status: 'failed'
          });
          throw new Error(`${error.message} report=${reportHint}`);
        }
      } else {
        actions.push({
          remote,
          status: 'failed',
          parityReportPath: path.relative(repoRoot, parityReportPath).replace(/\\/g, '/'),
          adminPaths,
          branchClassTrace,
          exitCode,
          error: commandError
        });
      }
      failedRemotes.push(remote);
      firstFailure ??= new Error(`priority:develop:sync failed for ${remote}. report=${reportHint} error=${commandError}`);
      continue;
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
        remoteSelection,
        actions,
        status: 'failed'
      });
      throw new Error(`${error.message} report=${reportHint}`);
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
          executionPlan,
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
        remoteSelection,
        actions,
        status: 'failed'
      });
      throw new Error(`${error.message} report=${reportHint}`);
    }
  }
  if (failedRemotes.length > 0) {
    writeDevelopSyncReport({
      repoRoot,
      reportPath,
      remotes,
      remoteSelection,
      actions,
      status: 'failed'
    });
    if (failedRemotes.length === 1 && firstFailure) {
      throw firstFailure;
    }
    const firstFailureMessage = String(firstFailure?.message ?? 'unknown failure').trim();
    throw new Error(
      `priority:develop:sync failed for ${failedRemotes.join(', ')}. report=${reportHint} firstError=${firstFailureMessage}`
    );
  }
  const report = writeDevelopSyncReport({
    repoRoot,
    reportPath,
    remotes,
    remoteSelection,
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

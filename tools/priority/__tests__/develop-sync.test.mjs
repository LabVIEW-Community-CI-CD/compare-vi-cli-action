#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import {
  existsSync,
  mkdirSync,
  readFileSync as readFileSyncImmediate,
  writeFileSync as writeFileSyncImmediate
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseArgs,
  resolveForkRemoteTargets,
  buildParityReportPath,
  buildPwshArgs,
  buildSyncAdminPaths,
  buildSyncLockName,
  buildDevelopSyncBranchClassTrace,
  runDevelopSync
} from '../develop-sync.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: options.timeout ?? 120000,
    env: options.env ?? process.env
  });

  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed: ${result.stderr || result.stdout || result.status}`);
  }

  return String(result.stdout ?? '').trim();
}

function normalizeGitPath(basePath, rawPath) {
  return path.isAbsolute(rawPath) ? path.normalize(rawPath) : path.normalize(path.resolve(basePath, rawPath));
}

function initRepo(repoDir) {
  run('git', ['init', '--initial-branch=develop', repoDir], { cwd: path.dirname(repoDir) });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: repoDir });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: repoDir });
}

function initTempGitRepo(repoDir) {
  initRepo(repoDir);
  writeFileSyncImmediate(path.join(repoDir, '.gitkeep'), 'temp\n', 'utf8');
  mkdirSync(path.join(repoDir, 'tools', 'policy'), { recursive: true });
  writeFileSyncImmediate(
    path.join(repoDir, 'tools', 'policy', 'branch-classes.json'),
    readFileSyncImmediate(path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'), 'utf8'),
    'utf8'
  );
  run('git', ['add', '.gitkeep'], { cwd: repoDir });
  run('git', ['add', 'tools/policy/branch-classes.json'], { cwd: repoDir });
  run('git', ['commit', '-m', 'temp init'], { cwd: repoDir });
}

function initBareRepo(repoDir) {
  run('git', ['init', '--bare', '--initial-branch=develop', repoDir], { cwd: path.dirname(repoDir) });
}

function readJson(filePath) {
  return JSON.parse(readFileSyncImmediate(filePath, 'utf8'));
}

test('develop-sync parseArgs accepts fork-remote and report overrides', () => {
  const parsed = parseArgs([
    'node',
    'develop-sync.mjs',
    '--fork-remote',
    'all',
    '--report',
    'custom/report.json'
  ]);

  assert.equal(parsed.forkRemote, 'all');
  assert.equal(parsed.reportPath, 'custom/report.json');
});

test('resolveForkRemoteTargets defaults to origin and supports all lanes', () => {
  assert.deepEqual(resolveForkRemoteTargets(null, {}), ['origin']);
  assert.deepEqual(resolveForkRemoteTargets('personal', {}), ['personal']);
  assert.deepEqual(resolveForkRemoteTargets('all', {}), ['origin', 'personal']);
});

test('buildPwshArgs pins the selected remote and parity path', () => {
  const repoRoot = '/tmp/repo';
  const parityReportPath = buildParityReportPath(repoRoot, 'personal');
  const args = buildPwshArgs({
    repoRoot,
    remote: 'personal',
    parityReportPath
  });

  assert.ok(args.includes('-HeadRemote'));
  assert.ok(args.includes('personal'));
  assert.ok(args.includes(parityReportPath));
});

test('buildDevelopSyncBranchClassTrace classifies upstream develop to fork develop as a mirror sync', () => {
  const trace = buildDevelopSyncBranchClassTrace(repoRoot);

  assert.equal(trace.contractPath, 'tools/policy/branch-classes.json');
  assert.equal(trace.source.id, 'upstream-integration');
  assert.equal(trace.target.id, 'fork-mirror-develop');
  assert.equal(trace.transition.action, 'sync');
  assert.equal(trace.transition.via, 'priority:develop:sync');
  assert.equal(trace.planeTransitions.origin.to, 'origin');
  assert.equal(trace.planeTransitions.personal.to, 'personal');
  assert.equal(trace.planeTransitions.origin.via, 'priority:develop:sync');
});

test('Sync-OriginUpstreamDevelop forwards the requested parity report path to the parity reporter', () => {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1');
  const source = readFileSyncImmediate(scriptPath, 'utf8');

  assert.match(source, /report-origin-upstream-parity\.mjs'/);
  assert.match(source, /'--output-path'/);
  assert.match(source, /\$parityReportPath/);
});

test('Sync-OriginUpstreamDevelop retries SSH auth failures against the fetch URL before failing', () => {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1');
  const source = readFileSyncImmediate(scriptPath, 'utf8');

  assert.match(source, /'remote', 'get-url', '--push', \$Remote/);
  assert.match(source, /retrying against fetch URL/);
  assert.match(source, /'credential\.interactive=never'/);
  assert.match(source, /'core\.askpass='/);
  assert.match(source, /Get-SafeRemoteLocation -Location \$fetchUrl/);
  assert.match(source, /Get-SafeRemoteLocation -Location \$pushUrl/);
  assert.match(source, /Get-SafeRemoteLocation -Location \(\[string\]\$_\)/);
  assert.match(source, /\$pushRefSpec = '\{0\}:\{1\}' -f \$resolvedSourceRef, \$resolvedTargetBranch/);
  assert.match(source, /Permission denied \\\(publickey\\\)/);
  assert.match(source, /fetch', '--no-tags', \$Remote, \$refSpec/);
});

test('Sync-OriginUpstreamDevelop routes GH013 through protected sync helper paths', () => {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1');
  const source = readFileSyncImmediate(scriptPath, 'utf8');

  assert.match(source, /function Test-GitHubProtectedBranchFailure/);
  assert.match(source, /function Get-ProtectedBranchSyncReason/);
  assert.match(source, /GH013/);
  assert.match(source, /Changes must be made through a pull request/);
  assert.match(source, /Changes must be made through the merge queue/);
  assert.match(source, /protected-develop-sync-pr\.mjs/);
  assert.match(source, /function Remove-RemoteBranchWithTransportFallback/);
  assert.match(source, /Protected branch rejected direct push to \{0\}\/\{1\}; routing through protected sync helper/);
  assert.match(source, /Protected sync staged via PR path/);
  assert.match(source, /\$attemptSyncReason = Get-ProtectedBranchSyncReason -Message \$message/);
  assert.match(source, /\$attemptSyncMode = 'direct-push'/);
  assert.match(source, /\$attemptSyncMode = \[string\]\(\$attemptProtectedSync\['syncMethod'\] \?\? 'protected-pr'\)/);
  assert.match(source, /if \(\$attemptSyncMode -eq 'fork-sync'\)/);
  assert.match(source, /Remove-RemoteBranchWithTransportFallback -Remote \$HeadRemote -BranchName \$syncBranch/);
  assert.match(source, /\$syncMode = \$attemptSyncMode/);
  assert.match(source, /if \(\$tipDiffCount -ne 0 -and \$syncMode -eq 'protected-pr'\)/);
  assert.match(source, /if \(\(\$attemptSyncMode -eq 'direct-push' -and \$attemptPushTransport\) -or \$attemptSyncMode -eq 'fork-sync'\)/);
  assert.match(source, /else \{\s*Write-Host \("\[sync\] Parity OK for \{0\} vs \{1\}"/s);
  assert.match(source, /function Write-SyncParityReport/);
});

test('Sync-OriginUpstreamDevelop classifies diverged fork planes before retrying direct push', () => {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1');
  const source = readFileSyncImmediate(scriptPath, 'utf8');

  assert.match(source, /function Test-GitPushNonFastForwardFailure/);
  assert.match(source, /function Refresh-ObservedRemoteTrackingRef/);
  assert.match(source, /Refresh-ObservedRemoteTrackingRef -Remote \$HeadRemote -BranchName \$Branch/);
  assert.match(source, /\$attemptSyncReason = 'diverged-fork-plane'/);
  assert.match(source, /\$attemptSyncReason = 'remote-already-converged'/);
  assert.match(source, /Remote already converged for \{0\}\/\{1\} after non-fast-forward rejection/);
  assert.match(source, /diverged-fork-plane: direct push to \{0\}\/\{1\} cannot fast-forward/);
  assert.match(source, /if \(Test-GitPushNonFastForwardFailure -Message \$message\)/);
});

test('buildSyncAdminPaths uses git-common-dir for repo-wide lock serialization in a linked worktree', () => {
  const adminPaths = buildSyncAdminPaths({ repoRoot, remote: 'origin' });
  const gitCommonDirRaw = run('git', ['rev-parse', '--git-common-dir'], { cwd: repoRoot });
  const expectedGitCommonDir = normalizeGitPath(repoRoot, gitCommonDirRaw);
  const expectedLockPath = path.join(
    expectedGitCommonDir,
    buildSyncLockName({ baseRemote: 'upstream', headRemote: 'origin', branch: 'develop' })
  );

  assert.equal(adminPaths.gitCommonDir, expectedGitCommonDir);
  assert.equal(adminPaths.lockPath, expectedLockPath);
  assert.notEqual(
    adminPaths.lockPath,
    path.join(repoRoot, '.git', buildSyncLockName({ baseRemote: 'upstream', headRemote: 'origin', branch: 'develop' }))
  );
});

test('runDevelopSync writes admin-path diagnostics when the underlying sync command fails', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-report-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const reportPath = path.join(tempRoot, 'develop-sync-report.json');
  await assert.rejects(
    async () => runDevelopSync({
      repoRoot,
      options: {
        forkRemote: 'origin',
        reportPath
      },
      spawnSyncFn: (command, args, options) => {
        if (command === 'git') {
          return spawnSync(command, args, options);
        }
        return { status: 1, stdout: '', stderr: 'mocked failure' };
      }
    }),
    /priority:develop:sync failed for origin/i
  );

  assert.equal(existsSync(reportPath), true);
  const report = readJson(reportPath);
  assert.equal(report.status, 'failed');
  assert.equal(report.actions[0].status, 'failed');
  assert.equal(report.actions[0].adminPaths.lockPath.endsWith('.lock'), true);
});

test('runDevelopSync preserves diverged fork classification when the sync script exits non-zero', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-diverged-report-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });
  initTempGitRepo(tempRoot);

  const parityReportPath = path.join(tempRoot, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  await mkdir(path.dirname(parityReportPath), { recursive: true });
  await writeFile(
    parityReportPath,
    JSON.stringify({
      schema: 'origin-upstream-parity@v1',
      status: 'ok',
      tipDiff: { fileCount: 4 },
      commitDivergence: { baseOnly: 2, headOnly: 2 },
      recommendation: {
        code: 'bidirectional-drift',
        summary: 'Both refs diverged with tree drift.'
      },
      planeTransition: {
        from: 'upstream',
        to: 'origin',
        action: 'sync',
        via: 'priority:develop:sync'
      },
      syncResult: {
        mode: 'direct-push',
        reason: 'diverged-fork-plane',
        parityConverged: false,
        planeTransition: {
          from: 'upstream',
          to: 'origin',
          action: 'sync',
          via: 'priority:develop:sync'
        },
        failureMessage: 'non-fast-forward'
      }
    }, null, 2),
    'utf8'
  );

  const reportPath = path.join(tempRoot, 'develop-sync-report.json');
  await assert.rejects(
    async () =>
      runDevelopSync({
        repoRoot: tempRoot,
        options: {
          forkRemote: 'origin',
          reportPath
        },
        spawnSyncFn: (command, args, options = {}) => {
          if (command === 'git') {
            return spawnSync(command, args, {
              ...options,
              cwd: tempRoot,
              encoding: 'utf8',
              stdio: ['ignore', 'pipe', 'pipe']
            });
          }
          if (command === 'pwsh') {
            writeFileSyncImmediate(
              parityReportPath,
              JSON.stringify({
                schema: 'origin-upstream-parity@v1',
                status: 'ok',
                tipDiff: { fileCount: 4 },
                commitDivergence: { baseOnly: 2, headOnly: 2 },
                recommendation: {
                  code: 'bidirectional-drift',
                  summary: 'Both refs diverged with tree drift.'
                },
                planeTransition: {
                  from: 'upstream',
                  to: 'origin',
                  action: 'sync',
                  via: 'priority:develop:sync'
                },
                syncResult: {
                  mode: 'direct-push',
                  reason: 'diverged-fork-plane',
                  parityConverged: false,
                  planeTransition: {
                    from: 'upstream',
                    to: 'origin',
                    action: 'sync',
                    via: 'priority:develop:sync'
                  },
                  failureMessage: 'non-fast-forward'
                }
              }, null, 2),
              'utf8'
            );
            return { status: 1, stdout: '', stderr: 'non-fast-forward' };
          }
          throw new Error(`Unexpected command ${command}`);
        }
      }),
    /priority:develop:sync failed for origin/i
  );

  const report = readJson(reportPath);
  assert.equal(report.status, 'failed');
  assert.equal(report.actions[0].status, 'failed');
  assert.equal(report.actions[0].syncMode, 'direct-push');
  assert.equal(report.actions[0].syncReason, 'diverged-fork-plane');
  assert.equal(report.actions[0].parityConverged, false);
  assert.equal(report.actions[0].recommendation.code, 'bidirectional-drift');
  assert.equal(report.actions[0].commitDivergence.headOnly, 2);
});

test('runDevelopSync ignores stale parity reports when the failed invocation does not rewrite them', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-stale-parity-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });
  initTempGitRepo(tempRoot);

  const parityReportPath = path.join(tempRoot, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  await mkdir(path.dirname(parityReportPath), { recursive: true });
  await writeFile(
    parityReportPath,
    JSON.stringify({
      schema: 'origin-upstream-parity@v1',
      status: 'ok',
      tipDiff: { fileCount: 0 },
      planeTransition: {
        from: 'upstream',
        to: 'origin',
        action: 'sync',
        via: 'priority:develop:sync'
      },
      syncResult: {
        mode: 'direct-push',
        reason: 'stale-report',
        parityConverged: true
      }
    }, null, 2),
    'utf8'
  );

  const reportPath = path.join(tempRoot, 'develop-sync-report.json');
  await assert.rejects(
    async () =>
      runDevelopSync({
        repoRoot: tempRoot,
        options: {
          forkRemote: 'origin',
          reportPath
        },
        spawnSyncFn: (command, args, options = {}) => {
          if (command === 'git') {
            return spawnSync(command, args, {
              ...options,
              cwd: tempRoot,
              encoding: 'utf8',
              stdio: ['ignore', 'pipe', 'pipe']
            });
          }
          if (command === 'pwsh') {
            return { status: 1, stdout: '', stderr: 'failed without rewriting parity' };
          }
          throw new Error(`Unexpected command ${command}`);
        }
      }),
    /priority:develop:sync failed for origin/i
  );

  const report = readJson(reportPath);
  assert.equal(report.status, 'failed');
  assert.equal(report.actions[0].status, 'failed');
  assert.equal(report.actions[0].syncReason, undefined);
  assert.equal(report.actions[0].error, 'failed without rewriting parity');
});

test('runDevelopSync records protected sync mode details from the parity report', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-protected-report-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });
  initTempGitRepo(tempRoot);

  const parityReportPath = path.join(tempRoot, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  await mkdir(path.dirname(parityReportPath), { recursive: true });
  await writeFile(
    parityReportPath,
    JSON.stringify({
      schema: 'origin-upstream-parity@v1',
      status: 'ok',
      tipDiff: { fileCount: 3 },
      planeTransition: {
        from: 'upstream',
        to: 'origin',
        action: 'sync',
        via: 'priority:develop:sync'
      },
      syncResult: {
        mode: 'protected-pr',
        reason: 'protected-branch-gh013',
        parityConverged: false,
        protectedSync: {
          planeTransition: {
            from: 'upstream',
            to: 'origin',
            action: 'sync',
            via: 'priority:develop:sync'
          },
          pullRequest: {
            number: 44,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/pull/44'
          }
        }
      }
    }, null, 2),
    'utf8'
  );

  const reportPath = path.join(tempRoot, 'develop-sync-report.json');
  const { report } = runDevelopSync({
    repoRoot: tempRoot,
    options: {
      forkRemote: 'origin',
      reportPath
    },
    spawnSyncFn: (command, args, options = {}) => {
      if (command === 'git') {
        return spawnSync(command, args, {
          ...options,
          cwd: tempRoot,
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'pipe']
        });
      }
      if (command === 'pwsh') {
        writeFileSyncImmediate(
          parityReportPath,
          JSON.stringify({
            schema: 'origin-upstream-parity@v1',
            status: 'ok',
            tipDiff: { fileCount: 3 },
            planeTransition: {
              from: 'upstream',
              to: 'origin',
              action: 'sync',
              via: 'priority:develop:sync'
            },
            syncResult: {
              mode: 'protected-pr',
              reason: 'protected-branch-gh013',
              parityConverged: false,
              protectedSync: {
                planeTransition: {
                  from: 'upstream',
                  to: 'origin',
                  action: 'sync',
                  via: 'priority:develop:sync'
                },
                pullRequest: {
                  number: 44,
                  url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/pull/44'
                }
              }
            }
          }, null, 2),
          'utf8'
        );
        return { status: 0, stdout: '', stderr: '' };
      }
      throw new Error(`Unexpected command ${command}`);
    }
  });

  assert.equal(report.status, 'ok');
  assert.equal(report.actions[0].syncMode, 'protected-pr');
  assert.equal(report.actions[0].syncReason, 'protected-branch-gh013');
  assert.equal(report.actions[0].parityConverged, false);
  assert.equal(report.actions[0].protectedSync.pullRequest.number, 44);
  assert.equal(report.actions[0].branchClassTrace.source.id, 'upstream-integration');
  assert.equal(report.actions[0].branchClassTrace.target.id, 'fork-mirror-develop');
  assert.equal(report.actions[0].planeTransition.from, 'upstream');
  assert.equal(report.actions[0].planeTransition.to, 'origin');
  assert.equal(report.actions[0].planeTransition.action, 'sync');
});

test('runDevelopSync records fork-sync mode details from the parity report', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-fork-sync-report-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });
  initTempGitRepo(tempRoot);

  const parityReportPath = path.join(tempRoot, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  await mkdir(path.dirname(parityReportPath), { recursive: true });
  await writeFile(
    parityReportPath,
    JSON.stringify({
      schema: 'origin-upstream-parity@v1',
      status: 'ok',
      tipDiff: { fileCount: 0 },
      planeTransition: {
        from: 'upstream',
        to: 'origin',
        action: 'sync',
        via: 'priority:develop:sync'
      },
      syncResult: {
        mode: 'fork-sync',
        reason: 'protected-branch-gh013',
        parityConverged: true,
        protectedSync: {
          planeTransition: {
            from: 'upstream',
            to: 'origin',
            action: 'sync',
            via: 'priority:develop:sync'
          },
          syncMethod: 'fork-sync',
          mergeUpstream: {
            message: 'Branch synced',
            merge_type: 'fast-forward'
          }
        }
      }
    }, null, 2),
    'utf8'
  );

  const reportPath = path.join(tempRoot, 'develop-sync-report.json');
  const { report } = runDevelopSync({
    repoRoot: tempRoot,
    options: {
      forkRemote: 'origin',
      reportPath
    },
    spawnSyncFn: (command, args, options = {}) => {
      if (command === 'git') {
        return spawnSync(command, args, {
          ...options,
          cwd: tempRoot,
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'pipe']
        });
      }
      if (command === 'pwsh') {
        writeFileSyncImmediate(
          parityReportPath,
          JSON.stringify({
            schema: 'origin-upstream-parity@v1',
            status: 'ok',
            tipDiff: { fileCount: 0 },
            planeTransition: {
              from: 'upstream',
              to: 'origin',
              action: 'sync',
              via: 'priority:develop:sync'
            },
            syncResult: {
              mode: 'fork-sync',
              reason: 'protected-branch-gh013',
              parityConverged: true,
              protectedSync: {
                planeTransition: {
                  from: 'upstream',
                  to: 'origin',
                  action: 'sync',
                  via: 'priority:develop:sync'
                },
                syncMethod: 'fork-sync',
                mergeUpstream: {
                  message: 'Branch synced',
                  merge_type: 'fast-forward'
                }
              }
            }
          }, null, 2),
          'utf8'
        );
        return { status: 0, stdout: '', stderr: '' };
      }
      throw new Error(`Unexpected command ${command}`);
    }
  });

  assert.equal(report.status, 'ok');
  assert.equal(report.actions[0].syncMode, 'fork-sync');
  assert.equal(report.actions[0].parityConverged, true);
  assert.equal(report.actions[0].protectedSync.syncMethod, 'fork-sync');
  assert.equal(report.actions[0].protectedSync.mergeUpstream.merge_type, 'fast-forward');
  assert.equal(report.actions[0].planeTransition.to, 'origin');
});

test('runDevelopSync fails closed when the parity report omits plane transition evidence', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-missing-plane-transition-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });
  initTempGitRepo(tempRoot);

  const parityReportPath = path.join(tempRoot, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  await mkdir(path.dirname(parityReportPath), { recursive: true });
  await writeFile(
    parityReportPath,
    JSON.stringify({
      schema: 'origin-upstream-parity@v1',
      status: 'ok',
      tipDiff: { fileCount: 0 },
      syncResult: {
        mode: 'direct-push',
        reason: 'direct-push',
        parityConverged: true
      }
    }, null, 2),
    'utf8'
  );

  const reportPath = path.join(tempRoot, 'develop-sync-report.json');
  await assert.rejects(
    async () =>
      runDevelopSync({
        repoRoot: tempRoot,
        options: {
          forkRemote: 'origin',
          reportPath
        },
        spawnSyncFn: (command, args, options = {}) => {
          if (command === 'git') {
            return spawnSync(command, args, {
              ...options,
              cwd: tempRoot,
              encoding: 'utf8',
              stdio: ['ignore', 'pipe', 'pipe']
            });
          }
          if (command === 'pwsh') {
            writeFileSyncImmediate(
              parityReportPath,
              JSON.stringify({
                schema: 'origin-upstream-parity@v1',
                status: 'ok',
                tipDiff: { fileCount: 0 },
                syncResult: {
                  mode: 'direct-push',
                  reason: 'direct-push',
                  parityConverged: true
                }
              }, null, 2),
              'utf8'
            );
            return { status: 0, stdout: '', stderr: '' };
          }
          throw new Error(`Unexpected command ${command}`);
        }
      }),
    /missing required planeTransition metadata/i
  );

  const report = readJson(reportPath);
  assert.equal(report.status, 'failed');
  assert.match(report.actions[0].error, /planeTransition metadata/i);
});

test('runDevelopSync fails closed when the parity report is unreadable', async (t) => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-bad-parity-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });
  initTempGitRepo(tempRoot);

  const parityReportPath = path.join(tempRoot, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  await mkdir(path.dirname(parityReportPath), { recursive: true });
  await writeFile(parityReportPath, '{not-valid-json', 'utf8');

  const reportPath = path.join(tempRoot, 'develop-sync-report.json');
  await assert.rejects(
    async () =>
      runDevelopSync({
        repoRoot: tempRoot,
        options: {
          forkRemote: 'origin',
          reportPath
        },
        spawnSyncFn: (command, args, options = {}) => {
          if (command === 'git') {
            return spawnSync(command, args, {
              ...options,
              cwd: tempRoot,
              encoding: 'utf8',
              stdio: ['ignore', 'pipe', 'pipe']
            });
          }
          if (command === 'pwsh') {
            return { status: 0, stdout: '', stderr: '' };
          }
          throw new Error(`Unexpected command ${command}`);
        }
      }),
    /Unable to read parity report/
  );

  const report = readJson(reportPath);
  assert.equal(report.status, 'failed');
  assert.equal(report.actions[0].status, 'failed');
  assert.match(report.actions[0].error, /Unable to read parity report/);
});

test('Sync-OriginUpstreamDevelop succeeds from a linked worktree and writes admin paths into parity diagnostics', async (t) => {
  const sandboxRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-worktree-'));
  const upstreamBare = path.join(sandboxRoot, 'upstream.git');
  const originBare = path.join(sandboxRoot, 'origin.git');
  const seedRepo = path.join(sandboxRoot, 'seed');
  const controlRepo = path.join(sandboxRoot, 'control');
  const worktreeRepo = path.join(sandboxRoot, 'worktree');
  const updaterRepo = path.join(sandboxRoot, 'updater');
  t.after(async () => {
    await rm(sandboxRoot, { recursive: true, force: true });
  });

  initBareRepo(upstreamBare);
  initBareRepo(originBare);

  initRepo(seedRepo);
  await writeFile(path.join(seedRepo, 'README.md'), 'seed\n', 'utf8');
  run('git', ['add', 'README.md'], { cwd: seedRepo });
  run('git', ['commit', '-m', 'seed'], { cwd: seedRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: seedRepo });
  run('git', ['remote', 'add', 'origin', originBare], { cwd: seedRepo });
  run('git', ['push', 'upstream', 'develop'], { cwd: seedRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: seedRepo });

  run('git', ['clone', originBare, controlRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: controlRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: controlRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: controlRepo });
  run('git', ['fetch', 'upstream'], { cwd: controlRepo });
  run('git', ['worktree', 'add', '-b', 'issue/test-sync', worktreeRepo, 'develop'], { cwd: controlRepo });
  run('git', ['checkout', '--detach'], { cwd: controlRepo });

  await mkdir(path.join(worktreeRepo, 'tools', 'priority'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'priority', 'lib'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'policy'), { recursive: true });
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
    path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'report-origin-upstream-parity.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'report-origin-upstream-parity.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'lib', 'branch-classification.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'lib', 'branch-classification.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'),
    path.join(worktreeRepo, 'tools', 'policy', 'branch-classes.json')
  );

  run('git', ['clone', upstreamBare, updaterRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: updaterRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: updaterRepo });
  await writeFile(path.join(updaterRepo, 'CHANGE.txt'), 'upstream advance\n', 'utf8');
  run('git', ['add', 'CHANGE.txt'], { cwd: updaterRepo });
  run('git', ['commit', '-m', 'advance upstream'], { cwd: updaterRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: updaterRepo });

  const parityReportPath = path.join(worktreeRepo, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  run(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
      '-HeadRemote',
      'origin',
      '-ParityReportPath',
      parityReportPath
    ],
    { cwd: worktreeRepo, timeout: 180000 }
  );

  run('git', ['fetch', 'origin', 'develop'], { cwd: controlRepo });
  run('git', ['fetch', 'upstream', 'develop'], { cwd: controlRepo });

  const originHead = run('git', ['--git-dir', originBare, 'rev-parse', 'develop'], { cwd: sandboxRoot });
  const upstreamHead = run('git', ['--git-dir', upstreamBare, 'rev-parse', 'develop'], { cwd: sandboxRoot });
  assert.equal(originHead, upstreamHead);
  assert.equal(run('git', ['branch', '--show-current'], { cwd: worktreeRepo }), 'issue/test-sync');

  const parityReport = JSON.parse(await readFile(parityReportPath, 'utf8'));
  assert.equal(parityReport.tipDiff.fileCount, 0);
  assert.equal(typeof parityReport.adminPaths.gitDir, 'string');
  assert.equal(typeof parityReport.adminPaths.gitCommonDir, 'string');
  assert.equal(typeof parityReport.adminPaths.lockPath, 'string');
  assert.equal(parityReport.adminPaths.lockPath.startsWith(parityReport.adminPaths.gitCommonDir), true);
  assert.notEqual(parityReport.adminPaths.lockPath, path.join(worktreeRepo, '.git', buildSyncLockName()));
});

test('Sync-OriginUpstreamDevelop refreshes the local tracking ref after SSH fallback push succeeds', async (t) => {
  const sandboxRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-fallback-'));
  const upstreamBare = path.join(sandboxRoot, 'upstream.git');
  const originBare = path.join(sandboxRoot, 'origin.git');
  const seedRepo = path.join(sandboxRoot, 'seed');
  const controlRepo = path.join(sandboxRoot, 'control');
  const worktreeRepo = path.join(sandboxRoot, 'worktree');
  const updaterRepo = path.join(sandboxRoot, 'updater');
  const fakeSshPath = path.join(sandboxRoot, process.platform === 'win32' ? 'fake-ssh.cmd' : 'fake-ssh.sh');
  const fakeSshCommand =
    process.platform === 'win32'
      ? `cmd /c "${fakeSshPath}"`
      : `sh "${fakeSshPath}"`;
  t.after(async () => {
    await rm(sandboxRoot, { recursive: true, force: true });
  });

  initBareRepo(upstreamBare);
  initBareRepo(originBare);

  initRepo(seedRepo);
  await writeFile(path.join(seedRepo, 'README.md'), 'seed\n', 'utf8');
  run('git', ['add', 'README.md'], { cwd: seedRepo });
  run('git', ['commit', '-m', 'seed'], { cwd: seedRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: seedRepo });
  run('git', ['remote', 'add', 'origin', originBare], { cwd: seedRepo });
  run('git', ['push', 'upstream', 'develop'], { cwd: seedRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: seedRepo });

  run('git', ['clone', originBare, controlRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: controlRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: controlRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: controlRepo });
  run('git', ['fetch', 'upstream'], { cwd: controlRepo });
  run('git', ['worktree', 'add', '-b', 'issue/test-sync-fallback', worktreeRepo, 'develop'], { cwd: controlRepo });
  run('git', ['checkout', '--detach'], { cwd: controlRepo });

  await mkdir(path.join(worktreeRepo, 'tools', 'priority'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'priority', 'lib'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'policy'), { recursive: true });
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
    path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'report-origin-upstream-parity.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'report-origin-upstream-parity.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'lib', 'branch-classification.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'lib', 'branch-classification.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'),
    path.join(worktreeRepo, 'tools', 'policy', 'branch-classes.json')
  );

  await writeFile(
    fakeSshPath,
    process.platform === 'win32'
      ? '@echo off\r\n>&2 echo Permission denied (publickey).\r\nexit /b 255\r\n'
      : '#!/bin/sh\nprintf \'Permission denied (publickey).\\n\' >&2\nexit 255\n',
    'utf8'
  );
  run('git', ['remote', 'set-url', '--push', 'origin', 'git@github.com:LabVIEW-Community-CI-CD/compare-vi-cli-action-fork.git'], {
    cwd: controlRepo
  });

  run('git', ['clone', upstreamBare, updaterRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: updaterRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: updaterRepo });
  await writeFile(path.join(updaterRepo, 'CHANGE.txt'), 'upstream advance\n', 'utf8');
  run('git', ['add', 'CHANGE.txt'], { cwd: updaterRepo });
  run('git', ['commit', '-m', 'advance upstream'], { cwd: updaterRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: updaterRepo });

  const parityReportPath = path.join(worktreeRepo, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  run(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
      '-HeadRemote',
      'origin',
      '-ParityReportPath',
      parityReportPath
    ],
    {
      cwd: worktreeRepo,
      timeout: 180000,
      env: {
        ...process.env,
        GIT_SSH_COMMAND: fakeSshCommand
      }
    }
  );

  const upstreamHead = run('git', ['--git-dir', upstreamBare, 'rev-parse', 'develop'], { cwd: sandboxRoot });
  const remoteTrackingHead = run('git', ['rev-parse', '--verify', 'origin/develop'], { cwd: worktreeRepo });
  assert.equal(remoteTrackingHead, upstreamHead);

  const parityReport = JSON.parse(await readFile(parityReportPath, 'utf8'));
  assert.equal(parityReport.tipDiff.fileCount, 0);
  assert.equal(parityReport.pushTransport.usedFallback, true);
});

test('Sync-OriginUpstreamDevelop targeted refresh detects a newer remote head instead of clobbering it', async (t) => {
  const sandboxRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-refresh-guard-'));
  const upstreamBare = path.join(sandboxRoot, 'upstream.git');
  const originBare = path.join(sandboxRoot, 'origin.git');
  const seedRepo = path.join(sandboxRoot, 'seed');
  const controlRepo = path.join(sandboxRoot, 'control');
  const updaterRepo = path.join(sandboxRoot, 'updater');
  const worktreeRepo = path.join(sandboxRoot, 'worktree');
  t.after(async () => {
    await rm(sandboxRoot, { recursive: true, force: true });
  });

  initBareRepo(upstreamBare);
  initBareRepo(originBare);

  initRepo(seedRepo);
  await writeFile(path.join(seedRepo, 'README.md'), 'seed\n', 'utf8');
  run('git', ['add', 'README.md'], { cwd: seedRepo });
  run('git', ['commit', '-m', 'seed'], { cwd: seedRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: seedRepo });
  run('git', ['remote', 'add', 'origin', originBare], { cwd: seedRepo });
  run('git', ['push', 'upstream', 'develop'], { cwd: seedRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: seedRepo });

  run('git', ['clone', originBare, controlRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: controlRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: controlRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: controlRepo });
  run('git', ['fetch', 'upstream'], { cwd: controlRepo });
  run('git', ['worktree', 'add', '-b', 'issue/test-sync-refresh-guard', worktreeRepo, 'develop'], { cwd: controlRepo });
  run('git', ['checkout', '--detach'], { cwd: controlRepo });

  await mkdir(path.join(worktreeRepo, 'tools', 'priority'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'priority', 'lib'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'policy'), { recursive: true });
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
    path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'report-origin-upstream-parity.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'report-origin-upstream-parity.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'lib', 'branch-classification.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'lib', 'branch-classification.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'),
    path.join(worktreeRepo, 'tools', 'policy', 'branch-classes.json')
  );

  run('git', ['clone', upstreamBare, updaterRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: updaterRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: updaterRepo });
  await writeFile(path.join(updaterRepo, 'CHANGE.txt'), 'upstream advance\n', 'utf8');
  run('git', ['add', 'CHANGE.txt'], { cwd: updaterRepo });
  run('git', ['commit', '-m', 'advance upstream'], { cwd: updaterRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: updaterRepo });

  const source = readFileSyncImmediate(path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'), 'utf8');
  const mutatedSource = source
    .replace(
      "Invoke-Git -Arguments @('fetch', '--no-tags', $Remote, $refSpec) | Out-Null",
      `Write-Host "[test-hook] simulate concurrent remote advance"
  $advancerPath = Join-Path $env:COMPAREVI_SYNC_TEST_CONCURRENT_UPDATE_ROOT 'advancer'
  if (-not (Test-Path -LiteralPath $advancerPath)) {
    git clone $env:COMPAREVI_SYNC_TEST_ORIGIN_BARE $advancerPath | Out-Null
  }
  Push-Location -LiteralPath $advancerPath
  try {
    git config user.email agent@example.com | Out-Null
    git config user.name "Agent Runner" | Out-Null
    "remote moved\`n" | Set-Content -LiteralPath concurrent.txt -Encoding utf8
    git add concurrent.txt | Out-Null
    git commit -m "advance origin again" | Out-Null
    git push origin develop | Out-Null
  }
  finally {
    Pop-Location
  }
  Invoke-Git -Arguments @('fetch', '--no-tags', $Remote, $refSpec) | Out-Null`
    );
  await writeFile(path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'), mutatedSource, 'utf8');

  const parityReportPath = path.join(worktreeRepo, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  const result = spawnSync(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
      '-HeadRemote',
      'origin',
      '-ParityReportPath',
      parityReportPath
    ],
    {
      cwd: worktreeRepo,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 180000,
      env: {
        ...process.env,
        COMPAREVI_SYNC_TEST_CONCURRENT_UPDATE_ROOT: sandboxRoot,
        COMPAREVI_SYNC_TEST_ORIGIN_BARE: originBare
      }
    }
  );

  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /Remote tracking ref .* expected/);
});

test('Sync-OriginUpstreamDevelop fails closed on diverged fork develop without retrying direct push', async (t) => {
  const sandboxRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-diverged-fork-'));
  const upstreamBare = path.join(sandboxRoot, 'upstream.git');
  const originBare = path.join(sandboxRoot, 'origin.git');
  const seedRepo = path.join(sandboxRoot, 'seed');
  const controlRepo = path.join(sandboxRoot, 'control');
  const originUpdaterRepo = path.join(sandboxRoot, 'origin-updater');
  const upstreamUpdaterRepo = path.join(sandboxRoot, 'upstream-updater');
  const worktreeRepo = path.join(sandboxRoot, 'worktree');
  t.after(async () => {
    await rm(sandboxRoot, { recursive: true, force: true });
  });

  initBareRepo(upstreamBare);
  initBareRepo(originBare);

  initRepo(seedRepo);
  await writeFile(path.join(seedRepo, 'README.md'), 'seed\n', 'utf8');
  run('git', ['add', 'README.md'], { cwd: seedRepo });
  run('git', ['commit', '-m', 'seed'], { cwd: seedRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: seedRepo });
  run('git', ['remote', 'add', 'origin', originBare], { cwd: seedRepo });
  run('git', ['push', 'upstream', 'develop'], { cwd: seedRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: seedRepo });

  run('git', ['clone', originBare, originUpdaterRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: originUpdaterRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: originUpdaterRepo });
  await writeFile(path.join(originUpdaterRepo, 'ORIGIN.txt'), 'origin-only\n', 'utf8');
  run('git', ['add', 'ORIGIN.txt'], { cwd: originUpdaterRepo });
  run('git', ['commit', '-m', 'origin diverges'], { cwd: originUpdaterRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: originUpdaterRepo });

  run('git', ['clone', upstreamBare, upstreamUpdaterRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: upstreamUpdaterRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: upstreamUpdaterRepo });
  await writeFile(path.join(upstreamUpdaterRepo, 'UPSTREAM.txt'), 'upstream-only\n', 'utf8');
  run('git', ['add', 'UPSTREAM.txt'], { cwd: upstreamUpdaterRepo });
  run('git', ['commit', '-m', 'upstream diverges'], { cwd: upstreamUpdaterRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: upstreamUpdaterRepo });

  run('git', ['clone', upstreamBare, controlRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: controlRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: controlRepo });
  run('git', ['remote', 'rename', 'origin', 'upstream'], { cwd: controlRepo });
  run('git', ['remote', 'add', 'origin', originBare], { cwd: controlRepo });
  run('git', ['fetch', 'origin'], { cwd: controlRepo });
  run('git', ['worktree', 'add', '-b', 'issue/test-sync-diverged', worktreeRepo, 'develop'], { cwd: controlRepo });
  run('git', ['checkout', '--detach'], { cwd: controlRepo });

  await mkdir(path.join(worktreeRepo, 'tools', 'priority'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'priority', 'lib'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'policy'), { recursive: true });
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
    path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'report-origin-upstream-parity.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'report-origin-upstream-parity.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'lib', 'branch-classification.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'lib', 'branch-classification.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'),
    path.join(worktreeRepo, 'tools', 'policy', 'branch-classes.json')
  );

  const parityReportPath = path.join(worktreeRepo, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  const result = spawnSync(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
      '-HeadRemote',
      'origin',
      '-ParityReportPath',
      parityReportPath
    ],
    {
      cwd: worktreeRepo,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 180000
    }
  );

  assert.notEqual(result.status, 0);
  assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, /Attempt 2\/3/);
  assert.match(`${result.stdout}\n${result.stderr}`, /diverged-fork-plane/);

  const parityReport = JSON.parse(await readFile(parityReportPath, 'utf8'));
  assert.equal(parityReport.syncResult.mode, 'direct-push');
  assert.equal(parityReport.syncResult.reason, 'diverged-fork-plane');
  assert.equal(parityReport.syncResult.parityConverged, false);
  assert.equal(parityReport.recommendation.code, 'bidirectional-drift');
  assert.equal(parityReport.commitDivergence.baseOnly > 0, true);
  assert.equal(parityReport.commitDivergence.headOnly > 0, true);
});

test('Sync-OriginUpstreamDevelop treats GH013 as a protected sync PR handoff instead of failing', async (t) => {
  const sandboxRoot = await mkdtemp(path.join(os.tmpdir(), 'develop-sync-protected-pr-'));
  const upstreamBare = path.join(sandboxRoot, 'upstream.git');
  const originBare = path.join(sandboxRoot, 'origin.git');
  const seedRepo = path.join(sandboxRoot, 'seed');
  const controlRepo = path.join(sandboxRoot, 'control');
  const worktreeRepo = path.join(sandboxRoot, 'worktree');
  const updaterRepo = path.join(sandboxRoot, 'updater');
  t.after(async () => {
    await rm(sandboxRoot, { recursive: true, force: true });
  });

  initBareRepo(upstreamBare);
  initBareRepo(originBare);

  initRepo(seedRepo);
  await writeFile(path.join(seedRepo, 'README.md'), 'seed\n', 'utf8');
  run('git', ['add', 'README.md'], { cwd: seedRepo });
  run('git', ['commit', '-m', 'seed'], { cwd: seedRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: seedRepo });
  run('git', ['remote', 'add', 'origin', originBare], { cwd: seedRepo });
  run('git', ['push', 'upstream', 'develop'], { cwd: seedRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: seedRepo });

  run('git', ['clone', originBare, controlRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: controlRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: controlRepo });
  run('git', ['remote', 'add', 'upstream', upstreamBare], { cwd: controlRepo });
  run('git', ['fetch', 'upstream'], { cwd: controlRepo });
  run('git', ['worktree', 'add', '-b', 'issue/test-sync-protected', worktreeRepo, 'develop'], { cwd: controlRepo });
  run('git', ['checkout', '--detach'], { cwd: controlRepo });

  await mkdir(path.join(worktreeRepo, 'tools', 'priority'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'priority', 'lib'), { recursive: true });
  await mkdir(path.join(worktreeRepo, 'tools', 'policy'), { recursive: true });
  const source = readFileSyncImmediate(path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'), 'utf8');
  const protectedSource = source.replace(
    "$attemptPushTransport = Invoke-PushWithTransportFallback -Remote $HeadRemote -BranchName $Branch",
    "throw \"GH013: Changes must be made through a pull request. Changes must be made through the merge queue.\""
  );
  await writeFile(path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'), protectedSource, 'utf8');
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'report-origin-upstream-parity.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'report-origin-upstream-parity.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'lib', 'branch-classification.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'lib', 'branch-classification.mjs')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'),
    path.join(worktreeRepo, 'tools', 'policy', 'branch-classes.json')
  );
  await writeFile(
    path.join(worktreeRepo, 'tools', 'priority', 'protected-develop-sync-pr.mjs'),
    `#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
const reportIndex = args.indexOf('--report-path');
const reportPath = reportIndex >= 0 ? args[reportIndex + 1] : path.join(process.cwd(), 'tests/results/_agent/issue/protected-report.json');
const syncIndex = args.indexOf('--sync-branch');
const syncBranch = syncIndex >= 0 ? args[syncIndex + 1] : 'sync/origin-develop';
mkdirSync(path.dirname(reportPath), { recursive: true });
writeFileSync(reportPath, JSON.stringify({
  schema: 'priority/protected-develop-sync@v1',
  generatedAt: '2026-03-12T00:00:00.000Z',
  targetRemote: 'origin',
  baseRemote: 'upstream',
  branch: 'develop',
  syncBranch,
  reason: 'protected-branch-gh013',
  planeTransition: {
    from: 'upstream',
    to: 'origin',
    action: 'sync',
    via: 'priority:develop:sync'
  },
  pullRequest: {
    number: 55,
    url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/pull/55',
    isDraft: false,
    mergeStateStatus: 'BLOCKED',
    reusedExisting: false
  },
  readyState: { status: 'marked-ready' },
  mergeRequest: { status: 'requested' }
}, null, 2) + '\\n', 'utf8');
`,
    'utf8'
  );

  run('git', ['clone', upstreamBare, updaterRepo], { cwd: sandboxRoot });
  run('git', ['config', 'user.email', 'agent@example.com'], { cwd: updaterRepo });
  run('git', ['config', 'user.name', 'Agent Runner'], { cwd: updaterRepo });
  await writeFile(path.join(updaterRepo, 'CHANGE.txt'), 'upstream advance\n', 'utf8');
  run('git', ['add', 'CHANGE.txt'], { cwd: updaterRepo });
  run('git', ['commit', '-m', 'advance upstream'], { cwd: updaterRepo });
  run('git', ['push', 'origin', 'develop'], { cwd: updaterRepo });

  const parityReportPath = path.join(worktreeRepo, 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  run(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-File',
      path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
      '-HeadRemote',
      'origin',
      '-ParityReportPath',
      parityReportPath
    ],
    { cwd: worktreeRepo, timeout: 180000 }
  );

  const parityReport = JSON.parse(await readFile(parityReportPath, 'utf8'));
  assert.equal(parityReport.planeTransition.from, 'upstream');
  assert.equal(parityReport.planeTransition.to, 'origin');
  assert.equal(parityReport.syncResult.mode, 'protected-pr');
  assert.equal(parityReport.syncResult.reason, 'protected-branch-gh013');
  assert.equal(parityReport.syncResult.parityConverged, false);
  assert.equal(parityReport.syncResult.planeTransition.to, 'origin');
  assert.equal(parityReport.syncResult.protectedSync.pullRequest.number, 55);
  assert.equal(parityReport.tipDiff.fileCount > 0, true);
});

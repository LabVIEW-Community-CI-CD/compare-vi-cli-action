#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync as readFileSyncImmediate } from 'node:fs';
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
  runDevelopSync
} from '../develop-sync.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: options.timeout ?? 120000
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
  assert.match(source, /\("\{0\}:\{0\}" -f \$BranchName\)/);
  assert.match(source, /Permission denied \\\(publickey\\\)/);
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
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1'),
    path.join(worktreeRepo, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1')
  );
  await copyFile(
    path.join(repoRoot, 'tools', 'priority', 'report-origin-upstream-parity.mjs'),
    path.join(worktreeRepo, 'tools', 'priority', 'report-origin-upstream-parity.mjs')
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

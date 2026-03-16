import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distRoot = path.join(repoRoot, 'dist', 'tools', 'priority');

let builtModulePromise = null;

async function loadModules() {
  if (!builtModulePromise) {
    const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
    assert.equal(buildResult.status, 0, [buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'));
      builtModulePromise = Promise.all([
      import(`${pathToFileURL(path.join(distRoot, 'lib', 'delivery-agent-common.js')).href}?cache=${Date.now()}`),
      import(`${pathToFileURL(path.join(distRoot, 'lib', 'delivery-agent-manager.js')).href}?cache=${Date.now()}`),
      import(`${pathToFileURL(path.join(distRoot, 'lib', 'delivery-agent-prereqs.js')).href}?cache=${Date.now()}`),
    ]);
  }
  return builtModulePromise;
}

async function initGitRepo(tempRoot) {
  execFileSync('git', ['init'], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['config', 'user.email', 'codex@example.test'], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['config', 'user.name', 'Codex Test'], { cwd: tempRoot, stdio: 'ignore' });
  await writeFile(path.join(tempRoot, 'tracked.txt'), 'baseline\n', 'utf8');
  execFileSync('git', ['add', 'tracked.txt'], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['commit', '-m', 'init'], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['branch', '-m', 'develop'], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['remote', 'add', 'upstream', tempRoot], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['fetch', '--quiet', 'upstream', 'develop:refs/remotes/upstream/develop'], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['symbolic-ref', 'refs/remotes/upstream/HEAD', 'refs/remotes/upstream/develop'], { cwd: tempRoot, stdio: 'ignore' });
}

async function makeTempRepo(prefix) {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), prefix));
  await initGitRepo(tempRoot);
  return tempRoot;
}

async function makeLinkedWorktree(prefix) {
  const sandboxRoot = await mkdtemp(path.join(os.tmpdir(), prefix));
  const repoDir = path.join(sandboxRoot, 'repo');
  const worktreeDir = path.join(sandboxRoot, 'worktree');
  execFileSync('git', ['init', '--initial-branch=develop', repoDir], { stdio: 'ignore' });
  execFileSync('git', ['config', 'user.email', 'codex@example.test'], { cwd: repoDir, stdio: 'ignore' });
  execFileSync('git', ['config', 'user.name', 'Codex Test'], { cwd: repoDir, stdio: 'ignore' });
  await writeFile(path.join(repoDir, 'tracked.txt'), 'baseline\n', 'utf8');
  execFileSync('git', ['add', 'tracked.txt'], { cwd: repoDir, stdio: 'ignore' });
  execFileSync('git', ['commit', '-m', 'init'], { cwd: repoDir, stdio: 'ignore' });
  execFileSync('git', ['worktree', 'add', '-b', 'issue/origin-linked', worktreeDir, 'develop'], { cwd: repoDir, stdio: 'ignore' });
  execFileSync('git', ['config', '--local', 'core.worktree', worktreeDir], { cwd: worktreeDir, stdio: 'ignore' });
  return { sandboxRoot, repoDir, worktreeDir };
}

async function copyDistCliTree(tempRoot) {
  const destinationRoot = path.join(tempRoot, 'dist', 'tools', 'priority');
  await cp(distRoot, destinationRoot, { recursive: true });
  return path.join(destinationRoot, 'delivery-agent.js');
}

test('workspace quarantine stays clear when the control root only has untracked files', async (t) => {
  const [common] = await loadModules();
  const { resolveWorkspaceQuarantine } = common;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-clear-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  await writeFile(path.join(tempRoot, 'untracked.log'), 'scratch\n', 'utf8');

  const quarantine = resolveWorkspaceQuarantine(tempRoot);
  assert.equal(quarantine.status, 'clear');
  assert.equal(quarantine.reason, 'clean');
  assert.equal(quarantine.branchName, 'develop');
  assert.equal(quarantine.controlRootBranch, 'develop');
  assert.equal(quarantine.isControlRoot, true);
  assert.equal(quarantine.trackedEntryCount, 0);
  assert.equal(quarantine.untrackedEntryCount, 1);
});

test('workspace quarantine blocks when the control root has tracked git dirt', async (t) => {
  const [common] = await loadModules();
  const { resolveWorkspaceQuarantine } = common;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-blocked-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  await writeFile(path.join(tempRoot, 'tracked.txt'), 'modified\n', 'utf8');
  await writeFile(path.join(tempRoot, 'untracked.log'), 'scratch\n', 'utf8');

  const quarantine = resolveWorkspaceQuarantine(tempRoot);
  assert.equal(quarantine.status, 'blocked');
  assert.equal(quarantine.reason, 'tracked-dirt');
  assert.equal(quarantine.branchName, 'develop');
  assert.equal(quarantine.controlRootBranch, 'develop');
  assert.equal(quarantine.isControlRoot, true);
  assert.equal(quarantine.trackedEntryCount, 1);
  assert.equal(quarantine.untrackedEntryCount, 1);
  assert.match(quarantine.trackedEntries[0].raw, /^ M tracked\.txt$/);
});

test('workspace quarantine stays clear for dirty tracked edits on non-control branches', async (t) => {
  const [common] = await loadModules();
  const { resolveWorkspaceQuarantine } = common;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-feature-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  execFileSync('git', ['checkout', '-b', 'issue/origin-1336-example'], { cwd: tempRoot, stdio: 'ignore' });
  await writeFile(path.join(tempRoot, 'tracked.txt'), 'modified\n', 'utf8');

  const quarantine = resolveWorkspaceQuarantine(tempRoot);
  assert.equal(quarantine.status, 'clear');
  assert.equal(quarantine.reason, 'non-control-root');
  assert.equal(quarantine.branchName, 'issue/origin-1336-example');
  assert.equal(quarantine.controlRootBranch, 'develop');
  assert.equal(quarantine.isControlRoot, false);
  assert.equal(quarantine.trackedEntryCount, 1);
});

test('workspace quarantine fails closed when tracked dirt is present and control-root identity is unknown', async (t) => {
  const [common] = await loadModules();
  const { resolveWorkspaceQuarantine } = common;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-unknown-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  execFileSync('git', ['symbolic-ref', '--delete', 'refs/remotes/upstream/HEAD'], { cwd: tempRoot, stdio: 'ignore' });
  await writeFile(path.join(tempRoot, 'tracked.txt'), 'modified\n', 'utf8');

  const quarantine = resolveWorkspaceQuarantine(tempRoot);
  assert.equal(quarantine.status, 'blocked');
  assert.equal(quarantine.reason, 'control-root-identity-unknown');
  assert.equal(quarantine.branchName, 'develop');
  assert.equal(quarantine.controlRootBranch, null);
  assert.equal(quarantine.isControlRoot, null);
  assert.equal(quarantine.trackedEntryCount, 1);
});

test('workspace quarantine uses branch-class policy fallback when upstream head metadata is missing', async (t) => {
  const [common] = await loadModules();
  const { resolveWorkspaceQuarantine } = common;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-policy-fallback-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  await mkdir(path.join(tempRoot, 'tools', 'policy'), { recursive: true });
  await writeFile(
    path.join(tempRoot, 'tools', 'policy', 'branch-classes.json'),
    `${JSON.stringify({
      repositoryPlanes: [{ id: 'upstream', developBranch: 'develop' }],
    }, null, 2)}\n`,
    'utf8',
  );
  execFileSync('git', ['symbolic-ref', '--delete', 'refs/remotes/upstream/HEAD'], { cwd: tempRoot, stdio: 'ignore' });
  execFileSync('git', ['checkout', '-b', 'issue/origin-1336-example'], { cwd: tempRoot, stdio: 'ignore' });
  await writeFile(path.join(tempRoot, 'tracked.txt'), 'modified\n', 'utf8');

  const quarantine = resolveWorkspaceQuarantine(tempRoot);
  assert.equal(quarantine.status, 'clear');
  assert.equal(quarantine.reason, 'non-control-root');
  assert.equal(quarantine.branchName, 'issue/origin-1336-example');
  assert.equal(quarantine.controlRootBranch, 'develop');
  assert.equal(quarantine.isControlRoot, false);
  assert.equal(quarantine.trackedEntryCount, 1);
});

test('ensureManagerCommand short-circuits on blocked workspace quarantine before prerequisites run', async (t) => {
  const [, manager] = await loadModules();
  const { ensureManagerCommand } = manager;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-ensure-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  await writeFile(path.join(tempRoot, 'tracked.txt'), 'modified\n', 'utf8');

  let prereqsCalled = 0;
  let hygieneCalled = 0;
  const report = await ensureManagerCommand(
    {
      repoRoot: tempRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runtimeDir: path.join('tests', 'results', '_agent', 'runtime'),
      daemonPollIntervalSeconds: 60,
      cycleIntervalSeconds: 90,
      maxCycles: 0,
      wslDistro: 'Ubuntu',
    },
    {
      runRepoHygieneFn() {
        hygieneCalled += 1;
      },
      async runPrereqsCommandFn() {
        prereqsCalled += 1;
        throw new Error('runPrereqsCommand should not execute for quarantined workspaces');
      },
      invokeDeliveryHostSignalFn() {
        throw new Error('invokeDeliveryHostSignal should not execute for quarantined workspaces');
      },
      spawnFn() {
        throw new Error('spawn should not execute for quarantined workspaces');
      },
      async sleepFn() {},
    },
  );

  assert.equal(hygieneCalled, 1);
  assert.equal(prereqsCalled, 0);
  assert.equal(report.status, 'stopped');
  assert.equal(report.outcome, 'workspace-quarantined');
  assert.equal(report.workspaceQuarantine.status, 'blocked');
  assert.equal(report.manager.alive, false);
  assert.equal(report.daemon.alive, false);
});

test('ensureManagerCommand applies repo hygiene before quarantine so invalid core.worktree can self-repair', async (t) => {
  const [, manager] = await loadModules();
  const { ensureManagerCommand } = manager;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-hygiene-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  execFileSync('git', ['config', '--local', 'core.worktree', path.join(tempRoot, 'missing-worktree')], { cwd: tempRoot, stdio: 'ignore' });

  let prereqsCalled = 0;
  await assert.rejects(
    ensureManagerCommand(
      {
        repoRoot: tempRoot,
        repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        runtimeDir: path.join('tests', 'results', '_agent', 'runtime'),
        daemonPollIntervalSeconds: 60,
        cycleIntervalSeconds: 90,
        maxCycles: 0,
        wslDistro: 'Ubuntu',
      },
      {
        async runPrereqsCommandFn() {
          prereqsCalled += 1;
          throw new Error('prereqs-ran');
        },
        invokeDeliveryHostSignalFn() {
          throw new Error('invokeDeliveryHostSignal should not execute when prereqs fail first');
        },
        spawnFn() {
          throw new Error('spawn should not execute when prereqs fail first');
        },
        async sleepFn() {},
      },
    ),
    /prereqs-ran/,
  );

  assert.equal(prereqsCalled, 1);
  const worktreeConfig = spawnSync('git', ['config', '--local', '--get', 'core.worktree'], {
    cwd: tempRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assert.equal(worktreeConfig.status, 1);
  assert.equal(worktreeConfig.stdout.trim(), '');
});

test('ensureManagerCommand does not quarantine tracked edits on non-control branches', async (t) => {
  const [, manager] = await loadModules();
  const { ensureManagerCommand } = manager;
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-branch-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  execFileSync('git', ['checkout', '-b', 'issue/origin-1336-example'], { cwd: tempRoot, stdio: 'ignore' });
  await writeFile(path.join(tempRoot, 'tracked.txt'), 'modified\n', 'utf8');

  let prereqsCalled = 0;
  await assert.rejects(
    ensureManagerCommand(
      {
        repoRoot: tempRoot,
        repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        runtimeDir: path.join('tests', 'results', '_agent', 'runtime'),
        daemonPollIntervalSeconds: 60,
        cycleIntervalSeconds: 90,
        maxCycles: 0,
        wslDistro: 'Ubuntu',
      },
      {
        async runPrereqsCommandFn(passedOptions) {
          prereqsCalled += 1;
          assert.equal(passedOptions.repoRoot, tempRoot);
          throw new Error('prereqs-ran');
        },
        invokeDeliveryHostSignalFn() {
          throw new Error('invokeDeliveryHostSignal should not execute when prereqs fail first');
        },
        spawnFn() {
          throw new Error('spawn should not execute when prereqs fail first');
        },
        async sleepFn() {},
      },
    ),
    /prereqs-ran/,
  );
  assert.equal(prereqsCalled, 1);
});

test('delivery-agent CLI ensure exits nonzero and prints machine-readable quarantine state for blocked control roots', async (t) => {
  await loadModules();
  const tempRoot = await makeTempRepo('delivery-agent-quarantine-cli-');
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  await writeFile(path.join(tempRoot, 'tracked.txt'), 'modified\n', 'utf8');
  const tempCliPath = await copyDistCliTree(tempRoot);

  const result = spawnSync(
    process.execPath,
    [tempCliPath, 'ensure', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action', '--runtime-dir', path.join('tests', 'results', '_agent', 'runtime')],
    {
      cwd: tempRoot,
      encoding: 'utf8',
    },
  );

  assert.equal(result.status, 1, result.stderr);
  assert.equal(result.stderr, '');
  const report = JSON.parse(result.stdout);
  assert.equal(report.status, 'stopped');
  assert.equal(report.workspaceQuarantine.status, 'blocked');
  assert.equal(report.workspaceQuarantine.reason, 'tracked-dirt');
  assert.equal(report.workspaceQuarantine.branchName, 'develop');
  assert.equal(report.workspaceQuarantine.controlRootBranch, 'develop');
  assert.equal(report.workspaceQuarantine.isControlRoot, true);

  const traceText = await readFile(
    path.join(tempRoot, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-manager-trace.ndjson'),
    'utf8',
  );
  assert.match(traceText, /"eventType":"workspace-quarantine-blocked"/);
});

test('repairRepoGitWorktreeConfig leaves a valid linked-worktree config untouched', async (t) => {
  const [, , prereqs] = await loadModules();
  const { repairRepoGitWorktreeConfig } = prereqs;
  const { sandboxRoot, worktreeDir } = await makeLinkedWorktree('delivery-agent-valid-worktree-');
  t.after(async () => {
    await rm(sandboxRoot, { recursive: true, force: true });
  });

  const result = repairRepoGitWorktreeConfig(worktreeDir);
  assert.equal(result.repaired, false);
  assert.equal(result.reason, 'already-valid');
  assert.equal(result.previousWorktree, worktreeDir);

  const persisted = execFileSync('git', ['config', '--local', '--get', 'core.worktree'], {
    cwd: worktreeDir,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
  assert.equal(persisted, worktreeDir);
});

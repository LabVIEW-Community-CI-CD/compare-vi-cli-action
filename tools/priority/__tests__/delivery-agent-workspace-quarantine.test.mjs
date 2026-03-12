#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'lib', 'delivery-agent-common.js');

let builtModulePromise = null;

async function loadModule() {
  if (!builtModulePromise) {
    const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
    assert.equal(buildResult.status, 0, [buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'));
    builtModulePromise = import(`${pathToFileURL(distModulePath).href}?cache=${Date.now()}`);
  }
  return builtModulePromise;
}

function runGit(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, [args.join(' '), result.stdout, result.stderr].filter(Boolean).join('\n'));
}

async function initTrackedRepo() {
  const repoDir = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-workspace-quarantine-'));
  runGit(repoDir, ['init', '-q']);
  runGit(repoDir, ['config', 'user.name', 'Codex']);
  runGit(repoDir, ['config', 'user.email', 'codex@example.invalid']);
  await writeFile(path.join(repoDir, 'tracked.txt'), 'baseline\n', 'utf8');
  runGit(repoDir, ['add', 'tracked.txt']);
  runGit(repoDir, ['commit', '-m', 'init'],);
  return repoDir;
}

function makeAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

test('control workspace quarantine ignores untracked files and validates against schema', async () => {
  const { inspectControlWorkspaceQuarantine } = await loadModule();
  const repoDir = await initTrackedRepo();
  await writeFile(path.join(repoDir, 'untracked.log'), 'scratch\n', 'utf8');

  const report = inspectControlWorkspaceQuarantine({
    repoRoot: repoDir,
    repo: 'example/repo',
    runtimeDir: 'tests/results/_agent/runtime',
  });
  const schema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'delivery-agent-workspace-quarantine-v1.schema.json'), 'utf8'),
  );
  const validate = makeAjv().compile(schema);

  assert.equal(report.status, 'ok');
  assert.equal(report.reason, 'clean');
  assert.equal(report.canProceedUnattended, true);
  assert.equal(report.dirtyTrackedCount, 0);
  assert.deepEqual(report.dirtyEntries, []);
  assert.deepEqual(report.dirtyPaths, []);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

test('control workspace quarantine quarantines tracked dirt', async () => {
  const { inspectControlWorkspaceQuarantine } = await loadModule();
  const repoDir = await initTrackedRepo();
  await writeFile(path.join(repoDir, 'tracked.txt'), 'baseline\nmodified\n', 'utf8');

  const report = inspectControlWorkspaceQuarantine({
    repoRoot: repoDir,
    repo: 'example/repo',
    runtimeDir: 'tests/results/_agent/runtime',
  });

  assert.equal(report.status, 'quarantined');
  assert.equal(report.reason, 'dirty-tracked-files');
  assert.equal(report.canProceedUnattended, false);
  assert.equal(report.dirtyTrackedCount, 1);
  assert.deepEqual(report.dirtyEntries, [' M tracked.txt']);
  assert.deepEqual(report.dirtyPaths, ['tracked.txt']);
});

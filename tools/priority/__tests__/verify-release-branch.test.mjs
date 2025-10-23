#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

function runGit(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${result.stderr || result.stdout}`);
  }
  return result.stdout.trim();
}

test('verify-release-branch succeeds when version/changelog updated', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'verify-release-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await mkdir(path.join(repoDir, 'docs'), { recursive: true });
  await writeFile(
    path.join(repoDir, 'docs', 'CHANGELOG.md'),
    '# Changelog\n\n## v0.1.0 - Initial\n- First release\n',
    'utf8'
  );
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: '0.1.0' }, null, 2) + '\n',
    'utf8'
  );

  runGit(repoDir, ['init']);
  runGit(repoDir, ['config', 'user.name', 'Test']);
  runGit(repoDir, ['config', 'user.email', 'test@example.com']);
  runGit(repoDir, ['add', '.']);
  runGit(repoDir, ['commit', '-m', 'initial release']);
  runGit(repoDir, ['branch', 'develop']);

  runGit(repoDir, ['checkout', '-b', 'release/v0.2.0']);
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: '0.2.0' }, null, 2) + '\n',
    'utf8'
  );
  await writeFile(
    path.join(repoDir, 'docs', 'CHANGELOG.md'),
    '# Changelog\n\n## v0.2.0 - Next\n- Updates\n\n## v0.1.0 - Initial\n- First release\n',
    'utf8'
  );
  runGit(repoDir, ['commit', '-am', 'prepare v0.2.0']);

  const script = path.resolve('tools', 'priority', 'verify-release-branch.mjs');
  const env = { ...process.env, GITHUB_HEAD_REF: 'release/v0.2.0', RELEASE_VALIDATE_BASE: 'HEAD~1' };
  const result = spawnSync(process.execPath, [script], { cwd: repoDir, env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.stdout);
});

test('verify-release-branch fails when changelog missing update', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'verify-release-fail-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await mkdir(path.join(repoDir, 'docs'), { recursive: true });
  await writeFile(
    path.join(repoDir, 'docs', 'CHANGELOG.md'),
    '# Changelog\n\n## v0.1.0 - Initial\n- First release\n',
    'utf8'
  );
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: '0.1.0' }, null, 2) + '\n',
    'utf8'
  );

  runGit(repoDir, ['init']);
  runGit(repoDir, ['config', 'user.name', 'Test']);
  runGit(repoDir, ['config', 'user.email', 'test@example.com']);
  runGit(repoDir, ['add', '.']);
  runGit(repoDir, ['commit', '-m', 'initial release']);
  runGit(repoDir, ['branch', 'develop']);

  runGit(repoDir, ['checkout', '-b', 'release/v0.3.0']);
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: '0.3.0' }, null, 2) + '\n',
    'utf8'
  );
  runGit(repoDir, ['commit', '-am', 'prepare v0.3.0']);

  const script = path.resolve('tools', 'priority', 'verify-release-branch.mjs');
  const env = { ...process.env, GITHUB_HEAD_REF: 'release/v0.3.0', RELEASE_VALIDATE_BASE: 'HEAD~1' };
  const result = spawnSync(process.execPath, [script], { cwd: repoDir, env, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr ?? result.stdout, /CHANGELOG\.md missing entry/i);
});

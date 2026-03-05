#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

function runGit(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${result.stderr || result.stdout}`);
  }
  return result.stdout.trim();
}

async function writeReleaseDocs(repoDir, tag, { includeReleaseNotes = true, notesTag = tag } = {}) {
  await writeFile(
    path.join(repoDir, 'PR_NOTES.md'),
    `# Release ${notesTag} Notes\n\nPrepared for ${notesTag}.\n`,
    'utf8'
  );
  await writeFile(
    path.join(repoDir, 'TAG_PREP_CHECKLIST.md'),
    `# ${notesTag} Tag Checklist\n\n- [ ] Verify ${notesTag} changelog and release notes.\n`,
    'utf8'
  );
  if (includeReleaseNotes) {
    await writeFile(
      path.join(repoDir, `RELEASE_NOTES_${tag}.md`),
      `# Release Notes ${notesTag}\n\nThis release ships ${notesTag}.\n`,
      'utf8'
    );
  }
}

test('verify-release-branch succeeds when version/changelog updated', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'verify-release-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await writeFile(
    path.join(repoDir, 'CHANGELOG.md'),
    '# Changelog\n\n## v0.1.0 - Initial\n- First release\n',
    'utf8'
  );
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: '0.1.0' }, null, 2) + '\n',
    'utf8'
  );
  await writeReleaseDocs(repoDir, 'v0.1.0');

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
    path.join(repoDir, 'CHANGELOG.md'),
    '# Changelog\n\n## v0.2.0 - Next\n- Updates\n\n## v0.1.0 - Initial\n- First release\n',
    'utf8'
  );
  await writeReleaseDocs(repoDir, 'v0.2.0');
  runGit(repoDir, ['commit', '-am', 'prepare v0.2.0']);

  const script = path.resolve('tools', 'priority', 'verify-release-branch.mjs');
  const env = { ...process.env, GITHUB_HEAD_REF: 'release/v0.2.0', RELEASE_VALIDATE_BASE: 'HEAD~1' };
  const result = spawnSync(process.execPath, [script], { cwd: repoDir, env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.stdout);
});

test('verify-release-branch fails when changelog missing update', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'verify-release-fail-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await writeFile(
    path.join(repoDir, 'CHANGELOG.md'),
    '# Changelog\n\n## v0.1.0 - Initial\n- First release\n',
    'utf8'
  );
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: '0.1.0' }, null, 2) + '\n',
    'utf8'
  );
  await writeReleaseDocs(repoDir, 'v0.1.0');

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
  await writeReleaseDocs(repoDir, 'v0.3.0');
  runGit(repoDir, ['commit', '-am', 'prepare v0.3.0']);

  const script = path.resolve('tools', 'priority', 'verify-release-branch.mjs');
  const env = { ...process.env, GITHUB_HEAD_REF: 'release/v0.3.0', RELEASE_VALIDATE_BASE: 'HEAD~1' };
  const result = spawnSync(process.execPath, [script], { cwd: repoDir, env, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr ?? result.stdout, /CHANGELOG\.md missing entry/i);
});

test('verify-release-branch fails when release docs are inconsistent', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'verify-release-docs-fail-'));
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
  await writeReleaseDocs(repoDir, 'v0.1.0');

  runGit(repoDir, ['init']);
  runGit(repoDir, ['config', 'user.name', 'Test']);
  runGit(repoDir, ['config', 'user.email', 'test@example.com']);
  runGit(repoDir, ['add', '.']);
  runGit(repoDir, ['commit', '-m', 'initial release']);
  runGit(repoDir, ['branch', 'develop']);

  runGit(repoDir, ['checkout', '-b', 'release/v0.4.0']);
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: '0.4.0' }, null, 2) + '\n',
    'utf8'
  );
  await writeFile(
    path.join(repoDir, 'docs', 'CHANGELOG.md'),
    '# Changelog\n\n## v0.4.0 - Next\n- Updates\n\n## v0.1.0 - Initial\n- First release\n',
    'utf8'
  );
  await writeReleaseDocs(repoDir, 'v0.4.0', { notesTag: 'v0.3.9' });
  runGit(repoDir, ['commit', '-am', 'prepare v0.4.0']);

  const script = path.resolve('tools', 'priority', 'verify-release-branch.mjs');
  const env = { ...process.env, GITHUB_HEAD_REF: 'release/v0.4.0', RELEASE_VALIDATE_BASE: 'HEAD~1' };
  const result = spawnSync(process.execPath, [script], { cwd: repoDir, env, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr ?? result.stdout, /does not reference release tag/i);
});

test('verify-release-branch fails when package.json is not updated relative to base', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'verify-release-package-diff-fail-'));
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
  await writeReleaseDocs(repoDir, 'v0.1.0');

  runGit(repoDir, ['init']);
  runGit(repoDir, ['config', 'user.name', 'Test']);
  runGit(repoDir, ['config', 'user.email', 'test@example.com']);
  runGit(repoDir, ['add', '.']);
  runGit(repoDir, ['commit', '-m', 'initial release']);
  runGit(repoDir, ['branch', 'develop']);

  runGit(repoDir, ['checkout', '-b', 'release/v0.1.0']);
  await writeFile(
    path.join(repoDir, 'docs', 'CHANGELOG.md'),
    '# Changelog\n\n## v0.1.0 - Refresh\n- Notes updated\n',
    'utf8'
  );
  await writeReleaseDocs(repoDir, 'v0.1.0');
  runGit(repoDir, ['commit', '-am', 'docs only']);

  const script = path.resolve('tools', 'priority', 'verify-release-branch.mjs');
  const env = { ...process.env, GITHUB_HEAD_REF: 'release/v0.1.0', RELEASE_VALIDATE_BASE: 'HEAD~1' };
  const result = spawnSync(process.execPath, [script], { cwd: repoDir, env, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr ?? result.stdout, /package\.json not updated relative to/i);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { evaluateVersionIntegrity, parseArgs, run } from '../validate-semver.mjs';

test('evaluateVersionIntegrity accepts valid semver without branch context', () => {
  const result = evaluateVersionIntegrity('1.2.3');
  assert.equal(result.valid, true);
  assert.deepEqual(result.issues, []);
});

test('evaluateVersionIntegrity rejects invalid semver version', () => {
  const result = evaluateVersionIntegrity('1.2');
  assert.equal(result.valid, false);
  assert.match(result.issues[0], /does not comply/i);
});

test('evaluateVersionIntegrity enforces release branch/version match', () => {
  const mismatch = evaluateVersionIntegrity('1.2.3', 'release/v1.2.4');
  assert.equal(mismatch.valid, false);
  assert.match(mismatch.issues.join(' '), /does not match release branch tag/i);

  const match = evaluateVersionIntegrity('1.2.3', 'release/v1.2.3');
  assert.equal(match.valid, true);
});

test('parseArgs resolves branch from cli flag or github env', () => {
  const cli = parseArgs(['--version', '1.2.3', '--branch', 'release/v1.2.3', '--repo-root', '.'], {});
  assert.equal(cli.versionArg, '1.2.3');
  assert.equal(cli.branch, 'release/v1.2.3');
  assert.equal(cli.repoRoot, path.resolve('.'));

  const env = parseArgs([], { GITHUB_HEAD_REF: 'release/v2.0.0' });
  assert.equal(env.branch, 'release/v2.0.0');
});

test('run reports aligned release surface versions for the current repo', () => {
  const result = run({ args: [] });
  assert.equal(result.code, 0);
  assert.equal(result.output.valid, true);
  assert.ok(result.output.surfaceVersions);
  assert.equal(result.output.version, result.output.surfaceVersions.packageVersion);
  assert.equal(result.output.version, result.output.surfaceVersions.propsVersion);
  assert.equal(result.output.version, result.output.surfaceVersions.moduleReleaseVersion);
});

test('run honors explicit repo-root overrides for helper-root bootstrap usage', () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'validate-semver-'));

  try {
    fs.mkdirSync(path.join(tempRoot, 'tools', 'CompareVI.Tools'), { recursive: true });
    fs.writeFileSync(
      path.join(tempRoot, 'package.json'),
      `${JSON.stringify({ name: 'fixture', version: '9.8.7' }, null, 2)}\n`,
      'utf8'
    );
    fs.writeFileSync(
      path.join(tempRoot, 'Directory.Build.props'),
      [
        '<Project>',
        '  <PropertyGroup>',
        '    <Version>9.8.7</Version>',
        '    <CompareViSharedPackageVersion>$(Version)</CompareViSharedPackageVersion>',
        '    <AssemblyVersion>9.8.7.0</AssemblyVersion>',
        '    <FileVersion>9.8.7.0</FileVersion>',
        '    <InformationalVersion>$(Version)+local</InformationalVersion>',
        '  </PropertyGroup>',
        '</Project>',
        ''
      ].join('\n'),
      'utf8'
    );
    fs.writeFileSync(
      path.join(tempRoot, 'tools', 'CompareVI.Tools', 'CompareVI.Tools.psd1'),
      [
        '@{',
        "  ModuleVersion = '9.8.7'",
        "  ProjectUri = 'https://example.test'",
        '}',
        ''
      ].join('\n'),
      'utf8'
    );

    const result = run({ args: ['--repo-root', tempRoot] });
    assert.equal(result.code, 0);
    assert.equal(result.output.valid, true);
    assert.equal(result.output.version, '9.8.7');
    assert.equal(result.output.repoRoot, tempRoot);
    assert.equal(result.output.surfaceVersions.packageVersion, '9.8.7');
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

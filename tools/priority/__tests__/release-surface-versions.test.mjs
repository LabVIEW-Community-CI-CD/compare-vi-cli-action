#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  deriveReleaseSurfaceVersions,
  readReleaseSurfaceVersions,
  evaluateReleaseSurfaceVersionExpectations,
  syncReleaseSurfaceVersions
} from '../lib/release-surface-versions.mjs';

async function seedRepo(repoDir, {
  packageVersion = '0.1.0',
  propsVersion = '0.1.0',
  moduleVersion = '0.1.0',
  modulePrerelease = null
} = {}) {
  await writeFile(
    path.join(repoDir, 'package.json'),
    JSON.stringify({ name: 'test', version: packageVersion }, null, 2) + '\n',
    'utf8'
  );

  await writeFile(
    path.join(repoDir, 'Directory.Build.props'),
    `<Project>
  <PropertyGroup>
    <Version>${propsVersion}</Version>
    <AssemblyVersion>${propsVersion.split('-')[0]}.0</AssemblyVersion>
    <FileVersion>${propsVersion.split('-')[0]}.0</FileVersion>
    <InformationalVersion>${propsVersion}+local</InformationalVersion>
    <CompareViSharedPackageVersion Condition="'$(CompareViSharedPackageVersion)' == ''">${propsVersion}</CompareViSharedPackageVersion>
  </PropertyGroup>
</Project>
`,
    'utf8'
  );

  await mkdir(path.join(repoDir, 'tools', 'CompareVI.Tools'), { recursive: true });
  await writeFile(
    path.join(repoDir, 'tools', 'CompareVI.Tools', 'CompareVI.Tools.psd1'),
    `@{
  RootModule        = 'CompareVI.Tools.psm1'
  ModuleVersion     = '${moduleVersion}'
  GUID              = '00000000-0000-0000-0000-000000000000'
  Author            = 'Test'
  CompanyName       = 'Test'
  Copyright         = '(c) Test'
  Description       = 'Test'
  PowerShellVersion = '5.1'
  FunctionsToExport = @('Invoke-CompareVIHistory')
  CmdletsToExport   = @()
  VariablesToExport = @()
  AliasesToExport   = @()
  PrivateData       = @{
    PSData = @{
      Tags = @('CompareVI')
      ProjectUri = 'https://example.com/repo'
${modulePrerelease ? `      Prerelease = '${modulePrerelease}'` : ''}
    }
  }
}
`,
    'utf8'
  );
}

test('deriveReleaseSurfaceVersions maps prerelease semver to numeric assembly/module versions', () => {
  const actual = deriveReleaseSurfaceVersions('1.2.3-rc.1');
  assert.equal(actual.packageVersion, '1.2.3-rc.1');
  assert.equal(actual.cliVersion, '1.2.3-rc.1');
  assert.equal(actual.sharedPackageVersion, '1.2.3-rc.1');
  assert.equal(actual.moduleVersion, '1.2.3');
  assert.equal(actual.modulePrerelease, 'rc.1');
  assert.equal(actual.moduleReleaseVersion, '1.2.3-rc.1');
  assert.equal(actual.assemblyVersion, '1.2.3.0');
  assert.equal(actual.informationalVersion, '$(Version)+local');
});

test('syncReleaseSurfaceVersions updates package, props, and module manifest together', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-surfaces-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await seedRepo(repoDir);

  const update = await syncReleaseSurfaceVersions(repoDir, '0.6.3');
  assert.equal(update.previous.packageVersion, '0.1.0');
  assert.equal(update.next.packageVersion, '0.6.3');
  assert.equal(update.next.propsVersion, '0.6.3');
  assert.equal(update.next.sharedPackageVersion, '0.6.3');
  assert.equal(update.next.moduleVersion, '0.6.3');
  assert.equal(update.next.modulePrerelease, null);
  assert.equal(update.next.moduleReleaseVersion, '0.6.3');

  const manifestContents = await readFile(path.join(repoDir, 'tools', 'CompareVI.Tools', 'CompareVI.Tools.psd1'), 'utf8');
  assert.ok(!manifestContents.includes("Prerelease = '"));
});

test('evaluateReleaseSurfaceVersionExpectations reports mismatched surfaces', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-surfaces-mismatch-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));

  await seedRepo(repoDir, {
    packageVersion: '0.6.3',
    propsVersion: '0.1.0',
    moduleVersion: '0.1.0'
  });

  const actual = await readReleaseSurfaceVersions(repoDir);
  const evaluation = evaluateReleaseSurfaceVersionExpectations('0.6.3', actual);
  assert.equal(evaluation.valid, false);
  assert.match(evaluation.issues.join(' '), /Directory\.Build\.props Version/);
  assert.match(evaluation.issues.join(' '), /CompareVI\.Tools ModuleVersion/);
});

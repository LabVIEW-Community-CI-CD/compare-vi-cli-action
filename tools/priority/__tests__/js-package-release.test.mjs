import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  __test,
  parseArgs,
  resolveJsPackageReleaseContext,
  stageJsPackageRelease,
  verifyJsPackageRelease
} from '../js-package-release.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('parseArgs applies JS package release defaults', () => {
  const parsed = parseArgs([
    'node',
    'js-package-release.mjs',
    '--action',
    'resolve',
    '--package-dir',
    'packages/runtime-harness',
    '--version',
    '0.1.0'
  ]);

  assert.equal(parsed.action, 'resolve');
  assert.equal(parsed.packageDir, 'packages/runtime-harness');
  assert.equal(parsed.version, '0.1.0');
  assert.equal(parsed.publish, false);
  assert.equal(parsed.registryUrl, 'https://npm.pkg.github.com');
  assert.equal(parsed.installRetries, 3);
});

test('resolveJsPackageReleaseContext derives runtime-harness publish metadata', async () => {
  const context = await resolveJsPackageReleaseContext(
    {
      action: 'resolve',
      packageDir: 'packages/runtime-harness',
      version: '0.1.0-rc.1',
      channel: 'rc',
      publish: false,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
      owner: 'LabVIEW-Community-CI-CD',
      serverUrl: 'https://github.com'
    },
    { repoRoot, now: new Date('2026-03-10T08:00:00Z') }
  );

  assert.equal(context.package.name, '@labview-community-ci-cd/runtime-harness');
  assert.equal(context.package.publishCapable, true);
  assert.equal(context.package.distTag, 'rc');
  assert.deepEqual(context.package.expectedExports, [
    '@labview-community-ci-cd/runtime-harness',
    '@labview-community-ci-cd/runtime-harness/worker',
    '@labview-community-ci-cd/runtime-harness/observer'
  ]);
  assert.match(context.source.publishEntries.join(','), /index\.mjs/);
  assert.match(context.source.publishEntries.join(','), /README\.md/);
});

test('resolveJsPackageReleaseContext rejects org publish rehearsal on a non-org owner', async () => {
  await assert.rejects(
    () =>
      resolveJsPackageReleaseContext(
        {
          action: 'resolve',
          packageDir: 'packages/runtime-harness',
          version: '0.1.0',
          channel: 'stable',
          publish: true,
          repository: 'svelderrainruiz/compare-vi-cli-action',
          owner: 'svelderrainruiz',
          serverUrl: 'https://github.com'
        },
        { repoRoot }
      ),
    /requires repository owner 'labview-community-ci-cd'/i
  );
});

test('stageJsPackageRelease creates a tarball candidate with staged publish metadata', async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-harness-stage-'));
  const report = await stageJsPackageRelease(
    {
      action: 'stage',
      packageDir: 'packages/runtime-harness',
      version: '0.1.0',
      channel: 'stable',
      publish: false,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
      owner: 'LabVIEW-Community-CI-CD',
      serverUrl: 'https://github.com',
      stagingDir: path.join(tempRoot, 'staging'),
      tarballDir: path.join(tempRoot, 'tarballs'),
      copyLicenseFrom: 'LICENSE'
    },
    { repoRoot, now: new Date('2026-03-10T08:04:00Z') }
  );

  const stagedPackageJson = JSON.parse(fs.readFileSync(report.source.stagedPackageJsonPath, 'utf8'));
  assert.equal(report.action, 'stage');
  assert.equal(stagedPackageJson.version, '0.1.0');
  assert.equal(stagedPackageJson.private, false);
  assert.equal(stagedPackageJson.publishConfig.registry, 'https://npm.pkg.github.com');
  assert.ok(fs.existsSync(report.outputs.tarballPath));
  assert.ok(fs.existsSync(path.join(report.outputs.stagingDir, 'LICENSE')));
  assert.deepEqual(stagedPackageJson.files, ['index.mjs', 'worker.mjs', 'observer.mjs', 'README.md']);
});

test('verifyJsPackageRelease imports the packed runtime-harness candidate from a clean consumer', async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-harness-verify-'));
  const staged = await stageJsPackageRelease(
    {
      action: 'stage',
      packageDir: 'packages/runtime-harness',
      version: '0.1.0',
      channel: 'stable',
      publish: false,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
      owner: 'LabVIEW-Community-CI-CD',
      serverUrl: 'https://github.com',
      stagingDir: path.join(tempRoot, 'staging'),
      tarballDir: path.join(tempRoot, 'tarballs'),
      copyLicenseFrom: 'LICENSE'
    },
    { repoRoot, now: new Date('2026-03-10T08:07:00Z') }
  );

  const verified = await verifyJsPackageRelease(
    {
      action: 'verify',
      packageDir: 'packages/runtime-harness',
      version: '0.1.0',
      channel: 'stable',
      publish: false,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
      owner: 'LabVIEW-Community-CI-CD',
      serverUrl: 'https://github.com',
      sourceSpec: staged.outputs.tarballPath,
      consumerDir: path.join(tempRoot, 'consumer')
    },
    { repoRoot, now: new Date('2026-03-10T08:10:00Z') }
  );

  assert.equal(verified.action, 'verify');
  assert.equal(verified.outputs.verificationMode, 'tarball');
  assert.equal(verified.verification.installedVersion, '0.1.0');
  assert.deepEqual(
    verified.verification.imports.map((entry) => entry.specifier),
    [
      '@labview-community-ci-cd/runtime-harness',
      '@labview-community-ci-cd/runtime-harness/worker',
      '@labview-community-ci-cd/runtime-harness/observer'
    ]
  );
  assert.equal(verified.execution.installAttempts, 1);
});

test('helper utilities classify release modes deterministically', () => {
  assert.equal(__test.defaultDistTag('stable'), 'latest');
  assert.equal(__test.defaultDistTag('rc'), 'rc');
  assert.equal(__test.detectSourceMode('D:\\tmp\\runtime-harness-0.1.0.tgz'), 'tarball');
  assert.equal(__test.detectSourceMode('@labview-community-ci-cd/runtime-harness@0.1.0'), 'registry');
});

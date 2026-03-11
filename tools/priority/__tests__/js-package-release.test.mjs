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

test('resolveJsPackageReleaseContext rejects package publish entries that escape the package directory', async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-harness-malicious-pkg-'));
  const packageDir = path.join(tempRoot, 'package');
  fs.mkdirSync(packageDir, { recursive: true });
  fs.writeFileSync(
    path.join(packageDir, 'package.json'),
    JSON.stringify(
      {
        name: '@labview-community-ci-cd/runtime-harness-malicious',
        version: '0.1.0',
        files: ['../.git/config']
      },
      null,
      2
    ),
    'utf8'
  );

  await assert.rejects(
    () =>
      resolveJsPackageReleaseContext(
        {
          action: 'resolve',
          packageDir,
          version: '0.1.0',
          publish: false,
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
          owner: 'LabVIEW-Community-CI-CD',
          serverUrl: 'https://github.com'
        },
        { repoRoot, now: new Date('2026-03-10T08:02:00Z') }
      ),
    /must stay within the package directory/i
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

test('stageJsPackageRelease rejects unsafe staging and tarball directories', async () => {
  const safeTempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-harness-stage-guard-'));

  await assert.rejects(
    () =>
      stageJsPackageRelease(
        {
          action: 'stage',
          packageDir: 'packages/runtime-harness',
          version: '0.1.0',
          channel: 'stable',
          publish: false,
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
          owner: 'LabVIEW-Community-CI-CD',
          serverUrl: 'https://github.com',
          stagingDir: repoRoot,
          tarballDir: path.join(safeTempRoot, 'tarballs'),
          copyLicenseFrom: 'LICENSE'
        },
        { repoRoot, now: new Date('2026-03-10T08:05:00Z') }
      ),
    /--staging-dir.*safe managed directory target|--staging-dir.*managed directory root/i
  );

  await assert.rejects(
    () =>
      stageJsPackageRelease(
        {
          action: 'stage',
          packageDir: 'packages/runtime-harness',
          version: '0.1.0',
          channel: 'stable',
          publish: false,
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
          owner: 'LabVIEW-Community-CI-CD',
          serverUrl: 'https://github.com',
          stagingDir: path.join(safeTempRoot, 'staging'),
          tarballDir: os.tmpdir(),
          copyLicenseFrom: 'LICENSE'
        },
        { repoRoot, now: new Date('2026-03-10T08:05:30Z') }
      ),
    /--tarball-dir.*safe managed directory target|--tarball-dir.*managed directory root/i
  );
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

test('verifyJsPackageRelease rejects unsafe consumer directories', async () => {
  await assert.rejects(
    () =>
      verifyJsPackageRelease(
        {
          action: 'verify',
          packageDir: 'packages/runtime-harness',
          version: '0.1.0',
          channel: 'stable',
          publish: false,
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
          owner: 'LabVIEW-Community-CI-CD',
          serverUrl: 'https://github.com',
          sourceSpec: path.join(os.tmpdir(), 'runtime-harness-0.1.0.tgz'),
          consumerDir: repoRoot
        },
        { repoRoot, now: new Date('2026-03-10T08:11:00Z') }
      ),
    /--consumer-dir.*safe managed directory target|--consumer-dir.*managed directory root/i
  );
});

test('verifyJsPackageRelease removes transient npmrc files after registry verification', async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-harness-registry-verify-'));
  const consumerDir = path.join(tempRoot, 'consumer');
  let observedNpmrcPath = null;
  let npmrcExistedDuringInstall = false;

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
      sourceSpec: '@labview-community-ci-cd/runtime-harness@0.1.0',
      consumerDir,
      token: 'ghp_test_token'
    },
    {
      repoRoot,
      now: new Date('2026-03-10T08:12:00Z'),
      runNpmFn: async (_args, options) => {
        observedNpmrcPath = options?.env?.NPM_CONFIG_USERCONFIG ?? null;
        npmrcExistedDuringInstall = Boolean(observedNpmrcPath && fs.existsSync(observedNpmrcPath));
        return { displayCommand: 'npm install --ignore-scripts --no-package-lock @labview-community-ci-cd/runtime-harness@0.1.0' };
      },
      runNodeFn: async () => ({
        stdout: JSON.stringify({
          version: '0.1.0',
          imports: [
            { specifier: '@labview-community-ci-cd/runtime-harness', exportKeys: ['default'] },
            { specifier: '@labview-community-ci-cd/runtime-harness/worker', exportKeys: ['default'] },
            { specifier: '@labview-community-ci-cd/runtime-harness/observer', exportKeys: ['default'] }
          ]
        })
      })
    }
  );

  assert.equal(verified.outputs.verificationMode, 'registry');
  assert.equal(verified.verification.npmrcPath, null);
  assert.equal(npmrcExistedDuringInstall, true);
  assert.equal(fs.existsSync(path.join(consumerDir, '.npmrc')), false);
});

test('helper utilities classify release modes deterministically', () => {
  assert.equal(__test.defaultDistTag('stable'), 'latest');
  assert.equal(__test.defaultDistTag('rc'), 'rc');
  assert.equal(__test.detectSourceMode('D:\\tmp\\runtime-harness-0.1.0.tgz'), 'tarball');
  assert.equal(__test.detectSourceMode('dist/runtime-harness-0.1.0.tgz'), 'tarball');
  assert.equal(__test.looksLikeRegistryPackageSpec('@labview-community-ci-cd/runtime-harness@0.1.0'), true);
  assert.equal(__test.detectSourceMode('@labview-community-ci-cd/runtime-harness@0.1.0'), 'registry');
  assert.throws(
    () => __test.normalizePackageRelativePath(repoRoot, '../.git/config', 'package.json files entry'),
    /must stay within the package directory/i
  );
});

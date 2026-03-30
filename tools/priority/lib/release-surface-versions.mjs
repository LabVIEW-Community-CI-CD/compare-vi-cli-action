#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import path from 'node:path';

export const RELEASE_SURFACE_VERSION_FILES = [
  'package.json',
  'package-lock.json',
  'Directory.Build.props',
  'tools/CompareVI.Tools/CompareVI.Tools.psd1'
];

function readTextTag(contents, tagName) {
  const match = contents.match(new RegExp(`<${tagName}(?:\\s+[^>]*)?>([^<]+)</${tagName}>`));
  return match ? match[1].trim() : null;
}

function replaceTextTag(contents, tagName, value) {
  const pattern = new RegExp(`(<${tagName}(?:\\s+[^>]*)?>)([^<]*)(</${tagName}>)`);
  if (!pattern.test(contents)) {
    throw new Error(`Unable to find <${tagName}> in Directory.Build.props`);
  }

  return contents.replace(pattern, `$1${value}$3`);
}

function readModuleManifestProperty(contents, propertyName) {
  const match = contents.match(new RegExp(`^\\s*${propertyName}\\s*=\\s*'([^']*)'`, 'm'));
  return match ? match[1].trim() : null;
}

function replaceModuleManifestProperty(contents, propertyName, value) {
  const pattern = new RegExp(`(^\\s*${propertyName}\\s*=\\s*')([^']*)(')`, 'm');
  if (!pattern.test(contents)) {
    throw new Error(`Unable to find ${propertyName} in CompareVI.Tools manifest`);
  }

  return contents.replace(pattern, `$1${value}$3`);
}

function upsertModulePrerelease(contents, prerelease) {
  const prereleasePattern = /^(\s*Prerelease\s*=\s*')([^']*)('.*)$/m;
  if (prerelease) {
    if (prereleasePattern.test(contents)) {
      return contents.replace(prereleasePattern, `$1${prerelease}$3`);
    }

    const projectUriPattern = /^(\s*ProjectUri\s*=\s*'[^']*'\r?\n)/m;
    if (!projectUriPattern.test(contents)) {
      throw new Error('Unable to place Prerelease in CompareVI.Tools manifest');
    }

    return contents.replace(projectUriPattern, `$1      Prerelease = '${prerelease}'\n`);
  }

  return contents.replace(/^\s*Prerelease\s*=\s*'[^']*'\r?\n/m, '');
}

export function parseSemverComponents(version) {
  const [withoutBuild, buildMetadata = null] = version.split('+', 2);
  const prereleaseIndex = withoutBuild.indexOf('-');
  if (prereleaseIndex === -1) {
    return {
      version,
      coreVersion: withoutBuild,
      prerelease: null,
      buildMetadata
    };
  }

  return {
    version,
    coreVersion: withoutBuild.slice(0, prereleaseIndex),
    prerelease: withoutBuild.slice(prereleaseIndex + 1),
    buildMetadata
  };
}

export function deriveReleaseSurfaceVersions(semver) {
  const parsed = parseSemverComponents(semver);
  return {
    packageVersion: semver,
    propsVersion: semver,
    cliVersion: semver,
    sharedPackageVersion: semver,
    moduleVersion: parsed.coreVersion,
    modulePrerelease: parsed.prerelease,
    moduleReleaseVersion: parsed.prerelease ? `${parsed.coreVersion}-${parsed.prerelease}` : parsed.coreVersion,
    assemblyVersion: `${parsed.coreVersion}.0`,
    fileVersion: `${parsed.coreVersion}.0`,
    informationalVersion: '$(Version)+local'
  };
}

export async function readReleaseSurfaceVersions(repoRoot) {
  const pkgPath = path.join(repoRoot, 'package.json');
  const packageLockPath = path.join(repoRoot, 'package-lock.json');
  const propsPath = path.join(repoRoot, 'Directory.Build.props');
  const moduleManifestPath = path.join(repoRoot, 'tools', 'CompareVI.Tools', 'CompareVI.Tools.psd1');

  const [pkgRaw, packageLockRaw, propsRaw, manifestRaw] = await Promise.all([
    readFile(pkgPath, 'utf8'),
    readFile(packageLockPath, 'utf8'),
    readFile(propsPath, 'utf8'),
    readFile(moduleManifestPath, 'utf8')
  ]);

  const pkg = JSON.parse(pkgRaw);
  const packageLock = JSON.parse(packageLockRaw);
  const propsVersion = readTextTag(propsRaw, 'Version');
  const sharedPackageVersionRaw = readTextTag(propsRaw, 'CompareViSharedPackageVersion');
  const moduleVersion = readModuleManifestProperty(manifestRaw, 'ModuleVersion');
  const modulePrerelease = readModuleManifestProperty(manifestRaw, 'Prerelease');
  const moduleReleaseVersion = modulePrerelease ? `${moduleVersion}-${modulePrerelease}` : moduleVersion;

  return {
    packageVersion: pkg.version ? String(pkg.version) : null,
    packageLockVersion: packageLock.version ? String(packageLock.version) : null,
    packageLockRootPackageVersion: packageLock?.packages?.['']?.version
      ? String(packageLock.packages[''].version)
      : null,
    propsVersion,
    cliVersion: propsVersion,
    sharedPackageVersion: sharedPackageVersionRaw === '$(Version)' ? propsVersion : sharedPackageVersionRaw,
    moduleVersion,
    modulePrerelease,
    moduleReleaseVersion,
    assemblyVersion: readTextTag(propsRaw, 'AssemblyVersion'),
    fileVersion: readTextTag(propsRaw, 'FileVersion'),
    informationalVersion: readTextTag(propsRaw, 'InformationalVersion')
  };
}

export function readReleaseSurfaceVersionsSync(repoRoot) {
  const pkgPath = path.join(repoRoot, 'package.json');
  const packageLockPath = path.join(repoRoot, 'package-lock.json');
  const propsPath = path.join(repoRoot, 'Directory.Build.props');
  const moduleManifestPath = path.join(repoRoot, 'tools', 'CompareVI.Tools', 'CompareVI.Tools.psd1');

  const pkgRaw = readFileSync(pkgPath, 'utf8');
  const packageLockRaw = readFileSync(packageLockPath, 'utf8');
  const propsRaw = readFileSync(propsPath, 'utf8');
  const manifestRaw = readFileSync(moduleManifestPath, 'utf8');

  const pkg = JSON.parse(pkgRaw);
  const packageLock = JSON.parse(packageLockRaw);
  const propsVersion = readTextTag(propsRaw, 'Version');
  const sharedPackageVersionRaw = readTextTag(propsRaw, 'CompareViSharedPackageVersion');
  const moduleVersion = readModuleManifestProperty(manifestRaw, 'ModuleVersion');
  const modulePrerelease = readModuleManifestProperty(manifestRaw, 'Prerelease');
  const moduleReleaseVersion = modulePrerelease ? `${moduleVersion}-${modulePrerelease}` : moduleVersion;

  return {
    packageVersion: pkg.version ? String(pkg.version) : null,
    packageLockVersion: packageLock.version ? String(packageLock.version) : null,
    packageLockRootPackageVersion: packageLock?.packages?.['']?.version
      ? String(packageLock.packages[''].version)
      : null,
    propsVersion,
    cliVersion: propsVersion,
    sharedPackageVersion: sharedPackageVersionRaw === '$(Version)' ? propsVersion : sharedPackageVersionRaw,
    moduleVersion,
    modulePrerelease,
    moduleReleaseVersion,
    assemblyVersion: readTextTag(propsRaw, 'AssemblyVersion'),
    fileVersion: readTextTag(propsRaw, 'FileVersion'),
    informationalVersion: readTextTag(propsRaw, 'InformationalVersion')
  };
}

export function evaluateReleaseSurfaceVersionExpectations(expectedSemver, actualVersions) {
  const expected = deriveReleaseSurfaceVersions(expectedSemver);
  const issues = [];

  const comparisons = [
    ['package.json version', actualVersions.packageVersion, expected.packageVersion],
    ['package-lock.json version', actualVersions.packageLockVersion, expected.packageVersion],
    ['package-lock.json packages[\"\"] version', actualVersions.packageLockRootPackageVersion, expected.packageVersion],
    ['Directory.Build.props Version', actualVersions.propsVersion, expected.propsVersion],
    ['comparevi-cli version', actualVersions.cliVersion, expected.cliVersion],
    ['CompareVi.Shared package version', actualVersions.sharedPackageVersion, expected.sharedPackageVersion],
    ['CompareVI.Tools ModuleVersion', actualVersions.moduleVersion, expected.moduleVersion],
    ['CompareVI.Tools release version', actualVersions.moduleReleaseVersion, expected.moduleReleaseVersion],
    ['Directory.Build.props AssemblyVersion', actualVersions.assemblyVersion, expected.assemblyVersion],
    ['Directory.Build.props FileVersion', actualVersions.fileVersion, expected.fileVersion],
    ['Directory.Build.props InformationalVersion', actualVersions.informationalVersion, expected.informationalVersion]
  ];

  for (const [label, actual, exp] of comparisons) {
    if ((actual ?? null) !== (exp ?? null)) {
      issues.push(`${label} ${actual ?? '<missing>'} does not match expected ${exp ?? '<missing>'}.`);
    }
  }

  return {
    expected,
    valid: issues.length === 0,
    issues
  };
}

export async function syncReleaseSurfaceVersions(repoRoot, semver) {
  const expected = deriveReleaseSurfaceVersions(semver);
  const previous = await readReleaseSurfaceVersions(repoRoot);

  const pkgPath = path.join(repoRoot, 'package.json');
  const packageLockPath = path.join(repoRoot, 'package-lock.json');
  const propsPath = path.join(repoRoot, 'Directory.Build.props');
  const moduleManifestPath = path.join(repoRoot, 'tools', 'CompareVI.Tools', 'CompareVI.Tools.psd1');

  const pkg = JSON.parse(await readFile(pkgPath, 'utf8'));
  pkg.version = semver;
  await writeFile(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`, 'utf8');

  const packageLock = JSON.parse(await readFile(packageLockPath, 'utf8'));
  packageLock.version = semver;
  if (packageLock?.packages?.['']) {
    packageLock.packages[''].version = semver;
  }
  await writeFile(packageLockPath, `${JSON.stringify(packageLock, null, 2)}\n`, 'utf8');

  let propsRaw = await readFile(propsPath, 'utf8');
  propsRaw = replaceTextTag(propsRaw, 'Version', expected.propsVersion);
  propsRaw = replaceTextTag(propsRaw, 'AssemblyVersion', expected.assemblyVersion);
  propsRaw = replaceTextTag(propsRaw, 'FileVersion', expected.fileVersion);
  propsRaw = replaceTextTag(propsRaw, 'InformationalVersion', expected.informationalVersion);
  propsRaw = replaceTextTag(propsRaw, 'CompareViSharedPackageVersion', '$(Version)');
  await writeFile(propsPath, propsRaw, 'utf8');

  let manifestRaw = await readFile(moduleManifestPath, 'utf8');
  manifestRaw = replaceModuleManifestProperty(manifestRaw, 'ModuleVersion', expected.moduleVersion);
  manifestRaw = upsertModulePrerelease(manifestRaw, expected.modulePrerelease);
  await writeFile(moduleManifestPath, manifestRaw, 'utf8');

  return {
    previous,
    next: await readReleaseSurfaceVersions(repoRoot),
    changedFiles: [...RELEASE_SURFACE_VERSION_FILES]
  };
}
